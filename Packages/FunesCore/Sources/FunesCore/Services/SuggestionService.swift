import Foundation
import FunesProtocol
import GRDB

/// A `suggest_memory` call (spec/architecture/mcp-server.md §6.4).
public struct SuggestInput: Sendable, Hashable {
    public var title: String
    public var body: String
    public var kind: MemoryKind?
    /// Empty: proposed by classification, falling back to `personal_preferences`.
    public var categories: [String]
    /// nil: LOW, raised to the categories' default (SENSITIVE for Health, Finance and Legal).
    public var sensitivity: Sensitivity?
    public var evidence: String?
    public var purpose: String?
    public var expiresAt: Date?
    public var confidence: Double?
    public var targetMemoryID: UUID?
    /// The caller's `metadata` object, serialized; stored inert (FR-S-05).
    public var metadataJSON: String?

    public init(title: String, body: String, kind: MemoryKind? = nil, categories: [String] = [],
                sensitivity: Sensitivity? = nil, evidence: String? = nil, purpose: String? = nil, expiresAt: Date? = nil,
                confidence: Double? = nil, targetMemoryID: UUID? = nil, metadataJSON: String? = nil) {
        self.title = title
        self.body = body
        self.kind = kind
        self.categories = categories
        self.sensitivity = sensitivity
        self.evidence = evidence
        self.purpose = purpose
        self.expiresAt = expiresAt
        self.confidence = confidence
        self.targetMemoryID = targetMemoryID
        self.metadataJSON = metadataJSON
    }
}

public enum SuggestStatus: String, Sendable, Codable {
    case saved, queued, denied
}

public struct SuggestOutcome: Sendable, Hashable {
    public var status: SuggestStatus
    public var memoryID: UUID?
    public var suggestionID: UUID?
    public var reason: ReasonCode?
    /// Pattern types for `secret_like_content`; never the text.
    public var findings: [SecretPattern]
    /// For the Mac's UI only.
    public var accessOffer: AccessRequestOffer?

    static func denied(_ reason: ReasonCode, findings: [SecretPattern] = []) -> SuggestOutcome {
        SuggestOutcome(status: .denied, reason: reason, findings: findings)
    }
}

/// The user's edits when applying a suggestion (FR-I-02 Edit & Apply); nil keeps the proposal.
public struct SuggestionEdit: Sendable, Hashable {
    public var title: String?
    public var body: String?
    public var kind: MemoryKind?
    public var categoryKeys: [String]?
    public var sensitivity: Sensitivity?
    public var expiresAt: Date??

    public init(title: String? = nil, body: String? = nil, kind: MemoryKind? = nil, categoryKeys: [String]? = nil,
                sensitivity: Sensitivity? = nil, expiresAt: Date?? = nil) {
        self.title = title
        self.body = body
        self.kind = kind
        self.categoryKeys = categoryKeys
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
    }
}

/// How to apply a suggestion (FR-I-02). An `update` takes Replace (the default) or Keep both
/// (FR-S-06); a `conflict` needs the user's answer. Every other action applies one way and
/// refuses a mode.
public enum ApplyMode: Sendable, Hashable {
    /// `update`: the target takes the proposal.
    case replace
    /// `update`: the proposal becomes a new memory and the target stays as it is.
    case keepBoth
    /// `conflict`: keep this memory, changed by the edits if there are any ("Edit…"), and archive
    /// the other.
    case keep(UUID)
    /// `conflict`: both are true; no memory changes.
    case bothTrue
}

public struct ApplyResult: Sendable, Hashable {
    /// The memory created or updated; the target of an archive or a duplicate; the memory kept
    /// in a conflict (the first for Both are true); a split's first piece.
    public var memoryID: UUID
    /// Every memory created, changed or archived, in that order.
    public var memoryIDs: [UUID]
    /// "Similar memory exists" (FR-V-13): active memories with the same normalized text. A hint only.
    public var similarMemoryIDs: [UUID]
}

/// Agent suggestions and direct writes (access policy §5) and the Inbox (FR-I-01..05).
public final class SuggestionService: Sendable {
    public static let lifetime: TimeInterval = 30 * 86_400
    public static let restorable: TimeInterval = 7 * 86_400

    public let store: VaultStore
    public let activity: any ActivityRecorder
    public let pause: FunesPause
    /// Asking for access shares DisclosureService's once-an-hour throttle.
    public let disclosures: DisclosureService?

    public init(store: VaultStore, activity: any ActivityRecorder, pause: FunesPause, disclosures: DisclosureService? = nil) {
        self.store = store
        self.activity = activity
        self.pause = pause
        self.disclosures = disclosures
    }

    // MARK: - suggest_memory

    /// Validation, the secret scanner, the gate, the scope check, then save, queue or deny
    /// (§5.1–5.4). Never blocks for the user; a validation failure stores nothing.
    ///
    /// `allowOnce` is an offer this service made for an earlier, refused call of the same suggestion,
    /// answered Allow Once by the user (access policy §7). It counts for this call only, and only
    /// while the agent's revision is the one the offer was made at: a stale grant is refused with
    /// `policy_changed` before it touches anything. A category offer adds only that category (never
    /// to an "all categories" access); an operation offer adds only that operation. Neither lifts a
    /// ceiling or a denial.
    ///
    /// `alwaysQueue` stores the suggestion in the Inbox even when the agent may save directly: a
    /// suggestion let through after an access request always waits for review (§7).
    /// `via` is for Activity only (ADR-0018).
    public func suggest(agentID: UUID, _ input: SuggestInput, now: Date, allowOnce: AccessRequestOffer? = nil,
                        alwaysQueue: Bool = false, via: ActivityEvent.Via = .mcp,
                        credential: CredentialCheck? = nil) async throws -> SuggestOutcome {
        let paused = pause.isPaused(at: now)
        enum Step { case done(SuggestOutcome), offer(SuggestOutcome, [String], AccessOperation, Int) }
        let step = try await store.writer.write { db -> Step in
            guard let agent = try AgentStore.fetch(db, id: agentID), !agent.isRemoved else { throw VaultError.unauthenticated }
            if let credential, !credential(agent) { throw VaultError.unauthenticated }
            try AgentStore.recordRequest(db, agentID: agentID, now: now)
            var access = agent.access
            if let once = allowOnce {
                guard once.agentID == agentID, once.agentRevision == agent.revision else {
                    return .done(.denied(.policyChanged))
                }
                if once.categoryKeys.isEmpty {
                    access.operations.insert(once.operation)
                } else if !access.allowedCategoryKeys.isEmpty {
                    access.allowedCategoryKeys.formUnion(once.categoryKeys)
                }
            }

            // §5.1 validation. Any failure: nothing stored.
            if let reason = Self.invalid(input, now: now) { return .done(.denied(reason)) }
            let known = Set(try String.fetchAll(db, sql: "SELECT key FROM category"))
            if input.categories.contains(where: { !known.contains($0) }) { return .done(.denied(.unknownCategory)) }
            let findings = SecretScanner.scan([input.title, input.body, input.evidence ?? "", input.metadataJSON ?? ""])
            if !findings.isEmpty { return .done(.denied(.secretLikeContent, findings: findings)) }
            if let target = input.targetMemoryID {
                // Never reveal that a memory exists: anything this agent couldn't read is not_found.
                guard let m = try MemoryStore.fetch(db, id: target),
                      PolicyEngine.eligibility(m, access: access, now: now) == nil else { return .done(.denied(.notFound)) }
            }

            // §5.2 gate (G1–G3).
            if let reason = PolicyEngine.gate(agent: agent, access: access, globalPaused: paused, now: now, requiring: nil) {
                return .done(.denied(reason))
            }

            // §5.3 scope of the proposed memory.
            let categories = try Self.categories(db, input)
            let sensitivity = try input.sensitivity ?? MemoryStore.defaultSensitivity(db, categoryKeys: categories)
            if let reason = PolicyEngine.scopeCheck(sensitivity: sensitivity, categoryKeys: categories, access: access) {
                let out = SuggestOutcome.denied(reason)
                return reason == .categoryNotAllowed && agent.asksForAccess
                    ? .offer(out, categories, .suggest, agent.revision) : .done(out)
            }

            // §5.4 decision. Corrections are always suggestions (FR-S-06).
            let ops = access.operations
            if ops.contains(.write), !access.askBeforeSaving, input.targetMemoryID == nil, !alwaysQueue {
                let m = try MemoryStore.insert(db, MemoryDraft(
                    title: input.title, body: input.body, kind: input.kind ?? .fact, categoryKeys: categories,
                    sensitivity: sensitivity, expiresAt: input.expiresAt, confidence: input.confidence ?? 0.5,
                    source: .agentWrite, sourceAgentID: agentID), actor: .agent(agentID), now: now)
                // Saved, then processed in the background (memory processing §5.6).
                try ProcessingQueue.enqueue(db, subject: m.id, now: now)
                return .done(SuggestOutcome(status: .saved, memoryID: m.id, findings: []))
            }
            if ops.contains(.suggest) || ops.contains(.write) {
                let id = try Self.insertSuggestion(db, origin: .agent, agentID: agentID, input: input, categories: categories,
                                                   sensitivity: sensitivity, now: now)
                if let target = input.targetMemoryID {
                    try MemoryStore.appendProvenance(db, memoryID: target, event: .suggestedCorrection, actor: .agent(agentID), at: now)
                }
                return .done(SuggestOutcome(status: .queued, suggestionID: id, findings: []))
            }
            let out = SuggestOutcome.denied(.operationNotAllowed)
            return agent.asksForAccess ? .offer(out, [], .suggest, agent.revision) : .done(out)
        }

        var outcome: SuggestOutcome
        switch step {
        case let .done(o): outcome = o
        case let .offer(o, categories, operation, revision):
            outcome = o
            outcome.accessOffer = disclosures?.offer(agentID: agentID, requestID: nil, categories: categories,
                                                     operation: operation, agentRevision: revision, now: now)
        }
        activity.record(ActivityEvent(
            time: now, actor: .agent(agentID), via: via, event: "suggest_memory", outcome: outcome.status.rawValue,
            ids: [outcome.memoryID, outcome.suggestionID].compactMap { $0 }, reason: outcome.reason,
            counts: Dictionary(uniqueKeysWithValues: outcome.findings.map { ($0.rawValue, 1) })))
        return outcome
    }

    static func invalid(_ input: SuggestInput, now: Date) -> ReasonCode? {
        let len = InputLimits.length(of:)
        guard InputLimits.title.contains(len(input.title)), InputLimits.body.contains(len(input.body)),
              (input.evidence.map(len) ?? 0) <= InputLimits.evidence, (input.purpose.map(len) ?? 0) <= InputLimits.purpose,
              input.categories.count <= InputLimits.memoryCategories,
              (input.confidence.map { (0...1).contains($0) } ?? true),
              (input.expiresAt.map { $0 > now } ?? true) else { return .invalidInput }
        if let metadata = input.metadataJSON {
            guard metadata.utf8.count <= InputLimits.callerMetadataBytes,
                  (try? JSONSerialization.jsonObject(with: Data(metadata.utf8))) is [String: Any] else { return .invalidInput }
        }
        return nil
    }

    /// The given categories, or the rules classifier's, or `personal_preferences`.
    static func categories(_ db: Database, _ input: SuggestInput) throws -> [String] {
        if !input.categories.isEmpty { return try MemoryStore.validateCategories(db, input.categories) }
        let proposal = RulesClassifier.propose(input.title + "\n" + input.body, categories: try CategoryStore.all(db))
        return try MemoryStore.validateCategories(db, proposal.categoryKeys)
    }

    /// Stores a pending suggestion. A targeted one records its target's current version, which
    /// apply checks (`targetChanged`); `targets` are a merge's, split's or conflict's other
    /// memories, at their current versions. `action` defaults to `update` with a target and
    /// `create` without. `process` queues the new input's processing job in the same transaction
    /// (memory processing §5.2): every ingest path, but not corrections, tidy-up proposals, the
    /// pieces of a split or a Funes export restore.
    static func insertSuggestion(_ db: Database, origin: SuggestionOrigin, agentID: UUID? = nil, deviceID: UUID? = nil,
                                 importRunID: UUID? = nil, captureID: UUID? = nil, action: SuggestionAction? = nil,
                                 input: SuggestInput, categories: [String], sensitivity: Sensitivity?,
                                 classification: String? = nil, targets: [(UUID, SuggestionTarget.Role)] = [],
                                 groupID: UUID? = nil, process: Bool = true, now: Date) throws -> UUID {
        let id = UUID()
        let targetVersion = try input.targetMemoryID.flatMap {
            try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [$0.db])
        }
        if input.targetMemoryID != nil, targetVersion == nil { throw VaultError.notFound }
        try db.execute(sql: """
            INSERT INTO suggestion (id, origin, agent_id, device_id, import_run_id, capture_id, target_memory_id,
              target_memory_version, action, title, body, kind, category_keys, sensitivity, expires_at, confidence,
              evidence, purpose, caller_metadata, classification, status, created_at, expires_after, group_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)
            """, arguments: [id.db, origin.rawValue, agentID?.db, deviceID?.db, importRunID?.db, captureID?.db,
                             input.targetMemoryID?.db, targetVersion,
                             (action ?? (input.targetMemoryID == nil ? .create : .update)).rawValue,
                             input.title, input.body, input.kind?.rawValue, JSON.encode(categories), sensitivity?.rawValue,
                             input.expiresAt, input.confidence, input.evidence, input.purpose, input.metadataJSON,
                             classification, now, now + lifetime, groupID?.db])
        if process, origin != .consolidation, groupID == nil, input.targetMemoryID == nil, targets.isEmpty {
            try ProcessingQueue.enqueue(db, subject: id, now: now)
        }
        for (position, (memoryID, role)) in targets.enumerated() {
            guard let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [memoryID.db]) else {
                throw VaultError.notFound
            }
            try db.execute(sql: """
                INSERT INTO suggestion_target (suggestion_id, memory_id, memory_version, role, position) VALUES (?, ?, ?, ?, ?)
                """, arguments: [id.db, memoryID.db, version, role.rawValue, position])
        }
        return id
    }

    // MARK: - Inbox

    public func suggestion(id: UUID) async throws -> Suggestion? {
        try await store.writer.read { db in try Self.fetch(db, id: id) }
    }

    static func fetch(_ db: Database, id: UUID) throws -> Suggestion? {
        try Row.fetchOne(db, sql: "SELECT * FROM suggestion WHERE id = ?", arguments: [id.db]).map(Suggestion.from(row:))
    }

    /// Pending suggestions, newest first (FR-I-01). `count` is the badge (FR-I-04).
    public func pending() async throws -> [Suggestion] {
        try await store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM suggestion WHERE status = 'pending' ORDER BY created_at DESC")
                .map(Suggestion.from(row:))
        }
    }

    /// The memories a suggestion refers to beyond its single target: a merge's sources, a
    /// conflict's two memories, an archive's survivor. In order.
    public func targets(suggestionID: UUID) async throws -> [SuggestionTarget] {
        try await store.writer.read { db in try Self.extraTargets(db, suggestionID: suggestionID) }
    }

    /// The pending pieces of a split (or of a split input), in the order they were made.
    public func pieces(groupID: UUID) async throws -> [Suggestion] {
        try await store.writer.read { db in try Self.pieces(db, groupID: groupID) }
    }

    /// True when a memory the suggestion refers to changed, or was archived or deleted, since it
    /// was suggested: Apply would refuse it with `targetChanged` (Keep both excepted).
    public func isStale(_ suggestion: Suggestion) async throws -> Bool {
        try await store.writer.read { db in
            do {
                _ = try Self.checked(db, Self.refs(db, suggestion))
                return false
            } catch VaultError.targetChanged {
                return true
            }
        }
    }

    /// Review Again for a stale suggestion (domain model: stale → Apply shows the current memory
    /// and asks again): records its memories' current versions, so the next Apply checks against
    /// what the card shows now. A memory that is no longer active can't be reviewed again:
    /// `targetChanged`, and the suggestion stays as it was.
    public func reviewAgain(suggestionID: UUID) async throws {
        try await store.writer.write { db in
            guard let s = try Self.fetch(db, id: suggestionID) else { throw VaultError.notFound }
            guard s.status == .pending else { throw VaultError.invalidState }
            let current = try Self.checked(db, Self.refs(db, s).map { Ref(memoryID: $0.memoryID, version: nil, role: $0.role) })
            if let target = s.targetMemoryID, let m = current[target] {
                try db.execute(sql: "UPDATE suggestion SET target_memory_version = ? WHERE id = ?",
                               arguments: [m.version, suggestionID.db])
            }
            for (id, m) in current {
                try db.execute(sql: "UPDATE suggestion_target SET memory_version = ? WHERE suggestion_id = ? AND memory_id = ?",
                               arguments: [m.version, suggestionID.db, id.db])
            }
        }
    }

    /// Applies the suggestion as its own action, in one transaction with its status (FR-I-02):
    /// `create` saves a memory; `update` changes its target (Replace) or saves a new memory
    /// (Keep both); `archive` archives its target; `duplicate` changes nothing; `split` saves its
    /// pending pieces and archives the original; `merge` saves one memory and archives its
    /// sources; `conflict` keeps the memory the user chose. Every memory changed or archived
    /// must still be active at the version the suggestion was made on (`targetChanged`).
    /// New text goes through validation and the secret scanner again.
    @discardableResult
    public func apply(suggestionID: UUID, edits: SuggestionEdit = SuggestionEdit(), mode: ApplyMode? = nil,
                      now: Date, actor: Actor = .user, via: ActivityEvent.Via = .app) async throws -> ApplyResult {
        let result = try await store.writer.write { db -> ApplyResult in
            guard let s = try Self.fetch(db, id: suggestionID) else { throw VaultError.notFound }
            guard s.status == .pending else { throw VaultError.invalidState }
            let result = try Self.applyAction(db, s, edits: edits, mode: mode, now: now, actor: actor)
            try db.execute(sql: "UPDATE suggestion SET status = 'applied', decided_at = ?, result_memory_id = ? WHERE id = ?",
                           arguments: [now, result.memoryID.db, suggestionID.db])
            return result
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: actor, via: via, event: "suggestion_applied",
                                      outcome: "applied", ids: [suggestionID] + result.memoryIDs))
        return result
    }

    /// A memory the suggestion refers to, at the version it was made on (nil: made before v0.3,
    /// so only checked for being active).
    struct Ref {
        var memoryID: UUID
        var version: Int?
        var role: SuggestionTarget.Role
    }

    static func extraTargets(_ db: Database, suggestionID: UUID) throws -> [SuggestionTarget] {
        try Row.fetchAll(db, sql: "SELECT * FROM suggestion_target WHERE suggestion_id = ? ORDER BY position",
                         arguments: [suggestionID.db]).map { row in
            SuggestionTarget(memoryID: try row.requiredUUID("memory_id"), memoryVersion: row["memory_version"],
                             role: try row.required("role"))
        }
    }

    static func pieces(_ db: Database, groupID: UUID) throws -> [Suggestion] {
        try Row.fetchAll(db, sql: "SELECT * FROM suggestion WHERE group_id = ? AND status = 'pending' ORDER BY created_at, rowid",
                         arguments: [groupID.db]).map(Suggestion.from(row:))
    }

    /// The single target first, then the others in order.
    static func refs(_ db: Database, _ s: Suggestion) throws -> [Ref] {
        var refs = s.targetMemoryID.map { [Ref(memoryID: $0, version: s.targetMemoryVersion, role: .target)] } ?? []
        for t in try extraTargets(db, suggestionID: s.id) where t.memoryID != s.targetMemoryID {
            refs.append(Ref(memoryID: t.memoryID, version: t.memoryVersion, role: t.role))
        }
        return refs
    }

    /// The memories, each still active at its version; otherwise `targetChanged`.
    static func checked(_ db: Database, _ refs: [Ref]) throws -> [UUID: Memory] {
        var out: [UUID: Memory] = [:]
        for ref in refs {
            guard let m = try MemoryStore.fetch(db, id: ref.memoryID), m.status == .active,
                  ref.version.map({ $0 == m.version }) ?? true else { throw VaultError.targetChanged }
            out[ref.memoryID] = m
        }
        return out
    }

    /// The proposal with the user's edits, validated; `fallback` categories when it has none.
    static func draft(_ db: Database, _ s: Suggestion, _ edits: SuggestionEdit, fallback: [String] = ["personal_preferences"],
                      kind: MemoryKind = .fact, sensitivity: Sensitivity? = nil, source: MemorySource,
                      actor: Actor) throws -> MemoryDraft {
        var categories = edits.categoryKeys ?? s.categoryKeys
        if categories.isEmpty { categories = fallback }
        return MemoryDraft(
            title: edits.title ?? s.title, body: edits.body ?? s.body, kind: edits.kind ?? s.kind ?? kind,
            categoryKeys: try MemoryStore.validateCategories(db, categories),
            sensitivity: edits.sensitivity ?? s.sensitivity ?? sensitivity, expiresAt: edits.expiresAt ?? s.expiresAt,
            confidence: s.confidence, source: source, sourceAgentID: s.agentID, sourceDeviceID: s.deviceID,
            // The owner applying it vouches for it; anything else (auto-apply) doesn't.
            trust: actor.isOwner ? .trusted : .untrusted)
    }

    static func applyAction(_ db: Database, _ s: Suggestion, edits: SuggestionEdit, mode: ApplyMode?, now: Date,
                            actor: Actor) throws -> ApplyResult {
        let refs = try refs(db, s)
        let origin = try originActor(db, s)
        func similar(_ m: Memory) throws -> [UUID] { try MemoryStore.exactDuplicates(db, title: m.title, body: m.body, excluding: m.id) }
        func applied(_ id: UUID, related: UUID? = nil) throws {
            try MemoryStore.appendProvenance(db, memoryID: id, event: .appliedFromSuggestion, actor: actor, at: now,
                                             relatedMemoryID: related)
        }
        func saveProposal() throws -> ApplyResult {
            let m = try MemoryStore.insert(db, draft(db, s, edits, source: origin.source, actor: actor), actor: origin.actor, now: now)
            try applied(m.id)
            return ApplyResult(memoryID: m.id, memoryIDs: [m.id], similarMemoryIDs: try similar(m))
        }

        switch s.action {
        case .create:
            guard mode == nil || mode == .keepBoth else { throw VaultError.unsupportedAction }
            return try saveProposal()

        case .update:
            switch mode ?? .replace {
            case .keepBoth:
                return try saveProposal()
            case .replace:
                guard let target = refs.first(where: { $0.role == .target }) else { throw VaultError.targetChanged }
                _ = try checked(db, [target])
                let d = try draft(db, s, edits, source: origin.source, actor: actor)
                let m = try MemoryStore.update(db, id: target.memoryID, MemoryEdit(
                    title: d.title, body: d.body, kind: edits.kind ?? s.kind, categoryKeys: d.categoryKeys,
                    sensitivity: d.sensitivity, expiresAt: .some(d.expiresAt)), actor: actor, now: now)
                try applied(m.id)
                return ApplyResult(memoryID: m.id, memoryIDs: [m.id], similarMemoryIDs: try similar(m))
            case .keep, .bothTrue:
                throw VaultError.unsupportedAction
            }

        case .archive:
            guard mode == nil else { throw VaultError.unsupportedAction }
            guard let target = refs.first(where: { $0.role == .target }) else { throw VaultError.targetChanged }
            _ = try checked(db, refs)
            let survivor = refs.first { $0.role == .survivor }?.memoryID
            try MemoryStore.setStatus(db, id: target.memoryID, to: .archived, actor: actor, now: now)
            try applied(target.memoryID, related: survivor)
            return ApplyResult(memoryID: target.memoryID, memoryIDs: [target.memoryID], similarMemoryIDs: [])

        case .duplicate:
            guard mode == nil else { throw VaultError.unsupportedAction }
            guard let target = refs.first else { throw VaultError.targetChanged }
            _ = try checked(db, refs)
            return ApplyResult(memoryID: target.memoryID, memoryIDs: [], similarMemoryIDs: [])

        case .split:
            guard mode == nil else { throw VaultError.unsupportedAction }
            guard let target = refs.first(where: { $0.role == .target }),
                  let original = try checked(db, refs)[target.memoryID] else { throw VaultError.targetChanged }
            let pieces = try pieces(db, groupID: s.id)
            guard !pieces.isEmpty else { throw VaultError.invalidState }
            var ids: [UUID] = []
            for piece in pieces {
                // A piece never goes below the original's sensitivity (memory processing §9.4).
                var d = try draft(db, piece, SuggestionEdit(), fallback: original.categoryKeys, kind: original.kind,
                                  source: .tidyUp, actor: actor)
                d.sensitivity = max(try d.sensitivity ?? MemoryStore.defaultSensitivity(db, categoryKeys: d.categoryKeys),
                                    original.sensitivity)
                d.sourceAgentID = original.sourceAgentID
                d.sourceDeviceID = original.sourceDeviceID
                let m = try MemoryStore.insert(db, d, actor: actor, now: now)
                try MemoryStore.appendProvenance(db, memoryID: m.id, event: .splitFrom, actor: actor, at: now, relatedMemoryID: original.id)
                try MemoryStore.appendProvenance(db, memoryID: original.id, event: .splitInto, actor: actor, at: now, relatedMemoryID: m.id)
                try db.execute(sql: "UPDATE suggestion SET status = 'applied', decided_at = ?, result_memory_id = ? WHERE id = ?",
                               arguments: [now, m.id.db, piece.id.db])
                ids.append(m.id)
            }
            try MemoryStore.setStatus(db, id: original.id, to: .archived, actor: actor, now: now)
            try applied(original.id)
            return ApplyResult(memoryID: ids[0], memoryIDs: ids + [original.id], similarMemoryIDs: [])

        case .merge:
            guard mode == nil else { throw VaultError.unsupportedAction }
            let sources = refs.filter { $0.role == .source }
            guard sources.count >= 2 else { throw VaultError.invalidState }
            let current = try checked(db, sources)
            let first = current[sources[0].memoryID]!
            var d = try draft(db, s, edits, fallback: first.categoryKeys, kind: first.kind,
                              sensitivity: current.values.map(\.sensitivity).max(), source: .tidyUp, actor: actor)
            d.sourceAgentID = nil
            d.sourceDeviceID = nil
            let m = try MemoryStore.insert(db, d, actor: actor, now: now)
            try applied(m.id)
            for source in sources {
                try MemoryStore.appendProvenance(db, memoryID: m.id, event: .mergedFrom, actor: actor, at: now,
                                                 relatedMemoryID: source.memoryID)
                try MemoryStore.setStatus(db, id: source.memoryID, to: .archived, actor: actor, now: now)
                try MemoryStore.appendProvenance(db, memoryID: source.memoryID, event: .mergedInto, actor: actor, at: now,
                                                 relatedMemoryID: m.id)
            }
            return ApplyResult(memoryID: m.id, memoryIDs: [m.id] + sources.map(\.memoryID), similarMemoryIDs: try similar(m))

        case .conflict:
            let pair = refs.filter { $0.role == .target }
            guard pair.count == 2 else { throw VaultError.invalidState }
            switch mode {
            case .bothTrue:
                _ = try checked(db, pair)
                return ApplyResult(memoryID: pair[0].memoryID, memoryIDs: [], similarMemoryIDs: [])
            case let .keep(kept) where pair.contains(where: { $0.memoryID == kept }):
                _ = try checked(db, pair)
                var ids = [kept]
                let edit = MemoryEdit(title: edits.title, body: edits.body, kind: edits.kind, categoryKeys: edits.categoryKeys,
                                      sensitivity: edits.sensitivity, expiresAt: edits.expiresAt)
                if edit != MemoryEdit() { try MemoryStore.update(db, id: kept, edit, actor: actor, now: now) }
                try applied(kept)
                for other in pair where other.memoryID != kept {
                    try MemoryStore.setStatus(db, id: other.memoryID, to: .archived, actor: actor, now: now)
                    try applied(other.memoryID, related: kept)
                    ids.append(other.memoryID)
                }
                return ApplyResult(memoryID: kept, memoryIDs: ids, similarMemoryIDs: [])
            default:
                throw VaultError.unsupportedAction
            }

        case .unknown:
            throw VaultError.unsupportedAction
        }
    }

    /// The memory source and provenance actor for a suggestion's origin.
    static func originActor(_ db: Database, _ s: Suggestion) throws -> (source: MemorySource, actor: Actor) {
        switch s.origin {
        case .agent: return (.agentSuggestion, s.agentID.map(Actor.agent) ?? .user)
        case .captureMac: return (.captureMac, .user)
        case .captureIPhone: return (.captureIPhone, s.deviceID.map(Actor.device) ?? .user)
        case .seedQuestion: return (.seedQuestion, .user)
        case .consolidation: return (.tidyUp, .system)
        case .import:
            let source = try s.importRunID.flatMap {
                try String.fetchOne(db, sql: "SELECT source FROM import_run WHERE id = ?", arguments: [$0.db])
            }
            let mapped: MemorySource = switch source {
            case "chatgpt": .importChatGPT
            case "claude": .importClaude
            case "markdown": .importMarkdown
            default: .importFunes
            }
            return (mapped, s.importRunID.map(Actor.importRun) ?? .user)
        }
    }

    /// Reject / Discard (FR-I-02). Activity keeps the id only.
    public func reject(suggestionID: UUID, now: Date, actor: Actor = .user, via: ActivityEvent.Via = .app) async throws {
        try await setStatus(suggestionID, from: .pending, to: .rejected, now: now)
        activity.record(ActivityEvent(time: now, phase: .event, actor: actor, via: via, event: "suggestion_rejected",
                                      outcome: "rejected", ids: [suggestionID]))
    }

    /// Restores an expired suggestion within 7 days of its expiry (FR-I-05), for another 30 days.
    public func restore(suggestionID: UUID, now: Date) async throws {
        try await store.writer.write { db in
            guard let s = try Self.fetch(db, id: suggestionID) else { throw VaultError.notFound }
            guard s.status == .expired, now < s.expiresAfter + Self.restorable else { throw VaultError.invalidState }
            try db.execute(sql: "UPDATE suggestion SET status = 'pending', decided_at = NULL, expires_after = ? WHERE id = ?",
                           arguments: [now + Self.lifetime, suggestionID.db])
        }
    }

    private func setStatus(_ id: UUID, from: SuggestionStatus, to: SuggestionStatus, now: Date) async throws {
        try await store.writer.write { db in
            guard let s = try Self.fetch(db, id: id) else { throw VaultError.notFound }
            guard s.status == from else { throw VaultError.invalidState }
            try db.execute(sql: "UPDATE suggestion SET status = ?, decided_at = ? WHERE id = ?",
                           arguments: [to.rawValue, now, id.db])
        }
    }

    /// The hourly job (storage §5): pending → expired after 30 days; expired ones deleted 7 days
    /// later, except while a capture receipt still points at them (receipts live 90 days).
    @discardableResult
    public func expire(now: Date) async throws -> (expired: Int, deleted: Int) {
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE suggestion SET status = 'expired', decided_at = ? WHERE status = 'pending' AND expires_after <= ?",
                           arguments: [now, now])
            let expired = db.changesCount
            try db.execute(sql: """
                DELETE FROM suggestion WHERE status = 'expired' AND expires_after <= ?
                  AND id NOT IN (SELECT suggestion_id FROM capture_receipt)
                """, arguments: [now - Self.restorable])
            return (expired, db.changesCount)
        }
    }
}
