import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 4b, task 4b.7: Allow cloud access and the remote token (ADR-0018, domain model `Agent`).
@Suite struct CloudAccessTests {
    @Test func remoteKeysHaveTheirOwnPrefix() throws {
        let issuer = LocalAgentKeyIssuer()
        let key = try issuer.issueRemote()
        #expect(key.plaintext.hasPrefix("fns_mcpr_v1_") && key.plaintext.count == 12 + 64)
        #expect(key.digest == issuer.digest(of: key.plaintext))
        #expect(SecretScanner.scan(key.plaintext).contains(.funesOrEKBKey))
    }

    @Test func offByDefaultAndMigrated() async throws {
        let (v, agents, _) = try AgentServiceTests.make()
        let (agent, _) = try await agents.create(name: "claude.ai", kind: .other, now: t0)
        #expect(agent.cloudAccess == false && agent.remoteKeyIssuedAt == nil && !agent.hasRemoteKey)
        let columns = try await v.store.writer.read { db in try db.columns(in: "agent").map(\.name) }
        #expect(Set(["cloud_access", "remote_key_digest", "remote_key_issued_at"]).isSubset(of: Set(columns)))
    }

    /// Storage §3: a v1 vault with an agent migrates to v2 with a backup first; the agent keeps its
    /// key and access, and gets cloud access off.
    @Test func migratesAVersion1Vault() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "funes-v1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "vault.sqlite")
        let agentID = UUID()
        do {
            let queue = try DatabaseQueue(path: file.path)
            try Schema.migrator.migrate(queue, upTo: "v1_initial")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO agent (id, name, agent_kind, key_digest, key_issued_at, created_at)
                    VALUES (?, 'Claude Code', 'claude_code', ?, ?, ?)
                    """, arguments: [agentID.db, Data(repeating: 7, count: 32), t0, t0])
                try db.execute(sql: "INSERT INTO access (agent_id, op_read, max_sensitivity) VALUES (?, 1, 2)",
                               arguments: [agentID.db])
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = try VaultStore.open(directory: directory)
        let agent = try #require(try store.agent(id: agentID))
        #expect(agent.name == "Claude Code" && agent.access.operations == [.read] && !agent.cloudAccess && !agent.hasRemoteKey)
        let applied = try store.writer.read { db in try Schema.migrator.appliedIdentifiers(db) }
        #expect(applied.contains("v2_remote_access"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Backups").path)
        #expect(backups.contains { $0.hasPrefix("pre-v2_remote_access") })
    }

    @Test func aRemoteKeyNeedsCloudAccess() async throws {
        let (v, agents, keys) = try AgentServiceTests.make()
        defer { withExtendedLifetime(v) {} }
        let (agent, _) = try await agents.create(name: "ChatGPT", kind: .other, now: t0)
        await #expect(throws: VaultError.invalidState) { try await agents.issueRemoteKey(agentID: agent.id, now: t0) }
        #expect(keys.remoteKey(agentID: agent.id) == nil)
    }

    @Test func issueAuthenticateAndReset() async throws {
        let (v, agents, keys) = try AgentServiceTests.make()
        let (agent, local) = try await agents.create(name: "Anthropic API", kind: .other, now: t0)
        let on = try await agents.setCloudAccess(agentID: agent.id, true, now: t0)
        #expect(on.cloudAccess && on.revision == agent.revision + 1)
        let first = try await agents.issueRemoteKey(agentID: agent.id, now: t0)
        #expect(keys.remoteKey(agentID: agent.id) == first.plaintext)
        #expect(try await agents.authenticate(remoteKeyDigest: first.digest)?.id == agent.id)
        // Only the digest is stored.
        let dump = try await v.store.writer.read { db in try String(describing: Row.fetchAll(db, sql: "SELECT * FROM agent")) }
        #expect(!dump.contains(first.plaintext) && !dump.contains(String(first.plaintext.dropFirst(12))))
        // Local and remote keys never stand in for each other.
        #expect(try await agents.authenticate(remoteKeyDigest: local.digest) == nil)
        #expect(try await agents.authenticate(keyDigest: first.digest) == nil)
        // Reset: the old one stops at once, and the revision goes up.
        let before = try #require(try await agents.agent(id: agent.id)).revision
        let second = try await agents.issueRemoteKey(agentID: agent.id, now: t0)
        #expect(try await agents.authenticate(remoteKeyDigest: first.digest) == nil)
        #expect(try await agents.authenticate(remoteKeyDigest: second.digest)?.id == agent.id)
        let after = try #require(try await agents.agent(id: agent.id))
        #expect(after.revision == before + 1 && after.hasRemoteKey && after.remoteKeyIssuedAt == t0)
    }

    @Test func turningCloudAccessOffDeletesTheToken() async throws {
        let (v, agents, keys) = try AgentServiceTests.make()
        let (agent, _) = try await agents.create(name: "Devin", kind: .other, now: t0)
        try await agents.setCloudAccess(agentID: agent.id, true, now: t0)
        let key = try await agents.issueRemoteKey(agentID: agent.id, now: t0)
        let off = try await agents.setCloudAccess(agentID: agent.id, false, now: t0)
        #expect(!off.cloudAccess && !off.hasRemoteKey && keys.remoteKey(agentID: agent.id) == nil)
        #expect(try await agents.authenticate(remoteKeyDigest: key.digest) == nil)
        #expect(try v.count("SELECT count(*) FROM agent WHERE remote_key_digest IS NOT NULL") == 0)
        // Back on: no token until a new one is issued.
        try await agents.setCloudAccess(agentID: agent.id, true, now: t0)
        #expect(try await agents.authenticate(remoteKeyDigest: key.digest) == nil)
        // Access is never touched by cloud access.
        #expect(try await agents.agent(id: agent.id)?.access == agent.access)
    }

    @Test func removalEndsEverything() async throws {
        let (v, agents, keys) = try AgentServiceTests.make()
        defer { withExtendedLifetime(v) {} }
        let (agent, _) = try await agents.create(name: "Cursor cloud", kind: .cursor, now: t0)
        try await agents.setCloudAccess(agentID: agent.id, true, now: t0)
        let key = try await agents.issueRemoteKey(agentID: agent.id, now: t0)
        try await agents.remove(agentID: agent.id, now: t0)
        #expect(try await agents.authenticate(remoteKeyDigest: key.digest) == nil)
        #expect(keys.remoteKey(agentID: agent.id) == nil)
        let removed = try #require(try await agents.agent(id: agent.id))
        #expect(!removed.cloudAccess && !removed.hasRemoteKey)
    }

    @Test func connectedAppsBumpTheRevision() async throws {
        let (v, agents, _) = try AgentServiceTests.make()
        defer { withExtendedLifetime(v) {} }
        let (agent, _) = try await agents.create(name: "Gemini", kind: .other, now: t0)
        let changed = try await agents.cloudAppsChanged(agentID: agent.id, now: t0)
        #expect(changed.revision == agent.revision + 1)
    }
}
