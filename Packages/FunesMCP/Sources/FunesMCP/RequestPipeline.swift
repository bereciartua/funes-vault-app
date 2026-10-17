import BridgeKitCore
import Foundation
import FunesCore
import FunesProtocol
import Synchronization

/// The vault services the MCP tools use.
public struct FunesServices: Sendable {
    public let store: VaultStore
    public let agents: AgentService
    public let disclosures: DisclosureService
    public let suggestions: SuggestionService
    public let pause: FunesPause
    public let activity: any ActivityRecorder

    public init(store: VaultStore, agents: AgentService, disclosures: DisclosureService, suggestions: SuggestionService,
                pause: FunesPause, activity: any ActivityRecorder) {
        self.store = store
        self.agents = agents
        self.disclosures = disclosures
        self.suggestions = suggestions
        self.pause = pause
        self.activity = activity
    }
}

/// Keys presented over MCP, looked up by digest in the vault. Paused and expired agents are still
/// authenticated, so their calls get proper reason codes (mcp-server.md §4 step 6).
///
/// The lookup is by SHA-256 of a 256-bit random key, so how long it takes reveals nothing useful.
public struct FunesAuthenticator: AgentAuthenticator {
    private let agents: AgentService

    public init(agents: AgentService) {
        self.agents = agents
    }

    public func authenticate(_ key: PresentedKey) async -> AuthenticationOutcome {
        do {
            guard let agent = try await agents.authenticate(keyDigest: key.digest) else { return .rejected }
            return .authenticated(AuthenticatedAgent(id: agent.id.uuidString.lowercased(), name: agent.name))
        } catch {
            return .unavailable
        }
    }
}

/// Every tool call after authentication and schema validation: Funes on? → agent state → rate
/// limits (calls, writes, in flight, pending approvals) → handler → Activity (mcp-server.md §4, §9).
/// Fails closed: any doubt is a refusal (ADR-0009).
public final class RequestPipeline: BridgeHandler {
    /// mcp-server.md §9.
    public static let maxInFlightPerAgent = 8
    public static let maxPendingApprovalsPerAgent = 3
    public static let getMemoryRequestInterval: TimeInterval = 5

    let services: FunesServices
    let presenter: any FunesPresenter
    let limiter: RateLimiter
    let now: @Sendable () -> Date
    let inCallWait: Duration
    private let inFlight = Mutex<[UUID: Int]>([:])
    /// `get_memory_request` calls by agent and request id. Keyed by both, so another agent's
    /// calls can't reveal that a request exists (T20).
    let lastGet = Mutex<[String: Date]>([:])

    public init(services: FunesServices, presenter: any FunesPresenter, limiter: RateLimiter,
                inCallWait: Duration = FunesMCPConfiguration.inCallWait, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.presenter = presenter
        self.limiter = limiter
        self.inCallWait = inCallWait
        self.now = now
    }

    public func handle(_ call: ToolCall) async -> ToolResult {
        guard let agentID = UUID(uuidString: call.agent.id) else { return ToolOutput.denied(.notFound) }
        let started = now()
        // 1. Funes on.
        if services.pause.isPaused(at: started) { return refuse(call, agentID, .funesPaused) }
        // 2. Agent state. Removed agents never authenticate; a row that can't be read is a refusal.
        let agent: Agent
        do {
            guard let found = try await services.agents.agent(id: agentID), !found.isRemoved else {
                return refuse(call, agentID, .notFound)
            }
            agent = found
        } catch {
            return refuse(call, agentID, .notFound)
        }
        if agent.paused { return refuse(call, agentID, .agentPaused) }
        if let expiry = agent.access.expiresAt, expiry <= started { return refuse(call, agentID, .accessExpired) }
        // 3. Rate limits: calls (and writes) per agent, then calls in flight.
        let isWrite = call.name == "suggest_memory"
        if case .limited(let wait) = limiter.allow(call.agent.id, write: isWrite) {
            return rateLimited(call, agentID, wait)
        }
        let admitted = inFlight.withLock { counts -> Bool in
            guard counts[agentID, default: 0] < Self.maxInFlightPerAgent else { return false }
            counts[agentID, default: 0] += 1
            return true
        }
        guard admitted else { return rateLimited(call, agentID, 1) }
        defer { inFlight.withLock { counts in counts[agentID] = max(0, counts[agentID, default: 1] - 1) } }
        // 4. The handler. Disclosures and suggestions record their own Activity rows.
        switch call.name {
        case "list_memory_categories": return listCategories(call, agent)
        case "request_memory": return await requestMemory(call, agent)
        case "get_memory_request": return await getMemoryRequest(call, agent)
        case "suggest_memory": return await suggestMemory(call, agent)
        case "open_in_funes": return await openInFunes(call, agent)
        default: return refuse(call, agentID, .notFound)
        }
    }

    // MARK: - Refusals

    func refuse(_ call: ToolCall, _ agentID: UUID, _ reason: ReasonCode, message: String? = nil) -> ToolResult {
        record(call, agentID, outcome: "denied", reason: reason)
        return ToolOutput.denied(reason, message: message)
    }

    func rateLimited(_ call: ToolCall, _ agentID: UUID, _ seconds: Int) -> ToolResult {
        record(call, agentID, outcome: "denied", reason: .rateLimited)
        return ToolOutput.denied(.rateLimited, message: Messages.rateLimited(seconds), isError: true,
                                 extra: ["retry_after_s": seconds])
    }

    func record(_ call: ToolCall, _ agentID: UUID, outcome: String, reason: ReasonCode? = nil, ids: [UUID] = []) {
        services.activity.record(ActivityEvent(time: now(), actor: .agent(agentID), via: .mcp, event: call.name,
                                               outcome: outcome, ids: ids, reason: reason))
    }
}
