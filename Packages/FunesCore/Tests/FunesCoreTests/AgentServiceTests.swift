import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Task 1.9: agents, access and keys (FR-A-01..06, NFR-SEC-03).
@Suite struct AgentServiceTests {
    static func make() throws -> (TestVault, AgentService, InMemoryAgentKeyStore) {
        let v = try TestVault()
        let keys = InMemoryAgentKeyStore()
        return (v, AgentService(store: v.store, keys: keys, activity: InMemoryActivityLog()), keys)
    }

    @Test func keysAreUnique32ByteHexWithThePrefix() throws {
        let issuer = LocalAgentKeyIssuer()
        let a = try issuer.issue(), b = try issuer.issue()
        #expect(a.plaintext != b.plaintext && a.digest != b.digest)
        #expect(a.plaintext.hasPrefix("fns_mcp_v1_") && a.plaintext.count == 11 + 64)
        #expect(a.plaintext.dropFirst(11).allSatisfy { "0123456789abcdef".contains($0) })
        #expect(a.digest.count == 32 && issuer.digest(of: a.plaintext) == a.digest)
        // The scanner keeps Funes keys out of the vault. (Random hex can also hold a Luhn-valid
        // digit run, so the key may match `creditCard` too.)
        #expect(SecretScanner.scan(a.plaintext).contains(.funesOrEKBKey))
    }

    @Test func createStoresOnlyTheDigest() async throws {
        let (v, agents, keys) = try Self.make()
        let (agent, key) = try await agents.create(name: "Claude Code", kind: .claudeCode, now: t0)
        #expect(agent.access == Access() && agent.revision == 1 && !agent.paused)
        #expect(keys.key(agentID: agent.id) == key.plaintext)
        #expect(try v.count("SELECT count(*) FROM agent WHERE key_digest = ?", [key.digest]) == 1)
        let dump = try await v.store.writer.read { db in try String(describing: Row.fetchAll(db, sql: "SELECT * FROM agent")) }
        #expect(!dump.contains(key.plaintext) && !dump.contains(String(key.plaintext.dropFirst(11))))
        #expect(try await agents.authenticate(key: key.plaintext)?.id == agent.id)
        #expect(try await agents.authenticate(key: "fns_mcp_v1_" + String(repeating: "0", count: 64)) == nil)
        #expect(try await agents.authenticate(key: "nope") == nil)
    }

    @Test func namesAreUniqueAmongActiveAgents() async throws {
        let (vault, agents, _) = try Self.make()
        defer { withExtendedLifetime(vault) {} }
        let (first, _) = try await agents.create(name: "Cursor", kind: .cursor, now: t0)
        await #expect(throws: VaultError.nameTaken) { try await agents.create(name: " Cursor ", kind: .cursor, now: t0) }
        await #expect(throws: VaultError.invalidInput(field: "name")) { try await agents.create(name: " ", kind: .other, now: t0) }
        try await agents.remove(agentID: first.id, now: t0)
        _ = try await agents.create(name: "Cursor", kind: .cursor, now: t0)
        #expect(try await agents.agents().count == 1)
        #expect(try await agents.agents(includingRemoved: true).count == 2)
    }

    @Test func everyChangeBumpsTheRevision() async throws {
        let (vault, agents, _) = try Self.make()
        defer { withExtendedLifetime(vault) {} }
        let (agent, _) = try await agents.create(name: "Codex", kind: .codex, access: Access.Preset.readLowAskFirst.access, now: t0)
        var revision = agent.revision
        func expectBump(_ a: Agent, line: Int = #line) {
            #expect(a.revision == revision + 1, "line \(line)")
            revision = a.revision
        }
        expectBump(try await agents.updateAccess(agentID: agent.id, Access.Preset.readAndSuggestAskFirst.access, now: t0))
        expectBump(try await agents.updateAccess(agentID: agent.id, Access.Preset.readAndSuggestAskFirst.access, now: t0))
        expectBump(try await agents.pause(agentID: agent.id, now: t0))
        expectBump(try await agents.resume(agentID: agent.id, now: t0))
        expectBump(try await agents.allowCategory(agentID: agent.id, "legal", now: t0))
        expectBump(try await agents.allowOperation(agentID: agent.id, .write, now: t0))
        _ = try await agents.rotateKey(agentID: agent.id, now: t0)
        expectBump(try #require(try await agents.agent(id: agent.id)))
        try await agents.update(agentID: agent.id, name: "Codex CLI", declaredRetention: .session, asksForAccess: true)
        let info = try #require(try await agents.agent(id: agent.id))
        #expect(info.revision == revision && info.name == "Codex CLI" && info.declaredRetention == .session && info.asksForAccess)
        #expect(info.access.allowedCategoryKeys == ["legal"] && info.access.deniedCategoryKeys == ["health", "finance", "legal"])
        #expect(info.access.operations == [.read, .suggest, .write])
    }

    @Test func presetsMatchFRA02() {
        #expect(Access.Preset.nothingYet.access.operations.isEmpty)
        let low = Access.Preset.readLowAskFirst.access
        #expect(low.operations == [.read] && low.maxSensitivity == .low && low.allowedCategoryKeys.isEmpty && low.askBeforeSharing)
        let suggest = Access.Preset.readAndSuggestAskFirst.access
        #expect(suggest.operations == [.read, .suggest] && suggest.maxSensitivity == .internal)
        #expect(suggest.deniedCategoryKeys == ["health", "finance", "legal"] && suggest.askBeforeSharing && suggest.askBeforeSaving)
    }

    @Test func rotationInvalidatesTheOldKeyAtOnce() async throws {
        let (vault, agents, keys) = try Self.make()
        defer { withExtendedLifetime(vault) {} }
        let (agent, old) = try await agents.create(name: "Zed", kind: .zed, now: t0)
        let new = try await agents.rotateKey(agentID: agent.id, now: t0.plus(minutes: 1))
        #expect(try await agents.authenticate(key: old.plaintext) == nil)
        #expect(try await agents.authenticate(key: new.plaintext)?.keyIssuedAt == t0.plus(minutes: 1))
        #expect(keys.key(agentID: agent.id) == new.plaintext)
    }

    @Test func aRemovedAgentCantAuthenticate() async throws {
        let (v, agents, keys) = try Self.make()
        let (agent, key) = try await agents.create(name: "VS Code", kind: .vscode, access: Access.Preset.readLowAskFirst.access, now: t0)
        try await agents.remove(agentID: agent.id, now: t0)
        #expect(try await agents.authenticate(key: key.plaintext) == nil)
        #expect(try await agents.authenticate(keyDigest: key.digest) == nil)
        #expect(keys.key(agentID: agent.id) == nil)
        let removed = try #require(try await agents.agent(id: agent.id))
        #expect(removed.isRemoved && removed.access.operations.isEmpty)
        #expect(try v.count("SELECT count(*) FROM agent WHERE key_digest IS NULL") == 1)
        await #expect(throws: VaultError.notFound) { try await agents.pause(agentID: agent.id, now: t0) }
        // And its requests fail authentication in the services.
        let disclosures = DisclosureService(store: v.store, retriever: FixedRetriever(store: v.store),
                                            activity: InMemoryActivityLog(), pause: FunesPause())
        await #expect(throws: VaultError.unauthenticated) {
            try await disclosures.request(agentID: agent.id, MemoryRequest(task: "t"), now: t0)
        }
    }

    @Test func unknownCategoriesInAccessAreRefused() async throws {
        let (vault, agents, _) = try Self.make()
        defer { withExtendedLifetime(vault) {} }
        let (agent, _) = try await agents.create(name: "Gemini", kind: .geminiCLI, now: t0)
        await #expect(throws: VaultError.unknownCategory("hobbies")) {
            try await agents.updateAccess(agentID: agent.id, Access(operations: [.read], allowedCategoryKeys: ["hobbies"]), now: t0)
        }
    }

    @Test func aPausedAgentIsRefusedButKeepsItsSetup() async throws {
        let (v, agents, _) = try Self.make()
        let (agent, key) = try await agents.create(name: "Desktop", kind: .claudeDesktop,
                                                   access: Access.Preset.readLowAskFirst.access, now: t0)
        try await agents.pause(agentID: agent.id, now: t0)
        let disclosures = DisclosureService(store: v.store, retriever: FixedRetriever(store: v.store),
                                            activity: InMemoryActivityLog(), pause: FunesPause())
        #expect(try await disclosures.request(agentID: agent.id, MemoryRequest(task: "t"), now: t0).reason == .agentPaused)
        #expect(try await agents.authenticate(key: key.plaintext)?.paused == true)
    }
}
