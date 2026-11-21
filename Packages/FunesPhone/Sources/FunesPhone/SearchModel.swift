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

    /// The card's state. The last answer stays in memory (never on disk) so that it comes back
    /// with its search, after opening a memory or another tab.
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
            // Another model, or none: the card, an answer on its way and the kept answer were the
            // previous model's.
            if macAnswers?.engine != oldValue?.engine || macAnswers?.locality != oldValue?.locality {
                lastAnswer = nil
                clearCard()
            }
            if macAnswers != nil { scheduleAutoAsk() }
        }
    }
    /// `answers_off` came back: no Ask until `status.get` says otherwise.
    private var macSaidOff = false

    /// Every successful `status.get`: what the Mac says now replaces an earlier `answers_off`,
    /// even when it says the same as before. `factsRevision`: its learned facts' revision (v0.10), from a status that
    /// reached the Mac (`.some(nil)`: not in use); `.none` when the check didn't reach it, which says nothing about them.
    public func statusChecked(_ answers: SearchAnswersStatus?, factsRevision: String?? = .none) {
        macAnswers = answers
        if answers != nil {
            macSaidOff = false
            scheduleAutoAsk()
        }
        if case let .some(revision) = factsRevision { revisionSeen(revision, searchAgain: true) }
    }

    // MARK: Learned facts (v0.10, ADR-0032)

    /// The Mac's learned facts' revision, as last heard (`status.get`, a search, a correction); nil while they're not in use.
    public private(set) var factsRevision: String?
    private var revisionHeard = false
    /// A correction (`facts.reject`) didn't go through: the Mac wasn't reachable (nothing queued), or it refused one that
    /// changed or went (the list is searched again, so its buttons are current).
    public private(set) var correctionFailure: CompanionClientError?
    /// Hears that the Mac's learned facts changed under an answer (`facts_changed`): the app asks `status.get` again.
    @ObservationIgnored public var onFactsChanged: @MainActor () -> Void = {}

    /// A revision from the Mac. A change, absent to present included, drops the answer the phone holds (shown or kept for
    /// its search: it rested on what may have changed) and, from a status, searches again; nothing is asked again on its
    /// own for that search. An answer still on its way is the Mac's to drop: it refuses one whose learned facts changed
    /// (`facts_changed`), while readings that change nothing it rested on (a backfill) leave it.
    private func revisionSeen(_ revision: String?, searchAgain: Bool) {
        defer { factsRevision = revision; revisionHeard = true }
        guard revisionHeard, revision != factsRevision else { return }
        lastAnswer = nil
        if case .answered = answer {
            let asked = autoAsked
            clearCard()
            autoAsked = asked ?? resultsParams
        }
        if searchAgain, resultsParams != nil { Task { await self.search() } }
    }

    /// **Not <name>** or **Not this** from a result's why line or an inferred claim: sent to the Mac, which applies it at
    /// once; the list reloads, and a result nothing else admits drops out. Unreachable: nothing is queued.
    public func correct(_ target: FactsCorrectionTarget) async {
        correctionFailure = nil
        do {
            let result = try await caller.call(FactsReject.self, target)
            revisionSeen(result.factsRevision, searchAgain: false)
            lastAnswer = nil
            clearCard()
            await search()
        } catch {
            let failure = error as? CompanionClientError ?? .local
            correctionFailure = failure
            if case .method = failure {
                // Refused (changed or gone since it was shown): the list again, with current buttons.
                lastAnswer = nil
                clearCard()
                await search()
            } else {
                onFailure(failure)
            }
        }
    }

    public func dismissCorrectionFailure() { correctionFailure = nil }

    /// A correction made elsewhere on this phone (People & history, 13d.2): the held answer and the card rested on what
    /// changed, so they go, and the list is searched again; nothing is asked again on its own.
    public func factsCorrectedElsewhere() {
        lastAnswer = nil
        let asked = autoAsked
        clearCard()
        autoAsked = asked ?? resultsParams
        if resultsParams != nil { Task { await self.search() } }
    }
    /// Settings ▸ Search answers ▸ Show Ask in Search (this iPhone only, on by default).
    public var showAsk = true { didSet { if showAsk != oldValue { showAsk ? scheduleAutoAsk() : cancelAutoAsk() } } }
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    /// Bumped by each Ask, Cancel and new search, so a late answer is dropped.
    private var answerGeneration = 0
    /// What the card answers, and the last answer that came: the search and its filters, and the
    /// memories read, unedited since (FR-iOS-13).
    private var answerKey: AnswerKey?
    private var lastAnswer: (key: AnswerKey, result: MemoryAnswerResult, results: Int, cited: [AnswerKey.Read])?
    /// The memories the card's answer cites, as listed when it came: with learned facts the Mac may read a result past
    /// the first ones shown, so an edit to one of those drops the answer too.
    private var answerCited: [AnswerKey.Read] = []
    private struct AnswerKey: Equatable {
        struct Read: Equatable { let id: UUID; let updatedAt: Date }
        let params: MemorySearchParams
        let read: [Read]
    }
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
        cancelAutoAsk()
        let params = params(cursor: nil)
        // Refreshing the same search, or coming back to it, keeps its card and an answer still on
        // its way; another search, scope or filter clears it, and so does a refresh after a failure.
        if answerKey?.params != params { clearCard() } else if case .failed = answer { clearCard() }
        do {
            let page = try await caller.call(MemoriesSearch.self, params)
            guard mine == generation else { return }
            revisionSeen(page.factsRevision, searchAgain: false)
            results = page.results
            resultsParams = params
            nextCursor = page.nextCursor
            phase = .loaded
            restoreAnswer()
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
            // Ranked at another revision than the first page: start the list over.
            if revisionHeard, page.factsRevision != factsRevision {
                loadingMore = false
                revisionSeen(page.factsRevision, searchAgain: false)
                await search()
                return
            }
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
        readMemoryChanged(memory.id, updatedAt: memory.status == scope ? memory.updatedAt : nil)
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
    public func removed(_ id: UUID) {
        readMemoryChanged(id, updatedAt: nil)
        results.removeAll { $0.id == id }
    }

    /// A memory an answer read was edited, left the scope or is gone: the card and the kept
    /// answer no longer answer the results.
    private func readMemoryChanged(_ id: UUID, updatedAt: Date?) {
        func stale(_ read: [AnswerKey.Read]?) -> Bool { read?.contains { $0.id == id && $0.updatedAt != updatedAt } == true }
        if stale(lastAnswer?.key.read) || stale(lastAnswer?.cited) { lastAnswer = nil }
        if stale(answerKey?.read) || stale(answerKey == nil ? nil : answerCited) { clearCard() }
    }

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
        guard let key = currentAnswerKey else { return }
        answerKey = key
        // Apple's on-device model reads at most 5 (memory processing §10.3).
        answer = .reading(count: macAnswers?.locality == .onDevice ? min(ids.count, 5) : ids.count)
        let caller = self.caller
        let task = Task { [weak self] in
            do {
                let result = try await caller.call(MemoriesAnswer.self, MemoryAnswerParams(query: params.query, filters: params.filters, ids: ids,
                                                                                  automatic: automatic ? true : nil))
                guard let self, mine == self.answerGeneration else { return }
                // The Mac checked it against what it rested on; its revision is the newest the phone has heard.
                if let made = result.factsRevision { self.factsRevision = made; self.revisionHeard = true }
                self.answer = .answered(result, results: total)
                let cited = result.sources.compactMap { id in
                    self.results.first { $0.id == id }.map { AnswerKey.Read(id: id, updatedAt: $0.updatedAt) }
                }
                self.answerCited = cited
                self.lastAnswer = (key, result, total, cited)
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
        clearCard()
    }

    /// The search an Ask now would answer, with the memories it would read.
    private var currentAnswerKey: AnswerKey? {
        guard let params = resultsParams else { return nil }
        return AnswerKey(params: params, read: results.prefix(askIDs.count).map { AnswerKey.Read(id: $0.id, updatedAt: $0.updatedAt) })
    }

    /// Results loaded: the card stays only while it answers them (the same memories, unedited),
    /// and the last answer comes back with its search (still the one in the field: a late reply to
    /// the previous search brings nothing back), while the Mac still answers and Ask shows.
    /// It counts as the search's answer: nothing is asked on its own after it.
    private func restoreAnswer() {
        let key = currentAnswerKey
        if answer != .idle {
            if answerKey != key { clearCard() }
        } else if let last = lastAnswer, last.key == key, key?.params == params(cursor: nil), macAnswers != nil, !macSaidOff, showAsk,
                  scope == .active, last.result.factsRevision == nil || last.result.factsRevision == factsRevision {
            answer = .answered(last.result, results: last.results)
            answerKey = key
            answerCited = last.cited
            autoAsked = last.key.params
        }
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
            case .modelUnavailable where error.reason == "facts_changed":
                // What it rested on changed while it was on its way: no card; the Mac's status, then the list, again.
                // Nothing is asked again on its own for this search.
                answer = .idle
                answerKey = nil
                onFactsChanged()
                Task { await self.search() }
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

    /// Cancel and Clear: the card goes, the phone stops waiting, and the answer doesn't come back
    /// with its search. The Mac's work ends at its result, its deadline or this iPhone's next Ask.
    public func clearAnswer() {
        if let key = answerKey, lastAnswer?.key == key { lastAnswer = nil }
        clearCard()
    }

    /// A new search, scope or filter: the card goes and the phone stops waiting; the last answer
    /// stays for when its search comes back.
    private func clearCard() {
        answerGeneration += 1
        answerTask?.cancel()
        answerTask = nil
        answerKey = nil
        answerCited = []
        cancelAutoAsk()
        answer = .idle
    }

    /// Leaving the Mac (unpaired, removed): nothing stays on the phone.
    public func clear() {
        clearAnswer()
        lastAnswer = nil
        factsRevision = nil
        revisionHeard = false
        correctionFailure = nil
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
