import Foundation
import FunesProtocol
import GRDB

/// A change between two of a memory's versions, for History and Activity (ADR-0027, FR-V-12,
/// FR-L-02): the version it replaced, from `memory_revision`, and the one it made.
public struct RevisionChange: Sendable, Hashable {
    public var memoryID: UUID
    /// The version the change replaced.
    public var version: Int
    public var at: Date
    /// `user`, `agent:<id>`, `device:<id>`, `import:<id>` or `system`, as in provenance.
    public var actor: String
    public var before: MemoryState
    /// The next version (the memory as it is now, for the latest change). Nil when that version
    /// isn't kept: earlier versions were off for a while.
    public var after: MemoryState?

    public init(memoryID: UUID, version: Int, at: Date, actor: String, before: MemoryState, after: MemoryState?) {
        self.memoryID = memoryID
        self.version = version
        self.at = at
        self.actor = actor
        self.before = before
        self.after = after
    }
}

/// Earlier versions of memories (ADR-0027): `MemoryStore.update` and `setStatus`, the only places
/// a version changes, keep the state they replace in the same transaction. Kept 90 days and at
/// most 50 per memory, purged with the memory. Never read by the policy engine, retrieval or
/// memory processing; never shared, exported or sent to the iPhone.
enum RevisionStore {
    static let lifetime: TimeInterval = 90 * 86_400
    static let perMemory = 50
    /// In `meta`: "0" once the user turned earlier versions off. Absent means on.
    static let keepKey = "keep_revisions"

    static func keeps(_ db: Database) throws -> Bool {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [keepKey]) != "0"
    }

    /// Keeps `old`, the memory as a change found it, unless earlier versions are off.
    static func record(_ db: Database, _ old: Memory, actor: Actor, at: Date) throws {
        guard try keeps(db) else { return }
        try db.execute(sql: """
            INSERT OR REPLACE INTO memory_revision
              (memory_id, version, title, body, kind, category_keys, sensitivity, status, expires_at, replaced_at, replaced_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [old.id.db, old.version, old.title, old.body, old.kind.rawValue, JSON.encode(old.categoryKeys),
                             old.sensitivity.rawValue, old.status.rawValue, old.expiresAt, at, actor.description])
    }

    /// A memory's changes, oldest first.
    static func changes(_ db: Database, memoryID: UUID) throws -> [RevisionChange] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM memory_revision WHERE memory_id = ? ORDER BY version",
                                    arguments: [memoryID.db])
        let current = try MemoryStore.fetch(db, id: memoryID)
        let revisions = rows.compactMap { row -> (version: Int, at: Date, actor: String, state: MemoryState)? in
            guard let kind = MemoryKind(rawValue: row["kind"]), let sensitivity = Sensitivity(rawValue: row["sensitivity"] as Int),
                  let status = MemoryStatus(rawValue: row["status"]) else { return nil }
            let state = MemoryState(title: row["title"], body: row["body"], kind: kind,
                                    categoryKeys: JSON.decode([String].self, row["category_keys"]) ?? [],
                                    sensitivity: sensitivity, status: status, expiresAt: row["expires_at"])
            return (row["version"], row["replaced_at"], row["replaced_by"], state)
        }
        return revisions.enumerated().map { i, r in
            let after: MemoryState? = if i + 1 < revisions.count {
                revisions[i + 1].version == r.version + 1 ? revisions[i + 1].state : nil
            } else {
                current.flatMap { $0.version == r.version + 1 ? MemoryState($0) : nil }
            }
            return RevisionChange(memoryID: memoryID, version: r.version, at: r.at, actor: r.actor, before: r.state, after: after)
        }
    }

    /// The daily job (storage §5): versions past 90 days, and each memory's oldest beyond 50.
    static func cleanup(_ db: Database, now: Date) throws -> Int {
        try db.execute(sql: "DELETE FROM memory_revision WHERE replaced_at <= ?", arguments: [now - lifetime])
        var removed = db.changesCount
        try db.execute(sql: """
            DELETE FROM memory_revision WHERE rowid IN (
              SELECT rowid FROM (
                SELECT rowid, ROW_NUMBER() OVER (PARTITION BY memory_id ORDER BY version DESC) AS n FROM memory_revision)
              WHERE n > ?)
            """, arguments: [perMemory])
        removed += db.changesCount
        return removed
    }
}

// MARK: - Public store API

extension VaultStore {
    /// A memory's changes whose earlier version is kept, oldest first (ADR-0027).
    public func revisionChanges(memoryID: UUID) throws -> [RevisionChange] {
        try writer.read { db in try RevisionStore.changes(db, memoryID: memoryID) }
    }

    /// Whether changes keep the version they replace (on unless the user turned it off).
    public func keepsEarlierVersions() throws -> Bool {
        try writer.read { db in try RevisionStore.keeps(db) }
    }

    /// Turns earlier versions on or off; off deletes every one kept so far.
    public func setKeepsEarlierVersions(_ on: Bool) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [RevisionStore.keepKey, on ? "1" : "0"])
            if !on { try db.execute(sql: "DELETE FROM memory_revision") }
        }
    }

    /// Forget Earlier Versions: deletes this memory's. Returns how many.
    @discardableResult
    public func forgetEarlierVersions(memoryID: UUID) throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM memory_revision WHERE memory_id = ?", arguments: [memoryID.db])
            return db.changesCount
        }
    }

    /// The daily cleanup (storage §5). Returns how many versions it deleted.
    @discardableResult
    public func cleanUpEarlierVersions(now: Date) async throws -> Int {
        try await writer.write { db in try RevisionStore.cleanup(db, now: now) }
    }
}
