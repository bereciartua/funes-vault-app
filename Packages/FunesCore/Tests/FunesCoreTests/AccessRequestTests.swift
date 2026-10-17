import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Task 3.6: what the access-request panel's answers do in FunesCore (access policy §7, FR-A-10):
/// a waiting request replaced after Allow Once or Always Allow, and Allow Once for a suggestion.
@Suite struct AccessRequestTests {
    @Test func supersedeReplacesAWaitingRequestQuietly() async throws {
        let fx = try ServiceFixture()
        fx.retriever.set([fx.id("m1")])
        let first = try await fx.request()
        let id = try #require(first.requestID)
        #expect(first.status == .needsApproval)
        try await fx.disclosures.supersede(requestID: id, now: fx.now)
        let (status, reason) = try await fx.status(id)
        #expect(status == .denied && reason == .policyChanged)
        #expect(try await fx.disclosures.pendingRequests(now: fx.now).isEmpty)
        #expect(fx.activity.events.contains { $0.requestID == id && $0.outcome == "replaced" && $0.approval == nil })
        // Only a waiting request can be replaced.
        await #expect(throws: VaultError.invalidState) { try await fx.disclosures.supersede(requestID: id, now: fx.now) }
    }

    @Test func allowOnceLetsOneSuggestionThrough() async throws {
        let fx = try ServiceFixture()
        try fx.setAgent(asksForAccess: true)
        try fx.setAccess { $0.operations = [.suggest]; $0.allowedCategoryKeys = ["communication_style"] }
        let s = SuggestionService(store: fx.store, activity: fx.activity, pause: fx.pause, disclosures: fx.disclosures)
        let input = SuggestInput(title: "Launch plan", body: "Ship the Mac preview first", categories: ["project_context"],
                                 sensitivity: .internal)
        let refused = try await s.suggest(agentID: fx.agentID, input, now: fx.now)
        #expect(refused.status == .denied && refused.reason == .categoryNotAllowed)
        let offer = try #require(refused.accessOffer)
        #expect(offer.categoryKeys == ["project_context"] && offer.operation == .suggest)
        let allowed = try await s.suggest(agentID: fx.agentID, input, now: fx.now, allowOnce: offer)
        #expect(allowed.status == .queued)
        // Once only: the next call is refused again, and the access is unchanged.
        #expect(try await s.suggest(agentID: fx.agentID, input, now: fx.now).status == .denied)
        let access = try #require(try fx.store.agent(id: fx.agentID)).access
        #expect(access.allowedCategoryKeys == ["communication_style"])
    }

    @Test func allowOnceNeverLiftsACeilingOrADenial() async throws {
        let fx = try ServiceFixture()
        try fx.setAccess { $0.operations = [.suggest]; $0.maxSensitivity = .low; $0.deniedCategoryKeys = ["health"] }
        let s = SuggestionService(store: fx.store, activity: fx.activity, pause: fx.pause, disclosures: fx.disclosures)
        let offer = AccessRequestOffer(agentID: fx.agentID, requestID: nil, categoryKeys: ["health"], operation: .suggest)
        let health = SuggestInput(title: "Allergy", body: "Penicillin", categories: ["health"], sensitivity: .low)
        #expect(try await s.suggest(agentID: fx.agentID, health, now: fx.now, allowOnce: offer).reason == .deniedCategory)
        let high = SuggestInput(title: "Plan", body: "Internal plan", categories: ["project_context"], sensitivity: .internal)
        #expect(try await s.suggest(agentID: fx.agentID, high, now: fx.now, allowOnce: offer).reason == .aboveSensitivityCeiling)
        // An offer made for another agent counts for nothing.
        try fx.setAccess { $0.operations = [] }
        let other = AccessRequestOffer(agentID: UUID(), requestID: nil, categoryKeys: [], operation: .suggest)
        let fine = SuggestInput(title: "Tea", body: "Green tea", categories: ["personal_preferences"], sensitivity: .low)
        #expect(try await s.suggest(agentID: fx.agentID, fine, now: fx.now, allowOnce: other).reason == .operationNotAllowed)
    }
}
