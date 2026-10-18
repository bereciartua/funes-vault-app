import CryptoKit
import Foundation
import FunesProtocol
import GRDB
import Synchronization

/// Which memories are relevant to a task (access policy §3.2). `SearchService` is the real one;
/// tests substitute "retrieval returns every active memory".
public protocol MemoryRetriever: Sendable {
    /// Candidate ids in score order, at most 30.
    func candidateIDs(task: String, keywords: [String], categories: [String]) async throws -> [UUID]
}

extension SearchService: MemoryRetriever {
    public func candidateIDs(task: String, keywords: [String], categories: [String]) async throws -> [UUID] {
        try await retrieve(task: task, keywords: keywords, categories: categories).map(\.memoryID)
    }
}

/// A `request_memory` call (spec/architecture/mcp-server.md §6.2).
public struct MemoryRequest: Sendable, Hashable {
    public var task: String
    public var keywords: [String]
    public var purpose: String?
    public var categories: [String]
    public var maxTokens: Int
    public var retention: Retention
    public var processors: [String]

    public init(task: String, keywords: [String] = [], purpose: String? = nil, categories: [String] = [],
                maxTokens: Int = InputLimits.defaultMaxTokens, retention: Retention = .unknown, processors: [String] = []) {
        self.task = task
        self.keywords = keywords
        self.purpose = purpose
        self.categories = categories
        self.maxTokens = maxTokens
        self.retention = retention
        self.processors = processors
    }

    /// The input limits. The MCP schema validator checks them too; this is the fail-closed copy.
    public func validate() throws {
        let len = InputLimits.length(of:)
        guard InputLimits.task.contains(len(task)) else { throw VaultError.invalidInput(field: "task") }
        guard keywords.count <= InputLimits.keywordCount, keywords.allSatisfy({ InputLimits.keywordLength.contains(len($0)) }) else {
            throw VaultError.invalidInput(field: "keywords")
        }
        guard (purpose.map(len) ?? 0) <= InputLimits.purpose else { throw VaultError.invalidInput(field: "purpose") }
        guard categories.count <= InputLimits.requestCategories else { throw VaultError.invalidInput(field: "categories") }
        guard InputLimits.maxTokens.contains(maxTokens) else { throw VaultError.invalidInput(field: "max_tokens") }
        guard processors.count <= InputLimits.processorCount,
              processors.allSatisfy({ len($0) <= InputLimits.processorLength }) else {
            throw VaultError.invalidInput(field: "processors")
        }
    }
}

/// The status an agent sees (mcp-server §6.2–6.3).
public enum RequestStatus: String, Sendable, Codable {
    case delivered, fulfilled
    case needsApproval = "needs_approval"
    case denied
    case alreadyDelivered = "already_delivered"
    case notFound = "not_found"
}

/// "Let it ask for more access" (access policy §7): offered to the user, never to the agent.
public struct AccessRequestOffer: Sendable, Hashable {
    public var agentID: UUID
    public var requestID: UUID?
    /// Categories to allow (Allow Once / Always Allow add exactly one of them).
    public var categoryKeys: [String]
    public var operation: AccessOperation
    /// The agent's revision when the offer was made. Allow Once holds only while it's current: any
    /// change to the agent's access drops it (§7).
    public var agentRevision: Int

    public init(agentID: UUID, requestID: UUID?, categoryKeys: [String], operation: AccessOperation, agentRevision: Int) {
        self.agentID = agentID
        self.requestID = requestID
        self.categoryKeys = categoryKeys
        self.operation = operation
        self.agentRevision = agentRevision
    }
}

/// The result of `request_memory` or `get_memory_request`.
public struct RequestOutcome: Sendable, Hashable {
    public var status: RequestStatus
    public var requestID: UUID?
    public var reason: ReasonCode?
    /// Only for `delivered` and `fulfilled`.
    public var bundle: MemoryBundle?
    /// Present after retrieval, absent for gate denials. Counts, never ids.
    public var withheld: [ReasonCode: Int]?
    public var maxTokens: Int
    /// For the Mac's UI only; not part of the agent's response.
    public var accessOffer: AccessRequestOffer?
}

/// What the approval panel or the pending list shows (access policy §3.6, FR-D-03). The memory
/// text is read fresh from the vault, never from the agent.
public struct ApprovalPanel: Sendable, Hashable {
    public var requestID: UUID
    public var agentID: UUID
    public var agentName: String
    /// The task and keywords, while still held in memory (15 minutes); nil after.
    public var task: String?
    public var keywords: [String]
    public var purpose: String?
    public var retention: Retention
    public var processors: [String]
    /// The eligible memories, current, in score order.
    public var memories: [Memory]
    public var snapshotRevision: String
    public var createdAt: Date
    public var expiresAt: Date
}

/// Allow Once (access policy §7): a temporary grant of one category, bound to the request that
/// offered it and the agent's revision. Never persisted; usable once.
public struct OnceGrant: Sendable, Hashable {
    public var offeredByRequestID: UUID
    public var agentRevision: Int
    public var categoryKey: String

    public init(offeredByRequestID: UUID, agentRevision: Int, categoryKey: String) {
        self.offeredByRequestID = offeredByRequestID
        self.agentRevision = agentRevision
        self.categoryKey = categoryKey
    }
}

/// Requests to read memories, approvals and single-use delivery (task 1.7, access policy §3).
///
/// - Every multi-step change runs in one write transaction (NFR-REL-01): one per request, per
///   approval and per delivery.
/// - The task text and keywords are never stored: the disclosure keeps their hash, and the text
///   is held here for 15 minutes for the panel and the pending list.
public final class DisclosureService: Sendable {
    /// Pending requests, approvals and the task cache all last 15 minutes.
    public static let window: TimeInterval = 15 * 60
    static let accessOfferInterval: TimeInterval = 3600

    public let store: VaultStore
    public let retriever: any MemoryRetriever
    public let activity: any ActivityRecorder
    public let pause: FunesPause

    struct CachedTask { let task: String, keywords: [String], expires: Date }
    private let tasks = Mutex<[UUID: CachedTask]>([:])
    private let windows = Mutex<[UUID: AllowWindow]>([:])
    /// "agent|category|operation" → when it was last offered.
    private let offered = Mutex<[String: Date]>([:])
    /// Request id → categories offered by it and not yet used by Allow Once.
    private let grants = Mutex<[UUID: Set<String>]>([:])
    /// Request id → the Allow Once grant it was made with, kept for its panel and delivery.
    private let requestGrants = Mutex<[UUID: OnceGrant]>([:])
    private let waiters = Mutex<[UUID: [UUID: CheckedContinuation<Void, Never>]]>([:])
    /// Set by `endWaits()`: Funes is quitting, so no wait lasts.
    private let waitsEnded = Mutex(false)

    public init(store: VaultStore, retriever: any MemoryRetriever, activity: any ActivityRecorder, pause: FunesPause) {
        self.store = store
        self.retriever = retriever
        self.activity = activity
        self.pause = pause
    }

    // MARK: - request_memory

    /// Evaluates a request: gate, retrieval, eligibility, decision (FR-D-01). ALLOW delivers in the
    /// same call (`fulfilled`); NEEDS_APPROVAL persists the snapshot and returns no text.
    /// `maxPendingApprovals` caps this agent's requests waiting for the user (mcp-server.md §9). It's
    /// counted in the same write transaction that would add one, so concurrent calls can't all pass;
    /// over the cap the request is denied with `rate_limited`.
    public func request(agentID: UUID, _ input: MemoryRequest, now: Date, grant: OnceGrant? = nil,
                        maxPendingApprovals: Int? = nil) async throws -> RequestOutcome {
        try input.validate()
        let agent = try await store.writer.read { db in try AgentStore.fetch(db, id: agentID) }
        guard let agent, !agent.isRemoved else { throw VaultError.unauthenticated }
        let access = try useGrant(grant, agent: agent)

        // A denial at the gate doesn't run retrieval (§3.1): the task isn't even embedded.
        let candidateIDs: [UUID] =
            if PolicyEngine.gate(agent: agent, access: access, globalPaused: pause.isPaused(at: now), now: now) == nil {
                try await retriever.candidateIDs(task: input.task, keywords: input.keywords, categories: input.categories)
            } else {
                []
            }
        let window = windows.withLock { $0[agentID] }
        let paused = pause.isPaused(at: now)
        let requestID = UUID()

        struct Result {
            var outcome: RequestOutcome
            var delivered: [UUID]
            var withheldCategories: [String]
            var revision = 0
        }
        let result = try await store.writer.write { db -> Result in
            // Re-read inside the transaction, so the decision and the stored snapshot agree.
            guard let agent = try AgentStore.fetch(db, id: agentID), !agent.isRemoved else { throw VaultError.unauthenticated }
            var access = agent.access
            if let grant, grant.agentRevision == agent.revision { access.allowedCategoryKeys.insert(grant.categoryKey) }
            try AgentStore.recordRequest(db, agentID: agentID, now: now)
            var row = Self.newRow(id: requestID, agent: agent, input: input, now: now)

            if let reason = PolicyEngine.gate(agent: agent, access: access, globalPaused: paused, now: now) {
                row.status = .denied
                row.reason = reason
                try Self.insert(db, row)
                return Result(outcome: RequestOutcome(status: .denied, requestID: requestID, reason: reason,
                                                      maxTokens: input.maxTokens), delivered: [], withheldCategories: [])
            }
            // Memories deleted since retrieval are gone; anything else not active counts as inactive.
            let candidates = try MemoryStore.fetch(db, ids: candidateIDs).filter { $0.status != .deleted }
            let e = PolicyEngine.evaluate(candidates: candidates, agent: agent, access: access, window: window, now: now)
            row.withheld = e.withheld
            row.candidateSnapshot = e.eligible.map { SnapshotItem(id: $0.id, version: $0.version) }
            row.reason = e.decision.reason
            let withheldCategories = candidates
                .filter { PolicyEngine.eligibility($0, access: access, now: now) == .categoryNotAllowed }
                .compactMap(\.categoryKeys.first)
            var outcome = RequestOutcome(status: .denied, requestID: requestID, reason: e.decision.reason,
                                         withheld: e.withheld, maxTokens: input.maxTokens)
            var delivered: [UUID] = []
            switch e.decision {
            case .deny:
                row.status = .denied
                try Self.insert(db, row)
            case .allow:
                row.status = .fulfilled
                row.deliveredAt = now
                row.decidedAt = now
                try Self.insert(db, row)
                let bundle = BundleCompiler.compile(e.eligible, maxTokens: input.maxTokens)
                try Self.writeItems(db, disclosureID: requestID, bundle: bundle, agentID: agentID, now: now)
                outcome.status = .fulfilled
                outcome.bundle = bundle
                delivered = bundle.items.map(\.memoryID)
            case .needsApproval:
                if let limit = maxPendingApprovals {
                    let waiting = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM disclosure WHERE agent_id = ? AND status = 'needs_approval' AND created_at > ?
                        """, arguments: [agentID.db, now - Self.window]) ?? 0
                    if waiting >= limit {
                        row.status = .denied
                        row.reason = .rateLimited
                        try Self.insert(db, row)
                        outcome.reason = .rateLimited
                        return Result(outcome: outcome, delivered: [], withheldCategories: [])
                    }
                }
                row.status = .needsApproval
                row.snapshotRevision = Self.snapshotRevision(agentID: agentID, agentRevision: agent.revision,
                                                             items: row.candidateSnapshot)
                try Self.insert(db, row)
                outcome.status = .needsApproval
            }
            return Result(outcome: outcome, delivered: delivered, withheldCategories: withheldCategories,
                          revision: agent.revision)
        }

        var outcome = result.outcome
        if outcome.status == .needsApproval {
            tasks.withLock { $0[requestID] = CachedTask(task: input.task, keywords: input.keywords, expires: now + Self.window) }
            if let grant { requestGrants.withLock { $0[requestID] = grant } }
        }
        if let withheld = outcome.withheld, Set(withheld.keys) == [.categoryNotAllowed], agent.asksForAccess {
            outcome.accessOffer = offer(agentID: agentID, requestID: requestID, categories: result.withheldCategories,
                                        operation: .read, agentRevision: result.revision, now: now)
        }
        activity.record(ActivityEvent(
            time: now, requestID: requestID, actor: .agent(agentID), via: .mcp, event: "request_memory",
            outcome: outcome.status.rawValue, ids: result.delivered, reason: outcome.reason,
            counts: outcome.withheld?.counts ?? [:],
            approval: outcome.status == .fulfilled ? .notRequired : nil))
        return outcome
    }

    /// The in-call flow (§3.7): evaluate, wait up to `wait` for the panel, deliver if approved.
    /// On timeout the result is `needs_approval` with the request id, and the request moves to
    /// Pending requests (T18). `onNeedsApproval` runs once the request is waiting, so the app can
    /// show its panel.
    public func requestInCall(agentID: UUID, _ input: MemoryRequest, wait: Duration = .seconds(45),
                              maxPendingApprovals: Int? = nil, now: @Sendable () -> Date = { Date() },
                              onNeedsApproval: @Sendable (RequestOutcome) -> Void = { _ in }) async throws -> RequestOutcome {
        let outcome = try await request(agentID: agentID, input, now: now(), maxPendingApprovals: maxPendingApprovals)
        guard outcome.status == .needsApproval, let id = outcome.requestID else { return outcome }
        onNeedsApproval(outcome)
        switch await waitForDecision(requestID: id, timeout: wait) {
        case .approved?:
            return try await deliver(requestID: id, agentID: agentID, now: now())
        case .denied?:
            var denied = outcome
            denied.status = .denied
            denied.reason = try await store.writer.read { db in
                try Row.fetchOne(db, sql: "SELECT reason FROM disclosure WHERE id = ?", arguments: [id.db])?.enumValue("reason")
            }
            return denied
        default:
            return outcome
        }
    }

    // MARK: - Approval (panel or pending list)

    /// The panel for a pending request, with each eligible memory's current text. If a memory or
    /// the agent's access changed since the snapshot, the snapshot is rebuilt first (so a stale
    /// panel's revision is refused on approval; T22).
    public func panel(requestID: UUID, now: Date) async throws -> ApprovalPanel? {
        let cached = tasks.withLock { $0[requestID] }.flatMap { $0.expires > now ? $0 : nil }
        return try await store.writer.write { db -> ApprovalPanel? in
            guard var d = try Self.fetch(db, id: requestID), d.status == .needsApproval,
                  now < d.createdAt + Self.window,
                  let agent = try AgentStore.fetch(db, id: d.agentID), !agent.isRemoved else { return nil }
            let access = self.access(agent, requestID: requestID)
            let snapshot = try MemoryStore.fetch(db, ids: d.candidateSnapshot.map(\.id))
            let current = snapshot.filter { PolicyEngine.eligibility($0, access: access, now: now) == nil }
            let items = current.map { SnapshotItem(id: $0.id, version: $0.version) }
            if items != d.candidateSnapshot || agent.revision != d.agentRevisionAtRequest {
                d.candidateSnapshot = items
                d.agentRevisionAtRequest = agent.revision
                d.snapshotRevision = Self.snapshotRevision(agentID: agent.id, agentRevision: agent.revision, items: items)
                if items.isEmpty {
                    try db.execute(sql: "UPDATE disclosure SET status = 'denied', reason = ?, decided_at = ? WHERE id = ?",
                                   arguments: [ReasonCode.noAllowedMemories.rawValue, now, requestID.db])
                    return nil
                }
                try db.execute(sql: """
                    UPDATE disclosure SET candidate_snapshot = ?, agent_revision = ?, snapshot_revision = ? WHERE id = ?
                    """, arguments: [JSON.encode(items), agent.revision, d.snapshotRevision, requestID.db])
            }
            return ApprovalPanel(requestID: d.id, agentID: agent.id, agentName: agent.name, task: cached?.task,
                                 keywords: cached?.keywords ?? [], purpose: d.purpose, retention: d.retention,
                                 processors: d.processors, memories: current, snapshotRevision: d.snapshotRevision ?? "",
                                 createdAt: d.createdAt, expiresAt: d.createdAt + Self.window)
        }
    }

    /// Requests waiting for the user or approved and not yet retrieved, newest first.
    public func pendingRequests(now: Date) async throws -> [Disclosure] {
        try await store.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM disclosure WHERE status IN ('needs_approval', 'approved') AND created_at > ? ORDER BY created_at DESC
                """, arguments: [now - Self.window]).map(Disclosure.from(row:))
        }
    }

    /// Shares the chosen subset (§3.6, FR-D-04). Refused with `snapshotChanged` when the panel's
    /// revision is stale (T22), `invalidInput` for an empty or foreign subset, `invalidState` when
    /// the request is no longer waiting (an expired one is denied with `approval_expired`).
    public func approve(requestID: UUID, snapshotRevision: String, memoryIDs: [UUID], now: Date) async throws {
        enum Result { case approved, expired, error(VaultError) }
        let result = try await store.writer.write { db -> Result in
            guard let d = try Self.fetch(db, id: requestID) else { return .error(.notFound) }
            guard d.status == .needsApproval else { return .error(.invalidState) }
            if now >= d.createdAt + Self.window {
                try db.execute(sql: "UPDATE disclosure SET status = 'denied', reason = ?, decided_at = ? WHERE id = ?",
                               arguments: [ReasonCode.approvalExpired.rawValue, now, requestID.db])
                return .expired
            }
            guard d.snapshotRevision == snapshotRevision else { return .error(.snapshotChanged) }
            let chosen = Set(memoryIDs)
            let ordered = d.candidateSnapshot.map(\.id).filter(chosen.contains)
            guard !chosen.isEmpty, ordered.count == chosen.count else { return .error(.invalidInput(field: "memory_ids")) }
            try db.execute(sql: """
                UPDATE disclosure SET status = 'approved', approved_memory_ids = ?, approval_expires_at = ?, decided_at = ?
                WHERE id = ?
                """, arguments: [JSON.encode(ordered), now + Self.window, now, requestID.db])
            return .approved
        }
        switch result {
        case .approved:
            activity.record(ActivityEvent(time: now, requestID: requestID, phase: .event, actor: .user, via: .app,
                                          event: "approval", outcome: "approved", counts: ["approved": memoryIDs.count],
                                          approval: .approved))
            notify(requestID)
        case .expired:
            notify(requestID)
            throw VaultError.invalidState
        case let .error(e):
            throw e
        }
    }

    /// Denies a waiting or approved request (`denied_by_user`).
    public func deny(requestID: UUID, now: Date) async throws {
        let changed = try await store.writer.write { db -> Bool in
            try db.execute(sql: """
                UPDATE disclosure SET status = 'denied', reason = ?, decided_at = ? WHERE id = ? AND status IN ('needs_approval', 'approved')
                """, arguments: [ReasonCode.deniedByUser.rawValue, now, requestID.db])
            return db.changesCount > 0
        }
        guard changed else { throw VaultError.invalidState }
        tasks.withLock { _ = $0.removeValue(forKey: requestID) }
        requestGrants.withLock { _ = $0.removeValue(forKey: requestID) }
        activity.record(ActivityEvent(time: now, requestID: requestID, phase: .event, actor: .user, via: .app,
                                      event: "approval", outcome: "denied", reason: .deniedByUser, approval: .denied))
        notify(requestID)
    }

    /// A waiting request replaced by a new one after the user allowed more access (access policy
    /// §7): denied with `policy_changed`, without a denial by the user in Activity. The agent never
    /// saw this request's id; it gets the new request's answer.
    public func supersede(requestID: UUID, now: Date) async throws {
        let changed = try await store.writer.write { db -> Bool in
            try db.execute(sql: """
                UPDATE disclosure SET status = 'denied', reason = ?, decided_at = ? WHERE id = ? AND status = 'needs_approval'
                """, arguments: [ReasonCode.policyChanged.rawValue, now, requestID.db])
            return db.changesCount > 0
        }
        guard changed else { throw VaultError.invalidState }
        tasks.withLock { _ = $0.removeValue(forKey: requestID) }
        requestGrants.withLock { _ = $0.removeValue(forKey: requestID) }
        activity.record(ActivityEvent(time: now, requestID: requestID, phase: .event, actor: .system, via: .app,
                                      event: "approval", outcome: "replaced", reason: .policyChanged))
        notify(requestID)
    }

    // MARK: - Delivery and get_memory_request

    /// `get_memory_request` (§3.8), running delivery (§3.7) when approved, in one transaction.
    public func deliver(requestID: UUID, agentID: UUID, now: Date) async throws -> RequestOutcome {
        let paused = pause.isPaused(at: now)
        let outcome = try await store.writer.write { db -> RequestOutcome in
            guard let agent = try AgentStore.fetch(db, id: agentID), !agent.isRemoved else { throw VaultError.unauthenticated }
            try AgentStore.recordRequest(db, agentID: agentID, now: now)
            // Unknown, or another agent's: the same answer (T20).
            guard let d = try Self.fetch(db, id: requestID), d.agentID == agentID else {
                return RequestOutcome(status: .notFound, requestID: requestID, reason: .notFound, maxTokens: 0)
            }
            var out = RequestOutcome(status: .denied, requestID: requestID, reason: d.reason, withheld: d.withheld,
                                     maxTokens: d.maxTokens)
            func back(to reason: ReasonCode) throws -> RequestOutcome {
                try db.execute(sql: "UPDATE disclosure SET status = 'needs_approval', reason = ? WHERE id = ?",
                               arguments: [reason.rawValue, requestID.db])
                out.status = .needsApproval
                out.reason = reason
                return out
            }
            switch d.status {
            case .needsApproval:
                out.status = .needsApproval
                out.reason = d.reason ?? .confirmationRequired
                return out
            case .delivered, .fulfilled:
                out.status = .alreadyDelivered
                out.reason = .alreadyDelivered
                return out
            case .denied, .failed, .evaluating:
                return out
            case .approved:
                break
            }
            // Funes or the agent paused: refused for now; the approval stands until it expires.
            if paused { out.reason = .funesPaused; return out }
            if agent.paused { out.reason = .agentPaused; return out }
            // Access can expire after approval without a revision change, so re-run the gate (G3, G4).
            let access = self.access(agent, requestID: requestID)
            if let reason = PolicyEngine.gate(agent: agent, access: access, globalPaused: false, now: now) {
                out.reason = reason
                return out
            }
            guard let expires = d.approvalExpiresAt, now <= expires else { return try back(to: .approvalExpired) }
            guard agent.revision == d.agentRevisionAtRequest else { return try back(to: .policyChanged) }
            let approved = d.approvedMemoryIDs ?? []
            let versions = Dictionary(uniqueKeysWithValues: d.candidateSnapshot.map { ($0.id, $0.version) })
            let memories = try MemoryStore.fetch(db, ids: approved)
            let unchanged = memories.count == approved.count && memories.allSatisfy { m in
                m.status == .active && versions[m.id] == m.version
                    && PolicyEngine.eligibility(m, access: access, now: now) == nil
            }
            // The whole request is invalidated, never partly delivered.
            guard !approved.isEmpty, unchanged else { return try back(to: .policyChanged) }
            let bundle = BundleCompiler.compile(memories, maxTokens: d.maxTokens)
            try Self.writeItems(db, disclosureID: requestID, bundle: bundle, agentID: agentID, now: now)
            try db.execute(sql: "UPDATE disclosure SET status = 'delivered', delivered_at = ? WHERE id = ?",
                           arguments: [now, requestID.db])
            out.status = .delivered
            out.reason = nil
            out.bundle = bundle
            return out
        }
        if outcome.status == .delivered {
            tasks.withLock { _ = $0.removeValue(forKey: requestID) }
            requestGrants.withLock { _ = $0.removeValue(forKey: requestID) }
        }
        activity.record(ActivityEvent(
            time: now, requestID: requestID, actor: .agent(agentID), via: .mcp, event: "get_memory_request",
            outcome: outcome.status.rawValue, ids: outcome.bundle?.items.map(\.memoryID) ?? [], reason: outcome.reason,
            approval: outcome.status == .delivered ? .approved : nil))
        return outcome
    }

    // MARK: - Expiry

    /// The minute job (§3.9): requests still waiting 15 minutes after creation are denied with
    /// `approval_expired`, and their task text is dropped. Returns how many.
    @discardableResult
    public func expirePending(now: Date) async throws -> Int {
        let expired = try await store.writer.write { db -> [UUID] in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM disclosure WHERE status = 'needs_approval' AND created_at <= ?
                """, arguments: [now - Self.window]).compactMap(UUID.init(uuidString:))
            for id in ids {
                try db.execute(sql: "UPDATE disclosure SET status = 'denied', reason = ?, decided_at = ? WHERE id = ?",
                               arguments: [ReasonCode.approvalExpired.rawValue, now, id.db])
            }
            return ids
        }
        tasks.withLock { cache in cache = cache.filter { $0.value.expires > now } }
        grants.withLock { g in g = g.filter { !expired.contains($0.key) } }
        requestGrants.withLock { g in g = g.filter { !expired.contains($0.key) } }
        for id in expired {
            activity.record(ActivityEvent(time: now, requestID: id, phase: .event, actor: .system, via: .app, event: "approval",
                                          outcome: "denied", reason: .approvalExpired, approval: .timeout))
            notify(id)
        }
        return expired.count
    }

    // MARK: - Waiting for the panel

    /// Waits until the request is approved or denied, or `timeout` passes, and returns its status.
    public func waitForDecision(requestID: UUID, timeout: Duration) async -> DisclosureStatus? {
        let token = UUID()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.withLock { $0[requestID, default: [:]][token] = c }
            // Checked after registering, so a wait can't slip past `endWaits()`.
            if waitsEnded.withLock({ $0 }) { resume(requestID, token) }
            if let s = try? status(requestID), s != .needsApproval { resume(requestID, token) }
            Task {
                // An explicit tolerance: by default a 45 s sleep may run seconds late (timer
                // coalescing), past the panel's countdown.
                try? await Task.sleep(for: timeout, tolerance: .milliseconds(100))
                self.resume(requestID, token)
            }
        }
        return try? status(requestID)
    }

    /// Funes is quitting: every wait returns now, and later ones at once, with the request's status
    /// as it is. Requests still waiting for the user stay in Pending requests (mcp-server.md §7).
    public func endWaits() {
        waitsEnded.withLock { $0 = true }
        let all = waiters.withLock { w in
            defer { w.removeAll() }
            return w
        }
        for group in all.values { for c in group.values { c.resume() } }
    }

    private func status(_ id: UUID) throws -> DisclosureStatus? {
        try store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT status FROM disclosure WHERE id = ?", arguments: [id.db])?.enumValue("status")
        }
    }

    private func resume(_ requestID: UUID, _ token: UUID) {
        let c = waiters.withLock { w -> CheckedContinuation<Void, Never>? in
            let c = w[requestID]?.removeValue(forKey: token)
            if w[requestID]?.isEmpty == true { w[requestID] = nil }
            return c
        }
        c?.resume()
    }

    private func notify(_ requestID: UUID) {
        let all = waiters.withLock { $0.removeValue(forKey: requestID) } ?? [:]
        for c in all.values { c.resume() }
    }

    // MARK: - Allow window and asking for access

    /// "Allow for 15 minutes" (FR-D-12), bound to the agent's current revision. In memory only.
    public func openAllowWindow(agentID: UUID, now: Date) async throws {
        let revision = try await store.writer.read { db in try AgentStore.fetch(db, id: agentID)?.revision }
        guard let revision else { throw VaultError.notFound }
        windows.withLock { $0[agentID] = AllowWindow(agentID: agentID, revision: revision, until: now + Self.window) }
    }

    public func closeAllowWindow(agentID: UUID) { windows.withLock { _ = $0.removeValue(forKey: agentID) } }

    /// An access request to offer the user, at most once an hour per agent, category and operation
    /// (§7, FR-A-10). Used for reads here and for suggestions by SuggestionService.
    func offer(agentID: UUID, requestID: UUID?, categories: [String], operation: AccessOperation, agentRevision: Int,
               now: Date) -> AccessRequestOffer? {
        var seen = Set<String>()
        let fresh = offered.withLock { offered -> [String] in
            let keys = (categories.isEmpty ? [""] : categories).filter { seen.insert($0).inserted }
            let due = keys.filter { key in
                offered["\(agentID.db)|\(key)|\(operation.rawValue)"].map { now.timeIntervalSince($0) >= Self.accessOfferInterval } ?? true
            }
            for key in due { offered["\(agentID.db)|\(key)|\(operation.rawValue)"] = now }
            return due
        }
        guard !fresh.isEmpty else { return nil }
        let categoryKeys = fresh.filter { !$0.isEmpty }
        if let requestID, !categoryKeys.isEmpty { grants.withLock { $0[requestID, default: []].formUnion(categoryKeys) } }
        return AccessRequestOffer(agentID: agentID, requestID: requestID, categoryKeys: categoryKeys, operation: operation,
                                  agentRevision: agentRevision)
    }

    /// The access a stored request is evaluated with: the agent's, plus the Allow Once grant the
    /// request was made with while the agent's revision still matches (§7). Any change to the
    /// agent's access bumps the revision and drops the grant, so the request fails closed.
    private func access(_ agent: Agent, requestID: UUID) -> Access {
        var access = agent.access
        if let grant = requestGrants.withLock({ $0[requestID] }), grant.agentRevision == agent.revision {
            access.allowedCategoryKeys.insert(grant.categoryKey)
        }
        return access
    }

    /// Validates and consumes an Allow Once grant; returns the access to evaluate with.
    private func useGrant(_ grant: OnceGrant?, agent: Agent) throws -> Access {
        var access = agent.access
        guard let grant else { return access }
        let ok = grants.withLock { g -> Bool in
            guard grant.agentRevision == agent.revision, g[grant.offeredByRequestID]?.contains(grant.categoryKey) == true else {
                return false
            }
            g[grant.offeredByRequestID]?.remove(grant.categoryKey)
            return true
        }
        guard ok else { throw VaultError.invalidState }
        access.allowedCategoryKeys.insert(grant.categoryKey)
        return access
    }

    // MARK: - Rows

    static func snapshotRevision(agentID: UUID, agentRevision: Int, items: [SnapshotItem]) -> String {
        struct Canonical: Encodable {
            let agentId: String, agentRevision: Int, items: [Item], instructionsVersion: Int
            struct Item: Encodable { let id: String, version: Int }
        }
        let canonical = Canonical(agentId: agentID.db, agentRevision: agentRevision,
                                  items: items.map { .init(id: $0.id.db, version: $0.version) },
                                  instructionsVersion: BundleCompiler.instructionsVersion)
        return SHA256.hash(data: Data(JSON.encode(canonical).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func taskHash(_ task: String, _ keywords: [String]) -> String {
        SHA256.hash(data: Data(JSON.encode([task] + keywords).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func newRow(id: UUID, agent: Agent, input: MemoryRequest, now: Date) -> Disclosure {
        Disclosure(id: id, agentID: agent.id, agentRevisionAtRequest: agent.revision,
                   taskHash: taskHash(input.task, input.keywords), taskLength: InputLimits.length(of: input.task),
                   purpose: input.purpose, retention: input.retention, processors: input.processors,
                   maxTokens: input.maxTokens, requestedCategoryKeys: input.categories, status: .evaluating,
                   candidateSnapshot: [], withheld: [:], createdAt: now)
    }

    static func insert(_ db: Database, _ d: Disclosure) throws {
        try db.execute(sql: """
            INSERT INTO disclosure (id, agent_id, agent_revision, task_hash, task_length, purpose, retention, processors,
              max_tokens, requested_categories, status, reason, candidate_snapshot, snapshot_revision, withheld,
              created_at, decided_at, delivered_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [d.id.db, d.agentID.db, d.agentRevisionAtRequest, d.taskHash, d.taskLength, d.purpose,
                             d.retention.rawValue, JSON.encode(d.processors), d.maxTokens, JSON.encode(d.requestedCategoryKeys),
                             d.status.rawValue, d.reason?.rawValue, JSON.encode(d.candidateSnapshot), d.snapshotRevision,
                             d.withheld.json, d.createdAt, d.decidedAt, d.deliveredAt])
    }

    static func fetch(_ db: Database, id: UUID) throws -> Disclosure? {
        try Row.fetchOne(db, sql: "SELECT * FROM disclosure WHERE id = ?", arguments: [id.db]).map(Disclosure.from(row:))
    }

    /// Delivery's writes: one DisclosureItem and one `shared` provenance row per released memory.
    static func writeItems(_ db: Database, disclosureID: UUID, bundle: MemoryBundle, agentID: UUID, now: Date) throws {
        for item in bundle.items {
            try db.execute(sql: """
                INSERT INTO disclosure_item (disclosure_id, memory_id, memory_version, category_key, sensitivity,
                  estimated_tokens, clipped) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [disclosureID.db, item.memoryID.db, item.memoryVersion, item.category,
                                 item.sensitivity.rawValue, item.estimatedTokens, item.clipped])
            try MemoryStore.appendProvenance(db, memoryID: item.memoryID, event: .shared, actor: .agent(agentID), at: now)
        }
    }

    /// The DisclosureItems of a delivered request.
    public func items(requestID: UUID) async throws -> [DisclosureItem] {
        try await store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM disclosure_item WHERE disclosure_id = ?", arguments: [requestID.db]).map { r in
                DisclosureItem(disclosureID: requestID, memoryID: try r.requiredUUID("memory_id"), memoryVersion: r["memory_version"],
                               sensitivity: r.sensitivity("sensitivity") ?? .secret, categoryKey: r["category_key"],
                               estimatedTokens: r["estimated_tokens"], clipped: r["clipped"])
            }
        }
    }

    public func disclosure(requestID: UUID) async throws -> Disclosure? {
        try await store.writer.read { db in try Self.fetch(db, id: requestID) }
    }
}
