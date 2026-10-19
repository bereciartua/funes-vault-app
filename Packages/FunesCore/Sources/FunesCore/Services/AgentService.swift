import CryptoKit
import Foundation
import FunesProtocol
import GRDB
import Security
import Synchronization

/// A freshly issued agent key. The plaintext is shown once (it goes to the key file) and never
/// stored in the vault; only the digest is.
public struct IssuedKey: Sendable, Hashable {
    public let plaintext: String
    public let digest: Data

    public init(plaintext: String, digest: Data) {
        self.plaintext = plaintext
        self.digest = digest
    }
}

/// Issues and digests agent MCP keys (`fns_mcp_v1_` + 64 hex characters; NFR-SEC-03).
/// BridgeKitCore provides the shared implementation from Phase 2; until then FunesCore uses
/// `LocalAgentKeyIssuer`, and swaps it for BridgeKitCore's when that lands.
public protocol AgentKeyIssuer: Sendable {
    func issue() throws -> IssuedKey
    /// A remote token for Remote Access (`fns_mcpr_v1_` + 64 hex; ADR-0018).
    func issueRemote() throws -> IssuedKey
    /// The digest a presented key is looked up by.
    func digest(of key: String) -> Data
}

/// 32 random bytes from the system CSPRNG, hex-encoded after the prefix; SHA-256 digest.
public struct LocalAgentKeyIssuer: AgentKeyIssuer {
    public init() {}

    public func issue() throws -> IssuedKey { try issue(prefix: Identifiers.mcpKeyPrefix) }

    public func issueRemote() throws -> IssuedKey { try issue(prefix: Identifiers.remoteKeyPrefix) }

    private func issue(prefix: String) throws -> IssuedKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw VaultError.invalidState }
        let key = prefix + bytes.map { String(format: "%02x", $0) }.joined()
        return IssuedKey(plaintext: key, digest: digest(of: key))
    }

    public func digest(of key: String) -> Data { Data(SHA256.hash(data: Data(key.utf8))) }
}

/// Where the plaintext keys live: `agent-keys/<agentId>.key`, and the remote token in
/// `agent-keys/<agentId>.remote.key`, written once and deleted on removal (storage §1). FunesMCP
/// provides the file implementation (BridgeKit's safe files).
public protocol AgentKeyStore: Sendable {
    func write(_ key: String, agentID: UUID) throws
    func delete(agentID: UUID) throws
    func writeRemote(_ key: String, agentID: UUID) throws
    /// No file is not an error.
    func deleteRemote(agentID: UUID) throws
}

/// Keeps keys in memory, for tests.
public final class InMemoryAgentKeyStore: AgentKeyStore {
    private let keys = Mutex<[UUID: String]>([:])
    private let remoteKeys = Mutex<[UUID: String]>([:])
    public init() {}
    public func write(_ key: String, agentID: UUID) throws { keys.withLock { $0[agentID] = key } }
    public func delete(agentID: UUID) throws { keys.withLock { _ = $0.removeValue(forKey: agentID) } }
    public func key(agentID: UUID) -> String? { keys.withLock { $0[agentID] } }
    public func writeRemote(_ key: String, agentID: UUID) throws { remoteKeys.withLock { $0[agentID] = key } }
    public func deleteRemote(agentID: UUID) throws { remoteKeys.withLock { _ = $0.removeValue(forKey: agentID) } }
    public func remoteKey(agentID: UUID) -> String? { remoteKeys.withLock { $0[agentID] } }
}

/// Adding, configuring, pausing, removing and authenticating agents (FR-A-01..12). Every change to
/// access, pause or key increments the revision, which invalidates pending approvals (FR-A-03).
public final class AgentService: Sendable {
    public let store: VaultStore
    public let issuer: any AgentKeyIssuer
    public let keys: any AgentKeyStore
    public let activity: any ActivityRecorder

    public init(store: VaultStore, issuer: any AgentKeyIssuer = LocalAgentKeyIssuer(), keys: any AgentKeyStore,
                activity: any ActivityRecorder) {
        self.store = store
        self.issuer = issuer
        self.keys = keys
        self.activity = activity
    }

    public func agent(id: UUID) async throws -> Agent? {
        try await store.writer.read { db in try AgentStore.fetch(db, id: id) }
    }

    /// Active agents, oldest first; with removed ones for Activity labels if asked.
    public func agents(includingRemoved: Bool = false) async throws -> [Agent] {
        try await store.writer.read { db in try AgentStore.all(db, includingRemoved: includingRemoved) }
    }

    /// Adds an agent with its own key (FR-A-01). It has no access unless a preset says otherwise.
    /// Returns the agent and the key's plaintext, shown once.
    public func create(name: String, kind: AgentKind, access: Access = Access(), declaredRetention: Retention = .unknown,
                       asksForAccess: Bool = false, now: Date) async throws -> (Agent, IssuedKey) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(InputLimits.length(of: name)) else { throw VaultError.invalidInput(field: "name") }
        let key = try issuer.issue()
        let agent = Agent(id: UUID(), name: name, agentKind: kind, keyIssuedAt: now, paused: false, revision: 1,
                          declaredRetention: declaredRetention, asksForAccess: asksForAccess, createdAt: now, access: access)
        try await store.writer.write { db in
            if try Bool.fetchOne(db, sql: "SELECT 1 FROM agent WHERE name = ? AND removed_at IS NULL", arguments: [name]) == true {
                throw VaultError.nameTaken
            }
            try AgentStore.insert(db, agent, keyDigest: key.digest)
        }
        try keys.write(key.plaintext, agentID: agent.id)
        activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "agent_added", ids: [agent.id]))
        return (agent, key)
    }

    /// Replaces the access (FR-A-03). Revision +1 even if nothing changed: the user saved.
    /// `expectedRevision` is the revision the editor read: if the access changed since (another
    /// window, Always Allow), nothing is written and it throws `revisionChanged` (fail closed).
    @discardableResult
    public func updateAccess(agentID: UUID, _ access: Access, expectedRevision: Int? = nil, now: Date) async throws -> Agent {
        try await change(agentID, event: "access_changed", now: now) { db in
            if let expectedRevision {
                guard let current = try AgentStore.fetch(db, id: agentID), current.revision == expectedRevision else {
                    throw VaultError.revisionChanged
                }
            }
            try AgentStore.writeAccess(db, agentID: agentID, access)
        }
    }

    /// "Always Allow" from an access request (§7): adds exactly that category to the allow list.
    @discardableResult
    public func allowCategory(agentID: UUID, _ key: String, now: Date) async throws -> Agent {
        try await change(agentID, event: "access_changed", now: now) { db in
            guard var access = try AgentStore.fetch(db, id: agentID)?.access else { throw VaultError.notFound }
            access.allowedCategoryKeys.insert(key)
            try AgentStore.writeAccess(db, agentID: agentID, access)
        }
    }

    /// "Always Allow" for a missing operation (§7).
    @discardableResult
    public func allowOperation(agentID: UUID, _ operation: AccessOperation, now: Date) async throws -> Agent {
        try await change(agentID, event: "access_changed", now: now) { db in
            guard var access = try AgentStore.fetch(db, id: agentID)?.access else { throw VaultError.notFound }
            access.operations.insert(operation)
            try AgentStore.writeAccess(db, agentID: agentID, access)
        }
    }

    @discardableResult
    public func pause(agentID: UUID, now: Date) async throws -> Agent {
        try await change(agentID, event: "agent_paused", now: now) { db in
            try db.execute(sql: "UPDATE agent SET paused = 1 WHERE id = ?", arguments: [agentID.db])
        }
    }

    @discardableResult
    public func resume(agentID: UUID, now: Date) async throws -> Agent {
        try await change(agentID, event: "agent_resumed", now: now) { db in
            try db.execute(sql: "UPDATE agent SET paused = 0 WHERE id = ?", arguments: [agentID.db])
        }
    }

    /// Informational fields: not part of the access, so no revision change.
    public func update(agentID: UUID, name: String? = nil, declaredRetention: Retention? = nil, asksForAccess: Bool? = nil) async throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !(1...64).contains(InputLimits.length(of: trimmed)) { throw VaultError.invalidInput(field: "name") }
        try await store.writer.write { db in
            guard let agent = try AgentStore.fetch(db, id: agentID), !agent.isRemoved else { throw VaultError.notFound }
            if let trimmed, trimmed != agent.name,
               try Bool.fetchOne(db, sql: "SELECT 1 FROM agent WHERE name = ? AND removed_at IS NULL", arguments: [trimmed]) == true {
                throw VaultError.nameTaken
            }
            try db.execute(sql: """
                UPDATE agent SET name = COALESCE(?, name), declared_retention = COALESCE(?, declared_retention),
                  asks_for_access = COALESCE(?, asks_for_access) WHERE id = ?
                """, arguments: [trimmed, declaredRetention?.rawValue, asksForAccess, agentID.db])
        }
    }

    /// Issues a new key and invalidates the old one at once (FR-A-06).
    public func rotateKey(agentID: UUID, now: Date) async throws -> IssuedKey {
        let key = try issuer.issue()
        try await change(agentID, event: "key_rotated", now: now) { db in
            try db.execute(sql: "UPDATE agent SET key_digest = ?, key_issued_at = ? WHERE id = ?",
                           arguments: [key.digest, now, agentID.db])
        }
        try keys.write(key.plaintext, agentID: agentID)
        return key
    }

    /// Deletes the keys and grants at once (FR-A-05), the remote token and cloud access too. The row
    /// stays, labelled "removed agent". The app revokes its connected cloud apps.
    public func remove(agentID: UUID, now: Date) async throws {
        try await change(agentID, event: "agent_removed", now: now) { db in
            try db.execute(sql: """
                UPDATE agent SET key_digest = NULL, removed_at = ?, paused = 0, cloud_access = 0,
                  remote_key_digest = NULL, remote_key_issued_at = NULL WHERE id = ?
                """, arguments: [now, agentID.db])
            try AgentStore.writeAccess(db, agentID: agentID, Access())
        }
        try keys.delete(agentID: agentID)
        try keys.deleteRemote(agentID: agentID)
    }

    // MARK: - Remote Access (ADR-0018)

    /// Allow cloud access. Off deletes the remote token at once (the app revokes the agent's
    /// connected cloud apps). Either way the revision goes up. The access itself never changes.
    @discardableResult
    public func setCloudAccess(agentID: UUID, _ on: Bool, now: Date) async throws -> Agent {
        let agent = try await change(agentID, event: on ? "cloud_access_on" : "cloud_access_off", now: now) { db in
            if on {
                try db.execute(sql: "UPDATE agent SET cloud_access = 1 WHERE id = ?", arguments: [agentID.db])
            } else {
                try db.execute(sql: """
                    UPDATE agent SET cloud_access = 0, remote_key_digest = NULL, remote_key_issued_at = NULL WHERE id = ?
                    """, arguments: [agentID.db])
            }
        }
        if !on { try keys.deleteRemote(agentID: agentID) }
        return agent
    }

    /// Issues the agent's remote token, replacing any earlier one at once (Copy Remote Token… the
    /// first time, Reset Remote Token… after). Needs cloud access. The plaintext goes to
    /// `agent-keys/<agentId>.remote.key`; the vault keeps only its digest.
    public func issueRemoteKey(agentID: UUID, now: Date) async throws -> IssuedKey {
        let key = try issuer.issueRemote()
        try await change(agentID, event: "remote_key_issued", now: now) { db in
            guard try AgentStore.fetch(db, id: agentID)?.cloudAccess == true else { throw VaultError.invalidState }
            try db.execute(sql: "UPDATE agent SET remote_key_digest = ?, remote_key_issued_at = ? WHERE id = ?",
                           arguments: [key.digest, now, agentID.db])
        }
        try keys.writeRemote(key.plaintext, agentID: agentID)
        return key
    }

    /// A cloud app connected or was revoked (OAuth): the revision goes up, so pending approvals
    /// made under the old set of credentials end (domain model, `revision`).
    @discardableResult
    public func cloudAppsChanged(agentID: UUID, now: Date) async throws -> Agent {
        try await change(agentID, event: "cloud_apps_changed", now: now) { _ in }
    }

    /// The agent a presented remote token belongs to, or nil (HTTP 401). Only agents with cloud
    /// access on match; removed agents have no digest.
    public func authenticate(remoteKeyDigest: Data) async throws -> Agent? {
        try await store.writer.read { db in try AgentStore.fetch(db, remoteKeyDigest: remoteKeyDigest) }
            .flatMap { $0.isRemoved || !$0.cloudAccess ? nil : $0 }
    }

    /// The agent a presented key belongs to, or nil (HTTP 401). Removed agents have no digest.
    public func authenticate(key: String) async throws -> Agent? {
        guard key.hasPrefix(Identifiers.mcpKeyPrefix) else { return nil }
        return try await authenticate(keyDigest: issuer.digest(of: key))
    }

    public func authenticate(keyDigest: Data) async throws -> Agent? {
        try await store.writer.read { db in try AgentStore.fetch(db, keyDigest: keyDigest) }.flatMap { $0.isRemoved ? nil : $0 }
    }

    @discardableResult
    private func change(_ agentID: UUID, event: String, now: Date,
                        _ body: @escaping @Sendable (Database) throws -> Void) async throws -> Agent {
        let agent = try await store.writer.write { db -> Agent in
            guard let agent = try AgentStore.fetch(db, id: agentID), !agent.isRemoved else { throw VaultError.notFound }
            try body(db)
            try AgentStore.bumpRevision(db, agentID: agentID)
            return try AgentStore.fetch(db, id: agentID) ?? agent
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: event, ids: [agentID]))
        return agent
    }
}
