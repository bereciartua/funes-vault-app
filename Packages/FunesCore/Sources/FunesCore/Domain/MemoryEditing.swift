import Foundation
import FunesProtocol

/// A memory's editable fields, for merging an editor's unsaved edits onto a newer version of the
/// memory (FR-V-02; 04-ux-mac.md ▸ Vault ▸ Unsaved edits). The Mac's `MemoryForm` maps to it.
public struct MemoryFields: Equatable, Sendable {
    public var title: String
    public var body: String
    public var kind: MemoryKind
    public var categoryKeys: [String]
    public var sensitivity: Sensitivity
    public var expiresAt: Date?

    public init(title: String, body: String, kind: MemoryKind, categoryKeys: [String], sensitivity: Sensitivity,
                expiresAt: Date?) {
        self.title = title
        self.body = body
        self.kind = kind
        self.categoryKeys = categoryKeys
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
    }

    public init(_ memory: Memory) {
        self.init(title: memory.title, body: memory.body, kind: memory.kind, categoryKeys: memory.categoryKeys,
                  sensitivity: memory.sensitivity, expiresAt: memory.expiresAt)
    }

    /// These edits (where they differ from `base`, the version they started from) applied to
    /// `current`, the memory as it is now. Nil when a field they edited also changed since, to
    /// something else: Save then reports the conflict. Fields they didn't edit take `current`'s
    /// values (a status change, Still True, or an edit elsewhere to another field).
    public func rebased(from base: MemoryFields, onto current: MemoryFields) -> MemoryFields? {
        var out = current
        func take<T: Equatable>(_ path: WritableKeyPath<MemoryFields, T>) -> Bool {
            guard self[keyPath: path] != base[keyPath: path] else { return true }
            if current[keyPath: path] != base[keyPath: path], current[keyPath: path] != self[keyPath: path] { return false }
            out[keyPath: path] = self[keyPath: path]
            return true
        }
        guard take(\.title), take(\.body), take(\.kind), take(\.categoryKeys), take(\.sensitivity), take(\.expiresAt)
        else { return nil }
        return out
    }
}

/// Which memories the Vault keeps selected when its list reloads (FR-V-10; 04-ux-mac.md ▸ Vault ▸
/// Show this memory).
public enum VaultSelection {
    /// The memory a reload may keep selected though the new list doesn't hold it: the single
    /// selected memory, when the reload is of the same search and filters (a change to the data,
    /// such as archiving it from its detail), or when it's the one "Show this memory" asked for.
    public static func keepable(_ selection: Set<UUID>, sameListing: Bool, revealed: UUID?) -> UUID? {
        guard selection.count == 1, let single = selection.first else { return nil }
        return sameListing || single == revealed ? single : nil
    }

    /// The selection once a load listed `listed`: unchanged when it's still just `keepable` and
    /// that memory exists (in any status); otherwise only the listed ones stay.
    public static func after(_ selection: Set<UUID>, listed: [UUID], keepable: UUID?, exists: Bool) -> Set<UUID> {
        if let keepable, exists, selection == [keepable] { return selection }
        return selection.intersection(listed)
    }
}
