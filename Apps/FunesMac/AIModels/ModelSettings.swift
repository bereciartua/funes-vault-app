import BridgeKitCore
import Foundation
import FunesCore
import FunesProtocol
import Observation

extension AIAccount {
    /// The presets Add Account offers, with a suggested first model each.
    static var presets: [AIAccount] {
        [AIAccount(endpoint: .anthropic(), name: "Anthropic", models: [AnthropicClient.suggestedModel]),
         AIAccount(endpoint: .openAI(), name: "OpenAI", models: ["gpt-5-mini"]),
         AIAccount(endpoint: .ollama(), name: "Ollama", models: ["llama3.2"]),
         AIAccount(endpoint: .lmStudio(), name: "LM Studio")]
    }

    /// A new Other OpenAI-Compatible Server.
    static func custom() -> AIAccount {
        AIAccount(endpoint: ProviderEndpoint(id: ProviderID(rawValue: "custom-\(UUID().uuidString.prefix(8).lowercased())"),
                                             kind: .openAICompatible, baseURL: URL(string: "http://127.0.0.1:8080/v1")!),
                  name: String(localized: "My Server"))
    }
}

extension PlanKind {
    /// "Claude (Claude Code)", "ChatGPT (Codex)".
    var name: String {
        switch self {
        case .claudeCode: String(localized: "Claude (Claude Code)")
        case .codex: String(localized: "ChatGPT (Codex)")
        }
    }

    /// The vendor's privacy settings, where the account's training setting lives.
    var privacySettings: URL {
        switch self {
        case .claudeCode: URL(string: "https://claude.ai/settings/data-privacy-controls")!
        case .codex: URL(string: "https://chatgpt.com/#settings/DataControls")!
        }
    }
}

/// A provider embedding model's client, before its locality is resolved.
struct EmbeddingRecipe: Sendable {
    var endpoint: ProviderEndpoint
    var model: String
    var info: EmbeddingModelInfo?
    var dimensions: Int?
    var key: String?

    func make() throws -> OpenAICompatibleEmbedder {
        try OpenAICompatibleEmbedder(endpoint: endpoint, model: model, info: info, dimensions: dimensions, apiKey: key)
    }
}

/// Settings ▸ AI (FR-AI-05..08, FR-AI-12, ADR-0030): accounts and plans with their models, each
/// job's choice, the cloud limit, usage and the second index, stored in user defaults as
/// `AISettings` (storage §1). The app's observable wrapper: it builds the clients and keeps the
/// Keychain and the plans' checks.
@MainActor @Observable
final class ModelSettings {
    static let defaultsKey = "AIModels"
    private let defaults: UserDefaults
    /// Called when anything the second index depends on changes: the choice, the cloud limit, a
    /// calibration, or its account's address, cloud flag or key.
    @ObservationIgnored var embeddingInputsChanged: () -> Void = {}
    let keys: any ProviderKeyStore
    private(set) var stored: AISettings
    /// Bumped when a key is saved or removed, so views reading `hasKey` refresh.
    private(set) var keyGeneration = 0

    init(defaults: UserDefaults, keys: any ProviderKeyStore) {
        self.defaults = defaults
        self.keys = keys
        let (settings, converted) = AISettings.load(defaults.data(forKey: Self.defaultsKey))
        stored = settings
        // The v1 shape is converted once and written back at once (ADR-0030 §6).
        if converted { save() }
    }

    /// The Keychain items: `com.funesvault.provider`, or a separate service for a development vault.
    static func keychain() -> KeychainProviderKeyStore {
        KeychainProviderKeyStore(service: Identifiers.providerKeychainService + (Preferences.isDevelopmentVault ? ".dev" : ""))
    }

    /// Changes the stored settings, saves, and tells the second index when its inputs changed.
    @discardableResult
    private func change<T>(_ body: (inout AISettings) -> T) -> T {
        let before = stored.embeddingInputs
        let result = body(&stored)
        save()
        if stored.embeddingInputs != before { embeddingInputsChanged() }
        return result
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: Accounts and plans

    var accounts: [AIAccount] { stored.accounts }
    func account(_ id: String) -> AIAccount? { stored.account(id) }
    func plan(_ kind: PlanKind) -> AIPlan { stored.plan(kind) }

    /// An account or plan with this id exists (a plan always does).
    func hasAccount(_ id: String) -> Bool { stored.exists(id) }

    /// An account's or plan's name: "Anthropic", "Claude (Claude Code)".
    func name(_ id: String) -> String { PlanKind(rawValue: id)?.name ?? account(id)?.name ?? id }

    /// An account's or plan's models.
    func models(of id: String) -> [String] { stored.models(of: id) ?? [] }

    /// Resolved localities (a DNS lookup for host names) by endpoint, filled by
    /// `resolveLocalities()`. Keyed by the endpoint, not the account, so an account whose address
    /// or cloud flag just changed counts as cloud until its new endpoint is resolved (fail closed),
    /// and a lookup that finishes late only fills in the endpoint it looked up.
    private(set) var localities: [ProviderEndpoint: Locality] = [:]

    /// Resolves every account's locality off the main thread.
    func resolveLocalities() async {
        let endpoints = Set(accounts.map(\.endpoint))
        let resolved = await Task.detached(priority: .utility) {
            endpoints.map { ($0, $0.locality()) }
        }.value
        for (endpoint, locality) in resolved { localities[endpoint] = locality }
    }

    /// Where an account or plan runs: a plan is cloud; an account is cloud until resolved.
    func locality(account id: String) -> Locality {
        if PlanKind(rawValue: id) != nil { return .cloud }
        guard let account = account(id), !account.endpoint.markedCloud else { return .cloud }
        return localities[account.endpoint] ?? .cloud
    }

    /// Where a job's effective model runs.
    func locality(_ model: EffectiveModel) -> Locality {
        switch model {
        case .onDevice, .rules: .onDevice
        case let .model(account, _), let .unresolved(account): locality(account: account)
        }
    }

    func upsert(_ account: AIAccount) {
        change { $0.upsert(account) }
    }

    /// Saves an account's key in the Keychain, or deletes it when `key` is nil or empty. Throws
    /// when the Keychain refuses.
    func setKey(_ key: String?, for id: String) throws {
        let provider = ProviderID(rawValue: id)
        if let key, !key.isEmpty { try keys.setKey(key, for: provider) } else { try keys.deleteKey(for: provider) }
        keyGeneration += 1
        if stored.embedding?.provider == id { embeddingInputsChanged() }
    }

    func hasKey(_ id: String) -> Bool {
        _ = keyGeneration
        return ((try? keys.key(for: ProviderID(rawValue: id))) ?? nil)?.isEmpty == false
    }

    /// Whether an account is missing the key it needs: Anthropic always, OpenAI's own endpoint.
    func needsKey(_ account: AIAccount) -> Bool { account.requiresKey && !hasKey(account.id) }

    @discardableResult
    func addModel(_ name: String, to id: String) -> Bool { change { $0.addModel(name, to: id) } }

    /// Removes a chat model; the jobs that chose it go back to their default.
    @discardableResult
    func removeModel(_ model: String, from id: String) -> RemovalEffect { change { $0.removeModel(model, from: id) } }

    /// Removing an account deletes its key (FR-AI-06), its usage and its jobs' choices, and the
    /// second index if it's this account's.
    @discardableResult
    func removeAccount(_ id: String) -> RemovalEffect {
        try? keys.deleteKey(for: ProviderID(rawValue: id))
        keyGeneration += 1
        return change { $0.removeAccount(id) }
    }

    // MARK: Choices (ADR-0030 §6)

    func choice(_ job: AIJob) -> JobChoice { stored.choice(job) }
    func setChoice(_ choice: JobChoice, for job: AIJob) { change { $0.setChoice(choice, for: job) } }
    func resolve(_ job: AIJob) -> Resolution { stored.resolve(job) }

    /// "Anthropic · claude-haiku-5-5", "Apple on-device"; nil for the tidy-up's rules.
    func label(_ model: EffectiveModel) -> String? {
        switch model {
        case .onDevice: String(localized: "Apple on-device")
        case .rules: nil
        case let .model(account, model): "\(name(account)) · \(model)"
        case let .unresolved(account): name(account)
        }
    }

    /// Why a job can't run as chosen, from configuration only.
    func problem(_ job: AIJob) -> JobProblem? {
        stored.problem(job, hasKey: hasKey, planStatus: subscriptionStatus, blocked: CLIRunner.isBlocked,
                       onDeviceAvailable: AppleFoundationGenerator.isAvailable)
    }

    /// Why an account or plan can't run now.
    func problem(account id: String) -> AccountProblem? {
        stored.problem(account: id, hasKey: hasKey, planStatus: subscriptionStatus, blocked: CLIRunner.isBlocked)
    }

    /// A job picker's accounts and their models.
    func pickerSections(_ job: AIJob) -> [PickerSection] {
        stored.pickerSections(job, installedPlans: Set(executables.keys), hasKey: hasKey, planStatus: subscriptionStatus,
                              blocked: CLIRunner.isBlocked)
    }

    /// Where a job's problem is fixed (ADR-0030 §9): its account's page when the account is why,
    /// otherwise the job's page.
    func destination(for job: AIJob) -> SettingsDestination {
        if case let .account(id, _)? = problem(job) { return .account(id) }
        switch job {
        case .newMemories: return .newMemories
        case .tidyUp: return .tidyUp
        case .searchAnswers: return .searchAnswers
        }
    }

    /// The jobs and second index that use an account.
    func usedBy(_ id: String) -> [AccountUse] { stored.usedBy(id) }

    // MARK: Plans (ADR-0024)

    /// Settings ▸ Models & Accounts ▸ ChatGPT (Codex): the opt-in, off by default.
    var codexAllowsFileReads: Bool {
        get { stored.codexAllowsFileReads }
        set { change { $0.codexAllowsFileReads = newValue } }
    }

    /// Where each CLI was found on this Mac; looked up off the main thread (a login shell), so
    /// building a router never waits for it.
    private(set) var executables: [PlanKind: String] = [:]
    /// Each plan's state, for Settings.
    private(set) var subscriptionStatus: [PlanKind: SubscriptionStatus] = [:]

    #if FUNES_UI_REVIEW
    @ObservationIgnored private var plansFixed = false

    /// The UI review's plans: where each CLI is and its state, never checked again.
    func reviewPlans(_ found: [PlanKind: String], _ status: [PlanKind: SubscriptionStatus]) {
        executables = found
        subscriptionStatus = status
        plansFixed = true
    }
    #endif

    /// Finds the CLIs and checks them: version, flags, sign-in, Codex's features. No model call.
    func refreshSubscriptions() async {
        #if FUNES_UI_REVIEW
        if plansFixed { return }
        #endif
        let home = NSHomeDirectory()
        let found = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: PlanKind.allCases.compactMap { kind in
                ExecutableLocator.live.locate(kind.command, home: home).map { (kind, $0) }
            })
        }.value
        executables = found
        for kind in PlanKind.allCases {
            if let client = subscriptionClient(kind) {
                subscriptionStatus[kind] = await client.status()
            } else {
                subscriptionStatus[kind] = .notInstalled
            }
        }
    }

    /// A plan's client with one of its models; nil while its CLI isn't found.
    func subscriptionClient(_ kind: PlanKind, model: String? = nil) -> (any SubscriptionClient)? {
        guard let path = executables[kind] else { return nil }
        let model = model ?? plan(kind).models.first ?? kind.suggestedModels[0]
        switch kind {
        case .claudeCode: return ClaudeCodeClient(executable: path, model: model)
        case .codex: return CodexClient(executable: path, model: model, allowsFileReads: codexAllowsFileReads)
        }
    }

    // MARK: Clients

    /// The client for an account or plan's model; nil when it can't be made (no CLI, no key).
    func generator(account id: String, model: String) -> (any GenerationProvider)? {
        if let kind = PlanKind(rawValue: id) { return subscriptionClient(kind, model: model) }
        return account(id).flatMap { try? client(for: $0, model: model) }
    }

    /// The client for a job's effective model; nil for Apple on-device, the rules or an
    /// unresolved choice.
    private func generator(_ model: EffectiveModel) -> (any GenerationProvider)? {
        guard case let .model(account, model) = model else { return nil }
        return generator(account: account, model: model)
    }

    /// A client for an account's model, with its key from the Keychain.
    func client(for account: AIAccount, model: String) throws -> any GenerationProvider {
        try Self.client(for: account, model: model, key: try keys.key(for: account.endpoint.id))
    }

    /// A client for an account's model with this key. Resolves the account's host, so off the main
    /// actor where it can wait.
    nonisolated static func client(for account: AIAccount, model: String, key: String?) throws -> any GenerationProvider {
        switch account.endpoint.kind {
        case .anthropic:
            guard let key, !key.isEmpty else { throw ProviderError.unauthorized }
            return try AnthropicClient(endpoint: account.endpoint, model: model, apiKey: key)
        case .openAICompatible:
            return try OpenAICompatibleClient(endpoint: account.endpoint, model: model, apiKey: key)
        }
    }

    // MARK: New memories

    /// New memories' account and model, when it has one (not Apple on-device, not unresolved).
    var newMemoriesModel: (account: String, model: String)? {
        guard case let .model(account, model) = resolve(.newMemories).model else { return nil }
        return (account, model)
    }

    /// "Anthropic · claude-haiku-5-5": New memories' model, for splitting and the processing card.
    var newMemoriesName: String? { newMemoriesModel.map { "\(name($0.account)) · \($0.model)" } }

    /// New memories' plan, when it's one.
    var newMemoriesPlan: PlanKind? { newMemoriesModel.flatMap { PlanKind(rawValue: $0.account) } }

    /// The router for New memories: its model, then Apple on-device, then rules, with cloud
    /// requests counted against `cap`.
    func makeRouter(cap: CloudRequestCap?) -> ModelRouter {
        ModelRouter(classifier: generator(resolve(.newMemories).model), cloudLimit: cloudLimit, cap: cap)
    }

    /// Who new captures go to when it isn't local and the cloud limit lets anything go (the
    /// capture box says so; UX review F6): "Claude", "Anthropic". Nil when they stay on this Mac.
    /// Locality needs a DNS lookup for host names, so it's worked out off the main thread.
    func cloudClassifierName() async -> String? {
        guard let chosen = newMemoriesModel, case .upTo = cloudLimit else { return nil }
        if let kind = PlanKind(rawValue: chosen.account) { return kind.plan }
        guard let account = account(chosen.account), !needsKey(account) else { return nil }
        let endpoint = account.endpoint
        let local = await Task.detached(priority: .utility) { endpoint.locality().isLocal }.value
        return local ? nil : account.name
    }

    // MARK: Daily tidy-up (memory processing §9)

    /// "Claude (Claude Code) · opus"; nil when only the code-only rules run (no model, or an
    /// unresolved choice).
    var tidyUpName: String? {
        guard case let .model(account, model) = resolve(.tidyUp).model else { return nil }
        return "\(name(account)) · \(model)"
    }

    /// The model id the tidy-up's auto-apply levels are measured on ("claude-opus-5-5", "haiku").
    var tidyUpModel: String? { resolve(.tidyUp).model.model }

    /// The tidy-up's router: its model and no on-device fallback; with none, only the code-only
    /// rules run. At the cap it waits for the next day (ADR-0022).
    func makeTidyUpRouter(cap: CloudRequestCap?) -> ModelRouter {
        ModelRouter(classifier: generator(resolve(.tidyUp).model), onDevice: nil, cloudLimit: cloudLimit, cap: cap)
    }

    // MARK: Search answers (memory processing §10, FR-AI-17)

    /// Whether Search answers are on (Off is the default).
    var searchAnswersOn: Bool {
        get { stored.searchAnswersOn }
        set { change { $0.searchAnswersOn = newValue } }
    }

    /// Answer: Off (nil, the default) · Only when I ask · Automatically for questions ·
    /// Automatically for every search.
    var searchAnswersMode: AnswerTrigger? {
        get { searchAnswersOn ? searchAnswersTrigger : nil }
        set {
            change {
                $0.searchAnswersOn = newValue != nil
                if let newValue { $0.searchAnswersTrigger = newValue }
            }
        }
    }

    /// When a search is answered while answers are on, as chosen (Apple on-device's answers are
    /// only asked for: see `SearchAnswersController.trigger`).
    var searchAnswersTrigger: AnswerTrigger { stored.searchAnswersTrigger }

    /// Whether Apple's on-device model answers (the effective choice is it).
    var searchAnswersOnDevice: Bool { resolve(.searchAnswers).model == .onDevice }

    /// "Claude (Claude Code) · opus", "Apple on-device", or the account alone while unresolved.
    var searchAnswersName: String { label(resolve(.searchAnswers).model) ?? String(localized: "Apple on-device") }

    /// The effective account, an API account's or a plan's id.
    var searchAnswersAccount: String? { resolve(.searchAnswers).model.account }

    /// Whether the effective choice is a plan (its own sign-in and limits).
    var searchAnswersPlan: PlanKind? { searchAnswersAccount.flatMap(PlanKind.init(rawValue:)) }

    /// Search answers' router, built by the returned closure off the main actor (an HTTP client
    /// resolves its host to learn its locality): the chosen model, or Apple on-device; no fallback
    /// to another (model providers §6). It throws the client's own error, such as `unauthorized`
    /// for an account without its key.
    func searchAnswerRouterBuilder(cap: CloudRequestCap?) -> @Sendable () throws -> ModelRouter {
        let limit = cloudLimit
        switch resolve(.searchAnswers).model {
        case .onDevice:
            return { ModelRouter(classifier: nil, onDevice: AppleFoundationGenerator.isAvailable ? AppleFoundationGenerator() : nil,
                                 cloudLimit: limit, cap: cap) }
        case .rules, .unresolved:
            return { ModelRouter(classifier: nil, onDevice: nil, cloudLimit: limit, cap: cap) }
        case let .model(id, model):
            if let kind = PlanKind(rawValue: id) {
                let client = subscriptionClient(kind, model: model)
                return { ModelRouter(classifier: client, onDevice: nil, cloudLimit: limit, cap: cap) }
            }
            guard let account = account(id) else { return { ModelRouter(classifier: nil, onDevice: nil, cloudLimit: limit, cap: cap) } }
            let key = try? keys.key(for: account.endpoint.id)
            return { ModelRouter(classifier: try Self.client(for: account, model: model, key: key), onDevice: nil, cloudLimit: limit, cap: cap) }
        }
    }

    // MARK: Limits (ADR-0022)

    var cloudLimit: CloudLimit {
        get { stored.cloudLimit }
        set { change { $0.cloudLimit = newValue } }
    }

    /// Cloud requests per day, shared by every job that uses a cloud model.
    var dailyCap: Int {
        get { stored.dailyCap ?? CloudRequestCap.defaultLimit }
        set { change { $0.dailyCap = max(10, min(10_000, newValue)) } }
    }

    /// Today's cloud request cap on this vault.
    func cap(store: VaultStore, activity: any ActivityRecorder) -> CloudRequestCap {
        CloudRequestCap(store: store, limit: dailyCap, activity: activity)
    }

    // MARK: Embeddings (ADR-0023)

    var embedding: EmbeddingChoice? { stored.embedding }

    /// The accounts that offer `/v1/embeddings`: every OpenAI-compatible one (not Anthropic).
    var embeddingProviders: [AIAccount] { accounts.filter(\.offersEmbeddings) }

    var embeddingProvider: AIAccount? { stored.embedding.flatMap { account($0.provider) } }

    func setEmbedding(_ choice: EmbeddingChoice?) {
        guard choice != stored.embedding else { return }
        change { $0.embedding = choice }
    }

    func setEmbedsAgentTasks(_ on: Bool) {
        guard var choice = stored.embedding, choice.embedsAgentTasks != on else { return }
        choice.embedsAgentTasks = on
        setEmbedding(choice)
    }

    func setCalibration(_ thresholds: CalibratedThresholds, for modelID: String) {
        change { $0.calibrations[modelID] = thresholds }
    }

    /// What it takes to build the second index's client: the endpoint, model, key and any
    /// calibrated thresholds. `make()` resolves the locality (a DNS lookup), so call it off the
    /// main thread.
    func embeddingRecipe(_ choice: EmbeddingChoice? = nil) -> EmbeddingRecipe? {
        guard let choice = choice ?? stored.embedding, let account = account(choice.provider), account.offersEmbeddings else { return nil }
        let id = OpenAICompatibleEmbedder.modelID(provider: account.endpoint.id, model: choice.model)
        let info = stored.calibrations[id].map {
            EmbeddingModelInfo(id: id, dimensions: $0.dimensions, vaultThreshold: $0.vault, retrievalThreshold: $0.retrieval)
        }
        return EmbeddingRecipe(endpoint: account.endpoint, model: choice.model, info: info, dimensions: choice.dimensions,
                               key: (try? keys.key(for: account.endpoint.id)) ?? nil)
    }

    // MARK: Usage (FR-AI-12)

    func usage(_ id: String) -> ProviderUsage? { stored.usage[id] }

    /// Adds embedding tokens to an account's counters.
    func addUsage(_ used: ProviderUsage, for id: String) {
        guard used.requests > 0 else { return }
        change { $0.addUsage(used, for: id) }
    }

    /// Adds a router's counts to the stored ones and resets the router.
    func collectUsage(from router: ModelRouter) {
        let counts = router.usageCounters()
        guard !counts.isEmpty else { return }
        router.resetUsage()
        change { settings in
            for (id, used) in counts { settings.addUsage(used, for: id.rawValue) }
        }
    }

    /// Reset Usage on an account's or plan's page.
    func resetUsage(for id: String) {
        change { $0.resetUsage(for: id) }
    }
}

extension Locality {
    /// The badge: On this Mac · Local server · Apple cloud · Cloud.
    var title: String {
        switch self {
        case .onDevice: String(localized: "On this Mac")
        case .localServer: String(localized: "Local server")
        case .appleCloud: String(localized: "Apple cloud")
        case .cloud: String(localized: "Cloud")
        }
    }
}
