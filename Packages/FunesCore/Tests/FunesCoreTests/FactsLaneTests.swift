import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Phase 13a.2's facts lane in `ProcessingQueue` (memory processing §11.3): the low-priority lane, revision- and
/// call-group-aware jobs, and work asked for while a job runs.
@Suite struct FactsLaneTests {
    let v: TestVault
    let queue: ProcessingQueue

    init() throws {
        v = try TestVault()
        queue = ProcessingQueue(store: v.store, activity: InMemoryActivityLog(), launchedAt: t0)
    }

    func enqueueFacts(_ memory: UUID, version: Int = 1, group: String = "people", reason: ProcessingQueue.FactsReason = .version,
                      at: Date = t0) async throws {
        try await v.store.writer.write { db in
            try ProcessingQueue.enqueueFacts(db, memoryID: memory, version: version, group: group, reason: reason, now: at)
        }
    }

    func rows() async throws -> [String] {
        try await v.store.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT kind || ':' || COALESCE(call_group, '-') || ':' || state || ':' || COALESCE(memory_version, '-') FROM processing_job
                ORDER BY created_at, rowid
                """)
        }
    }

    @Test func factsWaitWhileNewMemoriesOrTheTidyUpWait() async throws {
        let memory = UUID(), input = UUID()
        try await enqueueFacts(memory)
        try await v.store.writer.write { db in try ProcessingQueue.enqueue(db, subject: input, now: t0.plus(minutes: 1)) }
        // A New memories job queued later still comes first.
        let first = try #require(try await queue.claim(now: t0.plus(minutes: 2)))
        #expect(first.kind == .newMemory)
        // While it runs, and while it waits for a retry, the facts job waits too.
        #expect(try await queue.claim(now: t0.plus(minutes: 2)) == nil)
        try await queue.finish(first, .retry(code: "unavailable"), now: t0.plus(minutes: 2))
        #expect(try await queue.claim(now: t0.plus(minutes: 2)) == nil)
        let again = try #require(try await queue.claim(now: t0.plus(minutes: 60)))
        #expect(again.kind == .newMemory)
        try await queue.finish(again, .done(engine: nil), now: t0.plus(minutes: 60))

        // A tidy-up run this process opened pauses the lane; one left open before launch doesn't.
        try await v.store.writer.write { db in
            try db.execute(sql: "INSERT INTO tidy_up_run (id, started_at, engine) VALUES ('old', ?, NULL)", arguments: [t0.plus(minutes: -1)])
            try db.execute(sql: "INSERT INTO tidy_up_run (id, started_at, engine) VALUES ('now', ?, NULL)", arguments: [t0.plus(minutes: 60)])
        }
        #expect(try await queue.claim(now: t0.plus(minutes: 120)) == nil)
        try await v.store.writer.write { db in try db.execute(sql: "UPDATE tidy_up_run SET finished_at = ? WHERE id = 'now'", arguments: [t0.plus(minutes: 120)]) }
        // The in-process pause (the tidy-up before it writes its run).
        let paused = ProcessingQueue(store: v.store, activity: InMemoryActivityLog(), launchedAt: t0, factsPaused: { true })
        #expect(try await paused.claim(now: t0.plus(minutes: 120)) == nil)
        let facts = try #require(try await queue.claim(now: t0.plus(minutes: 120)))
        #expect(facts.kind == .facts && facts.subject == memory && facts.callGroup == "people" && facts.memoryVersion == 1)
        // The facts lane isn't the Inbox's work.
        try await v.store.writer.write { db in try ProcessingQueue.enqueue(db, subject: UUID(), now: t0) }
        #expect(try await queue.waiting() == 1)
    }

    @Test func memoriesComeBeforeTheSweep() async throws {
        try await v.store.writer.write { db in try ProcessingQueue.enqueueFactsSweep(db, now: t0) }
        let memory = UUID()
        try await enqueueFacts(memory, at: t0.plus(minutes: 1))
        #expect(try await queue.claim(now: t0.plus(minutes: 2))?.subject == memory)
    }

    @Test func factsJobsDedupeByRevisionAndCallGroup() async throws {
        let memory = UUID()
        try await enqueueFacts(memory)
        try await enqueueFacts(memory)
        try await enqueueFacts(memory, group: "work")
        #expect(try await rows() == ["facts:people:queued:1", "facts:work:queued:1"])
        try await enqueueFacts(memory, version: 2)                  // a newer version while queued: one job, the newer version
        #expect(try await rows() == ["facts:people:queued:2", "facts:work:queued:1"])
        _ = try await queue.drain(now: { t0 }) { _ in .done(engine: "x") }
        // The version it read isn't read again; a newer one is, and so is a reconciliation of the same version.
        try await enqueueFacts(memory, version: 2)
        try await enqueueFacts(memory, version: 1, group: "work")
        #expect(try await rows() == ["facts:people:done:2", "facts:work:done:1"])
        try await enqueueFacts(memory, version: 3, at: t0.plus(minutes: 1))
        try await enqueueFacts(memory, version: 1, group: "work", reason: .reconcile, at: t0.plus(minutes: 2))
        #expect(try await rows() == ["facts:people:queued:3", "facts:work:queued:1"])
        let job = try #require(try await queue.job(subject: memory, kind: .facts, callGroup: "people"))
        #expect(job.attempts == 0 && job.state == .queued)
    }

    @Test(arguments: [ProcessingQueue.Outcome.done(engine: "x"), .failed(code: "x"), .retry(code: "x"), .later(until: t0.plus(days: 1), code: "x")])
    func workAskedForWhileAJobRunsIsNeverLost(_ outcome: ProcessingQueue.Outcome) async throws {
        let memory = UUID()
        try await enqueueFacts(memory)
        var job = try #require(try await queue.claim(now: t0))
        if case .retry = outcome {         // the last attempt: a retry would fail the job
            job.attempts = ProcessingQueue.maxAttempts
            let id = job.id.db
            try await v.store.writer.write { db in
                try db.execute(sql: "UPDATE processing_job SET attempts = ? WHERE id = ?", arguments: [ProcessingQueue.maxAttempts, id])
            }
        }
        try await enqueueFacts(memory, version: 2)                  // an edit while it runs
        try await queue.finish(job, outcome, now: t0)
        let after = try #require(try await queue.job(subject: memory, kind: .facts, callGroup: "people"))
        #expect(after.state == .queued && after.memoryVersion == 2 && after.attempts == 0 && after.notBefore == nil)
        // Without anything new, the outcome stands.
        let rerun = try #require(try await queue.claim(now: t0))
        try await queue.finish(rerun, .done(engine: "x"), now: t0)
        #expect(try await queue.job(subject: memory, kind: .facts, callGroup: "people")?.state == .done)
    }
}

/// Phase 13a.2's reconciliation through the facts lane (memory processing §11.3, §11.4): what is asked again, what is
/// revalidated in code, and that a partial re-read never erases an earlier reading. Scripted model answers, no live calls.
@Suite(.serialized) struct FactsReconcileTests {
    let t: FactsExtractorTests
    var v: TestVault { t.v }
    let boss: String
    typealias Scripted = FactsExtractorTests.Scripted

    init() throws {
        t = try FactsExtractorTests()
        boss = FX.personPredicate { $0.lexicon.contains { $0.words.contains("manager") } }
    }

    var people: String { t.people }
    let clock = FactsHarness.Clock()

    /// An extractor on this suite's one clock (read times must go forward across extractors).
    func extractor(_ provider: any GenerationProvider) -> FactsExtractor {
        var x = t.extractor(provider)
        let c = clock
        x.clock = { c.now() }
        return x
    }

    static func fact(_ quote: String, _ predicate: String, _ name: String, entity: String = "name") -> [String: Any] {
        FactsExtractorTests.fact(quote, predicate, name, entity: entity, label: "manager", status: "current")
    }

    /// Plays memories through the lane, one at a time, each drained before the next, and returns the calls made.
    final class Lane: @unchecked Sendable {
        let queue: ProcessingQueue
        let worker: FactsQueueWorker
        let modes = Mutex<[(memory: String, mode: String, outcome: String)]>([])

        init(_ x: FactsExtractor, store: VaultStore) {
            queue = ProcessingQueue(store: store, activity: InMemoryActivityLog(), launchedAt: .distantPast)
            worker = FactsQueueWorker(extractor: x)
        }

        func read(_ memory: String, groups: [String], store: VaultStore) async throws {
            try await store.writer.write { db in
                let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [memory]) ?? 1
                for g in groups {
                    try ProcessingQueue.enqueueFacts(db, memoryID: UUID(uuidString: memory)!, version: version, group: g, reason: .version, now: Date())
                }
            }
            try await drain()
        }

        func drain() async throws {
            _ = try await queue.drain(now: { Date() }) { job in
                try await self.worker.process(job) { r, mode in
                    self.modes.withLock { m in for c in r.calls { m.append((c.memoryID, mode, c.outcome.rawValue)) } }
                }
            }
        }

        var calls: [(memory: String, mode: String, outcome: String)] { modes.withLock { $0 } }
    }

    func roleLink(_ memory: String) throws -> (entity: String?, basis: LinkBasis) {
        var g = try t.load()
        // A memory nothing was learned from isn't in the graph: its phrases still resolve.
        let mem = try g.memories[memory] ?? v.store.writer.read { db in
            let r = try #require(try Row.fetchOne(db, sql: "SELECT title, body, created_at FROM memory WHERE id = ?", arguments: [memory]))
            return FactsMemory(id: memory, text: FactStore.text(title: r["title"], body: r["body"]), written: FactStore.writtenDay(r["created_at"]),
                               source: .capture, trusted: true)
        }
        let ph = try #require(g.rolePhrases(mem.text).first)
        return g.resolve(mem, ph)
    }

    func name(_ entity: String?) throws -> String? { try entity.flatMap { try t.load().entities[$0]?.name } }

    // MARK: Asked again, or revalidated in code

    @Test func aNewHolderMakesAnUndecidedPhraseDueOnce() async throws {
        let b = boss
        let m1 = try t.memory("My manager is Elise Vale.")
        let m2 = try t.memory("My manager called about the deadline.", days: 5)
        let m3 = try t.memory("Karim Rook is my manager too.", days: 2)
        let x = extractor(Scripted { r in
            let m = FactsExtractorTests.memoryText(r.prompt)
            if m.contains("Elise") {
                return ["people": [["name": "Elise Vale", "quote": "Elise Vale", "person": "new"]],
                        "facts": [Self.fact("My manager is Elise Vale", b, "Elise Vale")], "roles": [["id": "r1", "refers_to": "name:Elise Vale"]]]
            }
            if m.contains("Karim") {
                return ["people": [["name": "Karim Rook", "quote": "Karim Rook", "person": "new"]],
                        "facts": [Self.fact("Karim Rook is my manager", b, "Karim Rook")], "roles": [["id": "r1", "refers_to": "name:Karim Rook"]]]
            }
            return ["roles": [["id": "r1", "refers_to": "unknown"]]]
        })
        let lane = Lane(x, store: v.store)
        for m in [m1, m2] { try await lane.read(m, groups: [people], store: v.store) }
        #expect(try roleLink(m2).basis == .soleKnown)                    // one holder: nothing to ask
        #expect(lane.calls.map(\.mode) == ["full", "full"])
        try await x.learn([m3], groups: [people])
        let stale = try await v.store.writer.read { db in try FactStore.staleDecisions(db) }.map(\.memoryID)
        #expect(stale == [m1])                                         // 13a.1 invalidated m1's decision
        lane.modes.withLock { $0.append((m3, "full", "applied")) }
        try await lane.drain()
        // Karim is a second holder: m2's phrase is asked again, partially; m1's named decision is revalidated in code.
        #expect(lane.calls.map { "\($0.memory == m2 ? "m2" : $0.memory == m3 ? "m3" : "m1") \($0.mode)" } == ["m1 full", "m2 full", "m3 full", "m2 reconcile"])
        #expect(try roleLink(m1).basis == .named)
        #expect(try roleLink(m2).basis == .candidates)
        // Asked once: another sweep finds nothing new.
        try await v.store.writer.write { db in try ProcessingQueue.enqueueFactsSweep(db, now: Date()) }
        try await lane.drain()
        #expect(lane.calls.count == 4)
    }

    @Test func aRestatedHolderIsRevalidatedWithoutACall() async throws {
        let b = boss
        let m1 = try t.memory("My manager is Elise Vale.")
        let m2 = try t.memory("Karim Rook is my other manager.", days: 1)
        let m3 = try t.memory("My manager approved the leave.", days: 2)
        let m4 = try t.memory("Elise Vale is still my manager.", days: 3)
        let x = extractor(Scripted { r in
            let m = FactsExtractorTests.memoryText(r.prompt)
            for n in ["Elise Vale", "Karim Rook"] where m.contains(n) {
                let id = FactsExtractorTests.rosterID(r.prompt, n)
                return ["people": [["name": n, "quote": n, "person": id]], "facts": [Self.fact(m.hasPrefix("My") ? "My manager is \(n)" : m.hasPrefix("Karim") ? "Karim Rook is my other manager" : "Elise Vale is still my manager", b, n, entity: id == "new" ? "name" : id)]]
            }
            return ["roles": [["id": "r1", "refers_to": FactsExtractorTests.rosterID(r.prompt, "Elise Vale")]]]
        })
        let lane = Lane(x, store: v.store)
        for m in [m1, m2, m3] { try await lane.read(m, groups: [people], store: v.store) }
        let before = try roleLink(m3)
        let chosen = try name(before.entity)
        #expect(before.basis == .context && chosen == "Elise Vale")
        try await x.learn([m4], groups: [people])
        let stale = try await v.store.writer.read { db in try FactStore.staleDecisions(db) }.map(\.memoryID)
        #expect(Set(stale) == [m1, m2, m3])          // 13a.1 invalidates every decision of the predicate
        try await lane.drain()
        // A fact of the predicate changed, but who might be meant didn't (m3), and the names m1 and m2 pair with their
        // phrases stand: all three are revalidated in code, with no call.
        #expect(!lane.calls.contains { $0.mode == "reconcile" })
        #expect(try roleLink(m3).basis == .context)
        #expect(try await v.store.writer.read { db in try FactStore.staleDecisions(db) }.isEmpty)
    }

    @Test func aSharedNameIsReopenedFromAliasEvidenceAndAskedAgain() async throws {
        let m1 = try t.memory("My friend Ana Gómez is a nurse.")
        let m2 = try t.memory("Ana sent flowers.", days: 1)
        let m3 = try t.memory("My friend Ana Silva teaches maths.", days: 2)
        let answers = Mutex(0)
        let x = extractor(Scripted { r in
            let m = FactsExtractorTests.memoryText(r.prompt)
            if m.contains("flowers") {
                let n = answers.withLock { $0 += 1; return $0 }
                return ["people": [["name": "Ana", "quote": "Ana sent", "person": n == 1 ? FactsExtractorTests.rosterID(r.prompt, "Ana Gómez") : "ambiguous"]]]
            }
            let full = m.contains("Gómez") ? "Ana Gómez" : "Ana Silva"
            return ["people": [["name": full, "quote": full, "person": "new"]]]
        })
        let lane = Lane(x, store: v.store)
        for m in [m1, m2] { try await lane.read(m, groups: [people], store: v.store) }
        #expect(try t.load().names[FactsGraph.NameKey(memoryID: m2, surface: "Ana")]?.basis == .named)
        // A second trusted Ana: until it's read again, m2's "Ana" reads as ambiguous; the sweep finds it from alias
        // evidence and asks about that name only.
        try await x.learn([m3], groups: [people])
        #expect(try t.load().names[FactsGraph.NameKey(memoryID: m2, surface: "Ana")]?.basis == .ambiguous)
        let due = try await v.store.writer.write { db in try FactsReconciler.reconcile(db, userAliases: t.user) }
        #expect(due.map(\.key.memoryID) == [m2] && due.first?.due == .init(roles: [], names: ["ana"]))
        try await v.store.writer.write { db in try ProcessingQueue.enqueueFactsSweep(db, now: Date()) }
        try await lane.drain()
        #expect(lane.calls.last.map { $0.memory == m2 && $0.mode == "reconcile" } == true)
        #expect(try t.load().names[FactsGraph.NameKey(memoryID: m2, surface: "Ana")]?.basis == .ambiguous)
        // Asked knowing both: nothing more to ask until the candidates change.
        #expect(try await v.store.writer.write { db in try FactsReconciler.reconcile(db, userAliases: t.user) }.isEmpty)
    }

    @Test func anInvalidAnswerAboutAnAmbiguousNameDoesntLoop() async throws {
        let sib = t.sibling
        let a = try t.memory("My sister Ana Gómez is a nurse.")
        let b = try t.memory("My friend Ana Silva teaches maths.", days: 1)
        let c = try t.memory("Ana recommended flossing.", days: 2)
        let calls = Mutex(0)
        let x = extractor(Scripted { r in
            let m = FactsExtractorTests.memoryText(r.prompt)
            if m.contains("flossing") {
                let n = calls.withLock { $0 += 1; return $0 }
                // The first answer is ambiguous; later ones quote text the memory doesn't have.
                return ["people": [["name": "Ana", "quote": n == 1 ? "Ana recommended" : "Ana said hello", "person": "ambiguous"]]]
            }
            if m.contains("dentist") {
                let silva = FactsExtractorTests.rosterID(r.prompt, "Ana Silva")
                return ["people": [["name": "Ana Silva", "quote": "Ana Silva", "person": silva]],
                        "facts": [FactsExtractorTests.fact("Ana Silva is my dentist", FX.personPredicate { $0.lexicon.contains { $0.words.contains("dentist") } },
                                                           "Ana Silva", entity: silva)]]
            }
            let full = m.contains("Gómez") ? "Ana Gómez" : "Ana Silva"
            return ["people": [["name": full, "quote": full, "person": "new"]], "facts": [FactsExtractorTests.fact(full, sib, full)]]
        })
        let lane = Lane(x, store: v.store)
        for m in [a, b, c] { try await lane.read(m, groups: [people], store: v.store) }
        #expect(calls.withLock { $0 } == 1)
        // A new fact about a candidate: c is asked again, the answer fails validation, the name stays ambiguous, and
        // the next sweep doesn't ask again.
        let d = try t.memory("Ana Silva is my dentist now.", days: 3)
        try await lane.read(d, groups: [people], store: v.store)
        #expect(calls.withLock { $0 } == 2)
        #expect(try t.load().names[FactsGraph.NameKey(memoryID: c, surface: "Ana")]?.basis == .ambiguous)
        try await v.store.writer.write { db in try ProcessingQueue.enqueueFactsSweep(db, now: Date()) }
        try await lane.drain()
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func aMemoryReadWithNothingLearnedIsStillReconciled() async throws {
        let b = boss
        let m1 = try t.memory("My manager called.", days: 5)
        let m2 = try t.memory("Elise Vale is my manager.", days: 1)
        let m3 = try t.memory("Karim Rook is my manager too.", days: 2)
        let x = extractor(Scripted { r in
            let m = FactsExtractorTests.memoryText(r.prompt)
            for n in ["Elise Vale", "Karim Rook"] where m.contains(n) {
                return ["people": [["name": n, "quote": n, "person": "new"]], "facts": [Self.fact(n, b, n)]]
            }
            return ["roles": [["id": "r1", "refers_to": "unknown"]]]
        })
        let lane = Lane(x, store: v.store)
        for m in [m1, m2, m3] { try await lane.read(m, groups: [people], store: v.store) }
        #expect(lane.calls.filter { $0.memory == m1 }.map(\.mode) == ["full", "reconcile"])
        // Archiving carries what it was asked: no new question.
        try await v.store.writer.write { db in
            let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [m1])!
            try db.execute(sql: "UPDATE memory SET version = version + 1, status = 'archived' WHERE id = ?", arguments: [m1])
            try FactStore.versionChanged(db, memoryID: m1, from: version, to: version + 1, textChanged: false, now: Date())
        }
        try await lane.drain()
        #expect(lane.calls.filter { $0.memory == m1 }.count == 2)
    }

    @Test func aLifecycleChangeQueuesTheSweepInItsTransaction() async throws {
        let sweeps = "SELECT COUNT(*) FROM processing_job WHERE kind = 'facts' AND call_group IS NULL AND state = 'queued'"
        let m1 = try t.memory("My manager is Elise Vale.")
        let m2 = try t.memory("Karim Rook is my manager.", days: 1)
        // Before any model reading (the app today), changes queue nothing.
        try await v.store.writer.write { db in try FactStore.bumpRevision(db) }
        #expect(try t.count(sweeps) == 0)
        let b = boss
        try await extractor(Scripted { r in
            let n = FactsExtractorTests.memoryText(r.prompt).contains("Elise") ? "Elise Vale" : "Karim Rook"
            return ["people": [["name": n, "quote": n, "person": "new"]], "facts": [Self.fact(n, b, n)]]
        }).learn([m1, m2], groups: [people])
        #expect(try t.count(sweeps) == 1)                   // queued by the applies, once
        _ = try await v.store.writer.write { db in try db.execute(sql: "UPDATE processing_job SET state = 'done' WHERE kind = 'facts'") }
        _ = try v.store.deleteMemory(id: UUID(uuidString: m2)!, now: t0.plus(days: 2))
        try v.store.purgeMemory(id: UUID(uuidString: m2)!, now: t0.plus(days: 2))
        #expect(try t.count(sweeps) == 1)
    }

    @Test func aModelThatIsntThereLeavesTheReadForLater() async throws {
        struct Down: GenerationProvider {
            let id: ProviderID = "anthropic"
            let locality = Locality.cloud
            let modelID = "down"
            func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
                throw ProviderError.unavailable
            }
        }
        let m1 = try t.memory("My manager called.")
        let lane = Lane(extractor(Down()), store: v.store)
        try await v.store.writer.write { db in
            try ProcessingQueue.enqueueFacts(db, memoryID: UUID(uuidString: m1)!, version: 1, group: t.people, reason: .version, now: Date())
        }
        let job = try #require(try await lane.queue.claim(now: Date()))
        let outcome = try await lane.worker.process(job)
        guard case .later = outcome else { Issue.record("\(outcome)"); return }
        // No model reading is recorded, so the job reads in full when it runs again.
        #expect(try t.count("SELECT COUNT(*) FROM facts_asked WHERE mention_kind = 'read'") == 0)
        #expect(try await lane.worker.plan(m1, group: t.people) == .full)
    }

    @Test func aStaleDecisionWhoseReAskFailedIsntAskedAgainUntilSomethingChanges() async throws {
        let b = boss
        let m1 = try t.memory("Elise Vale is my manager.")
        let m2 = try t.memory("Karim Rook is my manager too.", days: 1)
        let m3 = try t.memory("My manager approved the leave.", days: 5)
        let asked = Mutex(0)
        let x = extractor(Scripted { r in
            let m = FactsExtractorTests.memoryText(r.prompt)
            for n in ["Elise Vale", "Karim Rook", "Nora Pike"] where m.contains(n) {
                return ["people": [["name": n, "quote": n, "person": "new"]], "facts": [Self.fact(n, b, n)]]
            }
            // The first answer picks Elise; every later one names a roster id that doesn't exist.
            return asked.withLock { $0 += 1; return $0 } == 1
                ? ["roles": [["id": "r1", "refers_to": FactsExtractorTests.rosterID(r.prompt, "Elise Vale")]]]
                : ["roles": [["id": "r1", "refers_to": "e99"]]]
        })
        let lane = Lane(x, store: v.store)
        for m in [m1, m2, m3] { try await lane.read(m, groups: [people], store: v.store) }
        #expect(try roleLink(m3).basis == .context)
        // A third holder: the decision is asked again, the answer fails validation, and the next sweep doesn't ask.
        let m4 = try t.memory("Nora Pike is my manager as well.", days: 2)
        try await lane.read(m4, groups: [people], store: v.store)
        #expect(asked.withLock { $0 } == 2)
        try await v.store.writer.write { db in try ProcessingQueue.enqueueFactsSweep(db, now: Date()) }
        try await lane.drain()
        #expect(asked.withLock { $0 } == 2)
        #expect(try roleLink(m3).basis == .candidates)                  // the stale decision doesn't count
    }

    @Test func aPartialAnswerForAVersionNeverReadAppliesWhole() async throws {
        let b = boss
        let m1 = try t.memory("My manager is Elise Vale.")
        // The job planned a partial re-read of an earlier version; the memory was edited before the call.
        try await extractor(Scripted { _ in
            ["people": [["name": "Elise Vale", "quote": "Elise Vale", "person": "new"]], "facts": [Self.fact("My manager is Elise Vale", b, "Elise Vale")]]
        }).learn([m1], groups: [people], kind: "reconciliation", scope: .partial(roles: [0], names: []))
        let g = try t.load()
        #expect(g.facts.contains { $0.predicate == b && g.entities[$0.entity]?.name == "Elise Vale" })
        #expect(try t.count("SELECT COUNT(*) FROM facts_asked WHERE mention_kind = 'read' AND memory_id = '\(m1)'") == 1)
    }

    // MARK: A partial re-read never erases the earlier reading

    /// #110's live run (x09#0): a reconciliation re-read of the memory naming the manager returned quotes that didn't
    /// validate; it replaced the whole reading, Elise Vale was erased, and "My manager" went to Karim Rook at
    /// `sole_known`. The same answers through the lane now keep Elise.
    @Test func theLiveRunsLostManagerStaysFound() async throws {
        let b = boss, emp = t.employer
        let texts = ["m1": "In January 2019 I started a part-time editing job at Fallow Gauge. My manager there is Elise Vale.",
                     "m2": "Also in January 2019 I started a separate part-time editing job at Wren Array, alongside Fallow Gauge. My manager at the second job is Karim Rook.",
                     "m3": "My manager recommended the scenic train route."]
        var ids: [String: String] = [:]
        for (i, k) in ["m1", "m2", "m3"].enumerated() { ids[k] = try t.memory(texts[k]!, days: Double(i)) }
        let firstRead = Mutex(Set<String>())
        let x = extractor(Scripted { r in
            let m = FactsExtractorTests.memoryText(r.prompt)
            guard r.schema.json.contains("\"people\"") else {
                let org = m.contains("Wren") ? "Wren Array" : "Fallow Gauge"
                return m.contains("scenic") ? [:] : ["facts": [FactsExtractorTests.fact("editing job at \(org)", emp, org, start: "2019")]]
            }
            for n in ["Elise Vale", "Karim Rook"] where m.contains(n) {
                let again = !firstRead.withLock { $0.insert(n).inserted }
                // Every later reading of these memories quotes text they don't have (the live run's re-read).
                let q = again ? "Our manager is \(n)" : n
                return ["people": [["name": n, "quote": q, "person": FactsExtractorTests.rosterID(r.prompt, n)]],
                        "facts": [Self.fact(again ? "Our manager is \(n)" : "My manager there is \(n)".replacingOccurrences(of: "there is Karim", with: "at the second job is Karim"), b, n)],
                        "roles": [["id": "r1", "refers_to": "name:\(n)"]]]
            }
            return ["roles": [["id": "r1", "refers_to": "unknown"]]]
        })
        let lane = Lane(x, store: v.store)
        let groups = FactsRegistry.bundled.callGroups.keys.sorted()
        for k in ["m1", "m2", "m3"] { try await lane.read(ids[k]!, groups: groups, store: v.store) }
        // Force the re-read the live run made, as a partial one (roles and names), with the bad answer.
        let m1 = ids["m1"]!
        let g = try t.load()
        let start = try #require(g.rolePhrases(g.memories[m1]!.text).first).start
        try await x.learn([m1], groups: [people], kind: "reconciliation",
                          scope: .partial(roles: [FactStore.scalarOffset(g.memories[m1]!.text, utf16: start)], names: ["elise vale"]))
        let link = try roleLink(m1)
        let who = try name(link.entity)
        #expect(who == "Elise Vale")
        let graph = try t.load()
        #expect(graph.facts.contains { $0.predicate == b && graph.entities[$0.entity]?.name == "Elise Vale" })
        let second = try name(try roleLink(ids["m2"]!).entity)
        #expect(second == "Karim Rook")
        #expect(try roleLink(ids["m3"]!).basis == .candidates)
        // The control: the same answer as a whole reading (#110's re-read) loses her.
        try await x.learn([m1], groups: [people], kind: "reconciliation")
        let lost = try t.load()
        #expect(!lost.facts.contains { $0.predicate == b && lost.entities[$0.entity]?.name == "Elise Vale" })
    }

    @Test func aReReadThatMovesANameReplacesTheReadingOnlyWhenClean() async throws {
        let m1 = try t.memory("My friend Ana Gómez is a nurse.")
        let m2 = try t.memory("Ana sent flowers.", days: 1)
        let m3 = try t.memory("My friend Ana Silva teaches maths.", days: 2)
        try await extractor(Scripted { r in
            let m = FactsExtractorTests.memoryText(r.prompt)
            if m.contains("flowers") { return ["people": [["name": "Ana", "quote": "Ana sent", "person": FactsExtractorTests.rosterID(r.prompt, "Ana Gómez")]]] }
            let full = m.contains("Gómez") ? "Ana Gómez" : "Ana Silva"
            return ["people": [["name": full, "quote": full, "person": "new"]]]
        }).learn([m1, m2, m3], groups: [people])
        func whoIsAna() throws -> String? { try name(try t.load().names[FactsGraph.NameKey(memoryID: m2, surface: "Ana")]?.entity) }
        // Moves Ana to Ana Silva, but something else in the answer was dropped: the earlier rows stay (read as ambiguous).
        let silva: @Sendable (StructuredRequest<FactsJSON>, Bool) -> [String: Any] = { r, clean in
            var p: [[String: Any]] = [["name": "Ana", "quote": "Ana sent", "person": FactsExtractorTests.rosterID(r.prompt, "Ana Silva")]]
            if !clean { p.append(["name": "Bea", "quote": "Bea waved", "person": "new"]) }
            return ["people": p]
        }
        let rowsBefore = try t.count("SELECT COUNT(*) FROM alias_evidence WHERE memory_id = '\(m2)'")
        try await extractor(Scripted { silva($0, false) }).learn([m2], groups: [people], kind: "reconciliation", scope: .partial(roles: [], names: ["ana"]))
        #expect(try t.load().names[FactsGraph.NameKey(memoryID: m2, surface: "Ana")]?.basis == .ambiguous)
        let rowsAfter = try t.count("SELECT COUNT(*) FROM alias_evidence WHERE memory_id = '\(m2)'")
        #expect(rowsBefore == 1 && rowsAfter == 1)                    // Gómez's row stays
        let entities = try t.load().orderedEntities
        #expect(!entities.contains { $0.name == "Bea" })
        try await extractor(Scripted { silva($0, true) }).learn([m2], groups: [people], kind: "reconciliation", scope: .partial(roles: [], names: ["ana"]))
        #expect(try whoIsAna() == "Ana Silva")
    }
}
