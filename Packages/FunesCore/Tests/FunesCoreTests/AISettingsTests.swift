import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// Phase 11.1 (ADR-0030 §6, model providers §4, FR-AI-05/06/12/16): accounts and plans with several
/// chat models, the three kinds of job choice, following and unresolved choices, Used by, removal,
/// usage, what re-embeds, the privacy summary's facts, and the one-time conversion of the v1
/// `AIModels` JSON.
@Suite struct AISettingsTests {
    static let anthropic = AIAccount(endpoint: .anthropic(), name: "Anthropic",
                                     models: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
    static let ollama = AIAccount(endpoint: .ollama(), name: "Ollama", models: ["llama3.2"])

    static func settings() -> AISettings {
        var s = AISettings()
        s.upsert(anthropic)
        s.upsert(ollama)
        return s
    }

    static func model(_ account: String, _ model: String?) -> JobChoice { .model(ModelChoice(account: account, model: model)) }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "fixtures/ai-settings"))
        return try Data(contentsOf: url)
    }

    static let keyed: @Sendable (String) -> Bool = { $0 == "anthropic" }
    static let noBlocks: @Sendable (ProviderID) -> Bool = { _ in false }

    // MARK: Choices

    @Test func threeModelsOnOneAccountOnePerJob() {
        var s = Self.settings()
        s.setChoice(Self.model("anthropic", "claude-haiku-5-5"), for: .newMemories)
        s.setChoice(Self.model("anthropic", "claude-opus-5-5"), for: .tidyUp)
        s.setChoice(Self.model("anthropic", "claude-sonnet-5-5"), for: .searchAnswers)
        #expect(s.resolve(.newMemories) == Resolution(model: .model(account: "anthropic", model: "claude-haiku-5-5"), follows: false))
        #expect(s.resolve(.tidyUp) == Resolution(model: .model(account: "anthropic", model: "claude-opus-5-5"), follows: false))
        #expect(s.resolve(.searchAnswers) == Resolution(model: .model(account: "anthropic", model: "claude-sonnet-5-5"), follows: false))
        #expect(s.usedBy("anthropic") == [.job(.newMemories, model: "claude-haiku-5-5", follows: false),
                                          .job(.tidyUp, model: "claude-opus-5-5", follows: false),
                                          .job(.searchAnswers, model: "claude-sonnet-5-5", follows: false)])
        #expect(s.usedBy("ollama").isEmpty)
    }

    @Test func defaultsFollowNewMemoriesAndTheTidyUpNeverUsesOnDevice() {
        var s = Self.settings()
        #expect(s.resolve(.newMemories).model == .onDevice)
        #expect(s.resolve(.tidyUp) == Resolution(model: .rules, follows: true))
        #expect(s.resolve(.searchAnswers) == Resolution(model: .onDevice, follows: true))
        // Choices a job can't have read as its default.
        s.tidyUp = .onDevice
        s.newMemories = .followsNewMemories
        #expect(s.choice(.tidyUp) == .followsNewMemories)
        #expect(s.choice(.newMemories) == .onDevice)

        s.setChoice(Self.model("claude-code", "haiku"), for: .newMemories)
        #expect(s.resolve(.tidyUp) == Resolution(model: .model(account: "claude-code", model: "haiku"), follows: true))
        #expect(s.resolve(.searchAnswers) == Resolution(model: .model(account: "claude-code", model: "haiku"), follows: true))
        #expect(s.usedBy("claude-code") == [.job(.newMemories, model: "haiku", follows: false),
                                            .job(.tidyUp, model: "haiku", follows: true),
                                            .job(.searchAnswers, model: "haiku", follows: true)])
        s.setChoice(.onDevice, for: .searchAnswers)
        #expect(s.resolve(.searchAnswers) == Resolution(model: .onDevice, follows: false))
    }

    @Test func anUnresolvedChoiceNeverBorrowsAModel() {
        var s = Self.settings()
        s.setChoice(Self.model("anthropic", "claude-haiku-5-5"), for: .newMemories)
        s.setChoice(Self.model("ollama", nil), for: .searchAnswers)
        #expect(s.resolve(.searchAnswers).model == .unresolved(account: "ollama"))
        #expect(s.problem(.searchAnswers, hasKey: Self.keyed, planStatus: [:], blocked: Self.noBlocks, onDeviceAvailable: true)
            == .chooseModel)
        // Following an unresolved New memories stays unresolved: the tidy-up runs its rules.
        s.setChoice(Self.model("ollama", nil), for: .newMemories)
        #expect(s.resolve(.tidyUp) == Resolution(model: .unresolved(account: "ollama"), follows: true))
        #expect(s.usedBy("ollama").contains(.job(.tidyUp, model: nil, follows: true)))
    }

    /// A choice of an account that's gone: New memories goes back to Apple on-device; the others
    /// stay unresolved rather than following New memories' cloud model (fail closed).
    @Test func aChoiceOfAMissingAccountNeverStartsFollowing() {
        var s = Self.settings()
        s.setChoice(Self.model("anthropic", "claude-haiku-5-5"), for: .newMemories)
        s.newMemories = Self.model("gone", "x")
        #expect(s.resolve(.newMemories).model == .onDevice)
        s.setChoice(Self.model("anthropic", "claude-haiku-5-5"), for: .newMemories)
        s.tidyUp = Self.model("gone", "x")
        s.searchAnswers = Self.model("gone", "x")
        #expect(s.resolve(.tidyUp) == Resolution(model: .unresolved(account: "gone"), follows: false))
        #expect(s.resolve(.searchAnswers) == Resolution(model: .unresolved(account: "gone"), follows: false))
        #expect(s.problem(.tidyUp, hasKey: Self.keyed, planStatus: [:], blocked: Self.noBlocks, onDeviceAvailable: true) == .chooseModel)
    }

    // MARK: Problems and pickers

    @Test func problemsComeFromConfigurationOnly() {
        var s = Self.settings()
        s.setChoice(Self.model("anthropic", "claude-haiku-5-5"), for: .newMemories)
        #expect(s.problem(.newMemories, hasKey: { _ in false }, planStatus: [:], blocked: Self.noBlocks, onDeviceAvailable: true)
            == .account("anthropic", .noKey))
        #expect(s.problem(.newMemories, hasKey: Self.keyed, planStatus: [:], blocked: Self.noBlocks, onDeviceAvailable: true) == nil)
        // A local server needs no key; OpenAI's own endpoint does.
        #expect(s.problem(account: "ollama", hasKey: { _ in false }, planStatus: [:], blocked: Self.noBlocks) == nil)
        s.upsert(AIAccount(endpoint: .openAI(), name: "OpenAI", models: ["gpt-5-mini"]))
        #expect(s.problem(account: "openai", hasKey: { _ in false }, planStatus: [:], blocked: Self.noBlocks) == .noKey)

        s.setChoice(Self.model("codex", "gpt-6-luna"), for: .searchAnswers)
        let status: [PlanKind: SubscriptionStatus] = [.codex: .fileReadsNotAllowed(version: "1.0"), .claudeCode: .notSignedIn(version: "2")]
        #expect(s.problem(.searchAnswers, hasKey: Self.keyed, planStatus: status, blocked: Self.noBlocks, onDeviceAvailable: true)
            == .account("codex", .needsFileReadOK))
        #expect(s.problem(account: "claude-code", hasKey: Self.keyed, planStatus: status, blocked: Self.noBlocks) == .notSignedIn)
        // Apple on-device, where Apple Intelligence isn't available.
        s.setChoice(.onDevice, for: .searchAnswers)
        #expect(s.problem(.searchAnswers, hasKey: Self.keyed, planStatus: [:], blocked: Self.noBlocks, onDeviceAvailable: false)
            == .onDeviceUnavailable)
        #expect(s.problem(.tidyUp, hasKey: Self.keyed, planStatus: [:], blocked: Self.noBlocks, onDeviceAvailable: false) == nil)
    }

    @Test func cliBlockingIsPerAccountAcrossItsModels() {
        var s = Self.settings()
        s.setChoice(Self.model("claude-code", "haiku"), for: .newMemories)
        s.setChoice(Self.model("claude-code", "opus"), for: .tidyUp)
        let blocked: (ProviderID) -> Bool = { $0 == ClaudeCodeClient.providerID }
        let ready: [PlanKind: SubscriptionStatus] = [.claudeCode: .ready(version: "2.1")]
        for job in [AIJob.newMemories, .tidyUp] {
            #expect(s.problem(job, hasKey: Self.keyed, planStatus: ready, blocked: blocked, onDeviceAvailable: true)
                == .account("claude-code", .paused))
        }
    }

    @Test func pickersListEveryAccountAndAPlanWhenFoundOrChosen() {
        var s = Self.settings()
        s.upsert(AIAccount(endpoint: .lmStudio(), name: "LM Studio"))
        var sections = s.pickerSections(.newMemories, installedPlans: [.claudeCode], hasKey: { _ in false }, planStatus: [:],
                                        blocked: Self.noBlocks)
        #expect(sections.map(\.account) == ["anthropic", "ollama", "lmstudio", "claude-code"])
        #expect(sections[0].problem == .noKey)
        #expect(sections[2].models.isEmpty)
        #expect(sections[3].models == ["haiku", "opus"])
        // Codex isn't found but is the current choice, so it stays listed with why.
        s.setChoice(Self.model("codex", "gpt-6-luna"), for: .newMemories)
        sections = s.pickerSections(.newMemories, installedPlans: [], hasKey: Self.keyed, planStatus: [.codex: .notInstalled],
                                    blocked: Self.noBlocks)
        #expect(sections.last == PickerSection(account: "codex", models: ["gpt-6-luna", "gpt-5.6-terra"], problem: .notInstalled))
    }

    // MARK: Models

    @Test func modelsAreTrimmedUniqueAndAPlanStartsWithItsSuggestions() {
        var s = Self.settings()
        #expect(s.plan(.claudeCode).models == ["haiku", "opus"])
        let added = s.addModel("  sonnet ", to: "claude-code")
        let again = s.addModel("sonnet", to: "claude-code")
        let blank = s.addModel("  ", to: "ollama")
        let nowhere = s.addModel("x", to: "gone")
        #expect(added && !again && !blank && !nowhere)
        #expect(s.plan(.claudeCode).models == ["haiku", "opus", "sonnet"])
        s.upsert(AIAccount(endpoint: .lmStudio(), name: "LM Studio", models: [" qwen ", "qwen", ""]))
        #expect(s.account("lmstudio")?.models == ["qwen"])
    }

    @Test func removingAChatModelResetsItsDirectJobsAndNamesFollowers() {
        var s = Self.settings()
        s.setChoice(Self.model("anthropic", "claude-haiku-5-5"), for: .newMemories)
        s.setChoice(Self.model("anthropic", "claude-opus-5-5"), for: .tidyUp)
        s.embedding = EmbeddingChoice(provider: "ollama", model: "llama3.2")
        let effect = s.removalEffect(model: "claude-haiku-5-5", from: "anthropic")
        #expect(effect == RemovalEffect(direct: [.newMemories], followers: [.searchAnswers]))
        let removed = s.removeModel("claude-haiku-5-5", from: "anthropic")
        #expect(removed == effect)
        #expect(s.choice(.newMemories) == .onDevice)
        #expect(s.choice(.searchAnswers) == .followsNewMemories)
        #expect(s.choice(.tidyUp) == Self.model("anthropic", "claude-opus-5-5"))
        #expect(s.account("anthropic")?.models == ["claude-sonnet-5-5", "claude-opus-5-5"])

        let removedAgain = s.removeModel("claude-opus-5-5", from: "anthropic")
        #expect(removedAgain == RemovalEffect(direct: [.tidyUp]))
        #expect(s.choice(.tidyUp) == .followsNewMemories)
        // A chat model's removal never touches the second index, even one with the same name.
        let removedLast = s.removeModel("llama3.2", from: "ollama")
        #expect(removedLast == RemovalEffect())
        #expect(s.embedding == EmbeddingChoice(provider: "ollama", model: "llama3.2"))
    }

    @Test func aPlanKeepsItsLastModel() {
        var s = Self.settings()
        s.removeModel("haiku", from: "claude-code")
        #expect(!s.canRemove(model: "opus", from: "claude-code"))
        let removed = s.removeModel("opus", from: "claude-code")
        #expect(removed == RemovalEffect())
        #expect(s.plan(.claudeCode).models == ["opus"])
        #expect(s.canRemove(model: "llama3.2", from: "ollama"))
    }

    @Test func removingAnAccountResetsItsJobsUsageAndSecondIndex() {
        var s = Self.settings()
        s.setChoice(Self.model("ollama", "llama3.2"), for: .newMemories)
        s.setChoice(Self.model("ollama", "llama3.2"), for: .searchAnswers)
        s.embedding = EmbeddingChoice(provider: "ollama", model: "qwen3-embedding:0.6b")
        s.addUsage(ProviderUsage(requests: 3, inputTokens: 10, outputTokens: 2), for: "ollama")
        let effect = s.removalEffect(account: "ollama")
        #expect(effect == RemovalEffect(direct: [.newMemories, .searchAnswers], followers: [.tidyUp], secondIndex: true))
        let removed = s.removeAccount("ollama")
        #expect(removed == effect)
        #expect(s.account("ollama") == nil && s.usage["ollama"] == nil && s.embedding == nil)
        #expect(s.choice(.newMemories) == .onDevice && s.choice(.searchAnswers) == .followsNewMemories)
        // Plans aren't removed.
        let removedAgain = s.removeAccount("claude-code")
        #expect(removedAgain == RemovalEffect())
    }

    // MARK: Usage

    @Test func usageIsPerAccountAcrossModels() {
        var s = Self.settings()
        s.addUsage(ProviderUsage(requests: 1, inputTokens: 100, outputTokens: 10), for: "anthropic")
        s.addUsage(ProviderUsage(requests: 2, inputTokens: 50, outputTokens: 5), for: "anthropic")
        s.addUsage(ProviderUsage(requests: 0, inputTokens: 9, outputTokens: 9), for: "ollama")
        s.addUsage(ProviderUsage(requests: 4, inputTokens: 40, outputTokens: 4), for: "claude-code")
        #expect(s.usage["anthropic"] == ProviderUsage(requests: 3, inputTokens: 150, outputTokens: 15))
        #expect(s.usage["ollama"] == nil)
        s.resetUsage(for: "anthropic")
        #expect(s.usage["anthropic"] == nil && s.usage["claude-code"]?.requests == 4)
    }

    // MARK: What re-embeds

    @Test func onlyTheSecondIndexsInputsReembed() {
        var s = Self.settings()
        s.embedding = EmbeddingChoice(provider: "ollama", model: "nomic-embed-text")
        let before = s.embeddingInputs
        // Renaming its account or editing its chat models doesn't.
        var renamed = Self.ollama
        renamed.name = "My Ollama"
        renamed.models = ["llama3.2", "qwen3:4b"]
        s.upsert(renamed)
        #expect(s.embeddingInputs == before)
        // Another account's address doesn't either.
        var moved = Self.anthropic
        moved.endpoint.baseURL = URL(string: "https://proxy.example.com/v1")!
        s.upsert(moved)
        #expect(s.embeddingInputs == before)
        // Its address, its cloud flag, the cloud limit, a calibration and the choice do.
        var t = s
        var address = renamed
        address.endpoint.baseURL = URL(string: "http://192.168.1.4:11434/v1")!
        t.upsert(address)
        #expect(t.embeddingInputs != before)
        t = s
        var cloud = renamed
        cloud.endpoint.markedCloud = true
        t.upsert(cloud)
        #expect(t.embeddingInputs != before)
        t = s
        t.cloudLimit = .upTo(.low)
        #expect(t.embeddingInputs != before)
        t = s
        t.calibrations[OpenAICompatibleEmbedder.modelID(provider: "ollama", model: "nomic-embed-text")] =
            CalibratedThresholds(dimensions: 768, vault: 0.6, retrieval: 0.5)
        #expect(t.embeddingInputs != before)
        t = s
        t.embedding?.embedsAgentTasks = false
        #expect(t.embeddingInputs != before)
    }

    @Test func calibrationIdsStayAccountSlashModel() {
        #expect(OpenAICompatibleEmbedder.modelID(provider: "ollama", model: "nomic-embed-text") == "ollama/nomic-embed-text")
    }

    @Test func theTidyUpsAutoApplyLevelFollowsItsChosenModel() {
        var s = Self.settings()
        s.setChoice(Self.model("anthropic", "claude-haiku-5-5"), for: .newMemories)
        #expect(s.resolve(.tidyUp).model.model.map(TidyUpAutoApply.reached(model:)) == .exceptConflicts)
        s.upsert(AIAccount(endpoint: .openAI(), name: "OpenAI", models: ["gpt-6-luna", "gpt-5.6-terra"]))
        s.setChoice(Self.model("openai", "gpt-5.6-terra"), for: .tidyUp)
        #expect(s.resolve(.tidyUp).model.model.map(TidyUpAutoApply.reached(model:)) == .duplicatesOnly)
        s.setChoice(Self.model("openai", "gpt-6-luna"), for: .tidyUp)
        #expect(s.resolve(.tidyUp).model.model.map(TidyUpAutoApply.reached(model:)) == .off)
    }

    /// The engine `status.get` names is the account and the model, so a model change on the same
    /// account, directly or through New memories, is a change the iPhone sees.
    @Test func aModelChangeOnTheSameAccountChangesTheAnsweringModel() {
        var s = Self.settings()
        s.searchAnswersOn = true
        s.setChoice(Self.model("claude-code", "haiku"), for: .newMemories)
        let first = s.resolve(.searchAnswers).model
        s.setChoice(Self.model("claude-code", "opus"), for: .newMemories)
        let followed = s.resolve(.searchAnswers).model
        s.setChoice(Self.model("claude-code", "haiku"), for: .searchAnswers)
        let direct = s.resolve(.searchAnswers).model
        #expect(first.account == followed.account && followed.account == direct.account)
        #expect(first != followed && followed != direct)
    }

    // MARK: What AI features send

    @Test func sendFactsLocalOnly() {
        var s = Self.settings()
        s.searchAnswersOn = true
        let facts = s.sendFacts(proposals: true, split: true, tidyUpScheduled: true, localities: [:])
        // Apple on-device can't split, and the tidy-up with no model sends nothing.
        #expect(facts == [SendFact(job: .newMemories(splits: false), destination: .onDevice),
                          SendFact(job: .searchAnswers(.ask), destination: .onDevice)])
        s.searchAnswersOn = false
        #expect(s.sendFacts(proposals: false, split: false, tidyUpScheduled: false, localities: [:]).isEmpty)
    }

    @Test func sendFactsAPlanAndAnAPIKey() {
        var s = Self.settings()
        s.setChoice(Self.model("claude-code", "haiku"), for: .newMemories)
        s.setChoice(Self.model("ollama", "llama3.2"), for: .tidyUp)
        s.searchAnswersOn = true
        s.searchAnswersTrigger = .questions
        s.setChoice(Self.model("anthropic", "claude-opus-5-5"), for: .searchAnswers)
        let facts = s.sendFacts(proposals: true, split: false, tidyUpScheduled: true, localities: ["ollama": .localServer])
        #expect(facts == [
            SendFact(job: .newMemories(splits: false), destination: .account("claude-code", model: "haiku", locality: .cloud)),
            SendFact(job: .tidyUp(scheduled: true), destination: .account("ollama", model: "llama3.2", locality: .localServer)),
            SendFact(job: .searchAnswers(.questions), destination: .account("anthropic", model: "claude-opus-5-5", locality: .cloud)),
        ])
    }

    @Test func sendFactsSplittingWithProposalsOffAndAnUnscheduledTidyUp() {
        var s = Self.settings()
        s.setChoice(Self.model("anthropic", "claude-haiku-5-5"), for: .newMemories)
        let facts = s.sendFacts(proposals: false, split: true, tidyUpScheduled: false, localities: [:])
        #expect(facts == [
            SendFact(job: .newMemories(splits: true), destination: .account("anthropic", model: "claude-haiku-5-5", locality: .cloud)),
            // Tidy Up Now works with the schedule off.
            SendFact(job: .tidyUp(scheduled: false), destination: .account("anthropic", model: "claude-haiku-5-5", locality: .cloud)),
        ])
    }

    @Test func sendFactsOnDeviceAnswersOnlyWhenAsked() {
        var s = Self.settings()
        s.searchAnswersOn = true
        s.searchAnswersTrigger = .everySearch
        s.setChoice(.onDevice, for: .searchAnswers)
        #expect(s.sendFacts(proposals: false, split: false, tidyUpScheduled: false, localities: [:])
            == [SendFact(job: .searchAnswers(.ask), destination: .onDevice)])
    }

    @Test func sendFactsSecondIndexAndNothing() {
        var s = Self.settings()
        s.upsert(AIAccount(endpoint: .openAI(), name: "OpenAI"))
        s.embedding = EmbeddingChoice(provider: "openai", model: "text-embedding-3-small")
        s.cloudLimit = .never
        #expect(s.sendFacts(proposals: false, split: false, tidyUpScheduled: false, localities: [:]) == [
            SendFact(job: .searchIndex(memoryText: false, agentTasks: true),
                     destination: .account("openai", model: "text-embedding-3-small", locality: .cloud)),
        ])
        s.embedding = EmbeddingChoice(provider: "ollama", model: "qwen3-embedding:0.6b", embedsAgentTasks: false)
        #expect(s.sendFacts(proposals: false, split: false, tidyUpScheduled: false, localities: ["ollama": .localServer]) == [
            SendFact(job: .searchIndex(memoryText: true, agentTasks: false),
                     destination: .account("ollama", model: "qwen3-embedding:0.6b", locality: .localServer)),
        ])
    }

    // MARK: Conversion (ADR-0030 §6)

    @Test func nothingStoredIsTheDefaults() {
        let (s, converted) = AISettings.load(nil)
        #expect(s == AISettings() && !converted)
    }

    @Test func convertsTheFullV1Shape() throws {
        let (s, converted) = AISettings.load(try Self.fixture("v1-full"))
        #expect(converted && s.version == 2)
        #expect(s.accounts.map(\.models) == [["claude-haiku-5-5"], []])
        #expect(s.accounts.map(\.endpoint) == [.anthropic(), .ollama()])
        // The plan's stored model first, then its other suggestions; a blank model's plan has its suggestions.
        #expect(s.plan(.claudeCode).models == ["opus", "haiku"])
        #expect(s.plan(.codex).models == ["gpt-6-luna", "gpt-5.6-terra"])
        #expect(s.newMemories == Self.model("anthropic", "claude-haiku-5-5"))
        #expect(s.tidyUp == Self.model("claude-code", "opus"))
        #expect(s.searchAnswers == .onDevice)
        #expect(s.embedding == EmbeddingChoice(provider: "ollama", model: "qwen3-embedding:0.6b", embedsAgentTasks: false))
        #expect(s.cloudLimit == .upTo(.sensitive) && s.dailyCap == 500 && s.codexAllowsFileReads)
        #expect(s.usage["anthropic"]?.requests == 412 && s.usage["claude-code"]?.outputTokens == 2050)
        #expect(s.calibrations["ollama/nomic-embed-text"]?.dimensions == 768)
        #expect(s.searchAnswersOn && s.searchAnswersTrigger == .questions)
    }

    /// A converted setup routes each job to the same account (so the same endpoint and key, by
    /// account id) and the same model as v0.7 did.
    @Test func aConvertedSetupRoutesEachJobAsBefore() throws {
        let (s, _) = AISettings.load(try Self.fixture("v1-full"))
        #expect(s.resolve(.newMemories).model == .model(account: "anthropic", model: "claude-haiku-5-5"))
        #expect(s.account("anthropic")?.endpoint == .anthropic())
        #expect(s.resolve(.tidyUp).model == .model(account: "claude-code", model: "opus"))
        #expect(s.resolve(.searchAnswers).model == .onDevice)
    }

    @Test func aTaskOnAModelLessProviderStaysUnresolved() throws {
        let (s, _) = AISettings.load(try Self.fixture("v1-model-less"))
        #expect(s.account("lmstudio")?.models == [])
        #expect(s.tidyUp == Self.model("lmstudio", nil))
        // It doesn't start following the cloud New memories.
        #expect(s.searchAnswers == Self.model("lmstudio", nil))
        #expect(s.resolve(.searchAnswers).model == .unresolved(account: "lmstudio"))
        #expect(s.resolve(.newMemories).model == .model(account: "anthropic", model: "claude-haiku-5-5"))
    }

    /// v0.7 let an embedding model be saved as a provider's chat model (with a warning); it never
    /// chatted, so it isn't carried into the chat models, and a task on that provider is unresolved.
    /// The second index keeps it. (The shape of the author's own settings.)
    @Test func anEmbeddingModelSavedAsTheChatModelIsLeftOut() throws {
        let (s, _) = AISettings.load(try Self.fixture("v1-embedding-as-chat"))
        #expect(s.account("ollama")?.models == [])
        #expect(s.searchAnswers == Self.model("ollama", nil))
        #expect(s.embedding?.model == "qwen3-embedding:0.6b")
        #expect(s.newMemories == Self.model("claude-code", "opus"))
        #expect(s.tidyUp == Self.model("codex", "gpt-5.6-terra"))
        #expect(s.plan(.codex).models == ["gpt-5.6-terra", "gpt-6-luna"])
        #expect(s.cloudLimit == .upTo(.restricted) && s.codexAllowsFileReads)
    }

    @Test func plansWithABlankModelOrNoRecord() throws {
        let (s, _) = AISettings.load(try Self.fixture("v1-plans"))
        #expect(s.newMemories == Self.model("codex", nil))
        #expect(s.plan(.codex).models == ["gpt-6-luna", "gpt-5.6-terra"])
        // Claude Code without a record ran its first suggestion.
        #expect(s.tidyUp == Self.model("claude-code", "haiku"))
        #expect(s.searchAnswers == Self.model("claude-code", "haiku"))
        #expect(s.plans.map(\.kind) == [.codex])
        #expect(s.cloudLimit == .never)
    }

    @Test func followsAndDefaultsStayAsTheyAre() throws {
        let (s, converted) = AISettings.load(try Self.fixture("v1-defaults"))
        #expect(converted)
        #expect(s.newMemories == .onDevice && s.tidyUp == .followsNewMemories && s.searchAnswers == .followsNewMemories)
        #expect(!s.searchAnswersOn && s.searchAnswersTrigger == .ask && s.plans.isEmpty)
    }

    @Test func idsThatNameNothingDontStartFollowing() throws {
        let (s, _) = AISettings.load(try Self.fixture("v1-dangling"))
        #expect(s.newMemories == .onDevice)
        #expect(s.tidyUp == Self.model("gone", nil) && s.searchAnswers == Self.model("gone", nil))
        // With a cloud New memories, the tidy-up kept its rules and Search answers had nothing in
        // v0.7; neither starts using the cloud model.
        let (cloud, _) = AISettings.load(try Self.fixture("v1-dangling-cloud"))
        #expect(cloud.resolve(.newMemories).model == .model(account: "anthropic", model: "claude-haiku-5-5"))
        #expect(cloud.resolve(.tidyUp).model == .unresolved(account: "gone"))
        #expect(cloud.resolve(.searchAnswers).model == .unresolved(account: "gone"))
        #expect(cloud.sendFacts(proposals: false, split: false, tidyUpScheduled: true, localities: [:]).isEmpty)
    }

    @Test func alreadyConvertedLoadsAsIs() throws {
        var (s, _) = AISettings.load(try Self.fixture("v1-full"))
        s.addModel("claude-sonnet-5-5", to: "anthropic")
        let data = try JSONEncoder().encode(s)
        let (again, converted) = AISettings.load(data)
        #expect(!converted && again == s)
        // The old fields are gone from what's written.
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["providers"] == nil && json["classifier"] == nil && json["subscriptions"] == nil)
        // A field added later reads as its default.
        let minimal = AISettings.load(Data(#"{"version":2}"#.utf8))
        #expect(minimal.settings == AISettings() && !minimal.converted)
    }
}
