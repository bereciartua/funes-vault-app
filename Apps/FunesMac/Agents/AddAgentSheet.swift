import BridgeUI
import FunesCore
import FunesProtocol
import SwiftUI

/// Add Agent (FR-A-01, FR-A-02): tiles for the agents on this Mac (detected ones first) and for
/// cloud agents (ADR-0018), a name, and a starting access. A new agent has no access unless a
/// starting access gives it some. A cloud tile creates the agent with cloud access on, then opens
/// pairing or its token setup on the Cloud tab.
struct AddAgentSheet: View {
    let model: AppModel
    var added: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choice: SetupAgent?
    @State private var cloudChoice: CloudAgent?
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
                        cloudChoice = nil
                        name = uniqueName(base: agent == .other ? String(localized: "My Agent") : agent.displayName)
                    }
                }
            }
            Text(String(localized: "From the cloud, through Remote Access")).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(CloudAgent.allCases.filter(\.isSupported)) { agent in
                    CloudTile(agent: agent, selected: cloudChoice == agent) {
                        cloudChoice = agent
                        choice = nil
                        name = uniqueName(base: agent.name)
                    }
                }
            }
            if let cloudChoice, !model.remoteAccess.active {
                Label(String(localized: "Remote Access isn't set up yet. \(cloudChoice.name) can't reach Funes Vault until it is; the agent's Cloud tab links to it."),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if choice != nil || cloudChoice != nil {
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
                    .disabled((choice == nil && cloudChoice == nil) || name.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func uniqueName(base: String) -> String {
        let taken = Set(model.agents.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func add() {
        if let cloudChoice { return addCloud(cloudChoice) }
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

    /// A cloud agent: cloud access on from the start, then pairing (OAuth apps) or the token setup.
    private func addCloud(_ agent: CloudAgent) {
        let name = name
        let access = starting.access
        let asks = asksForAccess
        Task {
            do {
                let (created, _) = try await model.services.agents.create(name: name, kind: AgentKind(agent), access: access,
                                                                           asksForAccess: asks, now: Date())
                try await model.services.agents.setCloudAccess(agentID: created.id, true, now: Date())
                await model.refresh()
                model.remoteAccess.agentsChanged()
                added(created.id)
                model.agentTab = .cloud
                if agent.usesOAuth, agent.preRegisteredRedirectURI == nil, model.remoteAccess.active,
                   let fresh = model.agent(created.id) {
                    model.connectCloudApp(fresh)
                }
                dismiss()
            } catch {
                self.error = ErrorText.message(error)
            }
        }
    }
}

struct CloudTile: View {
    let agent: CloudAgent
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AgentIcon(kind: AgentKind(agent), size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).lineLimit(1)
                    Text(agent.usesOAuth ? String(localized: "Sign in") : String(localized: "Remote token"))
                        .font(.caption).foregroundStyle(.secondary)
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
        .accessibilityLabel(agent.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
