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
        guard let provider = classifier, !provider.model.isEmpty, case .upTo = cloudLimit else { return nil }
        if provider.endpoint.kind == .anthropic && !hasKey(provider.id) { return nil }
        let endpoint = provider.endpoint
        let local = await Task.detached(priority: .utility) { endpoint.locality().isLocal }.value
        return local ? nil : provider.name
    }

    /// The router for this choice: the chosen provider, then Apple on-device, then rules.
    func makeRouter() -> ModelRouter {
        let chosen = classifier.flatMap { try? client(for: $0) }
        return ModelRouter(classifier: chosen, cloudLimit: cloudLimit)
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
