import Foundation
import FunesProtocol

/// "Share LOW and PUBLIC memories with this agent without asking for 15 minutes" (FR-D-12).
/// Held in memory only, bound to the agent's revision.
public struct AllowWindow: Sendable, Hashable {
    public var agentID: UUID
    public var revision: Int
    public var until: Date
    /// Never above LOW.
    public var maxSensitivity: Sensitivity

    public init(agentID: UUID, revision: Int, until: Date, maxSensitivity: Sensitivity = .low) {
        self.agentID = agentID
        self.revision = revision
        self.until = until
        self.maxSensitivity = min(maxSensitivity, .low)
    }
}

/// The overall decision on a read request (access policy §3.4).
public enum Decision: Sendable, Hashable {
    case deny(ReasonCode)
    /// `allowed` or `allowed_by_window`.
    case allow(ReasonCode)
    /// `confirmation_required`.
    case needsApproval

    public var reason: ReasonCode {
        switch self {
        case let .deny(r), let .allow(r): r
        case .needsApproval: .confirmationRequired
        }
    }
}

/// The access policy as pure functions (spec/domain/access-policy.md). Nothing here sees the
/// task or purpose text: for a fixed candidate set the decision is the same for any wording
/// (principle 2, the prompt-injection defence).
public enum PolicyEngine {
    /// The agent gate, in order; the first failure decides (§3.1 G1–G4, §5.2 G1–G3).
    /// `requiring` is the operation checked by G4: `.read` for `request_memory`, `nil` for
    /// `suggest_memory`, whose operation rule is its own decision table (§5.4).
    public static func gate(agent: Agent, access: Access, globalPaused: Bool, now: Date,
                            requiring operation: AccessOperation? = .read) -> ReasonCode? {
        if globalPaused { return .funesPaused }
        if agent.paused { return .agentPaused }
        if let expiry = access.expiresAt, expiry <= now { return .accessExpired }
        if let operation, !access.operations.contains(operation) { return .operationNotAllowed }
        return nil
    }

    /// The reasons only the gate gives. An answer refused for one of them carries no profile
    /// (§3.10 rule 1).
    public static let gateReasons: Set<ReasonCode> = [.funesPaused, .agentPaused, .accessExpired, .operationNotAllowed]

    /// Per-memory eligibility, in order; the first failure decides (§3.3 M1–M5). `nil` = eligible.
    public static func eligibility(_ memory: Memory, access: Access, now: Date) -> ReasonCode? {
        if memory.status != .active { return .inactiveMemory }
        if memory.isExpired(at: now) { return .expiredMemory }
        return scopeCheck(sensitivity: memory.sensitivity, categoryKeys: memory.categoryKeys, access: access)
    }

    /// M3–M5 against a proposed memory (§5.3): an agent can't plant memories outside its scope.
    public static func scopeCheck(sensitivity: Sensitivity, categoryKeys: [String], access: Access) -> ReasonCode? {
        if sensitivity > access.maxSensitivity { return .aboveSensitivityCeiling }
        if categoryKeys.contains(where: access.deniedCategoryKeys.contains) { return .deniedCategory }
        if !access.allowedCategoryKeys.isEmpty, !categoryKeys.contains(where: access.allowedCategoryKeys.contains) {
            return .categoryNotAllowed
        }
        return nil
    }

    /// The decision over the eligible memories (§3.4).
    public static func decide(eligible: [Memory], access: Access, window: AllowWindow?, agentID: UUID,
                              agentRevision: Int, now: Date) -> Decision {
        if eligible.isEmpty { return .deny(.noAllowedMemories) }
        if !access.askBeforeSharing { return .allow(.allowed) }
        if let window, window.agentID == agentID, window.revision == agentRevision, now < window.until,
           eligible.allSatisfy({ $0.sensitivity <= window.maxSensitivity }) {
            return .allow(.allowedByWindow)
        }
        return .needsApproval
    }

    /// A memory scoring at least this share of the top score is a strong match: the panel ticks it.
    /// Weaker ones are offered unticked (§3.2, FR-D-03).
    public static let strongMatchRatio = 0.6

    /// The snapshot items that are strong matches. The top one always is; without scores (rows
    /// stored before scores were kept, or a retriever without them) every item is.
    public static func strongMatches(_ items: [SnapshotItem]) -> Set<UUID> {
        let scores = items.compactMap(\.score)
        guard scores.count == items.count, let top = scores.max(), top > 0 else { return Set(items.map(\.id)) }
        return Set(items.filter { ($0.score ?? 0) >= top * strongMatchRatio }.map(\.id))
    }

    /// Eligibility over retrieved candidates (in score order) and the decision.
    public struct Evaluation: Sendable, Hashable {
        public var eligible: [Memory]
        /// Ineligible candidates counted by reason; never ids (ADR-0012).
        public var withheld: [ReasonCode: Int]
        public var decision: Decision
    }

    /// §3.2 step 6 to §3.4 for an agent that passed the gate.
    public static func evaluate(candidates: [Memory], agent: Agent, access: Access, window: AllowWindow?,
                                now: Date) -> Evaluation {
        guard !candidates.isEmpty else {
            return Evaluation(eligible: [], withheld: [:], decision: .deny(.noMatchingMemories))
        }
        var eligible: [Memory] = []
        var withheld: [ReasonCode: Int] = [:]
        for m in candidates {
            if let reason = eligibility(m, access: access, now: now) {
                withheld[reason, default: 0] += 1
            } else {
                eligible.append(m)
            }
        }
        let decision = decide(eligible: eligible, access: access, window: window, agentID: agent.id,
                              agentRevision: agent.revision, now: now)
        return Evaluation(eligible: eligible, withheld: withheld, decision: decision)
    }
}
