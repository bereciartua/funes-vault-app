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
    /// When the user may have answered one of them: about one panel's time.
    public static let pendingRetrySeconds = 60
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
    private let quitting = Mutex(false)

    public init(services: FunesServices, presenter: any FunesPresenter, limiter: RateLimiter,
                inCallWait: Duration = FunesMCPConfiguration.inCallWait, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.presenter = presenter
        self.limiter = limiter
        self.inCallWait = inCallWait
        self.now = now
    }

    /// Funes is quitting (mcp-server.md §7): calls waiting for the user get `funes_quit` now, with
    /// their request id, and new calls get it at once. Their requests stay in Pending requests.
    public func quit() {
        quitting.withLock { $0 = true }
        services.disclosures.endWaits()
    }

    var isQuitting: Bool { quitting.withLock { $0 } }

    /// Tool calls being handled, for every agent; the app holds its quit until they've answered.
    public var callsInProgress: Int { inFlight.withLock { $0.values.reduce(0, +) } }

    public func handle(_ call: ToolCall) async -> ToolResult {
        guard let agentID = UUID(uuidString: call.agent.id) else { return ToolOutput.denied(.notFound) }
        if isQuitting { return quit(call, agentID) }
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
        // 3. Rate limits: calls (and writes) per agent, the same buckets on every channel, then calls
        // in flight. Remote calls also take a token from the stricter remote buckets (60 calls and 10
        // writes a minute): network hygiene for the tunnel, not an access rule (ADR-0018).
        let isWrite = call.name == "suggest_memory"
        if case .limited(let wait) = limiter.allow(call.agent.id, write: isWrite) {
            return rateLimited(call, agentID, wait)
        }
        if call.remote, case .limited(let wait) = limiter.allow(call.agent.id, write: isWrite, remote: true) {
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

    func quit(_ call: ToolCall, _ agentID: UUID, requestID: UUID? = nil) -> ToolResult {
        record(call, agentID, outcome: "denied", reason: .funesQuit)
        guard let requestID else { return ToolOutput.denied(.funesQuit, isError: true) }
        let id = requestID.uuidString.lowercased()
        return ToolOutput.denied(.funesQuit, message: Messages.quit(id), isError: true, extra: ["request_id": id])
    }

    func rateLimited(_ call: ToolCall, _ agentID: UUID, _ seconds: Int) -> ToolResult {
        record(call, agentID, outcome: "denied", reason: .rateLimited)
        return ToolOutput.denied(.rateLimited, message: Messages.rateLimited(seconds), isError: true,
                                 extra: ["retry_after_s": seconds])
    }

    func record(_ call: ToolCall, _ agentID: UUID, outcome: String, reason: ReasonCode? = nil, ids: [UUID] = []) {
        services.activity.record(ActivityEvent(time: now(), actor: .agent(agentID), via: Self.via(call), event: call.name,
                                               outcome: outcome, ids: ids, reason: reason))
    }

    /// Activity's channel. The only thing `ToolCall.remote` changes (ADR-0018): every decision
    /// above and in FunesCore gets the same inputs on both listeners.
    static func via(_ call: ToolCall) -> ActivityEvent.Via { call.remote ? .remote : .mcp }
}
