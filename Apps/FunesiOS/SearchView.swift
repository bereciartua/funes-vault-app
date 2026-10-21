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
            Group {
                if model.reachability.isConnected {
                    results
                } else {
                    VaultUnavailableView(model: model, feature: .search)
                }
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
            .reachabilityBanner(model)
        }
    }

    @ViewBuilder private var results: some View {
        let search = model.search
        switch search.phase {
        case .idle:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .searching where search.results.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(error) where search.results.isEmpty:
            ContentUnavailableView {
                Label("Couldn't search", systemImage: "exclamationmark.triangle")
            } description: {
                Text(PhoneModel.vaultMessage(for: error))
            } actions: {
                Button("Try Again") { Task { await search.search() } }
            }
        default:
            if search.results.isEmpty {
                if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(Self.emptyTitle(search.scope), systemImage: "tray")
                } else {
                    ContentUnavailableView.search(text: search.query)
                }
            } else {
                List {
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
                .refreshable { await search.search() }
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
