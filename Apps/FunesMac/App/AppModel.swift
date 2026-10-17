import BridgeKitCore
import BridgeUI
import Foundation
import FunesCore
import FunesProtocol
import Observation

/// A request waiting for the user, as the menu and Pending requests show it.
struct PendingRequest: Identifiable, Equatable {
    let id: UUID
    let agentID: UUID
    let agentName: String
    let status: DisclosureStatus
    let createdAt: Date
    var expiresAt: Date { createdAt + DisclosureService.window }

    func minutesLeft(at now: Date) -> Int { max(0, Int((expiresAt.timeIntervalSince(now) / 60).rounded(.up))) }
}

/// The main window's sections (04-ux-mac.md).
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case vault, inbox, agents, activity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .vault: String(localized: "Vault")
        case .inbox: String(localized: "Inbox")
        case .agents: String(localized: "Agents")
        case .activity: String(localized: "Activity")
        }
    }

    var symbol: String {
        switch self {
        case .vault: "archivebox"
        case .inbox: "tray"
        case .agents: "person.2"
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

    let vault: VaultModel
    let inboxState: InboxModel
    let activity: ActivityModel
    let checklist: ChecklistModel
    let modelSettings: ModelSettings
    let data: DataOperations
    /// Sparkle, or a stand-in where this build can't update itself.
    @ObservationIgnored var updater = UpdaterControls.unavailable
    /// MCP traffic counts since launch (Settings ▸ MCP).
    @ObservationIgnored var trafficCounts: () -> MCPTrafficCounters.Snapshot = { MCPTrafficCounters.Snapshot() }

    // MARK: Navigation

    var section: AppSection = .vault
    var settingsTab: SettingsTab = .general
    var agentTab: AgentTab = .access
    /// Add Agent… from the setup checklist.
    var addAgentRequest = 0
    var selectedMemoryID: UUID?
    var selectedAgentID: UUID?
    var selectedSuggestionIDs = Set<UUID>()
    /// Activity filtered to one memory (from "Shared 4 times") or one agent.
    var activityFocus: ActivityFocus?
    /// The main window asks to open or close; the controller acts on it.
    var windowRequest = 0

    @ObservationIgnored var openMainWindow: () -> Void = {}
    @ObservationIgnored var openSettings: (SettingsTab?) -> Void = { _ in }
    @ObservationIgnored var openCapture: () -> Void = {}
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
    /// Turns the MCP server on or off (Settings ▸ MCP).
    @ObservationIgnored var setServer: (Bool) -> Void = { _ in }
    /// Turns a notification kind on, asking macOS for permission the first time.
    @ObservationIgnored var requestNotificationPermission: (@escaping @MainActor (Bool) -> Void) -> Void = { $0(false) }
    /// ⌘N and ⌘F from the main menu, for the Vault.
    var newMemoryRequest = 0
    var searchFocusRequest = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var observation: AnyObject?
    @ObservationIgnored private var refreshPending = false

    init(services: VaultEnvironment, preferences: Preferences) {
        self.services = services
        self.preferences = preferences
        vault = VaultModel(services: services)
        inboxState = InboxModel(services: services)
        activity = ActivityModel(services: services)
        checklist = ChecklistModel(preferences: preferences)
        modelSettings = ModelSettings(defaults: preferences.defaults, keys: ModelSettings.keychain())
        data = DataOperations(environment: services, preferences: preferences)
        pausedUntil = services.pause.pausedUntil(at: Date())
        observation = services.store.observeChanges { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        services.activity.onAppend = { [weak self] event in
            Task { @MainActor in
                self?.activityGeneration += 1
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
        case .failed: return .paused
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
                           status: $0.status, createdAt: $0.createdAt)
        }
        categories = (try? services.store.categories()) ?? []
        hasMemories = !((try? services.store.memories(MemoryFilter(status: .activeIncludingExpired), now: now, limit: 1)) ?? []).isEmpty
        dataGeneration += 1
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

    func setNotification(_ key: String, _ on: Bool) {
        preferences.set(key, on)
        if on { requestNotificationPermission { _ in } }
    }

    // MARK: Lookups

    func agent(_ id: UUID?) -> Agent? { id.flatMap { id in agents.first { $0.id == id } } }

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

    func showMemory(_ id: UUID) {
        selectedMemoryID = id
        show(.vault)
    }

    func showAgent(_ id: UUID) {
        selectedAgentID = id
        show(.agents)
    }

    func showActivity(_ focus: ActivityFocus?) {
        activityFocus = focus
        show(.activity)
    }
}

/// What Activity is narrowed to when opened from elsewhere.
enum ActivityFocus: Equatable {
    case memory(UUID)
    case agent(UUID)
    case request(UUID)
}
