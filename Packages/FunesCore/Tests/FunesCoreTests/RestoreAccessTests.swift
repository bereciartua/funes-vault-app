import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// T38: Restore from Backup brings back memories, never credentials or access settings. The restored vault keeps the
/// current vault's agents, access, remote tokens and devices (storage §5.1).
@Suite struct RestoreAccessTests {
    /// A vault folder with its store, agents and a backup taken at `t0`.
    final class Folder: @unchecked Sendable {
        let directory: URL
        var store: VaultStore
        var agents: AgentService

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "restore-access-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            store = try VaultStore.open(directory: directory)
            agents = AgentService(store: store, keys: InMemoryAgentKeyStore(), activity: InMemoryActivityLog())
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        var backups: URL { directory.appending(path: "Backups") }

        func backUp() throws -> String { try store.dailyBackup(into: backups, now: t0).lastPathComponent }

        /// Restores `name` as the app does at launch, with the vault closed, then opens the result.
        func restore(_ name: String) throws {
            try store.writer.close()
            try VaultStore.restoreBackup(name, in: directory, now: t0.plus(days: 1))
            store = try VaultStore.open(directory: directory)
            agents = AgentService(store: store, keys: InMemoryAgentKeyStore(), activity: InMemoryActivityLog())
        }

        func execute(_ sql: String, _ arguments: StatementArguments = []) throws {
            try store.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
        }

        func value<T: DatabaseValueConvertible>(_ sql: String, _ arguments: StatementArguments = []) throws -> T? {
            try store.writer.read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
        }

        func addDevice(_ id: UUID) throws {
            try execute("""
                INSERT INTO device (id, name, model, signing_public_key, hpke_public_key, paired_at) VALUES (?, 'Phone', 'iPhone17,1', x'01', x'02', ?)
                """, [id.db, t0])
        }
    }

    @Test func removedAgentsAndReplacedKeysStayOut() async throws {
        let f = try Folder()
        let (removed, removedKey) = try await f.agents.create(name: "Removed", kind: .claudeCode, now: t0)
        let (rotated, oldKey) = try await f.agents.create(name: "Rotated", kind: .cursor, now: t0)
        let (paused, _) = try await f.agents.create(name: "Paused", kind: .zed, now: t0)
        let backup = try f.backUp()

        _ = try await f.agents.pause(agentID: paused.id, now: t0.plus(minutes: 1))
        try await f.agents.remove(agentID: removed.id, now: t0.plus(minutes: 1))
        let newKey = try await f.agents.rotateKey(agentID: rotated.id, now: t0.plus(minutes: 1))
        let (added, addedKey) = try await f.agents.create(name: "Added later", kind: .codex, now: t0.plus(minutes: 2))
        try f.restore(backup)

        #expect(try await f.agents.authenticate(key: removedKey.plaintext) == nil)
        #expect(try await f.agents.agent(id: removed.id)?.removedAt != nil)
        #expect(try await f.agents.authenticate(key: oldKey.plaintext) == nil)
        #expect(try await f.agents.authenticate(key: newKey.plaintext)?.id == rotated.id)
        // An agent added after the backup keeps working: its key file is still there.
        #expect(try await f.agents.authenticate(key: addedKey.plaintext)?.id == added.id)
        #expect(try await f.agents.agent(id: paused.id)?.paused == true)
    }

    /// GPT-6-Astra's review: a deny added after the backup moves to the replacement when its
    /// category is deleted, so the restored category would come back with no rule at all.
    @Test func aCategoryDeletedSinceIsDeniedToEveryAgent() async throws {
        let f = try Folder()
        _ = try f.store.createCategory(key: "old_projects", name: "Old projects")
        try f.store.createMemory(MemoryDraft(title: "Old", body: "An old project", categoryKeys: ["old_projects"]), now: t0)
        let (agent, _) = try await f.agents.create(name: "Claude", kind: .claudeCode, access: Access(operations: [.read]), now: t0)
        let backup = try f.backUp()

        var denied = try #require(try await f.agents.agent(id: agent.id)).access
        denied.deniedCategoryKeys = ["old_projects"]
        _ = try await f.agents.updateAccess(agentID: agent.id, denied, now: t0.plus(minutes: 1))
        try f.store.deleteCategory(key: "old_projects", replacement: "personal_preferences", now: t0.plus(minutes: 2))
        try f.restore(backup)

        let restored = try #require(try await f.agents.agent(id: agent.id)).access
        #expect(restored.allowedCategoryKeys.isEmpty)
        #expect(restored.deniedCategoryKeys == ["old_projects", "personal_preferences"])
    }

    @Test func aRemoteTokenReissuedSinceStaysReplaced() async throws {
        let f = try Folder()
        let (agent, _) = try await f.agents.create(name: "claude.ai", kind: .claudeAI, now: t0)
        _ = try await f.agents.setCloudAccess(agentID: agent.id, true, now: t0)
        let old = try await f.agents.issueRemoteKey(agentID: agent.id, now: t0)
        let backup = try f.backUp()

        let new = try await f.agents.issueRemoteKey(agentID: agent.id, now: t0.plus(minutes: 1))
        try f.restore(backup)

        #expect(try await f.agents.authenticate(remoteKeyDigest: old.digest) == nil)
        #expect(try await f.agents.authenticate(remoteKeyDigest: new.digest)?.id == agent.id)
    }

    /// GPT-6-Astra's review: a journal left by a restore that crashed midway must never be paired
    /// with the next copy, and the scratch files go.
    @Test func leftoversFromAnEarlierAttemptAreCleared() async throws {
        let f = try Folder()
        try f.store.createMemory(MemoryDraft(title: "Kept", body: "In the backup", categoryKeys: ["personal_preferences"]), now: t0)
        let backup = try f.backUp()
        for name in ["vault.sqlite.restoring", "vault.sqlite.restoring-journal", "vault.sqlite.restoring-current"] {
            try Data("left over".utf8).write(to: f.directory.appending(path: name))
        }
        try f.restore(backup)

        #expect(try f.value("SELECT count(*) FROM memory WHERE title = 'Kept'") == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: f.directory.path)
        #expect(!files.contains { $0.contains("restoring") }, "\(files)")
    }

    /// A backup from an older version is migrated before its agents are replaced.
    @Test func anOlderBackupIsMigratedFirst() async throws {
        let f = try Folder()
        let (agent, key) = try await f.agents.create(name: "Claude", kind: .claudeCode, now: t0)
        let vaultID: String = try #require(try f.value("SELECT value FROM meta WHERE key = 'vault_id'"))
        let old = f.backups.appending(path: "vault-old.sqlite")
        try FileManager.default.createDirectory(at: f.backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let queue = try DatabaseQueue(path: old.path)
        try Schema.migrator.migrate(queue, upTo: "v2_remote_access")
        try await queue.write { db in try db.execute(sql: "UPDATE meta SET value = ? WHERE key = 'vault_id'", arguments: [vaultID]) }
        try queue.close()
        try f.restore("vault-old.sqlite")

        #expect(try f.value("SELECT count(*) FROM sqlite_master WHERE name = 'memory_revision'") == 1)
        #expect(try await f.agents.authenticate(key: key.plaintext)?.id == agent.id)
    }

    @Test func accessStaysAsItIsNow() async throws {
        let f = try Folder()
        try f.execute("INSERT INTO category (key, name) VALUES ('old_projects', 'Old projects')")
        let everything = Access(operations: [.read, .suggest], maxSensitivity: .sensitive, deniedCategoryKeys: ["old_projects"],
                                askBeforeSharing: false, profileFields: [.name, .location])
        let (agent, _) = try await f.agents.create(name: "Claude", kind: .claudeCode, access: everything, now: t0)
        let backup = try f.backUp()

        // Since the backup: a new category, the agent narrowed to it, and the old category deleted
        // (which took the agent's deny on it along).
        try f.execute("INSERT INTO category (key, name) VALUES ('work_x', 'Work X')")
        let narrow = Access(operations: [.read], maxSensitivity: .low, allowedCategoryKeys: ["work_x"],
                            askBeforeSharing: true, profileFields: [.name])
        _ = try await f.agents.updateAccess(agentID: agent.id, narrow, now: t0.plus(minutes: 1))
        try f.execute("DELETE FROM category WHERE key = 'old_projects'")
        try f.restore(backup)

        let restored = try #require(try await f.agents.agent(id: agent.id))
        #expect(restored.access.operations == [.read] && restored.access.maxSensitivity == .low)
        #expect(restored.access.askBeforeSharing && restored.access.profileFields == [.name])
        // The allow list survives even though the backup had no such category: an empty list would
        // allow every category.
        #expect(restored.access.allowedCategoryKeys == ["work_x"])
        #expect(try f.value("SELECT name FROM category WHERE key = 'work_x'") == "Work X")
        // The backup brings its deleted category back, and the deny on it stays: it can only narrow.
        #expect(restored.access.deniedCategoryKeys == ["old_projects"])
    }

    @Test func cloudAccessTurnedOffStaysOff() async throws {
        let f = try Folder()
        let (agent, _) = try await f.agents.create(name: "claude.ai", kind: .claudeAI, now: t0)
        _ = try await f.agents.setCloudAccess(agentID: agent.id, true, now: t0)
        let token = try await f.agents.issueRemoteKey(agentID: agent.id, now: t0)
        let backup = try f.backUp()

        _ = try await f.agents.setCloudAccess(agentID: agent.id, false, now: t0.plus(minutes: 1))
        try f.restore(backup)

        #expect(try await f.agents.authenticate(remoteKeyDigest: token.digest) == nil)
        #expect(try await f.agents.agent(id: agent.id)?.cloudAccess == false)
    }

    @Test func devicesKeepTheirCurrentState() async throws {
        let f = try Folder()
        let revoked = UUID(), paired = UUID()
        try f.addDevice(revoked)
        let backup = try f.backUp()

        try f.execute("UPDATE device SET revoked_at = ? WHERE id = ?", [t0.plus(minutes: 1), revoked.db])
        try f.addDevice(paired)
        try f.restore(backup)

        #expect(try f.value("SELECT revoked_at FROM device WHERE id = ?", [revoked.db]) as Date? == t0.plus(minutes: 1))
        #expect(try f.value("SELECT count(*) FROM device WHERE id = ? AND revoked_at IS NULL", [paired.db]) == 1)
    }

    @Test func requestsWaitingInTheBackupEnd() async throws {
        let f = try Folder()
        let (agent, _) = try await f.agents.create(name: "Claude", kind: .claudeCode, now: t0)
        for status in ["needs_approval", "approved", "delivered"] {
            try f.execute("""
                INSERT INTO disclosure (id, agent_id, agent_revision, task_hash, task_length, retention, max_tokens, status, created_at)
                VALUES (?, ?, 1, 'h', 1, 'unknown', 1000, ?, ?)
                """, [UUID().db, agent.id.db, status, t0])
        }
        let backup = try f.backUp()
        try f.restore(backup)

        #expect(try f.value("SELECT count(*) FROM disclosure WHERE status IN ('needs_approval', 'approved')") == 0)
        #expect(try f.value("SELECT count(*) FROM disclosure WHERE status = 'denied' AND reason = 'approval_expired'") == 2)
        #expect(try f.value("SELECT count(*) FROM disclosure WHERE status = 'delivered'") == 1)
    }

    @Test func withoutTheCurrentVaultEveryoneIsSetUpAgain() async throws {
        let f = try Folder()
        let (agent, key) = try await f.agents.create(name: "Claude", kind: .claudeCode,
                                                     access: Access(operations: [.read]), now: t0)
        let device = UUID()
        try f.addDevice(device)
        try f.store.createMemory(MemoryDraft(title: "Kept", body: "In the backup", categoryKeys: ["personal_preferences"]), now: t0)
        let backup = try f.backUp()
        try f.store.writer.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: f.directory.appending(path: VaultStore.fileName + suffix))
        }
        try f.restore(backup)

        #expect(try f.value("SELECT count(*) FROM memory WHERE title = 'Kept'") == 1)
        #expect(try await f.agents.authenticate(key: key.plaintext) == nil)
        let restored = try #require(try await f.agents.agent(id: agent.id))
        #expect(restored.removedAt != nil && restored.access.operations.isEmpty)
        #expect(try f.value("SELECT count(*) FROM device WHERE id = ? AND revoked_at IS NOT NULL", [device.db]) == 1)
    }

    @Test func anotherVaultsBackupLetsNobodyIn() async throws {
        let other = try Folder()
        let (_, key) = try await other.agents.create(name: "Claude", kind: .claudeCode, now: t0)
        let backup = try other.backUp()
        let f = try Folder()
        try FileManager.default.createDirectory(at: f.backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: other.backups.appending(path: backup), to: f.backups.appending(path: backup))
        try f.restore(backup)

        #expect(try await f.agents.authenticate(key: key.plaintext) == nil)
        #expect(try f.value("SELECT count(*) FROM agent WHERE removed_at IS NULL") == 0)
    }

    @Test func aBackupFromANewerVersionIsRefused() async throws {
        let f = try Folder()
        try f.store.createMemory(MemoryDraft(title: "Now", body: "The current vault", categoryKeys: ["personal_preferences"]), now: t0)
        let backup = try f.backUp()
        let queue = try DatabaseQueue(path: f.backups.appending(path: backup).path)
        try await queue.write { db in try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99_future')") }
        try queue.close()

        #expect(throws: VaultError.newerSchema) { try VaultStore.restoreBackup(backup, in: f.directory, now: t0.plus(days: 1)) }
        #expect(!FileManager.default.fileExists(atPath: f.directory.appending(path: VaultStore.fileName + ".restoring").path))
        f.store = try VaultStore.open(directory: f.directory)
        #expect(try f.value("SELECT count(*) FROM memory WHERE title = 'Now'") == 1)
    }
}
