import BridgeKitCore
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
    var inbox: [Suggestion] = []
    var pending: [PendingRequest] = []
    var categories: [MemoryCategory] = []
    /// The Inbox is waiting on a decision; drives the menu bar's "needs you" state with `pending`.
    var inboxCount: Int { inbox.count }
    /// Updated once a minute, for "2 min ago" and countdowns.
    var now = Date()
    var pausedUntil: Date?
    /// Bumped when Activity gets a row.
    var activityGeneration = 0

    // MARK: Navigation

    var section: AppSection = .vault
    var settingsTab: SettingsTab = .general
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
    @ObservationIgnored var dockPreferenceChanged: () -> Void = {}
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
        pausedUntil = services.pause.pausedUntil(at: Date())
        observation = services.store.observeChanges { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        services.activity.onAppend = { [weak self] in
            Task { @MainActor in
                self?.activityGeneration += 1
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
        let agents = (try? await services.agents.agents()) ?? []
        let inbox = (try? await services.suggestions.pending()) ?? []
        let disclosures = (try? await services.disclosures.pendingRequests(now: now)) ?? []
        let names = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.name) })
        self.agents = agents
        self.inbox = inbox
        pending = disclosures.map {
            PendingRequest(id: $0.id, agentID: $0.agentID, agentName: names[$0.agentID] ?? String(localized: "Removed agent"),
                           status: $0.status, createdAt: $0.createdAt)
        }
        categories = (try? services.store.categories()) ?? []
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
