import AppKit
import BridgeUI
import Foundation
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
    /// A suggestion arrived (for the optional notification).
    @MainActor var suggestionArrived: (String) -> Void = { _ in }

    @MainActor
    init(environment: VaultEnvironment) {
        self.environment = environment
        queue.queueChanged = { [weak self] in self?.controller.update() }
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
        let remote = await MainActor.run { remoteRequests.contains(requestID) }
        var item = Self.shareItem(panel, withheld: disclosure?.withheld ?? [:], now: now, remote: remote)
        if focus { item.expiresAt = panel.expiresAt }
        await MainActor.run {
            // Quitting: the queue refuses it anyway; don't bring Funes forward for it.
            guard !queue.isClosed else { return }
            if let task = panel.task { tasks[requestID] = task }
            queue.enqueue(item) { [weak self] answer in self?.answered(panel, answer) }
            if focus { bringForward() }
        }
    }

    static func shareItem(_ panel: ApprovalPanel, withheld: [ReasonCode: Int], now: Date, remote: Bool = false) -> PanelItem {
        let rows = panel.memories.map { memory in
            PanelItem.Row(id: memory.id.uuidString, title: memory.title, detail: memory.body,
                          version: String(memory.version), badge: memory.sensitivity.title,
                          badgeIsWarning: memory.sensitivity >= .sensitive)
        }
        let held = withheld.values.reduce(0, +)
        let note: String? = held == 0 ? nil : String(localized: "\(held) more matched but can't go to this agent (\(withheldReasons(withheld))).")
        // The task and keywords are shown while FunesCore still holds them (15 minutes).
        return PanelItem.share(
            id: panel.requestID, agentID: panel.agentID.uuidString, agentName: panel.agentName, task: panel.task,
            keywords: panel.keywords, purpose: panel.purpose, keepsIt: retention(panel.retention),
            sharedWith: panel.processors, rows: rows, note: note,
            expiresAt: max(now, panel.createdAt) + panelSeconds, remote: remote)
    }

    private func answered(_ panel: ApprovalPanel, _ answer: PanelAnswer) {
        let disclosures = environment.disclosures
        Task {
            do {
                switch answer {
                case .primary(let selected):
                    let ids = selected.compactMap(UUID.init(uuidString:))
                    try await disclosures.approve(requestID: panel.requestID, snapshotRevision: panel.snapshotRevision,
                                                  memoryIDs: ids, now: Date())
                case .secondary:
                    try await disclosures.deny(requestID: panel.requestID, now: Date())
                case .expired:
                    // Unanswered: the request waits in Pending requests until its 15 minutes are up.
                    if Date() < panel.expiresAt {
                        await MainActor.run {
                            notice(String(localized: "No answer: \(panel.agentName) was told to wait. It's in Pending requests."))
                        }
                    }
                case .withdrawn, .tertiary, .edit:
                    break
                }
            } catch VaultError.snapshotChanged {
                // Something changed while the panel was up: show it again with fresh text.
                await present(requestID: panel.requestID, focus: false)
            } catch {
                logger.error("Answering a request failed")
            }
        }
    }

    // MARK: Save this memory?

    private func present(suggestionID: UUID, focus: Bool) async {
        guard let suggestion = try? await environment.suggestions.suggestion(id: suggestionID),
              suggestion.status == .pending else { return }
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
        if let evidence = suggestion.evidence, !evidence.isEmpty {
            facts.append(PanelItem.Fact(label: String(localized: "Why"), value: String(localized: "“\(evidence)” (as reported)"),
                                        collapsible: true))
        }
        let item = PanelItem(
            id: suggestion.id, kind: .save, agentID: suggestion.agentID?.uuidString ?? "",
            title: suggestion.targetMemoryID == nil ? String(localized: "Save this memory?")
                                                    : String(localized: "Save this correction?"),
            subtitle: String(localized: "From \(agentName). It's in your Inbox either way."),
            rows: [PanelItem.Row(id: suggestion.id.uuidString, title: suggestion.title, detail: suggestion.body,
                                 selectable: false)],
            facts: facts, primary: String(localized: "Save"), secondary: String(localized: "Later"),
            tertiary: String(localized: "Discard"), edit: String(localized: "Edit…"),
            announcement: String(localized: "\(agentName) suggests a memory for Funes"))
        await MainActor.run {
            guard !queue.isClosed else { return }
            queue.enqueue(item) { [weak self] answer in self?.answered(suggestion: suggestion.id, answer) }
            if focus { bringForward() } else { suggestionArrived(agentName) }
        }
    }

    private func answered(suggestion id: UUID, _ answer: PanelAnswer) {
        let suggestions = environment.suggestions
        Task {
            do {
                switch answer {
                case .primary: _ = try await suggestions.apply(suggestionID: id, now: Date())
                case .tertiary: try await suggestions.reject(suggestionID: id, now: Date())
                case .edit: await MainActor.run { editSuggestion(id) }
                case .secondary, .expired, .withdrawn: break
                }
            } catch {
                logger.error("Answering a suggestion failed")
            }
        }
    }

    // MARK: <Agent> wants more access

    func askForAccess(_ prompt: AccessPrompt) async -> AccessAnswer {
        let agentName = (try? await environment.agents.agent(id: prompt.agentID))?.name ?? String(localized: "An agent")
        let category = prompt.categoryKey.flatMap { key in (try? environment.store.categories())?.first { $0.key == key }?.name }
        let item = Self.accessItem(prompt, agentName: agentName, categoryName: category)
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                // A closed queue (quitting) answers `.withdrawn` at once: Not Now, so the call never waits.
                queue.enqueue(item) { answer in
                    switch answer {
                    case .primary: continuation.resume(returning: .alwaysAllow)
                    case .tertiary: continuation.resume(returning: prompt.allowsOnce ? .allowOnce : .notNow)
                    default: continuation.resume(returning: .notNow)
                    }
                }
            }
        }
    }

    /// "Cursor can't read Project Context. It asked for context for: <task>."
    static func accessItem(_ prompt: AccessPrompt, agentName: String, categoryName: String?) -> PanelItem {
        let what: String
        switch (prompt.operation, categoryName) {
        case (.read, let name?): what = String(localized: "\(agentName) can't read \(name).")
        case (_, let name?): what = String(localized: "\(agentName) can't add to \(name).")
        case (.read, nil): what = String(localized: "\(agentName) can't read your memories.")
        case (_, nil): what = String(localized: "\(agentName) can't suggest memories.")
        }
        var facts = [PanelItem.Fact]()
        if let task = prompt.task, !task.isEmpty {
            facts.append(PanelItem.Fact(label: String(localized: "It asked for context for"),
                                        value: String(localized: "“\(task)” (as reported)"), collapsible: true))
        }
        let always = categoryName.map { String(localized: "Always Allow adds \($0) to \(agentName)'s categories.") }
            ?? String(localized: "Always Allow lets \(agentName) suggest memories from now on.")
        let note = prompt.allowsOnce
            ? String(localized: "Allow Once is for this request only. \(always)")
            : String(localized: "It already got what it may read. \(always)")
        return PanelItem(
            id: UUID(), kind: .access, agentID: prompt.agentID.uuidString,
            title: String(localized: "\(agentName) wants more access"), subtitle: what, rows: [], facts: facts, note: note,
            primary: String(localized: "Always Allow"), secondary: String(localized: "Not Now"),
            tertiary: prompt.allowsOnce ? String(localized: "Allow Once") : nil, expiresAt: prompt.expiresAt,
            announcement: String(localized: "\(agentName) asks for more access in Funes"))
    }

    // MARK: Helpers

    @MainActor
    func sessionTask(_ requestID: UUID) -> String? { tasks[requestID] }

    @MainActor
    private func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        controller.bringForward()
    }

    static func retention(_ retention: Retention) -> String {
        switch retention {
        case .none: String(localized: "Not kept")
        case .session: String(localized: "For this session")
        case .persistent: String(localized: "Kept by the agent")
        case .unknown: String(localized: "Not said")
        }
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
