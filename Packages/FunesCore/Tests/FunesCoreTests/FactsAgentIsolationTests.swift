import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Nothing learned reaches an agent (access policy §3.11, vectors T47–T49; security and privacy §13; Phase 13a.2's
/// privacy payload gate). Two vaults hold the same memories, with real retrieval (`SearchService`); one also has learned
/// facts: the entity Lucía, a sister, that m1's "My sister" resolves to (`sole_known`), with Facts' learning on. Every
/// `request_memory` answer, its candidates, the bundle and Activity are the same in both, and carry no learned name.
@Suite(.serialized) struct FactsAgentIsolationTests {
    typealias F = PolicyFixture
    static let martin = Profile(givenName: "Martin", familyName: "Bereciartua", pronouns: "he/him", languages: ["en", "es"])

    struct Vault {
        let v: TestVault
        let search: SearchService
        let disclosures: DisclosureService
        let activity: InMemoryActivityLog
    }

    func vault(learned: Bool) async throws -> Vault {
        let v = try TestVault()
        let activity = InMemoryActivityLog()
        try await v.store.writer.write { db in
            for (i, (title, body)) in [("My sister drinks her mate bitter", "Every morning, with no sugar."),
                                       ("Weekly status update", "Shipped the export fix; next, the importer."),
                                       ("Coffee order", "A flat white, oat milk.")].enumerated() {
                _ = try MemoryStore.insert(db, MemoryDraft(title: title, body: body, categoryKeys: ["personal_preferences"], sensitivity: .low),
                                           actor: .user, now: F.now.plus(days: -2), id: F.id("m\(i + 1)"))
            }
            try AgentStore.insert(db, F.agent, keyDigest: Data(repeating: 1, count: 32))
            var access = try AgentStore.fetch(db, id: F.agentID)!.access
            access.askBeforeSharing = false
            access.allowedCategoryKeys.insert("personal_preferences")
            access.deniedCategoryKeys.remove("personal_preferences")
            try AgentStore.writeAccess(db, agentID: F.agentID, access)
        }
        try await ProfileService(store: v.store, activity: activity).save(Self.martin, now: F.now)
        if learned {
            try await v.store.writer.write { db in
                let sib = FX.personPredicate { $0.lexicon.contains { $0.words.contains("sister") } }
                _ = try FactStore.addManualFact(db, predicate: sib, name: "Lucía", sensitivity: Sensitivity.low.rawValue, now: F.now)
            }
            v.store.factsLane.setLearning(true)
            // m1's "My sister" resolves to Lucía, the only sister known.
            let g = try await v.store.writer.read { db in try FactStore.load(db).graph }
            let m1 = try #require(g.memories.values.first { $0.text.contains("mate") } ?? g.memories[F.id("m1").db] ?? FactsMemory(
                id: F.id("m1").db, text: "My sister drinks her mate bitter\nEvery morning, with no sugar.", written: "2026-01-01"))
            var copy = g
            let ph = try #require(copy.rolePhrases(m1.text).first)
            let (e, basis) = copy.resolve(m1, ph)
            #expect(e.flatMap { copy.entities[$0]?.name } == "Lucía" && basis == .soleKnown)
        }
        let search = SearchService(store: v.store, indexer: nil)
        return Vault(v: v, search: search, disclosures: DisclosureService(store: v.store, retriever: search, activity: activity, pause: FunesPause()),
                     activity: activity)
    }

    func ask(_ x: Vault, _ task: String) async throws -> RequestOutcome {
        var out = try await x.disclosures.request(agentID: F.agentID, MemoryRequest(task: task, keywords: [], purpose: nil, maxTokens: 1200), now: F.now)
        out.requestID = nil
        return out
    }

    /// T47: the same request with learned facts on or off: the same candidates and scores, withheld counts, decision and
    /// bundle; the link to Lucía admits nothing.
    @Test func t47AnAnswerIsTheSameWithLearnedFactsOnOrOff() async throws {
        let off = try await vault(learned: false), on = try await vault(learned: true)
        for task in ["What does Lucía drink?", "What does my sister drink?", "Draft my weekly status update"] {
            let a = try await off.search.candidates(task: task, keywords: [], categories: [])
            let b = try await on.search.candidates(task: task, keywords: [], categories: [])
            #expect(a.map(\.id) == b.map(\.id) && a.map(\.score) == b.map(\.score), "\(task): candidates")
            let ra = try await ask(off, task), rb = try await ask(on, task)
            #expect(ra == rb, "\(task): the answer changed with learned facts")
        }
        // Not vacuous: the sister question reaches m1, so the vault with facts had a linked memory to admit.
        #expect(try await on.search.candidates(task: "What does my sister drink?", keywords: [], categories: []).contains { $0.id == F.id("m1") })
    }

    /// T48 and T49: bundle items are `"<title>: <body>"` only; the profile's name appears only in `profile`; no learned
    /// name, label, basis or why line in any response field or Activity row.
    @Test func t48AndT49NoLearnedNameAnywhereAnAgentOrActivitySees() async throws {
        let on = try await vault(learned: true)
        let out = try await ask(on, "What does my sister drink?")
        let items = out.bundle?.items ?? []
        #expect(!items.isEmpty)
        for item in items {
            let m = try await on.v.store.writer.read { db in try MemoryStore.fetch(db, id: item.memoryID) }
            #expect(item.text == "\(m?.title ?? ""): \(m?.body ?? "")")
        }
        var withoutProfile = out
        withoutProfile.profile = nil
        let response = String(describing: withoutProfile)
        for learned in ["Lucía", "sole_known", "soleKnown", "probably"] { #expect(!response.contains(learned), "\(learned) in the response") }
        #expect(!response.contains("Martin"))
        #expect(String(describing: out.profile).contains("Martin"))
        let rows = String(describing: on.activity.events)
        #expect(!rows.contains("Lucía") && !rows.contains("Martin"))
    }
}
