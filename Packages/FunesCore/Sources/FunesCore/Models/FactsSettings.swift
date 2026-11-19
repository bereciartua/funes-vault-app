import Foundation
import FunesProtocol

/// Settings ▸ AI ▸ Features ▸ Facts (FR-F-01, model providers §4), stored in user defaults with the other AI settings
/// and never exported (storage §5.2). Off by default. Facts never follows another task: its choice is a qualified model.
public struct FactsSettings: Codable, Hashable, Sendable {
    /// *Learn from memories*: makes the model calls.
    public var learn = false
    /// *Use in search and answers*: what's known is used in search and answers (13b, 13d read it).
    public var use = false
    /// The chosen model; nil is the default, Claude Haiku 5.5 from the first account that offers it qualified.
    public var choice: ModelChoice?

    public init(learn: Bool = false, use: Bool = false, choice: ModelChoice? = nil) {
        self.learn = learn
        self.use = use
        self.choice = choice
    }

    private enum CodingKeys: String, CodingKey { case learn, use, choice }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        learn = try c.decodeIfPresent(Bool.self, forKey: .learn) ?? false
        use = try c.decodeIfPresent(Bool.self, forKey: .use) ?? false
        choice = try c.decodeIfPresent(ModelChoice.self, forKey: .choice)
    }
}

/// A model the Facts picker may offer: an account (or plan) and a full model id whose engine, as this app builds it,
/// a qualification record covers for at least one call group (memory processing §11.10).
public struct FactsOffer: Hashable, Sendable {
    public var account: String
    /// The full model id ("claude-haiku-5-5"), never an alias: a record names a full id.
    public var model: String
    /// The call groups it qualified for.
    public var groups: Set<String>
    public var engine: FactsEngine

    public var choice: ModelChoice { ModelChoice(account: account, model: model) }
}

/// What the Facts task runs on (model providers §4): the chosen offer, and Claude Haiku 5.5 on the same account for the
/// groups the chosen one didn't qualify for. One account, so one destination to disclose.
public struct FactsResolution: Hashable, Sendable {
    public var chosen: FactsOffer?
    public var fallback: FactsOffer?

    /// The groups some model reads.
    public var groups: Set<String> { (chosen?.groups ?? []).union(fallback?.groups ?? []) }
    /// The account the calls go to.
    public var account: String? { chosen?.account }
}

/// Why Facts can't learn as chosen, from configuration only.
public enum FactsProblem: Hashable, Sendable {
    /// No model has passed Funes's tests for Facts (what ships until 13a.2's Gates step writes records).
    case nothingQualified
    /// Some model qualified, but no account here can run it: these are the qualified model ids.
    case needsAccount([String])
    /// The choice isn't offered any more (or there's no default to fall back on).
    case chooseModel
    /// The chosen account can't run now.
    case account(String, AccountProblem)
}

/// Builds Facts clients, for the picker's offers and for the runner alike, so the engine an offer names is the engine
/// the runner's client reports (the runner still drops a client whose engine differs from its offer).
public enum FactsClients {
    /// The full model id Facts defaults to, and falls back on per call group.
    public static let defaultModel = "claude-haiku-5-5"

    /// The provider id an account's or plan's clients report.
    static func providerID(_ account: String, in settings: AISettings) -> ProviderID? {
        if let kind = PlanKind(rawValue: account) { return kind.providerID }
        guard let a = settings.account(account), isCanonical(a.endpoint) else { return nil }
        return a.endpoint.id
    }

    /// An HTTP account counts only at its preset's own address (same id, kind and base URL, ignoring case in the scheme
    /// and host and a trailing slash): a proxy or a renamed server can't inherit a record made against the real provider.
    static func isCanonical(_ endpoint: ProviderEndpoint) -> Bool {
        func normalized(_ url: URL) -> String {
            var s = url.absoluteString
            if var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let scheme = c.scheme?.lowercased(), host = c.host?.lowercased()
                c.scheme = scheme
                c.host = host
                s = c.string ?? s
            }
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return [ProviderEndpoint.anthropic(), .openAI(), .ollama(), .lmStudio()].contains {
            $0.id == endpoint.id && $0.kind == endpoint.kind && normalized($0.baseURL) == normalized(endpoint.baseURL)
        }
    }

    /// A client for an account's or plan's model. A plan needs its CLI's path; an API account its key.
    public static func make(account: String, model: String, settings: AISettings, executable: String?,
                            key: String?) throws -> any GenerationProvider {
        if let kind = PlanKind(rawValue: account) {
            guard let executable else { throw ProviderError.unavailable }
            switch kind {
            case .claudeCode: return ClaudeCodeClient(executable: executable, model: model)
            case .codex: return CodexClient(executable: executable, model: model, allowsFileReads: settings.codexAllowsFileReads)
            }
        }
        guard let a = settings.account(account), isCanonical(a.endpoint) else { throw ProviderError.unavailable }
        switch a.endpoint.kind {
        case .anthropic:
            guard let key, !key.isEmpty else { throw ProviderError.unauthorized }
            return try AnthropicClient(endpoint: a.endpoint, model: model, apiKey: key)
        case .openAICompatible:
            return try OpenAICompatibleClient(endpoint: a.endpoint, model: model, apiKey: key)
        }
    }

    /// The engine `make` would build, without building an HTTP client (which resolves the host): a plan's client is
    /// built with a placeholder path (its engine doesn't depend on it); an HTTP client reports its endpoint id as both
    /// provider and adapter (`GenerationProvider.factsAdapter`'s default). A test checks each against a built client.
    static func engine(account: String, model: String, settings: AISettings) -> FactsEngine? {
        if PlanKind(rawValue: account) != nil {
            return (try? make(account: account, model: model, settings: settings, executable: "/usr/bin/false", key: nil))
                .map { FactsEngine($0) }
        }
        guard let id = providerID(account, in: settings) else { return nil }
        return FactsEngine(model: "\(id.rawValue)/\(model)", adapter: id.rawValue)
    }
}

public extension AISettings {
    /// The offers, in picker order (accounts, then the plans in `plans`), from what `qualification` turns on now.
    func factsOffers(qualification: FactsQualification, registry: FactsRegistry = .bundled, plans: [PlanKind] = PlanKind.allCases)
        -> [FactsOffer] {
        let versions = FactsQualification.promptVersions(registry)
        let models = qualification.records.map(\.model).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var out: [FactsOffer] = []
        for account in accounts.map(\.id) + plans.map(\.rawValue) {
            guard let provider = FactsClients.providerID(account, in: self) else { continue }
            for full in models where full.hasPrefix(provider.rawValue + "/") {
                let model = String(full.dropFirst(provider.rawValue.count + 1))
                guard let engine = FactsClients.engine(account: account, model: model, settings: self), engine.model == full else { continue }
                let groups = Set(registry.callGroups.keys.filter {
                    qualification.qualifies(engine, group: $0, registry: registry, promptVersions: versions)
                })
                if !groups.isEmpty { out.append(FactsOffer(account: account, model: model, groups: groups, engine: engine)) }
            }
        }
        return out
    }

    /// The chosen offer (or the default: Claude Haiku 5.5 on the first account that can run it, else the first that
    /// offers it), and Haiku on the same account for the groups the chosen one doesn't cover.
    func factsResolution(offers: [FactsOffer], runnable: (String) -> Bool = { _ in true }) -> FactsResolution {
        let chosen: FactsOffer?
        if let choice = facts.choice {
            chosen = offers.first { $0.account == choice.account && $0.model == choice.model }
        } else {
            let haiku = offers.filter { $0.model == FactsClients.defaultModel }
            chosen = haiku.first { runnable($0.account) } ?? haiku.first
        }
        guard let chosen else { return FactsResolution() }
        let fallback = chosen.model == FactsClients.defaultModel ? nil
            : offers.first { $0.account == chosen.account && $0.model == FactsClients.defaultModel && !$0.groups.isSubset(of: chosen.groups) }
        return FactsResolution(chosen: chosen, fallback: fallback)
    }

    /// Why Facts can't learn as chosen: nothing qualified, no account for what did, the choice gone, or its account.
    func factsProblem(qualification: FactsQualification, offers: [FactsOffer], resolution: FactsResolution,
                      registry: FactsRegistry = .bundled, accountProblem: (String) -> AccountProblem?) -> FactsProblem? {
        if offers.isEmpty {
            let versions = FactsQualification.promptVersions(registry)
            let qualified = qualification.records.filter {
                qualification.qualifies($0.engine, group: $0.callGroup, registry: registry, promptVersions: versions)
            }
            guard !qualified.isEmpty else { return .nothingQualified }
            let ids = qualified.map { String($0.model.split(separator: "/", maxSplits: 1).last ?? "") }
            return .needsAccount(ids.reduce(into: []) { if !$0.contains($1) { $0.append($1) } })
        }
        guard let account = resolution.account else { return .chooseModel }
        return accountProblem(account).map { .account(account, $0) }
    }
}

public extension Profile {
    /// The names Facts matches to *you* (memory processing §11.3, "the names from About you"): the given and preferred
    /// names, each alone and with the family name. Never the family name alone, which relatives share. Trimmed, without
    /// empty or one-letter names, without repeats (case-insensitive).
    var factsAliases: [String] {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), t.count > 1 else { return nil }
            return t
        }
        let family = clean(familyName)
        var out: [String] = []
        for first in [clean(givenName), clean(preferredName)].compactMap({ $0 }) {
            for name in [first, family.map { "\(first) \($0)" }].compactMap({ $0 })
            where !out.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                out.append(name)
            }
        }
        return out
    }
}

/// What one facts job runs with (the Mac's runner builds one per job, so a settings or profile change applies at the
/// next job): the chosen offer and its fallback, each with what building its client needs, read on the main actor;
/// the clients themselves are built where it runs (`router`).
public struct FactsConfiguration: Sendable {
    public struct Recipe: Sendable {
        public var offer: FactsOffer
        /// A plan's CLI, when found.
        public var executable: String?
        /// An API account's key.
        public var key: String?

        public init(offer: FactsOffer, executable: String?, key: String?) {
            self.offer = offer
            self.executable = executable
            self.key = key
        }
    }

    public var settings: AISettings
    public var chosen: Recipe
    public var fallback: Recipe?
    public var cloudLimit: CloudLimit
    public var cap: CloudRequestCap?
    public var backoff: ProviderBackoff

    public init(settings: AISettings, chosen: Recipe, fallback: Recipe?, cloudLimit: CloudLimit, cap: CloudRequestCap?,
                backoff: ProviderBackoff) {
        self.settings = settings
        self.chosen = chosen
        self.fallback = fallback
        self.cloudLimit = cloudLimit
        self.cap = cap
        self.backoff = backoff
    }

    /// A recipe's client, only when its engine is the one its offer qualified (otherwise none: that group's memories
    /// wait, rather than a different engine reading them).
    func client(_ recipe: Recipe) -> (any GenerationProvider)? {
        guard let c = try? FactsClients.make(account: recipe.offer.account, model: recipe.offer.model, settings: settings,
                                             executable: recipe.executable, key: recipe.key),
              FactsEngine(c) == recipe.offer.engine else { return nil }
        return c
    }

    /// The router: each call group's model from `qualification` (the shipped records with the local off-switches read
    /// now), the chosen one where it qualified, else the fallback (`FactsQualification.resolve`). No classifier, no
    /// Apple on-device.
    public func router(qualification: FactsQualification, registry: FactsRegistry = .bundled) -> ModelRouter {
        let models = qualification.resolve(chosen: client(chosen), fallback: fallback.flatMap(client), registry: registry,
                                           promptVersions: FactsQualification.promptVersions(registry))
        return ModelRouter(classifier: nil, onDevice: nil, cloudLimit: cloudLimit, cap: cap, backoff: backoff, factsModels: models)
    }
}

/// How a model's full id reads in Facts' settings: "claude-haiku-5-5" → "Claude Haiku 5.5". Derived from the id's own
/// parts (family, version) for Claude ids, the only ones Facts offers, so a new Claude model needs no table; any other
/// id reads as written. Records, offers and the stored choice keep the full id; this is for display only.
public enum FactsModelName {
    public static func display(_ id: String) -> String {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "claude", parts.allSatisfy({ !$0.isEmpty }) else { return id }
        func digits(_ s: String) -> Bool { s.allSatisfy { $0.isASCII && $0.isNumber } }
        let version = parts.drop { !digits($0) }
        let words = parts.prefix { !digits($0) }
        // A version is one or two short numbers ("5-5"); a date suffix or anything else keeps the id as written.
        guard words.count >= 2, !version.isEmpty, version.count <= 2,
              version.allSatisfy({ $0.count <= 2 && digits($0) }),
              words.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isLetter } }) else { return id }
        return (words.map { $0.prefix(1).uppercased() + $0.dropFirst() } + [version.joined(separator: ".")]).joined(separator: " ")
    }
}
