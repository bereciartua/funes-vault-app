import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore
@testable import FunesCompanion

/// A model that says "Maria drinks her mate bitter", quoting the memory titled "My sister drinks her mate bitter".
final class SisterModel: GenerationProvider {
    let id: ProviderID = "anthropic"
    let locality = Locality.cloud
    let modelID = "claude-test"
    let prompts = Mutex<[String]>([])

    func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        prompts.withLock { $0.append(request.prompt) }
        let ref = request.prompt.range(of: "<title>My sister drinks her mate bitter</title>").map { r -> String in
            let before = request.prompt[..<r.lowerBound]
            let tag = before.range(of: "<memory ref=\"", options: .backwards)!
            return String(before[tag.upperBound...].prefix { $0 != "\"" })
        }
        let json = ref.map { #"{"found":"yes","claims":[{"text":"Maria drinks her mate bitter.","citations":[{"ref":"\#($0)","quote":"Every morning, with no sugar."}]}]}"# }
            ?? #"{"found":"no","claims":[]}"#
        return (try JSONDecoder().decode(T.self, from: Data(json.utf8)), ProviderUsage(requests: 1))
    }
}

/// The real answerer on the harness's own vault (set once the harness exists), passing the call's `facts` on.
final class FactsAnswers: SearchAnswering, @unchecked Sendable {
    var answerer: SearchAnswerer!
    let model = SisterModel()

    func engine() async -> SearchAnswerEngine? { SearchAnswerEngine(name: "Claude (Claude Code)", locality: .cloud) }

    func answer(_ query: String, ids: [UUID], actor: Actor, via: ActivityEvent.Via, automatic: Bool) async throws -> SearchAnswer {
        try await answer(query, ids: ids, filter: nil, facts: true, actor: actor, via: via, automatic: automatic)
    }

    func answer(_ query: String, ids: [UUID], filter: MemoryFilter?, facts: Bool, actor: Actor, via: ActivityEvent.Via,
                automatic: Bool) async throws -> SearchAnswer {
        try await answerer.answer(query, ids: ids, filter: filter, facts: facts, router: ModelRouter(classifier: model, onDevice: nil),
                                  actor: actor, via: via, now: t0.addingTimeInterval(86_400))
    }
}

/// Answers that always carry an inferred claim, whatever the call can show: the companion must drop it for an older phone.
struct InferringAnswers: SearchAnswering {
    func engine() async -> SearchAnswerEngine? { SearchAnswerEngine(name: "Ollama", locality: .localServer) }

    func answer(_ query: String, ids: [UUID], actor: Actor, via: ActivityEvent.Via, automatic: Bool) async throws -> SearchAnswer {
        let inference = ClaimInference(basis: "sole_known", factIDs: ["f1"], why: nil, corrections: [])
        return SearchAnswer(outcome: .answered, claims: [SearchAnswer.Claim(text: "Maria drinks mate.", citations: [.init(memoryID: ids[0], quote: "drinks mate")],
                                                                            inference: inference),
                                                         SearchAnswer.Claim(text: "You like mate.", citations: [.init(memoryID: ids[0], quote: "likes mate")])],
                            read: 1, withheld: 0, dropped: 0, engine: "ollama/llama", locality: .localServer, duration: .milliseconds(5))
    }
}

/// Phase 13d's protocol fields (companion protocol §3, §4): `caps`, why lines and corrections on results, inferred claims
/// on answers, `facts.reject`, and `status.get`'s `factsRevision`; an older phone degrades as specified.
@Suite struct FactsAnswerCompanionTests {
    let caps = CompanionCapability.current

    func harness(answers: (any SearchAnswering)? = nil) throws -> CompanionHarness { try CompanionHarness(answers: answers) }

    @Test func withTheCapabilityAResultCarriesItsWhyLineAndCorrections() async throws {
        let h = try harness()
        let phone = try await h.pairedPhone()
        let (_, sister) = try FactsSearchCompanionTests().facts(h)
        let found = try await h.result(MemoriesSearch.self, MemorySearchParams(query: "Maria"), phone: phone, caps: caps)
        let r = try #require(found.results.first { $0.id == sister })
        #expect(r.why == "My sister → Maria")
        let corrections = try #require(r.corrections)
        #expect(corrections.map(\.label) == ["Not Maria", "Not this"])
        #expect(corrections.allSatisfy { !$0.token.isEmpty } && corrections[0].memoryID == sister && corrections[1].memoryID == nil)
        #expect(found.factsRevision != nil)
        // A result plain search keeps has no why line; an unknown capability is ignored.
        #expect(found.results.first { $0.id != sister }?.why == nil)
        let unknown = try await h.result(MemoriesSearch.self, MemorySearchParams(query: "Maria"), phone: phone, caps: ["holograms"])
        #expect(unknown.results.allSatisfy { $0.why == nil && $0.corrections == nil } && unknown.factsRevision == nil)
    }

    @Test func statusCarriesTheFactsRevisionWhileFactsAreInUse() async throws {
        let h = try harness()
        let phone = try await h.pairedPhone()
        #expect(try await h.result(StatusGet.self, EmptyParams(), phone: phone).factsRevision == nil)
        _ = try FactsSearchCompanionTests().facts(h)
        let first = try #require(try await h.result(StatusGet.self, EmptyParams(), phone: phone).factsRevision)
        // A restore renews the epoch: the same counter never repeats a value.
        try await h.store.writer.write { db in
            try db.execute(sql: "UPDATE meta SET value = ? WHERE key = 'facts_epoch'", arguments: [UUID().db])
        }
        let restored = try #require(try await h.result(StatusGet.self, EmptyParams(), phone: phone).factsRevision)
        // "<epoch>.<counter>.<uses>": the epoch changed, the counter didn't, and the value did.
        let a = first.split(separator: "."), b = restored.split(separator: ".")
        #expect(restored != first && a[0] != b[0] && a[1] == b[1] && a[2] == b[2])
    }

    @Test func factsRejectAppliesOnceAndRefusesWhatItCantTake() async throws {
        let h = try harness()
        let phone = try await h.pairedPhone()
        let (_, sister) = try FactsSearchCompanionTests().facts(h)
        let found = try await h.result(MemoriesSearch.self, MemorySearchParams(query: "Maria"), phone: phone, caps: caps)
        let name = try #require(found.results.first { $0.id == sister }?.corrections?.first)
        // Without the capability: invalid_input.
        await #expect(throws: CompanionError(.invalidInput, message: "Needs the facts capability")) {
            _ = try await h.result(FactsReject.self, name, phone: phone)
        }
        // Two ids, or none: invalid_input.
        var two = name
        two.factID = "f"
        await #expect { _ = try await h.result(FactsReject.self, two, phone: phone, caps: caps) } throws: { ($0 as? CompanionError)?.code == .invalidInput }
        let before = try #require(try await h.result(StatusGet.self, EmptyParams(), phone: phone).factsRevision)
        let r1 = try await h.result(FactsReject.self, name, phone: phone, caps: caps)
        #expect(r1.factsRevision != before)
        let row = try #require(h.activity.events.last { $0.event == "facts_corrected" })
        #expect(row.actor.hasPrefix("device:") && row.via == .companion)
        let encoded = String(decoding: try JSONEncoder().encode(h.activity.events), as: UTF8.self)
        #expect(!encoded.contains("Maria"))
        // A repeat changes nothing more; the result drops out of the search.
        let r2 = try await h.result(FactsReject.self, name, phone: phone, caps: caps)
        #expect(r2.factsRevision == r1.factsRevision)
        let again = try await h.result(MemoriesSearch.self, MemorySearchParams(query: "Maria"), phone: phone, caps: caps)
        #expect(!again.results.contains { $0.id == sister })
        // A stale token, and a target that's gone.
        var stale = try #require(found.results.first { $0.id == sister }?.corrections?.last)
        stale.token = "AAAAAAAAAAAAAAAAAAAAAA"
        await #expect { _ = try await h.result(FactsReject.self, stale, phone: phone, caps: caps) } throws: { ($0 as? CompanionError)?.code == .targetChanged }
        let gone = FactsCorrectionTarget(what: .fact, factID: "no-such-fact", token: "x")
        await #expect { _ = try await h.result(FactsReject.self, gone, phone: phone, caps: caps) } throws: { ($0 as? CompanionError)?.code == .notFound }
    }

    @Test func anInferredClaimCarriesItsFieldsOnlyForAPhoneThatCanShowThem() async throws {
        let answers = FactsAnswers()
        let h2 = try harness(answers: answers)
        answers.answerer = SearchAnswerer(store: h2.store, search: h2.services.search, activity: h2.activity)
        let model = answers.model
        let phone = try await h2.pairedPhone()
        let (maria, sister) = try FactsSearchCompanionTests().facts(h2)
        let params = MemoryAnswerParams(query: "What does Maria drink?", ids: [maria, sister])
        let withCaps = try await h2.result(MemoriesAnswer.self, params, phone: phone, caps: caps)
        let claim = try #require(withCaps.claims.first)
        #expect(claim.inferred == true && claim.basis == "sole_known" && claim.factIDs?.isEmpty == false)
        #expect(claim.why == "Maria is your sister" && claim.corrections?.map(\.label) == ["Not Maria", "Not this"])
        #expect(withCaps.factsRevision != nil && withCaps.bridges == 0 && withCaps.unreadLinked == 0)
        let prompt = try #require(model.prompts.withLock { $0.last })
        #expect(prompt.contains("about=\"probably Maria, your sister"))
        // An older phone: 13b's plain selection, no attribute, nothing inferred.
        let old = try await h2.result(MemoriesAnswer.self, params, phone: phone)
        let oldPrompt = try #require(model.prompts.withLock { $0.last })
        #expect(!oldPrompt.contains("about=") && old.claims.allSatisfy { $0.inferred == nil } && old.factsRevision == nil)
        let json = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!json.contains("inferred") && !json.contains("corrections"))
    }

    @Test func anOlderPhoneNeverGetsAnInferredClaim() async throws {
        let h = try harness(answers: InferringAnswers())
        let phone = try await h.pairedPhone()
        let m = try h.store.createMemory(MemoryDraft(title: "Mate", body: "Maria drinks mate.", kind: .fact, categoryKeys: ["personal_preferences"], sensitivity: .low), now: t0)
        let old = try await h.result(MemoriesAnswer.self, MemoryAnswerParams(query: "mate", ids: [m.id]), phone: phone)
        #expect(old.claims.map(\.text) == ["You like mate."] && old.dropped == 1)
        let new = try await h.result(MemoriesAnswer.self, MemoryAnswerParams(query: "mate", ids: [m.id]), phone: phone, caps: caps)
        #expect(new.claims.count == 2 && new.claims[0].inferred == true)
    }
}
