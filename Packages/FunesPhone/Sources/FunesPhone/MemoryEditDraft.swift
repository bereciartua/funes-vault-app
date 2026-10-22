import Foundation
import FunesProtocol
import Observation

/// Sends one companion call. `CompanionClient` on the phone; a fake vault in tests.
public protocol CompanionCalling: Sendable {
    func perform<Call: CompanionCall>(_ request: PendingCall<Call>) async throws(CompanionClientError) -> Call.Result
}

/// A call's params, typed by its method. A value rather than the method's metatype, so it can
/// cross into the client actor.
public struct PendingCall<Call: CompanionCall>: Sendable {
    public var params: Call.Params

    public init(_ params: Call.Params) { self.params = params }
}

extension CompanionCalling {
    public func call<Call: CompanionCall>(_ call: Call.Type, _ params: Call.Params) async throws(CompanionClientError) -> Call.Result {
        try await perform(PendingCall<Call>(params))
    }
}

extension CompanionClient: CompanionCalling {
    public func perform<Call: CompanionCall>(_ request: PendingCall<Call>) async throws(CompanionClientError) -> Call.Result {
        try await call(Call.self, request.params)
    }
}

/// A memory's or a suggestion's fields while they're edited on the phone: the memory detail's
/// Edit, and the Inbox's Edit & Save. The Mac validates what's sent (FR-iOS-08); this only
/// catches what would obviously fail, so Save can be disabled.
public struct MemoryEditDraft: Sendable, Equatable {
    public enum Problem: Sendable, Equatable {
        case emptyTitle, emptyBody, noCategory
    }

    public var title: String
    public var body: String
    public var kind: MemoryKind
    public var categories: [String]
    public var sensitivity: Sensitivity
    public var expiresAt: Date?

    public init(title: String, body: String, kind: MemoryKind, categories: [String], sensitivity: Sensitivity,
                expiresAt: Date? = nil) {
        self.title = title
        self.body = body
        self.kind = kind
        self.categories = categories
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
    }

    public init(_ memory: Memory) {
        self.init(title: memory.title, body: memory.body, kind: memory.kind, categories: memory.categoryKeys,
                  sensitivity: memory.sensitivity, expiresAt: memory.expiresAt)
    }

    public init(_ item: InboxItem) {
        self.init(title: item.title, body: item.body, kind: item.kind, categories: item.categories, sensitivity: item.sensitivity,
                  expiresAt: item.expiresAt)
    }

    public var problem: Problem? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyTitle }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyBody }
        if categories.isEmpty { return .noCategory }
        return nil
    }

    /// Only the fields that differ from `original`, so an edit never rewrites what it didn't touch.
    public func changes(from original: MemoryEditDraft) -> MemoryChanges {
        MemoryChanges(title: title == original.title ? nil : title,
                      body: body == original.body ? nil : body,
                      kind: kind == original.kind ? nil : kind,
                      categories: categories == original.categories ? nil : categories,
                      sensitivity: sensitivity == original.sensitivity ? nil : sensitivity,
                      expiresAt: expiresAt == original.expiresAt ? nil : .some(expiresAt))
    }

    /// The memory with these fields, at `version`: what the Mac now holds after a save.
    func applied(to memory: Memory, version: Int, at now: Date) -> Memory {
        var memory = memory
        memory.title = title
        memory.body = body
        memory.kind = kind
        memory.categoryKeys = categories
        memory.sensitivity = sensitivity
        memory.expiresAt = expiresAt
        memory.version = version
        memory.updatedAt = now
        return memory
    }
}

/// The vault's categories (`categories.list`), for names on chips and the edit form's choices.
/// Read once per launch while the Mac is reachable; a key without a name shows as the key.
@MainActor @Observable
public final class CategoryList {
    public private(set) var all: [CompanionCategory] = []
    private let caller: any CompanionCalling
    private var loaded = false

    public init(caller: any CompanionCalling) { self.caller = caller }

    public func load(force: Bool = false) async {
        guard force || !loaded else { return }
        guard let categories = try? await caller.call(CategoriesList.self, EmptyParams()) else { return }
        all = categories
        loaded = true
    }

    public func name(_ key: String) -> String { all.first { $0.key == key }?.name ?? key }
}
