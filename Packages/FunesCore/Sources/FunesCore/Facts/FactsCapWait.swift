import Foundation

/// Why Facts jobs wait for tomorrow (FR-F-03, memory processing §11.3 "Cost and the cap"), for the Facts page: today's
/// cloud requests are used up; or only a share of them: the agents' (memories agents wrote wait; yours are still read),
/// or low-priority work's (catch-up, re-reads and reconciliation wait; new and changed memories are still read).
public enum FactsCapWait: String, Sendable, Hashable, CaseIterable {
    case total, agents, lowPriority

    /// What the page says now, from the codes jobs wait with (`VaultStore.factsCapWaits`) and today's counts: a code is
    /// as old as its refusal, so the cap used up since wins over a share, and a share that has room again (a raised cap)
    /// says nothing. Nil counts (unreadable) read as the cap used up.
    public static func current(codes: Set<String>, day: CloudRequestCap.Day?, limit: Int) -> Set<FactsCapWait> {
        guard !codes.isEmpty else { return [] }
        guard let day, day.total < limit else { return [.total] }
        var waits: Set<FactsCapWait> = []
        if codes.contains("cap_share"), day.lowPriority >= CloudRequestCap.lowPriorityLimit(for: limit) { waits.insert(.lowPriority) }
        if !codes.isDisjoint(with: ["cap", "cap_agents"]), day.agents >= CloudRequestCap.agentLimit(for: limit) { waits.insert(.agents) }
        return waits
    }
}
