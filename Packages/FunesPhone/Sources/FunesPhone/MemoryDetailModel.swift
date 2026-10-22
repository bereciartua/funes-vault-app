import Foundation
import FunesProtocol
import Observation

/// One memory, fetched from the Mac (UX: iPhone, Memory detail; FR-iOS-07, FR-iOS-08): its full
/// text and provenance, and Edit, Archive, Restore and Delete. Each change names the version the
/// phone last saw; a Mac that has moved on answers `conflict`, and the app asks "Changed on your
/// Mac, reload?". A failed save keeps the draft until it saves.
@MainActor @Observable
public final class MemoryDetailModel {
    public enum Phase: Sendable, Equatable {
        case loading, loaded
        /// The memory is no longer on the Mac.
        case gone
        case failed(CompanionClientError)
    }

    /// What the last change did, for the Search list.
    public enum Change: Sendable, Equatable {
        case changed(Memory)
        case removed(UUID)
    }

    public let id: UUID
    public private(set) var phase = Phase.loading
    public private(set) var detail: CompanionMemory?
    public var memory: Memory? { detail?.memory }
    /// The edit in progress: nil when not editing. Kept after a failed save until it saves.
    public var draft: MemoryEditDraft?
    /// A save or another change is on its way to the Mac.
    public private(set) var busy = false
    /// Why the last change failed, other than a conflict.
    public var error: CompanionClientError?
    /// The Mac's copy changed since this one was fetched: "Changed on your Mac, reload?".
    public var conflict = false
    /// Hears every change the Mac confirmed.
    @ObservationIgnored public var onChange: (@MainActor (Change) -> Void)?

    private let caller: any CompanionCalling
    /// Hears every failed call, for the reachability banner.
    @ObservationIgnored public var onFailure: @MainActor (CompanionClientError) -> Void
    private let clock: @Sendable () -> Date

    public init(id: UUID, caller: any CompanionCalling, onFailure: @escaping @MainActor (CompanionClientError) -> Void = { _ in },
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.id = id
        self.caller = caller
        self.onFailure = onFailure
        self.clock = clock
    }

    /// `memories.get`. A refetch that fails keeps what's shown.
    public func load() async {
        if detail == nil { phase = .loading }
        do {
            detail = try await caller.call(MemoriesGet.self, MemoryID(id: id))
            phase = .loaded
        } catch .method(let error) where error.code == .notFound {
            gone()
        } catch {
            if detail == nil { phase = .failed(error) }
            onFailure(error)
        }
    }

    /// "Reload" on the conflict question: the Mac's version replaces this one. While editing, the
    /// editor stays open with the Mac's version in place of the phone's edit, to change again.
    public func reload() async {
        let editing = draft != nil
        conflict = false
        error = nil
        await load()
        if let memory, editing {
            draft = MemoryEditDraft(memory)
        } else {
            draft = nil
        }
    }

    public func startEditing() {
        guard let memory else { return }
        error = nil
        draft = MemoryEditDraft(memory)
    }

    public func cancelEditing() {
        draft = nil
        error = nil
    }

    /// `memories.update` with the fields that changed. True once the Mac has it.
    @discardableResult
    public func save() async -> Bool {
        guard let memory, let draft, !busy else { return false }
        let changes = draft.changes(from: MemoryEditDraft(memory))
        guard !changes.isEmpty else {
            self.draft = nil
            return true
        }
        guard let version = await send(PendingCall<MemoriesUpdate>(MemoryUpdateParams(id: id, version: memory.version, changes: changes)))
        else { return false }
        let saved = draft.applied(to: memory, version: version.version, at: clock())
        detail?.memory = saved
        self.draft = nil
        onChange?(.changed(saved))
        // The new history line, and anything the Mac normalised.
        await load()
        return true
    }

    @discardableResult
    public func archive() async -> Bool { await setStatus(MemoriesArchive.self, to: .archived) }

    @discardableResult
    public func restore() async -> Bool { await setStatus(MemoriesRestore.self, to: .active) }

    /// Moves it to Recently Deleted on the Mac, where it can be restored for 30 days.
    @discardableResult
    public func delete() async -> Bool { await setStatus(MemoriesDelete.self, to: .deleted) }

    private func setStatus<Call: CompanionCall>(_ call: Call.Type, to status: MemoryStatus) async -> Bool
        where Call.Params == MemoryVersionRef, Call.Result == MemoryVersion {
        guard var memory, !busy else { return false }
        guard let version = await send(PendingCall<Call>(MemoryVersionRef(id: id, version: memory.version))) else { return false }
        let now = clock()
        memory.status = status
        memory.version = version.version
        memory.updatedAt = now
        memory.deletedAt = status == .deleted ? now : nil
        detail?.memory = memory
        onChange?(.changed(memory))
        await load()
        return true
    }

    /// One change: a conflict sets `conflict`, a gone memory `phase`, anything else `error`.
    private func send<Call: CompanionCall>(_ request: PendingCall<Call>) async -> Call.Result? {
        busy = true
        defer { busy = false }
        error = nil
        do {
            return try await caller.perform(request)
        } catch .method(let error) where error.code == .conflict {
            conflict = true
        } catch .method(let error) where error.code == .notFound {
            gone()
        } catch {
            self.error = error
            onFailure(error)
        }
        return nil
    }

    private func gone() {
        phase = .gone
        detail = nil
        draft = nil
        onChange?(.removed(id))
    }
}
