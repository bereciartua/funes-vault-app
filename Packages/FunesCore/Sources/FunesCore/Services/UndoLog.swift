import Foundation
import FunesProtocol
import GRDB

/// One automatic change Funes made (auto-apply, Phase 6a/6b), with what its memories looked like
/// before (spec/domain/domain-model.md, UndoEntry). Kept 30 days, purged with its memories,
/// never exported.
public struct UndoEntry: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var runID: UUID?
    public var suggestionID: UUID?
    /// What was done: a suggestion action (`create`, `update`, `merge`, `split`, `archive`).
    public var action: String
    public var memoryIDs: [UUID]
    public var undoneAt: Date?
    public var expiresAt: Date
}

/// The undo log (memory processing §5.7, §9.5; task 6.1.6). `record` runs an automatic change and
/// keeps each memory's before-state in the same transaction. `undo` puts them back: a memory the
/// change created goes to Recently Deleted, a changed one gets its old text, fields and status. A
/// memory changed again since can only be undone together with the later automatic changes that
/// explain it ("Undo this and N later changes"); a change by anyone else refuses.
public final class UndoLog: Sendable {
    public static let lifetime: TimeInterval = 30 * 86_400

    /// A memory as the change found it, and its version right after.
    struct Snapshot: Codable, Hashable {
        var memoryID: UUID
        /// False: the change created it.
        var existed: Bool
        var title: String?
        var body: String?
        var kind: MemoryKind?
        var categoryKeys: [String]?
        var sensitivity: Sensitivity?
        var status: MemoryStatus?
        var expiresAt: Date?
        var trust: MemoryTrust?
        var versionAfter: Int?
    }

    public let store: VaultStore
    public let activity: any ActivityRecorder

    public init(store: VaultStore, activity: any ActivityRecorder) {
        self.store = store
        self.activity = activity
    }

    /// Runs `change` in the caller's transaction and records the before-state of `memoryIDs`
    /// (existing ones, and the ids `change` returns as created). Returns the entry's id.
    @discardableResult
    static func record(_ db: Database, action: String, memoryIDs: [UUID], suggestionID: UUID? = nil, runID: UUID? = nil,
                       now: Date, change: () throws -> [UUID]) throws -> UUID {
        var snapshots = try memoryIDs.map { id -> Snapshot in
            guard let m = try MemoryStore.fetch(db, id: id) else { return Snapshot(memoryID: id, existed: false) }
            return Snapshot(memoryID: id, existed: true, title: m.title, body: m.body, kind: m.kind, categoryKeys: m.categoryKeys,
                            sensitivity: m.sensitivity, status: m.status, expiresAt: m.expiresAt,
                            trust: try MemoryStore.trust(db, id: id))
        }
        let created = try change()
        for id in created where !snapshots.contains(where: { $0.memoryID == id }) {
            snapshots.append(Snapshot(memoryID: id, existed: false))
        }
        for i in snapshots.indices {
            snapshots[i].versionAfter = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?",
                                                         arguments: [snapshots[i].memoryID.db])
        }
        let id = UUID()
        try db.execute(sql: """
            INSERT INTO undo_entry (id, created_at, run_id, suggestion_id, action, memory_ids, before_state, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id.db, now, runID?.db, suggestionID?.db, action, JSON.encode(snapshots.map(\.memoryID.db)),
                             JSON.encode(snapshots), now + lifetime])
        return id
    }

    /// The Applied automatically list: changes not undone yet, newest first.
    public func entries(now: Date) async throws -> [UndoEntry] {
        try await store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM undo_entry WHERE undone_at IS NULL AND expires_at > ? ORDER BY created_at DESC, rowid DESC",
                             arguments: [now]).map(Self.entry(from:))
        }
    }

    /// Undoes a change, and with `includingLater` the later automatic changes to the same memories
    /// first, newest first. Refuses with `undoNeedsLater(n)` when later changes depend on it, and
    /// with `undoNotPossible` when a memory was changed by anyone else since, or the entry is gone,
    /// expired or already undone. Returns the ids of the entries undone.
    @discardableResult
    public func undo(entryID: UUID, includingLater: Bool = false, actor: Actor = .user, now: Date) async throws -> [UUID] {
        let undone = try await store.writer.write { db -> [UUID] in
            guard let target = try Self.fetch(db, id: entryID), target.entry.undoneAt == nil, target.entry.expiresAt > now else {
                throw VaultError.undoNotPossible
            }
            // Later live entries touching any of the same memories, transitively.
            let live = try Row.fetchAll(db, sql: """
                SELECT * FROM undo_entry WHERE undone_at IS NULL AND (created_at > ? OR (created_at = ? AND rowid > (SELECT rowid FROM undo_entry WHERE id = ?)))
                ORDER BY created_at, rowid
                """, arguments: [target.entry.createdAt, target.entry.createdAt, entryID.db]).map(Self.parsed(from:))
            var touched = Set(target.entry.memoryIDs)
            var later: [(entry: UndoEntry, snapshots: [Snapshot])] = []
            for candidate in live where !touched.isDisjoint(with: candidate.entry.memoryIDs) {
                later.append(candidate)
                touched.formUnion(candidate.entry.memoryIDs)
            }
            if !later.isEmpty, !includingLater { throw VaultError.undoNeedsLater(later.count) }
            // Each memory must be exactly as the newest entry touching it left it.
            let chain = [target] + later
            for id in touched {
                guard let last = chain.last(where: { $0.entry.memoryIDs.contains(id) }),
                      let after = last.snapshots.first(where: { $0.memoryID == id })?.versionAfter else { continue }
                let current = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [id.db])
                guard current == after else { throw VaultError.undoNotPossible }
            }
            for item in chain.reversed() {
                // A merge's or split's new memories are archived (§9.5); other saved ones go to
                // Recently Deleted (§5.7).
                let created: MemoryStatus = ["merge", "split"].contains(item.entry.action) ? .archived : .deleted
                try Self.restore(db, item.snapshots, created: created, actor: actor, now: now)
                try db.execute(sql: "UPDATE undo_entry SET undone_at = ? WHERE id = ?", arguments: [now, item.entry.id.db])
            }
            return chain.reversed().map(\.entry.id)
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: actor, via: .app, event: "undone", outcome: "undone",
                                      ids: undone, counts: ["changes": undone.count]))
        return undone
    }

    static func restore(_ db: Database, _ snapshots: [Snapshot], created: MemoryStatus, actor: Actor, now: Date) throws {
        for s in snapshots {
            guard let m = try MemoryStore.fetch(db, id: s.memoryID) else { continue }
            if !s.existed {
                if m.status != created { try MemoryStore.setStatus(db, id: m.id, to: created, actor: actor, now: now) }
            } else {
                if let status = s.status, status != m.status {
                    try MemoryStore.setStatus(db, id: m.id, to: status, actor: actor, now: now)
                }
                try MemoryStore.update(db, id: m.id, MemoryEdit(
                    title: s.title, body: s.body, kind: s.kind, categoryKeys: s.categoryKeys, sensitivity: s.sensitivity,
                    expiresAt: .some(s.expiresAt)), actor: actor, now: now)
                if let trust = s.trust {
                    try db.execute(sql: "UPDATE memory SET trust = ? WHERE id = ?", arguments: [trust.rawValue, m.id.db])
                }
            }
            try MemoryStore.appendProvenance(db, memoryID: m.id, event: .undone, actor: actor, at: now)
        }
    }

    /// The daily job (storage §5): entries past 30 days are deleted, and suggestion groups whose
    /// pieces are all decided drop their source text.
    @discardableResult
    public func cleanup(now: Date) async throws -> Int {
        try await store.writer.write { db in
            try db.execute(sql: "DELETE FROM undo_entry WHERE expires_at <= ?", arguments: [now])
            let deleted = db.changesCount
            try db.execute(sql: """
                UPDATE suggestion_group SET source_text = NULL WHERE source_text IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM suggestion WHERE group_id = suggestion_group.id AND status = 'pending')
                """)
            return deleted
        }
    }

    /// Entries holding the before-state of these memories go when they're purged.
    static func purge(_ db: Database, memoryIDs: [String]) throws {
        guard !memoryIDs.isEmpty else { return }
        try db.execute(sql: """
            DELETE FROM undo_entry WHERE EXISTS (
              SELECT 1 FROM json_each(undo_entry.memory_ids) j WHERE j.value IN (\(databaseQuestionMarks(count: memoryIDs.count))))
            """, arguments: StatementArguments(memoryIDs))
    }

    static func fetch(_ db: Database, id: UUID) throws -> (entry: UndoEntry, snapshots: [Snapshot])? {
        try Row.fetchOne(db, sql: "SELECT * FROM undo_entry WHERE id = ?", arguments: [id.db]).map(parsed(from:))
    }

    static func parsed(from row: Row) throws -> (entry: UndoEntry, snapshots: [Snapshot]) {
        (try entry(from: row), JSON.decode([Snapshot].self, row["before_state"]) ?? [])
    }

    static func entry(from row: Row) throws -> UndoEntry {
        UndoEntry(id: try row.requiredUUID("id"), createdAt: row["created_at"], runID: row.uuid("run_id"),
                  suggestionID: row.uuid("suggestion_id"), action: row["action"],
                  memoryIDs: (JSON.decode([String].self, row["memory_ids"]) ?? []).compactMap(UUID.init(uuidString:)),
                  undoneAt: row["undone_at"], expiresAt: row["expires_at"])
    }
}
