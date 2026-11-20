import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Low-priority Facts work's share of the daily cap (memory processing §11.3 "Cost and the cap"): catch-up, re-reads and
/// reconciliation use at most 30% of a day's cloud requests and then wait for the next day, while captures and new and
/// changed memories' first reads still go to the cloud under the whole cap. The agents' share and the first backfill's
/// exemption are unchanged. Synthetic providers and `.unchecked` qualification only.
@Suite(.serialized) struct FactsCapShareTests {
    let v: TestVault
    let activity = InMemoryActivityLog()
    let queue: ProcessingQueue
    let groups = FactsRegistry.bundled.callGroups.keys.sorted()
    let utc = TimeZone(identifier: "UTC")!
    var lane: FactsLane { v.store.factsLane }

    init() throws {
        v = try TestVault()
        queue = ProcessingQueue(store: v.store, activity: activity, launchedAt: .distantPast)
    }

    typealias Model = FactsBackfillTests.Model

    final class Clock: @unchecked Sendable {
        private let t: Mutex<Date>
        init(_ start: Date) { t = Mutex(start) }
        func now() -> Date { t.withLock { $0 = $0.addingTimeInterval(1); return $0 } }
    }

    func cap(_ limit: Int) -> CloudRequestCap { CloudRequestCap(store: v.store, limit: limit, activity: activity, timeZone: utc) }

    func extractor(_ model: Model, cap: CloudRequestCap?, start: Date = t0) -> FactsExtractor {
        let clock = Clock(start)
        var x = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.internal), cap: cap,
                                                                   factsModel: model),
                               activity: activity, qualification: .unchecked)
        x.clock = { clock.now() }
        return x
    }

    @discardableResult
    func drain(_ x: FactsExtractor, now: Date = t0) async throws -> Int {
        try await queue.drain(now: { now }) { job in try await FactsQueueWorker(extractor: x).process(job) }
    }

    func memories(_ n: Int) throws -> [Memory] {
        try (0..<n).map { try v.memory("Note \($0)", "Plain note number \($0).") }
    }

    /// As once the first backfill was used and nothing is read now (a backup restored from before its reads): every
    /// memory is the lane's, none read.
    func usedBackfillNothingRead() async throws {
        try await v.store.writer.write { db in
            var s = FactsBackfill.State(startedAt: t0.plus(days: -30), memories: 0, calls: 0, engines: [:], limit: .upTo(.internal))
            s.finishedAt = t0.plus(days: -30)
            s.ended = "done"
            try FactsBackfill.write(db, s)
        }
        lane.setLearning(true)
    }

    func waiting(_ code: String) throws -> Int {
        try v.count("SELECT COUNT(*) FROM processing_job WHERE kind = 'facts' AND state = 'queued' AND error = ?", [code])
    }

    func normalVersion(_ m: Memory, _ group: String) throws -> Int? {
        try v.store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT normal_version FROM processing_job WHERE subject = ? AND kind = 'facts' AND call_group = ?",
                             arguments: [m.id.db, group])
        }
    }

    // MARK: The cap's arithmetic

    @Test func theShareIsThirtyPercentCountedWithTheCapAndNeverTheDaysNotice() async throws {
        let cap = cap(10)
        #expect(cap.lowPriorityLimit == 3 && cap.agentLimit == 4)
        #expect(CloudRequestCap.lowPriorityLimit(for: 300) == 90 && CloudRequestCap.agentLimit(for: 300) == 120)
        for _ in 0..<3 { try await cap.consume(.user, priority: .low, now: t0) }
        await #expect(throws: ProviderError.capReached) { try await cap.consume(.user, priority: .low, now: t0) }
        // The share's refusal isn't the day's notice: captures still go to the cloud.
        var day = try await cap.today(now: t0)
        #expect(day == CloudRequestCap.Day(day: cap.key(t0), total: 3, agents: 0, lowPriority: 3, reached: false))
        #expect(activity.events.filter { $0.event == "cap_reached" }.isEmpty)
        for _ in 0..<7 { try await cap.consume(.user, now: t0) }
        await #expect(throws: ProviderError.capReached) { try await cap.consume(.user, now: t0) }
        day = try await cap.today(now: t0)
        #expect(day.total == 10 && day.lowPriority == 3 && day.reached)
        #expect(activity.events.filter { $0.event == "cap_reached" }.count == 1)
        // The next day starts again.
        try await cap.consume(.user, priority: .low, now: t0.plus(days: 1))
        #expect(try await cap.today(now: t0.plus(days: 1)).lowPriority == 1)
    }

    @Test func anAgentsLowPriorityCallNeedsRoomInBothSharesAndTheAgentsShareIsUnchanged() async throws {
        let cap = cap(10)                                               // agents 4, low priority 3
        for _ in 0..<3 { try await cap.consume(.agent, priority: .low, now: t0) }
        // The low-priority share refuses an agent's low-priority call; the agents' share still has room for its normal one.
        await #expect(throws: ProviderError.capReached) { try await cap.consume(.agent, priority: .low, now: t0) }
        try await cap.consume(.agent, now: t0)
        #expect(activity.events.filter { $0.event == "cap_reached" }.isEmpty)
        // The agents' share full: refused as before, with the day's notice.
        await #expect(throws: ProviderError.capReached) { try await cap.consume(.agent, now: t0) }
        #expect(cap.refusal(try await cap.today(now: t0), .agent, .low) == .agents)
        #expect(activity.events.filter { $0.event == "cap_reached" && $0.outcome == "agent" }.count == 1)
        #expect(try await cap.today(now: t0) == CloudRequestCap.Day(day: cap.key(t0), total: 4, agents: 4, lowPriority: 3, reached: true))
        // The user's normal requests go on to the cap.
        for _ in 0..<6 { try await cap.consume(.user, now: t0) }
        #expect(cap.refusal(try await cap.today(now: t0), .user, .normal) == .total)
    }

    @Test func concurrentRequestsNeverPassTheShare() async throws {
        let cap = cap(100)                                              // low priority 30
        let counted = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<60 {
                group.addTask {
                    if (try? await cap.consume(.user, priority: .low, now: t0)) != nil { counted.withLock { $0 += 1 } }
                }
            }
        }
        #expect(counted.withLock { $0 } == 30)
        #expect(try await cap.today(now: t0).lowPriority == 30 && cap.lowPriorityLimit == 30)
    }

    @Test func aDayStoredBeforeTheShareKeepsItsCounts() async throws {
        let cap = cap(10)
        try await v.store.writer.write { db in
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [CloudRequestCap.metaKey, #"{"day":"\#(cap.key(t0))","total":5,"agents":2,"reached":false}"#])
        }
        #expect(try await cap.today(now: t0) == CloudRequestCap.Day(day: cap.key(t0), total: 5, agents: 2))
    }

    // MARK: A catch-up and the day's other work

    @Test func aCatchUpOf730CallsStaysWithinTheShareWhileCapturesAndNewMemoriesStillGoToTheCloud() async throws {
        let cap = cap(300)                                              // low priority 90
        let model = Model()
        let x = extractor(model, cap: cap)
        _ = try memories(365)
        try await usedBackfillNothingRead()
        #expect(try await FactsQueueWorker(extractor: x).scheduleCatchUp() == 365 * groups.count)
        #expect(365 * groups.count == 730)
        try await drain(x)
        #expect(model.calls.withLock { $0 } == 90)
        var day = try await cap.today(now: t0)
        #expect(day.total == 90 && day.lowPriority == 90 && !day.reached)
        #expect(activity.events.filter { $0.event == "cap_reached" }.isEmpty)
        #expect(try waiting("cap_share") == 640)
        #expect(try v.count("SELECT COUNT(*) FROM processing_job WHERE error = 'cap_share' AND not_before = ?", [cap.nextDay(after: t0)]) == 640)
        #expect(try v.store.factsCapWaits(now: t0) == ["cap_share"])
        #expect(FactsCapWait.current(codes: ["cap_share"], day: day, limit: 300) == [.lowPriority])

        // The same day, a capture is still classified by the cloud model…
        let stub = StubURLProtocol.Session { _ in .json(ModelRouterTests.proposal()) }
        let client = try OpenAICompatibleClient(endpoint: .openAI(), model: "m", apiKey: "k", session: stub.session)
        let router = ModelRouter(classifier: client, onDevice: ModelRouterTests.FakeOnDevice(), generationTimeout: .seconds(5), cap: cap)
        let record = await router.classify("likes jazz", categories: MemoryCategory.builtins, now: t0.plus(minutes: 1))
        #expect(record.engine != "apple.foundation" && stub.requests.count == 1)
        // …and a new memory is read, under the whole cap.
        let fresh = try v.memory("New", "A new note written today.", now: t0.plus(minutes: 2))
        try await drain(x)
        #expect(model.calls.withLock { $0 } == 90 + groups.count)
        day = try await cap.today(now: t0)
        #expect(day.total == 91 + groups.count && day.lowPriority == 90)
        #expect(try v.count("SELECT COUNT(*) FROM processing_job WHERE subject = ? AND state = 'done'", [fresh.id.db]) == groups.count)
        #expect(try waiting("cap_share") == 640)

        // The next day: 90 more, and the jobs still waiting skip their pass once the share is used up again.
        let runs = try v.count("SELECT COUNT(*) FROM facts_run")
        let tomorrow = cap.nextDay(after: t0).addingTimeInterval(3_600)
        try await drain(extractor(model, cap: cap, start: tomorrow), now: tomorrow)
        #expect(model.calls.withLock { $0 } == 180 + groups.count)
        #expect(try await cap.today(now: tomorrow).lowPriority == 90)
        #expect(try v.count("SELECT COUNT(*) FROM facts_run") == runs + 90)
        #expect(try waiting("cap_share") == 550)
    }

    @Test func aRaisedCapWakesJobsWaitingOnTheShare() async throws {
        let model = Model()
        _ = try memories(10)
        try await usedBackfillNothingRead()
        let small = cap(20)                                             // low priority 6
        let x = extractor(model, cap: small)
        try await FactsQueueWorker(extractor: x).scheduleCatchUp()
        try await drain(x)
        #expect(try model.calls.withLock { $0 } == 6 && waiting("cap_share") == 20 - 6)
        // The user raises the cap: the waiting jobs are due now, and the larger share reads them (12 of 40).
        #expect(try await queue.wakeFactsWaitingForCap(now: t0) == 14)
        try await drain(extractor(model, cap: cap(40)))
        #expect(try model.calls.withLock { $0 } == 12 && waiting("cap_share") == 8)
        #expect(try await cap(40).today(now: t0).lowPriority == 12)
    }

    // MARK: What counts as low-priority

    @Test func catchUpRereadsAndReconciliationAreLowANewOrChangedTextIsNot() async throws {
        let m = try v.memory("Older", "An older note.")
        try await usedBackfillNothingRead()
        let x = extractor(Model(), cap: cap(100))
        try await FactsQueueWorker(extractor: x).scheduleCatchUp()
        let g = groups[0]
        let job = try #require(try await v.store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM processing_job WHERE subject = ? AND call_group = ?", arguments: [m.id.db, g])
                .map(ProcessingJob.from(row:))
        })
        let priority = FactsQueueWorker.priority(job, group: g, store: v.store)
        #expect(try job.normalVersion == nil && priority(1) == .low)          // catch-up
        // An edit while it waits: the job is now a first read of new text, decided at the request (the store is read then).
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(body: "Edited today."), now: t0.plus(minutes: 1))
        #expect(try normalVersion(m, g) == 2)
        #expect(try priority(2) == .normal)
        #expect(try priority(1) == .low)                                          // the version it no longer reads
        // Once a model reading of that version exists, reading it again is a re-read, or reconciliation.
        try await v.store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO facts_asked (memory_id, memory_version, call_group, mention_kind, mention_key, knowledge, asked_at)
                VALUES (?, 2, ?, 'read', '', 'stale', ?)
                """, arguments: [m.id.db, g, t0])
        }
        #expect(try priority(2) == .low)
    }

    @Test func anEditDuringALowPriorityRequestMakesTheNextAttemptAFirstReadCountedAsNormal() async throws {
        let cap = cap(10)                                               // low priority 3
        let model = Model()
        let m = try v.memory("Older", "Never read.")
        try await usedBackfillNothingRead()
        let x = extractor(model, cap: cap)
        try await FactsQueueWorker(extractor: x).scheduleCatchUp()
        // While the catch-up job's first request is with the model, the user edits the memory: that answer can't apply,
        // and the next attempt reads the new text, a first read.
        let edited = Mutex(false)
        let store = v.store
        model.onRequest.withLock {
            $0 = {
                guard !edited.withLock({ let was = $0; $0 = true; return was }) else { return }
                _ = try? store.updateMemory(id: m.id, MemoryEdit(body: "Edited while it was read."), now: t0.plus(minutes: 1))
            }
        }
        try await drain(x)
        let day = try await cap.today(now: t0)
        #expect(model.calls.withLock { $0 } == 1 + groups.count)
        #expect(day.lowPriority == 1 && day.total == 1 + groups.count)
        #expect(try v.count("SELECT COUNT(*) FROM facts_asked WHERE memory_id = ? AND memory_version = 2 AND mention_kind = 'read'", [m.id.db]) == groups.count)
    }

    @Test func anArchiveOrCategoryChangeKeepsWhatAJobAlreadyWas() async throws {
        let older = try v.memory("Older", "Never read.")
        try await usedBackfillNothingRead()
        let x = extractor(Model(), cap: cap(100))
        try await FactsQueueWorker(extractor: x).scheduleCatchUp()
        // A never-read memory archived during a catch-up stays low-priority…
        _ = try v.store.archiveMemory(id: older.id, now: t0.plus(minutes: 1))
        #expect(try groups.allSatisfy { try normalVersion(older, $0) == nil })
        // …and a new memory whose categories change before its read stays a normal first read, at the new version.
        let fresh = try v.memory("New", "Written today.", now: t0.plus(minutes: 2))
        _ = try v.store.updateMemory(id: fresh.id, MemoryEdit(categoryKeys: ["communication_style"]), now: t0.plus(minutes: 3))
        #expect(try groups.allSatisfy { try normalVersion(fresh, $0) == 2 })
    }

    @Test func anEditUnparksAJobWaitingOnTheShareAndTheReadCountsAsNormal() async throws {
        let model = Model()
        let m = try v.memory("Older", "Never read.")
        try await usedBackfillNothingRead()
        let none = cap(3)                                               // low priority 0: every low call is refused
        let x = extractor(model, cap: none)
        try await FactsQueueWorker(extractor: x).scheduleCatchUp()
        try await drain(x)
        #expect(try model.calls.withLock { $0 } == 0 && waiting("cap_share") == groups.count)
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(body: "Edited, so read today."), now: t0.plus(minutes: 1))
        #expect(try waiting("cap_share") == 0)
        try await drain(x)
        #expect(model.calls.withLock { $0 } == groups.count)
        let day = try await none.today(now: t0)
        #expect(day.total == groups.count && day.lowPriority == 0)
    }

    @Test func newAndChangedMemoriesAreClaimedFirstThenTheBackfillThenLowPriorityWork() async throws {
        let older = try v.memory("Older", "Caught up.")
        try await usedBackfillNothingRead()
        try await FactsQueueWorker(extractor: extractor(Model(), cap: nil)).scheduleCatchUp()
        let marked = try v.memory("Marked", "A backfill read.", now: t0.plus(minutes: 1))
        try await v.store.writer.write { db in
            try db.execute(sql: "UPDATE processing_job SET normal_version = NULL, exempt_version = 1 WHERE subject = ?", arguments: [marked.id.db])
        }
        let fresh = try v.memory("New", "Written today.", now: t0.plus(minutes: 2))
        var order: [UUID] = []
        while let job = try await queue.claim(now: t0.plus(minutes: 5)) {
            order.append(job.subject)
            try await queue.finish(job, .done(engine: nil), now: t0.plus(minutes: 5))
        }
        let expected = [fresh.id, marked.id, older.id].flatMap { Array(repeating: $0, count: groups.count) }
        #expect(order.filter { $0 != ProcessingQueue.factsSweepSubject } == expected)
        // Reconciliation asking a finished first read again: low-priority, claimed after a new memory's first read.
        try await v.store.writer.write { db in
            for g in groups { try ProcessingQueue.enqueueFacts(db, memoryID: fresh.id, version: 1, group: g, reason: .reconcile, now: t0.plus(minutes: 6)) }
        }
        let newer = try v.memory("Newer", "Written later.", now: t0.plus(minutes: 7))
        #expect(try groups.allSatisfy { try normalVersion(fresh, $0) == nil })
        #expect(try await queue.claim(now: t0.plus(minutes: 8))?.subject == newer.id)
    }

    @Test func aFirstReadThatNeverHappenedStaysNormalAfterASensitivityChange() async throws {
        let model = Model()
        lane.setLearning(true)
        let none = cap(3)                                               // low priority 0
        let x = extractor(model, cap: none)
        // Above the cloud limit: code-only, no model read.
        let m = try v.memory("Private", "Above the limit.", sensitivity: .sensitive)
        try await drain(x)
        #expect(model.calls.withLock { $0 } == 0)
        // Lowered: its first read is still a first read, under the whole cap.
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(sensitivity: .low), now: t0.plus(minutes: 1))
        #expect(try groups.allSatisfy { try normalVersion(m, $0) == 2 })
        try await drain(x)
        #expect(model.calls.withLock { $0 } == groups.count)
        #expect(try await none.today(now: t0).lowPriority == 0)
    }

    // MARK: Which limit a job waits on

    @Test func waitCodesNameTheLimitLowPriorityBeforeTheAgentsShare() async throws {
        let cap = cap(10)                                               // agents 4, low priority 3
        let model = Model()
        let x = extractor(model, cap: cap)
        let agent = try v.memory("From an agent", "An agent wrote this.")
        try await v.store.writer.write { db in
            try db.execute(sql: "UPDATE memory SET source = 'agent_write', trust = 'untrusted' WHERE id = ?", arguments: [agent.id.db])
        }
        try await usedBackfillNothingRead()
        for _ in 0..<4 { try await cap.consume(.agent, now: t0) }       // the agents' share used up
        // The agent's memory caught up with both shares used: the low-priority share is named.
        for _ in 0..<3 { try await cap.consume(.user, priority: .low, now: t0) }
        try await FactsQueueWorker(extractor: x).scheduleCatchUp()
        try await drain(x)
        #expect(try waiting("cap_share") == groups.count)
        // An agent's new memory (a first read) waits on the agents' share.
        let fresh = try v.memory("Also from an agent", "Written today.", now: t0.plus(minutes: 1))
        try await v.store.writer.write { db in
            try db.execute(sql: "UPDATE memory SET source = 'agent_write', trust = 'untrusted' WHERE id = ?", arguments: [fresh.id.db])
        }
        try await drain(x)
        #expect(try waiting("cap_agents") == groups.count && model.calls.withLock { $0 } == 0)
        let codes = try v.store.factsCapWaits(now: t0)
        #expect(codes == ["cap_share", "cap_agents"])
        #expect(FactsCapWait.current(codes: codes, day: try await cap.today(now: t0), limit: 10) == [.lowPriority, .agents])
    }

    @Test func theCapUsedUpAfterJobsParkOnTheShareWinsTheStatusAndTheyWaitWithoutAPass() async throws {
        let cap = cap(10)                                               // low priority 3
        let model = Model()
        let x = extractor(model, cap: cap)
        _ = try memories(5)
        try await usedBackfillNothingRead()
        try await FactsQueueWorker(extractor: x).scheduleCatchUp()
        try await drain(x)
        #expect(try model.calls.withLock { $0 } == 3 && waiting("cap_share") == 5 * groups.count - 3)
        // Captures use the rest of the day; the status now says the cap, though the jobs wait on the share.
        for _ in 0..<7 { try await cap.consume(.user, now: t0) }
        #expect(FactsCapWait.current(codes: try v.store.factsCapWaits(now: t0), day: try await cap.today(now: t0), limit: 10) == [.total])
        // Woken (a cap change), they wait again without another pass.
        let runs = try v.count("SELECT COUNT(*) FROM facts_run")
        try await queue.wakeFactsWaitingForCap(now: t0)
        try await drain(x)
        #expect(try v.count("SELECT COUNT(*) FROM facts_run") == runs)
        #expect(try waiting("cap_share") == 5 * groups.count - 3 && model.calls.withLock { $0 } == 3)
    }

    @Test func v13KeepsEarlierFactsJobsAsLowPriority() throws {
        let db = try DatabaseQueue()
        try Schema.migrator.migrate(db, upTo: "v12_facts_backfill")
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO processing_job (id, subject, kind, state, attempts, created_at, updated_at, memory_version, call_group)
                VALUES (?, ?, 'facts', 'queued', 0, ?, ?, 1, 'people')
                """, arguments: [UUID().db, UUID().db, t0, t0])
        }
        try Schema.migrator.migrate(db)
        let row = try db.read { db in try Row.fetchOne(db, sql: "SELECT * FROM processing_job") }
        let job = try ProcessingJob.from(row: try #require(row))
        #expect(job.normalVersion == nil && job.memoryVersion == 1)
    }

    // MARK: The first backfill

    @Test func theExemptBackfillIsUntouchedAndItsOwnRetryIsNormal() async throws {
        let cap = cap(10)                                               // low priority 3
        let model = Model()
        let x = extractor(model, cap: cap)
        _ = try memories(4)
        lane.setLearning(true)
        let e = try await v.store.factsBackfillEstimate(extractor: x)
        try await v.store.startFactsBackfill(extractor: x, shown: e, activity: activity, now: t0)
        // The low-priority share used up beforehand.
        for _ in 0..<3 { try await cap.consume(.user, priority: .low, now: t0) }
        // A read whose exempt answer isn't the schema's: its retry counts as the read it is, not as low-priority work.
        model.failure.withLock { $0 = .invalidOutput }
        let job = try #require(try await queue.claim(now: t0))
        try await queue.finish(job, try await FactsQueueWorker(extractor: x).process(job), now: t0)
        #expect(model.calls.withLock { $0 } == 2)
        var day = try await cap.today(now: t0)
        #expect(day.total == 4 && day.lowPriority == 3)
        // Every other marked read is exempt: nothing counted, the share full or not.
        model.failure.withLock { $0 = nil }
        try await drain(x)
        day = try await cap.today(now: t0)
        #expect(model.calls.withLock { $0 } == 2 + 4 * groups.count - 1)
        #expect(day.total == 4 && day.lowPriority == 3)
    }

    // MARK: The status

    @Test func theStatusFollowsTodaysCountsNotJustTheWaitCodes() {
        let full = CloudRequestCap.Day(day: "d", total: 300, agents: 120, lowPriority: 90)
        let shares = CloudRequestCap.Day(day: "d", total: 210, agents: 120, lowPriority: 90)
        let room = CloudRequestCap.Day(day: "d", total: 100, agents: 10, lowPriority: 10)
        #expect(FactsCapWait.current(codes: [], day: full, limit: 300).isEmpty)
        // The cap used up since the share's refusal wins.
        #expect(FactsCapWait.current(codes: ["cap_share"], day: full, limit: 300) == [.total])
        #expect(FactsCapWait.current(codes: ["cap_share", "cap_agents"], day: shares, limit: 300) == [.lowPriority, .agents])
        #expect(FactsCapWait.current(codes: ["cap_share"], day: shares, limit: 300) == [.lowPriority])
        // A share with room again (a raised cap) says nothing; unreadable counts read as the cap.
        #expect(FactsCapWait.current(codes: ["cap_share", "cap_agents"], day: room, limit: 300).isEmpty)
        #expect(FactsCapWait.current(codes: ["cap_share"], day: shares, limit: 400).isEmpty)
        #expect(FactsCapWait.current(codes: ["cap_share"], day: nil, limit: 300) == [.total])
    }
}
