import BridgeUI
import FunesCore
import FunesProtocol
import SwiftUI

/// Agents (04-ux-mac.md, FR-A-01..12): the list with each agent's status and access, and the
/// selected agent's Access, Connect and Activity tabs.
struct AgentsView: View {
    @Bindable var model: AppModel
    @State private var adding = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text(String(localized: "Agents")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { adding = true } label: { Label(String(localized: "Add Agent…"), systemImage: "plus") }
                }
                .padding(16)
                Divider()
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
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
            .background(Palette.card)
            Group {
                if let agent = model.agent(model.selectedAgentID) {
                    AgentDetailView(model: model, agent: agent).id(agent.id)
                } else {
                    ContentUnavailableView(String(localized: "No agent selected"), systemImage: "person.crop.circle",
                                           description: Text(String(localized: "Select an agent to change its access or connect it.")))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.pane)
        }
        .sheet(isPresented: $adding) {
            AddAgentSheet(model: model) { id in
                model.selectedAgentID = id
                model.agentTab = .connect
            }
        }
        .onChange(of: model.addAgentRequest) { _, _ in adding = true }
        .onAppear {
            if model.selectedAgentID == nil { model.selectedAgentID = model.agents.first?.id }
        }
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
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
    case access, connect, activity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .access: String(localized: "Access")
        case .connect: String(localized: "Connect")
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
                ForEach(AgentTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 10)
            Divider()
            switch model.agentTab {
            case .access: AccessEditor(model: model, agent: agent)
            case .connect: ConnectTab(model: model, agent: agent)
            case .activity:
                ActivityList(model: model, scope: .agent(agent.id))
                    .padding(16)
            }
        }
        .confirmationDialog(String(localized: "Remove \(agent.name)?"), isPresented: $confirmRemove) {
            Button(String(localized: "Remove"), role: .destructive) { remove() }
        } message: {
            Text(String(localized: "Its key stops working at once and its access is deleted. Activity keeps its history, labelled “removed agent”. Its entry in the agent's own settings stays until you delete it there."))
        }
        .sheet(isPresented: $renaming) { renameSheet }
    }

    /// The name and status take the room; the buttons keep their size. The kind is one line that
    /// truncates, and is left out when the name already says it.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentIcon(kind: agent.agentKind, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    Button { newName = agent.name; renaming = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "Rename \(agent.name)"))
                }
                HStack(spacing: 6) {
                    Pill(label: AgentText.statusLine(agent, now: model.now, client: model.clientName(agent.id)),
                         tone: AgentText.tone(agent, now: model.now))
                        .fixedSize()
                    let kind = agent.agentKind.setupAgent.displayName
                    if kind != agent.name {
                        Text(kind).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: 8) {
                if agent.paused {
                    Button(String(localized: "Resume")) { run { try await model.services.agents.resume(agentID: agent.id, now: Date()) } }
                } else {
                    Button(String(localized: "Pause")) { run { try await model.services.agents.pause(agentID: agent.id, now: Date()) } }
                        .help(String(localized: "Refuse this agent's requests until you resume it"))
                }
                Button(String(localized: "Remove…"), role: .destructive) { confirmRemove = true }
            }
            .fixedSize()
        }
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
            try await model.services.agents.remove(agentID: agent.id, now: Date())
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
