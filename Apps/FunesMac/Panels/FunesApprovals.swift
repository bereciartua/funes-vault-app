import AppKit
import BridgeUI
import Foundation
import FunesCompanion
import FunesCore
import FunesMCP
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "approvals")

/// The MCP side's panels (tasks 2.9 and 3.6): **Share with…** for a request waiting for the user,
/// the non-blocking **Save this memory?** for a suggestion, and **<Agent> wants more access**. The
/// text comes fresh from the vault, never from the agent; what the agent said is shown "as reported".
final class FunesApprovals: FunesPresenter, @unchecked Sendable {
    /// The in-call wait; afterwards the request waits in Pending requests (15 minutes).
    static let panelSeconds: TimeInterval = 45

    private let environment: VaultEnvironment
    /// Approvals from the iPhone (task 5.6): the doorbell, and the phone's answers.
    private let desk: CompanionApprovals
    @MainActor let queue = ApprovalQueue()
    /// Task text of the requests this session showed a panel for, for Activity's detail pane. In
    /// memory only: the vault keeps a hash (FR-L-01), so after a relaunch it's "Task text not stored".
    @MainActor private var tasks: [UUID: String] = [:]
    /// Requests that came through Remote Access, so their panel says so when it's reopened.
    @MainActor private var remoteRequests = Set<UUID>()
    @MainActor private lazy var controller = ApprovalPanelController(queue: queue)
    /// Shows a short notice (the HUD), e.g. when a request waited past its panel.
    @MainActor var notice: (String) -> Void = { _ in }
    /// Edit… on the Save panel: the suggestion in the Inbox.
    @MainActor var editSuggestion: (UUID) -> Void = { _ in }
    /// The tunnel a cloud agent's latest request came through ("Tailscale Funnel"), for the Share
    /// panel's Goes to line. Nil when Funes doesn't know.
    @MainActor var remoteTunnel: (UUID) -> String? = { _ in nil }
    /// A suggestion arrived (for the optional notification).
    @MainActor var suggestionArrived: (String) -> Void = { _ in }
    /// Agents' suggestions whose Save panels wait for New memories processing: they show with the
    /// result, one per piece (memory processing §5.2). In memory only: after a relaunch they're
    /// in the Inbox.
    @MainActor private var awaitingProcessing = Set<UUID>()
    /// Vault changes, so a Save panel goes once its suggestion is answered elsewhere.
    private var observation: AnyObject?

    @MainActor
    init(environment: VaultEnvironment) {
        self.environment = environment
        let desk = environment.phoneApprovals
        self.desk = desk
        queue.queueChanged = { [weak self] in self?.controller.update() }
        // A paired iPhone answered first: the Mac's panel goes, and says where.
        Task { [weak self] in
            await desk.onPhoneAnswered { key, deviceName in
                Task { @MainActor in
                    guard let self else { return }
                    if self.queue.items.contains(where: { $0.id == key.id }) { self.queue.answer(key.id, .withdrawn) }
                    self.notice(String(localized: "Answered on \(deviceName)."))
                }
            }
        }
        observation = environment.store.observeChanges { [weak self] in
            Task { await self?.withdrawResolvedSaves() }
        }
    }



    func showApproval(requestID: UUID, agentID: UUID) async {
        await present(requestID: requestID, focus: false)
    }

    func showApproval(requestID: UUID, agentID: UUID, remote: Bool) async {
        if remote { await MainActor.run { _ = remoteRequests.insert(requestID) } }
        await present(requestID: requestID, focus: false)
    }

    func showSuggestion(suggestionID: UUID, agentID: UUID) async {
        await present(suggestionID: suggestionID, focus: false)
    }

    func open(requestID: UUID) async {
        await present(requestID: requestID, focus: true)
    }

    func open(suggestionID: UUID) async {
        await present(suggestionID: suggestionID, focus: true)
    }

    // MARK: Share with…

    /// `focus` is a reopened pending request (the menu, Activity or `open_in_funes`): it counts
    /// down to the end of its 15 minutes instead of the 45-second in-call wait.
    private func present(requestID: UUID, focus: Bool) async {
        let disclosures = environment.disclosures
        let now = Date()
        guard let panel = try? await disclosures.panel(requestID: requestID, now: now) else { return }
        let disclosure = try? await disclosures.disclosure(requestID: requestID)
        let agent = try? await environment.agents.agent(id: panel.agentID)
        let (remote, tunnel) = await MainActor.run {
            (remoteRequests.contains(requestID), remoteRequests.contains(requestID) ? remoteTunnel(panel.agentID) : nil)
        }
        var item = Self.shareItem(panel, withheld: disclosure?.withheld ?? [:], now: now, agent: agent, remote: remote,
                                  tunnel: tunnel, profileFields: disclosure?.profileFieldsSent ?? [])
        if focus {
            item.expiresAt = panel.expiresAt
            item.moreTime = nil
        }
        let shown = await MainActor.run { () -> Bool in
            // Quitting: the queue refuses it anyway; don't bring Funes forward for it.
            guard !queue.isClosed else { return false }
            if let task = panel.task { tasks[requestID] = task }
            queue.enqueue(item) { [weak self] answer in self?.answered(panel, answer) }
            if focus { bringForward() }
            return true
        }
        // A new request rings the paired iPhones; one reopened on the Mac doesn't.
        if shown, !focus {
            let destination = ApprovalDestination(remote: remote, vendor: agent?.agentKind.cloudAgent?.vendor, tunnel: tunnel)
            await desk.waiting(.share(requestID), destination: destination)
        }
    }

    /// The Share panel for a request: where the text goes (from what Funes knows), what the agent
    /// said (labelled as such), the user's own note on the agent, and the memories, strong matches
    /// ticked and weaker ones offered unticked (access policy §3.2).
    static func shareItem(_ panel: ApprovalPanel, withheld: [ReasonCode: Int], now: Date, agent: Agent?,
                          remote: Bool = false, tunnel: String? = nil, profileFields: [ProfileField] = []) -> PanelItem {
        let rows = panel.memories.map { memory in
            let weak = !panel.strong.contains(memory.id)
            return PanelItem.Row(id: memory.id.uuidString, title: memory.title, detail: memory.body,
                                 version: String(memory.version), badge: memory.sensitivity.title,
                                 badgeIsWarning: memory.sensitivity >= .sensitive, selected: !weak, weak: weak)
        }
        let ordered = rows.filter { !$0.weak } + rows.filter(\.weak)
        let held = withheld.values.reduce(0, +)
        let note: String? = held == 0 ? nil : String(localized: "\(held) more matched but can't go to this agent (\(withheldReasons(withheld))).")
        var facts = [PanelItem.Fact]()
        if let agent, agent.declaredRetention != .unknown {
            facts.append(PanelItem.Fact(label: String(localized: "Your note"),
                                        value: String(localized: "Keeps what it gets: \(AgentText.retention(agent.declaredRetention))")))
        }
        // The task and keywords are shown while FunesCore still holds them (15 minutes).
        return PanelItem.share(
            id: panel.requestID, agentID: panel.agentID.uuidString, agentName: panel.agentName,
            destination: destination(agentName: panel.agentName, kind: agent?.agentKind, remote: remote, tunnel: tunnel),
            task: panel.task, keywords: panel.keywords, purpose: panel.purpose, keepsIt: AgentText.retention(panel.retention),
            sharedWith: panel.processors, facts: facts, rows: ordered, note: note,
            aside: aboutYou(agentName: panel.agentName, profileFields), expiresAt: max(now, panel.createdAt) + panelSeconds)
    }

    /// "Claude Code also has your name and pronouns, as set in its Access." (ADR-0026): the
    /// answer that started the request already carried them, so they aren't tickable and Deny
    /// doesn't take them back.
    static func aboutYou(agentName: String, _ fields: [ProfileField]) -> PanelItem.Aside? {
        guard !fields.isEmpty else { return nil }
        return PanelItem.Aside(text: String(localized: "\(agentName) also has \(ProfileText.sentence(fields)), as set in "),
                               link: String(localized: "its Access"), after: ".")
    }

    /// Goes to: built only from facts Funes holds. A local agent may pass what it reads on to its AI
    /// service, which Funes can't see; a cloud agent's vendor comes from a fixed table, and the
    /// tunnel from Remote Access (UX review F2).
    static func destination(agentName: String, kind: AgentKind?, remote: Bool, tunnel: String?) -> PanelItem.Destination {
        guard remote else {
            return PanelItem.Destination(text: String(localized: "\(agentName) on this Mac. It may send what it reads to its AI service."),
                                         isCloud: false)
        }
        let vendor = kind?.cloudAgent?.vendor
        let text = switch (tunnel, vendor) {
        case let (tunnel?, vendor?): String(localized: "\(agentName), through your \(tunnel), to \(vendor)'s servers")
        case let (nil, vendor?): String(localized: "\(agentName), through Remote Access, to \(vendor)'s servers")
        case let (tunnel?, nil): String(localized: "\(agentName), a cloud agent, through your \(tunnel)")
        case (nil, nil): String(localized: "\(agentName), a cloud agent, through Remote Access")
        }
        return PanelItem.Destination(text: text, isCloud: true)
    }

    private func answered(_ panel: ApprovalPanel, _ answer: PanelAnswer) {
        let disclosures = environment.disclosures
        let desk = self.desk
        Task {
            do {
                switch answer {
                case .primary(let selected):
                    let ids = selected.compactMap(UUID.init(uuidString:))
                    try await disclosures.approve(requestID: panel.requestID, snapshotRevision: panel.snapshotRevision,
                                                  memoryIDs: ids, now: Date())
                    await desk.ended(.share(panel.requestID), answered: true)
                case .secondary:
                    // Never takes back an approval an iPhone gave first.
                    try await disclosures.deny(requestID: panel.requestID, now: Date(), waitingOnly: true)
                    await desk.ended(.share(panel.requestID), answered: true)
                case .expired:
                    // Unanswered: the request waits in Pending requests until its 15 minutes are up.
                    if Date() < panel.expiresAt {
                        await MainActor.run {
                            notice(String(localized: "No answer: \(panel.agentName) was told to wait. It's in Pending requests."))
                        }
                    }
                case .deferred:
                    await MainActor.run {
                        notice(String(localized: "Moved to Pending requests. You have until \(panel.expiresAt.formatted(date: .omitted, time: .shortened)) to answer."))
                    }
                case .withdrawn, .tertiary, .edit:
                    break
                }
            } catch VaultError.snapshotChanged {
                // Something changed while the panel was up: show it again with fresh text.
                await present(requestID: panel.requestID, focus: false)
            } catch VaultError.invalidState {
                // Answered first on an iPhone, or the 15 minutes ran out.
                await desk.ended(.share(panel.requestID), answered: false)
            } catch {
                logger.error("Answering a request failed")
            }
        }
    }

    // MARK: Save this memory?

    /// A processing job's outcome is recorded: the Save panels waiting for it show now.
    func processingEnded(_ id: UUID) async {
        guard await MainActor.run(body: { awaitingProcessing.contains(id) }) else { return }
        await present(suggestionID: id, focus: false)
    }

    /// The Save panels for an agent's suggestion, once New memories processing is done with it:
    /// one per piece of a split, or the suggestion itself. While it's processing nothing shows
    /// (opened from elsewhere, its "Processing…" card in the Inbox) and `processingEnded` comes
    /// back to it. With splitting off nothing waits.
    private func present(suggestionID: UUID, focus: Bool) async {
        await MainActor.run { _ = awaitingProcessing.insert(suggestionID) }
        let ids: [UUID]?
        do { ids = try await environment.suggestions.savePanels(for: suggestionID, now: Date()) } catch { ids = [] }
        guard let ids else {
            if focus { await MainActor.run { editSuggestion(suggestionID) } }
            return
        }
        // The job's end and the arrival may both get here: the first one shows the panels.
        guard await MainActor.run(body: { awaitingProcessing.remove(suggestionID) != nil }) else { return }
        // Opened from elsewhere, a split input is reviewed on its group card in the Inbox.
        if focus, ids != [suggestionID] {
            if !ids.isEmpty { await MainActor.run { editSuggestion(suggestionID) } }
            return
        }
        // The pieces queue behind each other ("+N more"); the notification comes once.
        for (i, id) in ids.enumerated() { await presentPanel(id, focus: focus, announce: i == 0) }
    }

    private func presentPanel(_ suggestionID: UUID, focus: Bool, announce: Bool) async {
        guard let suggestion = try? await environment.suggestions.suggestion(id: suggestionID), suggestion.status == .pending else {
            return
        }
        let agentName = (try? await suggestion.agentID.asyncMap { try await environment.agents.agent(id: $0) })??.name
            ?? String(localized: "An agent")
        let names = Dictionary(uniqueKeysWithValues: ((try? environment.store.categories()) ?? []).map { ($0.key, $0.name) })
        var facts = [PanelItem.Fact]()
        if let kind = suggestion.kind { facts.append(PanelItem.Fact(label: String(localized: "Kind"), value: kind.title)) }
        if !suggestion.categoryKeys.isEmpty {
            facts.append(PanelItem.Fact(label: String(localized: "Category"),
                                        value: suggestion.categoryKeys.map { names[$0] ?? $0 }.joined(separator: ", ")))
        }
        if let sensitivity = suggestion.sensitivity {
            facts.append(PanelItem.Fact(label: String(localized: "Sensitivity"), value: sensitivity.title))
        }
        var says = [PanelItem.Fact]()
        if let evidence = suggestion.evidence, !evidence.isEmpty {
            says.append(PanelItem.Fact(label: String(localized: "Why"), value: evidence, collapsible: true))
        }
        let item = PanelItem(
            id: suggestion.id, kind: .save, agentID: suggestion.agentID?.uuidString ?? "",
            title: suggestion.targetMemoryID == nil ? String(localized: "Save this memory?")
                                                    : String(localized: "Save this correction?"),
            shortLabel: String(localized: "\(agentName) · save"),
            subtitle: String(localized: "From \(agentName). It's in your Inbox either way."), agentSays: says,
            rows: [PanelItem.Row(id: suggestion.id.uuidString, title: suggestion.title, detail: suggestion.body,
                                 selectable: false)],
            facts: facts, primary: String(localized: "Save"), secondary: String(localized: "Later"),
            tertiary: String(localized: "Discard"), edit: String(localized: "Edit…"),
            announcement: String(localized: "\(agentName) suggests a memory for Funes"))
        let shown = await MainActor.run { () -> Bool in
            guard !queue.isClosed else { return false }
            // While the panel (or the iPhone's approval) is up, the tidy-up leaves it alone.
            environment.holds.hold(suggestion.id, .savePanel)
            queue.enqueue(item) { [weak self] answer in self?.answered(suggestion: suggestion.id, answer) }
            if focus { bringForward() } else if announce { suggestionArrived(agentName) }
            return true
        }
        if shown, !focus { await desk.waiting(.save(suggestion.id)) }
    }

    private func answered(suggestion id: UUID, _ answer: PanelAnswer) {
        let suggestions = environment.suggestions
        let holds = environment.holds
        holds.release(id, .savePanel)
        let desk = self.desk
        Task {
            do {
                switch answer {
                case .primary:
                    _ = try await suggestions.apply(suggestionID: id, now: Date())
                    await desk.ended(.save(id), answered: true)
                case .tertiary:
                    try await suggestions.reject(suggestionID: id, now: Date())
                    await desk.ended(.save(id), answered: true)
                case .edit: await MainActor.run { editSuggestion(id) }
                case .secondary, .expired, .deferred, .withdrawn: break
                }
            } catch {
                logger.error("Answering a suggestion failed")
            }
        }
    }

    /// Withdraws the Save panels whose suggestion isn't pending any more: saved or rejected in an
    /// Inbox (the iPhone's or this Mac's), split, expired or gone. The queue is read before the
    /// vault, so a panel shown meanwhile was pending when it was enqueued and is never taken back
    /// by a stale read. Quietly: sixty "already answered" notices would be the noise this removes,
    /// and a phone's answer to the panel itself says so already.
    func withdrawResolvedSaves() async {
        let ids = await MainActor.run { queue.items.filter { $0.kind == .save }.map(\.id) }
        guard !ids.isEmpty else { return }
        var resolved = [(UUID, answered: Bool)]()
        for id in ids {
            // A read that fails leaves the panel up; a suggestion that's gone takes it down.
            do {
                if let suggestion = try await environment.suggestions.suggestion(id: id) {
                    if suggestion.status != .pending { resolved.append((id, suggestion.status != .expired)) }
                } else {
                    resolved.append((id, false))
                }
            } catch {
                continue
            }
        }
        guard !resolved.isEmpty else { return }
        await MainActor.run { for (id, _) in resolved { queue.withdraw(id) } }
        // Takes back the iPhone's doorbell now rather than at the next minute's sweep.
        for (id, answered) in resolved { await desk.ended(.save(id), answered: answered) }
    }

    // MARK: <Agent> wants more access

    func askForAccess(_ prompt: AccessPrompt) async -> AccessAnswer {
        let agent = try? await environment.agents.agent(id: prompt.agentID)
        let agentName = agent?.name ?? String(localized: "An agent")
        let category = prompt.categoryKey.flatMap { key in (try? environment.store.categories())?.first { $0.key == key }?.name }
        let item = Self.accessItem(prompt, agentName: agentName, categoryName: category,
                                   asksBeforeSharing: agent?.access.askBeforeSharing ?? true)
        let desk = self.desk, id = item.id
        // A paired iPhone may answer it too; the queue takes whichever answer comes first. Not
        // awaited, so the doorbell's iCloud save never holds up the panel; an answer that comes
        // first ends it, and the desk then rings nothing.
        let request = CompanionApprovals.AccessRequest(agentID: prompt.agentID, categoryKey: prompt.categoryKey,
                                                       operation: prompt.operation, task: prompt.task,
                                                       expiresAt: prompt.expiresAt, allowsOnce: prompt.allowsOnce)
        Task {
            await desk.waitingForAccess(id: id, request) { [weak self] choice in
                await MainActor.run {
                    guard let self, self.queue.items.contains(where: { $0.id == id }) else { return false }
                    self.queue.answer(id, Self.panelAnswer(choice))
                    return true
                }
            }
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                // A closed queue (quitting) answers `.withdrawn` at once, so the call never waits.
                queue.enqueue(item) { answer in
                    let answered = switch answer {
                    case .primary, .secondary, .tertiary: true
                    case .expired, .withdrawn, .edit, .deferred: false
                    }
                    Task { await desk.ended(.access(id), answered: answered) }
                    switch answer {
                    case .primary: continuation.resume(returning: .alwaysAllow)
                    case .tertiary: continuation.resume(returning: prompt.allowsOnce ? .allowOnce : .notNow)
                    // Never seen or never answered: the next request may ask again.
                    case .expired, .withdrawn: continuation.resume(returning: .unanswered)
                    case .secondary, .edit, .deferred: continuation.resume(returning: .notNow)
                    }
                }
            }
        }
    }

    /// "Cursor wants to read Project context": Not Now, **Allow Once** (the default), and Always
    /// Allow as a link that says exactly what it adds (UX review F1).
    static func accessItem(_ prompt: AccessPrompt, agentName: String, categoryName: String?,
                           asksBeforeSharing: Bool = true) -> PanelItem {
        let title: String
        let always: String
        switch (prompt.operation, categoryName) {
        case (.read, let name?):
            title = String(localized: "\(agentName) wants to read \(name)")
            always = String(localized: "Always Allow \(agentName) to Read \(name)")
        case (_, let name?):
            title = String(localized: "\(agentName) wants to add to \(name)")
            always = String(localized: "Always Allow \(agentName) to Add to \(name)")
        case (.read, nil):
            title = String(localized: "\(agentName) wants to read your memories")
            always = String(localized: "Always Allow \(agentName) to Read")
        case (_, nil):
            title = String(localized: "\(agentName) wants to suggest memories")
            always = String(localized: "Always Allow \(agentName) to Suggest")
        }
        var says = [PanelItem.Fact]()
        if let task = prompt.task, !task.isEmpty {
            says.append(PanelItem.Fact(label: String(localized: "Task"), value: "“\(task)”", collapsible: true))
        }
        let subtitle: String
        if !prompt.allowsOnce {
            subtitle = String(localized: "It already got what it may read. Always Allow is for next time.")
        } else if prompt.operation == .read, categoryName != nil {
            subtitle = asksBeforeSharing
                ? String(localized: "Allow Once is for this request only. Next, you'll see exactly what would be shared.")
                : String(localized: "Allow Once is for this request only. It shares without asking, so the matching memories go to it at once.")
        } else {
            subtitle = String(localized: "Allow Once is for this request only. The suggestion still waits in your Inbox.")
        }
        return PanelItem(
            id: UUID(), kind: .access, agentID: prompt.agentID.uuidString, title: title,
            shortLabel: String(localized: "\(agentName) · access"), subtitle: subtitle, agentSays: says, rows: [],
            primary: always, secondary: String(localized: "Not Now"),
            tertiary: prompt.allowsOnce ? String(localized: "Allow Once") : nil, expiresAt: prompt.expiresAt,
            announcement: title)
    }

    /// A phone's answer to an access panel, as the panel's own buttons give it.
    static func panelAnswer(_ choice: ApprovalChoice) -> PanelAnswer {
        switch choice {
        case .alwaysAllow: .primary(selected: [])
        case .allowOnce: .tertiary
        default: .secondary
        }
    }

    // MARK: Helpers

    /// Review Request: brings the waiting panel forward and makes it key. False when nothing waits.
    @MainActor
    func review() -> Bool {
        guard !queue.items.isEmpty else { return false }
        bringForward()
        return true
    }

    /// Appended to panel announcements ("Control-Option-Command-R to review").
    @MainActor var reviewHint: String? {
        get { controller.reviewHint }
        set { controller.reviewHint = newValue }
    }

    @MainActor
    func sessionTask(_ requestID: UUID) -> String? { tasks[requestID] }

    @MainActor
    private func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        controller.bringForward()
    }


    static func withheldReasons(_ withheld: [ReasonCode: Int]) -> String {
        withheld.sorted { $0.key.rawValue < $1.key.rawValue }.map { reason, count in
            switch reason {
            case .aboveSensitivityCeiling: String(localized: "\(count) above its sensitivity limit")
            case .deniedCategory, .categoryNotAllowed: String(localized: "\(count) in categories it can't read")
            case .expiredMemory: String(localized: "\(count) expired")
            default: String(localized: "\(count) not shareable")
            }
        }.joined(separator: ", ")
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
