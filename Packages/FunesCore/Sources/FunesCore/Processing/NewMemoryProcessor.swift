import Foundation
import FunesProtocol
import GRDB

/// The `new_memory` job (memory processing §5.2, step 4): every new input is split into atomic
/// pieces, each classified and linked to related memories, when splitting is on and a local
/// server or cloud model is chosen. Otherwise, or when splitting fails, v0.2's behaviour: captures
/// are classified (the capture's "at least" level as the floor) and everything else keeps the
/// fields it arrived with.
public struct NewMemoryProcessor: Sendable {
    /// What a job may use, read fresh for each job (the user's settings).
    public struct Configuration: Sendable {
        /// The New memories router, or nil while classification and splitting are both off.
        public var router: ModelRouter?
        /// Settings ▸ AI Models ▸ New memories ▸ Split into separate memories.
        public var split: Bool
        public var autoApply: NewMemoryAutoApply

        public init(router: ModelRouter?, split: Bool = false, autoApply: NewMemoryAutoApply = NewMemoryAutoApply()) {
            self.router = router
            self.split = split
            self.autoApply = autoApply
        }
    }

    public let store: VaultStore
    public let captures: CaptureService
    public let finder: RelatedMemoryFinder
    public let holds: SuggestionHolds
    public let configuration: @Sendable () async -> Configuration
    /// Hands the router back after a job, for the usage counters.
    public let finished: @Sendable (ModelRouter) async -> Void
    public let now: @Sendable () -> Date

    public init(store: VaultStore, captures: CaptureService, finder: RelatedMemoryFinder? = nil,
                holds: SuggestionHolds = SuggestionHolds(), now: @escaping @Sendable () -> Date = { Date() },
                configuration: @escaping @Sendable () async -> Configuration,
                finished: @escaping @Sendable (ModelRouter) async -> Void = { _ in }) {
        self.store = store
        self.captures = captures
        self.finder = finder ?? RelatedMemoryFinder(store: store, indexer: nil)
        self.holds = holds
        self.now = now
        self.configuration = configuration
        self.finished = finished
    }

    /// Classification only (v0.2): `router` nil while classification is off.
    public init(store: VaultStore, captures: CaptureService, router: @escaping @Sendable () async -> ModelRouter?,
                finished: @escaping @Sendable (ModelRouter) async -> Void = { _ in }) {
        self.init(store: store, captures: captures, configuration: { Configuration(router: await router()) }, finished: finished)
    }

    var activity: any ActivityRecorder { captures.activity }

    public func process(_ job: ProcessingJob) async throws -> ProcessingQueue.Outcome {
        guard job.kind == .newMemory else { return .done(engine: nil) }
        let (suggestion, memory) = try await store.writer.read { db in
            (try SuggestionService.fetch(db, id: job.subject), try MemoryStore.fetch(db, id: job.subject))
        }
        let config = await configuration()
        guard let router = config.router else { return .done(engine: nil) }
        let outcome: ProcessingQueue.Outcome
        if let suggestion {
            outcome = try await process(suggestion, router: router, config: config)
        } else if let memory, memory.source == .agentWrite {
            outcome = try await processDirectWrite(memory, router: router, config: config)
        } else {
            outcome = .done(engine: nil)
        }
        await finished(router)
        return outcome
    }

    // MARK: - Suggestions: captures, seed answers, agent suggestions, imports

    func process(_ s: Suggestion, router: ModelRouter, config: Configuration) async throws -> ProcessingQueue.Outcome {
        guard s.status == .pending, s.groupID == nil, s.targetMemoryID == nil, s.action == .create else { return .done(engine: nil) }
        let isCapture = s.origin == .captureMac || s.origin == .captureIPhone
        let hint = JSON.decode(ClassificationRecord.self, s.classification)?.hint
        let now = self.now()
        if config.split, router.splitter != nil, let input = splitRequest(for: s, hint: hint) {
            do {
                let result = try await MemorySplitter(store: store, router: router, finder: finder).split(input, now: now)
                // Only seed answers are known to be typed; a capture may be shared text (§5.7).
                if try await store(result, for: s, typed: s.origin == .seedQuestion, autoApply: config.autoApply, now: now) {
                    return .done(engine: result.engine)
                }
            } catch SplitError.capReached where !isCapture {
                // Agent input and imports wait for the next day; the user's captures fall back to
                // classification on this Mac (ADR-0022).
                return .later(until: router.cap?.nextDay(after: now) ?? now + 3_600, code: "cap_reached")
            } catch is SplitError {
                // The original stays as it is (§5.4).
            }
        }
        guard isCapture else { return .done(engine: nil) }
        return try await classify(s, hint: hint, router: router)
    }

    /// Today's classification of a capture.
    func classify(_ s: Suggestion, hint: Sensitivity?, router: ModelRouter) async throws -> ProcessingQueue.Outcome {
        let record = await router.classify(s.body, categories: try store.categories(), hint: hint, now: now())
        if record.engine != RulesClassifier.engine || record.keptOnDevice {
            do {
                // "At least <level>" holds whatever the model proposed (PR #3 review 4304236141).
                try await captures.reclassify(suggestionID: s.id, record: record, floor: hint)
            } catch VaultError.invalidState {
                // Applied or rejected while the model worked: nothing to update.
            }
        }
        return .done(engine: record.engine)
    }

    /// The variant, note tag and floors per input (memory processing §5.3–§5.4). Nil: not split.
    /// An agent's or import item's title goes in the note tag; a capture's and a seed answer's
    /// title isn't the user's, so they get the date only.
    func splitRequest(for s: Suggestion, hint: Sensitivity?) -> SplitRequest? {
        switch s.origin {
        case .captureMac, .captureIPhone:
            return SplitRequest(text: s.body, note: ExtractionNote(title: nil, written: s.createdAt), variant: .firstPerson,
                                sensitivityHint: hint)
        case .seedQuestion:
            let question = SeedQuestion.all.first { $0.title == s.title }
            return SplitRequest(text: s.body, note: ExtractionNote(title: nil, written: s.createdAt), variant: .firstPerson,
                                hint: question.map { ExtractionHint(question: $0.prompt, kind: $0.kind, categoryKey: $0.categoryKey) },
                                declared: s.sensitivity)
        case .agent:
            return SplitRequest(text: s.body, note: ExtractionNote(title: s.title, written: s.createdAt), variant: .aboutUser,
                                declared: s.sensitivity, requester: .agent)
        case .import:
            return SplitRequest(text: s.body, note: ExtractionNote(title: s.title, written: s.createdAt), variant: .aboutUser,
                                declared: s.sensitivity)
        case .consolidation:
            return nil
        }
    }

    /// Stores a split (memory processing §5.2, step 5), in one transaction: the suggestion is
    /// replaced by its group only while it's still pending and nobody has it open; otherwise the
    /// pieces are attached as an offer. One new piece updates the suggestion's fields instead.
    /// Returns false when there was nothing to store (no valid piece).
    func store(_ result: SplitResult, for s: Suggestion, typed: Bool, autoApply: NewMemoryAutoApply, now: Date) async throws -> Bool {
        guard !result.pieces.isEmpty else { return false }
        let level = autoApply.effective(engine: result.engine)
        enum Stored { case decided, single, group(offer: Bool, pieces: [UUID], applied: [UUID]) }
        let stored = try await store.writer.write { db -> Stored in
            guard let current = try SuggestionService.fetch(db, id: s.id), current.status == .pending, current.groupID == nil else {
                return .decided  // applied, rejected or expired while the model worked
            }
            let agent = try current.agentID.flatMap { try AgentStore.fetch(db, id: $0) }
            if result.pieces.count == 1, result.pieces[0].decision.action == .create, Self.coversInput(result.pieces[0].piece, current.body) {
                let piece = result.pieces[0].piece
                let outside = agent.map { PolicyEngine.scopeCheck(sensitivity: piece.sensitivity, categoryKeys: piece.categoryKeys,
                                                                  access: $0.access) != nil } ?? false
                if !outside {
                    try Self.single(db, current, result.pieces[0], engine: result.engine)
                    return .single
                }
            }
            let offer = holds.isHeld(current.id)
            try Self.insertGroup(db, id: current.id, origin: current.origin, agentID: current.agentID, sourceText: current.body,
                                 engine: result.engine, now: now)
            var ids: [UUID] = []
            for piece in result.pieces {
                ids.append(try Self.insertPiece(db, piece, of: current, groupID: current.id, agent: agent, engine: result.engine, now: now))
            }
            try Self.markTruncated(db, current, result)
            guard !offer else { return .group(offer: true, pieces: ids, applied: []) }
            try db.execute(sql: "UPDATE suggestion SET status = 'split', decided_at = ? WHERE id = ?", arguments: [now, current.id.db])
            // Agents follow their own access, never this setting (§5.7).
            guard level > .off, current.origin != .agent else { return .group(offer: false, pieces: ids, applied: []) }
            let baseline = JSON.decode(ClassificationRecord.self, current.classification)?.hint ?? .public
            var applied: [UUID] = []
            for (id, piece) in zip(ids, result.pieces) {
                let floor = max(baseline, try MemoryStore.defaultSensitivity(db, categoryKeys: piece.piece.categoryKeys))
                guard NewMemoryAutoApply.applies(piece, level: level, typed: typed, baseline: floor),
                      let s = try SuggestionService.fetch(db, id: id) else { continue }
                try Self.autoApply(db, s, engine: result.engine, now: now)
                applied.append(id)
            }
            return .group(offer: false, pieces: ids, applied: applied)
        }
        switch stored {
        case .decided, .single:
            break
        case let .group(offer, pieces, applied):
            activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "split",
                                          outcome: offer ? "offered" : "split", ids: [s.id],
                                          counts: ["pieces": pieces.count, "truncated": result.truncated]))
            for id in applied {
                activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "auto_applied",
                                              outcome: "applied", ids: [id]))
            }
        }
        return true
    }

    /// One new piece: a capture or seed answer takes its title, kind, categories and sensitivity
    /// (the text stays the user's); agent input and imports keep their fields, with the
    /// sensitivity raised when the piece's is higher.
    static func single(_ db: Database, _ s: Suggestion, _ split: SplitPiece, engine: String) throws {
        let piece = split.piece
        switch s.origin {
        case .captureMac, .captureIPhone, .seedQuestion:
            let hint = JSON.decode(ClassificationRecord.self, s.classification)?.hint
            let sensitivity = max(piece.sensitivity, s.origin == .seedQuestion ? s.sensitivity ?? .public : .public)
            let record = ClassificationRecord(
                engine: engine, proposal: CaptureProposal(title: piece.title, kind: piece.kind, categoryKeys: piece.categoryKeys,
                                                          sensitivity: sensitivity, timeLimited: piece.timeLimited),
                keptOnDevice: false, hint: hint, piece: pieceRecord(split))
            try db.execute(sql: """
                UPDATE suggestion SET title = ?, kind = ?, category_keys = ?, sensitivity = ?, classification = ?, intent = ? WHERE id = ?
                """, arguments: [piece.title, piece.kind.rawValue, JSON.encode(piece.categoryKeys), sensitivity.rawValue,
                                 JSON.encode(record), piece.intent.rawValue, s.id.db])
        case .agent, .import, .consolidation:
            if piece.sensitivity > s.sensitivity ?? .public {
                try db.execute(sql: "UPDATE suggestion SET sensitivity = ? WHERE id = ?", arguments: [piece.sensitivity.rawValue, s.id.db])
            }
        }
    }

    /// One piece "with nothing changed" (§5.2): its quotes cover at least 80% of the input. A
    /// piece taken from part of it (an agent's note that also talks about itself) replaces it.
    static func coversInput(_ piece: ExtractedPiece, _ text: String) -> Bool {
        let quoted = piece.evidence.map { ExtractionValidator.normalize($0).count }.reduce(0, +)
        return Double(quoted) >= 0.8 * Double(ExtractionValidator.normalize(text).count)
    }

    static func pieceRecord(_ split: SplitPiece) -> PieceRecord {
        PieceRecord(atomic: split.piece.atomic, supported: split.piece.supported, confidence: split.piece.confidence,
                    action: split.decision.action, reason: split.decision.reason, related: split.related,
                    modelSensitivity: split.piece.modelSensitivity, timeLimited: split.piece.timeLimited,
                    claim: split.decision.action == .update ? split.piece.body : nil)
    }

    static func insertGroup(_ db: Database, id: UUID, origin: SuggestionOrigin, agentID: UUID?, sourceText: String?, engine: String,
                            now: Date) throws {
        try db.execute(sql: """
            INSERT INTO suggestion_group (id, origin, agent_id, source_text, engine, created_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET source_text = excluded.source_text, engine = excluded.engine
            """, arguments: [id.db, origin.rawValue, agentID?.db, sourceText, engine, now])
    }

    /// The original's record notes how many pieces beyond 40 were left out.
    static func markTruncated(_ db: Database, _ s: Suggestion, _ result: SplitResult) throws {
        guard result.truncated > 0 else { return }
        var record = JSON.decode(ClassificationRecord.self, s.classification)
            ?? ClassificationRecord(engine: result.engine, proposal: CaptureProposal(
                title: s.title, kind: s.kind ?? .fact, categoryKeys: s.categoryKeys, sensitivity: s.sensitivity ?? .low,
                timeLimited: false), keptOnDevice: false)
        record.truncated = result.truncated
        try db.execute(sql: "UPDATE suggestion SET classification = ? WHERE id = ?", arguments: [JSON.encode(record), s.id.db])
    }

    /// One piece as a suggestion of its group (memory processing §5.5): `create`; `update` (the
    /// target's title, kind and categories with the new text, never below the target's
    /// sensitivity); `duplicate`; or `archive` for a retraction. A target that changed since the
    /// decision call makes it `create`. A piece of an agent's input outside that agent's scope is
    /// flagged (access policy §5.3).
    @discardableResult
    static func insertPiece(_ db: Database, _ split: SplitPiece, of s: Suggestion, groupID: UUID, agent: Agent?, engine: String,
                            now: Date) throws -> UUID {
        let piece = split.piece
        var title = piece.title, body = piece.body, kind = piece.kind, categories = piece.categoryKeys
        var sensitivity = piece.sensitivity
        var action = SuggestionAction.create
        var target: UUID?
        var decision = split.decision
        if decision.action != .create, let id = decision.target, let m = try MemoryStore.fetch(db, id: id), m.status == .active,
           m.version == decision.targetVersion {
            target = id
            switch decision.action {
            case .update:
                action = .update
                title = m.title
                body = decision.updatedBody ?? piece.body
                kind = m.kind
                categories = m.categoryKeys
                sensitivity = max(sensitivity, m.sensitivity)
            case .duplicate: action = .duplicate
            case .retract: action = .archive
            case .create: break
            }
        } else {
            decision = .create
        }
        let outside = agent.map { PolicyEngine.scopeCheck(sensitivity: sensitivity, categoryKeys: categories, access: $0.access) != nil }
            ?? false
        var record = SplitPiece(piece: piece, decision: decision, related: split.related)
        record.piece.sensitivity = sensitivity
        let classification = ClassificationRecord(
            engine: engine, proposal: CaptureProposal(title: title, kind: kind, categoryKeys: categories, sensitivity: sensitivity,
                                                      timeLimited: piece.timeLimited),
            keptOnDevice: false, hint: JSON.decode(ClassificationRecord.self, s.classification)?.hint, piece: pieceRecord(record))
        return try SuggestionService.insertSuggestion(
            db, origin: s.origin, agentID: s.agentID, deviceID: s.deviceID, importRunID: s.importRunID, action: action,
            input: SuggestInput(title: title, body: body, kind: kind, categories: categories, sensitivity: sensitivity,
                                evidence: piece.evidence.joined(separator: "\n"), purpose: s.purpose, expiresAt: s.expiresAt,
                                confidence: piece.confidence, targetMemoryID: target),
            categories: categories, sensitivity: sensitivity, classification: JSON.encode(classification), groupID: groupID,
            process: false, expiresAfter: s.expiresAfter, intent: piece.intent, outsideScope: outside, now: now)
    }

    /// Applies a piece automatically (memory processing §5.7), with its undo entry, in the
    /// caller's transaction.
    static func autoApply(_ db: Database, _ s: Suggestion, engine: String, now: Date) throws {
        let targets = s.targetMemoryID.map { [$0] } ?? []
        var result: ApplyResult?
        try UndoLog.record(db, action: s.action.rawValue, memoryIDs: targets, suggestionID: s.id, now: now) {
            let r = try SuggestionService.applyAction(db, s, edits: SuggestionEdit(), mode: nil, now: now, actor: .system)
            result = r
            return r.memoryIDs.filter { !targets.contains($0) }
        }
        guard let result else { return }
        try db.execute(sql: "UPDATE suggestion SET status = 'applied', decided_at = ?, result_memory_id = ? WHERE id = ?",
                       arguments: [now, result.memoryID.db, s.id.db])
        for id in result.memoryIDs {
            try MemoryStore.appendProvenance(db, memoryID: id, event: .autoApplied, actor: .system, at: now, engine: engine)
        }
    }

    // MARK: - Agents' direct writes: saved, then split (§5.6)

    func processDirectWrite(_ m: Memory, router: ModelRouter, config: Configuration) async throws -> ProcessingQueue.Outcome {
        guard config.split, let splitter = router.splitter, m.status == .active, let agentID = m.sourceAgentID,
              try store.trust(memoryID: m.id) == .untrusted else { return .done(engine: nil) }
        let now = self.now()
        // Pieces that may be saved for the agent link only against memories it can read (§5.5).
        var pool: Set<UUID>?
        if config.autoApply.effective(engine: ModelRouter.engine(splitter)) == .exceptConflicts {
            pool = try await store.writer.read { db in
                guard let agent = try AgentStore.fetch(db, id: agentID) else { return [] }
                return Set(try MemoryStore.list(db, filter: MemoryFilter(), now: now)
                    .filter { PolicyEngine.eligibility($0, access: agent.access, now: now) == nil }.map(\.id))
            }
        }
        let result: SplitResult
        do {
            result = try await MemorySplitter(store: store, router: router, finder: finder).split(
                SplitRequest(text: m.body, note: ExtractionNote(title: m.title, written: m.createdAt), variant: .aboutUser,
                             declared: m.sensitivity, original: m.sensitivity, excluding: [m.id], linkPool: pool, requester: .agent),
                now: now)
        } catch SplitError.capReached {
            return .later(until: router.cap?.nextDay(after: now) ?? now + 3_600, code: "cap_reached")
        } catch is SplitError {
            return .done(engine: nil)
        }
        guard !result.pieces.isEmpty else { return .done(engine: result.engine) }
        let level = config.autoApply.effective(engine: result.engine)
        enum Stored { case unchanged, raised, suggestion(UUID), replaced([UUID]) }
        let stored = try await store.writer.write { db -> [Stored] in
            guard var current = try MemoryStore.fetch(db, id: m.id), current.status == .active, current.version == m.version,
                  let agent = try AgentStore.fetch(db, id: agentID) else { return [.unchanged] }
            var out: [Stored] = []
            // More sensitive than the agent declared: raised at once.
            let highest = result.pieces.map(\.piece.sensitivity).max() ?? current.sensitivity
            if highest > current.sensitivity {
                current = try MemoryStore.update(db, id: m.id, MemoryEdit(sensitivity: highest), actor: .system, now: now)
                out.append(.raised)
            }
            guard result.pieces.count > 1 || result.pieces[0].decision.action != .create else { return out }
            if level == .exceptConflicts, let ids = try Self.replace(db, current, result, agent: agent, engine: result.engine, now: now) {
                out.append(.replaced(ids))
                return out
            }
            out.append(.suggestion(try Self.splitSuggestion(db, current, result, agent: agent, now: now)))
            return out
        }
        for s in stored {
            switch s {
            case .unchanged: break
            case .raised:
                activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "sensitivity_raised",
                                              outcome: "saved", ids: [m.id]))
            case let .suggestion(id):
                activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "split",
                                              outcome: "offered", ids: [id, m.id], counts: ["pieces": result.pieces.count]))
            case let .replaced(ids):
                activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "split",
                                              outcome: "applied", ids: [m.id] + ids, counts: ["pieces": ids.count]))
            }
        }
        return .done(engine: result.engine)
    }

    /// "Split this memory": a `split` suggestion for the saved memory, its pieces in its group.
    static func splitSuggestion(_ db: Database, _ m: Memory, _ result: SplitResult, agent: Agent, now: Date) throws -> UUID {
        let id = try SuggestionService.insertSuggestion(
            db, origin: .agent, agentID: agent.id, action: .split,
            input: SuggestInput(title: m.title, body: m.body, kind: m.kind, categories: m.categoryKeys, sensitivity: m.sensitivity,
                                targetMemoryID: m.id),
            categories: m.categoryKeys, sensitivity: m.sensitivity, process: false, now: now)
        // The memory holds the text; the group keeps none of its own.
        try insertGroup(db, id: id, origin: .agent, agentID: agent.id, sourceText: nil, engine: result.engine, now: now)
        let s = try SuggestionService.fetch(db, id: id)!
        for piece in result.pieces {
            var p = piece
            // Splitting never lowers sensitivity (§5.4).
            p.piece.sensitivity = max(p.piece.sensitivity, m.sensitivity)
            try insertPiece(db, p, of: s, groupID: id, agent: agent, engine: result.engine, now: now)
        }
        return id
    }

    /// At Everything except conflicts: the pieces replace the original, create-only, when every
    /// piece is new and within the agent's write scope and its write limit (250 stored a rolling
    /// day). Nil otherwise, for a Split this memory suggestion.
    static func replace(_ db: Database, _ m: Memory, _ result: SplitResult, agent: Agent, engine: String, now: Date) throws -> [UUID]? {
        let access = agent.access
        guard access.operations.contains(.write), !access.askBeforeSaving,
              result.pieces.allSatisfy({ $0.decision.action == .create && $0.piece.supported && $0.piece.atomic }),
              result.pieces.allSatisfy({
                  PolicyEngine.scopeCheck(sensitivity: max($0.piece.sensitivity, m.sensitivity), categoryKeys: $0.piece.categoryKeys,
                                          access: access) == nil
              }) else { return nil }
        let stored = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory WHERE source_agent_id = ? AND created_at > ?",
                                      arguments: [agent.id.db, now - 86_400]) ?? 0
        guard stored + result.pieces.count <= 250 else { return nil }
        var ids: [UUID] = []
        try UndoLog.record(db, action: "split", memoryIDs: [m.id], now: now) {
            for piece in result.pieces {
                let new = try MemoryStore.insert(db, MemoryDraft(
                    title: piece.piece.title, body: piece.piece.body, kind: piece.piece.kind, categoryKeys: piece.piece.categoryKeys,
                    sensitivity: max(piece.piece.sensitivity, m.sensitivity), confidence: piece.piece.confidence ?? 0.5,
                    source: .agentWrite, sourceAgentID: agent.id), actor: .agent(agent.id), now: now)
                try MemoryStore.appendProvenance(db, memoryID: new.id, event: .splitFrom, actor: .system, at: now, relatedMemoryID: m.id,
                                                 engine: engine)
                try MemoryStore.appendProvenance(db, memoryID: m.id, event: .splitInto, actor: .system, at: now, relatedMemoryID: new.id,
                                                 engine: engine)
                ids.append(new.id)
            }
            try MemoryStore.setStatus(db, id: m.id, to: .archived, actor: .system, now: now)
            return ids
        }
        return ids
    }
}
