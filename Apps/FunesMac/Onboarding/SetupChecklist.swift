import BridgeUI
import FunesCore
import Observation
import SwiftUI

/// The setup checklist (FR-O-01): connect an agent, approve its first request, seed the vault,
/// review the Inbox. Connecting comes first, so a new user reaches an approved request in a few
/// steps (UX review F9). It shows at the top of the Vault until dismissed; "Approve its first
/// request" completes on the agent's first request.
@MainActor @Observable
final class ChecklistModel {
    enum Step: Int, CaseIterable { case add, connect, seed, review }

    private let preferences: Preferences
    private(set) var done: Set<Step> = []
    /// "Claude Code connected 10:42".
    private(set) var connectedLine: String?
    private(set) var dismissed = false
    /// Just hidden: the Vault offers Undo for a few seconds (UX review F7).
    private(set) var justHidden = false
    var showSeedQuestions = false
    var showImport: ImportKind?

    init(preferences: Preferences) {
        self.preferences = preferences
        dismissed = preferences.flag(Preferences.Key.checklistDismissed)
    }

    var isComplete: Bool { done.count == Step.allCases.count }
    var isVisible: Bool { !dismissed }

    func update(model: AppModel) {
        var done = Set<Step>()
        let seededBefore = preferences.flag(Preferences.Key.checklistSeeded)
        if model.hasMemories || seededBefore || model.inbox.contains(where: { $0.origin == .seedQuestion || $0.origin == .import }) {
            done.insert(.seed)
            if !seededBefore { preferences.set(Preferences.Key.checklistSeeded, true) }
        }
        let reviewedBefore = preferences.flag(Preferences.Key.checklistReviewed)
        if reviewedBefore || (done.contains(.seed) && model.hasMemories && model.inbox.isEmpty) {
            done.insert(.review)
            if !reviewedBefore { preferences.set(Preferences.Key.checklistReviewed, true) }
        }
        if !model.agents.isEmpty { done.insert(.add) }
        if let first = model.agents.compactMap({ agent in agent.firstRequestAt.map { (agent, $0) } }).min(by: { $0.1 < $1.1 }) {
            done.insert(.connect)
            connectedLine = String(localized: "\(first.0.name) connected \(first.1.formatted(date: .omitted, time: .shortened))")
        } else {
            connectedLine = nil
        }
        self.done = done
    }

    func dismiss() {
        dismissed = true
        preferences.set(Preferences.Key.checklistDismissed, true)
    }

    /// Hide, with Undo offered for 10 seconds.
    func hide() {
        dismiss()
        justHidden = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.justHidden = false
        }
    }

    func undoHide() {
        dismissed = false
        justHidden = false
        preferences.set(Preferences.Key.checklistDismissed, false)
    }

    /// Settings ▸ Advanced ▸ Reset the setup checklist.
    func reset(model: AppModel) {
        for key in [Preferences.Key.checklistDismissed, Preferences.Key.checklistSeeded, Preferences.Key.checklistReviewed] {
            preferences.set(key, false)
        }
        dismissed = false
        update(model: model)
    }
}

/// The card at the top of the Vault.
struct SetupChecklistCard: View {
    let model: AppModel
    @State private var detected: [SetupAgent] = []
    /// The first unfinished step's button gets the initial keyboard focus, never Hide: a stray
    /// Space on first launch must not throw the guide away (UX review F7).
    @FocusState private var firstAction: ChecklistModel.Step?

    private var checklist: ChecklistModel { model.checklist }

    var body: some View {
        Card {
            HStack {
                Text(checklist.isComplete ? String(localized: "You're all set") : String(localized: "Set up Funes Vault"))
                    .font(.headline)
                Text(String(localized: "\(checklist.done.count) of 4")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if checklist.isComplete {
                    Button(String(localized: "Dismiss")) { checklist.dismiss() }
                } else {
                    Button(String(localized: "Hide")) { checklist.hide() }
                        .buttonStyle(.link)
                        .focusable(false)
                        .help(String(localized: "Settings ▸ Advanced brings it back"))
                }
            }
            HStack(alignment: .top, spacing: 12) {
                step(.add, String(localized: "Connect an agent"), detectedLine) {
                    Button(String(localized: "Add…")) {
                        model.wantsAddAgent = true
                        model.show(.agents)
                    }
                }
                step(.connect, String(localized: "Approve its first request"),
                     checklist.connectedLine ?? String(localized: "Ask it something. Funes shows you exactly what it would share.")) {
                    if let agent = model.agents.first {
                        Button(agent.agentKind.setupAgent.oneClick ? String(localized: "Add to \(agent.agentKind.setupAgent.displayName)…")
                                                                   : String(localized: "Show Setup")) {
                            model.agentTab = .connect
                            model.showAgent(agent.id)
                        }
                    }
                }
                step(.seed, String(localized: "Seed your vault"),
                     String(localized: "Answer a few questions or import from ChatGPT or Claude.")) {
                    Menu(String(localized: "Start")) {
                        Button(String(localized: "Answer a Few Questions…")) { checklist.showSeedQuestions = true }
                        Divider()
                        Button(String(localized: "Import ChatGPT Memories…")) { checklist.showImport = .chatGPT }
                        Button(String(localized: "Paste Claude Memories…")) { checklist.showImport = .claude }
                        Button(String(localized: "Import a Markdown File…")) { checklist.showImport = .markdown }
                    }
                    .fixedSize()
                }
                step(.review, String(localized: "Review your Inbox"), String(localized: "Apply what's right.")) {
                    Button(model.inboxCount > 0 ? String(localized: "Open Inbox (\(model.inboxCount))") : String(localized: "Open Inbox")) {
                        model.show(.inbox)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .task { detected = SetupAgent.allCases.filter { model.detectAgents().contains($0) } }
        .defaultFocus($firstAction, ChecklistModel.Step.allCases.first { !checklist.done.contains($0) })
    }

    private var detectedLine: String {
        guard !detected.isEmpty else { return String(localized: "Claude Code, Cursor, Codex or another AI agent.") }
        let names = detected.prefix(3).map(\.displayName).joined(separator: ", ")
        return String(localized: "Found on this Mac: \(names)")
    }

    private func step<Action: View>(_ step: ChecklistModel.Step, _ title: String, _ detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        let done = checklist.done.contains(step)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle")
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                Text(title).fontWeight(.medium)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !done { action().controlSize(.small).focused($firstAction, equals: step) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(done ? String(localized: "\(title), done") : title)
    }
}
