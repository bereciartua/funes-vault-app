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

/// Settings ▸ AI Models (FR-AI-05..08, FR-AI-12): providers, the Classification choice, the cloud
/// limit and usage counters, in user defaults (storage §1). v0.1's embeddings are the bundled
/// bge-small only (ADR-0016), so there's nothing to choose for them.
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
    }

    static let defaultsKey = "AIModels"
    private let defaults: UserDefaults
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
        set { stored.cloudLimit = newValue; save() }
    }

    var classifier: ProviderConfig? { stored.classifier.flatMap { id in providers.first { $0.id == id } } }

    // MARK: Subscriptions (ADR-0024)

    /// Each plan's model; the first suggestion until the user picks another.
    func subscription(_ kind: SubscriptionConfig.Kind) -> SubscriptionConfig {
        stored.subscriptions?.first { $0.kind == kind } ?? SubscriptionConfig(kind: kind, model: kind.suggestedModels[0])
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
        case .codex: return CodexClient(executable: path, model: model)
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
    }

    /// Removing a provider deletes its key (FR-AI-06).
    func remove(_ id: String) {
        try? keys.deleteKey(for: ProviderID(rawValue: id))
        stored.providers.removeAll { $0.id == id }
        if stored.classifier == id { stored.classifier = nil }
        stored.usage[id] = nil
        save()
    }

    func hasKey(_ id: String) -> Bool { ((try? keys.key(for: ProviderID(rawValue: id))) ?? nil)?.isEmpty == false }

    /// A client for a provider, with its key from the Keychain.
    func client(for provider: ProviderConfig) throws -> any GenerationProvider {
        let key = try keys.key(for: provider.endpoint.id)
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
