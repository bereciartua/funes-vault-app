import BridgeKitCore
import Foundation
import FunesCore
@testable import FunesMCP
import FunesProtocol
import Testing

/// PR #9 review: a remote call already in flight when the agent's cloud access is turned off, or
/// its cloud credentials change, must release and save nothing. Local calls of the same agent keep
/// working, since cloud access never affects them (ADR-0018).
@MainActor
@Suite("Remote calls in flight when cloud access changes")
struct RemoteRevocationTests {
    struct Fixture {
        let directory: URL
        let agents: AgentService
        let disclosures: DisclosureService
        let retriever: SuspendedRetriever
        let local: FunesMCPServer
        let remote: FunesRemoteServer
        let agent: Agent
        let memory: Memory
        let activity: InMemoryActivityLog
    }

    func make(askBeforeSharing: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("funes-revoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let store = try VaultStore.open(directory: directory)
        let activity = InMemoryActivityLog()
        let pause = FunesPause()
        let retriever = SuspendedRetriever()
        let agents = AgentService(store: store, issuer: BridgeKitKeyIssuer(), keys: AgentKeyFileStore(dataFolder: directory),
                                  activity: activity)
        let disclosures = DisclosureService(store: store, retriever: retriever, activity: activity, pause: pause)
        let suggestions = SuggestionService(store: store, activity: activity, pause: pause, disclosures: disclosures)
        let now = Date()
        let memory = try store.createMemory(MemoryDraft(title: "Writes Swift 6", body: "Strict concurrency everywhere.",
                                                        categoryKeys: ["software_development"], sensitivity: .low), now: now)
        let (agent, _) = try await agents.create(
            name: "claude.ai", kind: .claudeAI,
            access: Access(operations: [.read], maxSensitivity: .internal, askBeforeSharing: askBeforeSharing), now: now)
        try await agents.setCloudAccess(agentID: agent.id, true, now: now)
        let services = FunesServices(store: store, agents: agents, disclosures: disclosures, suggestions: suggestions,
                                     pause: pause, activity: activity)
        let local = FunesMCPServer(services: services, presenter: SilentPresenter(), dataFolder: directory,
                                   version: "0.0.0-test", inCallWait: .seconds(5))
        let remote = FunesRemoteServer(local: local, dataFolder: directory, version: "0.0.0-test")
        return Fixture(directory: directory, agents: agents, disclosures: disclosures, retriever: retriever, local: local,
                       remote: remote, agent: agent, memory: memory, activity: activity)
    }

    func call(_ fixture: Fixture, remote: Bool) -> ToolCall {
        ToolCall(name: "request_memory", arguments: ["task": "Set up a Swift package"],
                 agent: AuthenticatedAgent(id: fixture.agent.id.uuidString.lowercased(), name: "claude.ai"),
                 agentName: nil, remote: remote, context: CallContext())
    }

    static func content(_ result: ToolResult) -> [String: Any] {
        result.json["structuredContent"] as? [String: Any] ?? [:]
    }

    static func text(_ result: ToolResult) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: result.json)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The reviewer's reproduction: retrieval suspended, cloud access turned off, retrieval released.
    @Test func cloudAccessOffDuringRetrievalReleasesNothing() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let pipeline = f.local.pipeline
        let inFlight = Task { await pipeline.handle(call(f, remote: true)) }
        await f.retriever.waitUntilRetrieving()
        try await f.remote.setCloudAccess(agentID: f.agent.id, false)
        f.retriever.release([f.memory.id])
        let result = await inFlight.value
        #expect(Self.content(result)["status"] as? String == "denied")
        #expect(!Self.text(result).contains("Strict concurrency"), "memory text released after revocation")
        #expect(try await f.disclosures.pendingRequests(now: Date()).isEmpty)
        #expect(!f.activity.events.contains { $0.event == "request_memory" && $0.outcome == "fulfilled" })
    }

    /// Local calls never depend on cloud access.
    @Test func aLocalCallIsUnaffected() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let pipeline = f.local.pipeline
        let inFlight = Task { await pipeline.handle(call(f, remote: false)) }
        await f.retriever.waitUntilRetrieving()
        try await f.remote.setCloudAccess(agentID: f.agent.id, false)
        f.retriever.release([f.memory.id])
        let result = await inFlight.value
        #expect(Self.content(result)["status"] as? String == "fulfilled")
        #expect(Self.text(result).contains("Strict concurrency"))
    }

    /// Cloud access stays on, but the remote token is reset mid-call: the old credential's call ends.
    @Test func aTokenResetDuringRetrievalReleasesNothing() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let pipeline = f.local.pipeline
        let inFlight = Task { await pipeline.handle(call(f, remote: true)) }
        await f.retriever.waitUntilRetrieving()
        _ = try await f.remote.issueRemoteKey(agentID: f.agent.id)
        f.retriever.release([f.memory.id])
        let result = await inFlight.value
        #expect(Self.content(result)["status"] as? String == "denied")
        #expect(!Self.text(result).contains("Strict concurrency"))
        // A call that starts after the reset is fine.
        let later = Task { await pipeline.handle(call(f, remote: true)) }
        await f.retriever.waitUntilRetrieving()
        f.retriever.release([f.memory.id])
        #expect(Self.content(await later.value)["status"] as? String == "fulfilled")
    }

    /// Revoking a connected cloud app ends the agent's in-flight remote calls too.
    @Test func revokingAppsDuringRetrievalReleasesNothing() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let pipeline = f.local.pipeline
        let inFlight = Task { await pipeline.handle(call(f, remote: true)) }
        await f.retriever.waitUntilRetrieving()
        f.remote.revokeApps(agentID: f.agent.id)
        f.retriever.release([f.memory.id])
        #expect(Self.content(await inFlight.value)["status"] as? String == "denied")
    }

    /// Approved in the panel after cloud access was turned off: delivery refuses.
    @Test func approvalAfterRevocationDeliversNothing() async throws {
        let f = try await make(askBeforeSharing: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let pipeline = f.local.pipeline
        let inFlight = Task { await pipeline.handle(call(f, remote: true)) }
        await f.retriever.waitUntilRetrieving()
        f.retriever.release([f.memory.id])
        // Wait until it's waiting for the user.
        var waiting: Disclosure?
        for _ in 0..<100 where waiting == nil {
            waiting = try await f.disclosures.pendingRequests(now: Date()).first
            if waiting == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let request = try #require(waiting)
        try await f.remote.setCloudAccess(agentID: f.agent.id, false)
        let panel = try #require(try await f.disclosures.panel(requestID: request.id, now: Date()))
        try? await f.disclosures.approve(requestID: request.id, snapshotRevision: panel.snapshotRevision,
                                         memoryIDs: panel.memories.map(\.id), now: Date())
        let result = await inFlight.value
        #expect(Self.content(result)["status"] as? String != "delivered")
        #expect(!Self.text(result).contains("Strict concurrency"), "memory text delivered after revocation")
    }
}
