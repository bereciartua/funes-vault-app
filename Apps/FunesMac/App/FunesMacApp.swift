import AppKit
import BridgeKitCore
import BridgeKitRemote
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
    private var remote: FunesRemoteServer?
    private var signInPanel: SignInPanelController?
    private let keepAwake = KeepAwake(reason: "Funes Vault Remote Access is on")
    private var minuteTimer: Timer?
    private var failedItem: NSStatusItem?
    private let hud = HUD()
    private let notifier = Notifier()
    private var capture: CaptureController?
    private var updater: SparkleUpdater?
    private var hotKey: HotKey?
    private var reviewHotKey: HotKey?
    /// The data folder's instance lock, held while this copy runs.
    private var instanceLock: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A relaunch waits for the copy before it to quit, then carries out a pending Erase All
        // Data before the settings are read or the vault opens (FR-G-05).
        AppMover.waitForPreviousCopy()
        if handOffToRunningCopy() { return }
        DataOperations.applyPendingErase(dataFolder: VaultEnvironment.defaultDataFolder(), defaults: preferences.defaults)
        // Before any window, panel or alert shows (FR-G-06).
        preferences.appearance.apply()
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
        model.openSettings = { destination in
            model.goToSettings(destination)
            settingsWindow.show()
        }
        model.openPendingRequest = { id in Task { await environment.approvals.open(requestID: id) } }
        model.dockPreferenceChanged = { [weak self] in self?.updateActivationPolicy() }

        wirePanels(environment, model: model)
        let saver = CaptureSaver(model: model, hud: hud)
        model.saveCapture = { saver.save($0) }
        let capture = CaptureController(model: model, saver: saver)
        self.capture = capture
        model.openCapture = { [weak self] in
            self?.menu?.panel.close("capture box")
            capture.show()
        }
        let hotKey = HotKey { model.openCapture() }
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
        // Review Request (⌃⌥⌘R): the keyboard path to a waiting panel, which never takes focus by
        // itself. The menu bar panel's card that shows the shortcut does the same (WaitingItems).
        let approvals = environment.approvals
        model.reviewRequest = { [weak self] in
            guard let target = model.waiting(now: Date()).reviewTarget else { return }
            // The menu bar panel sits above every panel: it closes first, as a card's Review does.
            self?.menu?.panel.close("review request")
            model.review(target, signIn: { self?.signInPanel?.bringForward() })
        }
        let reviewHotKey = HotKey(id: 2) { model.reviewRequest() }
        reviewHotKey.register(preferences.reviewShortcut)
        self.reviewHotKey = reviewHotKey
        approvals.reviewHint = preferences.reviewShortcut.map { String(localized: "\($0.spoken) to review") }
        model.setReviewShortcut = { [preferences] shortcut in
            guard reviewHotKey.register(shortcut) else {
                reviewHotKey.register(preferences.reviewShortcut)
                return false
            }
            preferences.reviewShortcut = shortcut
            approvals.reviewHint = shortcut.map { String(localized: "\($0.spoken) to review") }
            return true
        }
        NSApp.servicesProvider = capture
        NSUpdateDynamicServices()
        let panelModel = MenuBarPanelModel(app: model, saver: saver)
        panelModel.reviewSignIn = { [weak self] in self?.signInPanel?.bringForward() }
        let menu = StatusMenuController(model: model, panel: MenuBarPanelController(model: panelModel))
        self.menu = menu
        // Updates (FR-G-03): the relaunch waits while a panel is waiting for the user.
        model.relaunchGate = UpdateRelaunchGate(pendingApprovals: { environment.approvals.queue.items.count },
                                                maximumWait: FunesApprovals.panelSeconds + 15)
        let updater = SparkleUpdater()
        // A scheduled check never opens a window: what it found shows in the menu bar. With unsaved
        // edits around, a downloaded update waits for Install Now in the menu bar panel.
        model.askToDiscardDrafts = { [weak self] button in self?.askToDiscardDrafts(button: button) ?? true }
        model.showInstallerBusy = { [weak self] in self?.installerBusy() }
        model.installerLive = { [weak updater] in updater?.installerMayBeRunning ?? false }
        updater.postponeRelaunch = { [weak model] install in model?.postponeRelaunch(install) ?? false }
        model.data.confirmQuit = { [weak model] in model?.confirmAppRelaunch() ?? true }
        updater.aborted = { [weak model] in model?.updateAborted() }
        updater.foundUpdateChanged = { [weak model, weak menu] found in
            model?.foundUpdate = found
            menu?.update()
        }
        updater.start()
        self.updater = updater
        model.updater = updater.controls
        menu.checkForUpdates = { model.updater.checkForUpdates() }
        menu.updatesAvailable = { model.updater.isAvailable() }
        model.data.integrityFailed = { [notifier] in
            notifier.post(.refused, title: String(localized: "The vault needs attention"),
                          body: String(localized: "Its weekly check found a problem. Restore a backup in Settings ▸ Data & Backups."))
        }
        model.data.startJobs()
        // Find the subscription CLIs first, so the processing queue and the tidy-up can use a
        // chosen plan (ADR-0024).
        model.tidyUp.finished = { [notifier] run in
            notifier.post(.tidyUp, title: String(localized: "Tidy-up finished"), body: TidyUpController.notice(run))
        }
        Task { @MainActor in
            // Once the CLIs are found, the queue resumes what a quit left, so a chosen plan can
            // split it; until then a vault change doesn't kick it either. It doesn't wait for the
            // CLIs' checks (up to 15 s each): a call that fails falls back as any failure does.
            await model.modelSettings.locateSubscriptions()
            model.processing.start()
            model.processingStarted = true
            await model.modelSettings.checkSubscriptions()
            model.tidyUp.start()
        }
        model.embeddings.apply()
        model.changed = { [weak menu] in menu?.update() }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var inCallWait = FunesMCPConfiguration.inCallWait
        var callTimeout = FunesMCPConfiguration.toolCallTimeout
        #if DEBUG
        // FUNES_DEBUG_CALL_WAIT=<seconds>: a longer in-call wait (and call timeout), to measure how
        // long an agent waits for a tool call before giving up (Spike 3, task 4b.15). Debug only.
        if let text = ProcessInfo.processInfo.environment["FUNES_DEBUG_CALL_WAIT"], let seconds = Int(text),
           (1...900).contains(seconds) {
            inCallWait = .seconds(seconds)
            callTimeout = TimeInterval(seconds + 10)
        }
        #endif
        let mcp = FunesMCPServer(services: environment.services, presenter: environment.approvals,
                                 dataFolder: environment.dataFolder, version: version, port: preferences.mcpPort,
                                 inCallWait: inCallWait, callTimeout: callTimeout)
        mcp.statusChanged = { [weak model] status in
            model?.mcpStatus = status
            model?.changed()
        }
        self.mcp = mcp
        model.setServer = { [weak self] on in self?.setServer(on) }
        model.setPort = { [weak self] port in self?.setPort(port) }
        model.mcpPort = mcp.port
        model.trafficCounts = { [weak mcp] in mcp?.counters.snapshot ?? MCPTrafficCounters.Snapshot() }
        model.connection = { [weak mcp] id in mcp?.connections[id.db]?.agent }
        wireRemoteAccess(mcp, environment: environment, model: model, menu: menu, version: version)
        model.setupControls = OneClickAgents.live(home: Self.setupHome, appName: "Funes Vault", tag: "funes")
        model.detectAgents = { AgentDetection.installed(.live) }
        Task {
            #if DEBUG
            await DevSeed.runIfAsked(environment)
            #endif
            if preferences.mcpEnabled { mcp.start() }
            await model.refresh()
            // After the agents are read, so the page and menu count them. Always, so the automatic
            // turn-off and the tunnel checks run even if agents can't connect yet; the host starts
            // the listener only while they can (PR #9 review).
            model.remoteAccess.launch()
            // iPhone access is off by default; when it's on, the companion listener starts here (task 5.2).
            model.companion.launch()
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
        reportRestore()
        reportErase()
        #if DEBUG
        // FUNES_DEBUG_OPEN=home|vault|inbox|agents|activity|capture|panel|settings[:destination] opens a window at launch.
        if let open = ProcessInfo.processInfo.environment["FUNES_DEBUG_OPEN"], !open.isEmpty {
            let parts = open.split(separator: ":").map(String.init)
            if parts[0] == "capture" {
                model.openCapture()
            } else if parts[0] == "panel" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { menu.showPanel() }
            } else if parts[0] == "settings" {
                model.openSettings(parts.count > 1 ? SettingsDestination(rawValue: parts[1]) : nil)
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

    /// Calls in progress answer before the listener goes: one waiting for the user gets `funes_quit`
    /// with its request id (mcp-server.md §7). The quit waits for them, 3 seconds at most. The panel
    /// queue closes, so no panel shows after this, even one a call was still building.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unsaved edits live only in memory: a quit asks before dropping them.
        if let model {
            // Edits the user already agreed to discard for an install aren't asked about again;
            // edits to other memories made since are. No install starts while it asks, and a
            // pending one is let go so Sparkle installs at this quit, without relaunching.
            guard model.confirmTermination() else { return .terminateCancel }
        }
        guard let mcp, mcp.callsInProgress > 0 else { return .terminateNow }
        mcp.quit()
        environment?.approvals.queue.close()
        Task {
            let deadline = ContinuousClock.now + .seconds(3)
            while mcp.callsInProgress > 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // The answers are written on the listener's queue just after their handlers return.
            try? await Task.sleep(for: .milliseconds(250))
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Open panels are withdrawn and no more show; the endpoint file goes with the listener.
        environment?.approvals.queue.close()
        mcp?.stop()
        remote?.stop()
        keepAwake.set(false)
    }

    /// The Dock icon: the window as it was while it's open, else on Home.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow?.isVisible == true { mainWindow?.show() } else { model?.showHome() }
        return false
    }

    /// The panels' notices, Edit… and the optional notifications (FR-L-04).
    private func wirePanels(_ environment: VaultEnvironment, model: AppModel) {
        let approvals = environment.approvals
        let preferences = self.preferences
        let notifier = self.notifier
        approvals.notice = { [hud] text in hud.show(text, symbol: "hourglass") }
        approvals.remoteTunnel = { agentID in
            model.remoteServer?.note(agentID: agentID, near: Date())?.tunnel?.name ?? model.remoteAccess.inUseTunnelProvider?.name
        }
        approvals.queue.asideLinkClicked = { item in
            guard let id = UUID(uuidString: item.agentID) else { return }
            model.agentTab = .access
            model.showAgent(id)
        }
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
        model.activityAppended = { [hud] event in
            // The daily cap's notice (ADR-0022): Activity has the row once a day; no text.
            if event.event == "cap_reached", event.actor == "system" {
                hud.show(String(localized: "Today's cloud requests are used up. New captures are classified on this Mac until tomorrow."),
                         symbol: "gauge.with.dots.needle.100percent", seconds: 6)
                return
            }
            guard preferences.notifyRefused, event.outcome == "denied", event.actor.hasPrefix("agent:"),
                  let id = UUID(uuidString: String(event.actor.dropFirst(6))),
                  notifier.noteRefusal(agentID: id, at: event.time) else { return }
            notifier.post(.refused, title: String(localized: "\(model.agentName(id)) was refused repeatedly"),
                          body: String(localized: "More than 5 requests were refused in 10 minutes. See why in Activity."),
                          agentID: id)
        }
        notifier.onOpen = { kind, agent in
            switch kind {
            case .suggestion, .tidyUp: model.show(.inbox)
            case .expired, .refused: model.showActivity(agent.map(ActivityFocus.agent))
            case .tunnelDown: model.show(.remoteAccess)
            }
        }
    }

    /// The MCP server switch (Settings ▸ Agent Server). Remote Access runs only while it's on: the remote
    /// listener is a second door to the same server.
    private func setServer(_ on: Bool) {
        preferences.mcpEnabled = on
        if on {
            mcp?.start()
            model?.remoteAccess.resumeListening()
        } else {
            environment?.approvals.queue.withdrawAll()
            mcp?.stop()
            remote?.stop()
        }
        model?.changed()
    }

    /// Remote Access (ADR-0018): the remote listener on the same pipeline, its OAuth server, the
    /// page's controller, the sign-in panel and the tunnel-down notification.
    private func wireRemoteAccess(_ mcp: FunesMCPServer, environment: VaultEnvironment, model: AppModel,
                                  menu: StatusMenuController, version: String) {
        let remote = FunesRemoteServer(local: mcp, dataFolder: environment.dataFolder, version: version)
        self.remote = remote
        model.remoteServer = remote
        let preferences = self.preferences
        let notifier = self.notifier
        let keepAwake = self.keepAwake
        model.remoteAccess.host = RemoteAccessHost(
            start: { configuration in if preferences.mcpEnabled { remote.start(configuration) } },
            update: { remote.update($0) },
            stop: { remote.stop(); environment.approvals.withdrawRemote() },
            test: { configuration, done in RemoteProbe.test(configuration, nonces: remote.service.nonces, completion: done) },
            portIsFree: { PortProbe.isFree($0) },
            setKeepAwake: { keepAwake.set($0) },
            onACPower: { KeepAwake.onACPower },
            // A Funnel entry to the local MCP port is a mistake ("Wrong port"); any other belongs to
            // another app on this Mac.
            tunnels: .live(mistakenPorts: [preferences.mcpPort, FunesMCPConfiguration.defaultPort]),
            cloudAgents: { [weak model] in model?.remoteCloudAgents() ?? [] },
            mcpPort: { [weak model] in model?.mcpPort ?? FunesMCPConfiguration.defaultPort },
            tunnelDown: { provider in
                notifier.post(.tunnelDown, title: String(localized: "Remote Access's tunnel stopped"),
                              body: String(localized: "\(provider.name) isn't running, so cloud agents can't reach Funes Vault."))
            },
            changed: { [weak model, weak menu] in
                model?.changed()
                menu?.update()
            })
        remote.service.statusChanged = { [weak model] status in model?.remoteAccess.statusDidChange(status) }
        let panel = SignInPanelController(model: model)
        signInPanel = panel
        remote.oauth.pairingRequested = { [weak model] _ in model?.signInsChanged() }
        remote.oauth.pairingChanged = { [weak model] in model?.signInsChanged() }
        model.signInsUpdated = { panel.update() }
        remote.cloudAppsChanged = { [weak model] _ in
            guard let model else { return }
            model.cloudGeneration += 1
            model.remoteAccess.agentsChanged()
            Task { await model.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak model] _ in
            MainActor.assumeIsolated {
                model?.remoteAccess.checkTunnelNow()
                model?.remoteAccess.updateKeepAwake()
            }
        }
    }

    /// Another port (Settings ▸ Agent Server): the listener moves now. Setups that start `funes-mcp` find it
    /// through the endpoint file; setups that name the address need copying again.
    private func setPort(_ port: Int) {
        guard let mcp, FunesMCPConfiguration.portRange.contains(port), port != mcp.port else { return }
        preferences.mcpPort = port
        mcp.port = port
        if preferences.mcpEnabled { mcp.start() }
        model?.mcpPort = port
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
                // Takes back the doorbell records of requests that stopped waiting (ADR-0019).
                await environment.phoneApprovals.sweep()
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

    /// FR-O-03: offered when the app runs from Downloads or a disk image, until Not Now; Agents ▸
    /// Connect offers the move again before setting up an agent.
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
        // Not while an update is installing (it would land in the copy the move trashes); unsaved
        // edits are asked about before the move launches the new copy, and go at the quit.
        if let model, !model.confirmAppRelaunch() { return }
        if case .failed(let problem) = AppMover.move(FunesMacApp.identity, prepareToQuit: { NSApp.terminate(nil) }) {
            let failure = NSAlert()
            failure.messageText = String(localized: "Funes Vault couldn't be moved")
            failure.informativeText = problem
            failure.runModal()
        }
        #endif
    }

    /// One copy at a time on a vault: each copy holds an exclusive lock on `instance.lock` in its
    /// data folder for as long as it runs. A copy that can't take it brings the running one forward
    /// (as reopening it does) and quits before opening anything. A relaunch waits a while longer
    /// for the copy it names to let go. A development vault (Debug on FUNES_DATA_DIR) has its own
    /// folder, so it runs beside the installed app.
    private func handOffToRunningCopy() -> Bool {
        let folder = VaultEnvironment.defaultDataFolder()
        if Self.lockInstance(folder, into: &instanceLock) { return false }
        let arguments = CommandLine.arguments
        if let waitedFor = arguments.firstIndex(of: AppMover.waitForArgument)
            .flatMap({ $0 + 1 < arguments.count ? pid_t(arguments[$0 + 1]) : nil }) {
            let deadline = Date().addingTimeInterval(10)
            while kill(waitedFor, 0) == 0, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                if Self.lockInstance(folder, into: &instanceLock) { return false }
            }
            if Self.lockInstance(folder, into: &instanceLock) { return false }
        }
        logger.notice("Another copy has this vault open; handing over to it")
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Identifiers.macBundleID)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        // The same copy first: another build (a development one) may be running too.
        let running = others.first { $0.bundleURL == Bundle.main.bundleURL } ?? others.first
        if let running, let url = running.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else {
            running?.activate()
            NSApp.terminate(nil)
        }
        return true
    }

    /// The lock's name in the data folder; Erase All Data leaves it.
    static let instanceLockName = "instance.lock"

    /// Takes the data folder's instance lock (kept until the process ends); false while another
    /// process holds it.
    private static func lockInstance(_ folder: URL, into descriptor: inout Int32) -> Bool {
        if descriptor >= 0 { return true }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(folder.appendingPathComponent(instanceLockName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            // Fail open on a folder it can't write: the vault's own open reports the problem.
            logger.error("The instance lock couldn't be opened")
            return true
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    /// Restore, Erase or Move asked for while an update is installing: they wait, since the app
    /// mustn't relaunch itself while Sparkle's installer may replace it.
    private func installerBusy() {
        let alert = NSAlert()
        alert.messageText = String(localized: "An update is installing")
        alert.informativeText = String(localized: "Quit Funes Vault to finish installing it, then open it again and try once more.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// True when no memory has unsaved edits, or the user chose to discard them (FR-V-02): they
    /// aren't kept across a quit or relaunch.
    private func askToDiscardDrafts(button: String) -> Bool {
        guard let vault = model?.vault, !vault.draftIDs.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Discard unsaved changes?")
        alert.informativeText = String(localized: "\(vault.draftIDs.count) memories have changes you haven't saved. Funes Vault doesn't keep them when it quits.")
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// After a relaunch for Erase All Data (FR-G-05): only when something couldn't be deleted.
    private func reportErase() {
        guard DataOperations.eraseIncomplete else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Some data couldn't be erased")
        alert.informativeText = String(localized: "Funes Vault couldn't delete everything in its data folder. Quit Funes Vault and delete what's left in \(VaultEnvironment.defaultDataFolder().path).")
        alert.addButton(withTitle: String(localized: "Show in Finder"))
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([VaultEnvironment.defaultDataFolder()])
        }
    }

    /// After a relaunch for Restore from Backup (FR-G-04): how it went.
    private func reportRestore() {
        switch DataOperations.restoreOutcome {
        case .restored?:
            hud.show(String(localized: "Backup restored"), symbol: "clock.arrow.circlepath", seconds: 4)
        case .failed?:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "The backup couldn't be restored")
            alert.informativeText = String(localized: "Your vault is as it was before. You can try another backup in Settings ▸ Data & Backups.")
            NSApp.activate()
            alert.runModal()
        case nil:
            break
        }
    }

    /// The vault can't open (a newer schema, unsafe permissions): say so in the menu bar.
    private func showOpenFailure(_ error: Error) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image(.off)
        let menu = NSMenu()
        menu.appearance = NSApp.appearance
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
