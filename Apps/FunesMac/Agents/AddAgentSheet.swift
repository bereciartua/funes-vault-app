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
    @State private var place: Place
    @State private var showAll = false

    init(model: AppModel, place: Place = .local, added: @escaping (UUID) -> Void) {
        self.model = model
        self.added = added
        _place = State(initialValue: place)
    }

    /// On this Mac, or from the cloud (experimental): one at a time, so the main path stays short
    /// (UX review F10).
    enum Place: Hashable { case local, cloud }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Add an Agent")).font(.title2.weight(.semibold))
            Text(String(localized: "Each agent gets its own key and only the access you give it."))
                .foregroundStyle(.secondary)
            Picker(String(localized: "Where it runs"), selection: $place) {
                Text(String(localized: "On This Mac")).tag(Place.local)
                Text(String(localized: "Cloud · Experimental")).tag(Place.cloud)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: place) { _, _ in
                choice = nil
                cloudChoice = nil
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if place == .local { localTiles } else { cloudTiles }
                    if choice != nil || cloudChoice != nil { form }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: maxListHeight)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if let choice, choice.oneClick {
                    Text(String(localized: "Shows the change to \(choice.displayName)'s settings first."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(primaryTitle) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((choice == nil && cloudChoice == nil) || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear { detected = model.detectAgents() }
    }

    private var primaryTitle: String {
        if let choice, choice.oneClick { return String(localized: "Add and Connect…") }
        return String(localized: "Add Agent")
    }

    /// The sheet never grows past the screen: the tiles and form scroll.
    private var maxListHeight: CGFloat {
        min(max((NSScreen.main?.visibleFrame.height ?? 800) - 260, 240), 620)
    }

    @ViewBuilder private var localTiles: some View {
        let shown = showAll || detected.isEmpty ? tiles : tiles.filter { detected.contains($0) }
        if !detected.isEmpty, !showAll {
            Text(String(localized: "Found on this Mac")).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            ForEach(shown, id: \.self) { agent in
                AgentTile(agent: agent, detected: detected.contains(agent), selected: choice == agent) {
                    choice = agent
                    cloudChoice = nil
                    name = uniqueName(base: agent == .other ? String(localized: "My Agent") : agent.displayName)
                }
            }
        }
        if !detected.isEmpty {
            Button(showAll ? String(localized: "Show Only Agents Found on This Mac")
                           : String(localized: "Show All \(tiles.count) Agents")) { showAll.toggle() }
                .buttonStyle(.link)
        }
    }

    @ViewBuilder private var cloudTiles: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(model.remoteAccess.active
                 ? String(localized: "Remote Access is on. Cloud agents reach Funes through your tunnel, and what you share goes to their servers.")
                 : String(localized: "Cloud agents need Remote Access, which is off. What you share with them goes to their servers."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !model.remoteAccess.active {
                Button(String(localized: "Set Up Remote Access…")) {
                    dismiss()
                    model.show(.remoteAccess)
                }
            }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            ForEach(CloudAgent.allCases.filter(\.isSupported)) { agent in
                CloudTile(agent: agent, selected: cloudChoice == agent) {
                    cloudChoice = agent
                    choice = nil
                    name = uniqueName(base: agent.name)
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                // Add and Connect…: the Connect tab opens the one-click change at once.
                if choice.oneClick, !custom { model.pendingOneClick = agent.id }
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
                    Text(agent.name).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(agent.usesOAuth ? String(localized: "Sign in") : String(localized: "Remote token"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            // One height for every tile, whether its name takes one line or two.
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.16) : Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Palette.separator,
                                                                    lineWidth: selected ? 2 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.usesOAuth ? String(localized: "\(agent.name), sign in") : String(localized: "\(agent.name), remote token"))
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
                    Text(agent.displayName).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if detected { Text(String(localized: "On this Mac")).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            // One height for every tile, whether its name takes one line or two.
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
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
