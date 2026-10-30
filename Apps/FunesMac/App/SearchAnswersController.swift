import Foundation
import FunesCore
import FunesProtocol

/// Search answers with the user's settings (FR-AI-17, memory processing §10): the Vault's Ask and,
/// from the companion, the iPhone's. Each answer builds its router from Settings ▸ AI Models at
/// the time it's asked, so a change of model applies to the next Ask.
@MainActor
final class SearchAnswersController {
    let environment: VaultEnvironment
    let settings: ModelSettings
    private let answerer: SearchAnswerer

    init(environment: VaultEnvironment, settings: ModelSettings) {
        self.environment = environment
        self.settings = settings
        answerer = SearchAnswerer(store: environment.store, search: environment.search, activity: environment.activity)
    }

    /// Answer: Only when I ask.
    var isOn: Bool { settings.searchAnswersOn }

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

    func answer(_ query: String, ids: [UUID], actor: Actor = .user, via: ActivityEvent.Via = .app) async throws -> SearchAnswer {
        let router = settings.makeSearchAnswerRouter(cap: settings.cap(store: environment.store, activity: environment.activity))
        return try await answerer.answer(query, ids: ids, router: router, actor: actor, via: via)
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
