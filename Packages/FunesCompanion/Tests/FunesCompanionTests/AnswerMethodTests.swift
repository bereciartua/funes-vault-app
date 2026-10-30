import Foundation
import FunesCore
import FunesProtocol
import Synchronization
import Testing
@testable import FunesCompanion

/// A model that answers search-answer requests by quoting the first memory it was given.
final class QuotingModel: GenerationProvider {
    let id: ProviderID = "anthropic"
    let locality = Locality.cloud
    let modelID = "claude-test"
    let prompts = Mutex<[String]>([])

    func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        prompts.withLock { $0.append(request.prompt) }
        // The first memory's text, between its <text> tags.
        let text = request.prompt.components(separatedBy: "<text>").dropFirst().first?.components(separatedBy: "</text>").first ?? ""
        let quote = String(text.prefix(30))
        let json = #"{"found":"yes","claims":[{"text":"From your note.","citations":[{"ref":"m1","quote":"\#(quote)"}]}]}"#
        return (try JSONDecoder().decode(T.self, from: Data(json.utf8)), ProviderUsage(requests: 1))
    }
}

/// Search answers as the Mac's settings would give them: the real `SearchAnswerer` with a model.
struct RealAnswers: SearchAnswering {
    let answerer: SearchAnswerer
    let model: QuotingModel

    func engine() async -> SearchAnswerEngine? { SearchAnswerEngine(name: "Claude (Claude Code)", locality: .cloud) }

    func answer(_ query: String, ids: [UUID], actor: Actor, via: ActivityEvent.Via) async throws -> SearchAnswer {
        try await answerer.answer(query, ids: ids, router: ModelRouter(classifier: model, onDevice: nil), actor: actor, via: via, now: t0)
    }
}

/// Search answers that wait, fail as told, and record what they were asked and whether they were
/// cancelled.
final class ScriptedAnswers: SearchAnswering, @unchecked Sendable {
    let available: Bool
    let delay: Duration
    let failure: SearchAnswerError?
    let started = Mutex(0)
    let cancelled = Mutex(0)

    init(available: Bool = true, delay: Duration = .zero, failure: SearchAnswerError? = nil) {
        self.available = available
        self.delay = delay
        self.failure = failure
    }

    func engine() async -> SearchAnswerEngine? { available ? SearchAnswerEngine(name: "Ollama", locality: .localServer) : nil }

    func answer(_ query: String, ids: [UUID], actor: Actor, via: ActivityEvent.Via) async throws -> SearchAnswer {
        started.withLock { $0 += 1 }
        do {
            try await Task.sleep(for: delay)
        } catch {
            cancelled.withLock { $0 += 1 }
            throw CancellationError()
        }
        if let failure { throw failure }
        return SearchAnswer(outcome: .noAnswer, claims: [], read: ids.count, withheld: 0, dropped: 0, engine: "ollama/llama",
                            locality: .localServer, duration: .milliseconds(5))
    }
}

/// `memories.answer` and `status.get`'s `searchAnswers` (companion protocol §4, §7; v0.6).
@Suite struct AnswerMethodTests {
    static func harness(_ answers: (any SearchAnswering)?, callTimeout: Duration = CompanionHandlers.callTimeout,
                        answerTimeout: Duration = CompanionHandlers.answerTimeout) throws -> CompanionHarness {
        try CompanionHarness(answers: answers, callTimeout: callTimeout, answerTimeout: answerTimeout)
    }

    static func memory(_ h: CompanionHarness, _ title: String, _ body: String) throws -> Memory {
        try h.store.createMemory(MemoryDraft(title: title, body: body, categoryKeys: ["personal_preferences"], sensitivity: .low), now: t0)
    }

    @Test func statusSaysWhetherTheMacAnswers() async throws {
        let on = try Self.harness(ScriptedAnswers())
        let phone = try await on.pairedPhone()
        #expect(try await on.result(StatusGet.self, EmptyParams(), phone: phone).searchAnswers
                    == SearchAnswersStatus(engine: "Ollama", locality: .localServer))
        let off = try Self.harness(ScriptedAnswers(available: false))
        let other = try await off.pairedPhone()
        #expect(try await off.result(StatusGet.self, EmptyParams(), phone: other).searchAnswers == nil)
        let none = try Self.harness(nil)
        let third = try await none.pairedPhone()
        #expect(try await none.result(StatusGet.self, EmptyParams(), phone: third).searchAnswers == nil)
    }

    @Test func answersFromTheShownResultsAsTheOwner() async throws {
        let model = QuotingModel()
        let log = InMemoryActivityLog()
        let h = try CompanionHarness()
        let answerer = SearchAnswerer(store: h.store, search: SearchService(store: h.store, indexer: nil), activity: log)
        let harness = try Self.harness(RealAnswers(answerer: answerer, model: model))
        let phone = try await harness.pairedPhone()
        let coffee = try Self.memory(h, "Coffee", "Oat milk flat white, no sugar, every morning.")
        let archived = try Self.memory(h, "Old coffee", "Black coffee only.")
        try h.store.archiveMemory(id: archived.id, now: t0)
        let result = try await harness.result(MemoriesAnswer.self, MemoryAnswerParams(query: "coffee order", ids: [archived.id, UUID(), coffee.id]),
                                              phone: phone)
        // Archived and unknown ids are skipped; the claim cites the memory by id, with its quote.
        #expect(result.outcome == .answered && result.read == 1 && result.engine == "Claude (Claude Code)" && result.locality == .cloud)
        #expect(result.claims.first?.citations == [MemoryAnswerResult.Citation(id: coffee.id, quote: "Oat milk flat white, no sugar,")])
        #expect(result.sources == [coffee.id])
        let row = try #require(log.events.last)
        #expect(row.event == "search_answered" && row.actor == "device:\(phone.deviceID!.uuidString.lowercased())" && row.via == .companion)
        // The request carries the ids and the search, never memory text.
        let request = String(decoding: try CompanionRequest(MemoriesAnswer.self, params: MemoryAnswerParams(query: "coffee order",
                                                                                                         ids: [coffee.id])).encoded(), as: UTF8.self)
        #expect(!request.contains("Oat milk") && request.contains(coffee.id.uuidString))
    }

    @Test func badParamsAndAnswersOff() async throws {
        let h = try Self.harness(ScriptedAnswers())
        let phone = try await h.pairedPhone()
        for params in [MemoryAnswerParams(query: "coffee", ids: []), MemoryAnswerParams(query: "coffee", ids: (0..<9).map { _ in UUID() }),
                       MemoryAnswerParams(query: "  ", ids: [UUID()])] {
            await #expect(throws: CompanionError(.invalidInput, message: params.ids.isEmpty || params.ids.count > 8 ? "ids is 1 to 8" : "Bad query")) {
                try await h.result(MemoriesAnswer.self, params, phone: phone)
            }
        }
        let off = try Self.harness(ScriptedAnswers(available: false))
        let other = try await off.pairedPhone()
        await #expect(throws: CompanionError(.answersOff)) {
            try await off.result(MemoriesAnswer.self, MemoryAnswerParams(query: "coffee", ids: [UUID()]), phone: other)
        }
    }

    @Test func errorsHaveTheirCodes() async throws {
        let cases: [(SearchAnswerError, CompanionError)] = [
            (.capReached, CompanionError(.capReached)), (.timeout, CompanionError(.modelTimeout)),
            (.secretInSearch, CompanionError(.modelUnavailable, reason: "secret_in_search")),
            (.invalidOutput, CompanionError(.modelUnavailable, reason: "invalid_output")),
            (.provider(.unauthorized), CompanionError(.modelUnavailable, reason: "not_signed_in")),
            (.provider(.rateLimited(retryAfter: nil)), CompanionError(.modelUnavailable, reason: "plan_limit")),
            (.provider(.server(status: 500)), CompanionError(.modelUnavailable, reason: "provider_error")),
        ]
        for (failure, expected) in cases {
            let h = try Self.harness(ScriptedAnswers(failure: failure))
            let phone = try await h.pairedPhone()
            await #expect(throws: expected) {
                try await h.result(MemoriesAnswer.self, MemoryAnswerParams(query: "coffee", ids: [UUID()]), phone: phone)
            }
        }
    }

    /// Its own deadline: not cut at the usual call limit; at its own, the work is cancelled.
    @Test func itsOwnDeadline() async throws {
        let slow = ScriptedAnswers(delay: .milliseconds(400))
        let h = try Self.harness(slow, callTimeout: .milliseconds(100), answerTimeout: .milliseconds(1_500))
        let phone = try await h.pairedPhone()
        let result = try await h.result(MemoriesAnswer.self, MemoryAnswerParams(query: "coffee", ids: [UUID()]), phone: phone)
        #expect(result.outcome == .noAnswer)

        let stuck = ScriptedAnswers(delay: .seconds(30))
        let late = try Self.harness(stuck, callTimeout: .milliseconds(100), answerTimeout: .milliseconds(300))
        let other = try await late.pairedPhone()
        await #expect(throws: CompanionError(.modelTimeout, message: "Deadline")) {
            try await late.result(MemoriesAnswer.self, MemoryAnswerParams(query: "coffee", ids: [UUID()]), phone: other)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(stuck.cancelled.withLock { $0 } == 1)
    }

    /// One in flight per device: the same device's next Ask cancels the previous one's work.
    @Test func aNewAskFromTheSameDeviceCancelsThePrevious() async throws {
        let answers = ScriptedAnswers(delay: .seconds(2))
        let h = try Self.harness(answers)
        let phone = try await h.pairedPhone()
        async let first = h.call(MemoriesAnswer.self, MemoryAnswerParams(query: "coffee", ids: [UUID()]), phone: phone)
        for _ in 0..<100 where answers.started.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let second = Task { try await h.call(MemoriesAnswer.self, MemoryAnswerParams(query: "tea", ids: [UUID()]), phone: phone) }
        let (_, reply) = try await first
        #expect(throws: CompanionError(.unavailable, message: "Cancelled")) { _ = try reply?.get() }
        #expect(answers.cancelled.withLock { $0 } == 1)
        second.cancel()
        _ = try? await second.value
    }
}
