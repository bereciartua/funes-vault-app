import Foundation
import FunesProtocol
import Observation

/// One waiting request on the phone (FR-iOS-12): the Share, Save or access panel, built fresh by
/// `approvals.get` and answered once with `approvals.answer`, bound to the panel's revision.
/// The first answer wins on the Mac or a phone; a stale panel (`request_changed`) is fetched
/// again for the user to review. Answering needs the phone unlocked.
@MainActor @Observable
public final class ApprovalPanelModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        /// An answer is on its way to the Mac.
        case sending
        case closed(Closed)
        /// Couldn't fetch the panel: unreachable, or the Mac refused.
        case failed(CompanionClientError)
    }

    /// Why the panel can't be answered any more.
    public enum Closed: Sendable, Equatable {
        /// This phone's answer went through; `count` is the memories shared.
        case answered(ApprovalChoice, count: Int)
        /// The Mac (or another iPhone) answered first.
        case answeredOnMac
        /// Answered, perhaps by this phone: its last answer got no reply (a lost reply looks the
        /// same as a Mac answer from here).
        case alreadyAnswered
        case expired
        /// The Mac doesn't know it any more (a relaunch, an access request's wait over).
        case gone
    }

    /// Why an answer didn't go through; the panel stays up.
    public enum AnswerFailure: Sendable, Equatable {
        /// The phone is locked (no protected data): answers need it unlocked.
        case locked
        case call(CompanionClientError)
    }

    public private(set) var phase = Phase.loading
    public private(set) var detail: ApprovalDetail?
    /// Share: the ticked memories. Strong matches start ticked, weaker ones unticked (access
    /// policy §3.2), as on the Mac.
    public private(set) var selected: Set<UUID> = []
    /// The Mac said the panel changed (`request_changed`): this is the new one, to review again.
    public private(set) var changed = false
    public var answerFailure: AnswerFailure?

    /// Hears every failed call, for the reachability banner.
    @ObservationIgnored public var onFailure: @MainActor (CompanionClientError) -> Void = { _ in }
    /// The request can't be answered here any more: the list drops it.
    @ObservationIgnored public var onClosed: @MainActor (UUID) -> Void = { _ in }

    private var ref: ApprovalRef
    private let caller: any CompanionCalling
    private let isUnlocked: @MainActor () -> Bool
    /// The last answer got no reply, so it may have been taken.
    private var answerUnconfirmed = false

    public init(ref: ApprovalRef, caller: any CompanionCalling, isUnlocked: @escaping @MainActor () -> Bool = { true }) {
        self.ref = ref
        self.caller = caller
        self.isUnlocked = isUnlocked
    }

    /// The request's id once known (a ring names it only after the first fetch).
    public var id: UUID? { detail?.id ?? ref.id }

    /// Share rows: strong matches, then "Also matched, less closely".
    public var strongRows: [ApprovalRow] { detail?.share?.rows.filter { !$0.weak } ?? [] }
    public var weakRows: [ApprovalRow] { detail?.share?.rows.filter(\.weak) ?? [] }
    public var selectedCount: Int { selected.count }

    /// Share N is offered only with at least one memory ticked.
    public var canShare: Bool { phase == .ready && detail?.kind == .share && !selected.isEmpty }

    public func isSelected(_ id: UUID) -> Bool { selected.contains(id) }

    public func toggle(_ id: UUID) {
        guard phase == .ready, detail?.share?.rows.contains(where: { $0.id == id }) == true else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// `approvals.get`, by id or by the ring.
    public func load() async {
        if detail == nil { phase = .loading }
        do {
            show(try await caller.call(ApprovalsGet.self, ref))
        } catch {
            if !close(for: error) {
                if detail == nil { phase = .failed(error) } else { answerFailure = .call(error) }
                onFailure(error)
            }
        }
    }

    /// Sends one answer. Only a choice this panel offers; `share` sends the ticked memories in
    /// the panel's order.
    public func answer(_ choice: ApprovalChoice) async {
        guard phase == .ready, let detail, choice.kind == detail.kind else { return }
        if choice == .allowOnce, detail.access?.allowsOnce != true { return }
        guard isUnlocked() else {
            answerFailure = .locked
            return
        }
        var memoryIDs: [UUID]?
        if choice == .share {
            memoryIDs = (detail.share?.rows ?? []).map(\.id).filter(selected.contains)
            guard memoryIDs?.isEmpty == false else { return }
        }
        answerFailure = nil
        phase = .sending
        let params = ApprovalAnswerParams(id: detail.id, revision: detail.revision, choice: choice, memoryIds: memoryIDs)
        do {
            _ = try await caller.call(ApprovalsAnswer.self, params)
            phase = .closed(.answered(choice, count: memoryIDs?.count ?? 0))
            onClosed(detail.id)
        } catch .method(let failure) where failure.code == .requestChanged {
            // Something changed under the panel (T22): the new one, to review again.
            changed = true
            phase = .ready
            await load()
        } catch {
            if close(for: error) { return }
            // Not resent (§5): a reply that never came may still have been taken. Checking
            // again then says `already_answered`.
            if case .unreachable = error { answerUnconfirmed = true }
            phase = .ready
            answerFailure = .call(error)
            onFailure(error)
        }
    }

    private func show(_ fresh: ApprovalDetail) {
        let revised = detail.map { $0.id != fresh.id || $0.revision != fresh.revision } ?? true
        detail = fresh
        ref = ApprovalRef(id: fresh.id)
        if revised { selected = Set((fresh.share?.rows ?? []).filter { !$0.weak }.map(\.id)) }
        phase = .ready
    }

    /// The errors that end a panel. True when it's closed.
    private func close(for error: CompanionClientError) -> Bool {
        guard case let .method(failure) = error else { return false }
        let reason: Closed
        switch failure.code {
        case .alreadyAnswered: reason = answerUnconfirmed ? .alreadyAnswered : .answeredOnMac
        case .requestExpired: reason = .expired
        case .notFound: reason = .gone
        default: return false
        }
        phase = .closed(reason)
        answerFailure = nil
        if let id { onClosed(id) }
        return true
    }
}
