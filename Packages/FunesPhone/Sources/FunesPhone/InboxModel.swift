import Foundation
import FunesProtocol
import Observation

/// The Inbox tab (UX: iPhone, Inbox tab; FR-iOS-09): the Mac's waiting suggestions, answered with
/// Save, Edit & Save or Reject. A swiped row leaves at once; if the Mac doesn't take the answer,
/// it comes back where it was and the failure is shown.
@MainActor @Observable
public final class InboxModel {
    public enum Phase: Sendable, Equatable {
        case idle, loading, loaded
        case failed(CompanionClientError)
    }

    public enum Answer: Sendable, Equatable {
        case save, reject
    }

    /// An answer the Mac didn't take.
    public struct Failure: Sendable, Equatable, Identifiable {
        public var id: UUID { item.id }
        public var item: InboxItem
        public var answer: Answer
        public var error: CompanionClientError
    }

    public private(set) var items: [InboxItem] = []
    public private(set) var phase = Phase.idle
    public private(set) var nextCursor: String?
    /// The last answer that failed, for an alert.
    public var failure: Failure?
    /// Suggestions already answered on the Mac: they left this list without the phone's answer.
    public var answeredElsewhere = 0

    private let caller: any CompanionCalling
    private let onFailure: @MainActor (CompanionClientError) -> Void
    /// Answers on their way to the Mac: a refresh meanwhile doesn't bring their rows back.
    private var answering: Set<UUID> = []

    public init(caller: any CompanionCalling, onFailure: @escaping @MainActor (CompanionClientError) -> Void = { _ in }) {
        self.caller = caller
        self.onFailure = onFailure
    }

    /// `inbox.list`, from the first page. Pull to refresh.
    public func load() async {
        if items.isEmpty { phase = .loading }
        do {
            let page = try await caller.call(InboxList.self, InboxListParams())
            items = page.items.filter { !answering.contains($0.id) }
            nextCursor = page.nextCursor
            phase = .loaded
        } catch {
            if items.isEmpty { phase = .failed(error) }
            onFailure(error)
        }
    }

    public func loadMore() async {
        guard let cursor = nextCursor, phase == .loaded else { return }
        nextCursor = nil
        do {
            let page = try await caller.call(InboxList.self, InboxListParams(cursor: cursor))
            let known = Set(items.map(\.id)).union(answering)
            items += page.items.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
        } catch {
            nextCursor = cursor
            onFailure(error)
        }
    }

    /// Save (swipe right), or Edit & Save with `edits`. True once the Mac has it.
    @discardableResult
    public func save(_ id: UUID, edits: MemoryChanges? = nil) async -> Bool {
        let params = InboxApplyParams(suggestionId: id, edits: edits.flatMap { $0.isEmpty ? nil : $0 })
        return await answer(id, .save) { [caller] () async throws(CompanionClientError) in _ = try await caller.call(InboxApply.self, params) }
    }

    /// Reject (swipe left). True once the Mac has it.
    @discardableResult
    public func reject(_ id: UUID) async -> Bool {
        await answer(id, .reject) { [caller] () async throws(CompanionClientError) in _ = try await caller.call(InboxReject.self, SuggestionID(suggestionId: id)) }
    }

    private func answer(_ id: UUID, _ answer: Answer,
                        _ send: () async throws(CompanionClientError) -> Void) async -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), !answering.contains(id) else { return false }
        let item = items.remove(at: index)
        answering.insert(id)
        defer { answering.remove(id) }
        do {
            try await send()
            return true
        } catch .method(let error) where error.code == .notFound || error.code == .conflict {
            // Saved or rejected on the Mac first: it's no longer waiting either way.
            answeredElsewhere += 1
            return false
        } catch {
            items.insert(item, at: min(index, items.count))
            failure = Failure(item: item, answer: answer, error: error)
            onFailure(error)
            return false
        }
    }

    /// Leaving the Mac (unpaired, removed): nothing stays on the phone.
    public func clear() {
        items = []
        nextCursor = nil
        phase = .idle
        failure = nil
        answeredElsewhere = 0
    }
}
