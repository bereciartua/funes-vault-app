import Foundation
import FunesProtocol
import GRDB

/// Agent and access rows (storage §2). AgentService is the public API.
enum AgentStore {
    static func fetch(_ db: Database, id: UUID) throws -> Agent? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT agent.*, access.op_read, access.op_suggest, access.op_write, access.max_sensitivity,
              access.ask_before_sharing, access.ask_before_saving, access.expires_at AS access_expires_at
            FROM agent LEFT JOIN access ON access.agent_id = agent.id WHERE agent.id = ?
            """, arguments: [id.db]) else { return nil }
        return try agent(db, row: row)
    }

    static func fetch(_ db: Database, keyDigest: Data) throws -> Agent? {
        guard let id = try String.fetchOne(db, sql: "SELECT id FROM agent WHERE key_digest = ? AND removed_at IS NULL",
                                           arguments: [keyDigest]).flatMap(UUID.init(uuidString:)) else { return nil }
        return try fetch(db, id: id)
    }

    /// Only agents with cloud access on: a remote token never works without it.
    static func fetch(_ db: Database, remoteKeyDigest: Data) throws -> Agent? {
        guard let id = try String.fetchOne(db, sql: """
            SELECT id FROM agent WHERE remote_key_digest = ? AND cloud_access = 1 AND removed_at IS NULL
            """, arguments: [remoteKeyDigest]).flatMap(UUID.init(uuidString:)) else { return nil }
        return try fetch(db, id: id)
    }

    static func all(_ db: Database, includingRemoved: Bool = false) throws -> [Agent] {
        try String.fetchAll(db, sql: "SELECT id FROM agent \(includingRemoved ? "" : "WHERE removed_at IS NULL") ORDER BY created_at, id")
            .compactMap(UUID.init(uuidString:)).compactMap { try fetch(db, id: $0) }
    }

    private static func agent(_ db: Database, row: Row) throws -> Agent {
        let id = try row.requiredUUID("id")
        var allowed = Set<String>(), denied = Set<String>()
        for r in try Row.fetchAll(db, sql: "SELECT category_key, mode FROM access_category WHERE agent_id = ?", arguments: [id.db]) {
            if (r["mode"] as String) == "allow" { allowed.insert(r["category_key"]) } else { denied.insert(r["category_key"]) }
        }
        var ops = Set<AccessOperation>()
        if row["op_read"] as Bool? == true { ops.insert(.read) }
        if row["op_suggest"] as Bool? == true { ops.insert(.suggest) }
        if row["op_write"] as Bool? == true { ops.insert(.write) }
        // A missing access row is no access (fail closed).
        let access = Access(operations: ops, maxSensitivity: row.sensitivity("max_sensitivity") ?? .public,
                            allowedCategoryKeys: allowed, deniedCategoryKeys: denied,
                            askBeforeSharing: row["ask_before_sharing"] as Bool? ?? true,
                            askBeforeSaving: row["ask_before_saving"] as Bool? ?? true,
                            expiresAt: row["access_expires_at"])
        // A digest without cloud access can't be used; it isn't shown as a token either.
        let cloud: Bool = row["cloud_access"] ?? false
        let remoteDigest: Data? = row["remote_key_digest"]
        return Agent(id: id, name: row["name"], agentKind: row.enumValue("agent_kind") ?? .other,
                     keyIssuedAt: row["key_issued_at"], paused: row["paused"], revision: row["revision"],
                     declaredRetention: row.enumValue("declared_retention") ?? .unknown,
                     asksForAccess: row["asks_for_access"], firstRequestAt: row["first_request_at"],
                     lastRequestAt: row["last_request_at"], createdAt: row["created_at"], removedAt: row["removed_at"],
                     access: access, cloudAccess: cloud,
                     remoteKeyIssuedAt: cloud && remoteDigest != nil ? row["remote_key_issued_at"] : nil)
    }

    static func insert(_ db: Database, _ agent: Agent, keyDigest: Data?) throws {
        try db.execute(sql: """
            INSERT INTO agent (id, name, agent_kind, key_digest, key_issued_at, paused, revision, declared_retention,
              asks_for_access, created_at, cloud_access) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [agent.id.db, agent.name, agent.agentKind.rawValue, keyDigest, agent.keyIssuedAt, agent.paused,
                             agent.revision, agent.declaredRetention.rawValue, agent.asksForAccess, agent.createdAt,
                             agent.cloudAccess])
        try writeAccess(db, agentID: agent.id, agent.access)
    }

    /// Replaces the access row and category lists. Unknown category keys are refused.
    static func writeAccess(_ db: Database, agentID: UUID, _ access: Access) throws {
        let keys = access.allowedCategoryKeys.union(access.deniedCategoryKeys)
        if !keys.isEmpty {
            let known = Set(try String.fetchAll(db, sql: "SELECT key FROM category"))
            if let unknown = keys.sorted().first(where: { !known.contains($0) }) { throw VaultError.unknownCategory(unknown) }
        }
        try db.execute(sql: """
            INSERT OR REPLACE INTO access (agent_id, op_read, op_suggest, op_write, max_sensitivity, ask_before_sharing,
              ask_before_saving, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [agentID.db, access.operations.contains(.read), access.operations.contains(.suggest),
                             access.operations.contains(.write), access.maxSensitivity.rawValue, access.askBeforeSharing,
                             access.askBeforeSaving, access.expiresAt])
        try db.execute(sql: "DELETE FROM access_category WHERE agent_id = ?", arguments: [agentID.db])
        // A key may be on both lists; the policy lets deny win (T8).
        for key in access.deniedCategoryKeys.sorted() {
            try db.execute(sql: "INSERT INTO access_category (agent_id, category_key, mode) VALUES (?, ?, 'deny')",
                           arguments: [agentID.db, key])
        }
        for key in access.allowedCategoryKeys.sorted() {
            try db.execute(sql: "INSERT INTO access_category (agent_id, category_key, mode) VALUES (?, ?, 'allow')",
                           arguments: [agentID.db, key])
        }
    }

    static func bumpRevision(_ db: Database, agentID: UUID) throws {
        try db.execute(sql: "UPDATE agent SET revision = revision + 1 WHERE id = ?", arguments: [agentID.db])
    }

    /// FR-A-09: first and last authenticated request.
    static func recordRequest(_ db: Database, agentID: UUID, now: Date) throws {
        try db.execute(sql: "UPDATE agent SET first_request_at = COALESCE(first_request_at, ?), last_request_at = ? WHERE id = ?",
                       arguments: [now, now, agentID.db])
    }
}

extension VaultStore {
    /// One agent, removed ones included; a quick synchronous read (the MCP tool list is computed on
    /// the main actor).
    public func agent(id: UUID) throws -> Agent? {
        try writer.read { db in try AgentStore.fetch(db, id: id) }
    }
}
