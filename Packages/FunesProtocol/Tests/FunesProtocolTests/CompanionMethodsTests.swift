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
            StatusGet.self, CapturesSubmit.self, OverviewGet.self, CategoriesList.self, MemoriesSearch.self, MemoriesAnswer.self, MemoriesGet.self, MemoriesCreate.self,
            MemoriesUpdate.self, MemoriesArchive.self, MemoriesRestore.self, MemoriesDelete.self, InboxList.self, InboxGet.self, InboxApply.self,
            InboxReject.self, InboxRetry.self, InboxKeep.self, InboxReviewAgain.self, DeviceUnpair.self, ApprovalsList.self, ApprovalsGet.self, ApprovalsAnswer.self,
            ApprovalsSettingsGet.self, ApprovalsSettingsSet.self,
        ]
        #expect(Set(calls.map { $0.method }) == Set(CompanionMethod.allCases))
    }

    /// `memories.answer` and `status.get`'s `searchAnswers` (§4, v0.6): field names, the error's
    /// `reason`, and an older Mac's status without `searchAnswers`.
    @Test func answerShape() throws {
        let id = UUID()
        let params = MemoryAnswerParams(query: "coffee", ids: [id])
        let request = String(decoding: try CompanionRequest(MemoriesAnswer.self, params: params).encoded(), as: UTF8.self)
        #expect(request.contains(#""method":"memories.answer""#) && request.contains(#""ids":[""#))
        let result = MemoryAnswerResult(outcome: .noAnswer, claims: [.init(text: "T", citations: [.init(id: id, quote: "a quote here")])],
                                        read: 3, withheld: 1, dropped: 0, engine: "Claude (Claude Code)", locality: .cloud, durationMs: 4_000)
        let json = String(decoding: try CompanionJSON.encoder().encode(result), as: UTF8.self)
        for key in [#""outcome":"no_answer""#, #""locality":"cloud""#, #""durationMs":4000"#, #""quote":"a quote here""#] {
            #expect(json.contains(key), "\(key)")
        }
        let error = String(decoding: try CompanionJSON.encoder().encode(CompanionError(.modelUnavailable, reason: "plan_limit")), as: UTF8.self)
        #expect(error.contains(#""code":"model_unavailable""#) && error.contains(#""reason":"plan_limit""#))
        let older = #"{"macName":"Mac","appVersion":"0.5","serverTime":0,"inboxPending":0,"vaultActive":true}"#
        #expect(try CompanionJSON.decoder().decode(CompanionStatus.self, from: Data(older.utf8)).searchAnswers == nil)
        #expect(throws: CompanionError.self) { try MemoryAnswerParams(query: "coffee", ids: [id, id]).validate() }
    }

    /// `inbox.get` and `inbox.apply`'s mode (§4.2): field names and snake-case modes on the wire.
    @Test func inboxDetailShape() throws {
        let memory = Memory(title: "Ana", body: "Ana's birthday is 3 May", kind: .fact, categoryKeys: ["people"], sensitivity: .low,
                            source: .manual, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let item = InboxItem(id: UUID(), origin: .consolidation, action: .archive, sourceLabel: "Tidy-up", targetMemoryId: memory.id,
                             title: "Ana", body: "Ana's birthday is 3 May", kind: .fact, categories: ["people"], sensitivity: .low,
                             createdAt: Date(timeIntervalSince1970: 0))
        let detail = InboxDetail(item: item, memories: [InboxMemory(role: .survivor, memory: memory)], stale: true,
                                 tidyUp: InboxTidyUp(reason: "A copy", archiveReason: .duplicate,
                                                     kept: [.init(memoryId: memory.id, text: "the date")]),
                                 similar: [InboxSimilar(id: memory.id, title: "Ana")])
        let json = String(decoding: try CompanionJSON.encoder().encode(detail), as: UTF8.self)
        for key in [#""role":"survivor""#, #""archiveReason":"duplicate""#, #""stale":true"#, #""pieces":[]"#, #""text":"the date""#] {
            #expect(json.contains(key), "\(key)")
        }
        #expect(try CompanionJSON.decoder().decode(InboxDetail.self, from: Data(json.utf8)) == detail)
        #expect(detail.memories(.survivor) == [memory])
        let apply = String(decoding: try CompanionJSON.encoder().encode(
            InboxApplyParams(suggestionId: item.id, mode: .keep, keepMemoryId: memory.id)), as: UTF8.self)
        #expect(apply.contains(#""mode":"keep""#) && apply.contains(#""keepMemoryId""#))
        let bothTrue = String(decoding: try CompanionJSON.encoder().encode(InboxApplyMode.bothTrue), as: UTF8.self)
        #expect(bothTrue == #""both_true""#)
    }

    /// `overview.get` (§4): `in` on the wire, dates in milliseconds, counts as JSON objects.
    @Test func overviewShape() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let overview = VaultOverview(
            range: .days30, generatedAt: day, timeZone: "Europe/Madrid", total: 3, thisWeek: VaultOverview.Week(saved: 2, shared: 4),
            days: [VaultOverview.Bucket(date: day, inbound: VaultOverview.Sources(iphone: 2), out: ["a1": 4], refused: 1)],
            rhythm: VaultOverview.Rhythm(start: day, counts: [0, 2]), bySensitivity: ["low": 3],
            agents: [VaultOverview.AgentCount(id: "a1", name: "Claude Code", kind: .claudeCode, shared: 4, requests: 2)])
        let object = try json(try CompanionResponse(id: "1", result: overview).encoded())
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["range"] as? String == "30d")
        #expect(result["generatedAt"] as? Int64 == 1_800_000_000_000)
        let bucket = try #require((result["days"] as? [[String: Any]])?.first)
        #expect((bucket["in"] as? [String: Int])?["iphone"] == 2)
        #expect(bucket["out"] as? [String: Int] == ["a1": 4])
        #expect(result["bySensitivity"] as? [String: Int] == ["low": 3])
        #expect(result["oldestPendingAt"] == nil)
        #expect(try CompanionResponse<VaultOverview>.decode(try CompanionResponse(id: "1", result: overview).encoded()).get() == overview)
        #expect(overview.count(.low) == 3 && overview.days[0].shared == 4 && overview.days[0].inbound.total == 2)
    }

    /// Buckets begin at midnight in the calendar's time zone, weeks on its first weekday.
    @Test func overviewCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1
        let buckets = OverviewCalendar(calendar: calendar)
        // Wednesday 10 November 2027, 01:30 in New York, three days after summer time ended.
        let now = calendar.date(from: DateComponents(year: 2027, month: 11, day: 10, hour: 1, minute: 30))!
        let days = buckets.boundaries(.days30, now: now)
        #expect(days.count == 31)
        #expect(days[29] == calendar.date(from: DateComponents(year: 2027, month: 11, day: 10)))
        #expect(days[30] == calendar.date(from: DateComponents(year: 2027, month: 11, day: 11)))
        #expect(zip(days, days.dropFirst()).allSatisfy { calendar.dateComponents([.day], from: $0, to: $1).day == 1 })
        let weeks = buckets.boundaries(.weeks12, now: now)
        #expect(weeks[11] == calendar.date(from: DateComponents(year: 2027, month: 11, day: 7)))
        #expect(calendar.component(.weekday, from: weeks[0]) == 1)
        let months = buckets.boundaries(.months12, now: now)
        #expect(months.first == calendar.date(from: DateComponents(year: 2026, month: 12, day: 1)))
        #expect(months.last == calendar.date(from: DateComponents(year: 2027, month: 12, day: 1)))
        let rhythm = buckets.dayBoundaries(84, now: now)
        #expect(rhythm.count == 85 && rhythm[83] == days[29])
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
