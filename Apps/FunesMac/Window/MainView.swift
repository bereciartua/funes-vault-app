import FunesCore
import SwiftUI

/// A row in the sidebar: a section, or one agent in the Agents list.
enum SidebarItem: Hashable {
    case section(AppSection)
    case agent(UUID)
}

/// The main window: a sidebar with the sections and each agent, and the selection's content (04-ux-mac.md).
struct MainView: View {
    @Bindable var model: AppModel
    @State private var adding = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch model.section {
                case .vault: VaultView(model: model)
                case .inbox: InboxView(model: model)
                case .activity: ActivityScreen(model: model)
                case .agents: AgentsView(model: model)
                case .remoteAccess: RemoteAccessPage(model: model)
                }
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: MainWindowController.minimumSize.width, minHeight: MainWindowController.minimumSize.height)
        .sheet(isPresented: $adding) {
            AddAgentSheet(model: model) { id in
                model.selectedAgentID = id
                model.agentTab = .connect
                model.section = .agents
            }
        }
        .onChange(of: model.wantsAddAgent, initial: true) { _, wants in
            if wants {
                adding = true
                model.wantsAddAgent = false
            }
        }
        .sheet(isPresented: Binding(get: { model.checklist.showSeedQuestions }, set: { model.checklist.showSeedQuestions = $0 })) {
            SeedQuestionsSheet(model: model)
        }
        .sheet(item: Binding(get: { model.checklist.showImport }, set: { model.checklist.showImport = $0 })) { kind in
            ImportSheet(model: model, kind: kind)
        }
    }
}

/// Vault, Inbox and Activity; the Agents list with its +; then Remote Access and Settings… pinned
/// at the bottom, and a status line while agents can't connect or are paused.
struct Sidebar: View {
    let model: AppModel

    private var selection: Binding<SidebarItem?> {
        Binding(get: {
            guard model.section == .agents else { return .section(model.section) }
            return model.selectedAgentID.map(SidebarItem.agent)
        }, set: { item in
            switch item {
            case .section(let section): model.section = section
            case .agent(let id):
                model.selectedAgentID = id
                model.section = .agents
            case nil: break
            }
        })
    }

    var body: some View {
        List(selection: selection) {
            sectionRow(.vault)
            sectionRow(.inbox)
            sectionRow(.activity)
            Section {
                ForEach(model.agents) { agent in
                    AgentSidebarRow(model: model, agent: agent).tag(SidebarItem.agent(agent.id))
                }
                if model.agents.isEmpty {
                    Button { model.wantsAddAgent = true } label: {
                        Label(String(localized: "Add Agent…"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text(String(localized: "Agents")).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { model.wantsAddAgent = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Add Agent…"))
                        .accessibilityLabel(String(localized: "Add Agent…"))
                }
                // Line the button up with the rows' trailing edge.
                .padding(.trailing, 8)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private func sectionRow(_ section: AppSection) -> some View {
        let waiting = section == .inbox ? model.inboxCount : 0
        return Label(section.title, systemImage: section.symbol)
            .badge(waiting)
            .tag(SidebarItem.section(section))
            .accessibilityLabel(waiting > 0 ? String(localized: "Inbox, \(waiting) waiting") : section.title)
    }

    /// Agents scroll under these rows once the list is long, so then they get their own surface.
    private var footer: some View {
        let crowded = model.agents.count > 6
        return VStack(spacing: 0) {
            Divider().opacity(crowded ? 1 : 0)
            List(selection: selection) {
                remoteAccessRow
                Button { model.openSettings(nil) } label: {
                    Label(String(localized: "Settings…"), systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open Settings (⌘,)"))
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(height: 76)
            if SidebarStatus.shows(model) { SidebarStatus(model: model) }
        }
        .background(crowded ? AnyShapeStyle(.bar) : AnyShapeStyle(.clear))
    }

    private var remoteAccessRow: some View {
        let remote = model.remoteAccess
        return Label {
            HStack {
                Text(AppSection.remoteAccess.title)
                Spacer(minLength: 4)
                if remote.tunnelDown {
                    // An orange icon with primary text, never orange text (04-ux-mac.md).
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(String(localized: "Down"))
                    }
                    .font(.caption.weight(.medium))
                } else if remote.enabled {
                    Pill(label: String(localized: "On"), tone: .accent)
                }
            }
        } icon: {
            Image(systemName: AppSection.remoteAccess.symbol)
        }
        .tag(SidebarItem.section(.remoteAccess))
        .accessibilityLabel(remote.sidebarBadge.map { String(localized: "Remote Access, \($0)") } ?? AppSection.remoteAccess.title)
    }
}

/// An agent in the sidebar: its icon, name and a short status, with a badge counting its requests
/// waiting for you.
struct AgentSidebarRow: View {
    let model: AppModel
    let agent: Agent

    var body: some View {
        let waiting = model.pendingCount(agent.id)
        HStack(spacing: 8) {
            AgentIcon(kind: agent.agentKind, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(AgentText.sidebarLine(agent, now: model.now)).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .badge(waiting)
        .contextMenu {
            if agent.paused {
                Button(String(localized: "Resume")) { setPaused(false) }
            } else {
                Button(String(localized: "Pause")) { setPaused(true) }
            }
            Button(String(localized: "Show Activity")) { model.showActivity(.agent(agent.id)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(waiting))
    }

    private func accessibilityLabel(_ waiting: Int) -> String {
        let status = AgentText.statusLine(agent, now: model.now)
        switch waiting {
        case 0: return "\(agent.name), \(status)"
        case 1: return String(localized: "\(agent.name), \(status), 1 request waiting")
        default: return String(localized: "\(agent.name), \(status), \(waiting) requests waiting")
        }
    }

    private var color: Color {
        switch AgentText.status(agent, now: model.now) {
        case .connected: .green
        case .waiting: .accentColor
        case .paused: .orange
        case .expired: .red
        }
    }

    private func setPaused(_ paused: Bool) {
        Task {
            if paused {
                _ = try? await model.services.agents.pause(agentID: agent.id, now: Date())
            } else {
                _ = try? await model.services.agents.resume(agentID: agent.id, now: Date())
            }
            await model.refresh()
        }
    }
}

/// Under the sidebar, only while something's off: agents paused (with Resume), or the agent
/// server off or stopped.
struct SidebarStatus: View {
    let model: AppModel

    static func shows(_ model: AppModel) -> Bool {
        if model.pausedUntil != nil || !model.preferences.mcpEnabled { return true }
        switch model.mcpStatus {
        case .listening, .starting: return false
        case .off, .failed: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            if model.pausedUntil != nil {
                Button(String(localized: "Resume")) { model.resume() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var color: Color {
        switch model.iconState {
        case .normal, .needsYou: .green
        case .paused: .orange
        case .off: .secondary
        }
    }

    private var text: String {
        if let until = model.pausedUntil { return StatusMenuController.pausedText(until, now: model.now) }
        if !model.preferences.mcpEnabled { return String(localized: "Agents can't connect: the server is off") }
        switch model.mcpStatus {
        case .listening: return String(localized: "Agents can connect")
        case .starting: return String(localized: "Starting…")
        case .off: return String(localized: "The agent server is off")
        case .failed(.portInUse(let port)): return String(localized: "Port \(String(port)) is in use by another app")
        case .failed: return String(localized: "The agent server stopped")
        }
    }
}
