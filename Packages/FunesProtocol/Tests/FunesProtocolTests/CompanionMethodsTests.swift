import Foundation
import Testing
@testable import FunesProtocol

@Suite struct CompanionMethodsTests {
    func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func requestShapeAndTypedDecoding() throws {
        let capture = CompanionCapture(captureId: UUID(), text: "Ana's birthday is 3 May", createdAt: Date(timeIntervalSince1970: 1_792_000_000),
                                       source: .dictation, note: "from the car")
        let request = CompanionRequest(CapturesSubmit.self, id: "c1", params: CapturesSubmitParams(captures: [capture]))
        let data = try request.encoded()
        let object = try json(data)
        #expect(object["method"] as? String == "captures.submit")
        let params = try #require(object["params"] as? [String: Any])
        let first = try #require((params["captures"] as? [[String: Any]])?.first)
        #expect(first["createdAt"] as? Int64 == 1_792_000_000_000)
        #expect(first["source"] as? String == "dictation")

        let head = try CompanionRequestHead(plaintext: data)
        #expect(head.id == "c1")
        #expect(head.method == .capturesSubmit)
        #expect(try head.params(CapturesSubmit.self).captures == [capture])
        #expect(throws: CompanionError.self) { try head.params(MemoriesGet.self) }
    }

    @Test func methodsWithoutParamsAcceptNone() throws {
        let head = try CompanionRequestHead(plaintext: Data(#"{"id":"1","method":"status.get"}"#.utf8))
        #expect(try head.params(StatusGet.self) == EmptyParams())
    }

    @Test func unknownMethodIsReportedNotThrown() throws {
        let head = try CompanionRequestHead(plaintext: Data(#"{"id":"9","method":"vault.export","params":{}}"#.utf8))
        #expect(head.id == "9")
        #expect(head.method == nil)
    }

    @Test func badParamsAreInvalidInput() throws {
        let head = try CompanionRequestHead(plaintext: Data(#"{"id":"1","method":"memories.get","params":{"id":"nope"}}"#.utf8))
        #expect(throws: CompanionError(.invalidInput, message: "Bad params")) { try head.params(MemoriesGet.self) }
        #expect(throws: CompanionError.self) { try CompanionRequestHead(plaintext: Data("{}".utf8)) }
    }

    @Test func everyMethodHasACall() {
        let calls: [any CompanionCall.Type] = [
            StatusGet.self, CapturesSubmit.self, CategoriesList.self, MemoriesSearch.self, MemoriesGet.self, MemoriesCreate.self,
            MemoriesUpdate.self, MemoriesArchive.self, MemoriesRestore.self, MemoriesDelete.self, InboxList.self, InboxApply.self,
            InboxReject.self, DeviceUnpair.self, ApprovalsList.self, ApprovalsGet.self, ApprovalsAnswer.self,
            ApprovalsSettingsGet.self, ApprovalsSettingsSet.self,
        ]
        #expect(Set(calls.map { $0.method }) == Set(CompanionMethod.allCases))
    }

    @Test func responseResultAndError() throws {
        let ok = CompanionResponse(id: "1", result: MemoryVersion(version: 4))
        #expect(try json(try ok.encoded()).keys.sorted() == ["id", "result"])
        #expect(try CompanionResponse<MemoryVersion>.decode(try ok.encoded()).get() == MemoryVersion(version: 4))

        let secret = CompanionError(.secretLikeContent, message: "Looks like a key", findings: [.awsAccessKey])
        let failed = CompanionResponse<MemoryVersion>(id: "2", error: secret)
        let object = try json(try failed.encoded())
        #expect(object.keys.sorted() == ["error", "id"])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "secret_like_content")
        #expect(error["findings"] as? [String] == ["aws_access_key"])
        #expect(throws: secret) { try CompanionResponse<MemoryVersion>.decode(try failed.encoded()).get() }

        let limited = CompanionError(.rateLimited, retryAfterSeconds: 30)
        #expect(try json(try CompanionJSON.encoder().encode(limited))["retry_after_s"] as? Int == 30)
    }

    @Test func changesDistinguishAbsentFromNull() throws {
        let decoder = CompanionJSON.decoder()
        let absent = try decoder.decode(MemoryChanges.self, from: Data(#"{"title":"New"}"#.utf8))
        #expect(absent.title == "New")
        #expect(absent.expiresAt == nil)
        let cleared = try decoder.decode(MemoryChanges.self, from: Data(#"{"expiresAt":null}"#.utf8))
        #expect(cleared.expiresAt == .some(nil))
        let set = try decoder.decode(MemoryChanges.self, from: Data(#"{"expiresAt":1792000000000}"#.utf8))
        #expect(set.expiresAt == .some(Date(timeIntervalSince1970: 1_792_000_000)))
        #expect(try decoder.decode(MemoryChanges.self, from: Data("{}".utf8)).isEmpty)

        for changes in [absent, cleared, set, MemoryChanges(sensitivity: .secret, expiresAt: .some(nil))] {
            #expect(try decoder.decode(MemoryChanges.self, from: CompanionJSON.encoder().encode(changes)) == changes)
        }
        #expect(String(decoding: try CompanionJSON.encoder().encode(cleared), as: UTF8.self) == #"{"expiresAt":null}"#)
    }

    @Test func limitsAreValidated() throws {
        let capture = CompanionCapture(captureId: UUID(), text: "x", createdAt: Date(), source: .typed)
        #expect(throws: CompanionError.self) { try CapturesSubmitParams(captures: []).validate() }
        #expect(throws: CompanionError.self) {
            try CapturesSubmitParams(captures: Array(repeating: capture, count: 51)).validate()
        }
        try CapturesSubmitParams(captures: Array(repeating: capture, count: 50)).validate()
        #expect(throws: CompanionError.self) { try MemorySearchParams(query: "", limit: 51).validate() }
        #expect(throws: CompanionError.self) { try MemorySearchParams(query: String(repeating: "a", count: 1_001)).validate() }
        try MemorySearchParams(query: "coffee", limit: 50).validate()
    }

    @Test func roundTripsEveryResultType() throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let memory = Memory(title: "Coffee", body: "Oat flat white", kind: .preference, categoryKeys: ["personal_preferences"],
                            sensitivity: .low, source: .manual, createdAt: now, updatedAt: now)
        try roundTrip(CompanionStatus(macName: "Mac", appVersion: "0.2.0", serverTime: now, inboxPending: 3, vaultActive: true))
        try roundTrip(CapturesSubmitResult(accepted: [UUID()], rejected: [CaptureRejection(captureId: UUID(), reason: .secretLikeContent)]))
        try roundTrip(MemoryCategory.builtins.map(CompanionCategory.init))
        try roundTrip(MemorySearchResult(results: [MemorySummary(id: memory.id, title: "Coffee", snippet: "Oat…", kind: .preference,
                                                                 categories: ["personal_preferences"], sensitivity: .low,
                                                                 updatedAt: now)], nextCursor: "c2"))
        try roundTrip(CompanionMemory(memory: memory, provenance: [ProvenanceLabel(at: now, event: "created", label: "Created on Sam's iPhone")],
                                      sharedCount: 2, lastSharedAt: now))
        try roundTrip(MemoryCreated(id: UUID(), version: 1))
        try roundTrip(InboxListResult(items: [InboxItem(id: UUID(), origin: .captureIPhone, action: .create, sourceLabel: "Sam's iPhone",
                                                        title: "T", body: "B", kind: .fact, categories: ["health"],
                                                        sensitivity: .sensitive, createdAt: now)]))
        try roundTrip(MemorySearchParams(query: "q", filters: MemorySearchFilters(categories: ["health"], kinds: [.fact],
                                                                                  sensitivities: [.secret], status: .archived)))
        try roundTrip(MemoryUpdateParams(id: UUID(), version: 3, changes: MemoryChanges(title: "T", expiresAt: .some(nil))))
        try roundTrip(InboxApplyParams(suggestionId: UUID(), edits: MemoryChanges(categories: ["finance"])))
    }

    func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try CompanionJSON.encoder().encode(value)
        #expect(try CompanionJSON.decoder().decode(T.self, from: data) == value)
    }
}
