import BridgeUI
import FunesCore
import FunesProtocol
import ServiceManagement
import SwiftUI

/// Settings (04-ux-mac.md ▸ Settings, ADR-0030): a fixed sidebar with the profile row and eleven
/// panes in four groups, and the chosen pane in a stack whose pages open inside it. Back stays
/// within the pane; choosing a pane shows its top level. The sidebar is a `List` beside the pane,
/// not a `NavigationSplitView`, whose sidebar could be dragged and collapsed (Phase 11.0, ADR-0030
/// §1).
struct SettingsView: View {
    @Bindable var model: AppModel
    static let sidebarWidth: CGFloat = 210

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: Self.sidebarWidth)
            Divider()
            NavigationStack(path: $model.settingsPath) {
                pane(model.settingsPane)
                    .navigationTitle(model.settingsPane.title)
                    .navigationDestination(for: SettingsPage.self) { page in
                        SettingsPageView(model: model, page: page)
                    }
            }
            .id(model.settingsPane)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder
    private func pane(_ pane: SettingsPane) -> some View {
        switch pane {
        case .aboutYou: AboutYouSettings(model: model)
        case .general: GeneralSettings(model: model)
        case .notifications: NotificationSettings(model: model)
        case .capture: CaptureSettings(model: model)
        case .features: FeaturesPane(model: model)
        case .accounts: AccountsPane(model: model)
        case .privacy: PrivacyPane(model: model)
        case .agentServer: MCPSettings(model: model)
        case .iphone: IPhoneSettings(model: model)
        case .data: DataSettings(model: model)
        case .advanced: AdvancedSettings(model: model)
        }
    }
}

/// A page inside a pane, with the toolbar's "‹ <pane>" (⌘[) in place of the stack's own chevron,
/// so it names where it goes back to (ADR-0030 §1).
struct SettingsPageView: View {
    let model: AppModel
    let page: SettingsPage

    var body: some View {
        content
            .id(page)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        if !model.settingsPath.isEmpty { model.settingsPath.removeLast() }
                    } label: {
                        Label(page.pane.title, systemImage: "chevron.left").labelStyle(.titleAndIcon)
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityLabel(String(localized: "Back to \(page.pane.title)"))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .newMemories: NewMemoriesPage(model: model).navigationTitle(String(localized: "New memories"))
        case .tidyUp: TidyUpPage(model: model).navigationTitle(String(localized: "Daily tidy-up"))
        case .searchAnswers: SearchAnswersPage(model: model).navigationTitle(String(localized: "Search answers"))
        case .searchIndex: SearchIndexPage(model: model).navigationTitle(String(localized: "Search index"))
        case let .account(id): AccountPage(model: model, id: id)
        }
    }
}

/// The sidebar: the profile row, then the groups with plain headers. Not collapsible, fixed width.
struct SettingsSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.settingsPane }, set: { if let pane = $0 { model.showSettingsPane(pane) } })) {
            ProfileRow(profile: model.profile)
                .tag(SettingsPane.aboutYou)
            ForEach(SettingsPane.Group.allCases, id: \.self) { group in
                Section {
                    ForEach(group.panes) { pane in
                        Label {
                            Text(pane.title)
                        } icon: {
                            SettingsIcon(pane: pane)
                        }
                        .tag(pane)
                    }
                } header: {
                    if let title = group.title {
                        Text(title).accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The profile row (04-ux-mac.md ▸ Settings ▸ Window): initials and the full name over "About
/// You", or "About You" alone while the profile is empty.
struct ProfileRow: View {
    let profile: Profile

    private var name: String? { ProfileText.fullName(profile) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.gray.gradient)
                if let initials {
                    Text(initials).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(.white)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                if let name {
                    Text(name).font(.headline).lineLimit(1)
                    Text(String(localized: "About You")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "About You")).font(.headline)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.map { String(localized: "About You, \($0)") } ?? String(localized: "About You"))
    }

    /// From Call me, or the given and family name: "MB".
    private var initials: String? {
        let words: [String]
        if let preferred = profile.preferredName, profile.givenName == nil, profile.familyName == nil {
            words = preferred.split(separator: " ").map(String.init)
        } else {
            words = [profile.givenName, profile.familyName].compactMap { $0 }
        }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? nil : letters
    }
}

/// A pane's symbol on a colored rounded square, like System Settings'.
struct SettingsIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.gradient))
    }

    private var tint: Color {
        switch pane {
        case .aboutYou, .general, .advanced: .gray
        case .notifications: .red
        case .capture: .orange
        case .features: .purple
        case .accounts: .yellow
        case .privacy: .blue
        case .agentServer: .teal
        case .iphone: .cyan
        case .data: .indigo
        }
    }
}

/// Appearance (FR-G-06), launch at login (FR-G-02), the Dock icon, and Updates (FR-G-03), folded
/// in from their own tab (ADR-0030 §2).
struct GeneralSettings: View {
    let model: AppModel
    @State private var appearance = AppAppearance.automatic
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var showInDock = false
    @State private var automaticUpdates = true

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Appearance"), selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: appearance) { _, value in
                    model.preferences.appearance = value
                    value.apply()
                }
                Text(String(localized: "Automatic follows macOS."))
                    .font(.callout).foregroundStyle(.secondary)
            }
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
            Section(String(localized: "Updates")) {
                if model.updater.isAvailable() {
                    Toggle(String(localized: "Check for updates every day"), isOn: $automaticUpdates)
                        .onChange(of: automaticUpdates) { _, on in model.updater.setAutomaticChecks(on) }
                    LabeledContent(String(localized: "Last checked")) {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(model.updater.lastCheck().map(RelativeTime.full) ?? String(localized: "Never"))
                            Button(String(localized: "Check Now")) { model.updater.checkForUpdates() }
                        }
                    }
                    Text(String(localized: "Updates come from GitHub, signed for Funes Vault. Installing always takes a click, and waits while a request is waiting for you."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "This copy of Funes Vault doesn't check for updates (a build from source, or a development build). Download new versions from GitHub."))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(String(localized: "Version"), value: model.versionText)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appearance = model.preferences.appearance
            showInDock = model.preferences.showInDock
            launchAtLogin = LoginItem.isEnabled
            automaticUpdates = model.updater.automaticChecks()
        }
    }
}

/// Settings ▸ Notifications (FR-L-04): the four switches, moved out of General unchanged.
struct NotificationSettings: View {
    let model: AppModel
    @State private var notifyExpired = false
    @State private var notifySuggestion = false
    @State private var notifyRefused = false
    @State private var notifyTunnelDown = false

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "A request expired before you answered"), isOn: $notifyExpired)
                    .onChange(of: notifyExpired) { _, on in model.setNotification(Preferences.Key.notifyExpired, on) }
                Toggle(String(localized: "A suggestion is waiting in the Inbox"), isOn: $notifySuggestion)
                    .onChange(of: notifySuggestion) { _, on in model.setNotification(Preferences.Key.notifySuggestion, on) }
                Toggle(String(localized: "An agent was refused more than 5 times in 10 minutes"), isOn: $notifyRefused)
                    .onChange(of: notifyRefused) { _, on in model.setNotification(Preferences.Key.notifyRefused, on) }
                Toggle(String(localized: "Remote Access's tunnel stopped"), isOn: $notifyTunnelDown)
                    .onChange(of: notifyTunnelDown) { _, on in model.setNotification(RemoteAccessController.Key.notifyTunnelDown, on) }
                Text(String(localized: "Notifications never include memory text."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            notifyExpired = model.preferences.notifyExpired
            notifySuggestion = model.preferences.notifySuggestion
            notifyRefused = model.preferences.notifyRefused
            notifyTunnelDown = model.preferences.flag(RemoteAccessController.Key.notifyTunnelDown)
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
