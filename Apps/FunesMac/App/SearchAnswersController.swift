import Foundation
import FunesCore
import FunesProtocol

/// Search answers with the user's settings (FR-AI-17, memory processing §10): the Vault's Ask and,
/// from the companion, the iPhone's. Each answer builds its router from Settings ▸ AI Models at
/// the time it's asked, so a change of model applies to the next Ask.
@MainActor
final class SearchAnswersController: SearchAnswering {
    let environment: VaultEnvironment
    let settings: ModelSettings
    private let answerer: SearchAnswerer

    init(environment: VaultEnvironment, settings: ModelSettings) {
        self.environment = environment
        self.settings = settings
        answerer = SearchAnswerer(store: environment.store, search: environment.search, activity: environment.activity)
    }

    /// Search answers are on.
    var isOn: Bool { settings.searchAnswersOn }

    /// When a search is answered without asking. Apple on-device takes 30 s or more, so its answers
    /// are only asked for (memory processing §10.6).
    var trigger: AnswerTrigger { settings.searchAnswersOnDevice ? .ask : settings.searchAnswersTrigger }

    /// "Claude (Claude Code)", "Anthropic", "Apple on-device".
    var engineName: String { settings.searchAnswersName }

    /// Cloud requests per day, for the card at the cap.
    var dailyCap: Int { settings.dailyCap }

    /// The cloud limit's name, for "1 memory above Internal wasn't read".
    var cloudLimitName: String {
        switch settings.cloudLimit {
        case let .upTo(level): level.title
        case .never: String(localized: "the cloud limit")
        }
    }

    /// The model that would answer, for `status.get`: nil while answers are off or nothing can
    /// answer (no model on device, a plan that isn't installed, a provider without a model).
    func engine() async -> SearchAnswerEngine? {
        guard isOn else { return nil }
        if settings.searchAnswersOnDevice {
            return AppleFoundationGenerator.isAvailable ? SearchAnswerEngine(name: engineName, locality: .onDevice) : nil
        }
        if let plan = settings.searchAnswersPlan {
            return settings.executables[plan] == nil ? nil : SearchAnswerEngine(name: engineName, locality: .cloud, trigger: trigger)
        }
        guard let provider = settings.searchAnswersProvider, !provider.model.isEmpty, !settings.needsKey(provider) else { return nil }
        // Never waits on DNS (status.get is the phone's 3 s probe): the last resolved locality, and
        // cloud until the lookup in the background says otherwise (fail closed).
        let endpoint = provider.endpoint
        if resolved[endpoint] == nil {
            Task.detached(priority: .utility) { [weak self] in
                let locality = endpoint.locality()
                await MainActor.run { self?.resolved[endpoint] = locality }
            }
        }
        return SearchAnswerEngine(name: engineName, locality: resolved[endpoint] ?? .cloud, trigger: trigger)
    }

    /// Providers' resolved localities, for `engine()`.
    private var resolved: [ProviderEndpoint: Locality] = [:]

    /// Whether the effective model is Apple on-device, which reads at most 5 results.
    var readsAtMost: Int { settings.searchAnswersOnDevice ? SearchAnswerer.onDeviceMemoryCount : SearchAnswerer.memoryCount }

    func answer(_ query: String, ids: [UUID], actor: Actor = .user, via: ActivityEvent.Via = .app) async throws -> SearchAnswer {
        let build = settings.searchAnswerRouterBuilder(cap: settings.cap(store: environment.store, activity: environment.activity))
        let router: ModelRouter
        do {
            router = try await Task.detached(priority: .userInitiated) { try build() }.value
        } catch {
            // The client couldn't be made (a provider without its key): no call, but the attempt is logged.
            let failure = SearchAnswerError.provider(error as? ProviderError ?? .unavailable)
            answerer.logFailure(failure, engine: nil, actor: actor, via: via)
            throw failure
        }
        defer { settings.collectUsage(from: router) }
        do {
            return try await answerer.answer(query, ids: ids, router: router, actor: actor, via: via)
        } catch SearchAnswerError.provider(.unavailable) {
            // A plan's CLI says why it's unavailable: paused after a tool event, or too old.
            if let plan = settings.searchAnswersPlan, let client = settings.subscriptionClient(plan) {
                if CLIRunner.isBlocked(client.id) { throw SearchAnswerError.toolBlocked }
                if case .needsUpdate? = settings.subscriptionStatus[plan] { throw SearchAnswerError.needsUpdate }
            }
            throw SearchAnswerError.provider(.unavailable)
        }
    }

    /// The card's line for a failure (§10.5), and whether Try Again can help.
    func message(for error: SearchAnswerError) -> (text: String, retry: Bool) {
        switch error {
        case .secretInSearch:
            return (String(localized: "Your search looks like it contains a secret, so it wasn't sent."), false)
        case .capReached:
            return (String(localized: "Today's \(dailyCap) cloud requests are used up. Search still works; answers are back tomorrow."), false)
        case .timeout:
            return (String(localized: "Took too long. Try again."), true)
        case .invalidOutput:
            return (String(localized: "The model's answer couldn't be read. Try again."), true)
        case .tooLongForOnDevice:
            return (String(localized: "This search is too long for the on-device model."), false)
        case .vault:
            return (String(localized: "Funes couldn't read your vault. Try again."), true)
        case .needsUpdate:
            return (String(localized: "\(engineName) needs an update on your Mac."), false)
        case .toolBlocked:
            return (String(localized: "\(engineName) is paused: test its connection in Settings ▸ AI Models."), false)
        case let .provider(providerError):
            let tool = settings.searchAnswersPlan.map { $0 == .claudeCode ? "Claude Code" : "Codex" }
            switch providerError {
            case .unauthorized:
                if let tool { return (String(localized: "\(tool) isn't signed in on your Mac."), false) }
                return (String(localized: "\(engineName) didn't accept the API key. Check it in Settings ▸ AI Models."), false)
            case .unavailable:
                if settings.searchAnswersOnDevice, !AppleFoundationGenerator.isAvailable {
                    return (String(localized: "Choose a model to answer searches in Settings ▸ AI Models."), false)
                }
                if let tool { return (String(localized: "\(tool) isn't available: check it in Settings ▸ AI Models."), true) }
                return (String(localized: "\(engineName) isn't available right now."), true)
            case .rateLimited:
                return (String(localized: "\(engineName) says to slow down. Try again later."), true)
            case .refused:
                return (String(localized: "The model declined to answer."), true)
            default:
                return (String(localized: "\(engineName) didn't answer. Try again."), true)
            }
        }
    }
}
