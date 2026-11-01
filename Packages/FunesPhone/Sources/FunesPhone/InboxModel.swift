import Foundation
import FunesProtocol
import Observation

/// The Inbox tab (UX: iPhone, Inbox tab; FR-iOS-09): the Mac's waiting suggestions, every card
/// answered as on the Mac (ADR-0031): its own action with the card's choice (Replace or Keep
/// Both, Keep This or Both Are True), Edit & Save, Review Again, or Reject. An answered row
/// leaves at once; if the Mac doesn't take the answer, it comes back where it was and the failure
/// is shown. A row the Mac is still processing can only be rejected; one whose split failed
/// offers Try again and Keep as one (memory processing §5.2).
@MainActor @Observable
public final class InboxModel {
    public enum Phase: Sendable, Equatable {
        case idle, loading, loaded
        case failed(CompanionClientError)
    }

    public enum Answer: Sendable, Equatable {
        /// The card's own action (Save, Replace, Archive, Merge, …), with its choice.
        case save, reject
        /// A failed split: Try again, Keep as one.
        case retry, keep
        /// A stale card: Review Again.
        case reviewAgain
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
    /// Hears every failed call, for the reachability banner.
    @ObservationIgnored public var onFailure: @MainActor (CompanionClientError) -> Void
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
            // Cancelled (the tab closed): not the Mac's failure.
            guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
            onFailure(error)
        }
    }

    /// Swipe right saves only where the row shows everything that changes: a new memory, or one
    /// already in the vault (ADR-0031 §5). Every other card opens to be answered.
    public static func swipes(_ item: InboxItem) -> Bool {
        item.processing == nil && (item.action == .create || item.action == .duplicate)
    }

    /// `inbox.get`: the card in full, for its screen. One no longer waiting leaves the list.
    public func detail(_ id: UUID) async throws(CompanionClientError) -> InboxDetail {
        do {
            let detail = try await caller.call(InboxGet.self, SuggestionID(suggestionId: id))
            if let index = items.firstIndex(where: { $0.id == id }) { items[index] = detail.item }
            return detail
        } catch .method(let error) where error.code == .notFound {
            if items.contains(where: { $0.id == id }) {
                items.removeAll { $0.id == id }
                answeredElsewhere += 1
            }
            throw .method(error)
        } catch {
            if !Task.isCancelled { onFailure(error) }
            throw error
        }
    }

    /// Applies the card's own action: Save on a swipe, or from its screen with the card's choice
    /// (`mode`, `keep` for a conflict's Keep This), Edit & Save's `edits`, and the `revision` it
    /// showed. True once the Mac has it. Never while the Mac is processing it. A split reads the
    /// list again: its pieces that change other memories join it.
    @discardableResult
    public func save(_ id: UUID, mode: InboxApplyMode? = nil, keep: UUID? = nil, edits: MemoryChanges? = nil,
                     revision: String? = nil) async -> Bool {
        guard let item = items.first(where: { $0.id == id }), item.processing != .processing else { return false }
        let params = InboxApplyParams(suggestionId: id, edits: edits.flatMap { $0.isEmpty ? nil : $0 }, mode: mode, keepMemoryId: keep,
                                      revision: revision)
        let done = await answer(id, .save) { [caller] () async throws(CompanionClientError) in _ = try await caller.call(InboxApply.self, params) }
        if done, item.action == .split { await load() }
        return done
    }

    /// Review Again on a stale card: the Mac records its memories as they are now. True once the
    /// Mac has it; the screen then reads the card again. The row stays meanwhile, so a refresh
    /// keeps it too.
    @discardableResult
    public func reviewAgain(_ id: UUID) async -> Bool {
        guard let item = items.first(where: { $0.id == id }), !answering.contains(id) else { return false }
        do {
            _ = try await caller.call(InboxReviewAgain.self, SuggestionID(suggestionId: id))
            return true
        } catch .method(let error) where error.code == .notFound || error.code == .conflict {
            items.removeAll { $0.id == id }
            answeredElsewhere += 1
            return false
        } catch {
            failure = Failure(item: item, answer: .reviewAgain, error: error)
            onFailure(error)
            return false
        }
    }

    /// Reject (swipe left). True once the Mac has it.
    @discardableResult
    public func reject(_ id: UUID) async -> Bool {
        await answer(id, .reject) { [caller] () async throws(CompanionClientError) in _ = try await caller.call(InboxReject.self, SuggestionID(suggestionId: id)) }
    }

    /// Try again on a failed split: the row stays, processing again. True once the Mac has it.
    @discardableResult
    public func retry(_ id: UUID) async -> Bool {
        await mark(id, .retry, as: .processing) { [caller] () async throws(CompanionClientError) in
            _ = try await caller.call(InboxRetry.self, SuggestionID(suggestionId: id))
        }
    }

    /// Keep as one on a failed split: the row stays, an ordinary suggestion to save or reject.
    @discardableResult
    public func keepAsOne(_ id: UUID) async -> Bool {
        await mark(id, .keep, as: nil) { [caller] () async throws(CompanionClientError) in
            _ = try await caller.call(InboxKeep.self, SuggestionID(suggestionId: id))
        }
    }

    /// Changes a row's processing state once the Mac has the answer. One answered on the Mac
    /// meanwhile leaves; one whose state changed there is read again.
    private func mark(_ id: UUID, _ answer: Answer, as processing: InboxProcessing?,
                      _ send: () async throws(CompanionClientError) -> Void) async -> Bool {
        guard let item = items.first(where: { $0.id == id }), item.processing == .failed, !answering.contains(id) else { return false }
        answering.insert(id)
        defer { answering.remove(id) }
        do {
            try await send()
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].processing = processing }
            return true
        } catch .method(let error) where error.code == .notFound {
            items.removeAll { $0.id == id }
            answeredElsewhere += 1
            return false
        } catch .method(let error) where error.code == .conflict {
            await load()
            return false
        } catch {
            failure = Failure(item: item, answer: answer, error: error)
            onFailure(error)
            return false
        }
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
        } catch .method(let error) where error.code == .notFound {
            // Saved or rejected on the Mac first: it's no longer waiting.
            answeredElsewhere += 1
            return false
        } catch .method(let refusal) where refusal.code == .conflict {
            // Answered on the Mac, or (rarely) still waiting but no longer appliable: the card says which.
            do {
                let current = try await caller.call(InboxGet.self, SuggestionID(suggestionId: id))
                items.insert(current.item, at: min(index, items.count))
                failure = Failure(item: current.item, answer: answer, error: .method(refusal))
            } catch .method(let gone) where gone.code == .notFound {
                answeredElsewhere += 1
            } catch {
                items.insert(item, at: min(index, items.count))
                failure = Failure(item: item, answer: answer, error: .method(refusal))
            }
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
