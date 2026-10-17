import AppKit
import BridgeUI
import Foundation
import FunesCore
import FunesMCP
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "approvals")

/// The MCP side's panels (task 2.9): **Share with…** for a request waiting for the user, and
/// the non-blocking **Save this memory?** for a suggestion. The text comes fresh from the vault,
/// never from the agent; the agent's purpose is shown "as reported".
final class FunesApprovals: FunesPresenter, @unchecked Sendable {
    /// The in-call wait; afterwards the request waits in Pending requests (15 minutes).
    static let panelSeconds: TimeInterval = 45

    private let environment: VaultEnvironment
    @MainActor let queue = ApprovalQueue()
    @MainActor private lazy var controller = ApprovalPanelController(queue: queue)

    @MainActor
    init(environment: VaultEnvironment) {
        self.environment = environment
        queue.queueChanged = { [weak self] in self?.controller.update() }
    }

    func showApproval(requestID: UUID, agentID: UUID) async {
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

    private func present(requestID: UUID, focus: Bool) async {
        let disclosures = environment.disclosures
        let now = Date()
        guard let panel = try? await disclosures.panel(requestID: requestID, now: now) else { return }
        let disclosure = try? await disclosures.disclosure(requestID: requestID)
        let item = Self.shareItem(panel, withheld: disclosure?.withheld ?? [:], now: now)
        await MainActor.run {
            queue.enqueue(item) { [weak self] answer in self?.answered(panel, answer) }
            if focus { bringForward() }
        }
    }

    static func shareItem(_ panel: ApprovalPanel, withheld: [ReasonCode: Int], now: Date) -> PanelItem {
        let rows = panel.memories.map { memory in
            PanelItem.Row(id: memory.id.uuidString, title: memory.title, detail: memory.body,
                          version: String(memory.version), badge: memory.sensitivity.name.capitalized,
                          badgeIsWarning: memory.sensitivity >= .sensitive)
        }
        let held = withheld.values.reduce(0, +)
        let note: String? = held == 0 ? nil : String(localized: "\(held) more matched but can't go to this agent (\(withheldReasons(withheld))).")
        // The task and keywords are shown while FunesCore still holds them (15 minutes).
        return PanelItem.share(
            id: panel.requestID, agentID: panel.agentID.uuidString, agentName: panel.agentName, task: panel.task,
            keywords: panel.keywords, purpose: panel.purpose, keepsIt: retention(panel.retention),
            sharedWith: panel.processors, rows: rows, note: note,
            expiresAt: max(now, panel.createdAt) + panelSeconds)
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
                case .expired, .withdrawn, .tertiary:
                    // Unanswered: the request waits in Pending requests until it expires.
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
        if !suggestion.categoryKeys.isEmpty {
            facts.append(PanelItem.Fact(label: String(localized: "Category"),
                                        value: suggestion.categoryKeys.map { names[$0] ?? $0 }.joined(separator: ", ")))
        }
        if let sensitivity = suggestion.sensitivity {
            facts.append(PanelItem.Fact(label: String(localized: "Sensitivity"), value: sensitivity.name.capitalized))
        }
        if let evidence = suggestion.evidence, !evidence.isEmpty {
            facts.append(PanelItem.Fact(label: String(localized: "Why"), value: String(localized: "“\(evidence)” (as reported)")))
        }
        let item = PanelItem(
            id: suggestion.id, kind: .save, agentID: suggestion.agentID?.uuidString ?? "",
            title: String(localized: "Save this memory?"),
            subtitle: String(localized: "Suggested by \(agentName). It's in your Inbox either way."),
            rows: [PanelItem.Row(id: suggestion.id.uuidString, title: suggestion.title, detail: suggestion.body,
                                 selectable: false)],
            facts: facts, primary: String(localized: "Save"), secondary: String(localized: "Later"),
            tertiary: String(localized: "Reject"),
            announcement: String(localized: "\(agentName) suggests a memory for Funes"))
        await MainActor.run {
            queue.enqueue(item) { [weak self] answer in self?.answered(suggestion: suggestion.id, answer) }
            if focus { bringForward() }
        }
    }

    private func answered(suggestion id: UUID, _ answer: PanelAnswer) {
        let suggestions = environment.suggestions
        Task {
            do {
                switch answer {
                case .primary: _ = try await suggestions.apply(suggestionID: id, now: Date())
                case .tertiary: try await suggestions.reject(suggestionID: id, now: Date())
                case .secondary, .expired, .withdrawn: break
                }
            } catch {
                logger.error("Answering a suggestion failed")
            }
        }
    }

    // MARK: Helpers

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
