import Foundation
import FunesProtocol
import GRDB
import Synchronization

/// Whether the processing job splits new inputs now (memory processing §5.2): Settings ▸ AI
/// Models ▸ New memories ▸ Split into separate memories, with a local server or cloud model
/// chosen. The Mac keeps it current. While it's off, a waiting job holds nothing: cards and Save
/// panels appear at once, as before splitting.
public final class SplittingSwitch: Sendable {
    private let on: Mutex<Bool>

    public init(_ on: Bool = false) { self.on = Mutex(on) }

    public var isOn: Bool { on.withLock { $0 } }

    public func set(_ value: Bool) { on.withLock { $0 = value } }
}

/// A new input New memories processing hasn't finished with (memory processing §5.2, UX Mac ▸
/// Inbox). While its job is queued or running the card shows "Processing…" and can't be applied
/// or edited, only rejected; when the job fails, it offers Try again and Keep as one.
public enum InputProcessing: Sendable, Hashable {
    /// Being split now.
    case running
    /// Waiting for its turn behind `ahead` jobs.
    case queued(ahead: Int)
    /// Waiting until then: today's cloud request cap (`capReached`), or a retry's backoff.
    case waiting(until: Date, capReached: Bool)
    /// Splitting failed (the provider, a timeout, invalid output, a blocked CLI run, no pieces):
    /// "Couldn't split". `code` says why, for Activity and support.
    case failed(code: String?)

    /// Queued, running or waiting: not yet answerable.
    public var isProcessing: Bool {
        if case .failed = self { return false }
        return true
    }
}

extension SuggestionService {
    /// Pending inputs that processing holds or failed on, by suggestion id.
    public func processing(now: Date) async throws -> [UUID: InputProcessing] {
        let splitting = self.splitting.isOn
        return try await store.writer.read { db in try Self.processing(db, ids: nil, splitting: splitting, now: now) }
    }

    public func processing(id: UUID, now: Date) async throws -> InputProcessing? {
        let splitting = self.splitting.isOn
        return try await store.writer.read { db in try Self.processing(db, ids: [id], splitting: splitting, now: now)[id] }
    }

    /// A suggestion is held while it's pending, one the job would split (a new input: no group,
    /// no target, not the tidy-up's), and its `new_memory` job is queued or running with splitting
    /// on. A failed job shows whatever the switch says, until Try again or Keep as one.
    static func processing(_ db: Database, ids: [UUID]?, splitting: Bool, now: Date) throws -> [UUID: InputProcessing] {
        var sql = """
            SELECT s.id, j.state, j.error, j.not_before,
              (SELECT COUNT(*) FROM processing_job a WHERE a.state IN ('queued','running')
                 AND (a.not_before IS NULL OR a.not_before <= ?)
                 AND (a.created_at < j.created_at OR (a.created_at = j.created_at AND a.rowid < j.rowid))) AS ahead
            FROM suggestion s JOIN processing_job j ON j.subject = s.id AND j.kind = 'new_memory'
            WHERE s.status = 'pending' AND s.group_id IS NULL AND s.target_memory_id IS NULL AND s.action = 'create'
              AND s.origin != 'consolidation' AND j.state IN ('queued','running','failed')
            """
        var arguments: [any DatabaseValueConvertible] = [now]
        if let ids {
            guard !ids.isEmpty else { return [:] }
            sql += " AND s.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            arguments += ids.map(\.db)
        }
        var out: [UUID: InputProcessing] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)) {
            let id = try row.requiredUUID("id")
            let state: ProcessingJob.State = try row.required("state")
            let error: String? = row["error"]
            switch state {
            case .failed:
                out[id] = .failed(code: error)
            case .running where splitting:
                out[id] = .running
            case .queued where splitting:
                if let until: Date = row["not_before"], until > now {
                    out[id] = .waiting(until: until, capReached: error == "cap_reached")
                } else {
                    out[id] = .queued(ahead: row["ahead"])
                }
            case .queued, .running, .done:
                break
            }
        }
        return out
    }

    /// Queued, running or waiting: apply refuses it (`processing`).
    static func isProcessing(_ db: Database, _ id: UUID, splitting: Bool, now: Date) throws -> Bool {
        try processing(db, ids: [id], splitting: splitting, now: now)[id]?.isProcessing == true
    }

    /// What an agent's Save panels show for its suggestion (UX Mac ▸ Save panel): nil while it's
    /// processing (ask again when its job ends); one panel per undecided piece once it's split;
    /// itself while it's pending, failed splits included; nothing once it's decided.
    public func savePanels(for id: UUID, now: Date) async throws -> [UUID]? {
        let splitting = self.splitting.isOn
        return try await store.writer.read { db in
            guard let s = try Self.fetch(db, id: id) else { return [] }
            if try Self.isProcessing(db, id, splitting: splitting, now: now) { return nil }
            switch s.status {
            case .pending: return [id]
            case .split: return try Self.pieces(db, groupID: id).map(\.id)
            case .applied, .rejected, .expired: return []
            }
        }
    }

    /// Try again on a card whose split failed: its job goes back to the queue, as new.
    public func retryProcessing(suggestionID: UUID, now: Date, actor: Actor = .user, via: ActivityEvent.Via = .app) async throws {
        try await store.writer.write { db in
            guard let s = try Self.fetch(db, id: suggestionID) else { throw VaultError.notFound }
            guard s.status == .pending else { throw VaultError.invalidState }
            try db.execute(sql: """
                UPDATE processing_job SET state = 'queued', attempts = 0, error = NULL, not_before = NULL, updated_at = ?
                WHERE subject = ? AND kind = 'new_memory' AND state = 'failed'
                """, arguments: [now, suggestionID.db])
            guard db.changesCount == 1 else { throw VaultError.invalidState }
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: actor, via: via, event: "processing_job",
                                      outcome: "retried", ids: [suggestionID]))
    }

    /// Keep as one on a card whose split failed: the original stays one suggestion, reviewed as it is.
    public func keepAsOne(suggestionID: UUID, now: Date, actor: Actor = .user, via: ActivityEvent.Via = .app) async throws {
        try await store.writer.write { db in
            guard let s = try Self.fetch(db, id: suggestionID) else { throw VaultError.notFound }
            guard s.status == .pending else { throw VaultError.invalidState }
            try db.execute(sql: """
                UPDATE processing_job SET state = 'done', error = 'kept_as_one', not_before = NULL, updated_at = ?
                WHERE subject = ? AND kind = 'new_memory' AND state = 'failed'
                """, arguments: [now, suggestionID.db])
            guard db.changesCount == 1 else { throw VaultError.invalidState }
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: actor, via: via, event: "split", outcome: "kept_as_one",
                                      ids: [suggestionID]))
    }

    /// Reject cancels the input's job if it hasn't started (or failed); one already running finds
    /// the suggestion decided and stores nothing.
    static func cancelProcessing(_ db: Database, _ id: UUID, now: Date) throws {
        try db.execute(sql: """
            UPDATE processing_job SET state = 'done', error = 'cancelled', not_before = NULL, updated_at = ?
            WHERE subject = ? AND kind = 'new_memory' AND state IN ('queued','failed')
            """, arguments: [now, id.db])
    }
}
