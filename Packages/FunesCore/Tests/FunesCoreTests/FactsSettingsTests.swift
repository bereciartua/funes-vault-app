import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Settings ▸ AI ▸ Features ▸ Facts (FR-F-01, model providers §4): what the picker offers (every configured model, the
/// ones Funes tested first, ADR-0032 as amended on 2026-11-24), what Facts resolves to, the stored settings, and your
/// names.
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

    /// Haiku tested for every group through the Claude plan and an Anthropic key; Opus through the plan for the people
    /// group only.
    var qualification: FactsQualification {
        FactsQualification(records: groups.flatMap { [record($0, plan("claude-haiku-5-5")), record($0, key)] }
                           + [record(people, plan("claude-opus-5-5"))])
    }

    var settings: AISettings {
        var s = AISettings()
        s.upsert(AIAccount(endpoint: .anthropic(), name: "Anthropic", models: ["claude-haiku-5-5", "claude-sonnet-5-5"]))
        return s
    }

    func names(_ offers: [FactsOffer]) -> [String] { offers.map { "\($0.account)·\($0.model)\($0.tested ? "*" : "")" } }

    /// The Claude plan's untested offers: its suggestions, then its known models, but the tested full id.
    func planRest(tested: [String] = ["claude-haiku-5-5"]) -> [String] {
        ClaudeCodeClient.knownModels.reduce(into: ClaudeCodeClient.suggestedModels) { if !$0.contains($1) { $0.append($1) } }
            .filter { !tested.contains($0) }.map { "claude-code·\($0)" }
    }

    // MARK: Offers

    @Test func whatShipsRecommendsHaikuOnTheClaudePlanAndOffersEveryModel() {
        // 13e.2's records step tested Haiku through Claude Code for both call groups: it's recommended, and every other
        // configured model is offered after it, untested (the API account's adapter has no record).
        let s = settings
        let offers = s.factsOffers(qualification: .bundled, plans: [.claudeCode])
        #expect(names(offers) == ["claude-code·claude-haiku-5-5*", "anthropic·claude-haiku-5-5", "anthropic·claude-sonnet-5-5"]
            + planRest())
        #expect(s.factsProblem(offers: offers, resolution: s.factsResolution(offers: offers), accountProblem: { _ in nil }) == nil)
        #expect(s.factsResolution(offers: offers).chosen?.choice == ModelChoice(account: "claude-code", model: "claude-haiku-5-5"))
    }

    @Test func testedOffersComeFirstAndUntestedOnesStillRun() {
        let offers = settings.factsOffers(qualification: qualification, plans: [.claudeCode])
        // Opus is tested for the people group only, so it isn't recommended, and the plan's list doesn't name its full id.
        let got = names(offers)
        #expect(Array(got.prefix(3)) == ["anthropic·claude-haiku-5-5*", "claude-code·claude-haiku-5-5*", "anthropic·claude-sonnet-5-5"])
        #expect(Set(got.dropFirst(3)) == Set(planRest()) && got.count == 3 + planRest().count)
        // A plan the picker doesn't list (its CLI not found, not chosen) offers nothing.
        #expect(Set(settings.factsOffers(qualification: qualification, plans: []).map(\.account)) == ["anthropic"])
        // Without records, every configured model is still offered.
        #expect(names(settings.factsOffers(qualification: FactsQualification(records: []), plans: [.claudeCode]))
            == ["anthropic·claude-haiku-5-5", "anthropic·claude-sonnet-5-5"] + planRest(tested: []))
        // What an account listed is offered too, after yours.
        var listed = settings
        listed.setDiscovered(["claude-opus-5-5"], for: "anthropic")
        #expect(listed.factsOffers(qualification: qualification, plans: []).map(\.model) == ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
    }

    @Test func anEngineThatDiffersInAnyPartIsntTested() {
        // Another effort for the same model: another adapter, so no record.
        let high = FactsEngine(ClaudeCodeClient(executable: "/usr/bin/false", model: "claude-haiku-5-5", effort: "high"))
        let q = FactsQualification(records: groups.map { record($0, high) })
        #expect(settings.factsOffers(qualification: q).allSatisfy { !$0.tested })
        // Another batching or pipeline revision.
        var other = plan("claude-haiku-5-5")
        other.batching = "one-memory;pipeline=0"
        #expect(settings.factsOffers(qualification: FactsQualification(records: groups.map { record($0, other) })).allSatisfy { !$0.tested })
        // A stale prompt version.
        var stale = record(people, plan("claude-haiku-5-5"))
        stale.promptVersion = "000000"
        let partly = FactsQualification(records: [stale] + groups.filter { $0 != people }.map { record($0, plan("claude-haiku-5-5")) })
        #expect(!partly.tested(plan("claude-haiku-5-5"), registry: reg, promptVersions: versions))
    }

    @Test func aProxyRunsFactsButIsNeverRecommended() throws {
        var s = AISettings()
        s.upsert(AIAccount(endpoint: ProviderEndpoint(id: "anthropic", kind: .anthropic, baseURL: URL(string: "https://proxy.example.com/v1")!),
                           name: "Anthropic", models: ["claude-haiku-5-5"]))
        // Its engine names the same provider id as the real one's, which a record covers, but it isn't the preset's address.
        let offers = s.factsOffers(qualification: qualification, plans: [])
        #expect(names(offers) == ["anthropic·claude-haiku-5-5"])
        #expect(offers.first?.engine == key)
        let built = try FactsClients.make(account: "anthropic", model: "claude-haiku-5-5", settings: s, executable: nil, key: "k")
        #expect(FactsEngine(built) == key)
    }

    @Test func theEngineAnOfferNamesIsTheEngineTheBuiltClientReports() throws {
        var s = settings
        s.upsert(AIAccount(endpoint: .openAI(), name: "OpenAI"))
        s.upsert(AIAccount(endpoint: .ollama(), name: "Ollama"))
        for (account, model) in [("anthropic", "claude-haiku-5-5"), ("openai", "gpt-5-mini"), ("claude-code", "claude-haiku-5-5"),
                                 ("codex", "gpt-5.5"), ("ollama", "qwen3:8b")] {
            let built = try FactsClients.make(account: account, model: model, settings: s, executable: "/usr/bin/false", key: "k")
            #expect(FactsClients.engine(account: account, model: model, settings: s) == FactsEngine(built), "\(account)")
        }
    }

    // MARK: Resolution

    @Test func aTestedModelIsTheDefaultAndAChoiceReadsEveryGroup() {
        var s = settings
        let offers = s.factsOffers(qualification: qualification, plans: [.claudeCode])
        // The default: a tested model on the first account that can run it.
        #expect(s.factsResolution(offers: offers).chosen?.account == "anthropic")
        #expect(s.factsResolution(offers: offers, runnable: { $0 != "anthropic" }).chosen?.choice
            == ModelChoice(account: "claude-code", model: "claude-haiku-5-5"))
        // Without a tested one, Haiku by its id (untested here: an API account); with neither, nothing until a choice.
        let untested = offers.filter { !$0.tested }
        let apiHaiku = FactsOffer(account: "anthropic", model: "claude-haiku-5-5", engine: key, tested: false)
        #expect(s.factsResolution(offers: [apiHaiku] + untested).chosen == apiHaiku)
        #expect(s.factsResolution(offers: untested).chosen == nil)
        // Opus (untested for work) on the plan reads every group: no fallback.
        s.facts.choice = ModelChoice(account: "claude-code", model: "opus")
        let r = s.factsResolution(offers: offers)
        #expect(r.chosen?.model == "opus" && r.chosen?.tested == false)
        #expect(r.engines(reg) == Dictionary(uniqueKeysWithValues: groups.map { ($0, FactsEngine(model: "claude-code/opus", adapter: plan("opus").adapter)) }))
        #expect(FactsResolution().engines(reg).isEmpty)
    }

    @Test func aPinnedChoiceOutlivesItsRecord() {
        // Turning learning on pins the default: the Claude plan's Haiku by its full id, which the plan's list doesn't name.
        var s = settings
        s.facts.choice = ModelChoice(account: "claude-code", model: "claude-haiku-5-5")
        let lapsed = FactsQualification(records: [])
        let offers = s.factsOffers(qualification: lapsed, plans: [.claudeCode])
        let chosen = s.factsResolution(offers: offers).chosen
        #expect(chosen?.choice == s.facts.choice && chosen?.tested == false)
        #expect(s.factsProblem(offers: offers, resolution: s.factsResolution(offers: offers), accountProblem: { _ in nil }) == nil)
    }

    @Test func theProblemNamesWhatsMissing() {
        var s = AISettings()
        // No account or plan here.
        var offers = s.factsOffers(qualification: qualification, plans: [])
        #expect(s.factsProblem(offers: offers, resolution: s.factsResolution(offers: offers), accountProblem: { _ in nil }) == .noModel)
        // A choice whose account is gone (a model the account doesn't list is still offered: it was chosen).
        s = settings
        s.facts.choice = ModelChoice(account: "openai", model: "gpt-5-mini")
        offers = s.factsOffers(qualification: qualification, plans: [])
        #expect(s.factsProblem(offers: offers, resolution: s.factsResolution(offers: offers), accountProblem: { _ in nil }) == .chooseModel)
        // The chosen account can't run now.
        s.facts.choice = nil
        #expect(s.factsProblem(offers: offers, resolution: s.factsResolution(offers: offers), accountProblem: { _ in .noKey })
            == .account("anthropic", .noKey))
    }

    @Test func theRouterGivesTheChosenModelEveryGroupAndDropsAClientWhoseEngineIsntItsOffers() throws {
        let s = settings
        let offers = s.factsOffers(qualification: qualification, plans: [.claudeCode])
        let opus = try #require(offers.first { $0.model == "opus" })
        let haiku = try #require(offers.first { $0.account == "claude-code" && $0.model == "claude-haiku-5-5" })
        func config(_ chosen: FactsOffer, executable: String? = "/usr/bin/false") -> FactsConfiguration {
            FactsConfiguration(settings: s, chosen: .init(offer: chosen, executable: executable, key: nil),
                               cloudLimit: .upTo(.internal), cap: nil, backoff: ProviderBackoff())
        }
        // An untested model reads every group.
        #expect(groups.allSatisfy { config(opus).router().factsModels[$0]?.modelID == "opus" })
        #expect(groups.allSatisfy { config(haiku).router().factsModels[$0]?.modelID == "claude-haiku-5-5" })
        // An offer whose engine the client doesn't report (a changed adapter) reads nothing.
        var tampered = haiku
        tampered.engine.adapter = "claude-code/1;effort=high"
        #expect(config(tampered).router().factsModels.isEmpty)
        // No CLI: no client, so no model.
        #expect(config(haiku, executable: nil).router().factsModels.isEmpty)
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
        let offers = s.factsOffers(qualification: qualification, plans: [.claudeCode])
        #expect(Set(offers.map(\.account)) == ["claude-code"])
        #expect(s.factsResolution(offers: offers).chosen == nil)
        #expect(s.factsProblem(offers: offers, resolution: s.factsResolution(offers: offers), accountProblem: { _ in nil }) == .chooseModel)
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

    /// Facts' settings show a model's display name, derived from its full id; records keep the id.
    @Test func modelIdsReadAsDisplayNames() {
        #expect(FactsModelName.display("claude-haiku-5-5") == "Claude Haiku 5.5")
        #expect(FactsModelName.display("claude-opus-5-5") == "Claude Opus 5.5")
        #expect(FactsModelName.display("claude-sonnet-4") == "Claude Sonnet 4")
        // Other shapes read as written: an alias, a dated id, a local model's tag.
        for id in ["haiku", "gpt-5.6-terra", "gpt-oss-5", "qwen3:8b", "claude-haiku-5-5-20261101", "", "claude--5", "claude--haiku--5", "claude-haiku-五"] {
            #expect(FactsModelName.display(id) == id)
        }
    }
}
