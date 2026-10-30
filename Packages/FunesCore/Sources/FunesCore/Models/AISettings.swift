import Foundation
import FunesProtocol

// Settings ▸ AI's stored shape and the rules on it (ADR-0030 §6, model providers §4): accounts and
// plans that each offer several chat models, and what each job chose. No localized text: the app
// turns these facts into words.

/// A plan used through the user's own CLI (ADR-0024): Claude through Claude Code, ChatGPT through
/// Codex. Always listed; never added or removed.
public enum PlanKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudeCode = "claude-code"
    case codex
    public var id: String { rawValue }

    /// The plan's name: "Claude", "ChatGPT".
    public var plan: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "ChatGPT"
        }
    }

    /// The CLI's name: "Claude Code", "Codex".
    public var tool: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    public var command: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    /// What to run in Terminal to sign in.
    public var signIn: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex login"
        }
    }

    /// A new plan's models (ADR-0030 §6).
    public var suggestedModels: [String] {
        switch self {
        case .claudeCode: ClaudeCodeClient.suggestedModels
        case .codex: CodexClient.suggestedModels
        }
    }

    /// The id its client counts usage and CLI blocks under.
    public var providerID: ProviderID {
        switch self {
        case .claudeCode: ClaudeCodeClient.providerID
        case .codex: CodexClient.providerID
        }
    }
}

/// An API or local-server account (model providers §4): the endpoint, a name, and its chat models
/// in the user's order. The key is in the Keychain under the endpoint's id, never here.
public struct AIAccount: Codable, Hashable, Sendable, Identifiable {
    public var endpoint: ProviderEndpoint
    public var name: String
    public var models: [String]
    public var id: String { endpoint.id.rawValue }

    public init(endpoint: ProviderEndpoint, name: String, models: [String] = []) {
        self.endpoint = endpoint
        self.name = name
        self.models = models
    }

    /// Anthropic always needs a key; so does OpenAI's own endpoint. Other servers may not.
    public var requiresKey: Bool {
        endpoint.kind == .anthropic || endpoint.id == ProviderEndpoint.openAI().id
    }

    /// Only OpenAI-compatible accounts offer `/v1/embeddings` (the second index).
    public var offersEmbeddings: Bool { endpoint.kind == .openAICompatible }
}

/// A plan's chat models (ADR-0030 §6): never empty once stored.
public struct AIPlan: Codable, Hashable, Sendable, Identifiable {
    public var kind: PlanKind
    public var models: [String]
    public var id: String { kind.rawValue }

    public init(kind: PlanKind, models: [String]) {
        self.kind = kind
        self.models = models
    }
}

/// An account and one of its models. `model` is nil only after the conversion, for an account
/// that had none: the choice is unresolved and never borrows another job's model.
public struct ModelChoice: Codable, Hashable, Sendable {
    public var account: String
    public var model: String?

    public init(account: String, model: String?) {
        self.account = account
        self.model = model
    }
}

/// The three jobs a chat model does (ADR-0030 §3).
public enum AIJob: String, Codable, Sendable, CaseIterable {
    case newMemories, tidyUp, searchAnswers

    /// Its choice when nothing else is set: New memories Apple on-device, the others follow it.
    public var defaultChoice: JobChoice { self == .newMemories ? .onDevice : .followsNewMemories }

    /// Whether this job may follow New memories, or use Apple on-device (never the tidy-up: Spike E,
    /// 8 of 49 actions right).
    public var canFollow: Bool { self != .newMemories }
    public var canUseOnDevice: Bool { self != .tidyUp }
}

/// A job's choice (ADR-0030 §6): it follows New memories, it's Apple on-device, or an account and
/// model.
public enum JobChoice: Hashable, Sendable, Codable {
    case followsNewMemories
    case onDevice
    case model(ModelChoice)

    private enum CodingKeys: String, CodingKey { case kind, account, model }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "follows": self = .followsNewMemories
        case "on-device": self = .onDevice
        case "model":
            self = .model(ModelChoice(account: try c.decode(String.self, forKey: .account),
                                      model: try c.decodeIfPresent(String.self, forKey: .model)))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown job choice")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .followsNewMemories: try c.encode("follows", forKey: .kind)
        case .onDevice: try c.encode("on-device", forKey: .kind)
        case let .model(choice):
            try c.encode("model", forKey: .kind)
            try c.encode(choice.account, forKey: .account)
            try c.encodeIfPresent(choice.model, forKey: .model)
        }
    }

    public var modelChoice: ModelChoice? { if case let .model(choice) = self { choice } else { nil } }
}

/// What a job runs on once following is worked out.
public enum EffectiveModel: Hashable, Sendable {
    /// Apple's on-device model (New memories falls back to rules when it's unavailable).
    case onDevice
    /// The tidy-up with no model: its code-only rules.
    case rules
    case model(account: String, model: String)
    /// An account chosen without a model: New memories runs on-device then rules, the tidy-up its
    /// rules, Search answers is unavailable.
    case unresolved(account: String)

    public var account: String? {
        switch self {
        case let .model(account, _), let .unresolved(account): account
        case .onDevice, .rules: nil
        }
    }

    public var model: String? { if case let .model(_, model) = self { model } else { nil } }
}

/// A job's effective model, and whether it got it by following New memories.
public struct Resolution: Hashable, Sendable {
    public var model: EffectiveModel
    public var follows: Bool
}

/// A provider embedding model as the second index (ADR-0023, FR-AI-11): which account and model,
/// its dimensions when Funes doesn't know the model, and whether agents' tasks are embedded with it
/// (FR-AI-09, on by default).
public struct EmbeddingChoice: Codable, Hashable, Sendable {
    public var provider: String
    public var model: String
    public var dimensions: Int?
    public var embedsAgentTasks = true

    public init(provider: String, model: String, dimensions: Int? = nil, embedsAgentTasks: Bool = true) {
        self.provider = provider
        self.model = model
        self.dimensions = dimensions
        self.embedsAgentTasks = embedsAgentTasks
    }
}

/// Thresholds Calibrate measured for a model (model providers §8), by `<account>/<model>`.
public struct CalibratedThresholds: Codable, Hashable, Sendable {
    public var dimensions: Int
    public var vault: Float
    public var retrieval: Float

    public init(dimensions: Int, vault: Float, retrieval: Float) {
        self.dimensions = dimensions
        self.vault = vault
        self.retrieval = retrieval
    }
}

/// Why an account can't run now (ADR-0030 §6): from configuration and the plans' checks, never
/// from a probe.
public enum AccountProblem: Hashable, Sendable {
    case noKey
    case notInstalled
    case notSignedIn
    case needsUpdate
    case unsupported
    /// Codex, until the user accepts that it can read files.
    case needsFileReadOK
    /// A CLI that showed a tool event, until Test Connection passes.
    case paused
}

/// Why a job can't run as chosen: the orange label on its Features row.
public enum JobProblem: Hashable, Sendable {
    case chooseModel
    case account(String, AccountProblem)
    case onDeviceUnavailable
}

/// Who uses an account (Models & Accounts' "Used by").
public enum AccountUse: Hashable, Sendable {
    case job(AIJob, model: String?, follows: Bool)
    case secondIndex(model: String)
}

/// One account's models in a job's picker, with why it can't run now.
public struct PickerSection: Hashable, Sendable {
    public var account: String
    public var models: [String]
    public var problem: AccountProblem?
}

/// What removing a model or an account changes, for its confirmation (ADR-0030 §6).
public struct RemovalEffect: Hashable, Sendable {
    /// Jobs that chose it directly: reset to their default.
    public var direct: [AIJob] = []
    /// Jobs that follow New memories when New memories is among `direct`: they keep following.
    public var followers: [AIJob] = []
    /// Removing an account that the second index uses: indexing stops and its vectors go.
    public var secondIndex = false

    public var isEmpty: Bool { direct.isEmpty && followers.isEmpty && !secondIndex }
}

/// Settings ▸ AI, as stored in user defaults under `AIModels` (ADR-0030 §6). Keys, usage and
/// calibrations are by account id; locality is by endpoint.
public struct AISettings: Codable, Hashable, Sendable {
    /// 2 from v0.8; the v1 shape has no version and is converted once.
    public var version = 2
    public var accounts: [AIAccount] = []
    /// The plans' models; a plan without a record has its suggestions.
    public var plans: [AIPlan] = []
    public var newMemories: JobChoice = .onDevice
    public var tidyUp: JobChoice = .followsNewMemories
    public var searchAnswers: JobChoice = .followsNewMemories
    /// The second index (v0.3); nil: bge-small only.
    public var embedding: EmbeddingChoice?
    public var cloudLimit: CloudLimit = .upTo(.internal)
    /// Cloud requests per day (ADR-0022); nil is the default, 300.
    public var dailyCap: Int?
    /// The user accepted that Codex can run commands that read files (ADR-0024); off by default.
    public var codexAllowsFileReads = false
    /// By account id (a plan's is its kind), across its models (FR-AI-12).
    public var usage: [String: ProviderUsage] = [:]
    /// Calibrate's thresholds, by stored model id (`<account>/<model>`).
    public var calibrations: [String: CalibratedThresholds] = [:]
    /// Search answers (FR-AI-17): on or off, the default.
    public var searchAnswersOn = false
    /// When they're on, when a search is answered.
    public var searchAnswersTrigger: AnswerTrigger = .ask

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, accounts, plans, newMemories, tidyUp, searchAnswers, embedding, cloudLimit, dailyCap
        case codexAllowsFileReads, usage, calibrations, searchAnswersOn, searchAnswersTrigger
    }

    /// Every field but the version may be missing, so a field added later reads as its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        accounts = try c.decodeIfPresent([AIAccount].self, forKey: .accounts) ?? []
        plans = try c.decodeIfPresent([AIPlan].self, forKey: .plans) ?? []
        newMemories = try c.decodeIfPresent(JobChoice.self, forKey: .newMemories) ?? .onDevice
        tidyUp = try c.decodeIfPresent(JobChoice.self, forKey: .tidyUp) ?? .followsNewMemories
        searchAnswers = try c.decodeIfPresent(JobChoice.self, forKey: .searchAnswers) ?? .followsNewMemories
        embedding = try c.decodeIfPresent(EmbeddingChoice.self, forKey: .embedding)
        cloudLimit = try c.decodeIfPresent(CloudLimit.self, forKey: .cloudLimit) ?? .upTo(.internal)
        dailyCap = try c.decodeIfPresent(Int.self, forKey: .dailyCap)
        codexAllowsFileReads = try c.decodeIfPresent(Bool.self, forKey: .codexAllowsFileReads) ?? false
        usage = try c.decodeIfPresent([String: ProviderUsage].self, forKey: .usage) ?? [:]
        calibrations = try c.decodeIfPresent([String: CalibratedThresholds].self, forKey: .calibrations) ?? [:]
        searchAnswersOn = try c.decodeIfPresent(Bool.self, forKey: .searchAnswersOn) ?? false
        searchAnswersTrigger = try c.decodeIfPresent(AnswerTrigger.self, forKey: .searchAnswersTrigger) ?? .ask
    }

    // MARK: Accounts and plans

    public func account(_ id: String) -> AIAccount? { accounts.first { $0.id == id } }

    /// A plan's record, or its suggestions without one.
    public func plan(_ kind: PlanKind) -> AIPlan {
        plans.first { $0.kind == kind } ?? AIPlan(kind: kind, models: kind.suggestedModels)
    }

    /// An account's or plan's models; nil for an id that isn't either.
    public func models(of id: String) -> [String]? {
        if let kind = PlanKind(rawValue: id) { return plan(kind).models }
        return account(id)?.models
    }

    public func exists(_ id: String) -> Bool { models(of: id) != nil }

    /// Adds a chat model to an account or plan: trimmed, never empty or twice. False when nothing
    /// changed.
    @discardableResult
    public mutating func addModel(_ name: String, to id: String) -> Bool {
        let model = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let models = models(of: id), !models.contains(model) else { return false }
        setModels(models + [model], of: id)
        return true
    }

    private mutating func setModels(_ models: [String], of id: String) {
        if let kind = PlanKind(rawValue: id) {
            plans.removeAll { $0.kind == kind }
            plans.append(AIPlan(kind: kind, models: models))
            plans.sort { PlanKind.allCases.firstIndex(of: $0.kind)! < PlanKind.allCases.firstIndex(of: $1.kind)! }
        } else if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].models = models
        }
    }

    /// Adds or replaces an account, its models trimmed and without repeats.
    public mutating func upsert(_ account: AIAccount) {
        var account = account
        var seen = Set<String>()
        account.models = account.models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    /// Everything stored that the second index depends on (ADR-0030 §6 ▸ What re-embeds): the
    /// choice, the cloud limit, its model's calibration, and its account's address and cloud flag.
    /// An account's name and chat models aren't in it. The key, in the Keychain, is the app's to
    /// watch.
    public struct EmbeddingInputs: Hashable, Sendable {
        var choice: EmbeddingChoice?
        var cloudLimit: CloudLimit
        var calibration: CalibratedThresholds?
        var endpoint: ProviderEndpoint?
    }

    public var embeddingInputs: EmbeddingInputs {
        let account = embedding.flatMap { self.account($0.provider) }
        let id = embedding.map { OpenAICompatibleEmbedder.modelID(provider: ProviderID(rawValue: $0.provider), model: $0.model) }
        return EmbeddingInputs(choice: embedding, cloudLimit: cloudLimit, calibration: id.flatMap { calibrations[$0] },
                               endpoint: account?.endpoint)
    }

    // MARK: Choices

    /// A job's choice, as stored, with anything the job can't have read as its default.
    public func choice(_ job: AIJob) -> JobChoice {
        let stored = switch job {
        case .newMemories: newMemories
        case .tidyUp: tidyUp
        case .searchAnswers: searchAnswers
        }
        switch stored {
        case .followsNewMemories where !job.canFollow, .onDevice where !job.canUseOnDevice: return job.defaultChoice
        case let .model(choice) where !exists(choice.account): return job.defaultChoice
        default: return stored
        }
    }

    public mutating func setChoice(_ choice: JobChoice, for job: AIJob) {
        switch job {
        case .newMemories: newMemories = choice
        case .tidyUp: tidyUp = choice
        case .searchAnswers: searchAnswers = choice
        }
    }

    /// What a job runs on: its own choice, or New memories' when it follows; the tidy-up never
    /// runs on Apple on-device (its rules instead), and an unresolved choice stays unresolved.
    public func resolve(_ job: AIJob) -> Resolution {
        let follows = choice(job) == .followsNewMemories
        let source = follows ? choice(.newMemories) : choice(job)
        let model: EffectiveModel = switch source {
        case .followsNewMemories, .onDevice: job == .tidyUp ? .rules : .onDevice
        case let .model(choice):
            choice.model.map { .model(account: choice.account, model: $0) } ?? .unresolved(account: choice.account)
        }
        return Resolution(model: model, follows: follows)
    }

    /// The jobs and second index that use an account, directly or by following New memories.
    public func usedBy(_ id: String) -> [AccountUse] {
        var uses: [AccountUse] = AIJob.allCases.compactMap { job in
            let resolution = resolve(job)
            guard resolution.model.account == id else { return nil }
            return .job(job, model: resolution.model.model, follows: resolution.follows)
        }
        if let embedding, embedding.provider == id { uses.append(.secondIndex(model: embedding.model)) }
        return uses
    }

    // MARK: Problems

    /// Why an account can't run now. `hasKey` is the Keychain's answer; `planStatus` is each
    /// plan's last check (nil until checked); `blocked` is CLIRunner's tool block.
    public func problem(account id: String, hasKey: (String) -> Bool, planStatus: [PlanKind: SubscriptionStatus],
                        blocked: (ProviderID) -> Bool) -> AccountProblem? {
        if let kind = PlanKind(rawValue: id) {
            if blocked(kind.providerID) { return .paused }
            switch planStatus[kind] {
            case nil, .ready?: return nil
            case .notInstalled?: return .notInstalled
            case .notSignedIn?: return .notSignedIn
            case .needsUpdate?: return .needsUpdate
            case .unsupportedFeatures?: return .unsupported
            case .fileReadsNotAllowed?: return .needsFileReadOK
            case .blocked?: return .paused
            }
        }
        guard let account = account(id) else { return nil }
        return account.requiresKey && !hasKey(id) ? .noKey : nil
    }

    /// Why a job can't run as chosen, from configuration only (ADR-0030 §6).
    public func problem(_ job: AIJob, hasKey: (String) -> Bool, planStatus: [PlanKind: SubscriptionStatus],
                        blocked: (ProviderID) -> Bool, onDeviceAvailable: Bool) -> JobProblem? {
        switch resolve(job).model {
        case .rules: return nil
        case .onDevice: return onDeviceAvailable ? nil : .onDeviceUnavailable
        case .unresolved: return .chooseModel
        case let .model(account, _):
            return problem(account: account, hasKey: hasKey, planStatus: planStatus, blocked: blocked).map { .account(account, $0) }
        }
    }

    /// A job's picker: every account's models, then each plan's when its CLI is found or it's the
    /// current choice (ADR-0030 §6). An account with no models is listed with none.
    public func pickerSections(_ job: AIJob, installedPlans: Set<PlanKind>, hasKey: (String) -> Bool,
                               planStatus: [PlanKind: SubscriptionStatus], blocked: (ProviderID) -> Bool) -> [PickerSection] {
        let chosen = choice(job).modelChoice?.account
        let plans = PlanKind.allCases.filter { installedPlans.contains($0) || chosen == $0.rawValue }.map(\.rawValue)
        return (accounts.map(\.id) + plans).map { id in
            PickerSection(account: id, models: models(of: id) ?? [],
                          problem: problem(account: id, hasKey: hasKey, planStatus: planStatus, blocked: blocked))
        }
    }

    // MARK: Removal

    /// What removing `model` from an account changes: the jobs that chose it directly, and those
    /// following New memories when New memories is one of them.
    public func removalEffect(model: String, from id: String) -> RemovalEffect {
        let direct = AIJob.allCases.filter { choice($0) == .model(ModelChoice(account: id, model: model)) }
        return RemovalEffect(direct: direct, followers: followers(of: direct))
    }

    /// What removing an account changes: every job that uses it, and the second index.
    public func removalEffect(account id: String) -> RemovalEffect {
        let direct = AIJob.allCases.filter { choice($0).modelChoice?.account == id }
        return RemovalEffect(direct: direct, followers: followers(of: direct), secondIndex: embedding?.provider == id)
    }

    private func followers(of direct: [AIJob]) -> [AIJob] {
        guard direct.contains(.newMemories) else { return [] }
        return AIJob.allCases.filter { $0 != .newMemories && choice($0) == .followsNewMemories }
    }

    /// Whether a model can be removed: a plan keeps at least one.
    public func canRemove(model: String, from id: String) -> Bool {
        guard let models = models(of: id), models.contains(model) else { return false }
        return PlanKind(rawValue: id) == nil || models.count > 1
    }

    /// Removes a chat model and resets the jobs that chose it. The second index is never affected.
    @discardableResult
    public mutating func removeModel(_ model: String, from id: String) -> RemovalEffect {
        guard canRemove(model: model, from: id), let models = models(of: id) else { return RemovalEffect() }
        let effect = removalEffect(model: model, from: id)
        for job in effect.direct { setChoice(job.defaultChoice, for: job) }
        setModels(models.filter { $0 != model }, of: id)
        return effect
    }

    /// Removes an account (never a plan): its jobs reset, its usage cleared, and the second index
    /// cleared if it's this account's. The app deletes its key.
    @discardableResult
    public mutating func removeAccount(_ id: String) -> RemovalEffect {
        guard PlanKind(rawValue: id) == nil, account(id) != nil else { return RemovalEffect() }
        let effect = removalEffect(account: id)
        for job in effect.direct { setChoice(job.defaultChoice, for: job) }
        accounts.removeAll { $0.id == id }
        usage[id] = nil
        if effect.secondIndex { embedding = nil }
        return effect
    }

    // MARK: Usage (FR-AI-12)

    /// Adds counts to an account's, whichever of its models made them.
    public mutating func addUsage(_ used: ProviderUsage, for id: String) {
        guard used.requests > 0 else { return }
        var total = usage[id] ?? ProviderUsage()
        total.requests += used.requests
        total.inputTokens += used.inputTokens
        total.outputTokens += used.outputTokens
        usage[id] = total
    }

    public mutating func resetUsage(for id: String) { usage[id] = nil }
}

// MARK: - What AI features send (ADR-0030 §5)

/// One line of Privacy & Limits' summary: a job that can send something, where, and what.
public struct SendFact: Hashable, Sendable {
    public enum Destination: Hashable, Sendable {
        case onDevice
        /// An account or plan's model, with its locality (cloud until resolved).
        case account(String, model: String, locality: Locality)
    }

    public enum Job: Hashable, Sendable {
        /// Proposals on or splitting on; `splits` sends the split payload.
        case newMemories(splits: Bool)
        /// `scheduled`: every day at its time; otherwise when the user tidies up.
        case tidyUp(scheduled: Bool)
        /// The effective trigger (Apple on-device answers only when asked).
        case searchAnswers(AnswerTrigger)
        /// The second index: memory text unless the cloud limit is Nothing (for a cloud model), and
        /// agents' task descriptions when its switch is on.
        case searchIndex(memoryText: Bool, agentTasks: Bool)
    }

    public var job: Job
    public var destination: Destination
}

public extension AISettings {
    /// The facts behind "What AI features send". `localities` holds each account's resolved
    /// locality (an account not in it counts as cloud); `proposals`, `split` and `tidyUpScheduled`
    /// are the app's switches.
    func sendFacts(proposals: Bool, split: Bool, tidyUpScheduled: Bool, localities: [String: Locality]) -> [SendFact] {
        func destination(_ model: EffectiveModel) -> SendFact.Destination? {
            switch model {
            case .onDevice: .onDevice
            case .rules, .unresolved: nil
            case let .model(account, model):
                .account(account, model: model, locality: PlanKind(rawValue: account) != nil ? .cloud : localities[account] ?? .cloud)
            }
        }
        var facts: [SendFact] = []
        let newMemories = resolve(.newMemories).model
        // An unresolved New memories runs on-device, then rules.
        let newMemoriesDestination = destination(newMemories) ?? .onDevice
        let splits: Bool = {
            guard split, case let .account(_, _, locality) = newMemoriesDestination else { return false }
            return locality != .onDevice
        }()
        if proposals || splits {
            facts.append(SendFact(job: .newMemories(splits: splits), destination: newMemoriesDestination))
        }
        if let tidy = destination(resolve(.tidyUp).model) {
            facts.append(SendFact(job: .tidyUp(scheduled: tidyUpScheduled), destination: tidy))
        }
        if searchAnswersOn, let answers = destination(resolve(.searchAnswers).model) {
            let trigger = answers == .onDevice ? .ask : searchAnswersTrigger
            facts.append(SendFact(job: .searchAnswers(trigger), destination: answers))
        }
        if let embedding, let account = account(embedding.provider), account.offersEmbeddings {
            let locality = localities[account.id] ?? .cloud
            let memoryText = locality.isLocal || cloudLimit != .never
            facts.append(SendFact(job: .searchIndex(memoryText: memoryText, agentTasks: embedding.embedsAgentTasks),
                                  destination: .account(account.id, model: embedding.model, locality: locality)))
        }
        return facts
    }
}

// MARK: - Storage and the one-time conversion

public extension AISettings {
    /// Settings from user defaults' `AIModels` data, and whether they were converted from the v1
    /// shape (or were missing), so the caller writes them back at once.
    static func load(_ data: Data?) -> (settings: AISettings, converted: Bool) {
        guard let data else { return (AISettings(), false) }
        let decoder = JSONDecoder()
        if let version = try? decoder.decode(Version.self, from: data), (version.version ?? 1) >= 2,
           let settings = try? decoder.decode(AISettings.self, from: data) {
            return (settings, false)
        }
        guard let legacy = try? decoder.decode(LegacyAIModels.self, from: data) else { return (AISettings(), false) }
        return (AISettings(converting: legacy), true)
    }

    private struct Version: Decodable { var version: Int? }

    /// The v1 shape (v0.1–v0.7): one model per provider and per plan, and a provider id per task.
    struct LegacyAIModels: Codable, Sendable {
        public struct Provider: Codable, Sendable {
            public var endpoint: ProviderEndpoint
            public var name: String
            public var model: String
        }

        public struct Subscription: Codable, Sendable {
            public var kind: PlanKind
            public var model: String
        }

        public var providers: [Provider]?
        /// nil: Apple on-device. Otherwise a provider id or a plan.
        public var classifier: String?
        public var cloudLimit: CloudLimit?
        public var usage: [String: ProviderUsage]?
        public var dailyCap: Int?
        public var subscriptions: [Subscription]?
        public var codexAllowsFileReads: Bool?
        /// nil: the same as New memories.
        public var tidyUp: String?
        public var embedding: EmbeddingChoice?
        public var calibrations: [String: CalibratedThresholds]?
        public var searchAnswers: Bool?
        public var searchAnswersTrigger: String?
        /// nil: the same as New memories; `apple.foundation`: Apple on-device.
        public var searchAnswersModel: String?
    }

    /// ADR-0030 §6's conversion: each provider's model becomes its list (empty, or an embedding
    /// model, gives an empty list); each
    /// plan's list is its stored model, unless blank, then its suggestions; each task's id becomes
    /// that account with the model it had, or an unresolved choice when it had none. A task whose
    /// id names nothing gets its default, as the v1 code ran it.
    init(converting old: LegacyAIModels) {
        self.init()
        // An embedding model stored as the chat model never worked as one: it isn't carried into
        // the chat models (the second index has its own choice).
        accounts = (old.providers ?? []).map { p in
            let model = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let chat = !model.isEmpty && !EmbeddingCatalog.isEmbeddingModel(model)
            return AIAccount(endpoint: p.endpoint, name: p.name, models: chat ? [model] : [])
        }
        plans = (old.subscriptions ?? []).reduce(into: [AIPlan]()) { plans, sub in
            guard !plans.contains(where: { $0.kind == sub.kind }) else { return }
            let model = sub.model.trimmingCharacters(in: .whitespacesAndNewlines)
            var models = model.isEmpty ? [] : [model]
            for suggestion in sub.kind.suggestedModels where !models.contains(suggestion) { models.append(suggestion) }
            plans.append(AIPlan(kind: sub.kind, models: models))
        }
        func choice(_ id: String?, job: AIJob) -> JobChoice {
            guard let id else { return job.defaultChoice }
            if job == .searchAnswers, id == "apple.foundation" { return .onDevice }
            if let kind = PlanKind(rawValue: id) {
                // Without a record the plan ran its first suggestion.
                guard let sub = old.subscriptions?.first(where: { $0.kind == kind }) else {
                    return .model(ModelChoice(account: id, model: kind.suggestedModels[0]))
                }
                let model = sub.model.trimmingCharacters(in: .whitespacesAndNewlines)
                return .model(ModelChoice(account: id, model: model.isEmpty ? nil : model))
            }
            guard let account = account(id) else { return job.defaultChoice }
            return .model(ModelChoice(account: id, model: account.models.first))
        }
        newMemories = choice(old.classifier, job: .newMemories)
        tidyUp = choice(old.tidyUp, job: .tidyUp)
        searchAnswers = choice(old.searchAnswersModel, job: .searchAnswers)
        embedding = old.embedding
        cloudLimit = old.cloudLimit ?? .upTo(.internal)
        dailyCap = old.dailyCap
        codexAllowsFileReads = old.codexAllowsFileReads ?? false
        usage = old.usage ?? [:]
        calibrations = old.calibrations ?? [:]
        searchAnswersOn = old.searchAnswers ?? false
        searchAnswersTrigger = old.searchAnswersTrigger.flatMap(AnswerTrigger.init(rawValue:)) ?? .ask
    }
}
