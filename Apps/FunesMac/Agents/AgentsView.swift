import BridgeUI
import FunesCore
import FunesProtocol
import SwiftUI

/// Agents (04-ux-mac.md, FR-A-01..12): the list with each agent's status and access, and the
/// selected agent's Access, Connect and Activity tabs.
struct AgentsView: View {
    @Bindable var model: AppModel
    @State private var adding = false

    /// The list's width for the room beside the sidebar: 220 at the window's minimum (860), up to
    /// 300. A plain stack, not an HSplitView: on a live resize HSplitView kept its panes' widths and
    /// ran the detail off the window's edge.
    static func listWidth(_ available: CGFloat) -> CGFloat { min(max(available * 0.32, 220), 300) }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                list.frame(width: Self.listWidth(proxy.size.width))
                Divider()
                detail.frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $adding) {
            AddAgentSheet(model: model) { id in
                model.selectedAgentID = id
                model.agentTab = .connect
            }
        }
        // `initial`: the checklist's Add… also switches to this page, so it may not be on screen yet.
        .onChange(of: model.wantsAddAgent, initial: true) { _, wants in
            if wants {
                adding = true
                model.wantsAddAgent = false
            }
        }
        .onAppear {
            if model.selectedAgentID == nil { model.selectedAgentID = model.agents.first?.id }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Agents")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                // At the list's narrowest, the button keeps only its icon.
                ViewThatFits(in: .horizontal) {
                    Button { adding = true } label: { Label(String(localized: "Add Agent…"), systemImage: "plus") }
                    Button { adding = true } label: { Label(String(localized: "Add Agent…"), systemImage: "plus").labelStyle(.iconOnly) }
                        .help(String(localized: "Add Agent…"))
                }
            }
            .padding(16)
            Divider()
            if !model.pending.isEmpty {
                // Requests waiting for you, where the sidebar's badge points (UX review F12).
                PendingRequestsCard(model: model, compact: true)
                    .padding(10)
                Divider()
            }
            if model.agents.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No agents yet"), systemImage: "person.2")
                } description: {
                    Text(String(localized: "Add Claude Code, Cursor or another AI agent, then choose what it may read."))
                } actions: {
                    Button(String(localized: "Add Agent…")) { adding = true }
                }
            } else {
                List(selection: Binding(get: { model.selectedAgentID }, set: { model.selectedAgentID = $0 })) {
                    ForEach(model.agents) { agent in
                        AgentRow(agent: agent, model: model).tag(agent.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(String(localized: "Agents"))
            }
        }
        .frame(maxHeight: .infinity)
        .background(Palette.card)
    }

    private var detail: some View {
        Group {
            if let agent = model.agent(model.selectedAgentID) {
                AgentDetailView(model: model, agent: agent).id(agent.id)
            } else {
                ContentUnavailableView(String(localized: "No agent selected"), systemImage: "person.crop.circle",
                                       description: Text(String(localized: "Select an agent to change its access or connect it.")))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.pane)
    }
}

struct AgentRow: View {
    let agent: Agent
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentIcon(kind: agent.agentKind, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(AgentText.statusLine(agent, now: model.now)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(AgentText.accessSummary(agent.access, categories: model.categories))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch AgentText.status(agent, now: model.now) {
        case .connected: .green
        case .waiting: .accentColor
        case .paused: .orange
        case .expired: .red
        }
    }
}

enum AgentTab: String, CaseIterable, Identifiable {
    case access, connect, cloud, activity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .access: String(localized: "Access")
        case .connect: String(localized: "Connect")
        case .cloud: String(localized: "Cloud")
        case .activity: String(localized: "Activity")
        }
    }
}

/// One agent: header with Pause or Resume and Remove…, then the tabs.
struct AgentDetailView: View {
    @Bindable var model: AppModel
    let agent: Agent
    @State private var confirmRemove = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Picker(String(localized: "Tab"), selection: $model.agentTab) {
                ForEach(tabs) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 10)
            Divider()
            switch model.agentTab {
            case .access: AccessEditor(model: model, agent: agent)
            case .connect: ConnectTab(model: model, agent: agent)
            case .cloud: CloudTab(model: model, agent: agent)
            case .activity:
                ActivityList(model: model, scope: .agent(agent.id))
                    .padding(16)
            }
        }
        .confirmationDialog(String(localized: "Remove \(agent.name)?"), isPresented: $confirmRemove) {
            Button(String(localized: "Remove"), role: .destructive) { remove() }
        } message: {
            Text(agent.cloudAccess
                 ? String(localized: "Its key, remote token and connected cloud apps stop working at once, and its access is deleted. Activity keeps its history, labelled “removed agent”. Its entry in the agent's own settings stays until you delete it there.")
                 : String(localized: "Its key stops working at once and its access is deleted. Activity keeps its history, labelled “removed agent”. Its entry in the agent's own settings stays until you delete it there."))
        }
        .sheet(isPresented: $renaming) { renameSheet }
    }

    /// Cloud shows while Remote Access is on, or while the agent has cloud access or is a cloud agent.
    private var tabs: [AgentTab] {
        let cloud = model.remoteAccess.enabled || agent.cloudAccess || agent.agentKind.isCloud
        return AgentTab.allCases.filter { $0 != .cloud || cloud }
    }

    /// The icon, name and status, then Pause or Resume and Remove…: on one line when they fit,
    /// with the kind under the status when that makes them fit, and otherwise with the buttons on a
    /// line of their own and the kind wrapping. The kind is left out when the name already says it.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            oneLine(kindBelow: false)
            oneLine(kindBelow: true)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    AgentIcon(kind: agent.agentKind, size: 40)
                    identity(kindBelow: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) { headerButtons }.padding(.leading, 52)
            }
        }
    }

    private func oneLine(kindBelow: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AgentIcon(kind: agent.agentKind, size: 40)
            identity(kindBelow: kindBelow).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { headerButtons }.fixedSize()
        }
    }

    private func identity(kindBelow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(agent.name).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                Button { newName = agent.name; renaming = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Rename \(agent.name)"))
            }
            if kindBelow {
                status
                kindText?.fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) { status; kindText }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var status: some View {
        Pill(label: AgentText.statusLine(agent, now: model.now, client: model.clientName(agent.id)),
             tone: AgentText.tone(agent, now: model.now))
            .fixedSize()
    }

    private var kindText: Text? {
        let kind = agent.agentKind.cloudAgent?.name ?? agent.agentKind.setupAgent.displayName
        guard kind.localizedCaseInsensitiveCompare(agent.name) != .orderedSame else { return nil }
        return Text(kind).font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var headerButtons: some View {
        if agent.paused {
            Button(String(localized: "Resume")) { run { try await model.services.agents.resume(agentID: agent.id, now: Date()) } }
        } else {
            Button(String(localized: "Pause")) { run { try await model.services.agents.pause(agentID: agent.id, now: Date()) } }
                .help(String(localized: "Refuse this agent's requests until you resume it"))
        }
        Button(String(localized: "Remove…"), role: .destructive) { confirmRemove = true }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Rename Agent")).font(.title3.weight(.semibold))
            TextField(String(localized: "Name"), text: $newName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { renaming = false }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Rename")) {
                    let name = newName
                    run { try await model.services.agents.update(agentID: agent.id, name: name) }
                    renaming = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func remove() {
        run {
            try await model.removeAgent(agent)
            model.selectedAgentID = nil
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await body()
                error = nil
                await model.refresh()
            } catch {
                self.error = ErrorText.message(error)
            }
        }
    }
}
