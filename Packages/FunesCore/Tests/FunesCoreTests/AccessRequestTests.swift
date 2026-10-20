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
        let revision = try #require(try fx.store.agent(id: fx.agentID)).revision
        let offer = AccessRequestOffer(agentID: fx.agentID, requestID: nil, categoryKeys: ["health"], operation: .suggest,
                                       agentRevision: revision)
        let health = SuggestInput(title: "Allergy", body: "Penicillin", categories: ["health"], sensitivity: .low)
        #expect(try await s.suggest(agentID: fx.agentID, health, now: fx.now, allowOnce: offer).reason == .deniedCategory)
        let high = SuggestInput(title: "Plan", body: "Internal plan", categories: ["project_context"], sensitivity: .internal)
        #expect(try await s.suggest(agentID: fx.agentID, high, now: fx.now, allowOnce: offer).reason == .aboveSensitivityCeiling)
        // An offer made for another agent counts for nothing.
        try fx.setAccess { $0.operations = [] }
        let current = try #require(try fx.store.agent(id: fx.agentID)).revision
        let other = AccessRequestOffer(agentID: UUID(), requestID: nil, categoryKeys: [], operation: .suggest,
                                       agentRevision: current)
        let fine = SuggestInput(title: "Tea", body: "Green tea", categories: ["personal_preferences"], sensitivity: .low)
        #expect(try await s.suggest(agentID: fx.agentID, fine, now: fx.now, allowOnce: other).reason == .policyChanged)
    }

    /// PR #3 review 4304175697: Allow Once is bound to the revision the offer was made at. Revoking
    /// Suggest while the panel is open makes it fail closed, and nothing is stored.
    @Test func staleAllowOnceIsRefused() async throws {
        let fx = try ServiceFixture()
        try fx.setAgent(asksForAccess: true)
        try fx.setAccess { $0.operations = [.suggest]; $0.allowedCategoryKeys = ["communication_style"] }
        let s = SuggestionService(store: fx.store, activity: fx.activity, pause: fx.pause, disclosures: fx.disclosures)
        let input = SuggestInput(title: "Launch plan", body: "Ship the Mac preview first", categories: ["project_context"],
                                 sensitivity: .internal)
        let offer = try #require(try await s.suggest(agentID: fx.agentID, input, now: fx.now).accessOffer)
        try fx.setAccess { $0.operations = [.read] }
        let out = try await s.suggest(agentID: fx.agentID, input, now: fx.now, allowOnce: offer)
        #expect(out.status == .denied && out.reason == .policyChanged)
        #expect(try await s.pending().isEmpty)
    }

    /// PR #3 review 4304175697: a category grant grants only the category; it never brings back an
    /// operation the agent doesn't have.
    @Test func aCategoryGrantDoesntRestoreSuggest() async throws {
        let fx = try ServiceFixture()
        try fx.setAccess { $0.operations = [.read]; $0.allowedCategoryKeys = ["communication_style"] }
        let s = SuggestionService(store: fx.store, activity: fx.activity, pause: fx.pause, disclosures: fx.disclosures)
        let revision = try #require(try fx.store.agent(id: fx.agentID)).revision
        let offer = AccessRequestOffer(agentID: fx.agentID, requestID: nil, categoryKeys: ["project_context"],
                                       operation: .suggest, agentRevision: revision)
        let input = SuggestInput(title: "Launch plan", body: "Ship the Mac preview first", categories: ["project_context"],
                                 sensitivity: .internal)
        let out = try await s.suggest(agentID: fx.agentID, input, now: fx.now, allowOnce: offer)
        #expect(out.status == .denied && out.reason == .operationNotAllowed)
        #expect(try await s.pending().isEmpty)
    }

    /// PR #3 review 4304175703: a suggestion let through after an access request waits in the Inbox,
    /// even for an agent that may save without asking.
    @Test func allowedSuggestionsQueueEvenForWriters() async throws {
        let fx = try ServiceFixture()
        try fx.setAgent(asksForAccess: true)
        try fx.setAccess {
            $0.operations = [.write]
            $0.askBeforeSaving = false
            $0.allowedCategoryKeys = ["communication_style"]
        }
        let s = SuggestionService(store: fx.store, activity: fx.activity, pause: fx.pause, disclosures: fx.disclosures)
        let input = SuggestInput(title: "Launch plan", body: "Ship the Mac preview first", categories: ["project_context"],
                                 sensitivity: .internal)
        let offer = try #require(try await s.suggest(agentID: fx.agentID, input, now: fx.now).accessOffer)
        let once = try await s.suggest(agentID: fx.agentID, input, now: fx.now, allowOnce: offer, alwaysQueue: true)
        #expect(once.status == .queued && once.memoryID == nil)
        try fx.setAccess { $0.allowedCategoryKeys.insert("project_context") }  // Always Allow
        let always = try await s.suggest(agentID: fx.agentID, input, now: fx.now, alwaysQueue: true)
        #expect(always.status == .queued && always.memoryID == nil)
        #expect(try fx.vault.count("SELECT count(*) FROM memory WHERE title = 'Launch plan'") == 0)
        // Without the retry flag, the same agent's ordinary call still saves directly.
        #expect(try await s.suggest(agentID: fx.agentID, input, now: fx.now).status == .saved)
    }

    /// UX review F3: an offer the user never answered (the panel ran out or was withdrawn) doesn't
    /// use up the hour; Not Now still does.
    @Test func anUnansweredOfferCanBeMadeAgain() async throws {
        let fx = try ServiceFixture()
        try fx.setAgent(asksForAccess: true)
        try fx.setAccess { $0.operations = [.suggest]; $0.allowedCategoryKeys = ["communication_style"] }
        let s = SuggestionService(store: fx.store, activity: fx.activity, pause: fx.pause, disclosures: fx.disclosures)
        let input = SuggestInput(title: "Launch plan", body: "Ship the Mac preview first", categories: ["project_context"],
                                 sensitivity: .internal)
        let offer = try #require(try await s.suggest(agentID: fx.agentID, input, now: fx.now).accessOffer)
        #expect(try await s.suggest(agentID: fx.agentID, input, now: fx.now.plus(minutes: 1)).accessOffer == nil)
        fx.disclosures.releaseOffer(offer)
        #expect(try await s.suggest(agentID: fx.agentID, input, now: fx.now.plus(minutes: 2)).accessOffer != nil)
    }
}
