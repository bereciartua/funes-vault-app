import Foundation
import FunesProtocol
import GRDB

/// Restore from Backup brings back memories, never credentials or access settings (storage §5.1, T38). A backup holds the
/// agents' key and remote-token digests, their access and the paired devices as they were then, and
/// authentication trusts the digests in the database, so restoring it as is would let back in a key,
/// token or device removed or reset since, and widen access narrowed since.
///
/// So before the copy replaces the vault, it's migrated to this version's schema, and its agents,
/// access, remote tokens and devices are replaced by those of the vault it replaces (the
/// `pre-restore-…` snapshot): who can get in, and what they may read, stays as it is now. Without
/// that vault to copy from (no vault, or another vault's backup), every agent is removed and every
/// device revoked; they're set up again. Either way, nothing waiting for an answer in the backup
/// can be answered or delivered again.
enum RestoreAccess {
    /// Rewrites `incoming` in place; `current` is the snapshot of the vault being replaced, if any.
    /// The snapshot itself is never written: it's read from a migrated copy next to `incoming`.
    /// Throws, leaving the vault untouched, when either is from a newer version or can't be read.
    static func prepare(_ incoming: URL, current: URL?, now: Date) throws {
        var live: URL?
        if let current {
            let copy = incoming.deletingLastPathComponent().appending(path: incoming.lastPathComponent + "-current")
            removeWithSidecars(copy)
            live = copy
            try FileManager.default.copyItem(at: current, to: copy)
            _ = chmod(copy.path, 0o600)
        }
        defer { if let live { removeWithSidecars(live) } }
        if let live { try migrated(live).close() }
        let queue = try migrated(incoming)
        do {
            try rewrite(queue, live: live, now: now)
        } catch {
            try? queue.close()
            throw error
        }
        try queue.close()
    }

    /// Deletes a database file and any journal, WAL or shared-memory file beside it, so a later
    /// file under the same name is never paired with a stale hot journal.
    static func removeWithSidecars(_ url: URL) {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appending(path: url.lastPathComponent + suffix))
        }
    }

    private static func rewrite(_ queue: DatabaseQueue, live current: URL?, now: Date) throws {
        try queue.writeWithoutTransaction { db in
            var sameVault = false
            if let current {
                try db.execute(sql: "ATTACH DATABASE ? AS live", arguments: [current.path])
                let ids = try ["main", "live"].map { schema in
                    try String.fetchOne(db, sql: "SELECT value FROM \(schema).meta WHERE key = 'vault_id'")
                }
                sameVault = ids[0] != nil && ids[0] == ids[1]
            }
            try db.inTransaction {
                // Every restored agent and device starts shut out. One the live vault doesn't have
                // stays that way, and the unique indexes (active names, key digests) never see two
                // holders while the live rows are copied in.
                try db.execute(sql: """
                    UPDATE agent SET key_digest = NULL, removed_at = COALESCE(removed_at, ?), paused = 0, cloud_access = 0,
                      remote_key_digest = NULL, remote_key_issued_at = NULL
                    """, arguments: [now])
                try db.execute(sql: "UPDATE device SET revoked_at = COALESCE(revoked_at, ?)", arguments: [now])
                try db.execute(sql: "DELETE FROM access")
                try db.execute(sql: "DELETE FROM access_profile_field")
                if sameVault {
                    // Categories the backup lacks come along, so every live rule applies as is:
                    // dropping an allow would widen the list (an empty one allows every category).
                    try copy(db, "category", where: "key NOT IN (SELECT key FROM main.category)")
                    try upsert(db, "agent")
                    try copy(db, "access")
                    try copy(db, "access_profile_field")
                    try db.execute(sql: "DELETE FROM access_category")
                    try copy(db, "access_category")
                    // A category deleted since comes back with the backup's memories, but its rules
                    // can't be rebuilt: deleting it moved its memories, and their denies, elsewhere.
                    // So every agent is denied it until the user decides.
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO access_category (agent_id, category_key, mode)
                        SELECT agent.id, category.key, 'deny' FROM agent, category WHERE category.key NOT IN (SELECT key FROM live.category)
                        """)
                    try upsert(db, "device")
                    // The never-share categories, which agents added from now on start with.
                    try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [AgentService.neverShareKey])
                    try db.execute(sql: "INSERT INTO meta (key, value) SELECT key, value FROM live.meta WHERE key = ?",
                                   arguments: [AgentService.neverShareKey])
                } else {
                    try db.execute(sql: "DELETE FROM access_category")
                }
                // Removed agents keep an access row with no access, as AgentService.remove leaves them.
                try db.execute(sql: "INSERT OR IGNORE INTO access (agent_id) SELECT id FROM agent")
                // A request waiting in the backup was answered, delivered or expired since: an approved
                // one must not be delivered a second time (single use).
                try db.execute(sql: """
                    UPDATE disclosure SET status = 'denied', reason = ?, decided_at = COALESCE(decided_at, ?)
                    WHERE status IN ('needs_approval', 'approved')
                    """, arguments: [ReasonCode.approvalExpired.rawValue, now])
                return .commit
            }
            if current != nil { try db.execute(sql: "DETACH DATABASE live") }
        }
    }

    /// Opens `url` in rollback-journal mode (so every change is in the file itself when it's closed)
    /// and migrates it to this version's schema, refusing a newer one.
    private static func migrated(_ url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode = DELETE") }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        do {
            if try queue.read({ db in try Schema.migrator.hasBeenSuperseded(db) }) { throw VaultError.newerSchema }
            try Schema.migrator.migrate(queue)
        } catch {
            try? queue.close()
            throw error
        }
        return queue
    }

    private static func columns(_ db: Database, _ table: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?, 'main')", arguments: [table]).map { "\"\($0)\"" }
    }

    /// Inserts the live vault's rows of `table` that aren't there yet. Both files are at the same
    /// schema, so the columns match.
    private static func copy(_ db: Database, _ table: String, where filter: String = "true") throws {
        let list = try columns(db, table).joined(separator: ", ")
        try db.execute(sql: "INSERT OR IGNORE INTO main.\(table) (\(list)) SELECT \(list) FROM live.\(table) WHERE \(filter)")
    }

    /// Writes every live row of `table` over the restored one with the same `id`, or adds it. Rows
    /// are never deleted: disclosures, suggestions and receipts point at them.
    private static func upsert(_ db: Database, _ table: String) throws {
        let columns = try columns(db, table)
        let list = columns.joined(separator: ", ")
        let updates = columns.filter { $0 != "\"id\"" }.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        try db.execute(sql: "INSERT INTO main.\(table) (\(list)) SELECT \(list) FROM live.\(table) WHERE true ON CONFLICT(id) DO UPDATE SET \(updates)")
    }
}
