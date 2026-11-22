import Foundation
import FunesProtocol
import GRDB
import Synchronization

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
        /// Requests sent under the first backfill's exemption (at most one: `FactsExtractor.exemptVersion`).
        public var exempt = 0
        /// `ModelRouter.send` refused the call (a secret, an item above the cloud limit): code-only links, no request.
        public var refused = false
        /// The last request asked for was low-priority Facts work (`FactsExtractor.priority`), held to its share of the cap.
        public var lowPriority = false
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
/// A Facts model that isn't on this Mac gets a roster built from what's sendable under the cloud limit only
/// (`FactStore.withheld`, memory processing §11.9), each line a typed item with the highest sensitivity behind it, and
/// the memory text with the user's names replaced by the profile matcher (`FactsSentText`). A local model gets the whole
/// roster. Validation and the apply use the whole graph: that's local work.
///
/// **Gating** (memory processing §11.10): a group's model is asked only while some predicate of the group is recorded
/// with it (a qualification record for that model, adapter, batching, the group's prompt version and the registry
/// version, and no off-switch), read in the same transaction as the call's graph. Facts the answer gives for a
/// predicate that isn't recorded are dropped, and earlier ones are hidden (`FactStore.load`). The prompt and schema stay
/// the declared group's, so the prompt version never depends on the gate.
///
/// The app runs it through the facts lane (`FactsQueueWorker`, from the Mac's processing runner) while *Learn from
/// memories* is on; `permit` is checked before every request, so turning learning off, closing the lane or changing
/// the configuration stops a running job at its next send.
public struct FactsExtractor: Sendable {
    public let store: VaultStore
    public let router: ModelRouter
    public let activity: any ActivityRecorder
    public let registry: FactsRegistry
    public let userAliases: [String]
    /// The records the calls are checked against (the shipped ones; `.unchecked` only to measure a model).
    public let qualification: FactsQualification
    /// Each group's prompt version, as records name it.
    let promptVersions: [String: String]
    /// The clock, monotonic per write in tests (roster tokens are `updated_at` values compared as text).
    public var clock: @Sendable () -> Date = { Date() }
    /// Checked before every request, retries included: false stops the job there, with nothing sent or written, and the
    /// queue runs it again later (`FactsLane.permits`, in the app).
    public var permit: @Sendable () -> Bool = { true }
    /// The first backfill (FR-F-03): a full read of the memory at exactly this version skips the daily cap. Set by
    /// `FactsQueueWorker` for a marked job while the backfill runs; every other request counts.
    public var exemptVersion: Int?
    /// Called the moment the exempt request is sent, before the provider answers: the worker records it as spent in the
    /// store, so a quit or crash after sending can't grant it again.
    public var exemptSpent: @Sendable () throws -> Void = {}
    /// How urgent each counted request is (memory processing §11.3 "Cost and the cap"): asked right before every
    /// request, retries included, with the memory version being read (a partial read of a version the model hasn't read
    /// in this group is applied whole, so it's judged by the version, not the scope). Low-priority work is held to
    /// `CloudRequestCap.lowPriorityShare`. `FactsQueueWorker` sets it per job; direct `learn` calls are normal. A full
    /// read of the version `exemptVersion` names is normal whatever it says (the backfill read's own retry).
    public var priority: @Sendable (_ version: Int) throws -> CloudRequestCap.Priority = { _ in .normal }

    /// How calls are batched, and the pipeline's revision (a qualification record names it, memory processing §11.10):
    /// one memory per call per group, full or partial. Bump the revision when validation, the apply, rosters,
    /// reconciliation or scheduling change in a way that could move a gate's result; the recorded-call replays guard it.
    /// 3 (13e.2): a paired name no longer spans a line break.
    public static let batching = "one-memory;pipeline=3"

    public init(store: VaultStore, router: ModelRouter, activity: any ActivityRecorder, registry: FactsRegistry = .bundled,
                userAliases: [String] = [], qualification: FactsQualification = .bundled) {
        self.store = store
        self.router = router
        self.activity = activity
        self.registry = registry
        self.userAliases = userAliases
        self.qualification = qualification
        let versions = FactsQualification.promptVersions(registry)
        promptVersions = versions
        extractionKeys = Dictionary(uniqueKeysWithValues: registry.callGroups.keys.map { g in
            (g, (versions[g] ?? "") + "." + (registry.extractionDigests[g] ?? ""))
        })
    }

    /// Each group's extraction key: its prompt version (the prompt resource, instructions and schema) and the
    /// registry's extraction digest for it. A language-only change leaves it as is.
    let extractionKeys: [String: String]

    /// The key a model reading in `group` is made under (its `read` record keeps it): the extraction key and the
    /// predicates recorded now. `FactsExtractor.isStale` compares it with a later one.
    func readKey(_ group: String, _ uses: FactsUses) -> String {
        "x=\(extractionKeys[group] ?? "");r=" + uses.predicates(.recorded, group: group).sorted().joined(separator: ",")
    }

    /// Whether a reading made under `stored` should be read again under `current` (memory processing §11.3, §11.10):
    /// the group's extraction changed, or a predicate is recorded now that wasn't then (coverage grew). Fewer recorded
    /// predicates hide rows at load and need no re-read. A record with no key (made before keys were kept) is current.
    static func isStale(_ stored: String, current: String) -> Bool {
        func parts(_ k: String) -> (x: String, r: Set<String>)? {
            var x: String?, r = Set<String>()
            for part in k.split(separator: ";", omittingEmptySubsequences: false) {
                if part.hasPrefix("x=") { x = String(part.dropFirst(2)) }
                if part.hasPrefix("r=") { r = Set(part.dropFirst(2).split(separator: ",").map(String.init)) }
            }
            return x.map { ($0, r) }
        }
        guard let old = parts(stored), let now = parts(current) else { return false }
        return old.x != now.x || !now.r.isSubset(of: old.r)
    }

    /// The groups in a stable order.
    public var groups: [String] { registry.callGroups.keys.sorted() }

    /// Each group's engine, from the router.
    var engines: [String: FactsEngine] { router.factsModels.mapValues { FactsEngine($0) } }

    /// What's on now: the records for the router's engines, with the local off-switches read in this transaction.
    func currentUses(_ db: Database) throws -> FactsUses {
        try qualification.withOffSwitches(db).uses(engines: engines, registry: registry, promptVersions: promptVersions)
    }

    /// Whether a group's model may be asked: there is one, and some predicate of the group is recorded with it.
    func modelAllowed(_ group: String, _ uses: FactsUses) -> Bool {
        router.factsModels[group] != nil && !uses.predicates(.recorded, group: group).isEmpty
    }

    /// The limit a call's roster is built under: the cloud limit when any group's Facts model isn't on this Mac (the
    /// strictest, so reconciliation compares every group on one graph), nil (the whole graph) when all are local.
    var rosterLimit: CloudLimit? {
        guard router.factsModels.values.contains(where: { !$0.locality.isLocal }) else { return nil }
        return router.cloudLimit
    }

    /// Reads these memories, each in every call group (or the ones given), in order.
    @discardableResult
    public func learn(_ memoryIDs: [String], groups only: [String]? = nil, kind: String = "incremental",
                      scope: FactsScope = .full) async throws -> FactsLearnReport {
        var report = FactsLearnReport()
        let groups = only ?? self.groups
        for group in groups {
            let allowed = try await store.writer.read { db in modelAllowed(group, try currentUses(db)) }
            let engine = allowed ? router.factsModels[group].map(ModelRouter.engine) ?? codeEngine : codeEngine
            let runID = try await store.writer.write { db in
                try FactStore.startRun(db, kind: kind, callGroup: group, registryVersion: registry.fingerprint,
                                       promptVersion: FactsPrompt.version(group, registry: registry), engine: engine,
                                       capExempt: kind == Self.backfillKind, now: clock())
            }
            report.runs[group] = runID
            let first = report.calls.count
            do {
                for id in memoryIDs {
                    try Task.checkCancellation()
                    if let call = try await learnOne(id, group: group, runID: runID, scope: scope, into: &report.applied) {
                        report.calls.append(call)
                    }
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
            let exempt = calls.reduce(0) { $0 + $1.exempt }
            if exempt > 0 { counts["exempt"] = exempt }
            counts["input_tokens"] = calls.reduce(0) { $0 + $1.usage.inputTokens }
            counts["output_tokens"] = calls.reduce(0) { $0 + $1.usage.outputTokens }
            let now = clock(), countsJSON = FactStore.json(counts)
            try await store.writer.write { db in
                try db.execute(sql: "UPDATE facts_run SET counts = ?, finished_at = ? WHERE id = ?",
                               arguments: [countsJSON, now, runID])
            }
            // The backfill's reads are told once, when it ends (`facts_backfill`), rather than one row per memory.
            if kind != Self.backfillKind {
                activity.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "facts_learned",
                                              ids: UUID(uuidString: runID).map { [$0] } ?? [], counts: counts, engine: engine))
            }
        }
        return report
    }

    /// The engine a run records when no model reads.
    let codeEngine = "code"

    /// A code-only outcome whose cause passes (a model that's unavailable): the model should read later.
    static let transient = "model_unavailable"
    /// A code-only outcome at the daily cap (or the agents' share of it): the model reads once the cap resets.
    static let capReached = "cap_reached"
    /// No answer because the provider failed (a rate limit, the network, a timeout), not because the answer was invalid.
    static let providerFailed = "provider_failed"
    /// A run of the first backfill's exempt full reads (`facts_run.kind`).
    static let backfillKind = "backfill"

    /// Validation notes that record what code added, not something the model said that was dropped.
    static let codeAdditions: Set<String> = ["paired_applied", "paired_relation_added", "denial"]

    /// A code-only outcome because no qualified model reads the group (§11.10): not transient.
    static let unqualified = "unqualified"
    /// What's recorded changed between a call and its retry: the job reads again from the start.
    static let qualificationChanged = "qualification_changed"
    /// A fact the answer gave for a predicate that isn't recorded: dropped, and not the model's error.
    static let unqualifiedPredicate = "unqualified_predicate"
    /// `permit` said no before a request: learning turned off, the lane closed or the configuration changed.
    static let notPermitted = "not_permitted"

    struct Asked {
        var memory: FactsMemory
        var version: Int
        var sensitivity: Sensitivity
        var graph: FactsGraph
        /// The graph the roster comes from: the sendable one for a cloud model, else `graph`.
        var rosterGraph: FactsGraph
        /// The highest sensitivity behind each roster line (a sendable graph's).
        var lineSensitivity: [Sensitivity?]
        /// Known things by the whole graph, for validation (a thing the roster doesn't show still isn't a person).
        var things: Set<String>
        var phrases: [RolePhrase]
        /// What's on, read with the graph.
        var uses: FactsUses
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
            let uses = try currentUses(db)
            let g = try FactStore.load(db, registry: registry, userAliases: userAliases, uses: uses).graph
            let preds = Set(uses.predicates(.recorded, group: group))
            let limit = rosterLimit
            let sendable = try limit.map { try FactStore.load(db, registry: registry, userAliases: userAliases, uses: uses, sendable: $0) }
            let rg = sendable?.graph ?? g
            let roster = rg.roster(group, asking: fm)
            let lineSensitivity: [Sensitivity?] = roster.lines.map { line in
                guard let sendable else { return nil }
                let levels = line.entities.map { sendable.sensitivity[$0] }
                // Unknown sensitivity never goes to a cloud provider (`ModelRouter.send`).
                return levels.contains(where: { $0 == nil }) ? nil : Sensitivity(rawValue: levels.compactMap { $0 }.max() ?? 0)
            }
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
                         rosterGraph: rg, lineSensitivity: lineSensitivity,
                         things: sendable == nil ? roster.things : g.roster(group, asking: fm).things,
                         phrases: phrases, uses: uses,
                         sent: rg.sentText(fm.text), roster: roster,
                         quotedSensitivity: quoted, tokens: tokens, predicateVersions: versions,
                         readAt: clock())
        }
    }

    func request(_ a: Asked, group: String) -> StructuredRequest<FactsJSON> {
        StructuredRequest(instructions: FactsPrompt.instructions(group, perspective: a.memory.source, registry: registry),
                          prompt: FactsPrompt.message(roster: a.roster.text, written: a.memory.written, sent: a.sent.sent,
                                                      phrases: a.phrases.map { ph in
                                                          // The phrase as the text sent writes it; a pair only as the
                                                          // text sent has it (a user's name replaced there isn't sent).
                                                          (a.sent.sentSlice(NSRange(location: ph.start, length: ph.end - ph.start)),
                                                           ph.paired.flatMap { p in FactsSentText.findWord(p, in: a.sent.sent) != nil ? p : nil })
                                                      }),
                          schema: FactsPrompt.schema(group, registry: registry), maxOutputTokens: 4_096)
    }

    /// One memory in one call group. Nil when the memory is gone.
    func learnOne(_ memoryID: String, group: String, runID: String, scope: FactsScope = .full,
                  into total: inout FactStore.ApplyResult) async throws -> FactsLearnReport.Call? {
        // Whether the backfill's exempt request was sent, across both attempts: one per marked read.
        let spent = Mutex(0)
        // The last request's priority, for the report (the queue tells the low-priority share's wait apart).
        let low = Mutex(false)
        for attempt in 0..<2 {
            guard let a = try prepare(memoryID, group: group) else { return nil }
            func call(_ outcome: FactsLearnReport.Call.Outcome, dropped: [String] = [], ms: Int = 0, usage: ProviderUsage = .init()) -> FactsLearnReport.Call {
                .init(memoryID: memoryID, group: group, outcome: outcome, dropped: dropped, milliseconds: ms, usage: usage,
                      exempt: spent.withLock { $0 }, lowPriority: low.withLock { $0 })
            }
            // A partial re-read is of a version the model has read: it never falls back to code-only links.
            let partial = scope != .full
            // No qualified model, or a cloud model and a memory above its limit: code-only links, with no request built.
            guard modelAllowed(group, a.uses), let model = router.factsModels[group],
                  rosterLimit.map({ $0.allows(a.sensitivity) }) ?? true else {
                if !partial { try codeOnly(a, group: group, runID: runID) }
                let unqualified = router.factsModels[group] != nil && !modelAllowed(group, a.uses)
                return call(.codeOnly, dropped: unqualified ? [Self.unqualified] : [])
            }
            // Typed items (memory processing §11.9): the memory, the memories the roster quotes and every roster line,
            // each with its sensitivity, so `ModelRouter.send` refuses a cloud call if anything is above the limit.
            let items = [ModelItem(a.sent.sent, sensitivity: a.sensitivity)]
                + a.roster.quoted.map { q in
                    ModelItem(a.rosterGraph.sentText(a.rosterGraph.memories[q]?.text ?? "").sent, sensitivity: a.quotedSensitivity[q] ?? nil)
                }
                + (rosterLimit == nil ? [] : zip(a.roster.lines, a.lineSensitivity).map { ModelItem($0.0.text, sensitivity: $0.1) })
            let requester: CloudRequestCap.Requester = a.memory.source == .agent ? .agent : .user
            let before = router.usageCounters()[model.id] ?? ProviderUsage()
            let started = clock()
            var output: FactsJSON?
            var tries = 0, providerFailure = false
            // The first backfill's one exemption (FR-F-03): one request of a full read of the version it marked. It's
            // spent once a request is sent, whatever comes back; a retry, or an attempt after it, counts against the cap.
            let exemptRead = !partial && exemptVersion == a.version
            while output == nil, tries < 2 {          // one retry on an answer that isn't the schema's (§9.6)
                // §11.10, at every call: a retry with a use turned off since the graph was read starts over instead.
                if tries > 0 {
                    let now = try await store.writer.read { db in try currentUses(db) }
                    if now.predicates(.recorded, group: group) != a.uses.predicates(.recorded, group: group) {
                        return call(.changed, dropped: [Self.qualificationChanged])
                    }
                }
                tries += 1
                guard permit() else { return call(.changed, dropped: [Self.notPermitted]) }
                do {
                    let exempt = exemptRead && spent.withLock { $0 } == 0
                    // Decided for the version prepared now, at each request: an edit since the job was planned counts as
                    // what it is (§11.3).
                    let priority: CloudRequestCap.Priority = exemptRead ? .normal : try self.priority(a.version)
                    low.withLock { $0 = priority == .low }
                    output = try await router.facts(request(a, group: group), group: group, items: items, requester: requester,
                                                    priority: priority, exempt: exempt, permit: permit,
                                                    willSend: {
                                                        guard exempt else { return }
                                                        try exemptSpent()           // fails closed: unrecorded, unsent
                                                        spent.withLock { $0 = 1 }
                                                    }, now: clock())
                } catch is SendNotPermitted {
                    return call(.changed, dropped: [Self.notPermitted])
                } catch ProviderError.invalidOutput {
                    continue
                } catch let e as ProviderError where [.blocked, .capReached, .unavailable].contains(e) {
                    if !partial { try codeOnly(a, group: group, runID: runID) }
                    // The cap and an unavailable model pass: the queue asks again later.
                    var c = call(.codeOnly, dropped: e == .blocked ? [] : [e == .capReached ? Self.capReached : Self.transient])
                    c.refused = e == .blocked
                    return c
                } catch is ProviderError {
                    providerFailure = true
                    break
                }
            }
            let ms = Int(clock().timeIntervalSince(started) * 1_000)
            let after = router.usageCounters()[model.id] ?? ProviderUsage()
            let usage = ProviderUsage(requests: after.requests - before.requests, inputTokens: after.inputTokens - before.inputTokens,
                                      outputTokens: after.outputTokens - before.outputTokens)
            guard let output else { return call(.failed, dropped: providerFailure ? [Self.providerFailed] : [], ms: ms, usage: usage) }
            var v = FactsValidator(graph: a.graph, sent: a.sent, roster: a.roster.ids, phrases: a.phrases,
                                   predicates: registry.groupPredicates(group), knownThings: a.things,
                                   trusted: a.memory.trusted).validate(output)
            // A predicate that isn't recorded with this model (§11.10): what the answer says of it isn't kept.
            v.facts = v.facts.enumerated().compactMap { i, f in
                if a.uses.isOn(f.predicate, .recorded) { return f }
                v.dropped.append(.init(reason: Self.unqualifiedPredicate, index: i))
                return nil
            }
            if rosterLimit != nil { unseen(&v, a) }
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
                extraction.scope = scope
                extraction.readKey = readKey(group, a.uses)
                extraction.clean = v.dropped.allSatisfy {
                    Self.codeAdditions.contains($0.reason) || Self.unseenNotes.contains($0.reason) || $0.reason == Self.unqualifiedPredicate
                }
                let x = extraction, limit = rosterLimit, uses = a.uses
                let result = try await store.writer.write { db in
                    try FactStore.apply(db, memoryID: memoryID, version: a.version, extraction: x, callGroup: group,
                                        runID: runID, registry: registry, userAliases: userAliases, uses: uses, now: clock(),
                                        readAt: a.readAt, sendable: limit)
                }
                total.add(result)
                return call(.applied, dropped: v.dropped.map(\.reason), ms: ms, usage: usage)
            } catch let e as FactStore.ApplyError {
                if attempt == 1 { return call(.changed, dropped: [e == .memoryChanged ? "memory_changed" : "roster_changed"], ms: ms, usage: usage) }
            }
        }
        return nil
    }

    /// Notes for answers about what a cloud call couldn't see: not something the model got wrong.
    static let unseenNotes: Set<String> = ["unseen_namesake", "unseen_holder"]

    /// A cloud call saw only what's sendable. A name that could also mean someone it couldn't see is kept as ambiguous
    /// (asked again when its candidates change), with nothing the answer attached to that person; a role answer, or a
    /// fact about someone the memory doesn't name, is dropped when the predicate has a holder the call couldn't see (code
    /// resolves the phrase when it's read). Rather than decided without them.
    func unseen(_ v: inout FactsValidated, _ a: Asked) {
        let shown = Set(a.rosterGraph.entities.keys)
        var converted = Set<String>(), convertedNames = Set<String>()
        for i in v.people.indices where v.people[i].person != "ambiguous" {
            let candidates = a.graph.byName(v.people[i].name, onlyTrusted: a.memory.trusted).map(\.id)
            if candidates.contains(where: { !shown.contains($0) }) {
                if a.graph.entities[v.people[i].person] != nil { converted.insert(v.people[i].person) }
                convertedNames.insert(FactsText.fold(v.people[i].name))
                v.people[i].person = "ambiguous"
                v.dropped.append(.init(reason: "unseen_namesake", index: i))
            }
        }
        /// Holders of a predicate the whole graph knows that the call didn't see holding it: named, or a group's count.
        func unseenHolders(_ predicate: String) -> Bool {
            let all = Set(a.graph.facts.filter { $0.predicate == predicate && !$0.negated }.map(\.entity))
            let seen = Set(a.rosterGraph.facts.filter { $0.predicate == predicate && !$0.negated }.map(\.entity))
            let counts = a.graph.entities.values.filter { $0.group?.predicate == predicate && $0.name == nil }
            return !all.isSubset(of: seen) || counts.contains { a.rosterGraph.entities[$0.id]?.count != $0.count }
        }
        let named = Set(v.people.map(\.person))
        v.facts = v.facts.enumerated().compactMap { i, f in
            if converted.contains(f.entity) {
                v.dropped.append(.init(reason: "unseen_namesake", index: i))
                return nil
            }
            if a.graph.entities[f.entity]?.kind == FactsValidator.personKind, !named.contains(f.entity), unseenHolders(f.predicate) {
                v.dropped.append(.init(reason: "unseen_holder", index: i))
                return nil
            }
            return f
        }
        v.roles.removeAll { r in
            guard a.phrases.indices.contains(r.phrase) else { return false }
            // A role answer through a name kept as ambiguous rests on it too.
            if converted.contains(r.refersTo)
                || (r.refersTo.hasPrefix("name:") && convertedNames.contains(FactsText.fold(String(r.refersTo.dropFirst(5))))) {
                v.dropped.append(.init(reason: "unseen_namesake", index: r.phrase))
                return true
            }
            let ph = a.phrases[r.phrase]
            let (d, w) = a.graph.asOf(a.memory, ph)
            let all = a.graph.holders(ph, asOf: d, written: w)
            let (rd, rw) = a.rosterGraph.asOf(a.memory, ph)
            let seen = a.rosterGraph.holders(ph, asOf: rd, written: rw)
            // Named holders, and those a count says exist.
            guard !Set(all.holders.map(\.entity.id)).isSubset(of: Set(seen.holders.map(\.entity.id))) || all.extra > seen.extra
            else { return false }
            v.dropped.append(.init(reason: "unseen_holder", index: r.phrase))
            return true
        }
    }

    /// Code-only links for a memory the model can't read (memory processing §11.3): names only for known people's
    /// aliases of two or more words, or confirmed ones, matched as whole words, and only where exactly one person has
    /// that alias. Role phrases need nothing stored: they resolve through known facts when read. A memory version the
    /// model already read in this group keeps that reading.
    func codeOnly(_ a: Asked, group: String, runID: String) throws {
        guard a.uses.predicates(.recorded, group: group).contains(where: { registry.kindOf($0) == FactsValidator.personKind }) else { return }
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
            let g = try FactStore.load(db, registry: registry, userAliases: userAliases, uses: try currentUses(db)).graph
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
    static func wholeWord(_ name: String, in text: String, from start: Int = 0) -> NSRange? {
        let ns = text as NSString
        var from = start
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
