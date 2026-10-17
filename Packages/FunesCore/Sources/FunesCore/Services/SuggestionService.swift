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

/// Applying a correction (FR-S-06): replace the existing memory, or keep both.
public enum ApplyMode: Sendable, Hashable { case replace, keepBoth }

public struct ApplyResult: Sendable, Hashable {
    public var memoryID: UUID
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
    /// answered Allow Once by the user (access policy §7): its category or operation counts for this
    /// call only. It never widens an "all categories" access, and never lifts a ceiling or a denial.
    public func suggest(agentID: UUID, _ input: SuggestInput, now: Date,
                        allowOnce: AccessRequestOffer? = nil) async throws -> SuggestOutcome {
        let paused = pause.isPaused(at: now)
        enum Step { case done(SuggestOutcome), offer(SuggestOutcome, [String], AccessOperation) }
        let step = try await store.writer.write { db -> Step in
            guard let agent = try AgentStore.fetch(db, id: agentID), !agent.isRemoved else { throw VaultError.unauthenticated }
            try AgentStore.recordRequest(db, agentID: agentID, now: now)
            var access = agent.access
            if let once = allowOnce, once.agentID == agentID {
                if !access.allowedCategoryKeys.isEmpty { access.allowedCategoryKeys.formUnion(once.categoryKeys) }
                access.operations.insert(once.operation)
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
                return reason == .categoryNotAllowed && agent.asksForAccess ? .offer(out, categories, .suggest) : .done(out)
            }

            // §5.4 decision. Corrections are always suggestions (FR-S-06).
            let ops = access.operations
            if ops.contains(.write), !access.askBeforeSaving, input.targetMemoryID == nil {
                let m = try MemoryStore.insert(db, MemoryDraft(
                    title: input.title, body: input.body, kind: input.kind ?? .fact, categoryKeys: categories,
                    sensitivity: sensitivity, expiresAt: input.expiresAt, confidence: input.confidence ?? 0.5,
                    source: .agentWrite, sourceAgentID: agentID), actor: .agent(agentID), now: now)
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
            return agent.asksForAccess ? .offer(out, [], .suggest) : .done(out)
        }

        var outcome: SuggestOutcome
        switch step {
        case let .done(o): outcome = o
        case let .offer(o, categories, operation):
            outcome = o
            outcome.accessOffer = disclosures?.offer(agentID: agentID, requestID: nil, categories: categories,
                                                     operation: operation, now: now)
        }
        activity.record(ActivityEvent(
            time: now, actor: .agent(agentID), via: .mcp, event: "suggest_memory", outcome: outcome.status.rawValue,
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

    static func insertSuggestion(_ db: Database, origin: SuggestionOrigin, agentID: UUID? = nil, deviceID: UUID? = nil,
                                 importRunID: UUID? = nil, captureID: UUID? = nil, input: SuggestInput, categories: [String],
                                 sensitivity: Sensitivity?, classification: String? = nil, now: Date) throws -> UUID {
        let id = UUID()
        try db.execute(sql: """
            INSERT INTO suggestion (id, origin, agent_id, device_id, import_run_id, capture_id, target_memory_id, action,
              title, body, kind, category_keys, sensitivity, expires_at, confidence, evidence, purpose, caller_metadata,
              classification, status, created_at, expires_after)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
            """, arguments: [id.db, origin.rawValue, agentID?.db, deviceID?.db, importRunID?.db, captureID?.db,
                             input.targetMemoryID?.db, (input.targetMemoryID == nil ? SuggestionAction.create : .update).rawValue,
                             input.title, input.body, input.kind?.rawValue, JSON.encode(categories), sensitivity?.rawValue,
                             input.expiresAt, input.confidence, input.evidence, input.purpose, input.metadataJSON,
                             classification, now, now + lifetime])
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

    /// Creates (or, for a correction with `.replace`, updates) the memory, in one transaction with
    /// the suggestion's status (FR-I-02). Runs validation and the secret scanner again.
    @discardableResult
    public func apply(suggestionID: UUID, edits: SuggestionEdit = SuggestionEdit(), mode: ApplyMode = .keepBoth,
                      now: Date) async throws -> ApplyResult {
        let result = try await store.writer.write { db -> ApplyResult in
            guard let s = try Self.fetch(db, id: suggestionID) else { throw VaultError.notFound }
            guard s.status == .pending else { throw VaultError.invalidState }
            let title = edits.title ?? s.title, body = edits.body ?? s.body
            var categories = edits.categoryKeys ?? s.categoryKeys
            if categories.isEmpty { categories = ["personal_preferences"] }
            categories = try MemoryStore.validateCategories(db, categories)
            let expiresAt = edits.expiresAt ?? s.expiresAt
            let origin = try Self.originActor(db, s)
            let memoryID: UUID
            if s.action == .update, mode == .replace, let target = s.targetMemoryID,
               let existing = try MemoryStore.fetch(db, id: target), existing.status != .deleted {
                let m = try MemoryStore.update(db, id: target, MemoryEdit(
                    title: title, body: body, kind: edits.kind ?? s.kind, categoryKeys: categories,
                    sensitivity: edits.sensitivity ?? s.sensitivity, expiresAt: .some(expiresAt)), actor: .user, now: now)
                memoryID = m.id
            } else {
                let m = try MemoryStore.insert(db, MemoryDraft(
                    title: title, body: body, kind: edits.kind ?? s.kind ?? .fact, categoryKeys: categories,
                    sensitivity: edits.sensitivity ?? s.sensitivity, expiresAt: expiresAt, confidence: s.confidence,
                    source: origin.source, sourceAgentID: s.agentID, sourceDeviceID: s.deviceID), actor: origin.actor, now: now)
                memoryID = m.id
            }
            try MemoryStore.appendProvenance(db, memoryID: memoryID, event: .appliedFromSuggestion, actor: .user, at: now)
            try db.execute(sql: "UPDATE suggestion SET status = 'applied', decided_at = ?, result_memory_id = ? WHERE id = ?",
                           arguments: [now, memoryID.db, suggestionID.db])
            let similar = try MemoryStore.exactDuplicates(db, title: title, body: body, excluding: memoryID)
            return ApplyResult(memoryID: memoryID, similarMemoryIDs: similar)
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "suggestion_applied",
                                      outcome: "applied", ids: [suggestionID, result.memoryID]))
        return result
    }

    /// The memory source and provenance actor for a suggestion's origin.
    static func originActor(_ db: Database, _ s: Suggestion) throws -> (source: MemorySource, actor: Actor) {
        switch s.origin {
        case .agent: return (.agentSuggestion, s.agentID.map(Actor.agent) ?? .user)
        case .captureMac: return (.captureMac, .user)
        case .captureIPhone: return (.captureIPhone, s.deviceID.map(Actor.device) ?? .user)
        case .seedQuestion, .consolidation: return (.seedQuestion, .user)
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
    public func reject(suggestionID: UUID, now: Date) async throws {
        try await setStatus(suggestionID, from: .pending, to: .rejected, now: now)
        activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "suggestion_rejected",
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
