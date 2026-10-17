import Foundation
import FunesProtocol
import GRDB
import Synchronization
@testable import FunesCore

/// Retrieval stand-in: "assume retrieval returns every active memory unless the case says otherwise".
final class FixedRetriever: MemoryRetriever {
    private let ids = Mutex<[UUID]?>(nil)
    private let calls = Mutex(0)
    let store: VaultStore

    init(store: VaultStore) { self.store = store }

    /// nil: every active memory, oldest first.
    func set(_ ids: [UUID]?) { self.ids.withLock { $0 = ids } }
    var callCount: Int { calls.withLock { $0 } }

    func candidateIDs(task: String, keywords: [String], categories: [String]) async throws -> [UUID] {
        calls.withLock { $0 += 1 }
        if let fixed = ids.withLock({ $0 }) { return fixed }
        return try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM memory WHERE status = 'active' ORDER BY seq").compactMap(UUID.init(uuidString:))
        }
    }
}

/// The access-policy fixture (§9) in a real vault: agent A and memories m1–m6, plus the services.
final class ServiceFixture: @unchecked Sendable {
    typealias F = PolicyFixture
    let vault: TestVault
    let retriever: FixedRetriever
    let activity = InMemoryActivityLog()
    let pause = FunesPause()
    let disclosures: DisclosureService
    var store: VaultStore { vault.store }
    let agentID = F.agentID
    let now = F.now

    init() throws {
        vault = try TestVault()
        retriever = FixedRetriever(store: vault.store)
        disclosures = DisclosureService(store: vault.store, retriever: retriever, activity: activity, pause: pause)
        try store.writer.write { db in
            for s in F.specs {
                let m = try MemoryStore.insert(db, MemoryDraft(
                    title: "Memory \(s.name)", body: "Body of \(s.name)", categoryKeys: [s.category], sensitivity: s.sensitivity,
                    expiresAt: s.expired ? F.now.plus(days: -1) : nil), actor: .user, now: F.now.plus(days: -2), id: F.id(s.name))
                if s.archived { try MemoryStore.setStatus(db, id: m.id, to: .archived, actor: .user, now: F.now.plus(days: -2)) }
            }
            try AgentStore.insert(db, F.agent, keyDigest: Data(repeating: 1, count: 32))
        }
    }

    func id(_ name: String) -> UUID { F.id(name) }
    func names(_ ids: [UUID]) -> Set<String> { Set(ids.map(F.name(of:))) }

    func setAccess(_ change: (inout Access) -> Void) throws {
        try store.writer.write { db in
            var access = try AgentStore.fetch(db, id: agentID)!.access
            change(&access)
            try AgentStore.writeAccess(db, agentID: agentID, access)
            try AgentStore.bumpRevision(db, agentID: agentID)
        }
    }

    func setAgent(paused: Bool? = nil, revision: Int? = nil, asksForAccess: Bool? = nil) throws {
        try store.writer.write { db in
            if let paused { try db.execute(sql: "UPDATE agent SET paused = ? WHERE id = ?", arguments: [paused, agentID.db]) }
            if let revision { try db.execute(sql: "UPDATE agent SET revision = ? WHERE id = ?", arguments: [revision, agentID.db]) }
            if let asksForAccess {
                try db.execute(sql: "UPDATE agent SET asks_for_access = ? WHERE id = ?", arguments: [asksForAccess, agentID.db])
            }
        }
    }

    func addAgent(name: String, access: Access = Access(operations: [.read], maxSensitivity: .internal)) throws -> UUID {
        let id = UUID()
        try store.writer.write { db in
            try AgentStore.insert(db, Agent(id: id, name: name, agentKind: .other, paused: false, revision: 1,
                                            declaredRetention: .unknown, asksForAccess: false, createdAt: t0, access: access),
                                  keyDigest: Data(id.db.utf8))
        }
        return id
    }

    func request(_ task: String = "Draft my weekly status update", purpose: String? = nil, keywords: [String] = [],
                 maxTokens: Int = 1200, at: Date? = nil, grant: OnceGrant? = nil) async throws -> RequestOutcome {
        try await disclosures.request(agentID: agentID, MemoryRequest(task: task, keywords: keywords, purpose: purpose,
                                                                      maxTokens: maxTokens), now: at ?? now, grant: grant)
    }

    /// T1, then the user approves `names` in the panel.
    func approved(_ names: [String], at: Date? = nil) async throws -> UUID {
        let outcome = try await request()
        let id = outcome.requestID!
        let panel = try await disclosures.panel(requestID: id, now: at ?? now)!
        try await disclosures.approve(requestID: id, snapshotRevision: panel.snapshotRevision,
                                      memoryIDs: names.map(self.id), now: at ?? now)
        return id
    }

    func status(_ id: UUID) async throws -> (DisclosureStatus, ReasonCode?) {
        let d = try await disclosures.disclosure(requestID: id)!
        return (d.status, d.reason)
    }
}
