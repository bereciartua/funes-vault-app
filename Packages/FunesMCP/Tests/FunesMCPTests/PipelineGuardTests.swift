import BridgeKitCore
import Foundation
import FunesCore
@testable import FunesMCP
import FunesProtocol
import Testing

/// Code review 2026-11-10: refusals that came before the rate limiter, Remote Access turned off
/// with remote calls in flight, and a `request_memory` that outlasts the call's 55 s.
@MainActor
@Suite("Pipeline guards")
struct PipelineGuardTests {
    struct Fixture {
        let directory: URL
        let pause: FunesPause
        let agents: AgentService
        let disclosures: DisclosureService
        let retriever: SuspendedRetriever
        let local: FunesMCPServer
        let agent: Agent
        let memory: Memory
        let activity: InMemoryActivityLog
    }

    func make(askBeforeSharing: Bool = false, inCallWait: Duration = .seconds(5)) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("funes-guard-\(UUID().uuidString)")
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
                                   version: "0.0.0-test", inCallWait: inCallWait)
        return Fixture(directory: directory, pause: pause, agents: agents, disclosures: disclosures, retriever: retriever,
                       local: local, agent: agent, memory: memory, activity: activity)
    }

    func call(_ f: Fixture, _ tool: String, remote: Bool = false, context: CallContext = CallContext()) -> ToolCall {
        ToolCall(name: tool, arguments: tool == "request_memory" ? ["task": "Set up a Swift package"] : [:],
                 agent: AuthenticatedAgent(id: f.agent.id.uuidString.lowercased(), name: "claude.ai"),
                 agentName: nil, remote: remote, context: context)
    }

    static let burst = Int(FunesMCPConfiguration.limits.callBurst)

    static func content(_ result: ToolResult?) -> [String: Any] {
        result?.json["structuredContent"] as? [String: Any] ?? [:]
    }

    /// A paused Funes refuses with `funes_paused`, but a looping agent still runs out of calls:
    /// past the burst it gets `rate_limited` (mcp-server.md §9), so it can't write a refusal row
    /// per call at any rate it likes.
    @Test func pauseRefusalsAreThrottled() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.pause.pause(until: Date().addingTimeInterval(3_600))
        let pipeline = f.local.pipeline
        var reasons = [String]()
        for _ in 0..<(Self.burst + 5) {
            reasons.append(Self.content(await pipeline.handle(call(f, "list_memory_categories")))["reason"] as? String ?? "")
        }
        #expect(reasons.first == "funes_paused")
        #expect(reasons.last == "rate_limited")
        #expect(reasons.filter { $0 == "funes_paused" }.count == Self.burst)
    }

    /// The same for a paused agent.
    @Test func pausedAgentRefusalsAreThrottled() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.agents.pause(agentID: f.agent.id, now: Date())
        let pipeline = f.local.pipeline
        var last: [String: Any] = [:]
        for _ in 0..<(Self.burst + 1) {
            last = Self.content(await pipeline.handle(call(f, "open_in_funes")))
        }
        #expect(last["reason"] as? String == "rate_limited")
    }

    /// Turning Remote Access off ends every remote call in flight: retrieval suspended, the
    /// listener stopped, retrieval released.
    @Test func remoteAccessOffDuringRetrievalReleasesNothing() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let remote = FunesRemoteServer(local: f.local, dataFolder: f.directory, version: "0.0.0-test")
        let pipeline = f.local.pipeline
        let inFlight = Task { await pipeline.handle(call(f, "request_memory", remote: true)) }
        await f.retriever.waitUntilRetrieving()
        remote.stop()
        f.retriever.release([f.memory.id])
        let result = await inFlight.value
        #expect(Self.content(result)["status"] as? String == "denied")
        let text = String(decoding: (try? JSONSerialization.data(withJSONObject: result.json)) ?? Data(), as: UTF8.self)
        #expect(!text.contains("Strict concurrency"), "memory text released after Remote Access was turned off")
        // A local call of the same agent isn't affected.
        let localCall = Task { await pipeline.handle(call(f, "request_memory")) }
        await f.retriever.waitUntilRetrieving()
        f.retriever.release([f.memory.id])
        #expect(Self.content(await localCall.value)["status"] as? String == "fulfilled")
    }

    /// Once a request waits for the user, the call's timeout answer is that request with its id,
    /// not a bare `timeout`, so an agent cut off at 55 s can still ask for it.
    @Test func timeoutAnswerCarriesTheWaitingRequest() async throws {
        let f = try await make(askBeforeSharing: true, inCallWait: .milliseconds(300))
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let pipeline = f.local.pipeline
        let context = CallContext()
        let inFlight = Task { await pipeline.handle(call(f, "request_memory", context: context)) }
        await f.retriever.waitUntilRetrieving()
        f.retriever.release([f.memory.id])
        let result = Self.content(await inFlight.value)
        let fallback = Self.content(context.timeoutResult)
        #expect(result["status"] as? String == "needs_approval")
        #expect(fallback["status"] as? String == "needs_approval")
        #expect(fallback["request_id"] as? String == result["request_id"] as? String)
        #expect(fallback["request_id"] != nil)
    }

    /// A call that never waits leaves the registry's `timeout` in place.
    @Test func noTimeoutAnswerWithoutAWaitingRequest() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let pipeline = f.local.pipeline
        let context = CallContext()
        let inFlight = Task { await pipeline.handle(call(f, "request_memory", context: context)) }
        await f.retriever.waitUntilRetrieving()
        f.retriever.release([f.memory.id])
        #expect(Self.content(await inFlight.value)["status"] as? String == "fulfilled")
        #expect(context.timeoutResult == nil)
    }
}
