import FunesCore
import SwiftUI

/// The main window: a sidebar with the sections and the section's content (04-ux-mac.md).
struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(badge(section))
                        .tag(section)
                        .accessibilityLabel(accessibilityLabel(section))
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarStatus(model: model) }
        } detail: {
            Group {
                switch model.section {
                case .vault: VaultView(model: model)
                case .inbox: InboxView(model: model)
                case .agents: AgentsView(model: model)
                case .activity: ActivityScreen(model: model)
                }
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: MainWindowController.minimumSize.width, minHeight: MainWindowController.minimumSize.height)
        .sheet(isPresented: Binding(get: { model.checklist.showSeedQuestions }, set: { model.checklist.showSeedQuestions = $0 })) {
            SeedQuestionsSheet(model: model)
        }
        .sheet(item: Binding(get: { model.checklist.showImport }, set: { model.checklist.showImport = $0 })) { kind in
            ImportSheet(model: model, kind: kind)
        }
    }

    private func badge(_ section: AppSection) -> Int {
        switch section {
        case .inbox: model.inboxCount
        case .activity: model.pending.count
        default: 0
        }
    }

    private func accessibilityLabel(_ section: AppSection) -> String {
        switch section {
        case .inbox where model.inboxCount > 0: String(localized: "Inbox, \(model.inboxCount) waiting")
        case .activity where !model.pending.isEmpty: String(localized: "Activity, \(model.pending.count) pending requests")
        default: section.title
        }
    }
}

/// Under the sidebar: whether agents can reach Funes, and Resume while paused.
struct SidebarStatus: View {
    let model: AppModel

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
