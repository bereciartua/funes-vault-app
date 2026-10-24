import Foundation
import FunesProtocol
import GRDB

/// One tidy-up run as recorded (spec/domain/domain-model.md, TidyUpRun). Counts only, never text.
public struct TidyUpRun: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    /// `<provider>/<model>`, or nil when only the code-only rules ran.
    public var engine: String?
    /// Memories marked inspected.
    public var inspected: Int
    /// Clusters and splits sent to the model.
    public var clusters: Int
    /// Proposals left in the Inbox.
    public var suggestions: Int
    /// Changes applied automatically.
    public var applied: Int
    /// Stopped before every changed memory was looked at: the rest roll over to the next run.
    public var partial: Bool
    /// `cap_reached`, a provider error code, or `interrupted`.
    public var error: String?

    static func from(row: Row) throws -> TidyUpRun {
        TidyUpRun(id: try row.requiredUUID("id"), startedAt: row["started_at"], finishedAt: row["finished_at"], engine: row["engine"],
                  inspected: row["inspected"], clusters: row["clusters"], suggestions: row["suggestions"], applied: row["applied"],
                  partial: row["partial"], error: row["error"])
    }
}

/// "About N memories to check. Roughly X requests the first week, then a few a day." (§9.6)
public struct TidyUpEstimate: Sendable, Hashable {
    public var memories: Int
    public var requests: Int
}

/// Settings ▸ AI Models ▸ Daily tidy-up: Daily at a time, default 03:00 (memory processing §9.1).
public struct TidyUpSchedule: Sendable, Hashable, Codable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int = 3, minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }

    /// The latest scheduled time at or before `now`.
    public func lastSlot(atOrBefore now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    /// The next scheduled time after `now`.
    public func nextSlot(after now: Date, calendar: Calendar = .current) -> Date {
        let last = lastSlot(atOrBefore: now, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: last) ?? last
    }

    /// A run is due when a scheduled time passed since `since` (the last run's start, or when the
    /// tidy-up was turned on): the day's run, or the catch-up at launch or wake after a missed one.
    public func isDue(now: Date, since: Date?, calendar: Calendar = .current) -> Bool {
        guard let since else { return true }
        return lastSlot(atOrBefore: now, calendar: calendar) > since
    }
}

/// The daily tidy-up (memory processing §9, ADR-0021): changed memories with their local
/// neighbours, in clusters of at most 6, through the chosen model; validated in code, then left in
/// the Inbox or, with the user's permission, applied with undo. Exact duplicates and expired
/// memories need no model. Never on Apple on-device: without another provider only the code-only
/// rules run.
public struct TidyUpService: Sendable {
    public struct Configuration: Sendable {
        /// The tidy-up's router: its chosen provider (`splitter`, never Apple on-device) runs the
        /// model rules. Nil, or without one: only the code-only rules.
        public var router: ModelRouter?
        public var autoApply: TidyUpAutoApply
        /// Clusters and splits a run sends at most; the rest roll over (§9.6).
        public var maxClusters: Int

        public init(router: ModelRouter?, autoApply: TidyUpAutoApply = TidyUpAutoApply(), maxClusters: Int = TidyUpService.maxClusters) {
            self.router = router
            self.autoApply = autoApply
            self.maxClusters = maxClusters
        }
    }

    public static let maxClusters = 40
    public static let neighbours = 8
    public static let clusterSize = 6
    /// Per call, not per run (§9.6). Spike E's slowest tidy-up call took 18.6 s.
    public static let callTimeout: Duration = .seconds(20)
    /// A body this long likely holds more than one claim: it goes to §5's extractor (§9.2).
    public static let longBody = 600

    public let store: VaultStore
    public let activity: any ActivityRecorder
    public let finder: RelatedMemoryFinder
    /// Cards the user has open: a stale proposal under the cursor isn't dropped.
    public let holds: SuggestionHolds

    public init(store: VaultStore, activity: any ActivityRecorder, finder: RelatedMemoryFinder? = nil,
                holds: SuggestionHolds = SuggestionHolds()) {
        self.store = store
        self.activity = activity
        self.finder = finder ?? RelatedMemoryFinder(store: store, indexer: nil)
        self.holds = holds
    }

    // MARK: - Runs

    /// The newest run, for "Last tidy-up: today 03:04 · 37 memories checked · 4 suggestions".
    public func lastRun() async throws -> TidyUpRun? {
        try await store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM tidy_up_run ORDER BY started_at DESC, rowid DESC LIMIT 1").map(TidyUpRun.from(row:))
        }
    }

    /// Before the first run: the memories to check, and roughly how many requests (§9.6). Each
    /// cluster holds a few changed memories; a run sends at most 40.
    public func estimate() async throws -> TidyUpEstimate {
        let n = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory WHERE status = 'active' AND (reconciled_version IS NULL OR version > reconciled_version)") ?? 0
        }
        return TidyUpEstimate(memories: n, requests: min(Self.maxClusters * 7, (n + 2) / 3))
    }

    /// Marks memories inspected at their current version, in the caller's transaction (§9.2).
    static func markInspected(_ db: Database, _ ids: [UUID]) throws {
        for id in ids {
            try db.execute(sql: "UPDATE memory SET reconciled_version = version WHERE id = ?", arguments: [id.db])
        }
    }

    /// What a run starts from.
    struct State {
        var active: [UUID: Memory]
        var trust: [UUID: MemoryTrust]
        /// Never inspected, or changed since.
        var changed: Set<UUID>
        /// In a pending tidy-up proposal or a pending Share panel (§9.2).
        var busy: Set<UUID>
        /// Times shared, for an exact duplicate's survivor.
        var uses: [UUID: Int]
        /// Saved from a piece the extractor marked "may contain more than one thing".
        var nonAtomic: Set<UUID>
        var dismissals: Set<TidyUpDismissals.Key>
        var agents: [Agent]

        static func load(_ db: Database) throws -> State {
            let rows = try Row.fetchAll(db, sql: "SELECT id, trust, version, reconciled_version FROM memory WHERE status = 'active'")
            var trust: [UUID: MemoryTrust] = [:], changed = Set<UUID>()
            for row in rows {
                guard let id = row.uuid("id") else { continue }
                trust[id] = MemoryTrust(rawValue: row["trust"]) ?? .untrusted
                let version: Int = row["version"], reconciled: Int? = row["reconciled_version"]
                if reconciled.map({ version > $0 }) ?? true { changed.insert(id) }
            }
            let active = Dictionary(uniqueKeysWithValues: try MemoryStore.fetch(db, ids: Array(trust.keys)).map { ($0.id, $0) })
            var busy = Set(try String.fetchAll(db, sql: """
                SELECT target_memory_id FROM suggestion WHERE origin = 'consolidation' AND status = 'pending' AND target_memory_id IS NOT NULL
                UNION SELECT t.memory_id FROM suggestion_target t JOIN suggestion s ON s.id = t.suggestion_id
                  WHERE s.origin = 'consolidation' AND s.status = 'pending'
                """).compactMap(UUID.init(uuidString:)))
            busy.formUnion(try sharePanels(db))
            var uses: [UUID: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT memory_id, COUNT(*) AS n FROM disclosure_item GROUP BY memory_id") {
                if let id = row.uuid("memory_id") { uses[id] = row["n"] }
            }
            let nonAtomic = Set(try String.fetchAll(db, sql: """
                SELECT result_memory_id FROM suggestion WHERE status = 'applied' AND result_memory_id IS NOT NULL
                  AND json_valid(classification) AND json_extract(classification, '$.piece.atomic') = 0
                """).compactMap(UUID.init(uuidString:)))
            return State(active: active, trust: trust, changed: changed, busy: busy, uses: uses, nonAtomic: nonAtomic,
                         dismissals: try TidyUpDismissals.all(db), agents: try AgentStore.all(db))
        }

        /// Memories a pending Share panel lists: they're left alone until it's answered (ADR-0021).
        static func sharePanels(_ db: Database) throws -> Set<UUID> {
            var out = Set<UUID>()
            for json in try String.fetchAll(db, sql: """
                SELECT candidate_snapshot FROM disclosure WHERE status IN ('needs_approval','approved') AND candidate_snapshot IS NOT NULL
                """) {
                for item in JSON.decode([SnapshotItem].self, json) ?? [] { out.insert(item.id) }
            }
            return out
        }
    }

    /// The run's running totals.
    struct Totals {
        var inspected = 0
        var clusters = 0
        var suggestions = 0
        var applied = 0
        var appliedSuggestions: [UUID] = []
    }

    /// One run: the code-only rules, then up to 40 clusters or splits through the model, newest
    /// changes first. At the daily cap or a provider failure it stops; what's left rolls over.
    @discardableResult
    public func run(_ configuration: Configuration, now: Date = Date()) async throws -> TidyUpRun {
        let router = configuration.router
        let provider = router?.splitter
        let engine = provider.map(ModelRouter.engine)
        var run = TidyUpRun(id: UUID(), startedAt: now, engine: engine, inspected: 0, clusters: 0, suggestions: 0, applied: 0,
                            partial: false)
        let state = try await store.writer.write { [holds, run] db -> State in
            // A run a quit interrupted is closed; its memories roll over.
            try db.execute(sql: "UPDATE tidy_up_run SET finished_at = ?, partial = 1, error = COALESCE(error, 'interrupted') WHERE finished_at IS NULL",
                           arguments: [now])
            try db.execute(sql: "INSERT INTO tidy_up_run (id, started_at, engine) VALUES (?, ?, ?)", arguments: [run.id.db, now, engine])
            try Self.dropStale(db, holds: holds)
            return try State.load(db)
        }
        var totals = Totals()
        var handled = try await codeOnly(state, configuration: configuration, runID: run.id, totals: &totals, now: now)

        if let router, let provider {
            do {
                try await modelRules(state, handled: &handled, router: router, provider: provider, configuration: configuration,
                                     runID: run.id, totals: &totals, partial: &run.partial, now: now)
            } catch let stop as Stop {
                run.partial = true
                run.error = stop.code
            }
        }

        run.finishedAt = now
        run.inspected = totals.inspected
        run.clusters = totals.clusters
        run.suggestions = totals.suggestions
        run.applied = totals.applied
        try await store.writer.write { [run] db in
            try db.execute(sql: """
                UPDATE tidy_up_run SET finished_at = ?, inspected = ?, clusters = ?, suggestions = ?, applied = ?, partial = ?, error = ?
                WHERE id = ?
                """, arguments: [run.finishedAt, run.inspected, run.clusters, run.suggestions, run.applied, run.partial, run.error,
                                 run.id.db])
        }
        for id in totals.appliedSuggestions {
            activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "auto_applied",
                                          outcome: "applied", ids: [id]))
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "tidy_up_run",
                                      outcome: run.partial ? "partial" : "done", ids: [run.id],
                                      counts: ["inspected": run.inspected, "clusters": run.clusters, "suggestions": run.suggestions,
                                               "applied": run.applied]))
        return run
    }

    /// Why a run stopped early.
    struct Stop: Error {
        var code: String

        static func from(_ error: ProviderError) -> Stop {
            switch error {
            case .capReached: Stop(code: "cap_reached")
            case .timeout: Stop(code: "timeout")
            case .rateLimited: Stop(code: "rate_limited")
            case .unauthorized: Stop(code: "unauthorized")
            case .unavailable: Stop(code: "unavailable")
            case .blocked: Stop(code: "blocked")
            default: Stop(code: "provider_failed")
            }
        }
    }

    /// Pending proposals whose memories changed are dropped, so the next run looks again (§9.4).
    static func dropStale(_ db: Database, holds: SuggestionHolds) throws {
        let pending = try Row.fetchAll(db, sql: """
            SELECT * FROM suggestion WHERE origin = 'consolidation' AND status = 'pending' AND group_id IS NULL
            """).map(Suggestion.from(row:))
        for s in pending where !holds.isHeld(s.id) {
            do {
                _ = try SuggestionService.checked(db, SuggestionService.refs(db, s))
            } catch VaultError.targetChanged {
                try db.execute(sql: "DELETE FROM suggestion WHERE group_id = ?", arguments: [s.id.db])
                try db.execute(sql: "DELETE FROM suggestion WHERE id = ?", arguments: [s.id.db])
                try db.execute(sql: "DELETE FROM suggestion_group WHERE id = ?", arguments: [s.id.db])
            }
        }
    }

    // MARK: - Code only (§9.2)

    /// Exact duplicates (the trusted, more used, older copy survives) and expired memories. Returns
    /// the memories they settled, which the model rules leave alone this run.
    func codeOnly(_ state: State, configuration: Configuration, runID: UUID, totals: inout Totals, now: Date) async throws -> Set<UUID> {
        var actions: [(TidyUpAction, [UUID])] = []
        var handled = Set<UUID>()
        let free = state.active.values.filter { !state.busy.contains($0.id) }
        var groups: [String: [Memory]] = [:]
        for m in free where !m.isExpired(at: now) {
            groups["\(MemoryStore.normalized(m.title))\n\(MemoryStore.normalized(m.body))", default: []].append(m)
        }
        for copies in groups.values where copies.count > 1 && copies.contains(where: { state.changed.contains($0.id) }) {
            let survivor = TidyUpRules.survivor(copies, trust: state.trust, uses: state.uses)
            for copy in copies.sorted(by: { $0.id.db < $1.id.db }) where copy.id != survivor.id {
                var a = TidyUpAction(type: .archive, target: copy.id, survivor: survivor.id, archiveReason: .duplicate)
                a.exact = true
                actions.append((a, [copy.id, survivor.id]))
                handled.formUnion([copy.id, survivor.id])
            }
        }
        for m in free where m.isExpired(at: now) {
            actions.append((TidyUpAction(type: .archive, target: m.id, archiveReason: .expired), [m.id]))
            handled.insert(m.id)
        }
        guard !actions.isEmpty else { return handled }
        let level = configuration.autoApply.effective(engine: TidyUpRecord.rulesEngine)
        totals = try await store.writer.write { [totals, actions] db -> Totals in
            var totals = totals
            let dismissals = try TidyUpDismissals.all(db)
            for (action, ids) in actions {
                let current = try MemoryStore.fetch(db, ids: ids)
                guard current.count == ids.count, current.allSatisfy({ m in m.status == .active && m.version == state.active[m.id]?.version }),
                      !dismissals.contains(TidyUpDismissals.key(current)) else { continue }
                let target = current[0]
                let record = TidyUpRecord(engine: TidyUpRecord.rulesEngine, runID: runID, archiveReason: action.archiveReason,
                                          exact: action.exact ? true : nil)
                let id = try SuggestionService.insertSuggestion(
                    db, origin: .consolidation, action: .archive,
                    input: SuggestInput(title: target.title, body: target.body, kind: target.kind, categories: target.categoryKeys,
                                        sensitivity: target.sensitivity, targetMemoryID: target.id),
                    categories: target.categoryKeys, sensitivity: target.sensitivity, classification: JSON.encode(record),
                    targets: action.survivor.map { [($0, .survivor)] } ?? [], process: false, now: now)
                // An expiry is the memory's own date: applied only for one the user vouched for.
                let untrusted = action.archiveReason == .expired && state.trust[target.id] != .trusted
                let auto = action.archiveReason == .expired
                    ? level == .exceptConflicts && !untrusted
                    : TidyUpAutoApply.applies(action, level: level, untrusted: untrusted)
                if auto {
                    try Self.autoApply(db, suggestionID: id, engine: TidyUpRecord.rulesEngine, runID: runID, trustResult: false, now: now)
                    totals.applied += 1
                    totals.appliedSuggestions.append(id)
                } else {
                    totals.suggestions += 1
                }
            }
            return totals
        }
        return handled
    }

    // MARK: - The model rules (§9.2–§9.5)

    func modelRules(_ state: State, handled: inout Set<UUID>, router: ModelRouter, provider: any GenerationProvider,
                    configuration: Configuration, runID: UUID, totals: inout Totals, partial: inout Bool, now: Date) async throws {
        let local = provider.locality.isLocal
        func allowed(_ m: Memory) -> Bool { local || router.cloudLimit.allows(m.sensitivity) }
        let free = state.active.values.filter { !state.busy.contains($0.id) && !handled.contains($0.id) && !$0.isExpired(at: now) }
        let candidates = free.filter { state.changed.contains($0.id) }
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.db < $1.id.db }

        // Above the cloud limit with a cloud provider: marked inspected, never sent (§9.2).
        let above = candidates.filter { !allowed($0) }.map(\.id)
        if !above.isEmpty {
            try await store.writer.write { db in try Self.markInspected(db, above) }
            totals.inspected += above.count
        }
        var eligible = candidates.filter(allowed)
        var budget = configuration.maxClusters

        // Non-atomic memories go through §5's extractor as split proposals (§9.2).
        for m in eligible where m.body.count > Self.longBody || state.nonAtomic.contains(m.id) {
            guard budget > 0 else { partial = true; return }
            budget -= 1
            totals.clusters += 1
            if try await split(m, state: state, router: router, configuration: configuration, runID: runID, reason: nil,
                               totals: &totals, now: now) {
                handled.insert(m.id)
            }
        }
        eligible.removeAll { handled.contains($0.id) }

        // Neighbours by the shared finder, within the cloud limit (§9.2).
        let pool = Set(free.filter { allowed($0) && !handled.contains($0.id) }.map(\.id))
        let considered = Array(eligible.prefix(configuration.maxClusters * Self.clusterSize))
        if considered.count < eligible.count { partial = true }
        let related = try await finder.related(considered.map {
            RelatedMemoryFinder.Query(title: $0.title, body: $0.body, kind: $0.kind, categoryKeys: $0.categoryKeys)
        }, pool: pool, limit: Self.neighbours + 1)
        var neighbours: [UUID: [UUID]] = [:]
        for (m, ids) in zip(considered, related) { neighbours[m.id] = Array(ids.filter { $0 != m.id }.prefix(Self.neighbours)) }

        // Clusters: connected changed memories and their neighbours, at most 6; a memory an earlier
        // cluster holds is read-only context in the later ones (§9.2).
        var claimed = Set<UUID>()
        var clusters: [[(UUID, Bool)]] = []
        var lonely: [UUID] = []
        let changedEligible = Set(considered.map(\.id))
        for m in considered where !claimed.contains(m.id) {
            guard let first = neighbours[m.id], !first.isEmpty else { lonely.append(m.id); continue }
            var members = [m.id]
            var queue = first
            while !queue.isEmpty, members.count < Self.clusterSize {
                let n = queue.removeFirst()
                guard !members.contains(n) else { continue }
                members.append(n)
                if changedEligible.contains(n) { queue += neighbours[n] ?? [] }
            }
            clusters.append(members.map { ($0, !claimed.contains($0)) })
            claimed.formUnion(members.filter { !claimed.contains($0) })
        }
        // No neighbours: nothing to compare with, so inspected (§9.2).
        if !lonely.isEmpty {
            try await store.writer.write { [lonely] db in try Self.markInspected(db, lonely) }
            totals.inspected += lonely.count
        }

        for members in clusters {
            guard budget > 0 else { partial = true; return }
            budget -= 1
            totals.clusters += 1
            let cluster = TidyUpCluster(members: members.enumerated().compactMap { i, member in
                state.active[member.0].map { TidyUpCluster.Member(alias: "m\(i + 1)", memory: $0, trust: state.trust[$0.id] ?? .untrusted,
                                                                  editable: member.1) }
            })
            let output: TidyUpPrompt.Output
            do {
                output = try await router.call(TidyUpPrompt.request(cluster), items: TidyUpPrompt.items(cluster), with: provider,
                                               requester: .user, timeout: Self.callTimeout, now: now)
            } catch ProviderError.blocked {
                // Something in it can't leave the Mac: inspected, never sent.
                let ids = cluster.members.filter(\.editable).map(\.memory.id)
                try await store.writer.write { db in try Self.markInspected(db, ids) }
                totals.inspected += ids.count
                continue
            } catch let error as ProviderError {
                // At the cap the tidy-up waits for the next day; a provider that fails stops the run.
                throw Stop.from(error)
            }
            let outcome = TidyUpValidator.validate(output, cluster: cluster)
            let engine = ModelRouter.engine(provider)
            let (stored, splits) = try await store.writer.write { [totals] db -> (Totals, [(Memory, String?)]) in
                var totals = totals
                var splits: [(Memory, String?)] = []
                try Self.store(db, outcome.actions, cluster: cluster, engine: engine, state: state, configuration: configuration,
                               runID: runID, totals: &totals, splits: &splits, now: now)
                return (totals, splits)
            }
            totals = stored
            // The model's splits go through §5's extractor (§9.3).
            for (m, reason) in splits {
                _ = try await split(m, state: state, router: router, configuration: configuration, runID: runID, reason: reason,
                                    totals: &totals, now: now)
            }
        }
    }

    /// One cluster's validated actions, in one transaction: every memory must still be as the
    /// model saw it, or nothing is stored and the cluster is looked at again next time (false).
    @discardableResult
    static func store(_ db: Database, _ actions: [TidyUpAction], cluster: TidyUpCluster, engine: String, state: State,
                      configuration: Configuration, runID: UUID, totals: inout Totals, splits: inout [(Memory, String?)],
                      now: Date) throws -> Bool {
        let ids = cluster.members.map(\.memory.id)
        let current = Dictionary(uniqueKeysWithValues: try MemoryStore.fetch(db, ids: ids).map { ($0.id, $0) })
        guard cluster.members.allSatisfy({ current[$0.memory.id]?.version == $0.memory.version && current[$0.memory.id]?.status == .active })
        else { return false }
        let busy = try State.sharePanels(db)
        let dismissals = try TidyUpDismissals.all(db)
        let level = configuration.autoApply.effective(engine: engine)
        let floor = cluster.highestSensitivity
        func memory(_ id: UUID?) -> Memory? { id.flatMap { current[$0] } }
        func titled(_ text: String?) -> String? {
            // The model names memories by alias; the card shows their titles.
            guard var text else { return nil }
            for m in cluster.members.reversed() { text = text.replacingOccurrences(of: "\\b\(m.alias)\\b", with: "“\(m.memory.title)”",
                                                                                   options: .regularExpression) }
            return CaptureProposal.trim(text, to: 400)
        }

        for action in actions {
            guard !action.named.contains(where: busy.contains) else { continue }
            var keyed = action.named.compactMap(memory)
            if action.type == .update { keyed = cluster.members.compactMap { memory($0.memory.id) } }
            guard !dismissals.contains(TidyUpDismissals.key(keyed)) else { continue }
            var record = TidyUpRecord(engine: engine, runID: runID, reason: titled(action.reason), archiveReason: action.archiveReason,
                                      alsoArchive: action.alsoArchive, confidence: action.confidence, exact: action.exact ? true : nil)
            let input: SuggestInput
            var targets: [(UUID, SuggestionTarget.Role)] = []
            var suggestionAction = SuggestionAction(rawValue: action.type.rawValue) ?? .unknown
            switch action.type {
            case .split:
                if let m = memory(action.target) { splits.append((m, titled(action.reason))) }
                continue
            case .update:
                guard let target = memory(action.target) else { continue }
                record.context = ids
                input = SuggestInput(title: action.title ?? target.title, body: action.body ?? target.body, kind: target.kind,
                                     categories: target.categoryKeys, sensitivity: max(floor, target.sensitivity),
                                     targetMemoryID: target.id)
                if let copy = action.alsoArchive { targets = [(copy, .source)] }
            case .merge:
                guard let first = memory(action.sources.first) else { continue }
                record.kept = action.kept
                input = SuggestInput(title: action.title ?? first.title, body: action.body ?? first.body, kind: action.kind ?? first.kind,
                                     categories: first.categoryKeys, sensitivity: floor)
                targets = action.sources.map { ($0, .source) }
            case .archive:
                guard let target = memory(action.target) else { continue }
                input = SuggestInput(title: target.title, body: target.body, kind: target.kind, categories: target.categoryKeys,
                                     sensitivity: target.sensitivity, targetMemoryID: target.id)
                targets = action.survivor.map { [($0, .survivor)] } ?? []
            case .conflict:
                let pair = action.ids.compactMap(memory)
                guard pair.count == 2, let question = action.question else { continue }
                suggestionAction = .conflict
                input = SuggestInput(title: CaptureProposal.trim(question, to: InputLimits.proposedTitle), body: question,
                                     kind: pair[0].kind, categories: pair[0].categoryKeys,
                                     sensitivity: max(pair[0].sensitivity, pair[1].sensitivity))
                targets = pair.map { ($0.id, .target) }
            }
            let id = try SuggestionService.insertSuggestion(
                db, origin: .consolidation, action: suggestionAction, input: input, categories: input.categories,
                sensitivity: input.sensitivity, classification: JSON.encode(record), targets: targets, process: false, now: now)
            let untrusted = TidyUpAutoApply.leansOnUntrusted(action, cluster: cluster)
            if TidyUpAutoApply.applies(action, level: level, untrusted: untrusted),
               try noNewAccess(action, input: input, cluster: cluster, agents: state.agents, now: now) {
                try autoApply(db, suggestionID: id, engine: engine, runID: runID, trustResult: true, now: now)
                totals.applied += 1
                totals.appliedSuggestions.append(id)
            } else {
                totals.suggestions += 1
            }
        }
        let editable = cluster.members.filter(\.editable).map(\.memory.id)
        try markInspected(db, editable)
        totals.inspected += editable.count
        return true
    }

    /// The policy-engine check before auto-apply (§9.5): no agent could read the result without
    /// having been able to read every memory whose text went into it. An archive adds no text.
    static func noNewAccess(_ action: TidyUpAction, input: SuggestInput, cluster: TidyUpCluster, agents: [Agent], now: Date) throws -> Bool {
        guard action.type == .update || action.type == .merge else { return true }
        let sensitivity = input.sensitivity ?? cluster.highestSensitivity
        return agents.allSatisfy { agent in
            PolicyEngine.scopeCheck(sensitivity: sensitivity, categoryKeys: input.categories, access: agent.access) != nil
                || cluster.members.allSatisfy { PolicyEngine.eligibility($0.memory, access: agent.access, now: now) == nil }
        }
    }

    /// Applies a stored proposal automatically, with its undo entry, in the caller's transaction
    /// (§9.5): the memories are re-checked at their versions, and every memory it touched is
    /// marked inspected at its new version, so the next run doesn't re-inspect it. A merge's or
    /// split's new memories are trusted only when everything they came from was (`trustResult`).
    static func autoApply(_ db: Database, suggestionID: UUID, engine: String, runID: UUID, trustResult: Bool, now: Date) throws {
        guard let s = try SuggestionService.fetch(db, id: suggestionID) else { return }
        let named = try SuggestionService.refs(db, s).map(\.memoryID)
        var result: ApplyResult?
        try UndoLog.record(db, action: s.action.rawValue, memoryIDs: named, suggestionID: s.id, runID: runID, now: now) {
            let r = try SuggestionService.applyAction(db, s, edits: SuggestionEdit(), mode: nil, now: now, actor: .system)
            result = r
            return r.memoryIDs.filter { !named.contains($0) }
        }
        guard let result else { return }
        try db.execute(sql: "UPDATE suggestion SET status = 'applied', decided_at = ?, result_memory_id = ? WHERE id = ?",
                       arguments: [now, result.memoryID.db, s.id.db])
        let created = result.memoryIDs.filter { !named.contains($0) }
        if trustResult, !created.isEmpty {
            for id in created { try db.execute(sql: "UPDATE memory SET trust = 'trusted' WHERE id = ?", arguments: [id.db]) }
        }
        for id in result.memoryIDs {
            try MemoryStore.appendProvenance(db, memoryID: id, event: .autoApplied, actor: .system, at: now, engine: engine)
        }
        try markInspected(db, result.memoryIDs)
    }

    // MARK: - Splits (§9.2)

    /// A memory through §5's extractor, as a split proposal (or applied, at Everything except
    /// conflicts, when every piece is new, atomic and supported, the memory is trusted and no
    /// agent gains access). Returns true when it was proposed or applied; false when the extractor
    /// kept it whole, so it's clustered like any other.
    func split(_ m: Memory, state: State, router: ModelRouter, configuration: Configuration, runID: UUID, reason: String?,
               totals: inout Totals, now: Date) async throws -> Bool {
        let variant: ExtractionVariant = switch m.source {
        case .manual, .captureMac, .captureIPhone, .seedQuestion, .tidyUp: .firstPerson
        case .agentSuggestion, .agentWrite, .importChatGPT, .importClaude, .importMarkdown, .importFunes: .aboutUser
        }
        let result: SplitResult
        do {
            result = try await MemorySplitter(store: store, router: router, finder: finder).split(
                SplitRequest(text: m.body, variant: variant, original: m.sensitivity, excluding: [m.id], requester: .user), now: now)
        } catch SplitError.capReached {
            throw Stop(code: "cap_reached")
        } catch let SplitError.failed(error) {
            throw Stop.from(error)
        } catch is SplitError {
            try await store.writer.write { db in try Self.markInspected(db, [m.id]) }
            totals.inspected += 1
            return true
        }
        let isSplit = result.pieces.count > 1
        let level = configuration.autoApply.effective(engine: result.engine)
        let trusted = state.trust[m.id] == .trusted
        let stored = try await store.writer.write { [totals] db -> (Totals, Bool) in
            var totals = totals
            guard let current = try MemoryStore.fetch(db, id: m.id), current.status == .active, current.version == m.version else {
                return (totals, true)
            }
            guard isSplit else { return (totals, false) }
            if try TidyUpDismissals.all(db).contains(TidyUpDismissals.key([current])) {
                try Self.markInspected(db, [m.id])
                totals.inspected += 1
                return (totals, true)
            }
            let id = try Self.storeSplit(db, current, result, runID: runID, reason: reason, now: now)
            let agents = try AgentStore.all(db)
            let auto = level == .exceptConflicts && trusted
                && result.pieces.allSatisfy { $0.decision.action == .create && $0.piece.atomic && $0.piece.supported }
                && result.pieces.allSatisfy { piece in
                    agents.allSatisfy { agent in
                        PolicyEngine.scopeCheck(sensitivity: max(piece.piece.sensitivity, current.sensitivity),
                                                categoryKeys: piece.piece.categoryKeys, access: agent.access) != nil
                            || PolicyEngine.eligibility(current, access: agent.access, now: now) == nil
                    }
                }
            if auto {
                try Self.autoApply(db, suggestionID: id, engine: result.engine, runID: runID, trustResult: true, now: now)
                totals.applied += 1
                totals.appliedSuggestions.append(id)
            } else {
                totals.suggestions += 1
            }
            try Self.markInspected(db, [m.id])
            totals.inspected += 1
            return (totals, true)
        }
        totals = stored.0
        return stored.1
    }

    /// "Split this memory" from the tidy-up: a `split` suggestion for the memory, its pieces in
    /// its group, never below its sensitivity (§9.4).
    static func storeSplit(_ db: Database, _ m: Memory, _ result: SplitResult, runID: UUID, reason: String?, now: Date) throws -> UUID {
        let record = TidyUpRecord(engine: result.engine, runID: runID, reason: reason)
        let id = try SuggestionService.insertSuggestion(
            db, origin: .consolidation, action: .split,
            input: SuggestInput(title: m.title, body: m.body, kind: m.kind, categories: m.categoryKeys, sensitivity: m.sensitivity,
                                targetMemoryID: m.id),
            categories: m.categoryKeys, sensitivity: m.sensitivity, classification: JSON.encode(record), process: false, now: now)
        // The memory holds the text; the group keeps none of its own.
        try NewMemoryProcessor.insertGroup(db, id: id, origin: .consolidation, agentID: nil, sourceText: nil, engine: result.engine, now: now)
        let s = try SuggestionService.fetch(db, id: id)!
        for piece in result.pieces {
            var p = piece
            p.piece.sensitivity = max(p.piece.sensitivity, m.sensitivity)
            try NewMemoryProcessor.insertPiece(db, p, of: s, groupID: id, agent: nil, engine: result.engine, now: now)
        }
        return id
    }
}
