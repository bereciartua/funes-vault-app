import Foundation
import Testing
@testable import FunesProtocol

/// v0.10's protocol fields (companion protocol §3, §4): `caps`, correction targets, and older ends ignoring what's new.
@Suite struct CompanionFactsTests {
    @Test func capsAreReadPerCallAndUnknownOnesIgnored() throws {
        let with = try CompanionRequest(StatusGet.self, params: EmptyParams(), caps: ["facts", "holograms"]).encoded()
        #expect(try CompanionRequestHead(plaintext: with).showsFacts)
        let without = try CompanionRequest(StatusGet.self, params: EmptyParams()).encoded()
        #expect(try !CompanionRequestHead(plaintext: without).showsFacts)
        // A malformed list counts as none, and the call still decodes.
        let bad = Data(#"{"id":"1","method":"status.get","params":{},"caps":"facts"}"#.utf8)
        let head = try CompanionRequestHead(plaintext: bad)
        #expect(!head.showsFacts && head.method == .statusGet)
    }

    @Test func aMacBeforeCapsDecodesARequestCarryingThem() throws {
        // The request type as a Mac before v0.10 had it: no `caps`.
        struct OldRequest: Decodable { var id: String; var method: String; var params: MemorySearchParams }
        let json = try CompanionRequest(MemoriesSearch.self, params: MemorySearchParams(query: "x"), caps: CompanionCapability.current).encoded()
        let old = try JSONDecoder().decode(OldRequest.self, from: json)
        #expect(old.params.query == "x")
    }

    @Test func anOlderPhoneDecodesTheNewFields() throws {
        // The answer result as a phone before v0.10 had it.
        struct OldClaim: Decodable { var text: String }
        struct OldResult: Decodable { var claims: [OldClaim]; var read: Int }
        let target = FactsCorrectionTarget(what: .name, linkID: "m/e", memoryID: UUID(), token: "t", label: "Not Maria")
        let result = MemoryAnswerResult(outcome: .answered, claims: [.init(text: "Maria drinks mate.", citations: [], inferred: true,
                                                                            factIDs: ["f"], basis: "sole_known", why: "w", corrections: [target])],
                                        read: 1, withheld: 0, dropped: 0, engine: "e", locality: .cloud, durationMs: 1, bridges: 0,
                                        unreadLinked: 1, note: nil, factsRevision: "r")
        let data = try CompanionJSON.encoder().encode(result)
        #expect(try JSONDecoder().decode(OldResult.self, from: data).claims.first?.text == "Maria drinks mate.")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"factIds\"") && text.contains("\"linkId\"") && text.contains("\"memoryId\""))
        #expect(try CompanionJSON.decoder().decode(MemoryAnswerResult.self, from: data) == result)
    }

    @Test func aTargetHasExactlyTheIdItsKindNeeds() throws {
        #expect(throws: Never.self) { try FactsCorrectionTarget(what: .fact, factID: "f", token: "t").validate() }
        #expect(throws: CompanionError.self) { try FactsCorrectionTarget(what: .fact, linkID: "l", token: "t").validate() }
        #expect(throws: CompanionError.self) { try FactsCorrectionTarget(what: .name, linkID: "l", factID: "f", token: "t").validate() }
        #expect(throws: CompanionError.self) { try FactsCorrectionTarget(what: .order, token: "t").validate() }
        #expect(throws: CompanionError.self) { try FactsCorrectionTarget(what: .fact, factID: "f", token: "").validate() }
    }
}
