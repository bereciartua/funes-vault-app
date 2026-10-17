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
        titlesLoaded = true
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
                if !entry.event.ids.contains(id) { return false }
            case .request(let id):
                if entry.event.requestID != id { return false }
            }
            if let since, entry.time < since { return false }
            guard entry.matches(kind) else { return false }
            guard !query.isEmpty else { return true }
            return [entry.label, entry.result.text, labels(entry)].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// Which rows a list shows: everything, one agent's (its Activity tab), one memory's or one request's.
enum ActivityScope: Equatable {
    case all
    case agent(UUID)
    case memory(UUID)
    case request(UUID)
}
