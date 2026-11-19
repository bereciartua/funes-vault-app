import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Phase 13a.2's Settings ▸ AI ▸ Features ▸ Facts (FR-F-01, model providers §4): what the picker offers from the
/// qualification records, what Facts resolves to, the stored settings, and your names.
@Suite struct FactsSettingsTests {
    let reg = FactsRegistry.bundled
    var versions: [String: String] { FactsQualification.promptVersions(reg) }
    var groups: [String] { reg.callGroups.keys.sorted() }
    var people: String { groups.first { FactsPrompt.hasPeople($0, reg) }! }

    func record(_ group: String, _ engine: FactsEngine, uses: [String] = ["recorded", "linked"]) -> FactsQualification.Record {
        FactsQualification.Record(predicates: reg.groupPredicates(group), uses: uses, callGroup: group, engine: engine,
                                  promptVersion: versions[group]!, registryVersion: reg.fingerprint, gate: "test", recordedAt: "2026-11-18")
    }

    func plan(_ model: String) -> FactsEngine { FactsEngine(ClaudeCodeClient(executable: "/usr/bin/false", model: model)) }
    var key: FactsEngine { FactsEngine(model: "anthropic/claude-haiku-5-5", adapter: "anthropic") }

    /// Haiku for every group through the Claude plan and an Anthropic key; Opus for the people group through the plan.
    var qualification: FactsQualification {
        FactsQualification(records: groups.flatMap { [record($0, plan("claude-haiku-5-5")), record($0, key)] }
                           + [record(people, plan("claude-opus-5-5"))])
    }

    var settings: AISettings {
        var s = AISettings()
        s.upsert(AIAccount(endpoint: .anthropic(), name: "Anthropic", models: ["claude-haiku-5-5"]))
        return s
    }

    // MARK: Offers

    @Test func nothingShipsSoNothingIsOfferedAndThePageSaysWhy() {
        let s = settings
        let offers = s.factsOffers(qualification: .bundled)
        #expect(offers.isEmpty)
        #expect(s.factsProblem(qualification: .bundled, offers: offers, resolution: s.factsResolution(offers: offers),
                               accountProblem: { _ in nil }) == .nothingQualified)
        #expect(s.factsResolution(offers: offers) == FactsResolution())
    }

    @Test func offersAreTheQualifiedEnginesThisAppBuilds() {
        let offers = settings.factsOffers(qualification: qualification)
        let all = Set(groups)
        #expect(offers.map { "\($0.account)·\($0.model)" } == ["anthropic·claude-haiku-5-5", "claude-code·claude-haiku-5-5",
                                                               "claude-code·claude-opus-5-5"])
        #expect(offers[0].groups == all && offers[1].groups == all && offers[2].groups == [people])
        // Whatever the account's own model list says: the plan's "haiku" alias is never a record's full id.
        #expect(!offers.contains { $0.model == "haiku" })
        // A plan the picker doesn't list (its CLI not found, not chosen) offers nothing.
        #expect(settings.factsOffers(qualification: qualification, plans: []).map(\.account) == ["anthropic"])
    }

    @Test func anEngineThatDiffersInAnyPartIsntOffered() {
        // Another effort for the same model: another adapter, so no record.
        let high = FactsEngine(ClaudeCodeClient(executable: "/usr/bin/false", model: "claude-haiku-5-5", effort: "high"))
        let q = FactsQualification(records: groups.map { record($0, high) })
        #expect(settings.factsOffers(qualification: q).isEmpty)
        // Another batching or pipeline revision.
        var other = plan("claude-haiku-5-5")
        other.batching = "one-memory;pipeline=0"
        #expect(settings.factsOffers(qualification: FactsQualification(records: groups.map { record($0, other) })).isEmpty)
        // A record that turns on no recorded use doesn't let a model read a group.
        let linkedOnly = FactsQualification(records: groups.map { record($0, plan("claude-haiku-5-5"), uses: ["linked"]) })
        #expect(settings.factsOffers(qualification: linkedOnly).isEmpty)
    }

    @Test func anHTTPAccountCountsOnlyAtItsProvidersOwnAddress() {
        var s = AISettings()
        s.upsert(AIAccount(endpoint: ProviderEndpoint(id: "anthropic", kind: .anthropic, baseURL: URL(string: "https://proxy.example.com/v1")!),
                           name: "Anthropic"))
        #expect(s.factsOffers(qualification: qualification, plans: []).isEmpty)
        #expect(throws: ProviderError.self) {
            try FactsClients.make(account: "anthropic", model: "claude-haiku-5-5", settings: s, executable: nil, key: "k")
        }
    }

    @Test func theEngineAnOfferNamesIsTheEngineTheBuiltClientReports() throws {
        var s = settings
        s.upsert(AIAccount(endpoint: .openAI(), name: "OpenAI"))
        for (account, model) in [("anthropic", "claude-haiku-5-5"), ("openai", "gpt-5-mini"), ("claude-code", "claude-haiku-5-5"),
                                 ("codex", "gpt-5.5")] {
            let built = try FactsClients.make(account: account, model: model, settings: s, executable: "/usr/bin/false", key: "k")
            #expect(FactsClients.engine(account: account, model: model, settings: s) == FactsEngine(built), "\(account)")
        }
    }

    // MARK: Resolution

    @Test func haikuIsTheDefaultAndOpusFallsBackToHaikuOnItsOwnAccount() {
        var s = settings
        let offers = s.factsOffers(qualification: qualification)
        // The default: Haiku on the first account that can run it.
        #expect(s.factsResolution(offers: offers).chosen?.account == "anthropic")
        #expect(s.factsResolution(offers: offers, runnable: { $0 != "anthropic" }).chosen?.account == "claude-code")
        #expect(s.factsResolution(offers: offers).fallback == nil)
        // Opus on the plan: Haiku reads the rest, on the plan too (one destination).
        s.facts.choice = ModelChoice(account: "claude-code", model: "claude-opus-5-5")
        let r = s.factsResolution(offers: offers)
        #expect(r.chosen?.model == "claude-opus-5-5" && r.fallback?.account == "claude-code" && r.fallback?.model == "claude-haiku-5-5")
        #expect(r.groups == Set(groups))
        // Without Haiku on that account, the rest isn't learned.
        let noPlanHaiku = offers.filter { !($0.account == "claude-code" && $0.model == "claude-haiku-5-5") }
        #expect(s.factsResolution(offers: noPlanHaiku).fallback == nil)
        #expect(s.factsResolution(offers: noPlanHaiku).groups == [people])
    }

    @Test func theProblemNamesWhatsMissing() {
        var s = AISettings()
        // Records exist, but no account here can run them.
        let q = FactsQualification(records: groups.map { record($0, key) })
        var offers = s.factsOffers(qualification: q, plans: [])
        #expect(s.factsProblem(qualification: q, offers: offers, resolution: s.factsResolution(offers: offers),
                               accountProblem: { _ in nil }) == .needsAccount(["claude-haiku-5-5"]))
        // A choice that isn't offered any more.
        s = settings
        s.facts.choice = ModelChoice(account: "anthropic", model: "claude-opus-5-5")
        offers = s.factsOffers(qualification: q)
        #expect(s.factsProblem(qualification: q, offers: offers, resolution: s.factsResolution(offers: offers),
                               accountProblem: { _ in nil }) == .chooseModel)
        // The chosen account can't run now.
        s.facts.choice = nil
        #expect(s.factsProblem(qualification: q, offers: offers, resolution: s.factsResolution(offers: offers),
                               accountProblem: { _ in .noKey }) == .account("anthropic", .noKey))
    }

    @Test func theRouterDropsAClientWhoseEngineIsntItsOffers() throws {
        let s = settings
        let offers = s.factsOffers(qualification: qualification)
        let opus = try #require(offers.first { $0.model == "claude-opus-5-5" })
        let haiku = try #require(offers.first { $0.account == "claude-code" && $0.model == "claude-haiku-5-5" })
        func config(_ chosen: FactsOffer, _ fallback: FactsOffer?) -> FactsConfiguration {
            FactsConfiguration(settings: s, chosen: .init(offer: chosen, executable: "/usr/bin/false", key: nil),
                               fallback: fallback.map { .init(offer: $0, executable: "/usr/bin/false", key: nil) },
                               cloudLimit: .upTo(.internal), cap: nil, backoff: ProviderBackoff())
        }
        let router = config(opus, haiku).router(qualification: qualification)
        #expect(router.factsModels[people]?.modelID == "claude-opus-5-5")
        #expect(groups.filter { $0 != people }.allSatisfy { router.factsModels[$0]?.modelID == "claude-haiku-5-5" })
        // An offer whose engine the client doesn't report (a changed adapter) reads nothing.
        var tampered = haiku
        tampered.engine.adapter = "claude-code/1;effort=high"
        #expect(config(tampered, nil).router(qualification: qualification).factsModels.isEmpty)
        // No CLI: no client, so no model.
        let none = FactsConfiguration(settings: s, chosen: .init(offer: haiku, executable: nil, key: nil), fallback: nil,
                                      cloudLimit: .upTo(.internal), cap: nil, backoff: ProviderBackoff())
        #expect(none.router(qualification: qualification).factsModels.isEmpty)
        // The shipped records: nothing, whatever the configuration.
        #expect(config(opus, haiku).router(qualification: .bundled).factsModels.isEmpty)
    }

    // MARK: Stored settings

    @Test func factsSettingsAreOffByDefaultAndRoundTrip() throws {
        // Settings saved before Facts existed read as off.
        let old = try JSONSerialization.data(withJSONObject: ["version": 2, "searchAnswersOn": true])
        let (loaded, converted) = AISettings.load(old)
        #expect(!converted && loaded.facts == FactsSettings() && !loaded.facts.learn && !loaded.facts.use && loaded.facts.choice == nil)
        var s = settings
        s.facts = FactsSettings(learn: true, use: true, choice: ModelChoice(account: "anthropic", model: "claude-haiku-5-5"))
        #expect(AISettings.load(try JSONEncoder().encode(s)).settings.facts == s.facts)
    }

    @Test func removingTheChosenAccountNeverMovesLearningElsewhere() {
        var s = settings
        s.facts.choice = ModelChoice(account: "anthropic", model: "claude-haiku-5-5")
        s.removeAccount("anthropic")
        // The choice dangles: "Choose a model", nothing resolves, nothing is sent, though the plan offers Haiku too.
        let offers = s.factsOffers(qualification: qualification)
        #expect(offers.map(\.account) == ["claude-code", "claude-code"])
        #expect(s.factsResolution(offers: offers).chosen == nil)
        #expect(s.factsProblem(qualification: qualification, offers: offers, resolution: s.factsResolution(offers: offers),
                               accountProblem: { _ in nil }) == .chooseModel)
    }

    @Test func aPresetsAddressCountsWithATrailingSlashButAnotherHostDoesnt() {
        var e = ProviderEndpoint.anthropic()
        e.baseURL = URL(string: "HTTPS://API.anthropic.com/v1/")!
        e.markedCloud = true
        #expect(FactsClients.isCanonical(e))
        e.baseURL = URL(string: "https://api.anthropic.com.example.net/v1")!
        #expect(!FactsClients.isCanonical(e))
    }

    @Test func usageIsntAFactsInput() {
        var s = settings
        let before = s.factsInputs
        s.addUsage(ProviderUsage(requests: 1, inputTokens: 2, outputTokens: 3), for: "anthropic")
        s.searchAnswersOn.toggle()
        #expect(s.factsInputs == before)
        s.cloudLimit = .upTo(.low)
        #expect(s.factsInputs != before)
    }

    @Test func usedByAndWhatLeavesThisMacListFactsOnlyWhileLearning() {
        var s = settings
        let r = s.factsResolution(offers: s.factsOffers(qualification: qualification))
        #expect(s.factsUse("anthropic", resolution: r) == nil && s.factsSendFact(resolution: r, localities: [:]) == nil)
        s.facts.learn = true
        #expect(s.factsUse("anthropic", resolution: r) == .facts(model: "claude-haiku-5-5"))
        #expect(s.factsSendFact(resolution: r, localities: [:])?.destination == .account("anthropic", model: "claude-haiku-5-5", locality: .cloud))
        #expect(s.factsSendFact(resolution: FactsResolution(), localities: [:]) == nil)
    }

    // MARK: Your names

    @Test func yourNamesAreGivenAndPreferredAloneAndWithTheFamilyName() {
        var p = Profile()
        p.givenName = " Daniela "
        p.familyName = "Ortiz"
        p.preferredName = "Dani"
        #expect(p.factsAliases == ["Daniela", "Daniela Ortiz", "Dani", "Dani Ortiz"])
        // Never the family name alone; no one-letter names; no repeats.
        p.preferredName = "daniela"
        p.givenName = "D"
        #expect(p.factsAliases == ["daniela", "daniela Ortiz"])
        #expect(Profile().factsAliases.isEmpty)
    }
}
