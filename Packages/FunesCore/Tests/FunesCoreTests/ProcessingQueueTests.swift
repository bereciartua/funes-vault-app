import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Phase 6.1.4: the durable processing queue (memory processing §5.2): every ingest path
/// enqueues in its own transaction, one job at a time, resumed at launch, idempotent, retried.
@Suite struct ProcessingQueueTests {
    struct FakeOnDevice: GenerationProvider {
        let id: ProviderID = "apple.foundation"
        let locality = Locality.onDevice
        let modelID = "fake"
        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let json = #"{"title": "On device", "kind": "goal", "categoryKeys": ["personal_preferences"], "sensitivity": "public", "timeLimited": false}"#
            return (try HTTPClient.decode(json, as: T.self), ProviderUsage(requests: 1))
        }
    }

    static func jobs(_ v: TestVault) throws -> [String] {
        try v.store.writer.read { db in try String.fetchAll(db, sql: "SELECT kind || ':' || state FROM processing_job ORDER BY created_at, rowid") }
    }

    @Test func everyIngestPathEnqueuesInItsTransaction() async throws {
        let fx = try ServiceFixture()
        let v = fx.vault
        let captures = CaptureService(store: v.store, activity: fx.activity)
        let suggestions = SuggestionService(store: v.store, activity: fx.activity, pause: fx.pause)
        let mac = try await captures.capture("Buy oat milk", now: t0)
        let phone = try await DeviceService(store: v.store, activity: fx.activity)
            .register(name: "Phone", model: "iPhone", signingPublicKey: Data([1]), hpkePublicKey: Data([2]), now: t0)
        let fromPhone = try await captures.capture("Gym on Tuesdays", origin: .captureIPhone, captureID: UUID(), deviceID: phone.id, now: t0)
        let seed = try await suggestions.seed(SeedQuestion.all[0], answer: "Short answers please", now: t0)
        try fx.setAccess { $0.operations = [.suggest, .write]; $0.askBeforeSaving = false; $0.maxSensitivity = .internal }
        let written = try await suggestions.suggest(agentID: fx.agentID, SuggestionServiceTests.dev, now: t0)
        try fx.setAccess { $0.askBeforeSaving = true }
        let queued = try await suggestions.suggest(agentID: fx.agentID, SuggestionServiceTests.dev, now: t0)
        var correction = SuggestionServiceTests.dev
        correction.targetMemoryID = fx.id("m1")
        try fx.setAccess { $0.allowedCategoryKeys = []; $0.deniedCategoryKeys = [] }
        _ = try await suggestions.suggest(agentID: fx.agentID, correction, now: t0)
        let imports = ImportService(store: v.store, activity: fx.activity)
        let run = try await imports.commit(try await imports.preview([ImportItem(title: "Imported", body: "From ChatGPT")], source: .chatgpt), now: t0)
        let restore = try await imports.commit(try await imports.preview([ImportItem(title: "Restored", body: "From a backup")], source: .funes), now: t0)

        let queue = ProcessingQueue(store: v.store, activity: fx.activity)
        for subject in [mac.suggestionID, fromPhone.suggestionID, seed, written.memoryID!, queued.suggestionID!] + run.suggestionIDs {
            #expect(try await queue.job(subject: subject)?.state == .queued)
        }
        // Not processed again: corrections and a Funes export restore.
        #expect(try await queue.waiting() == 6)
        #expect(try await queue.job(subject: restore.suggestionIDs[0]) == nil)
    }

    @Test func oneAtATimeIdempotentAndResumedAtLaunch() async throws {
        let v = try TestVault()
        let queue = ProcessingQueue(store: v.store, activity: InMemoryActivityLog())
        let subject = UUID()
        try await v.store.writer.write { db in
            try ProcessingQueue.enqueue(db, subject: subject, now: t0)
            try ProcessingQueue.enqueue(db, subject: subject, now: t0)
            try ProcessingQueue.enqueue(db, subject: UUID(), now: t0.plus(minutes: 1))
        }
        #expect(try Self.jobs(v) == ["new_memory:queued", "new_memory:queued"])
        let first = try #require(try await queue.claim(now: t0))
        #expect(first.subject == subject && first.attempts == 1)
        #expect(try await queue.claim(now: t0) == nil)  // one at a time

        // Quit mid-job: at the next launch it's queued again and runs.
        let relaunched = ProcessingQueue(store: try VaultStore.open(directory: v.directory), activity: InMemoryActivityLog())
        #expect(try await relaunched.resume(now: t0) == 1)
        let ran = Mutex<[UUID]>([])
        #expect(try await relaunched.drain(now: { t0 }) { job in
            ran.withLock { $0.append(job.subject) }
            return .done(engine: "rules")
        } == 2)
        #expect(ran.withLock { $0.first } == subject)
        #expect(try Self.jobs(v) == ["new_memory:done", "new_memory:done"])
        // Done stays done: the same subject isn't queued again.
        try await v.store.writer.write { db in try ProcessingQueue.enqueue(db, subject: subject, now: t0) }
        #expect(try await queue.waiting() == 0)
        #expect(try await queue.cleanup(now: t0.plus(days: 31)) == 2)
    }

    @Test func retriesWithBackoffThenFails() async throws {
        let v = try TestVault()
        let log = InMemoryActivityLog()
        let queue = ProcessingQueue(store: v.store, activity: log)
        let subject = UUID()
        try await v.store.writer.write { db in try ProcessingQueue.enqueue(db, subject: subject, now: t0) }
        var now = t0
        for attempt in 1...ProcessingQueue.maxAttempts {
            let job = try #require(try await queue.claim(now: now))
            #expect(job.attempts == attempt)
            try await queue.finish(job, .retry(code: "unavailable"), now: now)
            #expect(try await queue.claim(now: now) == nil)  // not due yet
            now += ProcessingQueue.backoff(attempt)
        }
        #expect(try await queue.job(subject: subject)?.state == .failed)
        #expect(log.events.last?.event == "processing_job" && log.events.last?.outcome == "failed" && log.events.last?.ids == [subject])
        #expect(ProcessingQueue.backoff(1) == 30 && ProcessingQueue.backoff(9) == 3_600)
    }

    /// Exit criterion: iPhone captures are classified like Mac captures, with the "at least" level kept.
    @Test func capturesAreClassifiedByTheJob() async throws {
        let v = try TestVault()
        let log = InMemoryActivityLog()
        let captures = CaptureService(store: v.store, activity: log)
        let phone = try await DeviceService(store: v.store, activity: log)
            .register(name: "Phone", model: "iPhone", signingPublicKey: Data([1]), hpkePublicKey: Data([2]), now: t0)
        let fromPhone = try await captures.capture("Run a marathon next year", origin: .captureIPhone, captureID: UUID(),
                                                   deviceID: phone.id, now: t0)
        let fromMac = try await captures.capture("Learn Portuguese", sensitivityHint: .internal, now: t0)
        let queue = ProcessingQueue(store: v.store, activity: log)
        let processor = NewMemoryProcessor(store: v.store, captures: captures) {
            ModelRouter(classifier: nil, onDevice: FakeOnDevice())
        }
        #expect(try await queue.drain(now: { t0 }, processor.process) == 2)
        let suggestions = SuggestionService(store: v.store, activity: log, pause: FunesPause())
        let phoneSuggestion = try #require(try await suggestions.suggestion(id: fromPhone.suggestionID))
        #expect(phoneSuggestion.title == "On device" && phoneSuggestion.kind == .goal)
        let macSuggestion = try #require(try await suggestions.suggestion(id: fromMac.suggestionID))
        #expect(macSuggestion.sensitivity == .internal)  // the model said public; the user said at least internal
        #expect(try await queue.job(subject: fromPhone.suggestionID)?.engine == "apple.foundation")

        // Classification off: the job finishes and the rules' proposal stays.
        let later = try await captures.capture("Call the bank", now: t0)
        let off = NewMemoryProcessor(store: v.store, captures: captures) { nil }
        #expect(try await queue.drain(now: { t0 }, off.process) == 1)
        #expect(try await suggestions.suggestion(id: later.suggestionID)?.title == "Call the bank")
    }
}
