import BridgeKitCore
import Foundation
import FunesCore
import FunesProtocol
import Observation

/// A provider the user added (model providers §4): the endpoint, a name, and the model chosen
/// for classification. The API key is in the Keychain, never here.
struct ProviderConfig: Codable, Hashable, Identifiable {
    var endpoint: ProviderEndpoint
    var name: String
    var model: String
    var id: String { endpoint.id.rawValue }

    /// The presets the Add menu offers, with a suggested model each.
    static var presets: [ProviderConfig] {
        [ProviderConfig(endpoint: .anthropic(), name: "Anthropic", model: AnthropicClient.suggestedModel),
         ProviderConfig(endpoint: .openAI(), name: "OpenAI", model: "gpt-5-mini"),
         ProviderConfig(endpoint: .ollama(), name: "Ollama", model: "llama3.2"),
         ProviderConfig(endpoint: .lmStudio(), name: "LM Studio", model: "")]
    }

    var locality: Locality { endpoint.locality() }
}

/// The user's Claude or ChatGPT plan through their own Claude Code or Codex (ADR-0024,
/// FR-AI-16): the model to use. No key: the CLI's own sign-in is used.
struct SubscriptionConfig: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case claudeCode = "claude-code"
        case codex
        var id: String { rawValue }

        /// "Claude (Claude Code)", "ChatGPT (Codex)".
        var name: String {
            switch self {
            case .claudeCode: String(localized: "Claude (Claude Code)")
            case .codex: String(localized: "ChatGPT (Codex)")
            }
        }

        /// The plan's name, for the disclosure line.
        var plan: String {
            switch self {
            case .claudeCode: "Claude"
            case .codex: "ChatGPT"
            }
        }

        var command: String {
            switch self {
            case .claudeCode: "claude"
            case .codex: "codex"
            }
        }

        /// What to run in Terminal to sign in.
        var signIn: String {
            switch self {
            case .claudeCode: "claude"
            case .codex: "codex login"
            }
        }

        var suggestedModels: [String] {
            switch self {
            case .claudeCode: ClaudeCodeClient.suggestedModels
            case .codex: CodexClient.suggestedModels
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

    var kind: Kind
    var model: String
    var id: String { kind.rawValue }
}

/// A provider embedding model as the second index (ADR-0023, FR-AI-11): which provider and model,
/// its dimensions when Funes doesn't know the model, and whether agents' tasks are embedded with it
/// (FR-AI-09, on by default).
struct EmbeddingChoice: Codable, Hashable {
    var provider: String
    var model: String
    var dimensions: Int?
    var embedsAgentTasks = true
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

/// Thresholds Calibrate measured for a model (model providers §8).
struct CalibratedThresholds: Codable, Hashable {
    var dimensions: Int
    var vault: Float
    var retrieval: Float
}

/// Settings ▸ AI Models (FR-AI-05..08, FR-AI-12): providers, the Classification choice, the cloud
/// limit, usage counters and, from v0.3, a provider embedding model, in user defaults (storage §1).
@MainActor @Observable
final class ModelSettings {
    struct Stored: Codable {
        var providers: [ProviderConfig] = []
        /// nil: Apple on-device (the default). Otherwise a provider id.
        var classifier: String?
        var cloudLimit: CloudLimit = .upTo(.internal)
        var usage: [String: ProviderUsage] = [:]
        /// Cloud requests per day (ADR-0022); nil is the default, 300.
        var dailyCap: Int?
        /// The plans' models (ADR-0024); nil before v0.3.
        var subscriptions: [SubscriptionConfig]?
        /// The user accepted that Codex can run commands that read files (ADR-0024); off by default.
        var codexAllowsFileReads: Bool?
        /// The Daily tidy-up's provider (memory processing §9.1): a provider id or a plan; nil is the
        /// same as New memories.
        var tidyUp: String?
        /// The provider embedding model (v0.3); nil: bge-small only.
        var embedding: EmbeddingChoice?
        /// Calibrate's thresholds, by stored model id (`<provider>/<model>`).
        var calibrations: [String: CalibratedThresholds]?
        /// Search answers (v0.6, FR-AI-17): on or off, the default; nil before v0.6.
        var searchAnswers: Bool?
        /// When they're on, when a search is answered: an `AnswerTrigger`; nil is only when asked.
        var searchAnswersTrigger: String?
        /// Search answers' provider: a provider id or a plan; nil is the same as New memories.
        var searchAnswersModel: String?
    }

    static let defaultsKey = "AIModels"
    private let defaults: UserDefaults
    /// Called when anything the provider embedding index depends on changes: the choice, the cloud
    /// limit, or a provider's address or key.
    @ObservationIgnored var embeddingInputsChanged: () -> Void = {}
    let keys: any ProviderKeyStore
    private(set) var stored: Stored

    init(defaults: UserDefaults, keys: any ProviderKeyStore) {
        self.defaults = defaults
        self.keys = keys
        stored = (defaults.data(forKey: Self.defaultsKey)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    /// The Keychain items: `com.funesvault.provider`, or a separate service for a development vault.
    static func keychain() -> KeychainProviderKeyStore {
        KeychainProviderKeyStore(service: Identifiers.providerKeychainService + (Preferences.isDevelopmentVault ? ".dev" : ""))
    }

    var providers: [ProviderConfig] { stored.providers }
    var classifierID: String? { stored.classifier }
    var cloudLimit: CloudLimit {
        get { stored.cloudLimit }
        set { stored.cloudLimit = newValue; save(); embeddingInputsChanged() }
    }

    var classifier: ProviderConfig? { stored.classifier.flatMap { id in providers.first { $0.id == id } } }

    // MARK: Subscriptions (ADR-0024)

    /// Each plan's model; the first suggestion until the user picks another.
    func subscription(_ kind: SubscriptionConfig.Kind) -> SubscriptionConfig {
        stored.subscriptions?.first { $0.kind == kind } ?? SubscriptionConfig(kind: kind, model: kind.suggestedModels[0])
    }

    /// Settings ▸ Use your subscription ▸ ChatGPT (Codex): the opt-in, off by default.
    var codexAllowsFileReads: Bool {
        get { stored.codexAllowsFileReads ?? false }
        set { stored.codexAllowsFileReads = newValue; save() }
    }

    func setSubscriptionModel(_ kind: SubscriptionConfig.Kind, _ model: String) {
        var list = stored.subscriptions ?? []
        list.removeAll { $0.kind == kind }
        list.append(SubscriptionConfig(kind: kind, model: model))
        stored.subscriptions = list
        save()
    }

    /// The plan chosen for New memories, if one is.
    var chosenSubscription: SubscriptionConfig? {
        stored.classifier.flatMap(SubscriptionConfig.Kind.init(rawValue:)).map(subscription)
    }

    /// The chosen provider's name, an API provider's or a plan's.
    var chosenName: String? { classifier?.name ?? chosenSubscription?.kind.name }

    /// Where each CLI was found on this Mac; looked up off the main thread (a login shell), so
    /// building a router never waits for it.
    private(set) var executables: [SubscriptionConfig.Kind: String] = [:]
    /// Each plan's state, for Settings.
    private(set) var subscriptionStatus: [SubscriptionConfig.Kind: SubscriptionStatus] = [:]

    /// Finds the CLIs and checks them: version, flags, sign-in, Codex's features. No model call.
    func refreshSubscriptions() async {
        let home = NSHomeDirectory()
        let found = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: SubscriptionConfig.Kind.allCases.compactMap { kind in
                ExecutableLocator.live.locate(kind.command, home: home).map { (kind, $0) }
            })
        }.value
        executables = found
        for kind in SubscriptionConfig.Kind.allCases {
            if let client = subscriptionClient(kind) {
                subscriptionStatus[kind] = await client.status()
            } else {
                subscriptionStatus[kind] = .notInstalled
            }
        }
    }

    func subscriptionClient(_ kind: SubscriptionConfig.Kind) -> (any SubscriptionClient)? {
        guard let path = executables[kind] else { return nil }
        let model = subscription(kind).model
        switch kind {
        case .claudeCode: return ClaudeCodeClient(executable: path, model: model)
        case .codex: return CodexClient(executable: path, model: model, allowsFileReads: codexAllowsFileReads)
        }
    }

    /// Cloud requests per day, shared by New memories and the tidy-up (ADR-0022).
    var dailyCap: Int {
        get { stored.dailyCap ?? CloudRequestCap.defaultLimit }
        set { stored.dailyCap = max(10, min(10_000, newValue)); save() }
    }

    func setClassifier(_ id: String?) {
        stored.classifier = id
        save()
    }

    // MARK: Daily tidy-up (memory processing §9)

    /// The tidy-up's own choice; nil follows New memories.
    var tidyUpID: String? { stored.tidyUp }

    func setTidyUp(_ id: String?) {
        stored.tidyUp = id
        save()
    }

    /// The provider the tidy-up uses: its own choice, or New memories'. Nil for Apple on-device,
    /// which the tidy-up never uses (Spike E: 8 of 49 actions right).
    private var tidyUpChoice: String? { stored.tidyUp ?? stored.classifier }

    private func generator(_ id: String?) -> (any GenerationProvider)? {
        guard let id else { return nil }
        if let kind = SubscriptionConfig.Kind(rawValue: id) { return subscriptionClient(kind) }
        return providers.first { $0.id == id }.flatMap { try? client(for: $0) }
    }

    /// "Claude (Claude Code)", "Anthropic"; nil when only the code-only rules run.
    var tidyUpName: String? {
        guard let id = tidyUpChoice else { return nil }
        if let kind = SubscriptionConfig.Kind(rawValue: id) { return kind.name }
        return providers.first { $0.id == id }?.name
    }

    /// The model id the tidy-up's auto-apply levels are measured on ("claude-opus-5-5", "haiku").
    var tidyUpModel: String? {
        guard let id = tidyUpChoice else { return nil }
        if let kind = SubscriptionConfig.Kind(rawValue: id) { return subscription(kind).model }
        return providers.first { $0.id == id }?.model
    }

    /// The tidy-up's router: its provider and no on-device fallback; with none, only the code-only
    /// rules run. At the cap it waits for the next day (ADR-0022).
    func makeTidyUpRouter(cap: CloudRequestCap?) -> ModelRouter {
        ModelRouter(classifier: generator(tidyUpChoice), onDevice: nil, cloudLimit: cloudLimit, cap: cap)
    }

    // MARK: Search answers (memory processing §10, FR-AI-17)

    /// Whether Search answers are on (Off is the default).
    var searchAnswersOn: Bool {
        get { stored.searchAnswers ?? false }
        set { stored.searchAnswers = newValue; save() }
    }

    /// Answer: Off (nil, the default) · Only when I ask · Automatically for questions ·
    /// Automatically for every search.
    var searchAnswersMode: AnswerTrigger? {
        get { searchAnswersOn ? searchAnswersTrigger : nil }
        set {
            stored.searchAnswers = newValue != nil
            if let newValue { stored.searchAnswersTrigger = newValue == .ask ? nil : newValue.rawValue }
            save()
        }
    }

    /// When a search is answered while answers are on, as chosen (Apple on-device's answers are
    /// only asked for: see `SearchAnswersController.trigger`).
    var searchAnswersTrigger: AnswerTrigger { stored.searchAnswersTrigger.flatMap(AnswerTrigger.init(rawValue:)) ?? .ask }

    /// Search answers' own choice; nil follows New memories.
    var searchAnswersID: String? { stored.searchAnswersModel }

    func setSearchAnswersModel(_ id: String?) {
        stored.searchAnswersModel = id
        save()
    }

    /// Search answers' own choice of Apple's on-device model, apart from New memories'.
    static let onDeviceChoice = "apple.foundation"

    /// The provider that answers: its own choice, or New memories'. Nil is Apple on-device.
    private var searchAnswersChoice: String? {
        let id = stored.searchAnswersModel ?? stored.classifier
        return id == Self.onDeviceChoice ? nil : id
    }

    /// Whether Apple's on-device model answers (the effective choice is it).
    var searchAnswersOnDevice: Bool { searchAnswersChoice == nil }

    /// "Claude (Claude Code)", "Anthropic", "Apple on-device".
    var searchAnswersName: String {
        guard let id = searchAnswersChoice else { return String(localized: "Apple on-device") }
        if let kind = SubscriptionConfig.Kind(rawValue: id) { return kind.name }
        return providers.first { $0.id == id }?.name ?? id
    }

    /// Whether the effective choice is a plan (its own sign-in and limits).
    var searchAnswersPlan: SubscriptionConfig.Kind? { searchAnswersChoice.flatMap(SubscriptionConfig.Kind.init(rawValue:)) }

    /// The chosen API provider, when the choice is one.
    var searchAnswersProvider: ProviderConfig? { searchAnswersChoice.flatMap { id in providers.first { $0.id == id } } }

    /// Search answers' router, built by the returned closure off the main actor (an HTTP client
    /// resolves its host to learn its locality): the chosen provider, or Apple on-device; no
    /// fallback to another (model providers §6). It throws the client's own error, such as
    /// `unauthorized` for a provider without its key.
    func searchAnswerRouterBuilder(cap: CloudRequestCap?) -> @Sendable () throws -> ModelRouter {
        let limit = cloudLimit
        guard let id = searchAnswersChoice else {
            return { ModelRouter(classifier: nil, onDevice: AppleFoundationGenerator.isAvailable ? AppleFoundationGenerator() : nil,
                                 cloudLimit: limit, cap: cap) }
        }
        if let kind = SubscriptionConfig.Kind(rawValue: id) {
            let client = subscriptionClient(kind)
            return { ModelRouter(classifier: client, onDevice: nil, cloudLimit: limit, cap: cap) }
        }
        guard let provider = providers.first(where: { $0.id == id }) else {
            return { ModelRouter(classifier: nil, onDevice: nil, cloudLimit: limit, cap: cap) }
        }
        let key = try? keys.key(for: provider.endpoint.id)
        return { ModelRouter(classifier: try Self.client(for: provider, key: key), onDevice: nil, cloudLimit: limit, cap: cap) }
    }

    /// Whether a provider is missing the API key it needs: Anthropic always, OpenAI's own endpoint.
    func needsKey(_ provider: ProviderConfig) -> Bool {
        (provider.endpoint.kind == .anthropic || provider.endpoint.id == ProviderEndpoint.openAI().id) && !hasKey(provider.id)
    }

    func upsert(_ provider: ProviderConfig, key: String?) throws {
        if let key {
            if key.isEmpty { try keys.deleteKey(for: provider.endpoint.id) } else { try keys.setKey(key, for: provider.endpoint.id) }
        }
        if let index = stored.providers.firstIndex(where: { $0.id == provider.id }) {
            stored.providers[index] = provider
        } else {
            stored.providers.append(provider)
        }
        save()
        if stored.embedding?.provider == provider.id { embeddingInputsChanged() }
    }

    /// Removing a provider deletes its key (FR-AI-06).
    func remove(_ id: String) {
        try? keys.deleteKey(for: ProviderID(rawValue: id))
        stored.providers.removeAll { $0.id == id }
        if stored.classifier == id { stored.classifier = nil }
        if stored.tidyUp == id { stored.tidyUp = nil }
        if stored.searchAnswersModel == id { stored.searchAnswersModel = nil }
        stored.usage[id] = nil
        let embedded = stored.embedding?.provider == id
        if embedded { stored.embedding = nil }
        save()
        if embedded { embeddingInputsChanged() }
    }

    func hasKey(_ id: String) -> Bool { ((try? keys.key(for: ProviderID(rawValue: id))) ?? nil)?.isEmpty == false }

    /// A client for a provider, with its key from the Keychain.
    func client(for provider: ProviderConfig) throws -> any GenerationProvider {
        try Self.client(for: provider, key: try keys.key(for: provider.endpoint.id))
    }

    /// A client for a provider with this key. Resolves the provider's host, so off the main actor
    /// where it can wait.
    nonisolated static func client(for provider: ProviderConfig, key: String?) throws -> any GenerationProvider {
        switch provider.endpoint.kind {
        case .anthropic:
            guard let key, !key.isEmpty else { throw ProviderError.unauthorized }
            return try AnthropicClient(endpoint: provider.endpoint, model: provider.model, apiKey: key)
        case .openAICompatible:
            return try OpenAICompatibleClient(endpoint: provider.endpoint, model: provider.model, apiKey: key)
        }
    }

    /// The provider new captures go to when it isn't local and the cloud limit lets anything go
    /// (the capture box says so; UX review F6). Nil when classification stays on this Mac. Locality
    /// needs a DNS lookup for host names, so it's worked out off the main thread.
    func cloudClassifierName() async -> String? {
        if let plan = chosenSubscription, case .upTo = cloudLimit { return plan.kind.plan }
        guard let provider = classifier, !provider.model.isEmpty, case .upTo = cloudLimit else { return nil }
        if provider.endpoint.kind == .anthropic && !hasKey(provider.id) { return nil }
        let endpoint = provider.endpoint
        let local = await Task.detached(priority: .utility) { endpoint.locality().isLocal }.value
        return local ? nil : provider.name
    }

    /// The router for this choice: the chosen provider, then Apple on-device, then rules, with
    /// cloud requests counted against `cap`.
    func makeRouter(cap: CloudRequestCap?) -> ModelRouter {
        let chosen: (any GenerationProvider)? = chosenSubscription.flatMap { subscriptionClient($0.kind) }
            ?? classifier.flatMap { try? client(for: $0) }
        return ModelRouter(classifier: chosen, cloudLimit: cloudLimit, cap: cap)
    }

    /// Today's cloud request cap on this vault.
    func cap(store: VaultStore, activity: any ActivityRecorder) -> CloudRequestCap {
        CloudRequestCap(store: store, limit: dailyCap, activity: activity)
    }

    // MARK: Embeddings (ADR-0023)

    var embedding: EmbeddingChoice? { stored.embedding }

    /// The providers that offer `/v1/embeddings`: every OpenAI-compatible one (not Anthropic).
    var embeddingProviders: [ProviderConfig] { providers.filter { $0.endpoint.kind == .openAICompatible } }

    var embeddingProvider: ProviderConfig? { stored.embedding.flatMap { e in providers.first { $0.id == e.provider } } }

    func setEmbedding(_ choice: EmbeddingChoice?) {
        guard choice != stored.embedding else { return }
        stored.embedding = choice
        save()
        embeddingInputsChanged()
    }

    func setEmbedsAgentTasks(_ on: Bool) {
        guard var choice = stored.embedding, choice.embedsAgentTasks != on else { return }
        choice.embedsAgentTasks = on
        setEmbedding(choice)
    }

    func setCalibration(_ thresholds: CalibratedThresholds, for modelID: String) {
        var all = stored.calibrations ?? [:]
        all[modelID] = thresholds
        stored.calibrations = all
        save()
        embeddingInputsChanged()
    }

    /// What it takes to build the chosen provider model's client: the endpoint, model, key and any
    /// calibrated thresholds. `make()` resolves the locality (a DNS lookup), so call it off the
    /// main thread.
    func embeddingRecipe(_ choice: EmbeddingChoice? = nil) -> EmbeddingRecipe? {
        guard let choice = choice ?? stored.embedding, let provider = providers.first(where: { $0.id == choice.provider }),
              provider.endpoint.kind == .openAICompatible else { return nil }
        let id = OpenAICompatibleEmbedder.modelID(provider: provider.endpoint.id, model: choice.model)
        let info = stored.calibrations?[id].map {
            EmbeddingModelInfo(id: id, dimensions: $0.dimensions, vaultThreshold: $0.vault, retrievalThreshold: $0.retrieval)
        }
        return EmbeddingRecipe(endpoint: provider.endpoint, model: choice.model, info: info, dimensions: choice.dimensions,
                               key: (try? keys.key(for: provider.endpoint.id)) ?? nil)
    }

    /// Adds embedding tokens to a provider's counters (FR-AI-12).
    func addUsage(_ used: ProviderUsage, for id: String) {
        guard used.requests > 0 else { return }
        var total = stored.usage[id] ?? ProviderUsage()
        total.requests += used.requests
        total.inputTokens += used.inputTokens
        stored.usage[id] = total
        save()
    }

    /// Adds a router's counts to the stored ones and resets the router (FR-AI-12).
    func collectUsage(from router: ModelRouter) {
        let counts = router.usageCounters()
        guard !counts.isEmpty else { return }
        router.resetUsage()
        for (id, used) in counts {
            var total = stored.usage[id.rawValue] ?? ProviderUsage()
            total.requests += used.requests
            total.inputTokens += used.inputTokens
            total.outputTokens += used.outputTokens
            stored.usage[id.rawValue] = total
        }
        save()
    }

    func resetUsage() {
        stored.usage = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
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
