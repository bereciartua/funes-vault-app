import FunesPhone
import FunesProtocol
import SwiftUI

/// The Search tab (UX: iPhone, Search tab; FR-iOS-07): results come from the Mac, with the title,
/// a two-line snippet, category chips and a sensitivity badge. Disabled while the Mac can't be
/// reached.
struct SearchView: View {
    let model: PhoneModel

    private struct Key: Equatable {
        var query: String
        var scope: MemoryStatus
        var connected: Bool
    }

    var body: some View {
        @Bindable var search = model.search
        NavigationStack {
            List {
                BannerSection(model: model)
                if model.reachability.isConnected, !search.results.isEmpty {
                    Section {
                        ForEach(search.results) { summary in
                            NavigationLink(value: summary.id) {
                                ResultRow(summary: summary, categories: model.categories)
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
            .task(id: Key(query: search.query, scope: search.scope, connected: model.reachability.isConnected)) {
                guard model.reachability.isConnected else { return }
                // Typing: wait for a pause before asking the Mac.
                if !search.query.isEmpty {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                }
                await search.search()
            }
            .navigationDestination(for: UUID.self) { id in
                MemoryDetailView(model: model, id: id)
            }
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
                } else {
                    ContentUnavailableView.search(text: search.query)
                }
            }
        }
    }

    static func emptyTitle(_ scope: MemoryStatus) -> String {
        switch scope {
        case .active: String(localized: "No memories yet")
        case .archived: String(localized: "Nothing archived")
        case .deleted: String(localized: "Recently Deleted is empty")
        }
    }
}

/// A result: title, a two-line snippet, category chips and the sensitivity badge.
struct ResultRow: View {
    let summary: MemorySummary
    let categories: CategoryList

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.title).font(.headline).lineLimit(1)
            Text(summary.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
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
