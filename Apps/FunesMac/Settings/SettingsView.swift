import FunesCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, capture, models, mcp, data, updates, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .capture: String(localized: "Capture")
        case .models: String(localized: "AI Models")
        case .mcp: String(localized: "MCP")
        case .data: String(localized: "Data")
        case .updates: String(localized: "Updates")
        case .advanced: String(localized: "Advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .capture: "square.and.pencil"
        case .models: "cpu"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .data: "externaldrive"
        case .updates: "arrow.down.circle"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// Settings (04-ux-mac.md): one pane per tab.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                pane(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 460)
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings(model: model)
        case .capture: CaptureSettings(model: model)
        case .models: ModelSettings(model: model)
        case .mcp: MCPSettings(model: model)
        case .data: DataSettings(model: model)
        case .updates: UpdateSettings(model: model)
        case .advanced: AdvancedSettings(model: model)
        }
    }
}

/// Launch at login (FR-G-02), the Dock icon and notifications (FR-L-04).
struct GeneralSettings: View {
    let model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var showInDock = false
    @State private var notifyExpired = false
    @State private var notifySuggestion = false
    @State private var notifyRefused = false

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Open Funes Vault at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        loginError = LoginItem.set(on)
                        launchAtLogin = LoginItem.isEnabled
                    }
                if LoginItem.needsApproval {
                    Text(String(localized: "macOS needs your approval in System Settings ▸ General ▸ Login Items."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let loginError { Text(loginError).font(.callout).foregroundStyle(.red) }
                Toggle(String(localized: "Show in Dock"), isOn: $showInDock)
                    .onChange(of: showInDock) { _, on in
                        model.preferences.showInDock = on
                        model.dockPreferenceChanged()
                    }
                Text(String(localized: "Funes Vault always stays in the menu bar. Without the Dock icon, it shows in the Dock only while a window is open."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(String(localized: "Notifications")) {
                Toggle(String(localized: "A request expired before you answered"), isOn: $notifyExpired)
                    .onChange(of: notifyExpired) { _, on in model.setNotification(Preferences.Key.notifyExpired, on) }
                Toggle(String(localized: "A suggestion is waiting in the Inbox"), isOn: $notifySuggestion)
                    .onChange(of: notifySuggestion) { _, on in model.setNotification(Preferences.Key.notifySuggestion, on) }
                Toggle(String(localized: "An agent was refused more than 5 times in 10 minutes"), isOn: $notifyRefused)
                    .onChange(of: notifyRefused) { _, on in model.setNotification(Preferences.Key.notifyRefused, on) }
                Text(String(localized: "Notifications never include memory text."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            showInDock = model.preferences.showInDock
            notifyExpired = model.preferences.notifyExpired
            notifySuggestion = model.preferences.notifySuggestion
            notifyRefused = model.preferences.notifyRefused
            launchAtLogin = LoginItem.isEnabled
        }
    }
}

/// `SMAppService.mainApp` (FR-G-02).
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Turns it on or off; returns a message when macOS refused.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return on ? String(localized: "macOS didn't add Funes Vault to Login Items.")
                      : String(localized: "macOS didn't remove Funes Vault from Login Items.")
        }
    }
}
