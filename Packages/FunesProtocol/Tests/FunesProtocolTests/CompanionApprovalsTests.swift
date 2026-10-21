import Foundation
import Testing
@testable import FunesProtocol

/// The approvals methods' types (task 5.6).
@Suite struct CompanionApprovalsTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try CompanionJSON.encoder().encode(value)
        #expect(try CompanionJSON.decoder().decode(T.self, from: data) == value)
    }

    @Test func panelsRoundTrip() throws {
        let row = ApprovalRow(id: UUID(), title: "Coffee", body: "Oat flat white", version: 3, kind: .preference,
                              categories: ["personal_preferences"], sensitivity: .low, weak: false)
        let share = SharePanel(destination: ApprovalDestination(remote: true, vendor: "OpenAI", tunnel: "Tailscale Funnel"),
                               keywords: ["coffee"], purpose: "Order", retention: .session, processors: ["OpenAI"],
                               declaredRetention: nil, rows: [row], withheld: [.aboveSensitivityCeiling: 2])
        try roundTrip(ApprovalDetail(id: UUID(), kind: .share, revision: "abc", agentName: "ChatGPT", agentKind: .chatGPT,
                                     task: "Order my usual", createdAt: now, expiresAt: now + 900, share: share))
        try roundTrip(ApprovalDetail(id: UUID(), kind: .save, revision: "r", agentName: "Cursor", createdAt: now, expiresAt: now + 900,
                                     save: SavePanel(action: .create, title: "T", body: "B", kind: .fact, categories: [],
                                                     sensitivity: nil)))
        try roundTrip(ApprovalDetail(id: UUID(), kind: .access, revision: "r", agentName: "Cursor", createdAt: now, expiresAt: now + 45,
                                     access: AccessPanel(operation: .read, categoryKey: "health", categoryName: "Health",
                                                         allowsOnce: true, asksBeforeSharing: true)))
        try roundTrip(ApprovalListResult(items: [ApprovalSummary(id: UUID(), kind: .share, agentName: "Claude Code", count: 3,
                                                                 createdAt: now, expiresAt: now + 900)]))
        try roundTrip(ApprovalAnswerParams(id: UUID(), revision: "r", choice: .share, memoryIds: [UUID()]))
        try roundTrip(ApprovalSettings(enabled: true, tag: "t", doorbell: .noAccount))
    }

    @Test func withheldIsKeyedByReasonAndToleratesNewOnes() throws {
        let share = SharePanel(destination: ApprovalDestination(remote: false), keywords: [], purpose: nil, retention: .unknown,
                               processors: [], declaredRetention: nil, rows: [], withheld: [.deniedCategory: 1])
        let object = try #require(try JSONSerialization.jsonObject(with: CompanionJSON.encoder().encode(share)) as? [String: Any])
        #expect(object["withheld"] as? [String: Int] == ["denied_category": 1])
        let newer = Data(#"{"destination":{"remote":false},"keywords":[],"retention":"unknown","processors":[],"rows":[],"withheld":{"denied_category":1,"from_the_future":2}}"#.utf8)
        #expect(try CompanionJSON.decoder().decode(SharePanel.self, from: newer).withheld == [.deniedCategory: 1])
    }

    @Test func answersAreValidated() throws {
        let id = UUID()
        #expect(throws: CompanionError.self) { try ApprovalAnswerParams(id: id, revision: "r", choice: .share).validate() }
        #expect(throws: CompanionError.self) { try ApprovalAnswerParams(id: id, revision: "r", choice: .share, memoryIds: []).validate() }
        let twice = UUID()
        #expect(throws: CompanionError.self) {
            try ApprovalAnswerParams(id: id, revision: "r", choice: .share, memoryIds: [twice, twice]).validate()
        }
        #expect(throws: CompanionError.self) { try ApprovalAnswerParams(id: id, revision: "", choice: .deny).validate() }
        #expect(throws: CompanionError.self) {
            try ApprovalAnswerParams(id: id, revision: "r", choice: .deny, memoryIds: [UUID()]).validate()
        }
        try ApprovalAnswerParams(id: id, revision: "r", choice: .share, memoryIds: [UUID()]).validate()
        try ApprovalAnswerParams(id: id, revision: "r", choice: .notNow).validate()
        #expect(ApprovalChoice.allCases.filter { $0.kind == .access } == [.allowOnce, .alwaysAllow, .notNow])
    }

    @Test func aRefNamesExactlyOneThing() throws {
        try ApprovalRef(id: UUID()).validate()
        try ApprovalRef(ring: String(repeating: "a", count: 32)).validate()
        #expect(throws: CompanionError.self) { try ApprovalRef(ring: "not-a-ring").validate() }
        var both = ApprovalRef(id: UUID())
        both.ring = String(repeating: "a", count: 32)
        #expect(throws: CompanionError.self) { try both.validate() }
        #expect(throws: CompanionError.self) {
            try CompanionJSON.decoder().decode(ApprovalRef.self, from: Data("{}".utf8)).validate()
        }
    }

    @Test func newErrorCodesOnTheWire() {
        #expect(CompanionErrorCode.alreadyAnswered.rawValue == "already_answered")
        #expect(CompanionErrorCode.requestExpired.rawValue == "request_expired")
        #expect(CompanionErrorCode.requestChanged.rawValue == "request_changed")
    }
}
