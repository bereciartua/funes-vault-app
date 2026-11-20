import Foundation
import FunesProtocol
import GRDB

/// The first Facts backfill (FR-F-03, memory processing §11.3 "Cost and the cap"): the memories already in the vault,
/// read once outside the daily cap, started by the user after seeing the call count and cost. One exemption in total,
/// covering both call groups.
///
/// - **The exemption** is one full read per marked job: a `facts` job carries `exempt_version`, the memory version it was
///   marked for, and only a full read of exactly that version skips the cap (`FactsExtractor.exemptVersion`). Reconciliation,
///   a changed memory and re-reads count, as every other Facts call does. The mark goes when the job ends (done or
///   failed), so exempt calls never exceed what the sheet counted.
/// - **Resumable:** the marked jobs are the resume point; a quit, sleep, a network loss or a provider failure leaves them
///   queued. A provider failure on a marked job waits instead of spending an attempt.
/// - **Bound to the estimate:** the state records each group's engine and the roster limit the user saw; a marked job
///   finding another pauses the backfill (`changed`) until the user reviews the new estimate.
/// - **The end:** when the last mark goes (in that transaction), the state is finished and Activity gets one
///   `facts_backfill` row; also checked at launch (`settle`).
/// - **State** in `meta('facts_backfill')`, kept by Remove learned facts (ended there), so a Remove never grants a second
///   exemption.
public enum FactsBackfill {
    static let metaKey = "facts_backfill"

    /// The backfill's state; present once it started (the exemption is used).
    public struct State: Codable, Sendable, Equatable {
        public var startedAt: Date
        /// Memories marked at the start.
        public var memories: Int
        /// The model calls the sheet counted.
        public var calls: Int
        /// Each call group's engine (`ModelRouter.engine`) the estimate was made with.
        public var engines: [String: String]
        /// The roster limit the estimate was made with (`CloudLimit`, nil when every model is on this Mac).
        public var limit: CloudLimit?
        /// Paused by the user.
        public var paused = false
        /// Paused because Facts' model or the cloud limit changed since the estimate.
        public var changed = false
        public var finishedAt: Date?
        /// How it ended: `done`, or `removed` (Remove learned facts while it ran).
        public var ended: String?

        public init(startedAt: Date, memories: Int, calls: Int, engines: [String: String], limit: CloudLimit?) {
            self.startedAt = startedAt
            self.memories = memories
            self.calls = calls
            self.engines = engines
            self.limit = limit
        }

        public var isRunning: Bool { finishedAt == nil }
        public var isPaused: Bool { isRunning && (paused || changed) }
    }

    /// What the sheet shows before anything is sent, computed from the open vault.
    public struct Estimate: Sendable, Equatable {
        /// Active and archived memories with some call group a model would read for the first time.
        public var memories = 0
        /// Model calls: those memories within the roster limit, once per group.
        public var calls = 0
        /// Of `memories`, the ones above the cloud limit: code-only links, no call.
        public var kept = 0
        /// The groups a model reads now (a group with none isn't part of the backfill).
        public var groups: [String] = []
        public var engines: [String: String] = [:]
        public var limit: CloudLimit?
        /// API-equivalent dollars, when every group's model has a measured cost (`FactsCost`).
        public var cost: Double?

        public init(memories: Int = 0, calls: Int = 0, kept: Int = 0, groups: [String] = [], engines: [String: String] = [:],
                    limit: CloudLimit? = nil, cost: Double? = nil) {
            self.memories = memories
            self.calls = calls
            self.kept = kept
            self.groups = groups
            self.engines = engines
            self.limit = limit
            self.cost = cost
        }
    }

    /// The backfill's progress, for the Facts page and the Features row.
    public struct Progress: Sendable, Equatable {
        public var state: State
        /// Memories whose marked jobs have all ended.
        public var done: Int
        public var total: Int { state.memories }

        public init(state: State, done: Int) {
            self.state = state
            self.done = done
        }
    }

    // MARK: State

    public static func state(_ db: Database) throws -> State? {
        JSON.decode(State.self, try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [metaKey]))
    }

    static func write(_ db: Database, _ state: State) throws {
        try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [metaKey, JSON.encode(state)])
    }

    /// How many memories still have a marked job.
    static func remaining(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT subject) FROM processing_job WHERE kind = 'facts' AND exempt_version IS NOT NULL") ?? 0
    }

    public static func progress(_ db: Database) throws -> Progress? {
        guard let s = try state(db) else { return nil }
        return Progress(state: s, done: s.isRunning ? max(0, s.memories - (try remaining(db))) : s.memories)
    }

    // MARK: The estimate

    /// The memories a model would read for the first time, per group with a model allowed now (§11.10), and the calls
    /// that makes, in one read. A memory already read at its current version in a group isn't counted there.
    /// `owed`: only the reads the running backfill still owes (its marks), for a review after a change.
    static func estimate(_ db: Database, extractor x: FactsExtractor, owed: Bool = false) throws -> Estimate {
        let uses = try x.currentUses(db)
        var e = Estimate()
        e.groups = x.groups.filter { x.modelAllowed($0, uses) }
        for g in e.groups { e.engines[g] = x.router.factsModels[g].map(ModelRouter.engine) }
        e.limit = x.rosterLimit
        guard !e.groups.isEmpty else { return e }
        let read = try readSet(db)
        var marked = Set<String>()
        if owed {
            for r in try Row.fetchAll(db, sql: "SELECT subject, call_group FROM processing_job WHERE kind = 'facts' AND exempt_version IS NOT NULL") {
                marked.insert((r["subject"] as String) + "\u{1F}" + (r["call_group"] as String))
            }
        }
        var perGroup: [String: Int] = [:]
        for m in try Row.fetchAll(db, sql: "SELECT id, version, sensitivity FROM memory WHERE status IN ('active','archived')") {
            let id: String = m["id"], version: Int = m["version"]
            let unread = e.groups.filter {
                !read.contains(ReadKey(memoryID: id, version: version, group: $0)) && (!owed || marked.contains(id + "\u{1F}" + $0))
            }
            guard !unread.isEmpty else { continue }
            e.memories += 1
            let sensitivity = Sensitivity(rawValue: m["sensitivity"]) ?? .secret
            if let limit = e.limit, !limit.allows(sensitivity) {
                e.kept += 1
                continue
            }
            e.calls += unread.count
            for g in unread { perGroup[g, default: 0] += 1 }
        }
        var cost = 0.0
        for g in e.groups {
            guard let model = x.router.factsModels[g]?.modelID, let perCall = FactsCost.perCall(model: model, group: g) else {
                return e
            }
            cost += perCall * Double(perGroup[g] ?? 0)
        }
        e.cost = cost
        return e
    }

    struct ReadKey: Hashable {
        var memoryID: String
        var version: Int
        var group: String
    }

    /// Every (memory, version, group) the model has read.
    static func readSet(_ db: Database) throws -> Set<ReadKey> {
        Set(try Row.fetchAll(db, sql: "SELECT memory_id, memory_version, call_group FROM facts_asked WHERE mention_kind = 'read'").map {
            ReadKey(memoryID: $0["memory_id"], version: $0["memory_version"], group: $0["call_group"])
        })
    }

    // MARK: Starting, pausing, the end

    public enum StartError: Error, Equatable {
        /// *Learn from memories* is off.
        case notLearning
        /// The one exemption was used already.
        case used
        /// The vault or Facts' configuration changed since the estimate: show the sheet again.
        case changed
        /// Nothing to send: starting would use the exemption for no read.
        case nothing
    }

    /// Starts the backfill the user agreed to after seeing `shown`, in one transaction: refuses unless learning is on,
    /// no backfill ever started, and the estimate made now is the one shown (so nothing beyond what was shown is sent).
    /// Marks every (memory, group) a model hasn't read at its current version, in the groups shown, and wakes them.
    static func start(_ db: Database, extractor x: FactsExtractor, shown: Estimate, now: Date) throws -> State {
        guard FactsLane.learning(db) else { throw StartError.notLearning }
        guard try state(db) == nil else { throw StartError.used }
        let current = try estimate(db, extractor: x)
        guard current.groups == shown.groups, current.engines == shown.engines, current.limit == shown.limit,
              current.calls <= shown.calls else { throw StartError.changed }
        guard current.calls > 0 else { throw StartError.nothing }
        let read = try readSet(db)
        var marked = Set<String>()
        for m in try Row.fetchAll(db, sql: "SELECT id, version FROM memory WHERE status IN ('active','archived')") {
            let id: String = m["id"], version: Int = m["version"]
            for g in shown.groups where !read.contains(ReadKey(memoryID: id, version: version, group: g)) {
                try mark(db, memoryID: id, version: version, group: g, now: now)
                marked.insert(id)
            }
        }
        var s = State(startedAt: now, memories: marked.count, calls: current.calls, engines: current.engines, limit: current.limit)
        if marked.isEmpty {
            s.finishedAt = now
            s.ended = "done"
        }
        try write(db, s)
        return s
    }

    /// One marked job: queued now (a wait for the cap, a model or a retry is cleared), carrying the version its exempt
    /// read is for. A running job gets a new generation, so it runs again marked when it ends.
    static func mark(_ db: Database, memoryID: String, version: Int, group: String, now: Date) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT id, state FROM processing_job WHERE subject = ? AND kind = 'facts' AND call_group = ?",
                                      arguments: [memoryID, group]) {
            let id: String = row["id"]
            if (row["state"] as String) == "running" {
                try db.execute(sql: """
                    UPDATE processing_job SET exempt_version = ?, generation = generation + 1, memory_version = MAX(COALESCE(memory_version, ?1), ?1),
                      updated_at = ? WHERE id = ?
                    """, arguments: [version, now, id])
            } else {
                try db.execute(sql: """
                    UPDATE processing_job SET state = 'queued', attempts = 0, error = NULL, not_before = NULL, engine = NULL,
                      generation = generation + 1, memory_version = ?, exempt_version = ?, updated_at = ? WHERE id = ?
                    """, arguments: [version, version, now, id])
            }
        } else {
            try db.execute(sql: """
                INSERT INTO processing_job (id, subject, kind, state, attempts, created_at, updated_at, memory_version, call_group, exempt_version)
                VALUES (?, ?, 'facts', 'queued', 0, ?, ?, ?, ?, ?)
                """, arguments: [UUID().db, memoryID, now, now, version, group, version])
        }
    }

    /// Pauses or resumes (the user's Pause / Resume). Resuming a backfill paused by a change goes through `review`.
    static func setPaused(_ db: Database, _ paused: Bool) throws -> State? {
        guard var s = try state(db), s.isRunning else { return nil }
        s.paused = paused
        try write(db, s)
        return s
    }

    /// The user reviewed the estimate made after a change, and carries on: the backfill continues bound to it.
    static func review(_ db: Database, extractor x: FactsExtractor, shown: Estimate, now: Date = Date()) throws -> (state: State?, finished: [String: Int]?) {
        guard var s = try state(db), s.isRunning else { return (nil, nil) }
        let current = try estimate(db, extractor: x, owed: true)
        guard current.engines == shown.engines, current.limit == shown.limit, current.calls <= shown.calls else {
            throw StartError.changed
        }
        s.engines = current.engines
        s.limit = current.limit
        s.changed = false
        s.paused = false
        try write(db, s)
        // A group no model reads now can't be read exempt: its marks go (catch-up reads it later, under the cap), so
        // they can't pause the backfill again.
        let groups = current.groups
        try db.execute(sql: """
            UPDATE processing_job SET exempt_version = NULL WHERE kind = 'facts' AND exempt_version IS NOT NULL
              AND call_group NOT IN (\(databaseQuestionMarks(count: max(1, groups.count))))
            """, arguments: StatementArguments(groups.isEmpty ? [""] : groups))
        // Those may have been the last marks: it ends here, told once.
        if let done = try settle(db, now: now) { return (done, try finishedCounts(db, done)) }
        return (s, nil)
    }

    /// A marked job found Facts' engine or limit changed since the estimate: the backfill pauses until reviewed.
    static func pauseForChange(_ db: Database) throws {
        guard var s = try state(db), s.isRunning, !s.changed else { return }
        s.changed = true
        try write(db, s)
    }

    /// Ends the backfill when no mark is left, in the caller's transaction. Returns the finished state the first time.
    static func settle(_ db: Database, now: Date) throws -> State? {
        guard var s = try state(db), s.isRunning, try remaining(db) == 0 else { return nil }
        s.finishedAt = now
        s.ended = "done"
        s.paused = false
        s.changed = false
        try write(db, s)
        return s
    }

    /// Remove learned facts: every facts job goes, so an unfinished backfill ends as `removed`. The state stays.
    static func endForRemoval(_ db: Database, now: Date) throws {
        guard var s = try state(db), s.isRunning else { return }
        s.finishedAt = now
        s.ended = "removed"
        s.paused = false
        s.changed = false
        try write(db, s)
    }

    /// The finished backfill's Activity counts: memories and the calls its runs made (ids and counts only).
    static func finishedCounts(_ db: Database, _ s: State) throws -> [String: Int] {
        var calls = 0, codeOnly = 0, failed = 0
        for text in try String.fetchAll(db, sql: "SELECT counts FROM facts_run WHERE kind = 'backfill' AND started_at >= ?",
                                        arguments: [s.startedAt]) {
            let c = JSON.decode([String: Int].self, text) ?? [:]
            calls += c["exempt"] ?? 0
            codeOnly += c["code_only"] ?? 0
            failed += c["failed"] ?? 0
        }
        return ["memories": s.memories, "calls": calls, "code_only": codeOnly, "failed": failed]
    }

    static func activity(_ event: String, time: Date, counts: [String: Int]) -> ActivityEvent {
        ActivityEvent(time: time, phase: .event, actor: event == "started" ? .user : .system, via: .app, event: "facts_backfill",
                      outcome: event, counts: counts)
    }

    // MARK: Catch-up and re-reads (§11.3's registry rule, §11.10's coverage)

    /// Queues, as low-priority work (held to its share of the cap, §11.3), what the model should read and hasn't, in one
    /// write transaction (only while learning is on): for each active or archived memory and each group a model may read now,
    /// - a reading made under another extraction key, or before a predicate recorded now was (stale), read again in full;
    /// - no model reading at the current version, within the roster limit, with no job pending or failed for that
    ///   version, and in scope: the first backfill has started (every memory is then the lane's), or the memory had a
    ///   facts job in that group (it was code-only: above the limit then, no model, an unqualified group).
    /// Covers a raised cloud limit, a model back, grown coverage, a registry extraction change (batched per release: the
    /// launch after an update queues them all), and turning learning on again. Returns how many it queued.
    static func catchUp(_ db: Database, extractor x: FactsExtractor, now: Date) throws -> Int {
        guard FactsLane.learning(db) else { return 0 }
        let uses = try x.currentUses(db)
        let groups = x.groups.filter { x.modelAllowed($0, uses) }
        guard !groups.isEmpty else { return 0 }
        let keys = Dictionary(uniqueKeysWithValues: groups.map { ($0, x.readKey($0, uses)) })
        let limit = x.rosterLimit, everything = try state(db) != nil
        var reads: [ReadKey: String] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT memory_id, memory_version, call_group, knowledge FROM facts_asked WHERE mention_kind = 'read'") {
            reads[ReadKey(memoryID: r["memory_id"], version: r["memory_version"], group: r["call_group"])] = r["knowledge"]
        }
        var jobs: [String: (state: String, version: Int?, engine: String?)] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT subject, call_group, state, memory_version, engine FROM processing_job WHERE kind = 'facts' AND call_group IS NOT NULL
            """) {
            jobs[(r["subject"] as String) + "\u{1F}" + (r["call_group"] as String)] = (r["state"], r["memory_version"], r["engine"])
        }
        var queued = 0
        for m in try Row.fetchAll(db, sql: "SELECT id, version, sensitivity FROM memory WHERE status IN ('active','archived')") {
            let id: String = m["id"], version: Int = m["version"]
            let sendable = limit.map { $0.allows(Sensitivity(rawValue: m["sensitivity"]) ?? .secret) } ?? true
            for g in groups {
                let job = jobs[id + "\u{1F}" + g]
                if let job, ["queued", "running"].contains(job.state) { continue }
                // A read that failed, or that the guardrails refused, for this version isn't tried again until the memory
                // changes.
                if let job, job.state == "failed" || job.engine == FactsQueueWorker.refusedEngine, (job.version ?? 0) >= version { continue }
                guard sendable else { continue }
                if let stored = reads[ReadKey(memoryID: id, version: version, group: g)] {
                    guard FactsExtractor.isStale(stored, current: keys[g] ?? "") else { continue }
                } else {
                    guard everything || job != nil else { continue }
                }
                guard let uuid = UUID(uuidString: id) else { continue }
                try ProcessingQueue.enqueueFacts(db, memoryID: uuid, version: version, group: g, reason: .reconcile, now: now)
                queued += 1
            }
        }
        return queued
    }
}

/// Measured API-equivalent cost of one Facts call (ADR-0032 "The cap"), from `Resources/facts-cost.json`: only measured
/// models have one; the sheet says no figure otherwise.
public enum FactsCost {
    private struct File: Decodable {
        let perCall: [String: [String: Double]]
        enum CodingKeys: String, CodingKey { case perCall = "per_call" }
    }

    static let measured: [String: [String: Double]] = {
        guard let url = Bundle.module.url(forResource: "facts-cost", withExtension: "json"), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        return file.perCall
    }()

    public static func perCall(model: String, group: String) -> Double? { measured[model]?[group] }
}

extension VaultStore {
    /// The first backfill's progress, nil before it started.
    public func factsBackfill() throws -> FactsBackfill.Progress? {
        try writer.read { db in try FactsBackfill.progress(db) }
    }

    /// Facts jobs waiting for the daily cap to reset, if any.
    public func factsWaitingForCap(now: Date) throws -> Bool {
        try !factsCapWaits(now: now).isEmpty
    }

    /// The codes Facts jobs wait with for the daily cap's next day (`ProcessingQueue.factsCapCodes`): the cap, the
    /// agents' share, the low-priority share. What each says may be out of date (the status reads today's counts too).
    public func factsCapWaits(now: Date) throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT error FROM processing_job WHERE kind = 'facts' AND state = 'queued' AND not_before > ?
                  AND error IN (\(databaseQuestionMarks(count: ProcessingQueue.factsCapCodes.count)))
                """, arguments: StatementArguments([now] + ProcessingQueue.factsCapCodes.sorted())))
        }
    }

    /// The sheet's estimate, from the open vault, for the extractor the runner would build now.
    /// `owed`: what a running backfill still owes (the review after a change of model or limit).
    public func factsBackfillEstimate(extractor: FactsExtractor, owed: Bool = false) async throws -> FactsBackfill.Estimate {
        try await writer.read { db in try FactsBackfill.estimate(db, extractor: extractor, owed: owed) }
    }

    /// Starts the first backfill after the user saw `shown` (Start Reading). Activity: `facts_backfill` `started`.
    @discardableResult
    public func startFactsBackfill(extractor: FactsExtractor, shown: FactsBackfill.Estimate, activity: any ActivityRecorder,
                                   now: Date = Date()) async throws -> FactsBackfill.State {
        let s = try await writer.write { db in try FactsBackfill.start(db, extractor: extractor, shown: shown, now: now) }
        factsLane.setBackfillPaused(false)
        activity.record(FactsBackfill.activity("started", time: now, counts: ["memories": s.memories, "calls": s.calls]))
        if s.finishedAt != nil {
            activity.record(FactsBackfill.activity("finished", time: now, counts: ["memories": 0, "calls": 0, "code_only": 0, "failed": 0]))
        }
        return s
    }

    /// Pause / Resume: a running backfill job sends nothing more once paused, retries included.
    public func setFactsBackfillPaused(_ paused: Bool) async throws {
        // The mirror follows the store on the safe side: a pause holds the claim once committed (then the permit); a
        // resume opens the permit before the claim can hand a marked job out.
        if !paused { factsLane.setBackfillPaused(try await writer.read { db in try FactsBackfill.state(db)?.changed ?? false }) }
        let s = try await writer.write { db in try FactsBackfill.setPaused(db, paused) }
        factsLane.setBackfillPaused(s?.isPaused ?? false)
    }

    /// A marked job found no model for its group (the runner's `no_model`): the backfill pauses for a review.
    public func pauseFactsBackfillForChange() async throws {
        let paused = try await writer.write { db -> Bool in
            guard let s = try FactsBackfill.state(db), s.isRunning else { return false }
            try FactsBackfill.pauseForChange(db)
            return true
        }
        if paused { factsLane.setBackfillPaused(true) }
    }

    /// Carries on after the user reviewed the estimate a change of model or limit called for.
    public func reviewFactsBackfill(extractor: FactsExtractor, shown: FactsBackfill.Estimate,
                                    activity: any ActivityRecorder) async throws {
        let paused = try await writer.read { db in try FactsBackfill.state(db)?.paused ?? false }
        if !paused { factsLane.setBackfillPaused(false) }
        let now = Date()
        let (s, finished) = try await writer.write { db in try FactsBackfill.review(db, extractor: extractor, shown: shown, now: now) }
        factsLane.setBackfillPaused(s?.isPaused ?? false)
        if let finished { activity.record(FactsBackfill.activity("finished", time: now, counts: finished)) }
    }

    /// At launch: a backfill with no mark left ends (a crash between the last job and its end can't leave it running).
    public func settleFactsBackfill(activity: any ActivityRecorder, now: Date = Date()) async throws {
        let finished = try await writer.write { db -> (FactsBackfill.State, [String: Int])? in
            guard let s = try FactsBackfill.settle(db, now: now) else { return nil }
            return (s, try FactsBackfill.finishedCounts(db, s))
        }
        if let (_, counts) = finished { activity.record(FactsBackfill.activity("finished", time: now, counts: counts)) }
        factsLane.setBackfillPaused(try await writer.read { db in try FactsBackfill.state(db)?.isPaused ?? false })
    }
}
