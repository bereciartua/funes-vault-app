import Foundation
import FunesProtocol
import GRDB

/// What one `learn` did, for the caller (the queue, the fixture harness): counts and ids only.
public struct FactsLearnReport: Sendable {
    public struct Call: Sendable {
        public enum Outcome: String, Sendable { case applied, failed, codeOnly = "code_only", changed }
        public var memoryID: String
        public var group: String
        public var outcome: Outcome
        public var dropped: [String]                // validation's reasons
        public var milliseconds: Int
        public var usage: ProviderUsage
    }

    public var runs: [String: String] = [:]          // call group → facts_run id
    public var calls: [Call] = []
    var applied = FactStore.ApplyResult()
}

/// The Facts task (memory processing §11.3): for each memory version and call group, one model call with the
/// memory, its role phrases and a roster; validation; then one transaction that applies only if the memory and the
/// roster entries the answer used are unchanged. Memories the model can't read (no Facts model, above the cloud limit,
/// a secret, the cap reached) get code-only links instead. Activity gets ids and counts, never names, labels or quotes.
///
/// Nothing in the app calls this yet: the queue, the privacy step that builds rosters from sendable items only, and
/// qualification come in later steps of Phase 13a.2.
public struct FactsExtractor: Sendable {
    public let store: VaultStore
    public let router: ModelRouter
    public let activity: any ActivityRecorder
    public let registry: FactsRegistry
    public let userAliases: [String]
    /// Until rosters are built from sendable items only (the privacy step), a Facts model that isn't on this Mac is
    /// refused, and memories get code-only links, unless this is set: the fixture harness only.
    public var unfilteredRostersAllowed = false
    /// The clock, monotonic per write in tests (roster tokens are `updated_at` values compared as text).
    public var clock: @Sendable () -> Date = { Date() }

    public init(store: VaultStore, router: ModelRouter, activity: any ActivityRecorder, registry: FactsRegistry = .bundled,
                userAliases: [String] = []) {
        self.store = store
        self.router = router
        self.activity = activity
        self.registry = registry
        self.userAliases = userAliases
    }

    /// The groups in a stable order.
    public var groups: [String] { registry.callGroups.keys.sorted() }

    /// Whether a model may be asked at all.
    var modelAllowed: Bool {
        guard let m = router.factsModel else { return false }
        return m.locality.isLocal || unfilteredRostersAllowed
    }

    /// Reads these memories, each in every call group (or the ones given), in order.
    @discardableResult
    public func learn(_ memoryIDs: [String], groups only: [String]? = nil, kind: String = "incremental") async throws -> FactsLearnReport {
        var report = FactsLearnReport()
        let groups = only ?? self.groups
        let engine = router.factsModel.map(ModelRouter.engine) ?? codeEngine
        for group in groups {
            let runID = try await store.writer.write { db in
                try FactStore.startRun(db, kind: kind, callGroup: group, registryVersion: registry.version,
                                       promptVersion: FactsPrompt.version(group, registry: registry), engine: engine, now: clock())
            }
            report.runs[group] = runID
            let first = report.calls.count
            do {
                for id in memoryIDs {
                    try Task.checkCancellation()
                    if let call = try await learnOne(id, group: group, runID: runID, into: &report.applied) { report.calls.append(call) }
                }
            } catch {
                // The run ends with its error's kind (never text); the job stays for the queue to run again.
                let now = clock(), kind = error is CancellationError ? "cancelled" : "failed"
                try? await store.writer.write { db in
                    try db.execute(sql: "UPDATE facts_run SET finished_at = ?, error = ? WHERE id = ?", arguments: [now, kind, runID])
                }
                throw error
            }
            let calls = report.calls[first...]
            func n(_ o: FactsLearnReport.Call.Outcome) -> Int { calls.filter { $0.outcome == o }.count }
            var counts: [String: Int] = ["memories": calls.count, "calls": calls.count - n(.codeOnly)]
            counts["applied"] = n(.applied)
            counts["failed"] = n(.failed)
            counts["changed"] = n(.changed)
            counts["code_only"] = n(.codeOnly)
            counts["dropped"] = calls.reduce(0) { $0 + $1.dropped.count }
            counts["input_tokens"] = calls.reduce(0) { $0 + $1.usage.inputTokens }
            counts["output_tokens"] = calls.reduce(0) { $0 + $1.usage.outputTokens }
            let now = clock(), countsJSON = FactStore.json(counts)
            try await store.writer.write { db in
                try db.execute(sql: "UPDATE facts_run SET counts = ?, finished_at = ? WHERE id = ?",
                               arguments: [countsJSON, now, runID])
            }
            activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "facts_learned",
                                          ids: UUID(uuidString: runID).map { [$0] } ?? [], counts: counts, engine: engine))
        }
        return report
    }

    /// The engine a run records when no model reads.
    let codeEngine = "code"

    struct Asked {
        var memory: FactsMemory
        var version: Int
        var sensitivity: Sensitivity
        var graph: FactsGraph
        var phrases: [RolePhrase]
        var sent: FactsSentText
        var roster: FactsRoster
        var quotedSensitivity: [String: Sensitivity]
        /// Every entity's `updated_at` when the graph was read: the apply checks the ones the answer used.
        var tokens: [String: String]
        /// The holder count of each predicate the role phrases are about, when the graph was read.
        var predicateVersions: [String: String]
        /// When the graph was read: what the reading knew.
        var readAt: Date
    }

    /// What one call would carry, read in one transaction.
    func prepare(_ memoryID: String, group: String) throws -> Asked? {
        try store.writer.read { db in
            guard let m = try Row.fetchOne(db, sql: "SELECT * FROM memory WHERE id = ?", arguments: [memoryID]),
                  ["active", "archived"].contains(m["status"] as String) else { return nil }
            let version: Int = m["version"]
            let created: Date = m["created_at"]
            let fm = FactsMemory(id: memoryID, text: FactStore.text(title: m["title"], body: m["body"]),
                                 written: FactStore.writtenDay(created),
                                 source: FactStore.source((m["original_source"] as String?) ?? m["source"]),
                                 trusted: (m["trust"] as String) == "trusted")
            let g = try FactStore.load(db, registry: registry, userAliases: userAliases).graph
            let preds = Set(registry.groupPredicates(group))
            let roster = g.roster(group, asking: fm)
            var quoted: [String: Sensitivity] = [:]
            for q in roster.quoted {
                quoted[q] = try Int.fetchOne(db, sql: "SELECT sensitivity FROM memory WHERE id = ?", arguments: [q]).flatMap(Sensitivity.init)
            }
            var tokens: [String: String] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT id, updated_at FROM entity") { tokens[r["id"]] = r["updated_at"] }
            let phrases = g.rolePhrases(fm.text, predicates: preds)
            var versions: [String: String] = [:]
            for p in Set(phrases.map(\.predicate)) { versions[p] = try FactStore.predicateVersion(db, p) }
            return Asked(memory: fm, version: version, sensitivity: Sensitivity(rawValue: m["sensitivity"]) ?? .secret, graph: g,
                         phrases: phrases,
                         sent: FactsSentText(fm.text, userAliases: userAliases, registry: registry), roster: roster,
                         quotedSensitivity: quoted, tokens: tokens, predicateVersions: versions,
                         readAt: clock())
        }
    }

    func request(_ a: Asked, group: String) -> StructuredRequest<FactsJSON> {
        StructuredRequest(instructions: FactsPrompt.instructions(group, perspective: a.memory.source, registry: registry),
                          prompt: FactsPrompt.message(roster: a.roster.text, written: a.memory.written, sent: a.sent.sent,
                                                      phrases: a.phrases.map { ph in
                                                          (FactsSentText(ph.surface, userAliases: userAliases, registry: registry).sent, ph.paired)
                                                      }),
                          schema: FactsPrompt.schema(group, registry: registry), maxOutputTokens: 4_096)
    }

    /// One memory in one call group. Nil when the memory is gone.
    func learnOne(_ memoryID: String, group: String, runID: String, into total: inout FactStore.ApplyResult) async throws -> FactsLearnReport.Call? {
        for attempt in 0..<2 {
            guard let a = try prepare(memoryID, group: group) else { return nil }
            func call(_ outcome: FactsLearnReport.Call.Outcome, dropped: [String] = [], ms: Int = 0, usage: ProviderUsage = .init()) -> FactsLearnReport.Call {
                .init(memoryID: memoryID, group: group, outcome: outcome, dropped: dropped, milliseconds: ms, usage: usage)
            }
            guard modelAllowed else {
                try codeOnly(a, group: group, runID: runID)
                return call(.codeOnly)
            }
            let items = [ModelItem(a.sent.sent, sensitivity: a.sensitivity)]
                + a.roster.quoted.map { q in
                    ModelItem(FactsSentText(a.graph.memories[q]?.text ?? "", userAliases: userAliases, registry: registry).sent,
                              sensitivity: a.quotedSensitivity[q] ?? nil)
                }
            let requester: CloudRequestCap.Requester = a.memory.source == .agent ? .agent : .user
            let before = router.usageCounters()[router.factsModel!.id] ?? ProviderUsage()
            let started = clock()
            var output: FactsJSON?
            var tries = 0
            while output == nil, tries < 2 {          // one retry on an answer that isn't the schema's (§9.6)
                tries += 1
                do {
                    output = try await router.facts(request(a, group: group), items: items, requester: requester, now: clock())
                } catch ProviderError.invalidOutput {
                    continue
                } catch let e as ProviderError where [.blocked, .capReached, .unavailable].contains(e) {
                    try codeOnly(a, group: group, runID: runID)
                    return call(.codeOnly)
                } catch is ProviderError {
                    break
                }
            }
            let ms = Int(clock().timeIntervalSince(started) * 1_000)
            let after = router.usageCounters()[router.factsModel!.id] ?? ProviderUsage()
            let usage = ProviderUsage(requests: after.requests - before.requests, inputTokens: after.inputTokens - before.inputTokens,
                                      outputTokens: after.outputTokens - before.outputTokens)
            guard let output else { return call(.failed, ms: ms, usage: usage) }
            let v = FactsValidator(graph: a.graph, sent: a.sent, roster: a.roster.ids, phrases: a.phrases,
                                   predicates: registry.groupPredicates(group), knownThings: a.roster.things,
                                   trusted: a.memory.trusted).validate(output)
            // The roster entries the answer used: those it names, and the holders of the phrases it was asked about.
            var used = v.referenced
            // A name left ambiguous rests on who shared it when the graph was read.
            for p in v.people where p.person == "ambiguous" {
                used.formUnion(a.graph.byName(p.name, onlyTrusted: a.memory.trusted).map(\.id))
            }
            for ph in a.phrases {
                let (d, w) = a.graph.asOf(a.memory, ph)
                used.formUnion(a.graph.holders(ph, asOf: d, written: w).holders.map(\.entity.id))
            }
            do {
                // New entities (none yet) have no token: they can't have changed under the call.
                var extraction = FactsExtraction(people: v.people, facts: v.facts, roles: v.roles, things: v.things,
                                                 roster: a.tokens.filter { used.contains($0.key) })
                extraction.predicateVersions = a.predicateVersions
                let x = extraction
                let result = try await store.writer.write { db in
                    try FactStore.apply(db, memoryID: memoryID, version: a.version, extraction: x, callGroup: group,
                                        runID: runID, registry: registry, userAliases: userAliases, now: clock(), readAt: a.readAt)
                }
                total.add(result)
                return call(.applied, dropped: v.dropped.map(\.reason), ms: ms, usage: usage)
            } catch let e as FactStore.ApplyError {
                if attempt == 1 { return call(.changed, dropped: [e == .memoryChanged ? "memory_changed" : "roster_changed"], ms: ms, usage: usage) }
            }
        }
        return nil
    }

    /// Code-only links for a memory the model can't read (memory processing §11.3): names only for known people's
    /// aliases of two or more words, or confirmed ones, matched as whole words, and only where exactly one person has
    /// that alias. Role phrases need nothing stored: they resolve through known facts when read. A memory version the
    /// model already read in this group keeps that reading.
    func codeOnly(_ a: Asked, group: String, runID: String) throws {
        guard registry.groupPredicates(group).contains(where: { registry.kindOf($0) == FactsValidator.personKind }) else { return }
        try store.writer.write { db in
            // Only for the version the snapshot read, if it's still current and the model hasn't read it since.
            guard let m = try Row.fetchOne(db, sql: "SELECT version, status FROM memory WHERE id = ?", arguments: [a.memory.id]),
                  (m["version"] as Int) == a.version, ["active", "archived"].contains(m["status"] as String),
                  try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM fact_evidence WHERE memory_id = ?1 AND memory_version = ?2 AND call_group = ?3)
                      OR EXISTS (SELECT 1 FROM alias_evidence WHERE memory_id = ?1 AND memory_version = ?2 AND call_group = ?3 AND source = 'model')
                      OR EXISTS (SELECT 1 FROM mention_decision WHERE memory_id = ?1 AND memory_version = ?2 AND call_group = ?3 AND source = 'model')
                    """, arguments: [a.memory.id, a.version, group]) == false else { return }
            try db.execute(sql: "DELETE FROM alias_evidence WHERE memory_id = ? AND memory_version = ? AND call_group = ? AND source = 'code'",
                           arguments: [a.memory.id, a.version, group])
            let removed = db.changesCount > 0
            let stop = Set(registry.language.stopNames.map { FactsText.fold($0) })
            // Who has which name now, not when the call was prepared.
            let g = try FactStore.load(db, registry: registry, userAliases: userAliases).graph
            var byAlias: [String: [(aliasID: String, entity: String, text: String, usable: Bool)]] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT a.id, a.entity_id, a.alias, a.normalized, a.confirmed, a.manual FROM entity_alias a JOIN entity e ON e.id = a.entity_id
                WHERE e.kind = ? AND e.is_you = 0 AND e.tombstone = 0 ORDER BY a.rowid
                """, arguments: [FactsValidator.personKind]) {
                let text: String = (r["alias"] as String?) ?? r["normalized"]
                let entity: String = r["entity_id"]
                guard let e = g.entities[entity], e.aliases.contains(text) || (r["confirmed"] as Int) == 1 || (r["manual"] as Int) == 1
                else { continue }
                let confirmed = (r["confirmed"] as Int) == 1 || (r["manual"] as Int) == 1
                let f = FactsText.fold(text)
                // A trusted memory's names match only aliases trusted memories, or the user, gave (§11.4).
                let usable = (confirmed || f.split(separator: " ").count >= 2) && !stop.contains(f) && f.count >= 3
                    && (!a.memory.trusted || confirmed || e.trustedAliases.contains(text))
                byAlias[f, default: []].append((r["id"], entity, text, usable))
            }
            let trust = a.memory.trusted ? "trusted" : "untrusted"
            var wrote = false
            for (_, hits) in byAlias.sorted(by: { $0.key < $1.key }) {
                // Exactly one person has the name, by the kind's own rule too ("Maria" is also Maria Silva's first name).
                guard Set(hits.map(\.entity)).count == 1, let hit = hits.first(where: \.usable),
                      Set(g.byName(hit.text).map(\.id)) == [hit.entity],
                      let r = FactsText.wholeWord(hit.text, in: a.memory.text) else { continue }
                wrote = true
                try db.execute(sql: """
                    INSERT OR REPLACE INTO alias_evidence (alias_id, memory_id, memory_version, span_start, span_end, quote, sensitivity,
                      trust, run_id, call_group, source, read_at, first_read_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'code', ?, ?)
                    """, arguments: [hit.aliasID, a.memory.id, a.version, FactStore.scalarOffset(a.memory.text, utf16: r.location),
                                     FactStore.scalarOffset(a.memory.text, utf16: r.location + r.length),
                                     FactsText.substring(a.memory.text, r.location, r.location + r.length),
                                     a.sensitivity.rawValue, trust, runID, group, a.readAt, clock()])
            }
            if wrote || removed { try FactStore.bumpRevision(db) }
        }
    }
}

extension FactStore.ApplyResult {
    mutating func add(_ r: FactStore.ApplyResult) {
        entities += r.entities
        facts += r.facts
        evidence += r.evidence
        decisions += r.decisions
        mergeSuggestions += r.mergeSuggestions
        ambiguousNames += r.ambiguousNames
    }
}

extension FactsText {
    /// The first whole-word, case- and accent-insensitive occurrence of a name in a text (UTF-16 range).
    static func wholeWord(_ name: String, in text: String) -> NSRange? {
        let ns = text as NSString
        var from = 0
        while from < ns.length {
            let r = ns.range(of: name, options: [.caseInsensitive, .diacriticInsensitive],
                             range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { return nil }
            func letter(_ i: Int) -> Bool {
                guard i >= 0, i < ns.length, let u = Unicode.Scalar(ns.character(at: i)) else { return false }
                return CharacterSet.alphanumerics.contains(u)
            }
            if !letter(r.location - 1), !letter(r.location + r.length) { return r }
            from = r.location + 1
        }
        return nil
    }
}
