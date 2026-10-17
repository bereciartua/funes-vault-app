import BridgeUI
import FunesCore
import FunesProtocol
import SwiftUI

/// Add Agent (FR-A-01, FR-A-02): tiles for the agents on this Mac (detected ones first), a name,
/// and a starting access. A new agent has no access unless a starting access gives it some.
struct AddAgentSheet: View {
    let model: AppModel
    var added: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choice: SetupAgent?
    @State private var name = ""
    @State private var starting: StartingAccess = .readLowAskFirst
    @State private var asksForAccess = false
    @State private var error: String?
    @State private var detected: Set<SetupAgent> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Add an Agent")).font(.title2.weight(.semibold))
            Text(String(localized: "Each agent gets its own key and only the access you give it."))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(tiles, id: \.self) { agent in
                    AgentTile(agent: agent, detected: detected.contains(agent), selected: choice == agent) {
                        choice = agent
                        name = uniqueName(for: agent)
                    }
                }
            }
            if choice != nil {
                Divider()
                Form {
                    TextField(String(localized: "Name"), text: $name)
                    Picker(String(localized: "Starting access"), selection: $starting) {
                        ForEach(StartingAccess.allCases) { Text($0.title).tag($0) }
                    }
                    Text(starting.detail).font(.callout).foregroundStyle(.secondary)
                    Toggle(String(localized: "Let it ask for more access"), isOn: $asksForAccess)
                    Text(String(localized: "When a request is refused only because a category isn't allowed, Funes asks you: Not Now, Allow Once or Always Allow. At most once an hour."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Add Agent")) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear { detected = model.detectAgents() }
    }

    /// Detected agents first, then the rest, with Other MCP client last.
    private var tiles: [SetupAgent] {
        let all = SetupAgent.allCases.filter { $0 != .other }
        return all.filter { detected.contains($0) } + all.filter { !detected.contains($0) } + [.other]
    }

    private func uniqueName(for agent: SetupAgent) -> String {
        let base = agent == .other ? String(localized: "My Agent") : agent.displayName
        let taken = Set(model.agents.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func add() {
        guard let choice else { return }
        let name = name
        let access = starting.access
        let asks = asksForAccess
        let custom = starting == .custom
        Task {
            do {
                let (agent, _) = try await model.services.agents.create(name: name, kind: AgentKind(choice), access: access,
                                                                         asksForAccess: asks, now: Date())
                await model.refresh()
                added(agent.id)
                if custom { model.agentTab = .access }
                dismiss()
            } catch {
                self.error = ErrorText.message(error)
            }
        }
    }
}

struct AgentTile: View {
    let agent: SetupAgent
    let detected: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AgentIcon(kind: AgentKind(agent), size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.displayName).lineLimit(1)
                    if detected { Text(String(localized: "On this Mac")).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.16) : Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Palette.separator,
                                                                    lineWidth: selected ? 2 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detected ? String(localized: "\(agent.displayName), on this Mac") : agent.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
