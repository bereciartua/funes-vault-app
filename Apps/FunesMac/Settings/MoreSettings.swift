import AppKit
import BridgeKitCore
import BridgeUI
import FunesCore
import FunesMCP
import FunesProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ MCP (04-ux-mac.md): server on or off, port, the launcher and its optional symlink,
/// protocol counts (never bodies).
struct MCPSettings: View {
    let model: AppModel
    @State private var on = true
    @State private var port = FunesMCPConfiguration.defaultPort
    @State private var portMessage: String?
    @State private var linkMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Let agents connect"), isOn: $on)
                    .onChange(of: on) { _, value in model.setServer(value) }
                LabeledContent(String(localized: "Status"), value: SidebarStatusText.text(model))
                LabeledContent(String(localized: "Port")) {
                    HStack {
                        if port != model.mcpPort {
                            Button(String(localized: "Change Port")) { changePort() }
                        }
                        TextField(String(localized: "Port"), value: $port, format: .number.grouping(.never))
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70)
                            .onSubmit { changePort() }
                    }
                }
                LabeledContent(String(localized: "Address")) {
                    Text(verbatim: "http://127.0.0.1:\(model.mcpPort)/mcp").font(.callout.monospaced()).textSelection(.enabled)
                }
                if case .failed(.portInUse) = model.mcpStatus {
                    Text(String(localized: "Another app is using port \(String(model.mcpPort)). Quit it, then turn this off and on again, or choose another port. Funes never moves on its own, because agents' setups name the port."))
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let portMessage {
                    Text(portMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(String(localized: "Launcher")) {
                LabeledContent(String(localized: "funes-mcp")) { MonoText(text: model.launcherPath) }
                Text(String(localized: "Agents start the launcher, which reads their key file and talks to Funes. Setups on the Connect tab use this path."))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if model.launcherLinked {
                        Text(String(localized: "Linked as ~/.local/bin/funes-mcp")).foregroundStyle(.secondary)
                        Button(String(localized: "Remove Link")) { linkMessage = model.setLauncherLink(false) }
                    } else {
                        Button(String(localized: "Link to ~/.local/bin/funes-mcp")) { linkMessage = model.setLauncherLink(true) }
                    }
                }
                if let linkMessage { Text(linkMessage).font(.callout).foregroundStyle(.secondary) }
            }
            Section(String(localized: "Traffic since launch")) {
                let counts = model.trafficCounts()
                LabeledContent(String(localized: "Requests"), value: "\(counts.requests)")
                LabeledContent(String(localized: "Refused keys"), value: "\(counts.authFailures)")
                ForEach(counts.byStatus.sorted { $0.key < $1.key }, id: \.key) { status, count in
                    LabeledContent(String(localized: "HTTP \(String(status))"), value: "\(count)")
                }
                Text(String(localized: "Counts only: Funes never logs what agents send or receive."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            on = model.preferences.mcpEnabled
            port = model.mcpPort
        }
    }

    private func changePort() {
        let range = FunesMCPConfiguration.portRange
        guard range.contains(port) else {
            portMessage = String(localized: "Choose a port from \(String(range.lowerBound)) to \(String(range.upperBound)).")
            return
        }
        guard port != model.mcpPort else { return }
        model.setPort(port)
        portMessage = String(localized: "Agents that start funes-mcp follow the new port on their own. Set up again any agent whose setup names the address, such as Claude Code.")
    }
}

enum SidebarStatusText {
    @MainActor
    static func text(_ model: AppModel) -> String {
        if !model.preferences.mcpEnabled { return String(localized: "Off") }
        switch model.mcpStatus {
        case .listening: return model.pausedUntil == nil ? String(localized: "On") : String(localized: "On, but Funes is paused")
        case .starting: return String(localized: "Starting…")
        case .off: return String(localized: "Off")
        case .failed(.portInUse(let port)): return String(localized: "Port \(String(port)) is in use")
        case .failed: return String(localized: "Stopped after an error")
        }
    }
}

/// Settings ▸ Data (FR-G-04, FR-G-05, FR-X-05, FR-X-06): backups, export, import, Show in Finder,
/// Erase All Data.
struct DataSettings: View {
    let model: AppModel
    @State private var backups: [URL] = []
    @State private var automatic = true
    @State private var message: String?
    @State private var includeArchived = false
    @State private var restoring: URL?
    @State private var erasing = false
    @State private var importing: ImportKind?

    var body: some View {
        Form {
            Section(String(localized: "Backups")) {
                Toggle(String(localized: "Back up the vault every day"), isOn: $automatic)
                    .onChange(of: automatic) { _, on in model.preferences.defaults.set(on, forKey: Preferences.Key.automaticBackups) }
                LabeledContent(String(localized: "Last backup"),
                               value: model.data.lastBackup.map(RelativeTime.full) ?? String(localized: "None yet"))
                HStack {
                    Button(String(localized: "Back Up Now")) {
                        do {
                            try model.data.backUpNow()
                            message = String(localized: "Backed up.")
                        } catch {
                            message = String(localized: "The backup couldn't be written.")
                        }
                        backups = model.data.backups()
                    }
                    Menu(String(localized: "Restore from Backup…")) {
                        ForEach(backups, id: \.self) { url in
                            Button(Self.label(url)) { restoring = url }
                        }
                    }
                    .fixedSize()
                    .disabled(backups.isEmpty)
                }
                if model.data.integrityProblem {
                    Label(String(localized: "The weekly check found a problem with the vault file. Restore the latest backup."),
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(String(localized: "Funes keeps the last 7 backups in its data folder."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(String(localized: "Export and import")) {
                Toggle(String(localized: "Include archived memories"), isOn: $includeArchived)
                Button(String(localized: "Export…")) { export() }
                Text(String(localized: "A funesvault.export.v1 file with your categories and memories. It never includes agents, their access, keys or Activity."))
                    .font(.callout).foregroundStyle(.secondary)
                Menu(String(localized: "Import…")) {
                    Button(String(localized: "Funes Vault Export…")) { importing = .funes }
                    Button(String(localized: "ChatGPT Memories…")) { importing = .chatGPT }
                    Button(String(localized: "Claude Memories…")) { importing = .claude }
                    Button(String(localized: "Markdown File…")) { importing = .markdown }
                }
                .fixedSize()
            }
            Section(String(localized: "Data folder")) {
                LabeledContent(String(localized: "Location")) { MonoText(text: model.services.dataFolder.path) }
                Button(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([model.services.dataFolder]) }
                Button(String(localized: "Erase All Data…"), role: .destructive) { erasing = true }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .onAppear {
            backups = model.data.backups()
            automatic = model.preferences.defaults.bool(forKey: Preferences.Key.automaticBackups)
        }
        .confirmationDialog(String(localized: "Restore this backup?"), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button(String(localized: "Restore and Relaunch")) {
                if let restoring { try? model.data.restore(restoring) }
            }
        } message: {
            Text(String(localized: "Funes relaunches with the vault as it was then. The current vault is kept in Backups first."))
        }
        .confirmationDialog(String(localized: "Erase all of Funes Vault's data?"), isPresented: $erasing) {
            Button(String(localized: "Export First…")) { export() }
            Button(String(localized: "Erase All Data"), role: .destructive) { model.data.eraseAll(modelSettings: model.modelSettings) }
        } message: {
            Text(String(localized: "This deletes every memory, suggestion, agent and key, Activity, backups and AI provider keys, then relaunches empty. It can't be undone. Agents' own settings still name Funes until you remove it there."))
        }
        .sheet(item: $importing) { kind in ImportSheet(model: model, kind: kind) }
    }

    static func label(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate.map(RelativeTime.full) ?? url.lastPathComponent
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Funes Vault \(Date().formatted(.iso8601.year().month().day())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let includeArchived = includeArchived
        Task {
            do {
                let data = try await model.data.export(includeArchived: includeArchived)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                message = String(localized: "Exported.")
            } catch {
                message = String(localized: "The export couldn't be written.")
            }
        }
    }
}

/// Settings ▸ Updates (FR-G-03): automatic checks and Check Now, through Sparkle.
struct UpdateSettings: View {
    let model: AppModel
    @State private var automatic = true

    var body: some View {
        Form {
            if model.updater.isAvailable() {
                Toggle(String(localized: "Check for updates every day"), isOn: $automatic)
                    .onChange(of: automatic) { _, on in model.updater.setAutomaticChecks(on) }
                LabeledContent(String(localized: "Last checked"),
                               value: model.updater.lastCheck().map(RelativeTime.full) ?? String(localized: "Never"))
                Button(String(localized: "Check Now")) { model.updater.checkForUpdates() }
                Text(String(localized: "Updates come from GitHub, signed for Funes Vault. Installing always takes a click, and waits while a request is waiting for you."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(String(localized: "This copy of Funes Vault can't update itself (a development build, or one without its update key). Download new versions from GitHub."))
                    .foregroundStyle(.secondary)
            }
            LabeledContent(String(localized: "Version"), value: model.versionText)
        }
        .formStyle(.grouped)
        .onAppear { automatic = model.updater.automaticChecks() }
    }
}

/// Settings ▸ Advanced: Activity retention (Q20) and resetting the setup checklist.
struct AdvancedSettings: View {
    let model: AppModel
    @State private var important = 400
    @State private var other = 30
    @State private var reset = false

    var body: some View {
        Form {
            Section(String(localized: "Activity")) {
                Stepper(value: $important, in: 30...730, step: 10) {
                    LabeledContent(String(localized: "Keep shares, refusals and changes"), value: String(localized: "\(important) days"))
                }
                Stepper(value: $other, in: 1...365) {
                    LabeledContent(String(localized: "Keep everything else"), value: String(localized: "\(other) days"))
                }
                Text(String(localized: "At most 20,000 important rows are kept. Older rows go at the next cleanup (at launch and every 6 hours)."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(String(localized: "Restore Defaults")) {
                    important = 400
                    other = 30
                }
            }
            Section(String(localized: "Setup")) {
                Button(String(localized: "Show the Setup Checklist Again")) {
                    model.checklist.reset(model: model)
                    reset = true
                }
                if reset { Text(String(localized: "It's at the top of the Vault.")).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            important = model.preferences.defaults.integer(forKey: Preferences.Key.importantRetentionDays)
            other = model.preferences.defaults.integer(forKey: Preferences.Key.routineRetentionDays)
        }
        .onChange(of: important) { _, _ in save() }
        .onChange(of: other) { _, _ in save() }
    }

    private func save() {
        model.preferences.defaults.set(important, forKey: Preferences.Key.importantRetentionDays)
        model.preferences.defaults.set(other, forKey: Preferences.Key.routineRetentionDays)
        model.services.activity.store.setRetention(model.preferences.activityRetention)
    }
}
