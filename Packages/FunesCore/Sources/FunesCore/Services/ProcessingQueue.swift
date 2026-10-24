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

    static func from(row: Row) throws -> ProcessingJob {
        ProcessingJob(id: try row.requiredUUID("id"), subject: try row.requiredUUID("subject"), kind: try row.required("kind"),
                      state: try row.required("state"), attempts: row["attempts"], engine: row["engine"],
                      notBefore: row["not_before"], createdAt: row["created_at"])
    }
}

/// The durable processing queue (memory processing §5.2, step 3): every ingest path enqueues a
/// job in the same transaction as its input, so quitting loses nothing. Jobs run one at a time,
/// oldest first, are idempotent per subject and kind, are resumed at launch, and are retried with
/// backoff. Activity rows carry ids and counts only.
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
    }

    public let store: VaultStore
    public let activity: any ActivityRecorder

    public init(store: VaultStore, activity: any ActivityRecorder) {
        self.store = store
        self.activity = activity
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

    /// Takes the oldest job that is due, marking it running and counting the attempt.
    public func claim(now: Date) async throws -> ProcessingJob? {
        try await store.writer.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processing_job WHERE state = 'running'") == 0,
                  let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM processing_job WHERE state = 'queued' AND (not_before IS NULL OR not_before <= ?)
                    ORDER BY created_at, rowid LIMIT 1
                    """, arguments: [now]) else { return nil }
            var job = try ProcessingJob.from(row: row)
            job.state = .running
            job.attempts += 1
            try db.execute(sql: "UPDATE processing_job SET state = 'running', attempts = ?, updated_at = ? WHERE id = ?",
                           arguments: [job.attempts, now, job.id.db])
            return job
        }
    }

    /// Records a job's outcome: done, back in the queue after a backoff, or failed after
    /// `maxAttempts`. A job that threw is retried like `.retry`.
    public func finish(_ job: ProcessingJob, _ outcome: Outcome, now: Date) async throws {
        let state: ProcessingJob.State
        switch outcome {
        case let .done(engine):
            state = .done
            try await store.writer.write { db in
                try db.execute(sql: "UPDATE processing_job SET state = 'done', engine = ?, error = NULL, not_before = NULL, updated_at = ? WHERE id = ?",
                               arguments: [engine, now, job.id.db])
            }
        case let .later(until, code):
            state = .queued
            try await store.writer.write { db in
                try db.execute(sql: "UPDATE processing_job SET state = 'queued', attempts = MAX(0, attempts - 1), error = ?, not_before = ?, updated_at = ? WHERE id = ?",
                               arguments: [code, until, now, job.id.db])
            }
        case let .retry(code):
            state = job.attempts >= Self.maxAttempts ? .failed : .queued
            try await store.writer.write { db in
                try db.execute(sql: "UPDATE processing_job SET state = ?, error = ?, not_before = ?, updated_at = ? WHERE id = ?",
                               arguments: [state.rawValue, code, state == .queued ? now + Self.backoff(job.attempts) : nil, now,
                                           job.id.db])
            }
        }
        if state != .queued {
            activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "processing_job",
                                          outcome: state.rawValue, ids: [job.subject], counts: ["attempts": job.attempts]))
        }
    }

    /// 30 s, 2 min, 8 min, 32 min, then an hour.
    static func backoff(_ attempts: Int) -> TimeInterval {
        min(3_600, 30 * pow(4, Double(max(0, attempts - 1))))
    }

    /// Runs due jobs one at a time until none is left, with `work` doing each. Returns how many ran.
    @discardableResult
    public func drain(now: @Sendable () -> Date = { Date() },
                      _ work: @Sendable (ProcessingJob) async throws -> Outcome) async throws -> Int {
        var ran = 0
        while let job = try await claim(now: now()) {
            let outcome: Outcome
            do { outcome = try await work(job) } catch { outcome = .retry(code: "error") }
            try await finish(job, outcome, now: now())
            ran += 1
        }
        return ran
    }

    /// Jobs not yet done: queued, running or waiting for a retry.
    public func waiting() async throws -> Int {
        try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processing_job WHERE state IN ('queued','running')") ?? 0
        }
    }

    public func job(subject: UUID, kind: ProcessingJob.Kind = .newMemory) async throws -> ProcessingJob? {
        try await store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM processing_job WHERE subject = ? AND kind = ?",
                             arguments: [subject.db, kind.rawValue]).map(ProcessingJob.from(row:))
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
