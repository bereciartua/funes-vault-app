import Foundation
import Synchronization
import Testing
@testable import FunesCore

/// 13e.2: the Swift harness records live calls and replays them by each call's key, so a gate read replays.
@Suite struct FactsHarnessCallsTests {
    @Test func aRecordedCallReplaysByItsKeyAndAMissIsCounted() async throws {
        let scripted = AnswerProvider(modelID: "claude-haiku-5-5") { prompt in
            ["found": "yes", "claims": [["text": "Echo: \(prompt)", "citations": [["ref": "m1", "quote": "quoted words"]]]]]
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "calls-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try FactsHarness.CallRecorder(scripted, file: url)
        func request(_ p: String) -> StructuredRequest<SearchAnswerer.Output> {
            StructuredRequest(instructions: "i", prompt: p, schema: SearchAnswerer.schema)
        }
        let (a, _) = try await recorder.generate(request("one"))
        _ = try await recorder.generate(request("two"))
        #expect(a.claims.first?.text == "Echo: one")
        // The record keeps the key and the output, never the prompt.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("\"prompt\""))
        let replay = try FactsHarness.CallReplay(url)
        let (b, _) = try await replay.generate(request("two"))
        #expect(b.claims.first?.text == "Echo: two")
        await #expect(throws: ProviderError.self) { _ = try await replay.generate(request("three")) }
        await #expect(throws: ProviderError.self) { _ = try await replay.generate(request("two")) }   // used up
        #expect(replay.misses.withLock { $0 } == 2)
        #expect(replay.id == scripted.id && replay.factsAdapter == scripted.factsAdapter)
    }

    @Test func anOutputThatDoesntDecodeIsOneEntryAndARetryReplaysItsOwn() async throws {
        let calls = Mutex<Int>(0)
        let flaky = AnswerProvider(modelID: "claude-haiku-5-5") { _ in
            let n = calls.withLock { v in v += 1; return v }
            return n == 1 ? ["found": "yes", "claims": "not a list"] : ["found": "no", "claims": []]
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "calls-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try FactsHarness.CallRecorder(flaky, file: url)
        let request = StructuredRequest<SearchAnswerer.Output>(instructions: "i", prompt: "same", schema: SearchAnswerer.schema)
        await #expect(throws: (any Error).self) { _ = try await recorder.generate(request) }
        let retry = try await recorder.generate(request)
        #expect(retry.0.found == "no")
        #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 2)
        let replay = try FactsHarness.CallReplay(url)
        await #expect(throws: (any Error).self) { _ = try await replay.generate(request) }
        #expect(try await replay.generate(request).0.found == "no")
        // A record is never written over.
        #expect(throws: (any Error).self) { _ = try FactsHarness.CallRecorder(flaky, file: url) }
    }

    @Test func aFailedCallIsRecordedAndReplaysAsThatFailure() async throws {
        let failing = AnswerProvider(modelID: "claude-haiku-5-5", failure: .timeout)
        let url = FileManager.default.temporaryDirectory.appending(path: "calls-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try FactsHarness.CallRecorder(failing, file: url)
        let request = StructuredRequest<SearchAnswerer.Output>(instructions: "i", prompt: "p", schema: SearchAnswerer.schema)
        await #expect(throws: ProviderError.timeout) { _ = try await recorder.generate(request) }
        // Written as the call ended, not at the end of the run.
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"error\":\"timeout\""))
        let replay = try FactsHarness.CallReplay(url)
        await #expect(throws: ProviderError.timeout) { _ = try await replay.generate(request) }
        #expect(replay.misses.withLock { $0 } == 0)
    }
}
