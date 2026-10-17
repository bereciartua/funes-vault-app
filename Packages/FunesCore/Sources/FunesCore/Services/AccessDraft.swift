import Foundation
import FunesProtocol

/// The access editor's draft (FR-A-03; PR #3 review 4304236144). It remembers the agent it was
/// built from, so:
/// - it's edited when it differs from that baseline (not from whatever the agent is now);
/// - an untouched draft follows changes made elsewhere (Always Allow from a panel);
/// - an edited draft keeps the user's values, says it's stale when the agent changed, and saving it
///   requires the baseline's revision, so it can't silently undo the other change.
public struct AccessDraft: Sendable, Hashable {
    public private(set) var baseline: Agent
    public var access: Access
    public var asksForAccess: Bool
    public var retention: Retention
    /// The agent as it is now, when that differs from the baseline.
    public private(set) var latest: Agent?

    public init(_ agent: Agent) {
        baseline = agent
        access = agent.access
        asksForAccess = agent.asksForAccess
        retention = agent.declaredRetention
    }

    public var isEdited: Bool {
        access != baseline.access || asksForAccess != baseline.asksForAccess || retention != baseline.declaredRetention
    }

    public var accessEdited: Bool { access != baseline.access }

    /// The agent changed since this draft was built while the user had edits.
    public var isStale: Bool {
        guard let latest else { return false }
        return latest.revision != baseline.revision || latest.asksForAccess != baseline.asksForAccess
            || latest.declaredRetention != baseline.declaredRetention
    }

    /// The draft for `agent` as it is now: rebuilt when untouched, kept (and marked stale if the agent
    /// changed) when edited.
    public func refreshed(from agent: Agent) -> AccessDraft {
        guard isEdited else { return AccessDraft(agent) }
        var kept = self
        kept.latest = agent == baseline ? nil : agent
        return kept
    }

    /// Saves through `agents`: the access only with the baseline's revision (else `revisionChanged`,
    /// nothing written), then the informational fields. Returns a fresh draft of the saved agent.
    public func save(with agents: AgentService, now: Date) async throws -> AccessDraft {
        if isStale { throw VaultError.revisionChanged }
        if accessEdited {
            try await agents.updateAccess(agentID: baseline.id, access, expectedRevision: baseline.revision, now: now)
        }
        if asksForAccess != baseline.asksForAccess || retention != baseline.declaredRetention {
            try await agents.update(agentID: baseline.id, declaredRetention: retention, asksForAccess: asksForAccess)
        }
        guard let saved = try await agents.agent(id: baseline.id) else { throw VaultError.notFound }
        return AccessDraft(saved)
    }
}
