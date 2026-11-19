import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Phase 13a.2's Settings step on the facts lane (memory processing §11.3): memory commits queue facts jobs while
/// *Learn from memories* is on; a facts job is admitted only while learning is on and nothing closes the lane, atomically
/// with the claim; the tidy-up and Remove learned facts wait for a running one; a job checks before every request.
@Suite struct FactsLaneSwitchTests {
    let v: TestVault
    let queue: ProcessingQueue
    var lane: FactsLane { v.store.factsLane }
    let groups = FactsRegistry.bundled.callGroups.keys.sorted()

    init() throws {
        v = try TestVault()
        queue = ProcessingQueue(store: v.store, activity: InMemoryActivityLog(), launchedAt: .distantPast)
    }

    func factsJobs() throws -> [String] {
        try v.store.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT COALESCE(call_group, '-') || ':' || state || ':' || COALESCE(memory_version, '-') FROM processing_job
                WHERE kind = 'facts' ORDER BY call_group, rowid
                """)
        }
    }

    // MARK: Commits

    @Test func commitsQueueFactsJobsOnlyWhileLearningIsOn() throws {
        _ = try v.memory("Off")
        #expect(try factsJobs().isEmpty)
        lane.setLearning(true)
        let m = try v.memory("On")
        #expect(try factsJobs() == groups.map { "\($0):queued:1" })
        lane.setLearning(false)
        _ = try v.memory("Off again")
        #expect(try factsJobs().count == groups.count)
        _ = m
    }

    @Test func everyVersionLeftActiveOrArchivedAsksAgainButADeleteDoesnt() throws {
        lane.setLearning(true)
        let m = try v.memory("Note", "First text")
        try v.store.writer.write { db in try db.execute(sql: "UPDATE processing_job SET state = 'done' WHERE kind = 'facts'") }
        // A text edit (version 2), then a sensitivity change (version 3): each asks for that version.
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(body: "Second text"), now: t0.plus(minutes: 1))
        #expect(try factsJobs() == groups.map { "\($0):queued:2" })
        try v.store.writer.write { db in try db.execute(sql: "UPDATE processing_job SET state = 'done' WHERE kind = 'facts'") }
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(sensitivity: .internal), now: t0.plus(minutes: 2))
        #expect(try factsJobs() == groups.map { "\($0):queued:3" })
        // A confidence-only change isn't a version.
        try v.store.writer.write { db in try db.execute(sql: "UPDATE processing_job SET state = 'done' WHERE kind = 'facts'") }
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(confidence: 0.5), now: t0.plus(minutes: 3))
        #expect(try factsJobs() == groups.map { "\($0):done:3" })
        // Archived: asked again (the job makes no call when the reading carried forward).
        _ = try v.store.archiveMemory(id: m.id, now: t0.plus(minutes: 4))
        #expect(try factsJobs() == groups.map { "\($0):queued:4" })
        // Deleted: nothing to read.
        try v.store.writer.write { db in try db.execute(sql: "UPDATE processing_job SET state = 'done' WHERE kind = 'facts'") }
        _ = try v.store.deleteMemory(id: m.id, now: t0.plus(minutes: 5))
        #expect(try factsJobs() == groups.map { "\($0):done:4" })
    }

    // MARK: Admission

    @Test func aFactsJobIsAdmittedOnlyWhileLearningIsOnAndTheLaneIsOpen() async throws {
        let memory = UUID()
        try await v.store.writer.write { db in
            try ProcessingQueue.enqueueFacts(db, memoryID: memory, version: 1, group: groups[0], reason: .version, now: t0)
        }
        #expect(try await queue.claim(now: t0) == nil)                 // learning off
        lane.setLearning(true)
        await lane.close(.tidyUp)
        #expect(try await queue.claim(now: t0) == nil)                 // closed
        lane.open(.tidyUp)
        let job = try #require(try await queue.claim(now: t0))
        #expect(job.kind == .facts)
        // One at a time: another facts job waits until this one's outcome is recorded.
        try await v.store.writer.write { db in
            try ProcessingQueue.enqueueFacts(db, memoryID: UUID(), version: 1, group: groups[0], reason: .version, now: t0)
        }
        #expect(try await queue.claim(now: t0) == nil)
        try await queue.finish(job, .done(engine: nil), now: t0)
        await lane.close(.removing)                                    // nothing running: returns at once
        lane.open(.removing)
    }

    @Test func theTidyUpWaitsForARunningFactsJobAndNoneStartsMeanwhile() async throws {
        lane.setLearning(true)
        for g in groups {
            try await v.store.writer.write { db in
                try ProcessingQueue.enqueueFacts(db, memoryID: UUID(), version: 1, group: g, reason: .version, now: t0)
            }
        }
        let job = try #require(try await queue.claim(now: t0))
        let closed = Mutex(false)
        let tidy = Task {
            await lane.close(.tidyUp)
            closed.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!closed.withLock { $0 })
        try await queue.finish(job, .done(engine: nil), now: t0)
        await tidy.value
        #expect(closed.withLock { $0 })
        // Closed: the next facts job waits until the tidy-up reopens the lane.
        #expect(try await queue.claim(now: t0) == nil)
        lane.open(.tidyUp)
        #expect(try await queue.claim(now: t0) != nil)
    }

    @Test func turningLearningOffOrAChangeStopsAJobBeforeItsNextRequest() {
        lane.setLearning(true)
        let g = lane.generation
        #expect(lane.permits(g))
        lane.reconfigured()
        #expect(!lane.permits(g))
        let g2 = lane.generation
        lane.setLearning(false)
        #expect(!lane.permits(g2) && !lane.permits(lane.generation))
    }

    @Test func anExtractorThatMayNotSendSendsNothingAndGoesBackToTheQueue() async throws {
        let m = try v.memory("My sister called", "My sister called about the trip.")
        let calls = Mutex(0)
        let provider = FactsExtractorTests.Scripted { _ in
            calls.withLock { $0 += 1 }
            return [:]
        }
        var x = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.internal),
                                                                   factsModel: provider),
                               activity: InMemoryActivityLog(), qualification: .unchecked)
        x.permit = { false }
        let job = ProcessingJob(id: UUID(), subject: m.id, kind: .facts, state: .running, attempts: 1, createdAt: t0,
                                memoryVersion: 1, callGroup: groups[0])
        let outcome = try await FactsQueueWorker(extractor: x).process(job)
        #expect(calls.withLock { $0 } == 0)
        guard case let .later(_, code) = outcome else { Issue.record("expected later, got \(outcome)"); return }
        #expect(code == "changed")
        // Nothing was read or written for it.
        #expect(try v.count("SELECT COUNT(*) FROM facts_asked") == 0)
        #expect(try v.count("SELECT COUNT(*) FROM alias_evidence") == 0)
    }

    @Test func aChangeWhileTheCapsWriteWaitsStillSendsNothing() async throws {
        let m = try v.memory("My sister called", "My sister called about the trip.")
        let calls = Mutex(0), asked = Mutex(0)
        let provider = FactsExtractorTests.Scripted { _ in
            calls.withLock { $0 += 1 }
            return [:]
        }
        var x = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.internal),
                                                                   factsModel: provider),
                               activity: InMemoryActivityLog(), qualification: .unchecked)
        // Allowed when the extractor asks before the call; revoked by the time the router reaches the send boundary
        // (after the cap's write, which can wait).
        x.permit = { asked.withLock { $0 += 1; return $0 == 1 } }
        let job = ProcessingJob(id: UUID(), subject: m.id, kind: .facts, state: .running, attempts: 1, createdAt: t0,
                                memoryVersion: 1, callGroup: groups[0])
        let outcome = try await FactsQueueWorker(extractor: x).process(job)
        #expect(calls.withLock { $0 } == 0 && asked.withLock { $0 } == 2)
        guard case let .later(_, code) = outcome else { Issue.record("expected later, got \(outcome)"); return }
        #expect(code == "changed")
    }

    @Test func aRevocationWhileTheCapsWriteIsHeldSendsNothing() async throws {
        lane.setLearning(true)
        let generation = lane.generation
        let cap = CloudRequestCap(store: v.store)
        let calls = Mutex(0)
        let provider = FactsExtractorTests.Scripted { _ in
            calls.withLock { $0 += 1 }
            return [:]
        }
        let request = StructuredRequest<FactsJSON>(instructions: "i", prompt: "p",
                                                   schema: FactsPrompt.schema(groups[0], registry: .bundled))
        // Hold the writer, so the cap's write waits behind it.
        let release = DispatchSemaphore(value: 0), holding = Mutex(false)
        let holder = Task.detached { [store = v.store] in
            try store.writer.write { _ in
                holding.withLock { $0 = true }
                release.wait()
            }
        }
        while !holding.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        let lane = self.lane
        let send = Task {
            try await ModelRouter.send(request, items: [ModelItem("A note", sensitivity: .low)], to: provider, cloudLimit: .upTo(.internal),
                                       cap: cap, timeout: .seconds(5), permit: { lane.permits(generation) })
        }
        try await Task.sleep(for: .milliseconds(200))                  // the send waits on the cap's write
        lane.setLearning(false)
        release.signal()
        try await holder.value
        await #expect(throws: SendNotPermitted.self) { _ = try await send.value }
        #expect(calls.withLock { $0 } == 0)
    }

    /// Rejects every commit while on.
    final class RejectCommits: TransactionObserver, @unchecked Sendable {
        let on = Mutex(false)
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
        func databaseDidChange(with event: DatabaseEvent) {}
        func databaseWillCommit() throws { if on.withLock({ $0 }) { throw DatabaseError(resultCode: .SQLITE_ABORT) } }
        func databaseDidCommit(_ db: Database) {}
        func databaseDidRollback(_ db: Database) {}
    }

    @Test func aClaimWhoseCommitFailsDoesntHoldTheLane() async throws {
        lane.setLearning(true)
        _ = try v.memory("A note")
        let reject = RejectCommits()
        v.store.writer.add(transactionObserver: reject, extent: .databaseLifetime)
        reject.on.withLock { $0 = true }
        await #expect(throws: (any Error).self) { try await queue.claim(now: t0) }
        reject.on.withLock { $0 = false }
        await lane.close(.tidyUp)                                      // nothing running: returns at once
        lane.open(.tidyUp)
        #expect(try await queue.claim(now: t0)?.kind == .facts)
    }

    // MARK: Remove learned facts

    @Test func removingWaitsForARunningJobThenTakesEveryFactsJobAndLearningOff() async throws {
        lane.setLearning(true)
        let m = try v.memory("A note")
        let job = try #require(try await queue.claim(now: t0))
        #expect(job.subject == m.id)
        let removed = Mutex(false)
        let remove = Task {
            _ = try await v.store.removeLearnedFactsStoppingLearning(activity: InMemoryActivityLog(), now: t0)
            removed.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!removed.withLock { $0 })                              // waits for the running job
        #expect(!lane.learning)                                        // learning went off first
        try await queue.finish(job, .done(engine: nil), now: t0)
        try await remove.value
        #expect(removed.withLock { $0 })
        // Every facts job is gone, the sweep its revision bump queued included, and commits queue none now.
        #expect(try factsJobs().isEmpty)
        _ = try v.memory("After")
        #expect(try factsJobs().isEmpty)
        #expect(lane.isOpen == false)
    }

    // MARK: Waiting for a model

    @Test func jobsThatWaitedForAModelAreDueOnceTheSettingsChange() async throws {
        lane.setLearning(true)
        _ = try v.memory("A note")
        let job = try #require(try await queue.claim(now: t0))
        try await queue.finish(job, .later(until: t0.plus(days: 1), code: "no_model"), now: t0)
        #expect(try await queue.claim(now: t0.plus(minutes: 1))?.callGroup != job.callGroup)
        #expect(try await queue.wakeFacts(code: "no_model", now: t0) == 1)
    }

    // MARK: Your names

    @Test func changingYourNameStopsARunningJobBeforeItsNextRequest() async throws {
        lane.setLearning(true)
        let profiles = ProfileService(store: v.store, activity: InMemoryActivityLog())
        let g = lane.generation
        var p = Profile()
        p.occupation = "Writer"
        _ = try await profiles.save(p, now: t0)
        #expect(lane.permits(g))                                       // not a name
        p.givenName = "Dani"
        _ = try await profiles.save(p, now: t0.plus(minutes: 1))
        #expect(!lane.permits(g))
    }
}
