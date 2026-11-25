import Foundation
import FunesProtocol

/// Settings ▸ AI ▸ Features ▸ Facts (FR-F-01, model providers §4), stored in user defaults with the other AI settings
/// and never exported (storage §5.2). Off by default. Facts never follows another task: its choice is any configured
/// model; the ones Funes tested are recommended (ADR-0032, amended 2026-11-24).
public struct FactsSettings: Codable, Hashable, Sendable {
    /// *Learn from memories*: makes the model calls.
    public var learn = false
    /// *Use in search and answers*: what's known is used in search and answers (13b, 13d read it).
    public var use = false
    /// The chosen model; nil is the default, a tested model (Claude Haiku 5.5 on the Claude plan) on the first account
    /// that can run it.
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

/// A model the Facts picker offers: an account (or plan) and a model the app can build a Facts client for. Every model
/// configured on an account or plan is one; a tested engine that the plan's list doesn't name (the list holds aliases)
/// is added (model providers §4).
public struct FactsOffer: Hashable, Sendable {
    public var account: String
    /// The model id as configured, or a tested engine's full id ("claude-haiku-5-5").
    public var model: String
    public var engine: FactsEngine
    /// Funes tested this engine for every call group (memory processing §11.10): the picker marks it *Recommended*.
    public var tested: Bool

    public var choice: ModelChoice { ModelChoice(account: account, model: model) }
}

/// What the Facts task runs on (model providers §4): the chosen offer, for every call group. One account, so one
/// destination to disclose.
public struct FactsResolution: Hashable, Sendable {
    public var chosen: FactsOffer?

    /// The account the calls go to.
    public var account: String? { chosen?.account }

    /// Each call group's engine: the chosen one's, for every group; none without a choice.
    public func engines(_ registry: FactsRegistry = .bundled) -> [String: FactsEngine] {
        guard let chosen else { return [:] }
        return Dictionary(uniqueKeysWithValues: registry.callGroups.keys.map { ($0, chosen.engine) })
    }
}

/// Why Facts can't learn as chosen, from configuration only.
public enum FactsProblem: Hashable, Sendable {
    /// No account or plan here offers a model.
    case noModel
    /// The choice isn't offered any more (or there's no default to fall back on).
    case chooseModel
    /// The chosen account can't run now.
    case account(String, AccountProblem)
}

/// Builds Facts clients, for the picker's offers and for the runner alike, so the engine an offer names is the engine
/// the runner's client reports (the runner still drops a client whose engine differs from its offer).
public enum FactsClients {
    /// The full model id Facts suggests by default (tested on the Claude plan).
    public static let defaultModel = "claude-haiku-5-5"

    /// The provider id an account's or plan's clients report.
    static func providerID(_ account: String, in settings: AISettings) -> ProviderID? {
        if let kind = PlanKind(rawValue: account) { return kind.providerID }
        return settings.account(account)?.endpoint.id
    }

    /// Whether a record can speak for an account's engine: a plan, or an HTTP account at its preset's own address.
    static func canBeTested(_ account: String, in settings: AISettings) -> Bool {
        if PlanKind(rawValue: account) != nil { return true }
        return settings.account(account).map { isCanonical($0.endpoint) } ?? false
    }

    /// An HTTP account is tested only at its preset's own address (same id, kind and base URL, ignoring case in the scheme
    /// and host and a trailing slash): a proxy or a renamed server runs Facts, but never as *Recommended*.
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
        guard let a = settings.account(account) else { throw ProviderError.unavailable }
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
    /// The offers, in picker order: the tested ones first, then the rest, each in account order (accounts, then the
    /// plans in `plans`). `qualification` only says which are tested.
    func factsOffers(qualification: FactsQualification, registry: FactsRegistry = .bundled, plans: [PlanKind] = PlanKind.allCases)
        -> [FactsOffer] {
        let versions = FactsQualification.promptVersions(registry)
        let recorded = qualification.records.map(\.model).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var tested: [FactsOffer] = [], rest: [FactsOffer] = []
        for account in accounts.map(\.id) + plans.map(\.rawValue) {
            guard let provider = FactsClients.providerID(account, in: self) else { continue }
            let testable = FactsClients.canBeTested(account, in: self)
            let listed = (models(of: account) ?? []).filter { !$0.isEmpty }
            // A recorded model this account's provider serves, by its full id, when the list doesn't name it.
            let extra = testable ? recorded.filter { $0.hasPrefix(provider.rawValue + "/") }
                .map { String($0.dropFirst(provider.rawValue.count + 1)) } : []
            var seen = Set<String>()
            for model in extra + listed where seen.insert(model).inserted {
                guard let engine = FactsClients.engine(account: account, model: model, settings: self) else { continue }
                let isTested = testable && qualification.tested(engine, registry: registry, promptVersions: versions)
                let offer = FactsOffer(account: account, model: model, engine: engine, tested: isTested)
                if isTested { tested.append(offer) } else if listed.contains(model) { rest.append(offer) }
            }
        }
        return tested + rest
    }

    /// The chosen offer, or with no choice the default: a tested offer on the first account that can run it (else the
    /// first tested one), else Claude Haiku 5.5 likewise. The default is a suggestion; any offer can be chosen.
    func factsResolution(offers: [FactsOffer], runnable: (String) -> Bool = { _ in true }) -> FactsResolution {
        if let choice = facts.choice {
            return FactsResolution(chosen: offers.first { $0.account == choice.account && $0.model == choice.model })
        }
        for pool in [offers.filter(\.tested), offers.filter { $0.model == FactsClients.defaultModel }] where !pool.isEmpty {
            return FactsResolution(chosen: pool.first { runnable($0.account) } ?? pool.first)
        }
        return FactsResolution()
    }

    /// Why Facts can't learn as chosen: no model here, the choice gone, or its account.
    func factsProblem(offers: [FactsOffer], resolution: FactsResolution, accountProblem: (String) -> AccountProblem?) -> FactsProblem? {
        if offers.isEmpty { return .noModel }
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
/// next job): the chosen offer, with what building its client needs, read on the main actor; the client itself is
/// built where it runs (`router`).
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
    public var cloudLimit: CloudLimit
    public var cap: CloudRequestCap?
    public var backoff: ProviderBackoff

    public init(settings: AISettings, chosen: Recipe, cloudLimit: CloudLimit, cap: CloudRequestCap?, backoff: ProviderBackoff) {
        self.settings = settings
        self.chosen = chosen
        self.cloudLimit = cloudLimit
        self.cap = cap
        self.backoff = backoff
    }

    /// A recipe's client, only when its engine is the one its offer names (otherwise none: the memories wait, rather
    /// than a different engine reading them).
    func client(_ recipe: Recipe) -> (any GenerationProvider)? {
        guard let c = try? FactsClients.make(account: recipe.offer.account, model: recipe.offer.model, settings: settings,
                                             executable: recipe.executable, key: recipe.key),
              FactsEngine(c) == recipe.offer.engine else { return nil }
        return c
    }

    /// The router: the chosen model for every call group (`FactsQualification.resolve`). No classifier, no Apple
    /// on-device.
    public func router(registry: FactsRegistry = .bundled) -> ModelRouter {
        let models = FactsQualification.resolve(chosen: client(chosen), registry: registry)
        return ModelRouter(classifier: nil, onDevice: nil, cloudLimit: cloudLimit, cap: cap, backoff: backoff, factsModels: models)
    }
}

/// How a model's full id reads in Facts' settings: "claude-haiku-5-5" → "Claude Haiku 5.5". Derived from the id's own
/// parts (family, version) for Claude ids, so a new Claude model needs no table; any other id reads as written. Records, offers and the stored choice keep the full id; this is for display only.
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
