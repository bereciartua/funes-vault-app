import Foundation
import GRDB

/// Runs the facts lane's jobs (memory processing §11.3). A memory's job reads it in its call group: in full when the
/// model hasn't read that version in that group yet, otherwise only what reconciliation finds due now (a partial
/// re-read), or nothing, with no call. The sweep revalidates in code what it can and queues the memories with something
/// due. Every applied change queues the sweep again (`FactStore.bumpRevision`), in the same transaction.
///
/// Memory commits queue the jobs while *Learn from memories* is on (`ProcessingQueue.enqueueFactsForCommit`), and the
/// Mac's processing runner runs them here, with a configuration built for each job.
///
/// The first backfill's jobs are marked (`FactsBackfill`): while it runs, a marked job's full read of the version it
/// was marked for skips the daily cap; it stops before any request once the backfill is paused, and pauses it when the
/// engine or the cloud limit isn't the one its estimate showed. Every other call counts against the cap; at the cap a
/// job waits for the cap's next day.
///
/// Only a first read of the version a new or changed text asked for (`ProcessingJob.normalVersion`) is normal work.
/// Catch-up, re-reads and reconciliation are low-priority: held to `CloudRequestCap.lowPriorityShare`, at which they wait
/// for the next day (`cap_share`) while new and changed memories are still read under the whole cap.
public struct FactsQueueWorker: Sendable {
    public let extractor: FactsExtractor
    public var clock: @Sendable () -> Date

    public init(extractor: FactsExtractor) {
        self.extractor = extractor
        self.clock = extractor.clock
    }

    /// What a memory's job will do.
    enum Plan: Equatable {
        case gone
        case full
        case partial(FactsReconciler.Due)
        case nothing
    }

    func plan(_ memoryID: String, group: String) async throws -> Plan {
        try await planned(memoryID, group: group).plan
    }

    /// The plan, and the version a full read would read. A reading made under another extraction key, or before a
    /// predicate recorded now was, is read again in full (a re-read, under the cap).
    func planned(_ memoryID: String, group: String) async throws -> (plan: Plan, version: Int?, reread: Bool) {
        let registry = extractor.registry, users = extractor.userAliases, limit = extractor.rosterLimit
        return try await extractor.store.writer.write { [extractor] db in
            guard let m = try Row.fetchOne(db, sql: "SELECT version, status FROM memory WHERE id = ?", arguments: [memoryID]),
                  ["active", "archived"].contains(m["status"] as String) else { return (.gone, nil, false) }
            let version: Int = m["version"]
            guard let stored = try String.fetchOne(db, sql: """
                SELECT knowledge FROM facts_asked WHERE memory_id = ? AND memory_version = ? AND call_group = ? AND mention_kind = 'read'
                """, arguments: [memoryID, version, group]) else { return (.full, version, false) }
            let uses = try extractor.currentUses(db)
            if extractor.modelAllowed(group, uses), FactsExtractor.isStale(stored, current: extractor.readKey(group, uses)) {
                return (.full, version, true)
            }
            let due = try FactsReconciler.reconcile(db, only: memoryID, registry: registry, userAliases: users,
                                                    uses: try extractor.currentUses(db), sendable: limit)
                .first { $0.key.group == group }?.due
            return (due.map { .partial($0) } ?? .nothing, version, false)
        }
    }

    /// A done job whose read the guardrails refused (`processing_job.engine`).
    static let refusedEngine = "code:refused"

    /// Why a marked job doesn't run now: the backfill is paused (by the user, or by a change since its estimate).
    static let backfillPaused = "backfill_paused"
    /// A marked job's provider failed (a rate limit, the network): it waits, without spending an attempt.
    static let providerWait: TimeInterval = 300

    /// For a marked job: whether the backfill lets it read exempt now, or why it waits. A backfill that isn't running
    /// (ended, or removed) leaves the job an ordinary one.
    func backfill(_ job: ProcessingJob, group: String) async throws -> (exempt: Int?, wait: Bool) {
        guard let version = job.exemptVersion else { return (nil, false) }
        let engine = extractor.router.factsModels[group].map(ModelRouter.engine), limit = extractor.rosterLimit
        let (exempt, wait, changed) = try await extractor.store.writer.write { [extractor] db -> (Int?, Bool, Bool) in
            guard let s = try FactsBackfill.state(db), s.isRunning else { return (nil, false, false) }
            if s.isPaused { return (nil, true, false) }
            // Another engine, a wider limit, or the group's model no longer allowed (a use turned off): not what the
            // user agreed to, so it waits for a review rather than reading, or giving up the read, without one.
            let allowed = extractor.modelAllowed(group, try extractor.currentUses(db))
            if engine != s.engines[group] || Self.widens(limit, s.limit) || !allowed {
                try FactsBackfill.pauseForChange(db)
                return (nil, true, true)
            }
            return (version, false, false)
        }
        if changed { extractor.store.factsLane.setBackfillPaused(true) }      // once the pause is committed
        return (exempt, wait)
    }

    /// Whether `now` lets a call send more than `then` did: a cloud limit above the one the estimate showed.
    static func widens(_ now: CloudLimit?, _ then: CloudLimit?) -> Bool {
        switch (now, then) {
        case (nil, _): false                                  // every model on this Mac: the engine check covers a switch
        case (_?, nil): true
        case let (.upTo(a)?, .upTo(b)?): a > b
        case (.upTo?, .never?): true
        case (.never?, _?): false
        }
    }

    /// How urgent each of a job's requests is (memory processing §11.3), asked with the version being read: a first
    /// read (no model reading of that version yet in the group) of the version a new or changed text asked this job for
    /// (read from the store then) is normal; reconciliation and re-reads (a reading exists) and anything catch-up queued
    /// are low-priority.
    static func priority(_ job: ProcessingJob, group: String, store: VaultStore) -> @Sendable (Int) throws -> CloudRequestCap.Priority {
        let id = job.id.db, memoryID = job.subject.db
        return { version in
            try store.writer.read { db in
                guard try Int.fetchOne(db, sql: "SELECT normal_version FROM processing_job WHERE id = ?", arguments: [id]) == version
                else { return .low }
                let read = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM facts_asked WHERE memory_id = ? AND memory_version = ? AND call_group = ? AND mention_kind = 'read')
                    """, arguments: [memoryID, version, group]) ?? false
                return read ? .low : .normal
            }
        }
    }

    /// Which limit a refused call waits on, for the status (`ProcessingQueue.factsCapCodes`): the cap, then the
    /// low-priority share for low-priority work, then the agents' share. Read with the refusing cap's own limit, so what
    /// refused it the same day is still used up; nil when nothing is (the day turned).
    static func capCode(_ cap: CloudRequestCap, lowPriority: Bool, now: Date) async throws -> String? {
        let day = try await cap.today(now: now)
        if day.total >= cap.limit { return "cap" }
        if lowPriority, day.lowPriority >= cap.lowPriorityLimit { return "cap_share" }
        if day.agents >= cap.agentLimit { return "cap_agents" }
        return nil
    }

    /// The facts lane's catch-up and re-reads (`FactsBackfill.catchUp`), under the cap. The runner calls it at launch and
    /// on every Facts settings change while learning is on. Returns how many jobs it queued.
    @discardableResult
    public func scheduleCatchUp() async throws -> Int {
        let now = clock()
        return try await extractor.store.writer.write { [extractor] db in try FactsBackfill.catchUp(db, extractor: extractor, now: now) }
    }

    /// Runs one `facts` job and says how it went. `report` hears each learn's report (the harness records its calls).
    public func process(_ job: ProcessingJob, report: @Sendable (FactsLearnReport, String) async -> Void = { _, _ in })
        async throws -> ProcessingQueue.Outcome {
        guard job.kind == .facts else { return .done(engine: nil) }
        guard let group = job.callGroup else {
            let registry = extractor.registry, users = extractor.userAliases, now = clock(), limit = extractor.rosterLimit
            try await extractor.store.writer.write { [extractor] db in
                try FactsReconciler.sweep(db, registry: registry, userAliases: users, uses: try extractor.currentUses(db),
                                          sendable: limit, now: now)
            }
            return .done(engine: nil)
        }
        let memoryID = job.subject.db
        let (exemptVersion, wait) = try await backfill(job, group: group)
        if wait { return .later(until: clock(), code: Self.backfillPaused) }
        let scope: FactsScope, kind: String
        let planned = try await planned(memoryID, group: group)
        switch planned.plan {
        case .gone, .nothing: return .done(engine: nil)
        case .full:
            let exempt = exemptVersion != nil && planned.version == exemptVersion && !planned.reread
            (scope, kind) = (.full, exempt ? FactsExtractor.backfillKind : planned.reread ? "reread" : "incremental")
        case let .partial(due): (scope, kind) = (.partial(roles: due.roles, names: due.names), "reconciliation")
        }
        var extractor = self.extractor
        extractor.priority = Self.priority(job, group: group, store: extractor.store)
        let exemptRead = exemptVersion != nil && planned.version == exemptVersion && !planned.reread
        if let last = job.lastError, ProcessingQueue.factsCapCodes.contains(last), !exemptRead, let cap = extractor.router.cap,
           let model = extractor.router.factsModels[group], !model.locality.isLocal {
            // Waited on the cap, its code-only links already written: while the cap or the low-priority share is still used
            // up, low-priority work waits again without another pass (each parked job would otherwise redo one every
            // day). Coded `cap_share` either way: the status reads today's counts, so a used-up cap still says so.
            let low = try planned.version.map { try extractor.priority($0) } == .low
            let now = clock()
            if low, cap.refusal(try await cap.today(now: now), .user, .low) != nil {
                return .later(until: cap.nextDay(after: now), code: "cap_share")
            }
        }
        if let exemptVersion, !planned.reread {
            // Pause stops a backfill job before its next request, retries included.
            let permit = extractor.permit, lane = extractor.store.factsLane
            extractor.exemptVersion = exemptVersion
            extractor.permit = { permit() && !lane.backfillPaused }
            // Spent once sent: the mark goes in the store before the provider answers (durable across a quit).
            let store = extractor.store, id = job.id.db
            extractor.exemptSpent = {
                try store.writer.write { db in
                    try db.execute(sql: "UPDATE processing_job SET exempt_version = NULL WHERE id = ?", arguments: [id])
                }
            }
        }
        let r = try await extractor.learn([memoryID], groups: [group], kind: kind, scope: scope)
        let engine: String? = switch r.calls.first?.outcome {
        case nil: nil
        case .codeOnly?: extractor.codeEngine
        default: extractor.router.factsModels[group].map(ModelRouter.engine) ?? extractor.codeEngine
        }
        await report(r, scope == .full ? "full" : "reconcile")
        if exemptVersion != nil, let c = r.calls.first {
            let waits = c.dropped.contains(FactsExtractor.capReached) || c.dropped.contains(FactsExtractor.transient)
            let ends = c.outcome == .applied || (c.outcome == .codeOnly && !waits)
            if c.exempt > 0, !ends {
                // Its exempt request was sent and the read didn't end (an invalid answer, a provider failure after
                // sending, a change under it): the exemption is spent, and the job carries on as an ordinary one.
                try await extractor.store.writer.write { db in
                    try db.execute(sql: "UPDATE processing_job SET exempt_version = NULL WHERE id = ?", arguments: [job.id.db])
                }
            } else if c.outcome == .failed, c.dropped.contains(FactsExtractor.providerFailed) {
                // Nothing was sent (a provider still backing off): the job waits, keeping its exemption (FR-F-03).
                return .later(until: clock().addingTimeInterval(Self.providerWait), code: "provider")
            }
        }
        if let c = r.calls.first, c.outcome == .codeOnly, c.dropped.contains(FactsExtractor.capReached) {
            // At the daily cap, or one of its shares: read when the cap resets (FR-F-03), not counted as an attempt.
            let now = clock()
            guard let cap = extractor.router.cap else { return .later(until: now.addingTimeInterval(3_600), code: "cap") }
            // Nothing used up: the day turned since the refusal, so it's due again now.
            guard let code = try await Self.capCode(cap, lowPriority: c.lowPriority, now: now) else { return .later(until: now, code: "cap") }
            return .later(until: cap.nextDay(after: now), code: code)
        }
        if let c = r.calls.first, c.outcome == .codeOnly, c.dropped.contains(FactsExtractor.transient) {
            // Read by the model later: an hour on, not counted as an attempt.
            return .later(until: clock().addingTimeInterval(3_600), code: "unavailable")
        }
        // Refused by the guardrails (a secret, an item above the limit): recorded, so the catch-up doesn't ask again
        // until the memory changes.
        if let c = r.calls.first, c.outcome == .codeOnly, c.refused { return .done(engine: Self.refusedEngine) }
        switch r.calls.first?.outcome {
        case nil, .applied?, .codeOnly?: return .done(engine: engine)
        case .changed?: return .later(until: clock(), code: "changed")       // read again at once (§11.3)
        case .failed?: return .retry(code: "failed")
        }
    }
}
