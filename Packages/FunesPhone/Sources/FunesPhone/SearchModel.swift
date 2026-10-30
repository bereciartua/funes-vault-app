import Foundation
import FunesProtocol
import Observation

/// The Search tab (UX: iPhone, Search tab; FR-iOS-07): a query against the Mac and its results,
/// a page at a time. Nothing outlives the app's memory.
@MainActor @Observable
public final class SearchModel {
    public enum Phase: Sendable, Equatable {
        case idle, searching, loaded
        case failed(CompanionClientError)
    }

    public static let pageSize = 30

    // Changing the search clears the answer at once, before the search's pause ends.
    public var query = "" { didSet { if query != oldValue { searchChanged() } } }
    /// Active, Archived or Recently Deleted.
    public var scope = MemoryStatus.active { didSet { if scope != oldValue { searchChanged() } } }
    /// Only memories at this level: Home's Sensitivity tile. Nil for every level.
    public var sensitivity: Sensitivity? { didSet { if sensitivity != oldValue { searchChanged() } } }
    public private(set) var results: [MemorySummary] = []
    public private(set) var phase = Phase.idle
    public private(set) var nextCursor: String?
    public private(set) var loadingMore = false
    /// The search and filters the results answer, as sent (trimmed).
    public private(set) var resultsParams: MemorySearchParams?

    // MARK: Search answers (FR-iOS-13)

    /// The card's state; the answer lives on screen only (never kept).
    public enum AnswerState: Sendable, Equatable {
        case idle
        case reading(count: Int)
        case answered(MemoryAnswerResult, results: Int)
        case failed(AnswerFailure)
    }

    /// Why an answer didn't come, for the card's words (`AnswerWording`).
    public enum AnswerFailure: Sendable, Equatable {
        case answersOff, capReached, timeout
        case modelUnavailable(reason: String?)
        /// The Mac couldn't be reached: the usual unreachable state.
        case client(CompanionClientError)
    }

    public private(set) var answer = AnswerState.idle
    /// The Mac's Search answers (`status.get`); nil while they're off. The app keeps it current.
    public var macAnswers: SearchAnswersStatus? {
        didSet {
            guard macAnswers != oldValue else { return }
            // Fresh word from the Mac replaces an earlier answers_off.
            macSaidOff = false
            if macAnswers == nil { clearAnswer() } else { scheduleAutoAsk() }
        }
    }
    /// `answers_off` came back: no Ask until `status.get` says otherwise.
    private var macSaidOff = false

    /// Every successful `status.get`: what the Mac says now replaces an earlier `answers_off`,
    /// even when it says the same as before.
    public func statusChecked(_ answers: SearchAnswersStatus?) {
        macAnswers = answers
        if answers != nil {
            macSaidOff = false
            scheduleAutoAsk()
        }
    }
    /// Settings ▸ Search answers ▸ Show Ask in Search (this iPhone only, on by default).
    public var showAsk = true { didSet { if showAsk != oldValue { showAsk ? scheduleAutoAsk() : cancelAutoAsk() } } }
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    /// Bumped by each Ask, Cancel and new search, so a late answer is dropped.
    private var answerGeneration = 0
    /// The automatic Ask waiting for its pause (memory processing §10.6) and what it waits with:
    /// the search, its first results and the trigger; and the search an Ask (automatic or not)
    /// started for, so refreshing it, Clear or Cancel never ask again until the search changes.
    @ObservationIgnored var autoTask: Task<Void, Never>?
    private var autoPending: AutoKey?
    private var autoAsked: MemorySearchParams?
    private struct AutoKey: Equatable { let params: MemorySearchParams; let ids: [UUID]; let trigger: AnswerTrigger }
    /// Whether Search is on screen (the view sets it): nothing is asked on its own while it isn't.
    public var visible = false { didSet { if visible != oldValue { visible ? scheduleAutoAsk() : cancelAutoAsk() } } }
    /// Waits out the automatic Ask's pause; tests shorten it.
    @ObservationIgnored var pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    private let caller: any CompanionCalling
    /// Hears every failed call, for the reachability banner.
    @ObservationIgnored public var onFailure: @MainActor (CompanionClientError) -> Void
    /// Bumped by each search, so an answer to an older query is dropped.
    private var generation = 0

    public init(caller: any CompanionCalling, onFailure: @escaping @MainActor (CompanionClientError) -> Void = { _ in }) {
        self.caller = caller
        self.onFailure = onFailure
    }

    /// Runs the query in the scope. An empty query lists the most recently updated memories.
    public func search() async {
        generation += 1
        let mine = generation
        phase = .searching
        loadingMore = false
        // A new search, scope or filter clears the card and stops waiting.
        clearAnswer()
        do {
            let params = params(cursor: nil)
            let page = try await caller.call(MemoriesSearch.self, params)
            guard mine == generation else { return }
            results = page.results
            resultsParams = params
            nextCursor = page.nextCursor
            phase = .loaded
            // New results restart the pause: it counts from the list the answer will read.
            scheduleAutoAsk()
        } catch {
            // Cancelled (the query changed while typing, the tab closed): another search follows,
            // and a cancelled call says nothing about the Mac.
            guard mine == generation, !Task.isCancelled else { return }
            phase = .failed(error)
            onFailure(error)
        }
    }

    /// The next page, appended.
    public func loadMore() async {
        guard let cursor = nextCursor, !loadingMore, phase == .loaded else { return }
        let mine = generation
        loadingMore = true
        defer { if mine == generation { loadingMore = false } }
        do {
            let page = try await caller.call(MemoriesSearch.self, params(cursor: cursor))
            guard mine == generation else { return }
            let known = Set(results.map(\.id))
            results += page.results.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            onFailure(error)
        }
    }

    /// The detail saved, archived, restored or deleted `memory`: its row changes, or leaves the
    /// scope.
    public func changed(_ memory: Memory) {
        guard let index = results.firstIndex(where: { $0.id == memory.id }) else { return }
        guard memory.status == scope else {
            results.remove(at: index)
            return
        }
        results[index] = MemorySummary(id: memory.id, title: memory.title, snippet: Self.snippet(memory.body), kind: memory.kind,
                                       categories: memory.categoryKeys, sensitivity: memory.sensitivity, updatedAt: memory.updatedAt,
                                       expiresAt: memory.expiresAt)
    }

    /// The memory is gone from the Mac.
    public func removed(_ id: UUID) { results.removeAll { $0.id == id } }

    /// The Ask pill: the Mac answers, Show Ask is on, the Active scope, a non-empty search whose
    /// results have loaded, and no card showing.
    public var canAsk: Bool {
        guard macAnswers != nil, !macSaidOff, showAsk, scope == .active, phase == .loaded, !results.isEmpty, case .idle = answer,
              let params = resultsParams, params.filters?.status == nil, !params.query.isEmpty else { return false }
        // The results listed are the current search's, not the last one's while typing.
        let current = self.params(cursor: nil)
        return current.query == params.query && current.filters == params.filters
    }

    /// A row's number on the card, when the answer cites it.
    public func sourceNumber(_ id: UUID) -> Int? {
        guard case let .answered(result, _) = answer else { return nil }
        return result.sources.firstIndex(of: id).map { $0 + 1 }
    }

    /// The memories an Ask sends: the first 10 results shown, in order (8 to a Mac that takes no
    /// more).
    public var askIDs: [UUID] {
        let most = min(macAnswers?.maxIDs ?? MemoryAnswerParams.maxIDs, MemoryAnswerParams.maxIDs)
        return Array(results.prefix(max(most, 1)).map(\.id))
    }

    /// Asks the Mac to answer the search from the results shown. Returns when the card shows the
    /// answer, a failure, or was cleared meanwhile.
    public func ask() async { await ask(automatic: false) }

    private func ask(automatic: Bool) async {
        guard canAsk, let params = resultsParams else { return }
        // Any Ask, automatic or not, is this search's one: none follows on its own after it.
        autoAsked = params
        if !automatic { cancelAutoAsk() }
        answerTask?.cancel()
        answerGeneration += 1
        let mine = answerGeneration
        let ids = askIDs
        let total = results.count
        // Apple's on-device model reads at most 5 (memory processing §10.3).
        answer = .reading(count: macAnswers?.locality == .onDevice ? min(ids.count, 5) : ids.count)
        let caller = self.caller
        let task = Task { [weak self] in
            do {
                let result = try await caller.call(MemoriesAnswer.self, MemoryAnswerParams(query: params.query, filters: params.filters, ids: ids,
                                                                                  automatic: automatic ? true : nil))
                guard let self, mine == self.answerGeneration else { return }
                self.answer = .answered(result, results: total)
            } catch {
                guard let self, mine == self.answerGeneration, !Task.isCancelled else { return }
                self.fail(error as? CompanionClientError ?? .local)
            }
        }
        answerTask = task
        await task.value
    }

    /// Asks on its own after the pause, once for each search, while Search shows, when the Mac
    /// says to and the search qualifies (a question, or any search); never while Show Ask is off.
    /// Called when results arrive and when the Mac's status, Show Ask or Search's visibility
    /// change: a pause already running with the same search, results and trigger goes on, any
    /// other change starts it again, and a search that no longer qualifies stops it.
    private func scheduleAutoAsk() {
        guard visible, let trigger = macAnswers?.trigger, canAsk, let params = resultsParams, autoAsked != params,
              trigger.fires(for: params.query) else {
            cancelAutoAsk()
            return
        }
        let key = AutoKey(params: params, ids: askIDs, trigger: trigger)
        if autoTask != nil, autoPending == key { return }
        autoTask?.cancel()
        autoPending = key
        let pause = self.pause
        autoTask = Task { [weak self] in
            try? await pause(trigger.pause)
            guard !Task.isCancelled, let self else { return }
            // Done waiting: a later change schedules afresh.
            self.autoTask = nil
            self.autoPending = nil
            guard self.visible, self.resultsParams == params, self.canAsk, self.macAnswers?.trigger.fires(for: params.query) == true
            else { return }
            await self.ask(automatic: true)
        }
    }

    private func cancelAutoAsk() {
        autoTask?.cancel()
        autoTask = nil
        autoPending = nil
    }

    /// The search, scope or filter changed: a new search, which may be answered on its own again.
    private func searchChanged() {
        autoAsked = nil
        clearAnswer()
    }

    private func fail(_ error: CompanionClientError) {
        switch error {
        case let .method(error):
            switch error.code {
            case .answersOff:
                answer = .failed(.answersOff)
                macSaidOff = true
            case .capReached: answer = .failed(.capReached)
            case .modelTimeout: answer = .failed(.timeout)
            case .modelUnavailable: answer = .failed(.modelUnavailable(reason: error.reason))
            case .askRequired:
                // The Mac answers this search only when asked now: show Ask, and ask on its own
                // again only when a fresh status says to.
                answer = .idle
                macAnswers?.trigger = .ask
            default: answer = .failed(.client(.method(error)))
            }
        case .answerTimedOut:
            answer = .failed(.timeout)
        default:
            answer = .failed(.client(error))
            onFailure(error)
        }
    }

    /// Cancel and Clear, a new search, and leaving Search: the card goes and the phone stops
    /// waiting. The Mac's work ends at its result, its deadline or this iPhone's next Ask.
    public func clearAnswer() {
        answerGeneration += 1
        answerTask?.cancel()
        answerTask = nil
        cancelAutoAsk()
        answer = .idle
    }

    /// Leaving the Mac (unpaired, removed): nothing stays on the phone.
    public func clear() {
        clearAnswer()
        autoAsked = nil
        generation += 1
        results = []
        resultsParams = nil
        nextCursor = nil
        phase = .idle
        loadingMore = false
    }

    private func params(cursor: String?) -> MemorySearchParams {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filters = scope == .active && sensitivity == nil
            ? nil : MemorySearchFilters(sensitivities: sensitivity.map { [$0] }, status: scope == .active ? nil : scope)
        return MemorySearchParams(query: query, filters: filters, limit: Self.pageSize, cursor: cursor)
    }

    /// The Mac's snippet without a search (memory processing §10.2), for a row changed on the phone:
    /// the edit may have moved the match, so the row shows the body's start, unmarked.
    static func snippet(_ body: String) -> String {
        let flat = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= 160 ? flat : String(flat.prefix(159)) + "…"
    }
}
