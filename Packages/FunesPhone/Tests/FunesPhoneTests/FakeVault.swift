import Foundation
import FunesProtocol
@testable import FunesPhone

/// The Mac's vault as the companion methods see it: memories with versions, waiting suggestions
/// and two categories. A change naming an old version is `conflict`, as `CompanionHandlers`
/// answers. Failures can be queued per method.
final class FakeVault: CompanionCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var memories: [UUID: Memory] = [:]
    private var suggestions: [InboxItem] = []
    private var failures: [CompanionMethod: [CompanionClientError]] = [:]
    private var delays: [String: Duration] = [:]
    private(set) var calls: [CompanionMethod] = []
    private(set) var updates: [MemoryUpdateParams] = []
    private(set) var applied: [InboxApplyParams] = []
    private(set) var rejected: [UUID] = []
    private(set) var searches: [MemorySearchParams] = []

    @discardableResult
    func add(_ title: String, body: String = "Some text", status: MemoryStatus = .active, updated: TimeInterval = 0) -> Memory {
        let memory = Memory(title: title, body: body, kind: .fact, categoryKeys: ["work"], sensitivity: .low, status: status,
                            source: .manual, createdAt: t0, updatedAt: t0.addingTimeInterval(updated))
        lock.withLock { memories[memory.id] = memory }
        return memory
    }

    @discardableResult
    func suggest(_ title: String) -> InboxItem {
        let item = InboxItem(id: UUID(), origin: .agent, action: .create, sourceLabel: "Claude Code", title: title, body: "Body of \(title)",
                             kind: .preference, categories: ["work"], sensitivity: .low, createdAt: t0)
        lock.withLock { suggestions.append(item) }
        return item
    }

    /// An edit made on the Mac: the version moves on.
    func macEdit(_ id: UUID, body: String) {
        lock.withLock {
            memories[id]?.body = body
            memories[id]?.version += 1
        }
    }

    /// Answered on the Mac: it leaves the Inbox.
    func macAnswer(_ id: UUID) { lock.withLock { suggestions.removeAll { $0.id == id } } }

    func memory(_ id: UUID) -> Memory? { lock.withLock { memories[id] } }
    var inbox: [InboxItem] { lock.withLock { suggestions } }

    /// The next call of `method` fails with `error`.
    func fail(_ method: CompanionMethod, with error: CompanionClientError) { lock.withLock { failures[method, default: []].append(error) } }

    /// A search for `query` answers only after `delay`.
    func delay(_ query: String, _ delay: Duration) { lock.withLock { delays[query] = delay } }

    func perform<Call: CompanionCall>(_ request: PendingCall<Call>) async throws(CompanionClientError) -> Call.Result {
        if let search = request.params as? MemorySearchParams, let delay = lock.withLock({ delays[search.query] }) {
            try? await Task.sleep(for: delay)
        }
        return try locked(Call.method, request.params) as! Call.Result
    }

    private func locked(_ method: CompanionMethod, _ params: Any) throws(CompanionClientError) -> Any {
        lock.lock()
        defer { lock.unlock() }
        calls.append(method)
        if var queued = failures[method], !queued.isEmpty {
            let error = queued.removeFirst()
            failures[method] = queued
            throw error
        }
        return try handle(method, params)
    }

    private func handle(_ method: CompanionMethod, _ params: Any) throws(CompanionClientError) -> Any {
        switch method {
        case .categoriesList:
            return [CompanionCategory(MemoryCategory(key: "work", name: "Work")), CompanionCategory(MemoryCategory(key: "home", name: "Home"))]
        case .memoriesSearch:
            let params = params as! MemorySearchParams
            searches.append(params)
            let status = params.filters?.status ?? .active
            let hits = memories.values
                .filter { $0.status == status }
                .filter { params.query.isEmpty || $0.title.localizedCaseInsensitiveContains(params.query) }
                .sorted { $0.updatedAt > $1.updatedAt }
            let offset = params.cursor.flatMap(Int.init) ?? 0
            let page = Array(hits.dropFirst(offset).prefix(params.limit ?? 20))
            let summaries = page.map {
                MemorySummary(id: $0.id, title: $0.title, snippet: $0.body, kind: $0.kind, categories: $0.categoryKeys,
                              sensitivity: $0.sensitivity, updatedAt: $0.updatedAt)
            }
            return MemorySearchResult(results: summaries, nextCursor: offset + page.count < hits.count ? String(offset + page.count) : nil)
        case .memoriesGet:
            let id = (params as! MemoryID).id
            guard let memory = memories[id] else { throw .method(CompanionError(.notFound)) }
            return CompanionMemory(memory: memory, provenance: [ProvenanceLabel(at: t0, event: "created", label: "You")], sharedCount: 0)
        case .memoriesUpdate:
            let params = params as! MemoryUpdateParams
            updates.append(params)
            var memory = try current(params.id, version: params.version)
            let c = params.changes
            memory.title = c.title ?? memory.title
            memory.body = c.body ?? memory.body
            memory.kind = c.kind ?? memory.kind
            memory.categoryKeys = c.categories ?? memory.categoryKeys
            memory.sensitivity = c.sensitivity ?? memory.sensitivity
            if let expiry = c.expiresAt { memory.expiresAt = expiry }
            return save(memory)
        case .memoriesArchive, .memoriesRestore, .memoriesDelete:
            let ref = params as! MemoryVersionRef
            var memory = try current(ref.id, version: ref.version)
            memory.status = method == .memoriesArchive ? .archived : method == .memoriesRestore ? .active : .deleted
            return save(memory)
        case .inboxList:
            let offset = (params as! InboxListParams).cursor.flatMap(Int.init) ?? 0
            let page = Array(suggestions.dropFirst(offset).prefix(2))
            return InboxListResult(items: page, nextCursor: offset + page.count < suggestions.count ? String(offset + page.count) : nil)
        case .inboxApply:
            let params = params as! InboxApplyParams
            guard let index = suggestions.firstIndex(where: { $0.id == params.suggestionId }) else { throw .method(CompanionError(.notFound)) }
            suggestions.remove(at: index)
            applied.append(params)
            return InboxApplied(memoryId: UUID())
        case .inboxReject:
            let id = (params as! SuggestionID).suggestionId
            guard let index = suggestions.firstIndex(where: { $0.id == id }) else { throw .method(CompanionError(.notFound)) }
            suggestions.remove(at: index)
            rejected.append(id)
            return EmptyResult()
        default:
            throw .method(CompanionError(.unknownMethod))
        }
    }

    private func current(_ id: UUID, version: Int) throws(CompanionClientError) -> Memory {
        guard let memory = memories[id] else { throw .method(CompanionError(.notFound)) }
        guard memory.version == version else { throw .method(CompanionError(.conflict)) }
        return memory
    }

    private func save(_ memory: Memory) -> MemoryVersion {
        var memory = memory
        memory.version += 1
        memories[memory.id] = memory
        return MemoryVersion(version: memory.version)
    }
}

/// Collects what the models report to the reachability banner.
@MainActor final class FailureLog {
    private(set) var errors: [CompanionClientError] = []
    var record: @MainActor (CompanionClientError) -> Void { { [weak self] in self?.errors.append($0) } }
}
