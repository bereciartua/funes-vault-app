import Foundation
import FunesCore
import FunesProtocol
import Observation

/// The Vault's list: search, filters, sort and selection (FR-V-10, FR-V-11, FR-V-14). Lives as
/// long as the app, so switching sections keeps the place.
@MainActor @Observable
final class VaultModel {
    enum StatusChoice: String, CaseIterable, Identifiable {
        case active, archived, expired, recentlyDeleted
        var id: String { rawValue }

        var title: String {
            switch self {
            case .active: String(localized: "Active")
            case .archived: String(localized: "Archived")
            case .expired: String(localized: "Expired")
            case .recentlyDeleted: String(localized: "Recently Deleted")
            }
        }

        var filter: MemoryFilter.StatusFilter {
            switch self {
            case .active: .active
            case .archived: .archived
            case .expired: .expired
            case .recentlyDeleted: .recentlyDeleted
            }
        }
    }

    enum SortChoice: String, CaseIterable, Identifiable {
        case updated, created, title
        var id: String { rawValue }

        var title: String {
            switch self {
            case .updated: String(localized: "Last Updated")
            case .created: String(localized: "Date Created")
            case .title: String(localized: "Title")
            }
        }

        var sort: MemoryFilter.Sort {
            switch self {
            case .updated: .updated
            case .created: .created
            case .title: .title
            }
        }
    }

    /// Search debounce (plan 3.2).
    static let debounce: Duration = .milliseconds(150)

    private let services: VaultEnvironment
    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    var status: StatusChoice = .active { didSet { if status != oldValue { selection = []; scheduleSearch(now: true) } } }
    var categoryKeys = Set<String>() { didSet { if categoryKeys != oldValue { scheduleSearch(now: true) } } }
    var kinds = Set<MemoryKind>() { didSet { if kinds != oldValue { scheduleSearch(now: true) } } }
    var sensitivities = Set<Sensitivity>() { didSet { if sensitivities != oldValue { scheduleSearch(now: true) } } }
    var sources = Set<MemorySource>() { didSet { if sources != oldValue { scheduleSearch(now: true) } } }
    var sort: SortChoice = .updated { didSet { if sort != oldValue { scheduleSearch(now: true) } } }

    private(set) var memories: [Memory] = []
    /// Whether the last load finished; until then the list doesn't claim to be empty.
    private(set) var loaded = false
    var selection = Set<UUID>()
    /// A message under the toolbar after a bulk action ("12 archived, 1 couldn't be changed").
    var bulkResult: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(services: VaultEnvironment) {
        self.services = services
    }

    var filter: MemoryFilter {
        MemoryFilter(status: status.filter, categoryKeys: categoryKeys, kinds: kinds, sensitivities: sensitivities,
                     sources: sources, sort: sort.sort)
    }

    var hasFilters: Bool { !categoryKeys.isEmpty || !kinds.isEmpty || !sensitivities.isEmpty || !sources.isEmpty }

    func clearFilters() {
        categoryKeys = []
        kinds = []
        sensitivities = []
        sources = []
    }

    /// Runs the search after the debounce; filters and sort apply at once.
    func scheduleSearch(now: Bool = false) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            if !now { try? await Task.sleep(for: Self.debounce) }
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func load() async {
        let now = Date()
        let filter = self.filter
        let query = self.query
        do {
            let hits = try await services.search.vaultSearch(query, filter: filter, now: now)
            guard !Task.isCancelled, query == self.query, filter == self.filter else { return }
            memories = try services.store.memories(ids: hits.map(\.memoryID))
            selection = selection.intersection(memories.map(\.id))
            loaded = true
        } catch {
            loaded = true
        }
    }

    // MARK: Bulk actions (FR-V-14)

    enum BulkAction {
        case archive, restore, delete, deleteNow
        case moveToCategory(String)
        case sensitivity(Sensitivity)
    }

    func perform(_ action: BulkAction, on ids: Set<UUID>) async {
        let store = services.store
        let now = Date()
        var done = 0, failed = 0
        for id in ids {
            do {
                switch action {
                case .archive: try store.archiveMemory(id: id, now: now)
                case .restore: try store.restoreMemory(id: id, now: now)
                case .delete: try store.deleteMemory(id: id, now: now)
                case .deleteNow: try store.purgeMemory(id: id)
                case .moveToCategory(let key): try store.updateMemory(id: id, MemoryEdit(categoryKeys: [key]), now: now)
                case .sensitivity(let level): try store.updateMemory(id: id, MemoryEdit(sensitivity: level), now: now)
                }
                done += 1
            } catch {
                failed += 1
            }
        }
        bulkResult = Self.summary(action, done: done, failed: failed)
        selection = []
        await load()
    }

    static func summary(_ action: BulkAction, done: Int, failed: Int) -> String {
        let verb: String = switch action {
        case .archive: String(localized: "\(done) archived")
        case .restore: String(localized: "\(done) restored")
        case .delete: String(localized: "\(done) moved to Recently Deleted")
        case .deleteNow: String(localized: "\(done) deleted permanently")
        case .moveToCategory, .sensitivity: String(localized: "\(done) changed")
        }
        return failed == 0 ? verb : String(localized: "\(verb), \(failed) couldn't be changed")
    }
}
