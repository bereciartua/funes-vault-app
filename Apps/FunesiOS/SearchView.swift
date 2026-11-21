import FunesPhone
import FunesProtocol
import SwiftUI

/// The Search tab (UX: iPhone, Search tab; FR-iOS-07): results come from the Mac, with the title,
/// a two-line snippet, category chips and a sensitivity badge. Disabled while the Mac can't be
/// reached.
struct SearchView: View {
    let model: PhoneModel
    /// Settings ▸ Search answers ▸ Show Ask in Search (this iPhone only).
    @AppStorage(SearchAnswersSettings.showAskKey) private var showAsk = true
    /// The cited memory a number opened.
    @State private var openSource: AnswerSource?

    private struct Key: Equatable {
        var query: String
        var scope: MemoryStatus
        var sensitivity: Sensitivity?
        var connected: Bool
    }

    var body: some View {
        @Bindable var search = model.search
        @Bindable var phone = model
        NavigationStack(path: $phone.searchPath) {
            List {
                // Search answers (FR-iOS-13): the Ask pill, then the card, as the list's first section.
                if model.reachability.isConnected {
                    if search.canAsk {
                        Section { AskPill { Task { await search.ask() } } }
                    } else if search.answer != .idle {
                        Section { AnswerCardView(search: search, model: model) { openSource = $0 } }
                    }
                }
                if model.reachability.isConnected, !search.results.isEmpty {
                    Section {
                        ForEach(search.results) { summary in
                            NavigationLink(value: SearchRoute.memory(summary.id)) {
                                ResultRow(summary: summary, categories: model.categories, source: search.sourceNumber(summary.id))
                            }
                            // Not <name> and Not this, with the Mac's words (v0.10): sent to the Mac, which applies them.
                            .contextMenu {
                                if let corrections = summary.corrections {
                                    FactsCorrectionButtons(targets: corrections) { target in Task { await search.correct(target) } }
                                }
                            }
                        }
                        if search.nextCursor != nil {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .task { await search.loadMore() }
                        }
                    }
                }
            }
            .overlay { placeholder }
            .refreshable {
                if model.reachability.isConnected { await search.search() } else { await model.refresh(fresh: true) }
            }
            .navigationTitle("Search")
            .searchable(text: $search.query, prompt: Text("Search your vault"))
            .searchScopes($search.scope) {
                ForEach(MemoryStatus.allCases, id: \.self) { Text($0.scopeTitle).tag($0) }
            }
            .task(id: Key(query: search.query, scope: search.scope, sensitivity: search.sensitivity, connected: model.reachability.isConnected)) {
                guard model.reachability.isConnected else { return }
                // Typing: wait for a pause before asking the Mac.
                if !search.query.isEmpty {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                }
                await search.search()
            }
            .toolbar {
                // The previous query's results stay listed until the Mac answers: say it's asking.
                if model.reachability.isConnected, search.phase == .searching, !search.results.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        ProgressView().accessibilityLabel("Searching")
                    }
                }
                // People & history (13d.2), while the Mac has it for this phone.
                if model.people.available {
                    ToolbarItem {
                        Button { model.searchPath.append(.people) } label: {
                            Label("People & History", systemImage: "person.2")
                        }
                    }
                }
                // Home's Sensitivity tile sets it; here it can be changed or cleared.
                ToolbarItem {
                    Menu {
                        Picker("Sensitivity", selection: $search.sensitivity) {
                            Text("Any Sensitivity").tag(Sensitivity?.none)
                            ForEach(Sensitivity.allCases, id: \.self) { Text($0.title).tag(Sensitivity?.some($0)) }
                        }
                    } label: {
                        Label("Sensitivity", systemImage: search.sensitivity == nil ? "line.3.horizontal.decrease.circle"
                                                                                   : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityValue(search.sensitivity?.title ?? String(localized: "Any Sensitivity"))
                }
            }
            .navigationDestination(for: SearchRoute.self) { route in
                switch route {
                case let .memory(id): MemoryDetailView(model: model, id: id)
                case .people: PeopleView(model: model)
                case let .entity(id): PeopleEntityView(model: model, id: id)
                }
            }
            // People & history leaves the stack: nothing it read stays.
            .onChange(of: model.searchPath) { _, path in
                if !path.contains(.people) { model.people.disappeared() }
            }
            .navigationDestination(item: $openSource) { source in
                MemoryDetailView(model: model, id: source.id, quote: source.quote)
            }
            .onChange(of: model.macAnswers, initial: true) { _, answers in search.macAnswers = answers }
            // Each fresh status.get, even an unchanged one, lifts an earlier answers_off.
            .onChange(of: model.lastChecked) { _, _ in
                // Only a status that reached the Mac says anything about its learned facts.
                search.statusChecked(model.macAnswers, factsRevision: model.reachability.isConnected ? .some(model.factsRevision) : .none)
            }
            // People & history: an older Mac hides it, Facts off closes it, a new revision reloads what's open. Only a
            // status that reached the Mac says anything about it.
            .onChange(of: model.lastChecked, initial: true) { _, _ in
                if model.reachability.isConnected { model.peopleStatusChecked() }
            }
            .onAppear { search.onFactsChanged = { Task { await model.refresh(fresh: true) } } }
            .alert(Self.correctionTitle(search.correctionFailure), isPresented: Binding(get: { search.correctionFailure != nil },
                                                                                       set: { if !$0 { search.dismissCorrectionFailure() } })) {
                Button("OK") { search.dismissCorrectionFailure() }
            } message: {
                Text(Self.correctionMessage(search.correctionFailure))
            }
            .onChange(of: showAsk, initial: true) { _, on in search.showAsk = on }
            // Opening a memory or another tab keeps the card (and an answer on its way); nothing is
            // asked on its own meanwhile.
            .onAppear { search.visible = true }
            .onDisappear { search.visible = false }
        }
    }

    /// What shows over the list while there are no results to list.
    @ViewBuilder private var placeholder: some View {
        let search = model.search
        if !model.reachability.isConnected {
            VaultUnavailableView(model: model, feature: .search)
        } else if search.results.isEmpty {
            switch search.phase {
            case .idle, .searching:
                ProgressView()
            case let .failed(error):
                ContentUnavailableView {
                    Label("Couldn't search", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(PhoneModel.vaultMessage(for: error))
                } actions: {
                    Button("Try Again") { Task { await search.search() } }
                }
            case .loaded:
                if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(Self.emptyTitle(search.scope), systemImage: "tray")
                } else if model.isDemo {
                    // The demo's search matches whole phrases: say which question to try.
                    ContentUnavailableView {
                        Label("No Results", systemImage: "magnifyingglass")
                    } description: {
                        Text(AnswerWording.failure(.modelUnavailable(reason: AnswerWording.demoHintReason), engine: "") { _ in "" }.text)
                    }
                } else {
                    ContentUnavailableView.search(text: search.query)
                }
            }
        }
    }

    /// A correction that didn't go through: the Mac wasn't reachable, or it refused one that changed.
    static func correctionTitle(_ failure: CompanionClientError?) -> String {
        if case .method = failure { return String(localized: "Couldn't correct that") }
        return String(localized: "Mac not reachable")
    }

    static func correctionMessage(_ failure: CompanionClientError?) -> String {
        guard let failure else { return "" }
        if case .method = failure { return String(localized: "It changed on your Mac. The results are up to date now; try again if it's still wrong.") }
        return PhoneModel.vaultMessage(for: failure)
    }

    static func emptyTitle(_ scope: MemoryStatus) -> String {
        switch scope {
        case .active: String(localized: "No memories yet")
        case .archived: String(localized: "Nothing archived")
        case .deleted: String(localized: "Recently Deleted is empty")
        }
    }
}

/// A result: title, a two-line snippet, category chips and the sensitivity badge. The snippet is
/// the passage that matches the search, with the matches the Mac marks in bold (FR-V-17).
struct ResultRow: View {
    let summary: MemorySummary
    let categories: CategoryList
    /// The answer's number for this memory, when the answer cites it.
    var source: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(summary.title).font(.headline).lineLimit(1)
                if let source { SourceNumber(number: source).accessibilityLabel(Text("Source \(source)")) }
            }
            Text(SnippetHighlight.attributed(summary.snippet, matches: summary.snippetMatches)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            // Why a link admitted it (v0.10), as the Mac words it.
            if let why = summary.why {
                Label(why, systemImage: "link").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 4) {
                SensitivityBadge(sensitivity: summary.sensitivity)
                CategoryChips(keys: summary.categories, categories: categories)
            }
            .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
