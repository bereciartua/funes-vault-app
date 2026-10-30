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
    /// While searching, each shown row's snippet: the passage that matches and its matches (FR-V-17).
    private(set) var snippets: [UUID: Snippet] = [:]
    /// Whether the last load finished; until then the list doesn't claim to be empty.
    private(set) var loaded = false
    var selection = Set<UUID>() {
        didSet { if let quoted, selection != [quoted.memoryID] { self.quoted = nil } }
    }
    /// A message under the toolbar after a bulk action ("12 archived, 1 couldn't be changed").
    var bulkResult: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// The search the list shows, the row index of each memory, the snippet pages asked for and
    /// the rows in view. `listing` counts loads, so a page asked for by an older one is dropped.
    @ObservationIgnored private var listedQuery = ""
    /// The filters the list shows, as `listedQuery` is its search.
    @ObservationIgnored private var listedFilter = MemoryFilter()
    @ObservationIgnored private var listing = 0
    @ObservationIgnored private var rowIndex: [UUID: Int] = [:]
    @ObservationIgnored private var snippetPages = Set<Int>()
    @ObservationIgnored private var visibleRows = Set<UUID>()

    /// Snippets are made a page of rows at a time, as rows appear (memory processing §10.2).
    static let snippetPage = 50
    /// The preview's snippet length: about one line of the list, so the match stays in view.
    nonisolated static let previewLength = 80

    init(services: VaultEnvironment) {
        self.services = services
    }

    // MARK: Search answers (FR-AI-17, memory processing §10)

    /// The card's state. An answer keeps the engine's name and the cloud limit as they were when
    /// it was asked, and a failure its words, so a later change in Settings doesn't relabel it.
    enum Answer: Equatable {
        case reading(count: Int)
        case answered(SearchAnswer, results: Int, engine: String, limit: String)
        case failed(text: String, retry: Bool)
    }

    /// Answers searches with the user's settings; set by the app.
    @ObservationIgnored var answers: SearchAnswersController?
    /// The card at the top of the list; nil shows the Ask row (when it can).
    private(set) var answer: Answer?
    /// A claim's number was clicked: the memory selected and the quote to highlight in its detail,
    /// until the selection changes or the text is edited.
    var quoted: (memoryID: UUID, quote: String)? {
        get { quotedValue.map { ($0.memoryID, $0.quote) } }
        set { quotedValue = newValue.map { Quoted(memoryID: $0.memoryID, quote: $0.quote) } }
    }
    private struct Quoted: Equatable { let memoryID: UUID; let quote: String }
    private var quotedValue: Quoted?
    @ObservationIgnored private var answerTask: Task<Void, Never>?

    /// Whether Search answers are on: the Ask row, the card and the chips show only then.
    var answersOn: Bool { answers?.isOn ?? false }

    /// The Ask row: answers on, the Active scope, a non-empty search with results, listed for the
    /// current search and filters (not a list still loading for a change).
    var canAsk: Bool {
        answersOn && status == .active && !listedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && listedQuery == query && listedFilter == filter && !memories.isEmpty
    }

    /// Asks the chosen model to answer the search from its top results as shown. A new Ask
    /// cancels the one in progress.
    func ask() {
        guard canAsk, let answers else { return }
        answerTask?.cancel()
        let query = listedQuery, filter = listedFilter
        let ids = Array(memories.prefix(SearchAnswerer.memoryCount).map(\.id))
        let total = memories.count
        let engine = answers.engineName, limit = answers.cloudLimitName
        answer = .reading(count: min(ids.count, answers.readsAtMost))
        answerTask = Task { [weak self] in
            do {
                let result = try await answers.answer(query, ids: ids)
                guard !Task.isCancelled, let self, self.listedQuery == query, self.listedFilter == filter else { return }
                self.answer = .answered(result, results: total, engine: engine, limit: limit)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, self.listedQuery == query, self.listedFilter == filter else { return }
                let message = answers.message(for: error as? SearchAnswerError ?? .vault)
                self.answer = .failed(text: message.text, retry: message.retry)
            }
        }
    }

    /// Cancel and Clear; and any change of search, scope or filter (rows never move under a card).
    func clearAnswer() {
        answerTask?.cancel()
        answerTask = nil
        answer = nil
        quoted = nil
    }

    /// The cited memories in the order the answer first cites them: their numbers on the card and
    /// on the rows.
    var answerSources: [UUID] {
        guard answersOn, case let .answered(result, _, _, _) = answer else { return [] }
        var seen = Set<UUID>()
        return result.claims.flatMap(\.citations).map(\.memoryID).filter { seen.insert($0).inserted }
    }

    /// A row's source number, if the answer cites it.
    func sourceNumber(_ id: UUID) -> Int? { answerSources.firstIndex(of: id).map { $0 + 1 } }

    #if FUNES_UI_REVIEW
    /// The UI review's answer scenes.
    func reviewAnswer(_ answer: SearchAnswer, results: Int) {
        self.answer = .answered(answer, results: results, engine: answers?.engineName ?? "", limit: answers?.cloudLimitName ?? "")
    }
    #endif

    /// A claim's number: select the memory, and highlight the quote in its detail.
    func showSource(_ id: UUID, quote: String) {
        selection = [id]
        quoted = (id, quote)
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
        clearAnswer()
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
            let found = try services.store.memories(ids: hits.map(\.memoryID))
            // The first page's snippets come with the list, so its rows don't change under the eye.
            let first = try await Self.snippets(for: found.prefix(Self.snippetPage), query: query, search: services.search)
            guard !Task.isCancelled, query == self.query, filter == self.filter else { return }
            memories = found
            listedQuery = query
            listedFilter = filter
            listing += 1
            rowIndex = Dictionary(found.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            snippetPages = [0]
            snippets = first
            // Rows still in view past the first page (a refresh while scrolled) get theirs again.
            for id in visibleRows { requestSnippets(for: id) }
            selection = selection.intersection(memories.map(\.id))
            loaded = true
        } catch {
            loaded = true
        }
    }

    /// A row came into view: its page's snippets, if not asked for yet.
    func rowAppeared(_ id: UUID) {
        visibleRows.insert(id)
        requestSnippets(for: id)
    }

    func rowDisappeared(_ id: UUID) { visibleRows.remove(id) }

    private func requestSnippets(for id: UUID) {
        guard !listedQuery.isEmpty, let index = rowIndex[id] else { return }
        let page = index / Self.snippetPage
        guard snippetPages.insert(page).inserted else { return }
        let rows = memories[(page * Self.snippetPage)..<min((page + 1) * Self.snippetPage, memories.count)]
        let query = listedQuery, mine = listing
        Task {
            guard let made = try? await Self.snippets(for: rows, query: query, search: services.search), mine == listing else { return }
            snippets.merge(made) { _, new in new }
        }
    }

    /// One `highlight()` query for the rows; a row without a body match gets the body's start.
    /// Off the main actor: trimming 50 long bodies takes tens of milliseconds.
    nonisolated static func snippets(for rows: ArraySlice<Memory>, query: String, search: SearchService) async throws -> [UUID: Snippet] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !rows.isEmpty else { return [:] }
        let matches = try await search.bodyMatches(query, ids: rows.map(\.id))
        return Dictionary(rows.map { m in
            (m.id, matches[m.id]?.snippet(length: previewLength) ?? BodyMatches.plainSnippet(m.body, length: previewLength))
        }, uniquingKeysWith: { a, _ in a })
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
