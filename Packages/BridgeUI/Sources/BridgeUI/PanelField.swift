import Foundation
import Observation

/// The menu bar panel's field (written for Funes, ADR-0029): ⏎ remembers what's typed, ⌘⏎
/// searches and then asks, Esc steps back. The app gives it its search, its save and its answers;
/// this holds the keys' rules, the draft, and which call a result belongs to, so a late one is
/// dropped. The draft is kept in memory only. Results and answers exist only after a search.
@MainActor @Observable
public final class PanelField<Row: Identifiable & Sendable & Equatable, Answer: Sendable & Equatable> where Row.ID: Sendable {
    /// Rows shown under the field; the answer reads more (`Page.rows`).
    public static var shownRows: Int { 5 }

    /// A search's results: the first rows (up to what an answer reads) and how many matched.
    public struct Page: Equatable, Sendable {
        public var rows: [Row]
        public var total: Int
        public init(rows: [Row], total: Int) {
            self.rows = rows
            self.total = total
        }
    }

    public enum AnswerState: Equatable, Sendable {
        case reading(count: Int)
        case answered(Answer)
        case failed(text: String, retry: Bool)
    }

    /// The line under the field.
    public enum Hint: Equatable, Sendable {
        /// "⏎ Remember · ⌘⏎ Search · goes to your Inbox".
        case keys
        case saving
        /// "Saved to Inbox", for `savedDuration`.
        case saved
        /// "Your last note wasn't saved", with Restore.
        case notSaved
    }

    public enum ReturnAction: Equatable, Sendable {
        /// Nothing more to do: saved, refused, or nothing to act on.
        case handled
        /// Open this result (the caller closes the panel).
        case open(Row)
    }

    public enum EscapeAction: Equatable, Sendable {
        case handled
        /// Nothing left to step back from: close the panel.
        case close
    }

    // MARK: State

    /// What's typed: the draft. Editing it after a search clears the results and the answer.
    public var text = "" {
        didSet { if text != oldValue { textChanged() } }
    }
    /// The search's results; nil shows the chart.
    public private(set) var page: Page?
    /// A search is running.
    public private(set) var searching = false
    /// The selected result, among the rows shown.
    public private(set) var selection = 0
    public private(set) var answer: AnswerState?
    public private(set) var hint = Hint.keys
    /// Shown under the field: the scanner's reason, or why a note wasn't saved.
    public var error: String?
    /// A note that failed to save while something else was typed: Restore brings it back. Notes
    /// that fail one after another are kept together, a blank line apart.
    public private(set) var unsaved: String?
    /// Bumped whenever dictation must stop: a save, ⌘⏎, Esc, closing.
    public private(set) var dictationStops = 0

    // MARK: What the app provides

    /// Why the text can't be saved as it is (too long, a secret), checked before the field clears.
    @ObservationIgnored public var validate: (String) -> String? = { _ in nil }
    /// Stores a capture; nil when stored, else why it wasn't.
    @ObservationIgnored public var store: @MainActor (String) async -> String? = { _ in nil }
    @ObservationIgnored public var search: @MainActor (String) async throws -> Page = { _ in Page(rows: [], total: 0) }
    /// Search answers are on.
    @ObservationIgnored public var answersOn: () -> Bool = { false }
    /// The pause before asking on its own for this search, or nil to wait for ⌘⏎.
    @ObservationIgnored public var autoAskPause: (String) -> Duration? = { _ in nil }
    /// How many of the rows an answer reads (5 on device, else 10).
    @ObservationIgnored public var readsAtMost: () -> Int = { 10 }
    @ObservationIgnored public var ask: @MainActor (String, [Row.ID]) async throws -> Answer = { _, _ in throw CancellationError() }
    /// The card's words for a failed answer, and whether Try Again can help.
    @ObservationIgnored public var failure: (Error) -> (text: String, retry: Bool) = { _ in ("", false) }
    @ObservationIgnored public var savedDuration: Duration = .seconds(2)

    // MARK: Calls in progress

    /// Bumped by anything that drops the results: a result for an older value is thrown away.
    @ObservationIgnored private var generation = 0
    /// Bumped by each Ask and by Cancel or Clear.
    @ObservationIgnored private var askGeneration = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private var savedTask: Task<Void, Never>?
    /// The text the results are for.
    @ObservationIgnored private var searched: String?
    /// What was typed when Restore swapped the unsaved note in: it comes back once that's saved.
    @ObservationIgnored private var nextDraft: String?

    public init() {}

    /// The rows shown under the field.
    public var shownRows: [Row] { Array((page?.rows ?? []).prefix(Self.shownRows)) }

    /// Results (or a search for them) show in place of the chart.
    public var showsResults: Bool { page != nil || searching }

    // MARK: Keys

    /// ⏎: with results showing, opens the selected one (and never saves); otherwise remembers
    /// the text.
    public func returnKey() -> ReturnAction {
        if showsResults {
            guard page != nil, shownRows.indices.contains(selection) else { return .handled }
            return .open(shownRows[selection])
        }
        remember()
        return .handled
    }

    /// ⌘⏎: searches; with results showing, asks (when answers are on).
    public func commandReturn() {
        stopDictation()
        if page != nil {
            if canAsk, answer == nil || isFailed { askNow() }
            return
        }
        guard !searching else { return }
        runSearch()
    }

    /// Esc: results → the chart (the text stays); then the text is cleared; then the panel closes.
    public func escape() -> EscapeAction {
        stopDictation()
        if showsResults {
            clearResults()
            return .handled
        }
        if !text.isEmpty {
            text = ""
            error = nil
            return .handled
        }
        return .close
    }

    /// ↑ ↓ among the rows shown.
    public func moveSelection(by step: Int) {
        let count = shownRows.count
        guard count > 0 else { return }
        selection = min(max(selection + step, 0), count - 1)
    }

    public func select(_ row: Row) {
        if let index = shownRows.firstIndex(where: { $0.id == row.id }) { selection = index }
    }

    /// The panel closed: results and answers go and their calls are cancelled; the draft stays,
    /// and a save in progress goes on.
    public func close() {
        stopDictation()
        clearResults()
        error = nil
    }

    /// Restore: the note that wasn't saved comes back, and what was typed since waits as the
    /// next draft.
    public func restore() {
        guard let unsaved else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        nextDraft = typed.isEmpty ? nil : text
        self.unsaved = nil
        hint = .keys
        error = nil
        text = unsaved
    }

    public func stopDictation() { dictationStops += 1 }

    // MARK: Remember

    private func remember() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if let reason = validate(body) {
            error = reason
            return
        }
        stopDictation()
        error = nil
        text = nextDraft ?? ""
        nextDraft = nil
        hint = .saving
        savedTask?.cancel()
        let store = self.store
        Task { [weak self] in
            let failed = await store(body)
            guard let self else { return }
            guard let failed else {
                self.showSaved()
                return
            }
            if self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.text = body
                self.error = failed
                self.hint = .keys
            } else {
                // A note already waiting for Restore keeps its place: both come back together.
                self.unsaved = self.unsaved.map { $0 + "\n\n" + body } ?? body
                self.error = failed
                self.hint = .notSaved
            }
        }
    }

    private func showSaved() {
        guard hint != .notSaved else { return }
        hint = .saved
        let duration = savedDuration
        savedTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.hint == .saved else { return }
            self.hint = .keys
        }
    }

    // MARK: Search and answers

    private var canAsk: Bool { answersOn() && !(page?.rows.isEmpty ?? true) }
    private var isFailed: Bool { if case .failed = answer { true } else { false } }

    private func runSearch() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        clearResults()
        searching = true
        searched = text
        let mine = generation
        let search = self.search
        searchTask = Task { [weak self] in
            let page = (try? await search(query)) ?? Page(rows: [], total: 0)
            guard !Task.isCancelled, let self, self.generation == mine else { return }
            self.page = page
            self.selection = 0
            self.searching = false
            self.scheduleAutoAsk(query)
        }
    }

    private func scheduleAutoAsk(_ query: String) {
        guard canAsk, answer == nil, let pause = autoAskPause(query) else { return }
        let mine = generation
        autoTask = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled, let self, self.generation == mine, self.answer == nil else { return }
            self.askNow()
        }
    }

    /// Asks now (⌘⏎, the Ask row, Try Again); a new Ask cancels the one in progress.
    public func askNow() {
        guard canAsk, let page, let query = searched?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        autoTask?.cancel()
        answerTask?.cancel()
        askGeneration += 1
        let mine = (generation, askGeneration)
        let ids = page.rows.map(\.id)
        answer = .reading(count: min(ids.count, readsAtMost()))
        let ask = self.ask
        answerTask = Task { [weak self] in
            do {
                let result = try await ask(query, ids)
                guard !Task.isCancelled, let self, (self.generation, self.askGeneration) == mine else { return }
                self.answer = .answered(result)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, (self.generation, self.askGeneration) == mine else { return }
                let failure = self.failure(error)
                self.answer = .failed(text: failure.text, retry: failure.retry)
            }
        }
    }

    /// Cancel and Clear on the answer card: the results stay, and nothing asks again on its own.
    public func clearAnswer() {
        answerTask?.cancel()
        autoTask?.cancel()
        askGeneration += 1
        answer = nil
    }

    private func textChanged() {
        if showsResults || answer != nil, text != searched { clearResults() }
    }

    private func clearResults() {
        generation += 1
        searchTask?.cancel()
        answerTask?.cancel()
        autoTask?.cancel()
        searchTask = nil
        answerTask = nil
        autoTask = nil
        page = nil
        searching = false
        answer = nil
        selection = 0
        searched = nil
    }
}
