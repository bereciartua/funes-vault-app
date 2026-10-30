import BridgeUI
import Foundation
import FunesCore
import FunesProtocol
import Observation

/// A search result in the menu bar panel: the title, the first category and the sensitivity,
/// never the body.
struct PanelSearchRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let category: String?
    let sensitivity: Sensitivity
}

/// A search answer with what the card shows beside it, as it was when asked.
struct PanelSearchAnswer: Equatable, Sendable {
    let answer: SearchAnswer
    let results: Int
    let engine: String
    let limit: String
}

/// The menu bar panel's state (ADR-0029, 04-ux-mac.md ▸ Menu bar): what waits, the two tiles,
/// the field and the last 24 hours. Built once; the panel reads it each time it opens. It holds no
/// memory text or title until the user searches (FR-G-01).
@MainActor @Observable
final class MenuBarPanelModel {
    let app: AppModel
    let field = PanelField<PanelSearchRow, PanelSearchAnswer>()
    /// The last 24 hours; nil until read.
    private(set) var pulse: RecentPulse?
    /// Ticks each second while the panel shows, for the countdowns.
    private(set) var now = Date()
    /// Bumped each time the panel opens, so the field takes the focus.
    private(set) var focusRequest = 0
    /// The tallest the panel may be: the screen's visible area under the icon.
    var maxHeight: CGFloat = 720
    /// Where the Agents switch and the footer's ⋯ are, in the panel's content (top-down), for
    /// their menus.
    @ObservationIgnored var pauseMenuAnchor = CGRect.zero
    @ObservationIgnored var moreMenuAnchor = CGRect.zero
    /// The Cloud chip under the field: who proposes a capture's fields, or nil on this Mac.
    let chip = CaptureBoxModel()

    /// Closes the panel (set by its controller).
    @ObservationIgnored var closePanel: () -> Void = {}
    /// Shows the pause lengths from the Agents switch.
    @ObservationIgnored var showPauseMenu: () -> Void = {}
    /// Remote Access's own question, then on.
    @ObservationIgnored var confirmRemoteOn: () -> Void = {}
    /// Dictation is asking for access: the panel stays open meanwhile.
    @ObservationIgnored var holdOpen: (Bool) -> Void = { _ in }
    /// A cloud sign-in's panel, forward and key.
    @ObservationIgnored var reviewSignIn: () -> Void = {}
    @ObservationIgnored private var pulseTask: Task<Void, Never>?
    /// The vault change the chart was read after.
    @ObservationIgnored private var chartGeneration = -1

    init(app: AppModel, saver: CaptureSaver) {
        self.app = app
        let services = app.services
        let answers = app.searchAnswers
        field.validate = { saver.validate($0) }
        field.store = { await saver.store($0) }
        field.search = { [weak app] query in
            // The Vault's search with the Active scope and no filters, as many rows as an answer reads.
            let hits = try await services.search.vaultSearch(query, filter: MemoryFilter(status: .active), now: Date())
            let ids = hits.prefix(SearchAnswerer.memoryCount).map(\.memoryID)
            let found = try services.store.memories(ids: Array(ids))
            let rows = found.map { memory in
                PanelSearchRow(id: memory.id, title: memory.title,
                               category: memory.categoryKeys.first.map { app?.categoryName($0) ?? $0 },
                               sensitivity: memory.sensitivity)
            }
            return .init(rows: rows, total: hits.count)
        }
        field.answersOn = { answers.isOn }
        field.autoAskPause = { query in answers.trigger.fires(for: query) ? answers.trigger.pause : nil }
        field.readsAtMost = { answers.readsAtMost }
        field.ask = { [weak self] query, ids in
            let engine = answers.engineName, limit = answers.cloudLimitName
            let total = self?.field.page?.total ?? ids.count
            // Activity records it as search_answered, actor the user, as the Vault's Ask does.
            let result = try await answers.answer(query, ids: ids)
            return PanelSearchAnswer(answer: result, results: total, engine: engine, limit: limit)
        }
        field.failure = { answers.message(for: $0 as? SearchAnswerError ?? .vault) }
    }

    // MARK: What it shows

    var waiting: WaitingItems { app.waiting(now: now) }

    var agentsTile: AgentsTile { app.agentsTile }

    var remoteTile: RemoteTile { app.remoteTile }

    var isNewVault: Bool { !app.hasMemories && (pulse?.isQuiet ?? true) }

    // MARK: Opening and closing

    /// The panel is about to show: fresh counts, the Cloud chip, the focus in the field.
    func opened() {
        now = Date()
        app.tick()
        app.updateCloudChip(chip)
        focusRequest += 1
        refreshPulse()
    }

    /// The panel closed: only the draft stays (results, answers and their calls go).
    func closed() {
        field.close()
        pulseTask?.cancel()
    }

    func tick() { now = Date() }

    /// The app's state changed while the panel shows: the chart follows vault changes.
    func vaultChanged() {
        guard app.dataGeneration != chartGeneration else { return }
        refreshPulse()
    }

    /// The last 24 hours, read off the main thread; a read for an older call is dropped.
    func refreshPulse() {
        pulseTask?.cancel()
        chartGeneration = app.dataGeneration
        let store = app.services.store
        pulseTask = Task { [weak self] in
            let pulse = await Task.detached(priority: .userInitiated) { try? store.recentPulse(now: Date()) }.value
            guard !Task.isCancelled, let pulse else { return }
            self?.pulse = pulse
        }
    }

    #if FUNES_UI_REVIEW
    func reviewPulse(_ pulse: RecentPulse) {
        pulseTask?.cancel()
        self.pulse = pulse
    }
    #endif

    // MARK: Actions

    /// Review: the panel closes, and the item's own panel comes forward. Nothing is answered here.
    func review(_ route: WaitingItems.Route) {
        closePanel()
        app.review(route, signIn: reviewSignIn)
    }

    func open(_ row: PanelSearchRow) {
        closePanel()
        app.showMemory(row.id)
    }

    /// Show All 23 in Vault: the Vault searching for the text.
    func showAllInVault() {
        let query = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        closePanel()
        app.showVault(query: query)
    }

    /// An hour of the chart: Activity for that hour, or its Problems for a refused dot.
    func openHour(_ bucket: VaultOverview.Bucket, problems: Bool) {
        closePanel()
        app.showActivity(.period(RecentPulse.interval(of: bucket)), kind: problems ? .problems : .all)
    }

    func show(_ section: AppSection) {
        closePanel()
        app.show(section)
    }

    func openSettings(_ tab: SettingsTab?) {
        closePanel()
        app.openSettings(tab)
    }

    func addAgent() {
        closePanel()
        app.show(.agents)
        app.wantsAddAgent = true
    }

    func showPendingRequests() {
        closePanel()
        app.showActivity(nil)
    }
}

// MARK: The answer card

extension MenuBarPanelModel: AnswerCardSource {
    var answer: VaultModel.Answer? {
        switch field.answer {
        case nil: nil
        case .reading(let count): .reading(count: count)
        case .answered(let a): .answered(a.answer, results: a.results, engine: a.engine, limit: a.limit)
        case .failed(let text, let retry): .failed(text: text, retry: retry)
        }
    }

    var answerSources: [UUID] {
        guard case .answered(let a) = field.answer else { return [] }
        var seen = Set<UUID>()
        return a.answer.claims.flatMap(\.citations).map(\.memoryID).filter { seen.insert($0).inserted }
    }

    func ask() { field.askNow() }

    func clearAnswer() { field.clearAnswer() }

    /// A claim's number: the memory in the Vault with the quoted sentence highlighted, as the
    /// Vault's numbers do (the Vault searches for the same text, so its list holds it).
    func showSource(_ id: UUID, quote: String) {
        let query = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        closePanel()
        app.showVault(query: query)
        app.vault.showSource(id, quote: quote)
    }

    func sourceTitle(_ id: UUID) -> String { field.page?.rows.first { $0.id == id }?.title ?? "" }
}

// MARK: Dictation

extension MenuBarPanelModel: DictationTarget {
    var text: String {
        get { field.text }
        set { field.text = newValue }
    }

    var error: String? {
        get { field.error }
        set { field.error = newValue }
    }

    var stopDictation: Int { field.dictationStops }

    func focusField() { focusRequest += 1 }

    func dictationStarting(_ starting: Bool) { holdOpen(starting) }
}

// MARK: The app's side

extension AppModel {
    /// What waits for the user, for the panel's cards and Review Request (ADR-0029).
    func waiting(now: Date) -> WaitingItems {
        let queue = services.approvals.queue
        let open = pending.filter { $0.status == .needsApproval }.map { request in
            WaitingItems.Pending(id: request.id,
                                 title: request.memoryCount == 1 ? String(localized: "\(request.agentName) wants 1 memory")
                                                                 : String(localized: "\(request.agentName) wants \(request.memoryCount) memories"),
                                 expiresAt: request.expiresAt)
        }
        return WaitingItems(queue: queue.ordered, current: queue.current, signIns: signIns, pending: open, now: now)
    }

    /// Review, from a card or Review Request: brings the item's own panel forward, key. It
    /// keeps its arming delay and keys, so the key press that chose Review can't answer it.
    func review(_ route: WaitingItems.Route, signIn: () -> Void) {
        switch route {
        case .queueItem(let id):
            if !services.approvals.review(id) { _ = services.approvals.review() }
        case .pending(let id):
            openPendingRequest(id)
        case .signIn:
            signIn()
        }
    }

    var agentsTile: AgentsTile {
        let server: AgentsTile.Server = switch mcpStatus {
        case .off: .off
        case .starting: .starting
        case .listening: .listening
        case .failed(.portInUse(let port)): .failed(portInUse: port)
        case .failed: .failed(portInUse: nil)
        }
        return AgentsTile(serverEnabled: preferences.mcpEnabled, server: server, pausedUntil: pausedUntil, agents: agents.count)
    }

    var remoteTile: RemoteTile {
        let up = if case .listening = mcpStatus { preferences.mcpEnabled } else { false }
        return remoteAccess.tile(agentServerUp: up, agentsPaused: pausedUntil != nil)
    }
}
