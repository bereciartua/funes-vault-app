import Foundation
import FunesProtocol
import GRDB

/// One durable piece of model work (spec/domain/domain-model.md, ProcessingJob): about a
/// suggestion or a memory, never holding text.
public struct ProcessingJob: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// A new input: classification today, splitting from Phase 6a (memory processing §5.2).
        case newMemory = "new_memory"
        /// A daily tidy-up run (Phase 6b).
        case tidyUp = "tidy_up"
        /// Learning facts from one memory in one call group, or the reconciliation sweep (memory processing §11.3):
        /// the low-priority lane.
        case facts
    }

    public enum State: String, Sendable, Hashable, Codable {
        case queued, running, done, failed
    }

    public var id: UUID
    /// A suggestion id, or a memory id for an agent's direct write.
    public var subject: UUID
    public var kind: Kind
    public var state: State
    public var attempts: Int
    public var engine: String?
    public var notBefore: Date?
    public var createdAt: Date
    /// A `facts` job: the memory version it was last asked for, and its call group. The sweep has neither.
    public var memoryVersion: Int?
    public var callGroup: String?
    /// Bumped by every enqueue: work asked for while the job ran isn't lost when it finishes.
    public var generation: Int = 0

    /// The facts lane's reconciliation sweep, rather than one memory.
    public var isFactsSweep: Bool { kind == .facts && callGroup == nil }

    static func from(row: Row) throws -> ProcessingJob {
        ProcessingJob(id: try row.requiredUUID("id"), subject: try row.requiredUUID("subject"), kind: try row.required("kind"),
                      state: try row.required("state"), attempts: row["attempts"], engine: row["engine"],
                      notBefore: row["not_before"], createdAt: row["created_at"], memoryVersion: row["memory_version"],
                      callGroup: row["call_group"], generation: row["generation"] ?? 0)
    }
}

/// The durable processing queue (memory processing §5.2, step 3): every ingest path enqueues a
/// job in the same transaction as its input, so quitting loses nothing. Jobs run one at a time,
/// oldest first, are idempotent per subject and kind, are resumed at launch, and are retried with
/// backoff. Activity rows carry ids and counts only.
///
/// `facts` jobs (memory processing §11.3) run in a low-priority lane: only while no New memories or tidy-up job is
/// queued or running and no tidy-up run is open. There is one per memory and call group, asked for again by a newer
/// memory version or by reconciliation, and one reconciliation sweep, which runs after them.
public final class ProcessingQueue: Sendable {
    /// Attempts before a job is given up as `failed`.
    public static let maxAttempts = 5
    /// Finished jobs are kept this long, so a subject isn't processed twice, then cleaned up.
    public static let retention: TimeInterval = 30 * 86_400

    /// What a job's work reports.
    public enum Outcome: Sendable, Hashable {
        /// Done; `engine` is the model that did it, if any.
        case done(engine: String?)
        /// Try again later (a provider was unavailable or rate-limited); counts as an attempt.
        case retry(code: String)
        /// Wait until then without counting an attempt: agent input and imports at the daily cap
        /// wait for the next day (ADR-0022).
        case later(until: Date, code: String)
        /// Given up at once: splitting failed, and the card offers Try again and Keep as one
        /// (memory processing §5.2).
        case failed(code: String)
    }

    public let store: VaultStore
    public let activity: any ActivityRecorder
    /// When this process started: a tidy-up run left open before it was interrupted, not running.
    public let launchedAt: Date
    /// An in-process pause for the facts lane (the Mac's tidy-up while it runs, before it writes its run row).
    public let factsPaused: @Sendable () -> Bool

    public init(store: VaultStore, activity: any ActivityRecorder, launchedAt: Date = Date(),
                factsPaused: @escaping @Sendable () -> Bool = { false }) {
        self.store = store
        self.activity = activity
        self.launchedAt = launchedAt
        self.factsPaused = factsPaused
    }

    /// The subject of the facts lane's one reconciliation sweep.
    public static let factsSweepSubject = UUID(uuidString: "00000000-0000-0000-0000-0000000000f5")!

    /// Why a facts job is asked for.
    public enum FactsReason: Sendable {
        /// A committed memory version to read: ignored if that version (or a newer one) was already done.
        case version
        /// Reconciliation found something to ask again: always runs, and the job works out what.
        case reconcile
    }

    /// Asks for a memory to be read in a call group, in the caller's transaction (memory processing §11.3). One row
    /// per memory and group: a newer version or a reconciliation requeues a finished row, and one that is running
    /// gets a new generation, so it runs again when it finishes, whatever its outcome.
    static func enqueueFacts(_ db: Database, memoryID: UUID, version: Int, group: String, reason: FactsReason, now: Date) throws {
        try upsertFacts(db, subject: memoryID, version: version, group: group, reason: reason, now: now)
    }

    /// Asks for the reconciliation sweep, in the caller's transaction. Deduped like any facts job.
    static func enqueueFactsSweep(_ db: Database, now: Date) throws {
        try upsertFacts(db, subject: factsSweepSubject, version: nil, group: nil, reason: .reconcile, now: now)
    }

    private static func upsertFacts(_ db: Database, subject: UUID, version: Int?, group: String?, reason: FactsReason, now: Date) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT id, state, memory_version FROM processing_job WHERE subject = ? AND kind = 'facts' AND COALESCE(call_group, '') = ?
            """, arguments: [subject.db, group ?? ""]) else {
            try db.execute(sql: """
                INSERT INTO processing_job (id, subject, kind, state, attempts, created_at, updated_at, memory_version, call_group)
                VALUES (?, ?, 'facts', 'queued', 0, ?, ?, ?, ?)
                """, arguments: [UUID().db, subject.db, now, now, version, group])
            return
        }
        let id: String = row["id"], state: String = row["state"], old: Int? = row["memory_version"]
        let newer = version.map { v in old.map { v > $0 } ?? true } ?? false
        switch state {
        case "queued", "running":
            try db.execute(sql: """
                UPDATE processing_job SET generation = generation + 1, memory_version = MAX(COALESCE(memory_version, ?1), ?1), updated_at = ?2
                WHERE id = ?3
                """, arguments: [version, now, id])
        default:
            guard reason == .reconcile || newer else { return }       // that version was read already
            try db.execute(sql: """
                UPDATE processing_job SET state = 'queued', attempts = 0, error = NULL, not_before = NULL, engine = NULL,
                  generation = generation + 1, memory_version = COALESCE(?, memory_version), created_at = ?, updated_at = ? WHERE id = ?
                """, arguments: [version, now, now, id])
        }
    }

    /// Queues a job in the caller's transaction. A second job for the same subject and kind is
    /// ignored, whatever state the first is in.
    static func enqueue(_ db: Database, subject: UUID, kind: ProcessingJob.Kind = .newMemory, now: Date) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO processing_job (id, subject, kind, state, attempts, created_at, updated_at)
            VALUES (?, ?, ?, 'queued', 0, ?, ?)
            """, arguments: [UUID().db, subject.db, kind.rawValue, now, now])
    }

    /// At launch: jobs left `running` by a quit or crash go back to the queue. Returns how many.
    @discardableResult
    public func resume(now: Date) async throws -> Int {
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE processing_job SET state = 'queued', updated_at = ? WHERE state = 'running'", arguments: [now])
            return db.changesCount
        }
    }

    /// Takes the oldest job that is due, marking it running and counting the attempt. New memories and tidy-up jobs
    /// come first; a `facts` job only while the facts lane is open, memories before the sweep.
    public func claim(now: Date) async throws -> ProcessingJob? {
        let paused = factsPaused()
        return try await store.writer.write { [launchedAt] db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processing_job WHERE state = 'running'") == 0 else { return nil }
            var found = try Row.fetchOne(db, sql: """
                SELECT * FROM processing_job WHERE state = 'queued' AND kind != 'facts' AND (not_before IS NULL OR not_before <= ?)
                ORDER BY created_at, rowid LIMIT 1
                """, arguments: [now])
            if found == nil, !paused, try Self.factsLaneOpen(db, launchedAt: launchedAt) {
                found = try Row.fetchOne(db, sql: """
                    SELECT * FROM processing_job WHERE state = 'queued' AND kind = 'facts' AND (not_before IS NULL OR not_before <= ?)
                    ORDER BY call_group IS NULL, created_at, rowid LIMIT 1
                    """, arguments: [now])
            }
            guard let row = found else { return nil }
            var job = try ProcessingJob.from(row: row)
            job.state = .running
            job.attempts += 1
            try db.execute(sql: "UPDATE processing_job SET state = 'running', attempts = ?, updated_at = ? WHERE id = ?",
                           arguments: [job.attempts, now, job.id.db])
            return job
        }
    }

    /// The facts lane waits while New memories or the tidy-up wait (memory processing §11.3): any other job queued
    /// (due or waiting for a retry) or running, or a tidy-up run this process opened and hasn't finished.
    static func factsLaneOpen(_ db: Database, launchedAt: Date) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS (SELECT 1 FROM processing_job WHERE kind != 'facts' AND state IN ('queued','running'))
              AND NOT EXISTS (SELECT 1 FROM tidy_up_run WHERE finished_at IS NULL AND started_at >= ?)
            """, arguments: [launchedAt]) ?? false
    }

    /// Records a job's outcome: done, back in the queue after a backoff, or failed after
    /// `maxAttempts`. A job that threw is retried like `.retry`. A `facts` job asked for again while it ran goes
    /// straight back to the queue, whatever its outcome.
    public func finish(_ job: ProcessingJob, _ outcome: Outcome, now: Date) async throws {
        let id = job.id.db
        let state: ProcessingJob.State? = try await store.writer.write { db in
            // Checked in the same transaction as the outcome is written, so an enqueue can't fall between them.
            if job.kind == .facts {
                try db.execute(sql: """
                    UPDATE processing_job SET state = 'queued', attempts = 0, error = NULL, not_before = NULL, updated_at = ?
                    WHERE id = ? AND generation != ?
                    """, arguments: [now, id, job.generation])
                if db.changesCount > 0 { return nil }
            }
            switch outcome {
            case let .done(engine):
                try db.execute(sql: "UPDATE processing_job SET state = 'done', engine = ?, error = NULL, not_before = NULL, updated_at = ? WHERE id = ?",
                               arguments: [engine, now, id])
                return .done
            case let .later(until, code):
                try db.execute(sql: "UPDATE processing_job SET state = 'queued', attempts = MAX(0, attempts - 1), error = ?, not_before = ?, updated_at = ? WHERE id = ?",
                               arguments: [code, until, now, id])
                return .queued
            case let .failed(code):
                try db.execute(sql: "UPDATE processing_job SET state = 'failed', error = ?, not_before = NULL, updated_at = ? WHERE id = ?",
                               arguments: [code, now, id])
                return .failed
            case let .retry(code):
                let state: ProcessingJob.State = job.attempts >= Self.maxAttempts ? .failed : .queued
                try db.execute(sql: "UPDATE processing_job SET state = ?, error = ?, not_before = ?, updated_at = ? WHERE id = ?",
                               arguments: [state.rawValue, code, state == .queued ? now + Self.backoff(job.attempts) : nil, now, id])
                return state
            }
        }
        if let state, state != .queued {
            activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "processing_job",
                                          outcome: state.rawValue, ids: [job.subject], counts: ["attempts": job.attempts]))
        }
    }

    /// 30 s, 2 min, 8 min, 32 min, then an hour.
    static func backoff(_ attempts: Int) -> TimeInterval {
        min(3_600, 30 * pow(4, Double(max(0, attempts - 1))))
    }

    /// Runs due jobs one at a time until none is left, with `work` doing each. `finished` hears
    /// each job once its outcome is recorded (the Mac shows an agent's Save panels then). Returns
    /// how many ran.
    @discardableResult
    public func drain(now: @Sendable () -> Date = { Date() },
                      finished: @Sendable (ProcessingJob) async -> Void = { _ in },
                      _ work: @Sendable (ProcessingJob) async throws -> Outcome) async throws -> Int {
        var ran = 0
        while let job = try await claim(now: now()) {
            let outcome: Outcome
            do { outcome = try await work(job) } catch { outcome = .retry(code: "error") }
            try await finish(job, outcome, now: now())
            await finished(job)
            ran += 1
        }
        return ran
    }

    /// Jobs not yet done: queued, running or waiting for a retry. The facts lane isn't counted (it isn't the
    /// Inbox's work).
    public func waiting() async throws -> Int {
        try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processing_job WHERE state IN ('queued','running') AND kind != 'facts'") ?? 0
        }
    }

    public func job(subject: UUID, kind: ProcessingJob.Kind = .newMemory, callGroup: String? = nil) async throws -> ProcessingJob? {
        try await store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM processing_job WHERE subject = ? AND kind = ? AND COALESCE(call_group, '') = ?",
                             arguments: [subject.db, kind.rawValue, callGroup ?? ""]).map(ProcessingJob.from(row:))
        }
    }

    /// The daily job: finished jobs older than 30 days are deleted.
    @discardableResult
    public func cleanup(now: Date) async throws -> Int {
        try await store.writer.write { db in
            try db.execute(sql: "DELETE FROM processing_job WHERE state IN ('done','failed') AND updated_at <= ?",
                           arguments: [now - Self.retention])
            return db.changesCount
        }
    }
}
