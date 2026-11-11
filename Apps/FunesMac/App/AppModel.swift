import BridgeKitCore
import BridgeKitRemote
import BridgeUI
import Foundation
import FunesCore
import FunesMCP
import FunesProtocol
import Observation

/// A request waiting for the user, as the menu and Pending requests show it.
struct PendingRequest: Identifiable, Equatable {
    let id: UUID
    let agentID: UUID
    let agentName: String
    let status: DisclosureStatus
    let createdAt: Date
    /// How many memories it would share, from its snapshot.
    var memoryCount = 0
    /// The task, while this session still holds it (it's never stored).
    var task: String?
    var expiresAt: Date { createdAt + DisclosureService.window }

    func minutesLeft(at now: Date) -> Int { max(0, Int((expiresAt.timeIntervalSince(now) / 60).rounded(.up))) }

    /// "3 memories · 13 min left" (UX review F12).
    func summary(at now: Date) -> String {
        let memories = memoryCount == 1 ? String(localized: "1 memory") : String(localized: "\(memoryCount) memories")
        return status == .approved ? String(localized: "\(memories) · approved, waiting for the agent")
                                   : String(localized: "\(memories) · \(minutesLeft(at: now)) min left")
    }
}

/// The main window's sections (04-ux-mac.md), in the View menu's order (⌘1–⌘6). Agents shows
/// the agent selected in the sidebar's Agents list.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home, vault, inbox, activity, agents, remoteAccess
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .vault: String(localized: "Vault")
        case .inbox: String(localized: "Inbox")
        case .agents: String(localized: "Agents")
        case .remoteAccess: String(localized: "Remote Access")
        case .activity: String(localized: "Activity")
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .vault: "archivebox"
        case .inbox: "tray"
        case .agents: "person.2"
        case .remoteAccess: "globe"
        case .activity: "list.bullet.rectangle"
        }
    }
}

/// What the menu bar, the main window and Settings show, on the main actor. Reads come from
/// FunesCore's services; `refresh()` runs after every vault change (`VaultStore.observeChanges`)
/// and every Activity row, debounced.
@MainActor @Observable
final class AppModel {
    let services: VaultEnvironment
    let preferences: Preferences

    // MARK: State shown everywhere

    var mcpStatus: MCPService.Status = .off
    var agents: [Agent] = []
    /// Removed agents too, for labels in Activity and history ("removed agent").
    var allAgents: [Agent] = []
    var inbox: [Suggestion] = []
    var pending: [PendingRequest] = []
    var categories: [MemoryCategory] = []
    /// About you (ADR-0026): Home's greeting, the access editor's values, About You's pane.
    var profile = Profile()
    /// Whether the vault has any active memory (the checklist and empty states).
    var hasMemories = false
    /// The Inbox is waiting on a decision; drives the menu bar's "needs you" state with `pending`.
    var inboxCount: Int { inbox.count }
    /// Updated once a minute, for "2 min ago" and countdowns.
    var now = Date()
    var pausedUntil: Date?
    /// Bumped when Activity gets a row.
    var activityGeneration = 0
    /// Bumped after every vault change, so open screens reload.
    var dataGeneration = 0
    /// Bumped only when the vault's database changed (not for an Activity row alone): the Vault's
    /// list and detail reload on it.
    var memoriesGeneration = 0

    let vault: VaultModel
    /// Search answers with the user's settings (FR-AI-17): the Vault's Ask, and the iPhone's.
    let searchAnswers: SearchAnswersController
    /// Home's pulse and cards (FR-H-02).
    let home: HomeModel
    /// Home's composer: the capture box's model, saved the same way.
    let composer = CaptureBoxModel()
    let inboxState: InboxModel
    let activity: ActivityModel
    let checklist: ChecklistModel
    let modelSettings: ModelSettings
    /// The provider embedding model's index (ADR-0023, task 6c.3).
    let embeddings: EmbeddingController
    let data: DataOperations
    /// Classification (and from 6a, splitting) of everything that arrives, in the background.
    let processing: ProcessingRunner
    /// The daily tidy-up: its schedule, Tidy Up Now and the last run (memory processing §9).
    let tidyUp: TidyUpController
    /// Remote Access (ADR-0018): its settings, guide and tunnel checks. The app delegate gives it
    /// the listener through its host.
    let remoteAccess: RemoteAccessController
    /// Settings ▸ iPhone: iPhone access, pairing and paired devices (task 5.2).
    let companion: CompanionController
    /// The remote listener and OAuth server, while the app runs.
    @ObservationIgnored var remoteServer: FunesRemoteServer?
    /// Bumped when connected cloud apps or pairing change, so views re-read them.
    var cloudGeneration = 0
    /// Sign-ins waiting for the user, oldest first (the sign-in panel shows the first).
    var signIns: [PairingRequest] = []
    @ObservationIgnored var signInsUpdated: () -> Void = {}
    /// The Cloud tab's last result ("Remote token copied…"), said once.
    var cloudMessage: String?
    /// Sparkle, or a stand-in where this build can't update itself.
    @ObservationIgnored var updater = UpdaterControls.unavailable
    /// An update a scheduled check found (Sparkle's gentle reminders), until the user opens it:
    /// the menu bar panel, the status menu and the icon's tooltip show it (FR-G-03).
    var foundUpdate: FoundUpdate?
    /// An update is downloaded and ready, held because memories have unsaved edits: the menu bar
    /// panel says so and offers Install Now (FR-V-02, FR-G-03).
    private(set) var updateHeld = false
    /// Sparkle's install handler for that update, until it's let go or dropped by a quit.
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    /// A quit's alert is up: the approvals' wait doesn't start an install meanwhile.
    @ObservationIgnored private var quitting = false
    /// Waits for approval panels before a relaunch (set by the app).
    @ObservationIgnored var relaunchGate: UpdateRelaunchGate?
    /// Whether Sparkle's installer may be running (from an update's download, or one resumed at
    /// its installing stage, until the app quits; set by the app). While it is, the app never relaunches itself: Autoupdate quits every copy
    /// of the app and replaces the bundle when this one exits.
    @ObservationIgnored var installerLive: () -> Bool = { false }
    /// The edits a Restore, Erase, Move or Install Now just asked about, as they were then, and
    /// until when that answer holds: the quit that follows doesn't ask about them again, unless
    /// they changed since (it asks about those, and about any others).
    @ObservationIgnored private var askedForQuit: (drafts: [UUID: VaultModel.Draft], until: Date, forInstall: Bool)?
    private var askedDrafts: [UUID: VaultModel.Draft] {
        Dictionary(uniqueKeysWithValues: vault.draftIDs.compactMap { id in vault.draft(id).map { (id, $0) } })
    }
    /// What a Restore, Erase or Move that asked is about to do by quitting.
    enum AppRelaunch { case dataChange, move }
    /// Tells the user an update is installing, so Restore, Erase or Move must wait (set by the app).
    @ObservationIgnored var showInstallerBusy: () -> Void = {}
    /// Tells the user a Restore, Erase or Move didn't finish because its quit was cancelled (set by
    /// the app).
    @ObservationIgnored var showRelaunchUnfinished: (AppRelaunch) -> Void = { _ in }
    /// A Restore, Erase or Move has asked and is about to quit the app.
    @ObservationIgnored private var relaunchRequested: AppRelaunch?
    /// Asks before unsaved edits are dropped, with this button ("Discard and Quit"); true when
    /// there are none or the user agreed. Discards nothing itself (set by the app).
    @ObservationIgnored var askToDiscardDrafts: (_ button: String) -> Bool = { _ in true }
    /// MCP traffic counts since launch (Settings ▸ Agent Server).
    @ObservationIgnored var trafficCounts: () -> MCPTrafficCounters.Snapshot = { MCPTrafficCounters.Snapshot() }

    // MARK: Navigation

    /// A pane chosen in the sidebar: its top level.
    func showSettingsPane(_ pane: SettingsPane) {
        settingsPath = []
        settingsPane = pane
    }

    /// Settings at a destination, or at the last pane's top level (ADR-0030 §1, §9). An account
    /// that no longer exists opens Models & Accounts.
    func goToSettings(_ destination: SettingsDestination?) {
        guard let destination else { settingsPath = []; return }
        settingsPane = destination.pane
        switch destination.page {
        case let .account(id)? where !modelSettings.hasAccount(id): settingsPath = []
        case let page?: settingsPath = [page]
        case nil: settingsPath = []
        }
    }

    /// The main window opens on Home (FR-H-02).
    var section: AppSection = .home
    /// The Settings pane shown: the last one this session, General the first time (ADR-0030 §1).
    var settingsPane: SettingsPane = .general
    /// The pages open inside it; empty at its top level.
    var settingsPath: [SettingsPage] = []
    var agentTab: AgentTab = .access
    /// Open the Add Agent sheet: the sidebar's +, the checklist's Add… and the empty Agents page set it.
    var wantsAddAgent = false
    /// An agent just added with Add and Connect…: its Connect tab starts one-click setup.
    var pendingOneClick: UUID?
    var selectedMemoryID: UUID?
    var selectedAgentID: UUID?
    var selectedSuggestionIDs = Set<UUID>()
    /// Activity filtered to one memory (from "Shared 4 times") or one agent.
    var activityFocus: ActivityFocus?
    /// The main window asks to open or close; the controller acts on it.
    var windowRequest = 0

    @ObservationIgnored var openMainWindow: () -> Void = {}
    @ObservationIgnored var openSettings: (SettingsDestination?) -> Void = { _ in }
    @ObservationIgnored var openCapture: () -> Void = {}
    /// Saves a box's text as a capture (CaptureSaver); true when it was taken.
    @ObservationIgnored var saveCapture: (CaptureBoxModel) -> Bool = { _ in false }
    @ObservationIgnored var openPendingRequest: (UUID) -> Void = { _ in }
    @ObservationIgnored var changed: () -> Void = {}
    /// Each Activity row as it's written (for the "refused repeatedly" notification).
    @ObservationIgnored var activityAppended: (ActivityEvent) -> Void = { _ in }
    @ObservationIgnored var dockPreferenceChanged: () -> Void = {}
    /// One-click setup (live, or fakes in the UI-review build).
    @ObservationIgnored var setupControls = AgentSetupControls(
        preview: { _, _, done in done(.failure(OneClickFailure(message: String(localized: "One-click setup isn't available.")))) },
        apply: { _, done in done(.failure(OneClickFailure(message: String(localized: "One-click setup isn't available.")))) },
        restart: { _, done in done(false) })
    /// Agents installed on this Mac, for Add Agent's tiles.
    @ObservationIgnored var detectAgents: () -> Set<SetupAgent> = { [] }
    /// The last MCP connection per agent id ("Claude Code 2.1"), from the server.
    @ObservationIgnored var connection: (UUID) -> String? = { _ in nil }
    /// The port the MCP server listens on, or is configured for.
    var mcpPort: Int = 47_625
    /// Registers a new capture shortcut; false when another app has it.
    @ObservationIgnored var setCaptureShortcut: (Shortcut?) -> Bool = { _ in false }
    /// Registers a new Review Request shortcut; false when another app has it.
    @ObservationIgnored var setReviewShortcut: (Shortcut?) -> Bool = { _ in false }
    /// Brings the waiting panel forward and makes it key, or opens the newest pending request.
    @ObservationIgnored var reviewRequest: () -> Void = {}
    /// Turns the MCP server on or off (Settings ▸ Agent Server).
    @ObservationIgnored var setServer: (Bool) -> Void = { _ in }
    /// Moves the MCP server to another port (Settings ▸ Agent Server).
    @ObservationIgnored var setPort: (Int) -> Void = { _ in }
    /// Turns a notification kind on, asking macOS for permission the first time.
    @ObservationIgnored var requestNotificationPermission: (@escaping @MainActor (Bool) -> Void) -> Void = { $0(false) }
    /// ⌘N and ⌘F from the main menu, for the Vault.
    var newMemoryRequest = 0
    var searchFocusRequest = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var observation: AnyObject?
    @ObservationIgnored private var refreshPending = false
    /// The database changed since the last refresh.
    @ObservationIgnored private var storeChanged = true
    /// The processing queue started (after the subscription CLIs were found): until then a vault
    /// change doesn't kick it, so a job that should split on a plan model never runs without it.
    @ObservationIgnored var processingStarted = false

    init(services: VaultEnvironment, preferences: Preferences, modelSettings: ModelSettings? = nil) {
        self.services = services
        self.preferences = preferences
        vault = VaultModel(services: services)
        home = HomeModel(services: services, defaults: preferences.defaults)
        inboxState = InboxModel(services: services)
        activity = ActivityModel(services: services)
        checklist = ChecklistModel(preferences: preferences)
        self.modelSettings = modelSettings ?? ModelSettings(defaults: preferences.defaults, keys: ModelSettings.keychain())
        data = DataOperations(environment: services, preferences: preferences)
        processing = ProcessingRunner(environment: services, preferences: preferences, settings: self.modelSettings)
        tidyUp = TidyUpController(environment: services, preferences: preferences, settings: self.modelSettings)
        searchAnswers = SearchAnswersController(environment: services, settings: self.modelSettings)
        embeddings = EmbeddingController(environment: services, settings: self.modelSettings)
        remoteAccess = RemoteAccessController(defaults: preferences.defaults, appName: "Funes Vault", names: .funes,
                                              defaultPort: FunesRemoteConfiguration.defaultPort, host: .inert)
        var companionServices = services.companionServices
        companionServices.answers = searchAnswers
        companion = CompanionController(defaults: preferences.defaults, services: companionServices,
                                        approvals: services.phoneApprovals, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        pausedUntil = services.pause.pausedUntil(at: Date())
        inboxState.categories = { [weak self] in self?.categories ?? [] }
        inboxState.decided = { [weak self] in self?.checklist.markReviewed() }
        vault.answers = searchAnswers
        self.modelSettings.embeddingInputsChanged = { [weak self] in self?.embeddings.apply() }
        composer.save = { [weak self, composer] _ in self?.saveCapture(composer) ?? false }
        composer.search = { [weak self] text in self?.showVault(query: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        observation = services.store.observeChanges { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.storeChanged = true
                self.scheduleRefresh()
                if self.processingStarted { self.processing.kick() }
            }
        }
        services.activity.onAppend = { [weak self] event in
            Task { @MainActor in
                self?.activityGeneration += 1
                // A suggestion the user decided reviews the Inbox (the setup checklist): in a Save
                // panel or the Inbox on this Mac (actor `user`), or on the iPhone as the owner
                // (`device:`). Only those decide through apply/reject; automatic changes and the
                // tidy-up record their own events as `system`.
                if ["suggestion_applied", "suggestion_rejected"].contains(event.event),
                   event.actor == "user" || event.actor.hasPrefix("device:") {
                    self?.checklist.markReviewed()
                }
                self?.activityAppended(event)
                self?.scheduleRefresh()
            }
        }
    }

    var isPaused: Bool { services.pause.isPaused(at: Date()) }

    /// The menu bar icon's state (04-ux-mac.md).
    var iconState: MenuBarIcon.State {
        if !preferences.mcpEnabled { return .off }
        if isPaused { return .paused }
        switch mcpStatus {
        case .off, .starting: return .off
        case .failed: return .cantConnect
        case .listening: return pending.isEmpty && inbox.isEmpty ? .normal : .needsYou
        }
    }

    // MARK: Refresh

    /// Coalesces bursts of changes (an import, a bulk apply) into one read.
    func scheduleRefresh() {
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            await self?.refresh()
            guard let self else { return }
            self.refreshTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.scheduleRefresh()
            }
        }
    }

    func refresh() async {
        // Taken first: a change that arrives while this reads schedules another refresh.
        let storeDidChange = storeChanged
        storeChanged = false
        let now = Date()
        self.now = now
        pausedUntil = services.pause.pausedUntil(at: now)
        let all = (try? await services.agents.agents(includingRemoved: true)) ?? []
        let agents = all.filter { !$0.isRemoved }
        let inbox = (try? await services.suggestions.pending()) ?? []
        let disclosures = (try? await services.disclosures.pendingRequests(now: now)) ?? []
        let names = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.name) })
        self.agents = agents
        allAgents = all
        self.inbox = inbox
        pending = disclosures.map {
            PendingRequest(id: $0.id, agentID: $0.agentID, agentName: names[$0.agentID] ?? String(localized: "Removed agent"),
                           status: $0.status, createdAt: $0.createdAt, memoryCount: $0.candidateSnapshot.count,
                           task: services.approvals.sessionTask($0.id))
        }
        categories = (try? services.store.categories()) ?? []
        profile = (try? services.store.profile()) ?? Profile()
        hasMemories = !((try? services.store.memories(MemoryFilter(status: .activeIncludingExpired), now: now, limit: 1)) ?? []).isEmpty
        dataGeneration += 1
        if storeDidChange {
            memoriesGeneration += 1
            pruneDrafts()
        }
        checklist.update(model: self)
        changed()
    }

    func tick() {
        now = Date()
        let paused = services.pause.pausedUntil(at: now)
        if paused != pausedUntil {
            pausedUntil = paused
            if paused == nil { preferences.pausedUntil = nil }
        }
        pending.removeAll { $0.expiresAt <= now }
        changed()
    }

    // MARK: Unsaved edits and quitting (FR-V-02)

    // Updates and unsaved edits (FR-V-02): edits are asked about in one place, the quit. An update
    // with edits around is held (the panel offers Install Now); without, it waits only for the
    // approvals. A quit the user asks for never relaunches: the held install is dropped and
    // Sparkle installs at that quit. While Sparkle's installer may be running, Restore, Erase and
    // Move aren't started, so the app never relaunches itself under it.

    /// Sparkle's `shouldPostponeRelaunchForUpdate`: false relaunches now; true keeps `install`
    /// for later (held for edits, or the approvals' wait).
    func postponeRelaunch(_ install: @escaping () -> Void) -> Bool {
        pendingInstall = install
        return !installIfFree(sparkleRelaunches: true)
    }

    /// Lets the update go if nothing holds it; true when it did. With `sparkleRelaunches`, Sparkle
    /// relaunches itself (its delegate returned false), so `install` isn't called here.
    @discardableResult
    private func installIfFree(sparkleRelaunches: Bool = false, approvalsWaited: Bool = false,
                               ignoringDrafts: Bool = false) -> Bool {
        guard let install = pendingInstall, !quitting else { return false }
        updateHeld = !ignoringDrafts && !vault.draftIDs.isEmpty
        guard !updateHeld else { return false }
        if let gate = relaunchGate, !approvalsWaited {
            if gate.isWaiting { return false }
            if gate.postpone({ [weak self] in self?.installIfFree(approvalsWaited: true, ignoringDrafts: ignoringDrafts) }) {
                return false
            }
        }
        pendingInstall = nil
        // Install Now's answer holds only for the quit this install brings, right away.
        if ignoringDrafts { askedForQuit?.until = Date().addingTimeInterval(10) }
        if !sparkleRelaunches { install() }
        return true
    }

    /// The menu bar panel's Install Now: asks about unsaved edits ("Discard and Install") and lets
    /// the update go (after any approvals' wait); the edits go at the quit it brings.
    func installHeldUpdate() {
        guard pendingInstall != nil, askToDiscardDrafts(String(localized: "Discard and Install")) else { return }
        // The alert's run loop can deliver an abort; re-check. The edits go at the quit the install
        // brings, which doesn't ask about them again; if it never comes, they're kept.
        guard pendingInstall != nil else { return }
        // Held through the approvals' wait (up to the gate's maximum), then 10 s from the install.
        askedForQuit = (askedDrafts, Date().addingTimeInterval(90), true)
        updateHeld = false
        // An approvals' wait started earlier carries the old rule (hold for edits): start it again.
        relaunchGate?.cancel()
        installIfFree(ignoringDrafts: true)
    }

    /// Sparkle ended the update with an error: nothing is held any more.
    func updateAborted() {
        // Only Install Now's answer depended on the update; a Restore's, Erase's or Move's stands.
        if askedForQuit?.forInstall == true { askedForQuit = nil }
        pendingInstall = nil
        updateHeld = false
        relaunchGate?.cancel()
    }

    /// `applicationShouldTerminate`: asks about unsaved edits (except ones a Restore, Erase, Move or
    /// Install Now just asked about, unchanged since), with no install starting while it asks. True: the quit
    /// goes on; the edits are dropped and a held install is let go so Sparkle installs at this quit
    /// without relaunching.
    func confirmTermination() -> Bool {
        quitting = true
        let asked = askedForQuit.flatMap { Date() < $0.until ? $0.drafts : nil } ?? [:]
        askedForQuit = nil
        let answered = vault.draftIDs.allSatisfy { id in asked[id].map { $0 == vault.draft(id) } ?? false }
        guard answered || askToDiscardDrafts(String(localized: "Discard and Quit")) else {
            quitting = false
            if let relaunch = relaunchRequested {
                relaunchRequested = nil
                showRelaunchUnfinished(relaunch)
            }
            // An install held while the alert was up shows again (Install Now), or goes if free.
            installIfFree()
            return false
        }
        quitting = false
        relaunchRequested = nil
        pendingInstall = nil
        updateHeld = false
        relaunchGate?.cancel()
        vault.discardDrafts()
        return true
    }

    /// Before Restore, Erase All Data or Move to Applications relaunch the app: refused while
    /// Sparkle's installer may be running (`showInstallerBusy` says so), then asks about
    /// unsaved edits. True: go on; the quit that follows won't ask about these edits again (and
    /// drops them then, not before, so a move whose copy never opens loses nothing).
    func confirmAppRelaunch(_ relaunch: AppRelaunch) -> Bool {
        if installerLive() || pendingInstall != nil {
            showInstallerBusy()
            return false
        }
        guard askToDiscardDrafts(String(localized: "Discard and Quit")) else { return false }
        // The alert's run loop can deliver an extraction or an install; check again.
        if installerLive() || pendingInstall != nil {
            showInstallerBusy()
            return false
        }
        askedForQuit = (askedDrafts, Date().addingTimeInterval(60), false)
        relaunchRequested = relaunch
        return true
    }

    /// The Restore, Erase or Move didn't start after all (its marker couldn't be written, the move
    /// failed, or the moved copy didn't open): the edits it asked about are asked about again.
    func appRelaunchCalledOff() {
        askedForQuit = nil
        relaunchRequested = nil
    }

    /// Drafts of memories that are gone (purged here or elsewhere) can't be saved or reverted:
    /// they go, so they never hold a quit or an update.
    private func pruneDrafts() {
        let ids = vault.draftIDs
        guard !ids.isEmpty, let found = try? services.store.memories(ids: Array(ids)) else { return }
        let alive = Set(found.map(\.id))
        for id in ids where !alive.contains(id) { vault.setDraft(nil, for: id) }
    }

    // MARK: Pause (FR-A-11)

    func pause(_ duration: FunesPause.Duration) {
        let until = duration.end(from: Date())
        services.pause.pause(until: until)
        preferences.pausedUntil = until
        pausedUntil = until
        services.approvals.queue.withdrawAll()
        services.activity.record(ActivityEvent(time: Date(), phase: .event, actor: .user, via: .app, event: "funes_paused"))
        changed()
    }

    func resume() {
        services.pause.resume()
        preferences.pausedUntil = nil
        pausedUntil = nil
        services.activity.record(ActivityEvent(time: Date(), phase: .event, actor: .user, via: .app, event: "funes_resumed"))
        changed()
    }

    /// The Cloud chip under a capture field: who proposes the fields of what's typed there.
    func updateCloudChip(_ box: CaptureBoxModel) {
        guard preferences.classifyCaptures else {
            box.cloudProvider = nil
            return
        }
        let settings = modelSettings
        Task { box.cloudProvider = await settings.cloudClassifierName() }
    }

    func setNotification(_ key: String, _ on: Bool) {
        preferences.set(key, on)
        if on { requestNotificationPermission { _ in } }
    }

    // MARK: Lookups

    func agent(_ id: UUID?) -> Agent? { id.flatMap { id in agents.first { $0.id == id } } }

    /// The agent's requests waiting for you (its badge in the sidebar).
    func pendingCount(_ agentID: UUID) -> Int { pending.filter { $0.agentID == agentID }.count }

    /// An agent's name; "Removed agent" once it's gone.
    func agentName(_ id: UUID) -> String {
        guard let agent = allAgents.first(where: { $0.id == id }) else { return String(localized: "an agent") }
        return agent.isRemoved ? String(localized: "Removed agent (\(agent.name))") : agent.name
    }

    /// A model provider's name for Inbox cards ("via Anthropic").
    func providerName(_ id: String) -> String? {
        switch id {
        case "anthropic": "Anthropic"
        case "openai": "OpenAI"
        case "ollama": "Ollama"
        case "lmstudio": "LM Studio"
        default: nil
        }
    }

    /// "0.0.1 (1)".
    var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// funes-mcp inside the app bundle.
    var launcherPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(Identifiers.mcpLauncherName)").path
    }

    static var launcherLink: String { NSHomeDirectory() + "/.local/bin/" + Identifiers.mcpLauncherName }

    /// Whether ~/.local/bin/funes-mcp points at this app's launcher (mcp-server.md §1).
    var launcherLinked: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: Self.launcherLink)) == launcherPath
    }

    /// Adds or removes the symlink; returns what happened. Never replaces a file that isn't our link.
    func setLauncherLink(_ on: Bool) -> String {
        let manager = FileManager.default
        let link = Self.launcherLink
        let existing = try? manager.destinationOfSymbolicLink(atPath: link)
        if on {
            if manager.fileExists(atPath: link) || existing != nil {
                guard existing?.hasSuffix("/Contents/MacOS/\(Identifiers.mcpLauncherName)") == true else {
                    return String(localized: "Something else is already at ~/.local/bin/funes-mcp, so it was left alone.")
                }
                try? manager.removeItem(atPath: link)
            }
            do {
                try manager.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try manager.createSymbolicLink(atPath: link, withDestinationPath: launcherPath)
                return String(localized: "Linked. Make sure ~/.local/bin is on your PATH.")
            } catch {
                return String(localized: "The link couldn't be made.")
            }
        }
        guard existing == launcherPath else { return String(localized: "There's no link to remove.") }
        try? manager.removeItem(atPath: link)
        return String(localized: "Removed.")
    }

    /// What an agent's last MCP connection said it was ("claude-code 2.1").
    func clientName(_ id: UUID) -> String? { connection(id) }

    let setupNames = SetupNames(appName: "Funes Vault", agentOption: "agent", secretNoun: String(localized: "key"),
                                copySecretAction: String(localized: "Copy Key…"), environmentVariable: "FUNES_MCP_KEY")

    /// The values an agent's setup needs: the MCP URL, the launcher inside the app, its id and key file.
    func setupContext(for agent: Agent) -> SetupContext {
        let launcher = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(Identifiers.mcpLauncherName)").path
        let keyPath = services.keys.url(agentID: agent.id)?.path
            ?? services.dataFolder.appendingPathComponent("agent-keys/\(agent.id.db).key").path
        return SetupContext(serverKey: Identifiers.mcpServerKey, url: "http://127.0.0.1:\(mcpPort)/mcp", launcherPath: launcher,
                            agentID: agent.id.db, keyPath: keyPath, names: setupNames)
    }

    func categoryName(_ key: String) -> String { categories.first { $0.key == key }?.name ?? key }

    func show(_ section: AppSection) {
        self.section = section
        openMainWindow()
    }

    /// "Show this memory": the Vault on that memory, whatever its status or the filters.
    func showMemory(_ id: UUID) {
        vault.reveal(id)
        show(.vault)
    }

    func showAgent(_ id: UUID) {
        selectedAgentID = id
        show(.agents)
    }

    /// A History row's Show in Activity: this memory's Activity, with the row for that moment selected.
    func showActivity(memoryID: UUID, near time: Date) {
        activity.kind = .all
        activity.period = .all
        activity.select(memoryID: memoryID, near: time)
        showActivity(.memory(memoryID))
    }

    /// Activity narrowed to `focus`, showing `kind` (Home's chart opens Problems for a refused dot).
    func showActivity(_ focus: ActivityFocus?, kind: ActivityEntry.Kind? = nil) {
        activityFocus = focus
        if let kind { activity.kind = kind }
        if case .period = focus { activity.period = .all }
        show(.activity)
    }

    /// The main window on Home: Open Funes Vault, and reopening the app with the window closed.
    func showHome() { show(.home) }

    /// The Vault with these filters and nothing else, newest first or as it was (Home's cards).
    func showVault(query: String = "", sensitivities: Set<Sensitivity> = [], newestFirst: Bool = false) {
        vault.clearFilters()
        vault.status = .active
        vault.sensitivities = sensitivities
        vault.query = query
        if newestFirst { vault.sort = .created }
        selectedMemoryID = nil
        show(.vault)
    }
}

/// What Activity is narrowed to when opened from elsewhere.
enum ActivityFocus: Equatable {
    case memory(UUID)
    case agent(UUID)
    case request(UUID)
    /// A day, week or month of Home's chart, or an hour of the menu bar panel's.
    case period(DateInterval)
}
