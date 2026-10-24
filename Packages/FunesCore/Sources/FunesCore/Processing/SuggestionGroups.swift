import Foundation
import FunesProtocol
import GRDB

/// A split input in the Inbox (memory processing §5.2, UX Mac ▸ Inbox): the original suggestion,
/// its pieces, and what the group card shows about them.
public struct SuggestionGroup: Sendable, Hashable, Identifiable {
    /// The original suggestion's id (a split input), or the `split` suggestion's (Split this memory).
    public var id: UUID
    public var original: Suggestion
    /// Every piece, any status, in the order they were made.
    public var pieces: [Suggestion]
    /// The original text, while some piece is undecided; nil once dropped, or for Split this memory.
    public var sourceText: String?
    /// `<provider>/<model>` that split it.
    public var engine: String?

    /// Pieces arrived while the card was open: the card keeps its content and offers "Split into N?".
    public var isOffer: Bool { original.status == .pending && original.action != .split }
    public var pending: [Suggestion] { pieces.filter { $0.status == .pending } }
    /// Keep as one shows only while no piece is decided.
    public var canKeepAsOne: Bool { original.status == .split && pieces.allSatisfy { $0.status == .pending } }
    /// Pieces left out (beyond 40): "Long input: 40 shown".
    public var truncated: Int { JSON.decode(ClassificationRecord.self, original.classification)?.truncated ?? 0 }
}

/// One row's result of Apply all.
public struct GroupApplyResult: Sendable {
    public var applied: [UUID: ApplyResult]
    /// Pieces that failed, and why.
    public var failed: [UUID: VaultError]
    /// Flagged rows left for the user ("Outside <agent>'s scope").
    public var skipped: [UUID]
}

extension SuggestionService {
    /// The group with this id, or nil when it has no pieces.
    public func group(id: UUID) async throws -> SuggestionGroup? {
        try await store.writer.read { db in try Self.group(db, id: id) }
    }

    /// Groups with an undecided piece, newest first: split inputs, offers and Split this memory.
    public func openGroups() async throws -> [SuggestionGroup] {
        try await store.writer.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT DISTINCT group_id FROM suggestion WHERE group_id IS NOT NULL AND status = 'pending'
                """).compactMap(UUID.init(uuidString:))
            return try ids.compactMap { try Self.group(db, id: $0) }.sorted { $0.original.createdAt > $1.original.createdAt }
        }
    }

    static func group(_ db: Database, id: UUID) throws -> SuggestionGroup? {
        guard let original = try fetch(db, id: id) else { return nil }
        let pieces = try Row.fetchAll(db, sql: "SELECT * FROM suggestion WHERE group_id = ? ORDER BY created_at, rowid",
                                      arguments: [id.db]).map(Suggestion.from(row:))
        guard !pieces.isEmpty else { return nil }
        let row = try Row.fetchOne(db, sql: "SELECT source_text, engine FROM suggestion_group WHERE id = ?", arguments: [id.db])
        return SuggestionGroup(id: id, original: original, pieces: pieces, sourceText: row?["source_text"], engine: row?["engine"])
    }

    /// A suggestion still waiting for the user: pending, or split with an undecided piece (so
    /// `open_in_funes` and capture receipts keep working for a split input).
    public func isAwaitingReview(id: UUID) async throws -> Bool {
        try await store.writer.read { db in
            guard let s = try Self.fetch(db, id: id) else { return false }
            if s.status == .pending { return true }
            guard s.status == .split else { return false }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM suggestion WHERE group_id = ? AND status = 'pending'",
                                    arguments: [id.db]) ?? 0 > 0
        }
    }

    /// "Split into N?" accepted: the original is replaced by its pieces, if it's still pending.
    public func acceptSplit(groupID: UUID, now: Date) async throws {
        try await store.writer.write { db in
            guard let s = try Self.fetch(db, id: groupID), s.action != .split else { throw VaultError.notFound }
            guard s.status == .pending, !(try Self.pieces(db, groupID: groupID)).isEmpty else { throw VaultError.invalidState }
            try db.execute(sql: "UPDATE suggestion SET status = 'split', decided_at = ? WHERE id = ?", arguments: [now, groupID.db])
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "split", outcome: "split",
                                      ids: [groupID]))
    }

    /// Keep as one, or an offer declined: the pieces go and the original stays, or comes back,
    /// as one suggestion. Only while no piece is decided.
    public func keepAsOne(groupID: UUID, now: Date) async throws {
        try await store.writer.write { db in
            guard let s = try Self.fetch(db, id: groupID), s.action != .split else { throw VaultError.notFound }
            let decided = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM suggestion WHERE group_id = ? AND status != 'pending'",
                                           arguments: [groupID.db]) ?? 0
            guard decided == 0, s.status == .pending || s.status == .split else { throw VaultError.invalidState }
            try db.execute(sql: "DELETE FROM suggestion WHERE group_id = ?", arguments: [groupID.db])
            try db.execute(sql: "DELETE FROM suggestion_group WHERE id = ?", arguments: [groupID.db])
            try db.execute(sql: "UPDATE suggestion SET status = 'pending', decided_at = NULL WHERE id = ?", arguments: [groupID.db])
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "split", outcome: "kept_as_one",
                                      ids: [groupID]))
    }

    /// Apply all: each undecided row with its own action, skipping flagged rows; per-row results.
    public func applyAll(groupID: UUID, now: Date, actor: Actor = .user, via: ActivityEvent.Via = .app) async throws -> GroupApplyResult {
        guard let group = try await group(id: groupID) else { throw VaultError.notFound }
        if group.isOffer { try await acceptSplit(groupID: groupID, now: now) }
        var result = GroupApplyResult(applied: [:], failed: [:], skipped: [])
        for piece in group.pending {
            if piece.outsideScope {
                result.skipped.append(piece.id)
                continue
            }
            do {
                result.applied[piece.id] = try await apply(suggestionID: piece.id, now: now, actor: actor, via: via)
            } catch let error as VaultError {
                result.failed[piece.id] = error
            }
        }
        return result
    }

    /// The daily cleanup (storage §5): once every piece of a group is decided, its source text is
    /// dropped, from the group and from the original row.
    @discardableResult
    public func dropDecidedGroupText() async throws -> Int {
        try await store.writer.write { db in
            let decided = try String.fetchAll(db, sql: """
                SELECT g.id FROM suggestion_group g
                WHERE NOT EXISTS (SELECT 1 FROM suggestion p WHERE p.group_id = g.id AND p.status IN ('pending','expired'))
                  AND NOT EXISTS (SELECT 1 FROM suggestion o WHERE o.id = g.id AND o.status = 'pending')
                  AND (g.source_text IS NOT NULL
                       OR EXISTS (SELECT 1 FROM suggestion o WHERE o.id = g.id AND o.status = 'split' AND o.body != ''))
                """)
            for id in decided {
                try db.execute(sql: "UPDATE suggestion_group SET source_text = NULL WHERE id = ?", arguments: [id])
                try db.execute(sql: "UPDATE suggestion SET title = '', body = '' WHERE id = ? AND status = 'split'", arguments: [id])
            }
            return decided.count
        }
    }
}
