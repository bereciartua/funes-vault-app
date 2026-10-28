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

    public var query = ""
    /// Active, Archived or Recently Deleted.
    public var scope = MemoryStatus.active
    /// Only memories at this level: Home's Sensitivity tile. Nil for every level.
    public var sensitivity: Sensitivity?
    public private(set) var results: [MemorySummary] = []
    public private(set) var phase = Phase.idle
    public private(set) var nextCursor: String?
    public private(set) var loadingMore = false

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
        do {
            let page = try await caller.call(MemoriesSearch.self, params(cursor: nil))
            guard mine == generation else { return }
            results = page.results
            nextCursor = page.nextCursor
            phase = .loaded
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

    /// Leaving the Mac (unpaired, removed): nothing stays on the phone.
    public func clear() {
        generation += 1
        results = []
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

    /// The Mac's snippet rule (`CompanionHandlers.snippet`), for a row changed on the phone.
    static func snippet(_ body: String) -> String {
        let flat = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= 160 ? flat : String(flat.prefix(159)) + "…"
    }
}
