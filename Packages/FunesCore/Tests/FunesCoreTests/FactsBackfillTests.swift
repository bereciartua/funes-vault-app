import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Phase 13a.2's Backfill and cost step (FR-F-03, FR-AI-15, memory processing §11.3): the first backfill is one
/// exemption from the daily cap, started by the user after the estimate, resumable, bound to what the estimate showed;
/// every other Facts call counts, in the agents' share for an agent's memory; at the cap a job waits for the next day.
/// Synthetic providers and `.unchecked` qualification only: nothing here is a qualification record.
@Suite(.serialized) struct FactsBackfillTests {
    let v: TestVault
    let activity = InMemoryActivityLog()
    let queue: ProcessingQueue
    let groups = FactsRegistry.bundled.callGroups.keys.sorted()
    var lane: FactsLane { v.store.factsLane }

    init() throws {
        v = try TestVault()
        queue = ProcessingQueue(store: v.store, activity: activity, launchedAt: .distantPast)
    }

    /// A cloud model that answers nothing found, counting calls; it throws `failure` while one is set.
    final class Model: GenerationProvider, @unchecked Sendable {
        let id: ProviderID
        let locality: Locality
        let modelID: String
        let calls = Mutex(0)
        let failure = Mutex<ProviderError?>(nil)
        /// Runs as each request reaches the provider (before it answers).
        let onRequest = Mutex<(@Sendable () -> Void)?>(nil)
        let inner = FactsExtractorTests.Scripted { _ in [:] }

        init(model: String = "scripted", id: ProviderID = "anthropic", locality: Locality = .cloud) {
            modelID = model
            self.id = id
            self.locality = locality
        }

        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            calls.withLock { $0 += 1 }
            onRequest.withLock { $0 }?()
            if let e = failure.withLock({ $0 }) { throw e }
            return try await inner.generate(request)
        }
    }

    func extractor(_ model: Model, cap: CloudRequestCap? = nil, limit: CloudLimit = .upTo(.internal),
                   qualification: FactsQualification = .unchecked, backoff: ProviderBackoff = ProviderBackoff()) -> FactsExtractor {
        let clock = FactsHarness.Clock()
        var x = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: limit, cap: cap,
                                                                   backoff: backoff, factsModel: model),
                               activity: activity, qualification: qualification)
        x.clock = { clock.now() }
        return x
    }

    @discardableResult
    func drain(_ x: FactsExtractor) async throws -> Int {
        try await queue.drain(now: { t0 }) { job in try await FactsQueueWorker(extractor: x).process(job) }
    }

    func memories(_ n: Int, sensitivity: Sensitivity = .low) throws -> [Memory] {
        try (0..<n).map { try v.memory("Note \($0)", "Plain note number \($0).", sensitivity: sensitivity) }
    }

    /// The test's clock runs ahead of the drain's fixed `now`: a job told to wait "until now" is due again.
    func wake() async throws {
        try await v.store.writer.write { db in try db.execute(sql: "UPDATE processing_job SET not_before = NULL WHERE error != 'cap' OR error IS NULL") }
    }

    func state() throws -> FactsBackfill.State? { try v.store.writer.read { db in try FactsBackfill.state(db) } }
    func marked() throws -> Int { try v.count("SELECT COUNT(*) FROM processing_job WHERE exempt_version IS NOT NULL") }

    /// Learning on, the estimate, Start Reading.
    @discardableResult
    func start(_ x: FactsExtractor) async throws -> FactsBackfill.Estimate {
        lane.setLearning(true)
        let e = try await v.store.factsBackfillEstimate(extractor: x)
        try await v.store.startFactsBackfill(extractor: x, shown: e, activity: activity, now: t0)
        return e
    }

    // MARK: The estimate

    @Test func theEstimateCountsFirstReadsPerGroupWithAModelAndWhatStaysOnThisMac() async throws {
        let model = Model()
        let x = extractor(model)
        _ = try memories(3)
        _ = try v.memory("Above", "Something above the limit.", sensitivity: .sensitive)
        var e = try await v.store.factsBackfillEstimate(extractor: x)
        #expect(e.groups == groups)
        #expect(e.memories == 4 && e.kept == 1 && e.calls == 3 * groups.count)
        #expect(e.engines.count == groups.count && e.limit == .upTo(.internal))
        #expect(e.cost == nil)                                          // "scripted" has no measured cost
        // A memory read already in a group isn't counted there.
        let first = try #require(try await v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM memory WHERE title = 'Note 0'") })
        try await x.learn([first], groups: [groups[0]])
        e = try await v.store.factsBackfillEstimate(extractor: x)
        #expect(e.calls == 3 * groups.count - 1 && e.memories == 4)
        // No model allowed (no record for it): nothing to read.
        let none = try await v.store.factsBackfillEstimate(extractor: extractor(model, qualification: FactsQualification(records: [])))
        #expect(none.groups.isEmpty && none.calls == 0 && none.memories == 0)
        #expect(model.calls.withLock { $0 } == 1)
    }

    @Test func theCostComesFromTheMeasuredTableOnly() async throws {
        _ = try memories(365)
        let e = try await v.store.factsBackfillEstimate(extractor: extractor(Model(model: "claude-haiku-5-5")))
        // ADR-0032: about $0.13 + $0.09 for 365 memories on Haiku.
        #expect(e.calls == 730)
        #expect(abs((e.cost ?? 0) - 0.22) < 0.001)
        #expect(FactsCost.perCall(model: "claude-opus-5-5", group: groups[0]) == nil)
    }

    // MARK: Starting

    @Test func startNeedsLearningOnceAndTheEstimateShown() async throws {
        let x = extractor(Model())
        _ = try memories(2)
        let e = try await v.store.factsBackfillEstimate(extractor: x)
        await #expect(throws: FactsBackfill.StartError.notLearning) {
            try await v.store.startFactsBackfill(extractor: x, shown: e, activity: activity, now: t0)
        }
        lane.setLearning(true)
        // A memory added since the estimate (the user saw fewer calls): refused, the sheet shows the new count.
        lane.setLearning(false)
        _ = try v.memory("Later", "Added after the estimate.")
        lane.setLearning(true)
        await #expect(throws: FactsBackfill.StartError.changed) {
            try await v.store.startFactsBackfill(extractor: x, shown: e, activity: activity, now: t0)
        }
        let again = try await v.store.factsBackfillEstimate(extractor: x)
        let s = try await v.store.startFactsBackfill(extractor: x, shown: again, activity: activity, now: t0)
        #expect(s.memories == 3 && s.calls == 3 * groups.count && s.isRunning)
        await #expect(throws: FactsBackfill.StartError.used) {
            try await v.store.startFactsBackfill(extractor: x, shown: again, activity: activity, now: t0)
        }
        let started = activity.events.filter { $0.event == "facts_backfill" }
        #expect(started.count == 1 && started[0].outcome == "started" && started[0].counts == ["memories": 3, "calls": 3 * groups.count])
        let words = try #require(FactsActivityWords(started[0]))
        #expect(words.title == "Started reading existing memories" && words.detail == "3 memories · about \(3 * groups.count) model calls")
    }

    @Test func startWakesJobsWaitingForTheCapAModelOrARetry() async throws {
        lane.setLearning(true)
        _ = try memories(1)                                             // learning on: its jobs are queued
        try await v.store.writer.write { db in
            try db.execute(sql: "UPDATE processing_job SET not_before = ?, error = 'cap', attempts = 3", arguments: [t0.plus(days: 1)])
        }
        try await start(extractor(Model()))
        #expect(try v.count("SELECT COUNT(*) FROM processing_job WHERE not_before IS NULL AND error IS NULL AND attempts = 0 AND exempt_version = 1") == groups.count)
    }

    // MARK: The exemption

    @Test func backfillReadsSkipTheCapOnceAndEveryOtherCallCounts() async throws {
        let cap = CloudRequestCap(store: v.store, limit: 0)            // every counted request is refused
        let model = Model()
        let x = extractor(model, cap: cap)
        let ms = try memories(2)
        try await start(x)
        try await drain(x)
        #expect(model.calls.withLock { $0 } == 2 * groups.count)
        let day = try await cap.today(now: t0)
        #expect(day.total == 0 && day.agents == 0)
        #expect(try state()?.ended == "done" && marked() == 0)
        #expect(try v.count("SELECT COUNT(*) FROM facts_run WHERE kind = 'backfill' AND cap_exempt = 1") == 2 * groups.count)
        // After it: a changed memory counts, so at the cap it waits for the next day, code-only meanwhile.
        _ = try v.store.updateMemory(id: ms[0].id, MemoryEdit(body: "Edited after the backfill."), now: t0.plus(minutes: 1))
        try await drain(x)
        #expect(model.calls.withLock { $0 } == 2 * groups.count)
        let waiting = try await v.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT error, not_before FROM processing_job WHERE subject = ? AND kind = 'facts'", arguments: [ms[0].id.db])
                .map { ($0["error"] as String?, $0["not_before"] as Date?) }
        }
        #expect(waiting.count == groups.count && waiting.allSatisfy { $0.0 == "cap" })
        #expect(waiting.allSatisfy { $0.1 == cap.nextDay(after: t0) })
        #expect(try v.store.factsWaitingForCap(now: t0))
    }

    @Test func anAgentsMemoryIsExemptInTheBackfillAndInTheAgentsShareAfter() async throws {
        let cap = CloudRequestCap(store: v.store, limit: 10)            // agents' share: 4
        let model = Model()
        let x = extractor(model, cap: cap)
        let agent = try v.memory("From an agent", "An agent wrote this.")
        try await v.store.writer.write { db in
            try db.execute(sql: "UPDATE memory SET source = 'agent_write', trust = 'untrusted' WHERE id = ?", arguments: [agent.id.db])
        }
        try await start(x)
        try await drain(x)
        var day = try await cap.today(now: t0)
        #expect(day.total == 0 && day.agents == 0)
        _ = try v.store.updateMemory(id: agent.id, MemoryEdit(body: "Edited, still the agent's."), now: t0.plus(minutes: 1))
        try await drain(x)
        day = try await cap.today(now: t0)
        #expect(day.agents == groups.count && day.total == groups.count)
    }

    @Test func aMemoryEditedBeforeItsBackfillReadCountsAgainstTheCap() async throws {
        let cap = CloudRequestCap(store: v.store, limit: 100)
        let x = extractor(Model(), cap: cap)
        let m = try memories(1)[0]
        try await start(x)
        // Edited while its marked jobs wait: the read is of a version the user didn't count, so it isn't exempt.
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(body: "Edited before it was read."), now: t0.plus(minutes: 1))
        try await drain(x)
        #expect(try await cap.today(now: t0).total == groups.count)
        #expect(try state()?.ended == "done" && marked() == 0)
    }

    @Test func reconciliationAfterTheBackfillCountsAndExemptCallsNeverExceedTheEstimate() async throws {
        let cap = CloudRequestCap(store: v.store, limit: 100)
        let model = Model()
        let x = extractor(model, cap: cap)
        _ = try memories(3)
        let e = try await start(x)
        try await drain(x)
        let exempt = try await v.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT counts FROM facts_run WHERE cap_exempt = 1")
                .compactMap { JSON.decode([String: Int].self, $0)?["calls"] }.reduce(0, +)
        }
        #expect(exempt <= e.calls)
        #expect(model.calls.withLock { $0 } - exempt == (try await cap.today(now: t0)).total)
        // One finished row, counts only.
        let rows = activity.events.filter { $0.event == "facts_backfill" && $0.outcome == "finished" }
        #expect(rows.count == 1 && rows[0].counts["memories"] == 3 && rows[0].counts["calls"] == exempt && rows[0].ids.isEmpty)
        let words = try #require(FactsActivityWords(rows[0]))
        #expect(words.title == "Finished reading existing memories" && words.detail.hasPrefix("3 memories"))
        #expect(exempt < 2 || words.detail.contains(" · \(exempt) cloud requests outside the daily count"))
        #expect(try v.count("SELECT COUNT(*) FROM facts_run WHERE kind = 'backfill'") == 3 * groups.count)
    }

    // MARK: Resuming, pausing, failures

    @Test func itResumesWhereItStoppedSendingNoFinishedMemoryAgain() async throws {
        let model = Model()
        let x = extractor(model)
        _ = try memories(3)
        try await start(x)
        // Two jobs, then a quit.
        for _ in 0..<2 {
            let job = try #require(try await queue.claim(now: t0))
            try await queue.finish(job, try await FactsQueueWorker(extractor: x).process(job), now: t0)
        }
        let progress = try #require(try v.store.factsBackfill())
        #expect(progress.total == 3 && progress.done <= 1 && progress.state.isRunning)
        // A new launch: a new queue resumes; a job left running goes back.
        let next = ProcessingQueue(store: v.store, activity: activity, launchedAt: .distantPast)
        try await wake()
        try await next.resume(now: t0)
        try await next.drain(now: { t0 }) { job in try await FactsQueueWorker(extractor: x).process(job) }
        #expect(model.calls.withLock { $0 } == 3 * groups.count)        // each (memory, group) once
        #expect(try v.store.factsBackfill()?.done == 3 && state()?.ended == "done")
    }

    @Test func pauseHoldsMarkedJobsOnlyAndStopsARunningOneBeforeItsNextRequest() async throws {
        let model = Model()
        let x = extractor(model)
        _ = try memories(2)
        try await start(x)
        try await v.store.setFactsBackfillPaused(true)
        #expect(lane.backfillPaused)
        #expect(try await queue.claim(now: t0) == nil)
        // A new memory still runs.
        let fresh = try v.memory("New", "Captured while paused.")
        let job = try #require(try await queue.claim(now: t0))
        #expect(job.subject == fresh.id && job.exemptVersion == nil)
        try await queue.finish(job, try await FactsQueueWorker(extractor: x).process(job), now: t0)
        // A marked job claimed before the pause sends nothing after it.
        let marked = try await v.store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM processing_job WHERE exempt_version IS NOT NULL").map(ProcessingJob.from(row:))
        }
        let before = model.calls.withLock { $0 }
        let outcome = try await FactsQueueWorker(extractor: x).process(try #require(marked))
        #expect(model.calls.withLock { $0 } == before)
        guard case let .later(_, code) = outcome else { Issue.record("expected later, got \(outcome)"); return }
        #expect(code == FactsQueueWorker.backfillPaused)
        try await v.store.setFactsBackfillPaused(false)
        #expect(!lane.backfillPaused)
        try await drain(x)
        #expect(try state()?.ended == "done")
    }

    @Test func aFailureBeforeSendingNeverSpendsTheBackfill() async throws {
        let model = Model()
        let backoff = ProviderBackoff()
        backoff.rateLimited(model, retryAfter: 86_400, now: t0)        // the provider is backing off: nothing is sent
        let x = extractor(model, backoff: backoff)
        _ = try memories(1)
        try await start(x)
        // More claims than the queue's attempts: each waits, uncounted, keeping its mark, and the backfill doesn't end.
        for _ in 0..<(ProcessingQueue.maxAttempts + 2) {
            try await wake()
            guard let job = try await queue.claim(now: t0) else { break }
            let outcome = try await FactsQueueWorker(extractor: x).process(job)
            guard case let .later(_, code) = outcome else { Issue.record("expected later, got \(outcome)"); return }
            #expect(code == "provider")
            try await queue.finish(job, outcome, now: t0)
        }
        #expect(model.calls.withLock { $0 } == 0)
        #expect(try v.count("SELECT COUNT(*) FROM processing_job WHERE state = 'failed'") == 0)
        #expect(try state()?.isRunning == true && marked() == groups.count)
        // The provider is back (a new router, without the backoff): read exempt, and it ends.
        try await wake()
        try await drain(extractor(model))
        #expect(try state()?.ended == "done")
    }

    @Test func oneExemptRequestPerReadRetriesAndFailuresAfterItCount() async throws {
        let cap = CloudRequestCap(store: v.store, limit: 100)
        let model = Model()
        let x = extractor(model, cap: cap)
        let m = try memories(1)[0]
        let e = try await start(x)
        // Answers that aren't the schema's: the first request was exempt, its retry and every attempt after count.
        model.failure.withLock { $0 = .invalidOutput }
        let job = try #require(try await queue.claim(now: t0))
        let outcome = try await FactsQueueWorker(extractor: x).process(job)
        try await queue.finish(job, outcome, now: t0)
        #expect(model.calls.withLock { $0 } == 2)
        #expect(try await cap.today(now: t0).total == 1)
        #expect(try v.count("SELECT COUNT(*) FROM processing_job WHERE id = ? AND exempt_version IS NULL", [job.id.db]) == 1)
        // A request that was sent and failed (a server error) spends it too.
        model.failure.withLock { $0 = .server(status: 500) }
        let other = try #require(try await queue.claim(now: t0))
        #expect(other.subject == m.id && other.exemptVersion != nil)
        try await queue.finish(other, try await FactsQueueWorker(extractor: x).process(other), now: t0)
        #expect(try await cap.today(now: t0).total == 1)                // its one request was the exempt one
        #expect(try marked() == 0)
        // Every mark spent: the backfill ends; the reads carry on as ordinary jobs, under the cap.
        #expect(try state()?.ended == "done")
        model.failure.withLock { $0 = nil }
        try await wake()
        try await drain(x)
        let exempt = try await v.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT counts FROM facts_run").compactMap { JSON.decode([String: Int].self, $0)?["exempt"] }.reduce(0, +)
        }
        #expect(exempt <= e.calls && exempt == 2)
        let finished = activity.events.first { $0.event == "facts_backfill" && $0.outcome == "finished" }
        #expect(finished?.counts["calls"] == 2)
    }

    @Test func theExemptionIsSpentInTheStoreBeforeTheProviderAnswers() async throws {
        let model = Model()
        let x = extractor(model)
        _ = try memories(1)
        try await start(x)
        let store = v.store
        let seen = Mutex<[Int]>([])
        model.onRequest.withLock { $0 = { seen.withLock { $0.append((try? store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processing_job WHERE exempt_version IS NOT NULL") }) ?? -1) } } }
        // A crash right after sending would find each mark already gone: resumed, it reads under the cap.
        try await drain(x)
        #expect(seen.withLock { $0 } == Array((0..<groups.count).reversed()))
        #expect(try state()?.ended == "done")
    }

    @Test func aReviewDropsTheMarksOfAGroupNoModelReadsNow() async throws {
        let x = extractor(Model())
        _ = try memories(1)
        try await start(x)
        // Only one group's model is allowed now (a synthetic record for it alone): the other's marks can't be exempt.
        let g = groups[0], reg = FactsRegistry.bundled
        let one = FactsQualification(records: [FactsQualification.Record(
            predicates: reg.groupPredicates(g), uses: ["recorded"], callGroup: g, engine: FactsEngine(Model()),
            promptVersion: FactsPrompt.version(g, registry: reg), registryVersion: reg.fingerprint, gate: "test", recordedAt: "2026-11-18")])
        let narrower = extractor(Model(), qualification: one)
        try await drain(narrower)
        #expect(try state()?.changed == true)
        let owed = try await v.store.factsBackfillEstimate(extractor: narrower, owed: true)
        #expect(owed.groups == [g])
        try await v.store.reviewFactsBackfill(extractor: narrower, shown: owed, activity: activity)
        #expect(try v.count("SELECT COUNT(*) FROM processing_job WHERE exempt_version IS NOT NULL AND call_group != ?", [g]) == 0)
        // Its own group was read before the pause, so those were the last marks: it ends at the review, told once.
        #expect(try marked() == 0 && state()?.ended == "done")
        #expect(activity.events.filter { $0.event == "facts_backfill" && $0.outcome == "finished" }.count == 1)
    }

    @Test func anEditWhilePausedIsReadAsAnOrdinaryJob() async throws {
        let model = Model()
        let x = extractor(model)
        let m = try memories(1)[0]
        try await start(x)
        try await v.store.setFactsBackfillPaused(true)
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(body: "Edited while paused."), now: t0.plus(minutes: 1))
        #expect(try marked() == 0)
        try await drain(x)
        #expect(model.calls.withLock { $0 } == groups.count)
        #expect(try state()?.ended == "done")
    }

    @Test func startRefusesWhenThereIsNothingToSend() async throws {
        let x = extractor(Model())
        _ = try v.memory("Above", "Above the limit.", sensitivity: .sensitive)
        lane.setLearning(true)
        let e = try await v.store.factsBackfillEstimate(extractor: x)
        #expect(e.calls == 0 && e.kept == 1)
        await #expect(throws: FactsBackfill.StartError.nothing) {
            try await v.store.startFactsBackfill(extractor: x, shown: e, activity: activity, now: t0)
        }
        #expect(try state() == nil)                                     // the exemption is still there
    }

    @Test func aReviewCountsOnlyWhatsOwedAndCarriesOnWithNothingLeft() async throws {
        let x = extractor(Model())
        let ms = try memories(2)
        try await start(x)
        try await drain(extractor(Model(), limit: .upTo(.sensitive)))  // paused for the change
        #expect(try state()?.changed == true)
        // A memory added since doesn't count as owed; the deleted ones leave nothing to send.
        _ = try v.memory("New", "Added after the start.")
        for m in ms { _ = try v.store.deleteMemory(id: m.id, now: t0.plus(minutes: 1)) }
        let wider = extractor(Model(), limit: .upTo(.sensitive))
        let owed = try await v.store.factsBackfillEstimate(extractor: wider, owed: true)
        #expect(owed.calls == 0)
        try await v.store.reviewFactsBackfill(extractor: wider, shown: owed, activity: activity)
        try await wake()
        try await drain(wider)
        #expect(try state()?.ended == "done")
    }

    @Test func catchUpDoesntAskAgainForAReadTheGuardrailsRefused() async throws {
        let model = Model()
        let x = extractor(model)
        // A secret that got in some other way (memories refuse one): the scanner refuses the call.
        let m = try v.memory("Key", "A plain note.")
        try await v.store.writer.write { db in
            try db.execute(sql: "UPDATE memory SET body = ? WHERE id = ?",
                           arguments: ["The key is sk-ant-api03-" + String(repeating: "a", count: 90), m.id.db])
        }
        try await start(x)
        try await drain(x)
        #expect(model.calls.withLock { $0 } == 0)                       // refused before any request
        #expect(try await FactsQueueWorker(extractor: x).scheduleCatchUp() == 0)
        #expect(try await FactsQueueWorker(extractor: x).scheduleCatchUp() == 0)
    }

    @Test func anotherEngineOrAWiderLimitPausesUntilReviewed() async throws {
        let x = extractor(Model())
        _ = try memories(2)
        try await start(x)
        // The cloud limit raised since the estimate: the backfill pauses, nothing is read.
        let wider = extractor(Model(), limit: .upTo(.sensitive))
        try await drain(wider)
        #expect(try state()?.changed == true && lane.backfillPaused)
        #expect(try marked() == 2 * groups.count)
        // The user reviews the new estimate and carries on.
        let e = try await v.store.factsBackfillEstimate(extractor: wider)
        try await v.store.reviewFactsBackfill(extractor: wider, shown: e, activity: activity)
        #expect(try state()?.isPaused == false && !lane.backfillPaused)
        try await wake()
        try await drain(wider)
        #expect(try state()?.ended == "done")
        // Another engine is a change too.
        #expect(FactsQueueWorker.widens(.upTo(.sensitive), .upTo(.internal)))
        #expect(!FactsQueueWorker.widens(.upTo(.low), .upTo(.internal)))
        #expect(FactsQueueWorker.widens(.upTo(.low), .never))
    }

    @Test func aModelNoLongerAllowedPausesRatherThanSpendingTheMarks() async throws {
        let model = Model()
        _ = try memories(1)
        try await start(extractor(model))
        // Its use turned off (no record for it now): marked jobs wait for a review instead of ending code-only.
        try await drain(extractor(model, qualification: FactsQualification(records: [])))
        #expect(try state()?.changed == true && marked() == groups.count && model.calls.withLock { $0 } == 0)
    }

    /// Exempt reads the latest backfill made: its runs since it started (Remove deletes earlier runs with the facts).
    func exemptRuns() throws -> Int { try v.count("SELECT COUNT(*) FROM facts_run WHERE kind = 'backfill' AND cap_exempt = 1") }

    /// Remove learned facts starts Facts over: the backfill's state goes with what it read, so the next turn-on offers it
    /// again with a fresh count, and its exempt reads stay within that count, at the cap as the first time.
    @Test func removeStartsOverAndTheNextBackfillReadsExemptWithinItsCount() async throws {
        let cap = CloudRequestCap(store: v.store, limit: 0)            // every counted request is refused
        let model = Model()
        let x = extractor(model, cap: cap)
        _ = try memories(2)
        let first = try await start(x)
        try await drain(x)
        #expect(try state()?.ended == "done" && model.calls.withLock { $0 } == first.calls)
        _ = try await v.store.removeLearnedFactsStoppingLearning(activity: activity, now: t0.plus(minutes: 60))
        #expect(try state() == nil && marked() == 0 && !lane.learning)
        #expect(try await v.store.factsBackfill() == nil)
        // Turning learning on again: the sheet's count is every memory again, nothing read.
        lane.setLearning(true)
        #expect(try await v.store.factsBackfill() == nil)
        let again = try await v.store.factsBackfillEstimate(extractor: x)
        #expect(again.memories == 2 && again.calls == 2 * groups.count)
        let s = try await v.store.startFactsBackfill(extractor: x, shown: again, activity: activity, now: t0.plus(minutes: 120))
        #expect(try s.isRunning && s.calls == again.calls && marked() == again.calls)
        try await drain(x)
        #expect(try state()?.ended == "done" && marked() == 0)
        #expect(model.calls.withLock { $0 } == first.calls + again.calls)
        #expect(try exemptRuns() == again.calls)
        let day = try await cap.today(now: t0)
        #expect(day.total == 0 && day.lowPriority == 0)
        // Done again: no third exemption without another Remove.
        await #expect(throws: FactsBackfill.StartError.used) {
            try await v.store.startFactsBackfill(extractor: x, shown: again, activity: activity, now: t0.plus(minutes: 180))
        }
        #expect(activity.events.filter { $0.event == "facts_backfill" && $0.outcome == "started" }.count == 2)
    }

    /// Remove during an unfinished, paused backfill ends it with its marks; the next turn-on offers it again, unpaused.
    @Test func removeMidBackfillEndsItAndTheNextTurnOnOffersItAgain() async throws {
        let cap = CloudRequestCap(store: v.store, limit: 0)
        let model = Model()
        let x = extractor(model, cap: cap)
        _ = try memories(3)
        try await start(x)
        // One memory read, then paused with the rest still owed.
        let job = try #require(try await queue.claim(now: t0))
        try await queue.finish(job, try await FactsQueueWorker(extractor: x).process(job), now: t0)
        try await v.store.setFactsBackfillPaused(true)
        #expect(try state()?.isPaused == true && marked() == 3 * groups.count - 1 && lane.backfillPaused)
        _ = try await v.store.removeLearnedFactsStoppingLearning(activity: activity, now: t0.plus(minutes: 5))
        #expect(try state() == nil && marked() == 0 && !lane.backfillPaused)
        #expect(try v.count("SELECT COUNT(*) FROM processing_job WHERE kind = 'facts'") == 0)
        #expect(activity.events.filter { $0.event == "facts_backfill" && $0.outcome == "finished" }.isEmpty)
        lane.setLearning(true)
        let again = try await v.store.factsBackfillEstimate(extractor: x)
        #expect(again.memories == 3 && again.calls == 3 * groups.count)    // the read one is unread again
        try await v.store.startFactsBackfill(extractor: x, shown: again, activity: activity, now: t0.plus(minutes: 6))
        #expect(try state()?.isPaused == false && !lane.backfillPaused)
        try await drain(x)
        #expect(try state()?.ended == "done" && exemptRuns() == again.calls)
        #expect(model.calls.withLock { $0 } == 1 + again.calls)
        #expect(try await cap.today(now: t0).total == 0)
    }

    /// Not Now after a Remove: learning goes on for new and changed memories only, as the first time; nothing reads the
    /// older memories until Read Existing Memories….
    @Test func notNowAfterARemoveReadsOnlyNewMemories() async throws {
        let model = Model()
        let x = extractor(model)
        _ = try memories(2)
        try await start(x)
        try await drain(x)
        _ = try await v.store.removeLearnedFactsStoppingLearning(activity: activity, now: t0)
        let before = model.calls.withLock { $0 }
        lane.setLearning(true)
        #expect(try await v.store.writer.write { db in try FactsBackfill.catchUp(db, extractor: x, now: t0) } == 0)
        _ = try v.memory("New", "Captured after the Remove.")
        try await drain(x)
        #expect(model.calls.withLock { $0 } == before + groups.count)
        #expect(try state() == nil)
    }

    /// A state a Remove left ended `removed`, before Remove reset it: read as no backfill, so the sheet is offered.
    @Test func aStateEndedRemovedReadsAsNoBackfill() async throws {
        let x = extractor(Model())
        _ = try memories(1)
        try await v.store.writer.write { db in
            var s = FactsBackfill.State(startedAt: t0, memories: 1, calls: groups.count, engines: [:], limit: .upTo(.internal))
            s.finishedAt = t0
            s.ended = "removed"
            try FactsBackfill.write(db, s)
        }
        #expect(try state() == nil)
        try await start(x)
        #expect(try state()?.isRunning == true)
    }

    @Test func aBackfillWithNoMarkLeftEndsAtLaunch() async throws {
        let x = extractor(Model())
        _ = try memories(1)
        try await start(x)
        try await v.store.writer.write { db in try db.execute(sql: "UPDATE processing_job SET exempt_version = NULL") }
        try await v.store.settleFactsBackfill(activity: activity, now: t0)
        #expect(try state()?.ended == "done")
        #expect(activity.events.filter { $0.event == "facts_backfill" && $0.outcome == "finished" }.count == 1)
    }

    @Test func aMemoryDeletedMidBackfillStillLetsItEnd() async throws {
        let x = extractor(Model())
        let ms = try memories(2)
        try await start(x)
        _ = try v.store.deleteMemory(id: ms[1].id, now: t0.plus(minutes: 1))
        try await drain(x)
        #expect(try state()?.ended == "done")
    }

    // MARK: Catch-up and re-reads

    @Test func catchUpQueuesUnreadSendableMemoriesInScopeUnderTheCap() async throws {
        let cap = CloudRequestCap(store: v.store, limit: 100)
        let model = Model()
        let x = extractor(model, cap: cap)
        _ = try memories(2)
        _ = try v.memory("Above", "Above the limit.", sensitivity: .sensitive)
        lane.setLearning(true)
        // Before the backfill, existing memories aren't the lane's: nothing.
        #expect(try await FactsQueueWorker(extractor: x).scheduleCatchUp() == 0)
        try await start(x)
        try await drain(x)
        let read = model.calls.withLock { $0 }
        // Everything read: nothing more.
        #expect(try await FactsQueueWorker(extractor: x).scheduleCatchUp() == 0)
        // The limit rises: the memory above it is read now, under the cap.
        let wider = extractor(model, cap: cap, limit: .upTo(.sensitive))
        #expect(try await FactsQueueWorker(extractor: wider).scheduleCatchUp() == groups.count)
        try await drain(wider)
        #expect(model.calls.withLock { $0 } == read + groups.count)
        #expect(try await cap.today(now: t0).total == groups.count)
        // Learning off: nothing.
        lane.setLearning(false)
        #expect(try await FactsQueueWorker(extractor: wider).scheduleCatchUp() == 0)
    }

    @Test func aMemoryCodeOnlyForWantOfAModelIsReadOnceOneQualifies() async throws {
        lane.setLearning(true)
        let model = Model()
        let unqualified = extractor(model, qualification: FactsQualification(records: []))
        _ = try v.memory("New", "Captured before any model qualified.")
        try await drain(unqualified)                                    // code-only: no model may read it
        #expect(model.calls.withLock { $0 } == 0)
        // A model qualifies (coverage grows): the memory had jobs, so it's read, though no backfill ran.
        let x = extractor(model)
        #expect(try await FactsQueueWorker(extractor: x).scheduleCatchUp() == groups.count)
        try await drain(x)
        #expect(model.calls.withLock { $0 } == groups.count)
    }

    @Test func aStaleReadingIsReadAgainInFullOnlyInItsGroup() async throws {
        let model = Model()
        let x = extractor(model)
        let m = try memories(1)[0]
        try await start(x)
        try await drain(x)
        // One group's reading was made under another extraction key (a release changed that group).
        try await v.store.writer.write { db in
            try db.execute(sql: "UPDATE facts_asked SET knowledge = 'x=old;r=' WHERE mention_kind = 'read' AND call_group = ?", arguments: [groups[0]])
        }
        #expect(try await FactsQueueWorker(extractor: x).scheduleCatchUp() == 1)
        let before = model.calls.withLock { $0 }
        try await drain(x)
        #expect(model.calls.withLock { $0 } == before + 1)
        #expect(try v.count("SELECT COUNT(*) FROM facts_run WHERE kind = 'reread' AND call_group = ? AND cap_exempt = 0", [groups[0]]) == 1)
        _ = m
    }

    @Test func readKeysFollowExtractionAndCoverageNotLanguage() throws {
        let reg = FactsRegistry.bundled
        // A language-only change: query cues and a question word. No group's extraction digest moves.
        let language = try FX.registry { json in
            FX.editPredicate(&json, reg.predicates[0].id) { p in p["query_cues"] = (p["query_cues"] as! [String]) + ["zzcue"] }
            var lang = json["language"] as! [String: Any]
            lang["question_words"] = (lang["question_words"] as! [String]) + ["zzwhat"]
            json["language"] = lang
        }
        #expect(language.extractionDigests == reg.extractionDigests)
        #expect(language.fingerprint != reg.fingerprint)                // its gates still re-run
        // An extraction change in one group: only that group's digest moves.
        let pred = reg.predicates[0]
        let extraction = try FX.registry { json in
            FX.editPredicate(&json, pred.id) { p in p["definition"] = (p["definition"] as! String) + " Changed." }
        }
        for g in groups { #expect((extraction.extractionDigests[g] == reg.extractionDigests[g]) == (g != pred.callGroup)) }
        // Coverage: a predicate recorded now that wasn't is stale; fewer isn't; no key is current.
        #expect(FactsExtractor.isStale("x=a;r=p", current: "x=a;r=p,q"))
        #expect(!FactsExtractor.isStale("x=a;r=p,q", current: "x=a;r=p"))
        #expect(FactsExtractor.isStale("x=a;r=p", current: "x=b;r=p"))
        #expect(!FactsExtractor.isStale("", current: "x=b;r=p"))
    }

    // MARK: Asked records

    @Test func askedKnowledgeIsADigestSoNoNameOutlivesAPurge() async throws {
        let x = extractor(Model())
        _ = try v.memory("Sister", "My sister Zebulonia called.")
        try await start(x)
        try await drain(x)
        let rows = try await v.store.writer.read { db in try String.fetchAll(db, sql: "SELECT knowledge FROM facts_asked") }
        #expect(!rows.isEmpty && rows.allSatisfy { !$0.contains("Zebulonia") })
        #expect(rows.contains { $0.hasPrefix("x=") })                   // the read keys
    }

    @Test func anExportCarriesAskedRecordsSoARestoredMemoryIsntReadAgain() async throws {
        let model = Model()
        let x = extractor(model)
        let ms = try memories(2)
        try await start(x)
        try await drain(x)
        // Readings that found nothing: still worth exporting.
        let section = try #require(try await v.store.writer.write { db in
            try FactsExport.section(db, exporting: Set(ms.map(\.id.db)), now: t0)
        })
        #expect(section.asked?.filter { $0["mention_kind"]?.string == "read" }.count == 2 * groups.count)
        let fresh = try TestVault()
        var map: [String: (id: String, version: Int)] = [:]
        for m in ms {
            let n = try fresh.memory(m.title, m.body)
            map[m.id.db] = (n.id.db, 1)
        }
        // One memory didn't come back: its records don't either.
        map.removeValue(forKey: ms[1].id.db)
        let restored = map
        #expect(try await fresh.store.writer.write { db in try FactsExport.restore(db, section, memories: restored, now: t0) })
        #expect(try fresh.count("SELECT COUNT(*) FROM facts_asked WHERE mention_kind = 'read'") == groups.count)
        // Restored and learning on: the plan for it is "nothing", no call.
        let other = Model()
        var y = FactsExtractor(store: fresh.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.internal),
                                                                       factsModel: other),
                               activity: activity, qualification: .unchecked)
        y.clock = { t0 }
        let plan = try await FactsQueueWorker(extractor: y).plan(try #require(map[ms[0].id.db]).id, group: groups[0])
        #expect(plan == .nothing)
        // Older exports (no asked rows) still decode.
        var old = section
        old.asked = nil
        let decoded = try JSONDecoder().decode(FunesExportFacts.self, from: try JSONEncoder().encode(old))
        #expect(decoded.asked == nil)
    }
}
