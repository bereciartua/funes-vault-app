import Foundation
import FunesCore
import Observation

/// Activity's filters and selection (FR-L-02): All, Shared, Suggestions, Problems; agent; period;
/// search over labels.
@MainActor @Observable
final class ActivityModel {
    enum Period: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: String(localized: "Today")
            case .week: String(localized: "7 days")
            case .month: String(localized: "30 days")
            case .all: String(localized: "All time")
            }
        }

        func start(now: Date) -> Date? {
            switch self {
            case .today: Calendar.current.startOfDay(for: now)
            case .week: now.addingTimeInterval(-7 * 86_400)
            case .month: now.addingTimeInterval(-30 * 86_400)
            case .all: nil
            }
        }
    }

    private let services: VaultEnvironment
    var kind: ActivityEntry.Kind = .all
    var agentFilter: UUID?
    var period: Period = .all
    var search = ""
    var selection: String?
    /// Every row except the "start" halves, newest first.
    private(set) var entries: [ActivityEntry] = []
    /// Live titles of the memories and suggestions rows name; an id missing here is gone.
    private(set) var titles: [UUID: String] = [:]
    private(set) var titlesLoaded = false
    /// The memories of rows whose ids aren't memories: an automatic change's (by its suggestion)
    /// and an undo's (by its undo entries), while the undo log keeps them.
    private(set) var relatedMemories: [String: [UUID]] = [:]
    /// A History row's Show in Activity, until the rows are loaded.
    private var pendingSelection: (memoryID: UUID, time: Date)?

    init(services: VaultEnvironment) {
        self.services = services
    }

    func load() async {
        entries = services.activity.store.records()
            .filter { $0.event.phase != .start }
            .map { ActivityEntry(id: $0.rowID, event: $0.event) }
            .reversed()
            .sorted { $0.time > $1.time }
        let ids = Array(Set(entries.flatMap(\.event.ids)))
        var titles: [UUID: String] = [:]
        for memory in (try? services.store.memories(ids: ids)) ?? [] where memory.status != .deleted { titles[memory.id] = memory.title }
        let unknown = ids.filter { titles[$0] == nil }
        for suggestion in (try? await services.suggestions.suggestions(ids: unknown)) ?? [] { titles[suggestion.id] = suggestion.title }
        self.titles = titles
        relatedMemories = await Self.relatedMemories(entries, undo: UndoLog(store: services.store, activity: services.activity))
        titlesLoaded = true
        resolvePendingSelection()
    }

    static func relatedMemories(_ entries: [ActivityEntry], undo: UndoLog) async -> [String: [UUID]] {
        let applied = entries.filter { $0.event.event == "auto_applied" }
        let undone = entries.filter { $0.event.event == "undone" }
        let now = Date()
        let bySuggestion = (try? await undo.changes(suggestionIDs: Array(Set(applied.flatMap(\.event.ids))), now: now)) ?? []
        let byEntry = (try? await undo.changes(ids: Array(Set(undone.flatMap(\.event.ids))), now: now)) ?? []
        var related: [String: [UUID]] = [:]
        for entry in applied {
            related[entry.id] = bySuggestion.filter { $0.entry.suggestionID.map(entry.event.ids.contains) ?? false }
                .flatMap { $0.items.map(\.memoryID) }
        }
        for entry in undone {
            related[entry.id] = byEntry.filter { entry.event.ids.contains($0.id) }.flatMap { $0.items.map(\.memoryID) }
        }
        return related.filter { !$0.value.isEmpty }
    }

    /// Whether a row is about this memory: it names it, or its automatic change touched it.
    func isAbout(_ entry: ActivityEntry, memoryID: UUID) -> Bool {
        entry.event.ids.contains(memoryID) || relatedMemories[entry.id]?.contains(memoryID) == true
    }

    /// Selects the row about this memory nearest `time` (within 2 seconds), now or once loaded.
    func select(memoryID: UUID, near time: Date) {
        pendingSelection = (memoryID, time)
        if titlesLoaded { resolvePendingSelection() }
    }

    private func resolvePendingSelection() {
        guard let pending = pendingSelection else { return }
        pendingSelection = nil
        let distance = { (entry: ActivityEntry) in abs(entry.time.timeIntervalSince(pending.time)) }
        selection = entries.filter { isAbout($0, memoryID: pending.memoryID) && distance($0) < 2 }
            .min { distance($0) < distance($1) }?.id ?? selection
    }

    /// "Prefers Vitest", or "(deleted memory)" once it's gone (FR-V-04).
    func title(_ id: UUID) -> String {
        titles[id] ?? (titlesLoaded ? String(localized: "(deleted memory)") : "…")
    }

    /// The rows a scope and the filters show. `labels` gives the agent name and live titles for search.
    func rows(_ scope: ActivityScope, now: Date, labels: (ActivityEntry) -> String) -> [ActivityEntry] {
        let since = period.start(now: now)
        let query = search.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            switch scope {
            case .all:
                if let agentFilter, entry.agentID != agentFilter { return false }
            case .agent(let id):
                if entry.agentID != id && !(entry.event.actor == "user" && entry.event.ids.contains(id)) { return false }
            case .memory(let id):
                if !isAbout(entry, memoryID: id) { return false }
            case .request(let id):
                if entry.event.requestID != id { return false }
            case .period(let interval):
                if let agentFilter, entry.agentID != agentFilter { return false }
                if entry.time < interval.start || entry.time >= interval.end { return false }
            }
            if let since, entry.time < since { return false }
            guard entry.matches(kind) else { return false }
            guard !query.isEmpty else { return true }
            return [entry.label, entry.result.text, labels(entry)].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// Which rows a list shows: everything, one agent's (its Activity tab), one memory's, one request's,
/// or a span of time (a day of Home's chart).
enum ActivityScope: Equatable {
    case all
    case agent(UUID)
    case memory(UUID)
    case request(UUID)
    case period(DateInterval)
}
