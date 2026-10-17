import AppKit
import BridgeKitCore
import BridgeUI
import FunesCore
import FunesMCP
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "app")

@main
enum FunesMacApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        #if FUNES_UI_REVIEW
        if UIReview.handles(CommandLine.arguments) {
            let review = UIReview()
            app.delegate = review
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(review) { app.run() }
            return
        }
        #endif
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    static let identity = AppMover.Identity(displayName: "Funes Vault", bundleFileName: "FunesVault.app",
                                            bundleID: Identifiers.macBundleID)
}

/// The menu bar app (task 3.1): the vault and the MCP server run for the app's lifetime; the main
/// window and Settings open on demand.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private var environment: VaultEnvironment?
    private var model: AppModel?
    private var menu: StatusMenuController?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var mcp: FunesMCPServer?
    private var minuteTimer: Timer?
    private var failedItem: NSStatusItem?
    private let hud = HUD()
    private let notifier = Notifier()
    private var capture: CaptureController?
    private var updater: SparkleUpdater?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMover.waitForPreviousCopy()
        NSApp.mainMenu = MainMenu.build(target: self)
        let environment: VaultEnvironment
        do {
            environment = try VaultEnvironment(retention: preferences.activityRetention)
        } catch {
            logger.error("The vault didn't open")
            showOpenFailure(error)
            return
        }
        self.environment = environment
        if let until = preferences.pausedUntil, until > Date() { environment.pause.pause(until: until) }

        let model = AppModel(services: environment, preferences: preferences)
        self.model = model
        let mainWindow = MainWindowController(model: model)
        let settingsWindow = SettingsWindowController(model: model)
        self.mainWindow = mainWindow
        self.settingsWindow = settingsWindow
        mainWindow.visibilityChanged = { [weak self] in self?.updateActivationPolicy() }
        settingsWindow.visibilityChanged = { [weak self] in self?.updateActivationPolicy() }
        model.openMainWindow = { mainWindow.show() }
        model.openSettings = { tab in
            if let tab { model.settingsTab = tab }
            settingsWindow.show()
        }
        model.openPendingRequest = { id in Task { await environment.approvals.open(requestID: id) } }
        model.dockPreferenceChanged = { [weak self] in self?.updateActivationPolicy() }

        wirePanels(environment, model: model)
        let capture = CaptureController(model: model, hud: hud)
        self.capture = capture
        model.openCapture = { capture.show() }
        let hotKey = HotKey { capture.show() }
        hotKey.register(preferences.captureShortcut)
        self.hotKey = hotKey
        model.setCaptureShortcut = { [preferences] shortcut in
            guard hotKey.register(shortcut) else {
                hotKey.register(preferences.captureShortcut)
                return false
            }
            preferences.captureShortcut = shortcut
            return true
        }
        NSApp.servicesProvider = capture
        NSUpdateDynamicServices()
        let menu = StatusMenuController(model: model)
        self.menu = menu
        // Updates (FR-G-03): the relaunch waits while a panel is waiting for the user.
        let gate = UpdateRelaunchGate(pendingApprovals: { environment.approvals.queue.items.count },
                                      maximumWait: FunesApprovals.panelSeconds + 15)
        let updater = SparkleUpdater(gate: gate)
        updater.start()
        self.updater = updater
        model.updater = updater.controls
        menu.checkForUpdates = { model.updater.checkForUpdates() }
        menu.updatesAvailable = { model.updater.isAvailable() }
        model.data.integrityFailed = { [notifier] in
            notifier.post(.refused, title: String(localized: "The vault needs attention"),
                          body: String(localized: "Its weekly check found a problem. Restore a backup in Settings ▸ Data."))
        }
        model.data.startJobs()
        model.changed = { [weak menu] in menu?.update() }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let mcp = FunesMCPServer(services: environment.services, presenter: environment.approvals,
                                 dataFolder: environment.dataFolder, version: version)
        mcp.statusChanged = { [weak model] status in
            model?.mcpStatus = status
            model?.changed()
        }
        self.mcp = mcp
        model.setServer = { [weak self] on in self?.setServer(on) }
        model.mcpPort = mcp.configuration.mcpPort
        model.trafficCounts = { [weak mcp] in mcp?.counters.snapshot ?? MCPTrafficCounters.Snapshot() }
        model.connection = { [weak mcp] id in mcp?.connections[id.db]?.agent }
        model.setupControls = OneClickAgents.live(home: Self.setupHome, appName: "Funes Vault", tag: "funes")
        model.detectAgents = { AgentDetection.installed(.live) }
        Task {
            #if DEBUG
            await DevSeed.runIfAsked(environment)
            #endif
            if preferences.mcpEnabled { mcp.start() }
            await model.refresh()
        }
        startMinuteJob(environment, model: model)
        if let movedFrom = AppMover.movedFrom(), InstallLocation.volume(of: movedFrom) == nil {
            AppMover.cleanUpOldCopy(FunesMacApp.identity, movedFrom) { _ in }
        }
        updateActivationPolicy()
        if !preferences.flag(Preferences.Key.checklistDismissed), !preferences.flag("HasLaunched") {
            preferences.set("HasLaunched", true)
            mainWindow.show()
        }
        offerMoveToApplications()
        #if DEBUG
        // FUNES_DEBUG_OPEN=vault|inbox|agents|activity|settings[:tab] opens a window at launch.
        if let open = ProcessInfo.processInfo.environment["FUNES_DEBUG_OPEN"], !open.isEmpty {
            let parts = open.split(separator: ":").map(String.init)
            if parts[0] == "capture" {
                model.openCapture()
            } else if parts[0] == "settings" {
                model.openSettings(parts.count > 1 ? SettingsTab(rawValue: parts[1]) : nil)
            } else if let section = AppSection(rawValue: parts[0]) {
                model.show(section)
                if parts.count > 2, let tab = AgentTab(rawValue: parts[2]) { model.agentTab = tab }
                if parts.count > 1, parts[1] == "first" {
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        if let first = model.vault.memories.first { model.vault.selection = [first.id] }
                        if let first = model.agents.first { model.selectedAgentID = first.id }
                    }
                }
            }
        }
        #endif
        logger.info("Launched")
    }

    /// Where one-click setup writes agents' configs: the user's home, except for a development
    /// vault (Debug on FUNES_DATA_DIR), which writes into a scratch home so it never points the
    /// user's real agents at a development build.
    static var setupHome: String {
        guard Preferences.isDevelopmentVault else { return NSHomeDirectory() }
        let home = (ProcessInfo.processInfo.environment["FUNES_DATA_DIR"] ?? NSTemporaryDirectory()) + "-agent-home"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Open panels are refused (`funes_quit`); the endpoint file goes with the listener.
        environment?.approvals.queue.withdrawAll()
        mcp?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.show()
        return false
    }

    /// The panels' notices, Edit… and the optional notifications (FR-L-04).
    private func wirePanels(_ environment: VaultEnvironment, model: AppModel) {
        let approvals = environment.approvals
        let preferences = self.preferences
        let notifier = self.notifier
        approvals.notice = { [hud] text in hud.show(text, symbol: "hourglass") }
        approvals.editSuggestion = { id in
            model.inboxState.focused = id
            model.show(.inbox)
        }
        approvals.suggestionArrived = { name in
            guard preferences.notifySuggestion else { return }
            notifier.post(.suggestion, title: String(localized: "A suggestion is waiting"),
                          body: String(localized: "\(name) suggested a memory. Review it in the Inbox."))
        }
        model.requestNotificationPermission = { done in notifier.requestPermission(done) }
        model.activityAppended = { event in
            guard preferences.notifyRefused, event.outcome == "denied", event.actor.hasPrefix("agent:"),
                  let id = UUID(uuidString: String(event.actor.dropFirst(6))),
                  notifier.noteRefusal(agentID: id, at: event.time) else { return }
            notifier.post(.refused, title: String(localized: "\(model.agentName(id)) was refused repeatedly"),
                          body: String(localized: "More than 5 requests were refused in 10 minutes. See why in Activity."),
                          agentID: id)
        }
        notifier.onOpen = { kind, agent in
            switch kind {
            case .suggestion: model.show(.inbox)
            case .expired, .refused: model.showActivity(agent.map(ActivityFocus.agent))
            }
        }
    }

    /// The MCP server switch (Settings ▸ MCP).
    private func setServer(_ on: Bool) {
        preferences.mcpEnabled = on
        if on { mcp?.start() } else {
            environment?.approvals.queue.withdrawAll()
            mcp?.stop()
        }
        model?.changed()
    }

    /// Pending requests past their 15 minutes are denied, and old suggestions expire (access
    /// policy §3.9); the clock the menu and lists show moves on.
    private func startMinuteJob(_ environment: VaultEnvironment, model: AppModel) {
        let preferences = self.preferences
        let notifier = self.notifier
        let job: @MainActor () -> Void = {
            // Requests about to be denied for want of an answer (FR-L-04).
            if preferences.notifyExpired {
                for request in model.pending where request.status == .needsApproval && request.expiresAt <= Date() {
                    notifier.post(.expired, title: String(localized: "A request expired"),
                                  body: String(localized: "\(request.agentName)'s request waited 15 minutes without an answer."),
                                  agentID: request.agentID)
                }
            }
            model.tick()
            Task {
                _ = try? await environment.disclosures.expirePending(now: Date())
                _ = try? await environment.suggestions.expire(now: Date())
            }
        }
        job()
        let timer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { job() } }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    /// The Dock icon shows while a window is open, or always with Show in Dock.
    private func updateActivationPolicy() {
        let windowOpen = (mainWindow?.isVisible ?? false) || (settingsWindow?.isVisible ?? false)
        let policy: NSApplication.ActivationPolicy = preferences.showInDock || windowOpen ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// FR-O-03: offered once per launch when the app runs from Downloads or a disk image.
    private func offerMoveToApplications() {
        #if !DEBUG
        guard AppMover.location != .applications, !preferences.flag("MoveDeclined") else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Move Funes Vault to Applications?")
        alert.informativeText = String(localized: "It's running from \(AppMover.location.placeName(home: NSHomeDirectory())). In Applications it can open at login and update itself.")
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            preferences.set("MoveDeclined", true)
            return
        }
        if case .failed(let problem) = AppMover.move(FunesMacApp.identity, prepareToQuit: { NSApp.terminate(nil) }) {
            let failure = NSAlert()
            failure.messageText = String(localized: "Funes Vault couldn't be moved")
            failure.informativeText = problem
            failure.runModal()
        }
        #endif
    }

    /// The vault can't open (a newer schema, unsafe permissions): say so in the menu bar.
    private func showOpenFailure(_ error: Error) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image(.off)
        let menu = NSMenu()
        let line = NSMenuItem(title: String(localized: "The vault didn't open"), action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.addItem(line)
        let reason = NSMenuItem(title: ErrorText.message(error), action: nil, keyEquivalent: "")
        reason.isEnabled = false
        menu.addItem(reason)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Funes Vault"), action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        item.menu = menu
        failedItem = item
    }

    // MARK: Main menu actions

    @objc func showSettings(_ sender: Any?) { model?.openSettings(nil) }
    @objc func newMemory(_ sender: Any?) {
        guard let model else { return }
        model.show(.vault)
        model.newMemoryRequest += 1
    }
    @objc func findInVault(_ sender: Any?) {
        guard let model else { return }
        if model.section != .vault && model.section != .activity { model.section = .vault }
        model.searchFocusRequest += 1
    }
    @objc func remember(_ sender: Any?) { model?.openCapture() }
    @objc func showSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let section = AppSection(rawValue: raw) else { return }
        model?.show(section)
    }
}
