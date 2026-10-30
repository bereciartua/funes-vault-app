import Foundation
import FunesCore
import FunesProtocol

/// The cloud limit's words (ADR-0022).
enum CloudLimitText {
    static func title(_ limit: CloudLimit) -> String {
        switch limit {
        case .upTo(.secret): String(localized: "Everything, including Secret")
        case let .upTo(level): level.title
        case .never: String(localized: "Nothing")
        }
    }
}

/// Accounts' and plans' words: errors, plan states, and why one can't run now.
enum ProviderText {
    static func error(_ error: Error) -> String {
        switch error as? ProviderError {
        case .unauthorized?: String(localized: "Unavailable: check the API key.")
        case .rateLimited?: String(localized: "The provider says to slow down. Try again later.")
        case .server(let status)?: String(localized: "The provider answered with an error (\(status)).")
        case .invalidOutput?: String(localized: "The model's answer wasn't usable. Try another model.")
        case .refused?: String(localized: "The model declined.")
        case .timeout?: String(localized: "No answer within 20 seconds.")
        case .insecureEndpoint?: String(localized: "Cloud providers need an https:// address.")
        case .unavailable?: String(localized: "Check the address and the key.")
        case .blocked?: String(localized: "Funes didn't send it: it looked like a secret, or was above the cloud limit.")
        case .capReached?: String(localized: "Today's cloud requests are used up. Try again tomorrow, or raise the limit.")
        case .transport?, nil: String(localized: "Couldn't reach the server.")
        }
    }

    /// "Signed in to Claude Code 2.1.310", "Not signed in: run `claude` in Terminal and sign in"…
    static func planState(_ status: SubscriptionStatus, _ kind: PlanKind) -> String {
        let tool = kind.tool
        switch status {
        case let .ready(version): return String(localized: "Signed in to \(tool) \(version)")
        case .notInstalled: return String(localized: "\(tool) isn't installed on this Mac")
        case .notSignedIn: return String(localized: "Not signed in: run `\(kind.signIn)` in Terminal and sign in with \(kind.plan)")
        case .needsUpdate: return String(localized: "Update \(tool) to use it")
        case .unsupportedFeatures: return String(localized: "This \(tool) version isn't supported yet")
        case .fileReadsNotAllowed: return String(localized: "Off: it can read files on this Mac. Turn on the switch below to use it anyway.")
        case .blocked: return String(localized: "Unavailable: it tried to use a tool. Test Connection to try again.")
        }
    }

    /// After an account's name in a picker: "No key", "Not signed in".
    static func reason(_ problem: AccountProblem) -> String {
        switch problem {
        case .noKey: String(localized: "No key")
        case .notInstalled: String(localized: "Not installed")
        case .notSignedIn: String(localized: "Not signed in")
        case .needsUpdate: String(localized: "Needs an update")
        case .unsupported: String(localized: "Not supported yet")
        case .needsFileReadOK: String(localized: "Needs your OK to read files")
        case .paused: String(localized: "Paused after a tool use")
        }
    }

    /// The orange label on a Features row (04-ux-mac.md ▸ AI ▸ Features).
    static func label(_ problem: JobProblem) -> String {
        switch problem {
        case .chooseModel: String(localized: "Choose a model")
        case .onDeviceUnavailable: String(localized: "Not available on this Mac")
        case let .account(_, problem):
            switch problem {
            case .noKey: String(localized: "Needs a key")
            case .needsFileReadOK: String(localized: "Needs your OK")
            default: reason(problem)
            }
        }
    }
}

/// What each job's page, row and the privacy summary say, from Settings and the jobs' state
/// (FR-AI-08: every choice keeps its disclosure line). Words only; the facts come from
/// `AISettings`.
@MainActor
struct AIJobText {
    let model: AppModel
    private var settings: ModelSettings { model.modelSettings }

    /// "Claude through your Claude Code sign-in", "Anthropic": who a job's text goes to.
    func recipient(_ account: String) -> String {
        if let kind = PlanKind(rawValue: account) {
            return kind == .claudeCode ? String(localized: "\(kind.plan) through your Claude Code sign-in")
                                       : String(localized: "\(kind.plan) through your Codex sign-in")
        }
        return settings.name(account)
    }

    private var limit: String? {
        if case let .upTo(level) = settings.cloudLimit { return CloudLimitText.title(.upTo(level)) }
        return nil
    }

    // MARK: New memories

    var newMemories: Resolution { settings.resolve(.newMemories) }

    /// Splitting needs a local server or a cloud model with a model chosen; Apple on-device only
    /// proposes fields (memory processing §5.2).
    var canSplit: Bool {
        guard case .model = newMemories.model else { return false }
        return settings.locality(newMemories.model) != .onDevice
    }

    var newMemoriesStatus: String {
        switch newMemories.model {
        case .onDevice, .rules:
            return AppleFoundationGenerator.isAvailable
                ? String(localized: "Ready")
                : String(localized: "Apple Intelligence isn't available on this Mac: simple rules propose the fields.")
        case let .unresolved(account):
            return String(localized: "Choose one of \(settings.name(account))'s models. Until then: on-device, then rules.")
        case let .model(account, model):
            if let kind = PlanKind(rawValue: account) {
                let status = settings.subscriptionStatus[kind].map { ProviderText.planState($0, kind) } ?? String(localized: "Checking…")
                return status + " " + String(localized: "If it fails, Funes uses the on-device model, then rules.")
            }
            if EmbeddingCatalog.isEmbeddingModel(model) {
                return String(localized: "\(model) is an embedding model: choose a chat model. Until then: on-device, then rules.")
            }
            if let acc = settings.account(account), settings.needsKey(acc) {
                return String(localized: "Unavailable: check API key. Using on-device instead.")
            }
            return String(localized: "Ready. If it fails, Funes uses the on-device model, then rules.")
        }
    }

    /// "New memories sends new captures (up to Internal) and your category names and descriptions
    /// to Anthropic." (FR-AI-08)
    func newMemoriesDisclosure(split: Bool) -> String? {
        guard case let .model(account, _) = newMemories.model, !settings.locality(newMemories.model).isLocal else { return nil }
        if let kind = PlanKind(rawValue: account) {
            guard let limit else {
                return String(localized: "New memories sends nothing to \(kind.plan): the cloud limit is Nothing, so it runs on this Mac.")
            }
            return split
                ? String(localized: "New memories sends captures, agent suggestions and imports, plus related memories (up to \(limit)), to \(kind.plan) through your \(kind.tool) sign-in. It counts toward your plan's limits, and your \(kind.plan) account's training setting applies.")
                : String(localized: "New memories sends new captures (up to \(limit)) and your category names and descriptions to \(kind.plan) through your \(kind.tool) sign-in. It counts toward your plan's limits, and your \(kind.plan) account's training setting applies.")
        }
        let name = settings.name(account)
        guard let limit else {
            return String(localized: "New memories sends nothing to \(name): the cloud limit is Nothing, so it runs on this Mac.")
        }
        return split && canSplit
            ? String(localized: "New memories sends new captures, your answers, agents' suggestions and saved memories, and imports (up to \(limit)), then each piece with up to 5 related memories, and your category names and descriptions, to \(name).")
            : String(localized: "New memories sends new captures (up to \(limit)) and your category names and descriptions to \(name).")
    }

    func splitCaption(classify: Bool, split: Bool) -> String {
        guard canSplit else {
            return String(localized: "Splitting needs a local server or a cloud model. Apple's on-device model proposes fields only.")
        }
        if split {
            return String(localized: "Captures, your answers, agents' suggestions and imports become one suggestion per claim, each marked new, an update, already saved or a removal. You review every piece in the Inbox.")
        }
        return classify ? String(localized: "You review every proposal in the Inbox.")
                        : String(localized: "Captures get simple proposals from rules on this Mac.")
    }

    // MARK: Daily tidy-up

    /// Compares changed memories with related ones and proposes updates, merges, splits, archives
    /// and questions; the last run, or before the first, the estimate (§9.6).
    var tidyUpCaption: String {
        let hasModel = settings.tidyUpName != nil
        var lines = [hasModel
            ? String(localized: "Compares memories that changed with related ones and proposes updates, merges, splits and archives, and asks you about conflicts. Proposals wait in the Inbox's Tidy-up section.")
            : String(localized: "Finds exact duplicates and expired memories on this Mac. Choose a local server or a cloud model to also find updates, merges, splits and conflicts; Apple's on-device model isn't used for this.")]
        if case .unresolved = settings.resolve(.tidyUp).model {
            lines.insert(String(localized: "Choose a model to tidy up with."), at: 0)
        }
        if let run = model.tidyUp.lastRun {
            lines.append(TidyUpController.summary(run, left: model.tidyUp.left))
        } else if let estimate = model.tidyUp.estimate, hasModel {
            lines.append(String(localized: "About \(estimate.memories) memories to check. Roughly \(estimate.requests) requests the first week, then a few a day."))
        }
        return lines.joined(separator: " ")
    }

    /// "The daily tidy-up sends related memories (up to Internal) to Anthropic." (model providers §4)
    var tidyUpDisclosure: String? {
        let resolution = settings.resolve(.tidyUp)
        guard case let .model(account, _) = resolution.model, !settings.locality(resolution.model).isLocal else { return nil }
        let name = PlanKind(rawValue: account)?.plan ?? settings.name(account)
        guard let limit else {
            return String(localized: "The daily tidy-up sends nothing to \(name): the cloud limit is Nothing, so only exact duplicates and expired memories are found.")
        }
        return String(localized: "The daily tidy-up sends related memories (up to \(limit)), with their dates and sources, to \(name).")
    }

    // MARK: Search answers

    /// "Ready. Press ⌘⏎ in a search, or tap Ask on your iPhone.", the on-device warning, or what's missing.
    var searchAnswersStatus: String {
        switch settings.resolve(.searchAnswers).model {
        case .onDevice, .rules:
            guard AppleFoundationGenerator.isAvailable else { return String(localized: "Choose a model to answer searches.") }
            return settings.searchAnswersTrigger == .ask
                ? String(localized: "Apple's on-device model is slow on this Mac: answers may take 30 s or more.")
                : String(localized: "Apple's on-device model is too slow to answer on its own: it answers only when you ask, and may take 30 s or more.")
        case .unresolved:
            return String(localized: "Choose a model to answer searches.")
        case let .model(account, _):
            if let plan = PlanKind(rawValue: account) {
                switch settings.subscriptionStatus[plan] {
                case .ready?: break
                case let status?:
                    let text = ProviderText.planState(status, plan)
                    return text.hasSuffix(".") ? text : text + "."
                case nil: return String(localized: "Checking…")
                }
            } else if let acc = settings.account(account), settings.needsKey(acc) {
                return String(localized: "Add \(acc.name)'s API key in Models & Accounts.")
            }
        }
        switch settings.searchAnswersTrigger {
        case .ask: return String(localized: "Ready. Press ⌘⏎ in a search, or tap Ask on your iPhone.")
        case .questions:
            return String(localized: "Ready. A search that's a question is answered after a short pause, on this Mac and your iPhone; press ⌘⏎ to ask about any other.")
        case .everySearch:
            return String(localized: "Ready. Every search is answered after a short pause, on this Mac and your iPhone.")
        }
    }

    /// "Search answers send your search and its top results (up to Internal) to Claude through your
    /// Claude Code sign-in, when you ask." (model providers §4)
    var searchAnswersDisclosure: String? {
        let resolution = settings.resolve(.searchAnswers)
        guard case let .model(account, _) = resolution.model, !settings.locality(resolution.model).isLocal else { return nil }
        let name = settings.name(account)
        guard let limit else {
            return String(localized: "Search answers send nothing to \(name): the cloud limit is Nothing, so there's no answer.")
        }
        if let plan = PlanKind(rawValue: account) {
            let via = plan == .claudeCode ? String(localized: "through your Claude Code sign-in") : String(localized: "through your Codex sign-in")
            switch settings.searchAnswersTrigger {
            case .ask:
                return String(localized: "Search answers send your search and its top results (up to \(limit)) to \(plan.plan) \(via), when you ask. It counts toward your plan's limits.")
            case .questions:
                return String(localized: "Search answers send your search and its top results (up to \(limit)) to \(plan.plan) \(via), when you ask or pause on a question. Each answer counts toward your plan's limits and today's \(settings.dailyCap) cloud requests.")
            case .everySearch:
                return String(localized: "Search answers send your search and its top results (up to \(limit)) to \(plan.plan) \(via), each time you pause on a search. Each answer counts toward your plan's limits and today's \(settings.dailyCap) cloud requests.")
            }
        }
        switch settings.searchAnswersTrigger {
        case .ask:
            return String(localized: "Search answers send your search and its top results (up to \(limit)) to \(name), when you ask.")
        case .questions:
            return String(localized: "Search answers send your search and its top results (up to \(limit)) to \(name), when you ask or pause on a question. Each answer counts toward today's \(settings.dailyCap) cloud requests.")
        case .everySearch:
            return String(localized: "Search answers send your search and its top results (up to \(limit)) to \(name), each time you pause on a search. Each answer counts toward today's \(settings.dailyCap) cloud requests.")
        }
    }

    // MARK: Apply changes automatically

    /// The highest level either job's engine reached: New memories' (none yet) or the tidy-up's.
    var highestLevel: AutoApplyLevel {
        max(NewMemoryAutoApply.highestAvailable, settings.tidyUpModel.map(TidyUpAutoApply.reached(model:)) ?? .off)
    }

    var autoApplyCaption: String {
        let tidy = settings.tidyUpModel.map(TidyUpAutoApply.reached(model:)) ?? .off
        let tidyLine = switch tidy {
        case .off: String(localized: "The tidy-up's model hasn't been accurate enough to change memories by itself, so its proposals all wait for you.")
        case .duplicatesOnly: String(localized: "With this model the tidy-up can archive duplicates by itself; everything else waits for you.")
        case .exceptConflicts: String(localized: "With this model the tidy-up can apply updates, merges, splits and archives by itself; conflicts always wait for you.")
        }
        return String(localized: "Off: every proposal waits for you in the Inbox. No model has been accurate enough yet to save new memories by itself. Agents always follow their own access.") + " " + tidyLine + " " + String(localized: "Undo any automatic change for 30 days in the Inbox.")
    }

    // MARK: What AI features send (ADR-0030 §5)

    /// Where a local account runs: "on this Mac" for a loopback address, otherwise "on your local
    /// network". No DNS lookup: only a literal address or localhost counts as this Mac.
    private func whereLocal(_ account: String) -> String {
        let host = settings.account(account)?.endpoint.baseURL.host()?.lowercased() ?? ""
        let loopback = host == "localhost" || host.hasPrefix("127.") || host == "::1" || host == "[::1]"
        return loopback ? String(localized: "on this Mac") : String(localized: "on your local network")
    }

    /// " (up to Internal)" for a cloud model; nothing for a local one, which the limit doesn't cover.
    private func upTo(_ local: Bool) -> String {
        local ? "" : String(localized: " (up to \(limit ?? ""))")
    }

    /// One line of the summary, prefixed with the job's name.
    func sendLine(_ fact: SendFact) -> (text: String, leaves: Bool) {
        switch fact.destination {
        case .onDevice:
            switch fact.job {
            case .searchAnswers: return (String(localized: "Search answers: nothing; Apple on-device answers on this Mac."), false)
            default: return (String(localized: "New memories: nothing; Apple on-device proposes fields on this Mac, then rules."), false)
            }
        case let .account(account, _, locality):
            let local = locality.isLocal
            let to = local ? "\(settings.name(account)), \(whereLocal(account))" : recipient(account)
            switch fact.job {
            case let .newMemories(splits):
                guard local || limit != nil else {
                    return (String(localized: "New memories: nothing to \(to); the cloud limit is Nothing."), false)
                }
                let level = upTo(local)
                return (splits
                    ? String(localized: "New memories: captures, your answers, agents' suggestions and imports\(level), each with up to 5 related memories, and your category names and descriptions, to \(to).")
                    : String(localized: "New memories: new captures\(level) and your category names and descriptions, to \(to)."), !local)
            case let .tidyUp(scheduled):
                guard local || limit != nil else {
                    return (String(localized: "Daily tidy-up: nothing to \(to); the cloud limit is Nothing."), false)
                }
                let level = upTo(local)
                if scheduled {
                    let time = model.preferences.tidyUpSchedule
                    let at = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date())?
                        .formatted(date: .omitted, time: .shortened) ?? ""
                    return (String(localized: "Daily tidy-up: related memories\(level), with their dates and sources, to \(to), every day at \(at)."), !local)
                }
                return (String(localized: "Daily tidy-up: related memories\(level), with their dates and sources, to \(to), when you tidy up."), !local)
            case let .searchAnswers(trigger):
                guard local || limit != nil else {
                    return (String(localized: "Search answers: nothing to \(to); the cloud limit is Nothing."), false)
                }
                let level = upTo(local)
                let line = switch trigger {
                case .ask: String(localized: "Search answers: your search and its top results\(level), to \(to), when you ask.")
                case .questions: String(localized: "Search answers: your search and its top results\(level), to \(to), when you ask or pause on a question.")
                case .everySearch: String(localized: "Search answers: your search and its top results\(level), to \(to), each time you pause on a search.")
                }
                return (line, !local)
            case let .searchIndex(memoryText, agentTasks):
                if !memoryText {
                    return (agentTasks
                        ? String(localized: "Search index: your searches and agents' task descriptions, but no memory text, to \(to).")
                        : String(localized: "Search index: your searches, but no memory text, to \(to)."), true)
                }
                if local {
                    return (agentTasks
                        ? String(localized: "Search index: memory text, your searches and agents' task descriptions, to \(to).")
                        : String(localized: "Search index: memory text and your searches, to \(to)."), false)
                }
                return (agentTasks
                    ? String(localized: "Search index: memory text (up to \(limit ?? "")), your searches and agents' task descriptions, to \(to).")
                    : String(localized: "Search index: memory text (up to \(limit ?? "")) and your searches, to \(to)."), true)
            }
        }
    }

    /// The summary's facts, with the switches the app keeps.
    var sendFacts: [SendFact] {
        settings.stored.sendFacts(proposals: model.preferences.classifyCaptures, split: model.preferences.splitNewMemories,
                                  tidyUpScheduled: model.preferences.tidyUpDaily,
                                  localities: Dictionary(uniqueKeysWithValues: settings.accounts.map { ($0.id, settings.locality(account: $0.id)) }))
    }
}
