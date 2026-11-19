import Foundation
import FunesProtocol
import GRDB

/// One memory's validated extraction for one call group (13a.2 produces it from the model's output).
public struct FactsExtraction: Sendable {
    public var people: [ExtractedPerson]
    public var facts: [ExtractedFact]
    public var roles: [ExtractedRole]
    /// Named things that aren't people: entities of their kind, with this memory's alias evidence.
    public var things: [ExtractedThing]
    /// Roster entries the call used, with the `updated_at` each had (the apply checks they're unchanged).
    public var roster: [String: String]
    /// The holder count of each predicate whose role phrases the call was asked about, when it was read: a holder
    /// added since (one that had no roster token) also means the call's view changed.
    public var predicateVersions: [String: String] = [:]
    /// What a reconciliation re-read replaces (memory processing §11.3); `.full` is a whole reading.
    public var scope: FactsScope = .full
    /// Validation dropped nothing the model said (only the code's own additions are noted): a re-read that moves a
    /// name to someone else replaces the earlier reading only then.
    public var clean = true
    /// The key the reading was made under (`FactsExtractor.readKey`: the group's extraction key and what was recorded),
    /// kept on its `read` record so a registry change or grown coverage re-reads it (memory processing §11.3).
    public var readKey = ""

    public init(people: [ExtractedPerson] = [], facts: [ExtractedFact] = [], roles: [ExtractedRole] = [],
                things: [ExtractedThing] = [], roster: [String: String] = [:]) {
        self.people = people
        self.facts = facts
        self.roles = roles
        self.things = things
        self.roster = roster
    }
}

/// What a Facts call's answer replaces (memory processing §11.3). A first reading of a memory version in a call group is
/// `.full`. A reconciliation re-read re-asks only some role phrases (by scalar start) and one-word names (folded), as the
/// spike did: the call is the same, but only what it was about is applied, so an answer that fails validation can't
/// erase what an earlier reading found.
public enum FactsScope: Sendable, Equatable {
    case full
    case partial(roles: Set<Int>, names: Set<String>)

    /// What a partial apply leaves out of the graph it starts from, and replaces.
    struct Replaced: Equatable {
        var roles: Set<Int>
        var names: Set<String>
    }
}

/// Learned facts in the vault (storage §2 `v9_facts`, memory processing §11). The tables hold evidence, never derived
/// dates: `load` builds a `FactsGraph` from what still counts, and `apply` writes one memory's extraction as evidence.
enum FactStore {
    // MARK: Memories as learned facts see them

    /// The text spans and quotes are offsets into.
    static func text(title: String, body: String) -> String { "\(title)\n\(body)" }

    static func source(_ s: String) -> FactsMemory.Source {
        switch MemorySource(rawValue: s) {
        case .agentWrite, .agentSuggestion: return .agent
        case .importChatGPT, .importClaude, .importMarkdown, .importFunes: return .import   // the original date is unknown
        case .tidyUp: return .rewritten
        case .manual: return .manual
        default: return .capture
        }
    }

    static func writtenDay(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 1, c.month ?? 1, c.day ?? 1)
    }

    /// A memory that learned facts may count: active or archived, at its current version.
    struct Counted {
        var memory: FactsMemory
        var version: Int
        var status: String
        var sensitivity: Int
        var seq: Int
    }

    static func countedMemories(_ db: Database, ids: Set<String>? = nil) throws -> [String: Counted] {
        var out: [String: Counted] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, seq, title, body, created_at, COALESCE(original_source, source) AS source, trust, status, version, sensitivity FROM memory
            WHERE status IN ('active','archived') AND id IN (
              SELECT memory_id FROM fact_evidence WHERE memory_id IS NOT NULL
              UNION SELECT memory_id FROM alias_evidence UNION SELECT memory_id FROM mention_decision
              UNION SELECT memory_id FROM manual_override WHERE memory_id IS NOT NULL)
            """)
        for r in rows {
            let id: String = r["id"]
            if let ids, !ids.contains(id) { continue }
            let created: Date = r["created_at"]
            let fm = FactsMemory(id: id, text: text(title: r["title"], body: r["body"]), written: writtenDay(created),
                                 source: source(r["source"]), trusted: (r["trust"] as String) == "trusted")
            out[id] = Counted(memory: fm, version: r["version"], status: r["status"], sensitivity: r["sensitivity"], seq: r["seq"])
        }
        return out
    }

    // MARK: Offsets (storage keeps Unicode scalar offsets; the graph uses UTF-16)

    static func scalarOffset(_ text: String, utf16 n: Int) -> Int {
        let idx = String.Index(utf16Offset: min(max(0, n), text.utf16.count), in: text)
        return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: idx)
    }

    static func utf16Offset(_ text: String, scalar k: Int) -> Int {
        let us = text.unicodeScalars
        let idx = us.index(us.startIndex, offsetBy: min(max(0, k), us.count))
        return idx.utf16Offset(in: text)
    }

    /// Where a quote is in a text now, as UTF-16 offsets: the occurrence nearest the scalar offset it had.
    static func locate(_ quote: String?, in text: String, near scalarStart: Int?) -> (start: Int, end: Int)? {
        guard let quote, !quote.isEmpty else { return nil }
        let ns = text as NSString
        var hits: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: quote, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            hits.append(r)
            from = r.location + max(1, r.length)
        }
        let want = scalarStart.map { utf16Offset(text, scalar: $0) } ?? 0
        guard let best = hits.firstMin(by: { abs($0.location - want) }) else { return nil }
        return (best.location, best.location + best.length)
    }

    // MARK: JSON

    static func json(_ dict: [String: Any]) -> String {
        let clean = dict.filter { !($0.value is NSNull) }
        guard let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ s: String?) -> [String: Any] {
        guard let s, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func selector(_ s: String?) -> DateRange? {
        let o = object(s)
        guard let lo = o["lo"] as? Int, let hi = o["hi"] as? Int else { return nil }
        return DateRange(lo: lo, hi: hi)
    }

    static func selectorJSON(_ r: DateRange?) -> String? { r.map { json(["lo": $0.lo, "hi": $0.hi]) } }

    // MARK: The facts revision (companion protocol status.get's factsRevision)

    /// Bumps the facts revision. Whatever changed may make an earlier reading worth asking again, so the facts lane's
    /// reconciliation sweep is queued in the same transaction (memory processing §11.3), once any model reading exists.
    /// The sweep's own revalidations pass `reconcile: false`.
    static func bumpRevision(_ db: Database, reconcile: Bool = true, now: Date = Date()) throws {
        try db.execute(sql: "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'facts_revision'")
        if reconcile, try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM facts_asked WHERE mention_kind = 'read')") == true {
            try ProcessingQueue.enqueueFactsSweep(db, now: now)
        }
    }

    static func revision(_ db: Database) throws -> String {
        let epoch = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'facts_epoch'") ?? ""
        let counter = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'facts_revision'") ?? "0"
        return "\(epoch).\(counter)"
    }

    static func youID(_ db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT id FROM entity WHERE is_you = 1") ?? ""
    }

    // MARK: Load

    struct Loaded {
        var graph: FactsGraph
        /// User rows whose episode selector (theirs or the other endpoint's) matches no episode, or several: To check.
        var toCheck: [String]
        /// fact row id by (predicate, entity id), and back.
        var factIDs: [String: String]
        var factKeys: [String: (predicate: String, entity: String)]
        /// A sendable graph's: the highest sensitivity behind what each entity shows (its roster line, as a typed item).
        var sensitivity: [String: Int] = [:]

        static func key(_ predicate: String, _ entity: String) -> String { predicate + "\u{1F}" + entity }
    }

    /// A dependency on how many facts a predicate has, so a new candidate holder invalidates a decision.
    static func predicateRef(_ predicate: String) -> String { "predicate:" + predicate }

    static func predicateVersion(_ db: Database, _ predicate: String) throws -> String {
        String(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fact WHERE predicate = ? AND tombstone = 0", arguments: [predicate]) ?? 0)
    }

    /// The version a decision dependency is checked against: a memory's version, an entity's or fact's `updated_at`.
    static func currentVersion(_ db: Database, kind: String, ref: String) throws -> String? {
        switch kind {
        case "memory": return try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [ref]).map(String.init)
        case "entity": return try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [ref])
        default:
            if ref.hasPrefix("predicate:") { return try predicateVersion(db, String(ref.dropFirst("predicate:".count))) }
            return try String.fetchOne(db, sql: "SELECT updated_at FROM fact WHERE id = ?", arguments: [ref])
        }
    }

    /// The learned facts as the graph reads them. Counts memory evidence only from active and archived memories at
    /// their current version (an archived memory keeps its former and dated facts, not a current status), plus the
    /// user's own rows; applies manual overrides and corrections on top, so they win over inference.
    /// One memory version's rows in one call group, left out while that group is re-read.
    struct Exclusion {
        var memoryID: String
        var version: Int
        var callGroup: String
        /// What a scoped re-read replaces; nil is the whole reading.
        var scope: FactsScope.Replaced? = nil
        /// What a re-read doesn't replace because the reading wasn't asked it (§11.10): facts of predicates that aren't
        /// recorded now, and the role phrases of those predicates (scalar starts). They keep their earlier rows.
        var keptFacts: Set<String> = []
        var keptStarts: Set<Int> = []

        /// Whether the fact evidence rows of this version and group are left out (but for `keptFacts`').
        var factEvidence: Bool { scope == nil }
        /// Whether a model decision of this version and group (outcome, scalar start, mention) is left out.
        func decision(outcome: String, start: Int?, mention: String?) -> Bool {
            if outcome != "unknown", let start, keptStarts.contains(start) { return false }
            switch scope {
            case nil: return true
            case let r?:
                return outcome == "unknown" ? mention.map { r.names.contains(FactsText.fold($0)) } == true
                    : start.map(r.roles.contains) == true
            }
        }
        /// Whether an alias evidence row of this version and group, at this surface, is left out.
        func alias(surface: String) -> Bool {
            switch scope {
            case nil: return true
            case let r?: return r.names.contains(FactsText.fold(surface))
            }
        }
    }

    /// `sendable`: the graph a cloud call may see under that limit (`FactStore.withheld`): memories above it, and what
    /// rests on them, as if they didn't exist.
    /// `uses`: what's on (§11.10). A predicate whose `recorded` is off has its learned facts left out (the user's own
    /// entries stay), so no roster, code-only link, resolution, reconciliation or reader sees them. Only `apply` reads
    /// every stored row (`.everyDeclared`), so nothing hidden is lost when it writes.
    static func load(_ db: Database, registry: FactsRegistry, userAliases: [String] = [], uses: FactsUses,
                     excluding: Exclusion? = nil, sendable: CloudLimit? = nil) throws -> Loaded {
        var g = FactsGraph(registry: registry, userAliases: userAliases, uses: uses)
        g.idStyle = .uuid
        let all = try countedMemories(db)
        let hidden = try sendable.map { try withheld(db, counted: all, limit: $0) }
        let counted = sendable.map { limit in
            all.filter { Sensitivity(rawValue: $0.value.sensitivity).map(limit.allows) ?? false }
        } ?? all
        func counts(_ memoryID: String?, _ version: Int?) -> Counted? {
            guard let memoryID, let c = counted[memoryID], c.version == version else { return nil }
            return c
        }
        let overrides = try Row.fetchAll(db, sql: "SELECT * FROM manual_override ORDER BY created_at, rowid")
        func decoded(_ s: String?) -> Any? {
            guard let s, let data = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }

        // Entities and their aliases.
        var aliasRows: [String: [Row]] = [:]
        for a in try Row.fetchAll(db, sql: "SELECT * FROM entity_alias ORDER BY rowid") {
            aliasRows[a["entity_id"], default: []].append(a)
        }
        var supported = Set<String>(), trustedSupport = Set<String>()     // alias ids with counting evidence
        for e in try Row.fetchAll(db, sql: "SELECT alias_id, memory_id, memory_version, span_start FROM alias_evidence") {
            guard let c = counts(e["memory_id"], e["memory_version"]) else { continue }
            if let hidden, hidden.names.contains(Withheld.nameKey(e["alias_id"], e["memory_id"], e["memory_version"], e["span_start"])) {
                continue
            }
            supported.insert(e["alias_id"])
            if c.memory.trusted { trustedSupport.insert(e["alias_id"]) }
        }
        var groupEntities = Set<String>()
        // A confirmed alias carries no sensitivity: a cloud call sees it only with sendable evidence.
        let confirmedCounts = hidden == nil
        for e in try Row.fetchAll(db, sql: "SELECT * FROM entity WHERE is_you = 0 ORDER BY rowid") {
            let id: String = e["id"]
            if let hidden, hidden.entities.contains(id) { continue }
            // A tombstone's confirmed alias has no text, only its normalised form: enough to re-attach by.
            let aliases = (aliasRows[id] ?? []).filter { a in
                supported.contains(a["id"] as String) || (a["manual"] as Int) == 1 || ((a["confirmed"] as Int) == 1 && confirmedCounts)
            }.map { ($0["alias"] as String?) ?? ($0["normalized"] as String) }
            let trustedAliases = (aliasRows[id] ?? []).filter { a in
                trustedSupport.contains(a["id"] as String) || (a["manual"] as Int) == 1 || ((a["confirmed"] as Int) == 1 && confirmedCounts)
            }.map { ($0["alias"] as String?) ?? ($0["normalized"] as String) }
            var name: String? = e["name"]
            if let n = name, !aliases.contains(n) { name = aliases.first }
            if name == nil, !aliases.isEmpty { name = aliases.first }
            let gp: String? = e["group_predicate"]
            let group = gp.map { FactsEntity.RoleGroup(predicate: $0, cls: e["group_label"]) }
            if group != nil, name == nil { groupEntities.insert(id) }
            // A group's count and an entity's death come from evidence below; the columns hold the user's values.
            g.insert(FactsEntity(id: id, seq: 0, kind: e["kind"], name: name, aliases: Set(aliases), group: group,
                                 count: nil, deceased: (e["deceased"] as Int) == 1, trustedAliases: Set(trustedAliases)))
        }

        // Facts from their evidence, replayed in the order the memories were written (incarnations: a denial ends one,
        // a later affirmation starts the next, as `FactsGraph.apply` does). The user's rows come last and win.
        var factIDs: [String: String] = [:], factKeys: [String: (predicate: String, entity: String)] = [:]
        let factRows = try Row.fetchAll(db, sql: "SELECT * FROM fact ORDER BY rowid")
        var entityOfFact: [String: String] = [:]
        for f in factRows { entityOfFact[f["id"]] = f["entity_id"] }
        var evidence: [String: [Row]] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT rowid AS rid, * FROM fact_evidence ORDER BY rowid") {
            if let x = excluding, x.factEvidence, (r["memory_id"] as String?) == x.memoryID, (r["memory_version"] as Int?) == x.version,
               (r["call_group"] as String?) == x.callGroup, !x.keptFacts.contains(r["fact_id"]) { continue }
            if let hidden {
                if hidden.userRows.contains(r["id"]) { continue }
                if let mid: String = r["memory_id"], hidden.statements.contains(mid + "|" + (r["fact_id"] as String)) { continue }
            }
            evidence[r["fact_id"], default: []].append(r)
        }
        let rejectedEverywhere = Set(overrides.filter {
            ($0["target_kind"] as String) == "fact" && ($0["field"] as String) == "rejected" && ($0["memory_id"] as String?) == nil
        }.map { $0["target_id"] as String })
        var rejectedFromMemory: [String: Set<String>] = [:]      // fact id → memories whose evidence for it is rejected
        for o in overrides where (o["target_kind"] as String) == "fact" && (o["field"] as String) == "rejected" {
            guard let mid: String = o["memory_id"], let c = counted[mid],
                  locate(o["quote"], in: c.memory.text, near: nil) != nil else { continue }
            rejectedFromMemory[o["target_id"], default: []].insert(mid)
        }
        var toCheck: [String] = []
        var deceasedByEvidence = Set<String>()
        for f in factRows {
            let fid: String = f["id"], pred: String = f["predicate"], ent: String = f["entity_id"]
            guard g.entities[ent] != nil, !rejectedEverywhere.contains(fid), hidden?.facts.contains(fid) != true else { continue }
            let manual = (f["manual"] as Int) == 1
            // Counting rows in the order their memories were written; the user's rows after them.
            let rows = (evidence[fid] ?? []).compactMap { r -> (Row, Counted?)? in
                if (r["source"] as String) == "user" { return (r, nil) }
                guard let c = counts(r["memory_id"], r["memory_version"]),
                      rejectedFromMemory[fid]?.contains(c.memory.id) != true else { return nil }
                return (r, c)
            }.stableSorted { pair -> String in
                guard let c = pair.1 else { return "~" }
                return c.memory.written + String(format: "%012d", c.seq)
            }
            // A role group: its count is the latest counting memory's, and it's not a fact the timeline reads.
            if groupEntities.contains(ent) {        // only trusted memories set a count
                guard uses.isOn(pred, .recorded) else { continue }      // §11.10: hidden with its predicate
                for (r, c) in rows where (r["target_kind"] as String) == "fact" && (c?.memory.trusted ?? true) {
                    if let n = object(r["asserted"])["count"] as? Int { g.entities[ent]?.count = n }
                }
                continue
            }
            factIDs[Loaded.key(pred, ent)] = fid
            factKeys[fid] = (pred, ent)
            // One assertion per memory (or user row): its fact row, with its qualifiers and order edges.
            struct Pending { var a: FactAssertion; var denied: Bool; var only: Bool }
            var order: [String] = [], pending: [String: Pending] = [:]
            for (r, c) in rows {
                let src: String = r["source"]
                // One assertion per statement: a memory's rows carry its ordinal ("n"), so two statements stay two.
                let n = object(r["asserted"])["n"] as? Int ?? 0
                let key = c.map { "m:" + $0.memory.id + ":" + String(n) } ?? "u:" + (r["id"] as String)
                if pending[key] == nil {
                    order.append(key)
                    // A user row keeps the day the user entered it, never the day it's read.
                    let userDay = object(r["asserted"])["written"] as? String ?? "1970-01-01"
                    var a = FactAssertion(memoryID: c?.memory.id ?? "user", trusted: c?.memory.trusted ?? true,
                                          written: c?.memory.written ?? userDay, status: .unknown,
                                          qualifiers: [:], states: true, quote: r["quote"] ?? "", handover: false)
                    a.readOrder = c.map { "0" + $0.memory.written + String(format: "%012d", $0.seq) + String(format: "%06d", n) }
                        ?? "1" + String(format: "%015lld", r["rid"] as Int64)
                    pending[key] = Pending(a: a, denied: false, only: false)
                }
                var p = pending[key]!
                let asserted = object(r["asserted"])
                switch r["target_kind"] as String {
                case "fact":
                    if (r["polarity"] as String) == "denied" { p.denied = true }
                    p.a.status = (asserted["status"] as? String).flatMap(FactAssertion.Status.init) ?? .unknown
                    p.a.start = asserted["start"] as? String
                    p.a.end = asserted["end"] as? String
                    p.a.time = asserted["time"] as? String
                    p.a.handover = false            // derived below, from what was known when it was written
                    p.only = asserted["only"] as? Bool ?? false
                    p.a.only = p.only
                    p.a.states = (r["states"] as Int) == 1
                    if let c, c.status == "archived", p.a.status == .current {
                        p.a.status = .unknown        // an archived memory keeps its former and dated facts only
                    }
                case "qualifier":
                    if let q: String = r["qualifier"], let v = asserted["value"] as? String {
                        if q == "label" { p.a.label = v }
                        else if q == "deceased" {
                            p.a.deceased = v == "true"
                            // Only what a recorded predicate's evidence says (§11.10).
                            if v == "true", c?.memory.trusted == true, uses.isOn(pred, .recorded) { deceasedByEvidence.insert(ent) }
                        }
                        else { p.a.qualifiers[q] = v }
                    }
                case "order":
                    let before = (r["direction"] as String?) == "preceded_by"
                    let other = (r["other_fact_id"] as String?).flatMap { entityOfFact[$0] }
                    let name = asserted["value"] as? String
                    if before { p.a.precededBy = name; p.a.precededByEntity = other } else { p.a.followedBy = name; p.a.followedByEntity = other }
                    if src == "user" { p.a.otherSelector = selector(r["other_episode_selector"]) }
                default: break
                }
                if src == "user" {
                    p.a.fromUser = true
                    p.a.selector = selector(r["episode_selector"])
                }
                pending[key] = p
            }
            var incarnations: [LearnedFact] = []
            for key in order {
                let p = pending[key]!
                if p.denied {
                    // A denial from a memory never negates what the user entered (manual entries win over inference).
                    if let last = incarnations.indices.last, !incarnations[last].negated, !manual,
                       p.a.trusted || !incarnations[last].trusted {
                        incarnations[last].negated = true
                    }
                    continue
                }
                if incarnations.last == nil || incarnations.last!.negated {
                    incarnations.append(LearnedFact(entity: ent, predicate: pred, label: nil, cls: nil, only: false,
                                                    negated: false, assertions: []))
                }
                let i = incarnations.count - 1
                incarnations[i].only = incarnations[i].only || (p.only && p.a.trusted)
                incarnations[i].assertions.append(p.a)
            }
            for i in incarnations.indices {          // the user's label, else a trusted one (as `FactsGraph.apply`)
                let l = g.effectiveLabel(incarnations[i])
                incarnations[i].label = l
                incarnations[i].cls = g.labelClass(pred, l)
            }
            g.facts += incarnations
        }
        for e in deceasedByEvidence { g.entities[e]?.deceased = true }
        // Hand-overs, derived rather than stored: a fact's first statement, undated and not former, of an exclusive or
        // succession predicate, when another holder's (trusted, for a trusted statement) evidence was written before.
        let seqOf: [String: Int] = counted.mapValues(\.seq)
        func before(_ a: FactAssertion, _ b: FactAssertion) -> Bool {     // written order; memory order on the same day
            a.written != b.written ? a.written < b.written : (seqOf[a.memoryID] ?? 0) < (seqOf[b.memoryID] ?? 0)
        }
        for i in g.facts.indices {
            // The first trusted statement (an earlier untrusted one doesn't take its place), else the first of an
            // untrusted-only fact.
            let memoryRows = g.facts[i].assertions.indices.filter { !g.facts[i].assertions[$0].fromUser }
            guard let p = registry.predicate(g.facts[i].predicate), p.exclusive || p.succession,
                  let fi = memoryRows.first(where: { g.facts[i].assertions[$0].trusted }) ?? memoryRows.first else { continue }
            let first = g.facts[i].assertions[fi]
            guard first.start == nil, first.end == nil, first.time == nil, first.status != .former else { continue }
            let earlier = g.facts.contains { o in
                o.predicate == g.facts[i].predicate && o.entity != g.facts[i].entity && !o.negated
                    && o.assertions.contains { a in (a.trusted || !first.trusted) && !a.fromUser && before(a, first) }
            }
            if earlier { g.facts[i].assertions[fi].handover = true }
        }

        // Overrides win: names, deceased, labels, merges.
        var mergedInto: [String: String] = [:]
        // Merges first, so every other correction (a label, a rejection) applies to the merged entity and fact.
        let ordered = overrides.filter { ($0["field"] as String) == "merged_into" } + overrides.filter { ($0["field"] as String) != "merged_into" }
        func canonicalEntity(_ id: String) -> String {
            var id = id, hops = 0
            while let next = mergedInto[id], hops < 16 { id = next; hops += 1 }
            return id
        }
        for o in ordered {
            let kind: String = o["target_kind"], field: String = o["field"]
            // An entity's correction follows its merge (applied first) to the surviving entity.
            let target: String = kind == "entity" && field != "merged_into" ? canonicalEntity(o["target_id"]) : o["target_id"]
            // A correction made from a memory holds while that memory and its quoted span do.
            if let mid: String = o["memory_id"] {
                guard let c = counted[mid], locate(o["quote"], in: c.memory.text, near: nil) != nil else { continue }
            }
            let value = decoded(o["value"])
            switch (kind, field) {
            case ("entity", "name"):
                if let n = value as? String, g.entities[target] != nil {
                    // A merged-away entity's name is one more alias of the survivor, not its new name.
                    if target == (o["target_id"] as String) { g.entities[target]?.name = n }
                    g.addAlias(target, n, trusted: true)
                }
            case ("entity", "not_same"):
                if let other = value as? String { g.notSame.insert([target, canonicalEntity(other)]) }
            case ("entity", "deceased"):
                if let b = value as? Bool { g.entities[target]?.deceased = b }
            case ("entity", "merged_into"):
                // Merge With…: one entity, and one fact per predicate, its evidence fused.
                if let into = value as? String { mergedInto[target] = into }
                if let into = value as? String, let from = g.entities[target], g.entities[into] != nil, into != target {
                    g.entities[into]?.aliases.formUnion(from.aliases)
                    g.entities[into]?.trustedAliases.formUnion(from.trustedAliases)
                    let dead = (g.entities[into]?.deceased ?? false) || from.deceased
                    g.entities[into]?.deceased = dead
                    for i in g.facts.indices where g.facts[i].entity == target {
                        if let j = g.facts.indices.last(where: { g.facts[$0].entity == into && g.facts[$0].predicate == g.facts[i].predicate
                                                                && !g.facts[$0].negated }), !g.facts[i].negated {
                            // Fused in the order facts are read, so the latest statement (and the user's latest row)
                            // stays the latest.
                            g.facts[j].assertions = (g.facts[j].assertions + g.facts[i].assertions).stableSorted { $0.readOrder }
                            g.facts[j].only = g.facts[j].only || g.facts[i].only
                            if g.facts[j].label == nil { g.facts[j].label = g.facts[i].label; g.facts[j].cls = g.facts[i].cls }
                            g.facts[i].negated = true          // folded into the survivor's fact
                            g.facts[i].assertions = []
                        }
                        g.facts[i].entity = into
                    }
                    g.facts.removeAll { $0.entity == into && $0.negated && $0.assertions.isEmpty }
                    // The merged fact's label from all its evidence, the user's first.
                    for j in g.facts.indices where g.facts[j].entity == into { g.refreshLabel(j) }
                    for (fid, key) in factKeys where key.entity == target {
                        factKeys[fid] = (key.predicate, into)
                        factIDs[Loaded.key(key.predicate, into)] = factIDs[Loaded.key(key.predicate, into)] ?? fid
                    }
                    g.entities[target] = nil
                }
            case ("order", "rejected"):
                // The edge itself is in the value (its endpoints' fact ids and episode selectors), so it outlives the
                // evidence that stated it.
                if let v = value as? [String: Any], let b = v["before"] as? String, let a = v["after"] as? String,
                   let be = factKeys[b]?.entity ?? entityOfFact[b], let ae = factKeys[a]?.entity ?? entityOfFact[a] {
                    func sel(_ k: String) -> DateRange? {
                        guard let o = v[k] as? [String: Any], let lo = o["lo"] as? Int, let hi = o["hi"] as? Int else { return nil }
                        return DateRange(lo: lo, hi: hi)
                    }
                    g.rejectedEdges.append(FactsGraph.EdgeRejection(from: be, to: ae, fromSelector: sel("before_selector"),
                                                                    toSelector: sel("after_selector")))
                }
            case ("qualifier", "label"):
                if let (pred, ent) = factKeys[target], let l = value as? String {
                    for i in g.facts.indices where g.facts[i].predicate == pred && g.facts[i].entity == ent {
                        g.facts[i].label = l
                        g.facts[i].cls = g.labelClass(pred, l)
                    }
                }
            default: break
            }
        }

        // Order endpoints follow merges too: rejected edges and the user's edges name the surviving entity.
        func canonical(_ id: String) -> String {
            var id = id, hops = 0
            while let next = mergedInto[id], hops < 16 { id = next; hops += 1 }
            return id
        }
        if !mergedInto.isEmpty {
            g.rejectedEdges = g.rejectedEdges.map { r in
                var r = r
                r.from = canonical(r.from)
                r.to = canonical(r.to)
                return r
            }
            for i in g.facts.indices {
                for k in g.facts[i].assertions.indices {
                    if let p = g.facts[i].assertions[k].precededByEntity { g.facts[i].assertions[k].precededByEntity = canonical(p) }
                    if let f = g.facts[i].assertions[k].followedByEntity { g.facts[i].assertions[k].followedByEntity = canonical(f) }
                }
            }
        }
        // User rows whose selector matches no episode, or several, go to To check and don't apply; so do user order
        // edges whose other endpoint's selector doesn't pick exactly one episode.
        func overlapping(_ eps: [Episode], _ sel: DateRange) -> Int {
            eps.filter { e in (e.start?.lo ?? DateRange.minDay) <= sel.hi && sel.lo <= (e.end?.hi ?? DateRange.maxDay) }.count
        }
        let plainEpisodes: [String: [Episode]] = {
            var out: [String: [Episode]] = [:]
            for f in g.facts where !f.negated {
                var plain = f
                plain.assertions.removeAll { $0.fromUser && $0.selector != nil }
                out[FactStore.Loaded.key(f.predicate, f.entity), default: []] += g.factEpisodes(plain)
            }
            return out
        }()
        for i in g.facts.indices {
            let eps = plainEpisodes[Loaded.key(g.facts[i].predicate, g.facts[i].entity)] ?? []
            let pred = g.facts[i].predicate
            g.facts[i].assertions.removeAll { a in
                guard a.fromUser else { return false }
                if let sel = a.selector, overlapping(eps, sel) != 1 { toCheck.append(a.quote); return true }
                for other in [a.precededByEntity, a.followedByEntity].compactMap({ $0 }) {
                    if let sel = a.otherSelector, overlapping(plainEpisodes[Loaded.key(pred, other)] ?? [], sel) != 1 {
                        toCheck.append(a.quote)
                        return true
                    }
                }
                return false
            }
        }

        // Decisions: the model's at the memory's current version whose dependencies are unchanged, and the user's,
        // keyed to the quote.
        var dependencies: [String: [Row]] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT * FROM decision_dependency") { dependencies[r["decision_id"], default: []].append(r) }
        for d in try Row.fetchAll(db, sql: "SELECT * FROM mention_decision ORDER BY created_at, rowid") {
            let mid: String = d["memory_id"], src: String = d["source"], outcome: String = d["outcome"]
            guard let c = counted[mid], hidden?.decisions.contains(d["id"]) != true else { continue }
            if src == "model" {
                if let x = excluding, mid == x.memoryID, (d["call_group"] as String?) == x.callGroup,
                   x.decision(outcome: outcome, start: d["span_start"], mention: d["mention"]) { continue }
                if (d["memory_version"] as Int?) != c.version || (d["invalidated_at"] as Date?) != nil { continue }
                let stale = try (dependencies[d["id"]] ?? []).contains { dep in
                    try currentVersion(db, kind: dep["kind"], ref: dep["ref_id"]) != (dep["ref_version"] as String)
                }
                if stale { continue }
            }
            guard let span = locate(d["quote"], in: c.memory.text, near: d["span_start"]) else { continue }
            let key = FactsGraph.DecisionKey(memoryID: mid, start: span.start)
            // A correction about an entity merged away is about the one it was merged into (following the chain).
            var entity: String? = d["entity_id"]
            var hops = 0
            while let e = entity, let next = mergedInto[e], hops < 16 { entity = next; hops += 1 }
            switch outcome {
            case "rejected":
                if let entity { g.rejections[key, default: []].insert(entity) }
            case "someone_else":
                g.decisions[key] = MentionDecision(entity: nil, basis: .someoneElse)
            case "entity", "group":
                guard let entity, g.entities[entity] != nil else { continue }
                let basis = src == "user" ? LinkBasis.confirmed : (LinkBasis(rawValue: d["basis"]) ?? .context)
                g.decisions[key] = MentionDecision(entity: entity, basis: basis)
            default: break
            }
        }

        // Name links (memory processing §11.4): the people a memory names, from its alias evidence at its current
        // version, and the names the model left ambiguous. A one-word name that several trusted people now share reads
        // as ambiguous until the memory is read again: a reading from before the newest namesake existed.
        var readAt: [FactsGraph.NameKey: Date] = [:]
        var knownSince: [String: Date] = [:]           // entity + normalised alias → its first trusted reading
        for r in try Row.fetchAll(db, sql: """
            SELECT ev.memory_id, ev.memory_version, ev.span_start, ev.span_end, ev.call_group, ev.source, ev.read_at, ev.first_read_at, ev.trust,
              a.entity_id, a.normalized, ev.alias_id
            FROM alias_evidence ev JOIN entity_alias a ON a.id = ev.alias_id JOIN entity e ON e.id = a.entity_id
            WHERE e.kind = ? AND e.is_you = 0 ORDER BY ev.rowid
            """, arguments: [FactsValidator.personKind]) {
            guard let c = counts(r["memory_id"], r["memory_version"]) else { continue }
            if let hidden, hidden.names.contains(Withheld.nameKey(r["alias_id"], r["memory_id"], r["memory_version"], r["span_start"])) {
                continue
            }
            // When each person first had each name from trusted text: a reading before that didn't know them by it.
            if (r["trust"] as String) == "trusted", let at: Date = r["first_read_at"] ?? r["read_at"] {
                let k = canonicalEntity(r["entity_id"]) + "\u{1F}" + (r["normalized"] as String)
                knownSince[k] = min(knownSince[k] ?? at, at)
            }
            let a = utf16Offset(c.memory.text, scalar: r["span_start"]), b = utf16Offset(c.memory.text, scalar: r["span_end"])
            if let x = excluding, c.memory.id == x.memoryID, (r["call_group"] as String) == x.callGroup,
               x.alias(surface: b > a ? FactsText.substring(c.memory.text, a, b) : "") {
                if b > a, (r["source"] as String) == "model" {
                    g.reread[FactsText.fold(FactsText.substring(c.memory.text, a, b))] = canonicalEntity(r["entity_id"])
                }
                continue
            }
            guard b > a else { continue }
            let surface = FactsText.substring(c.memory.text, a, b)
            let entity = canonicalEntity(r["entity_id"])
            guard g.entities[entity] != nil else { continue }
            let key = FactsGraph.NameKey(memoryID: c.memory.id, surface: surface)
            if (r["source"] as String) == "code" {
                guard g.names[key] == nil else { continue }       // a model's reading of the same name wins
                g.codeNames.insert(key)
            } else {
                g.codeNames.remove(key)
            }
            g.names[key] = NameLink(entity: entity, basis: c.memory.trusted ? .named : .untrusted, candidates: [])
            readAt[key] = r["read_at"]
        }
        for d in try Row.fetchAll(db, sql: """
            SELECT id, memory_id, memory_version, mention, call_group FROM mention_decision
            WHERE source = 'model' AND outcome = 'unknown' AND basis = ? ORDER BY created_at, rowid
            """, arguments: [LinkBasis.ambiguous.rawValue]) {
            guard let c = counts(d["memory_id"], d["memory_version"]), let name: String = d["mention"],
                  hidden?.decisions.contains(d["id"]) != true else { continue }
            if let x = excluding, c.memory.id == x.memoryID, (d["call_group"] as String?) == x.callGroup,
               x.decision(outcome: "unknown", start: nil, mention: name) { continue }
            g.names[FactsGraph.NameKey(memoryID: c.memory.id, surface: name)] =
                NameLink(entity: nil, basis: .ambiguous, candidates: g.byName(name, onlyTrusted: c.memory.trusted).map(\.id))
        }
        // A confirmed or typed alias counts from when the user gave it.
        for rows in aliasRows.values {
            for a in rows where (a["confirmed"] as Int) == 1 || (a["manual"] as Int) == 1 {
                guard let at: Date = a["confirmed_at"] else { continue }
                let k = canonicalEntity(a["entity_id"]) + "\u{1F}" + (a["normalized"] as String)
                knownSince[k] = min(knownSince[k] ?? at, at)
            }
        }
        // A namesake with no dated alias behind it counts from when it was created.
        var createdAt: [String: Date] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT id, created_at FROM entity") { createdAt[r["id"]] = r["created_at"] }
        for (key, link) in g.names where link.basis == .named || link.basis == .untrusted {
            guard let e = link.entity, let ent = g.entities[e], FactsText.fold(key.surface).split(separator: " ").count == 1 else { continue }
            let sharing = g.byName(key.surface, kind: ent.kind, onlyTrusted: true).map(\.id)
            guard sharing.count > 1 || (sharing.count == 1 && sharing[0] != e) else { continue }
            let surface = FactsText.normName(key.surface, kind: ent.kind, registry: registry)
            // When the newest namesake came to share this name: its first trusted reading of an alias with it.
            let since = sharing.filter { $0 != e }.map { other -> Date in
                let forms = (g.entities[other]?.trustedAliases ?? []).filter { a in
                    let n = FactsText.normName(a, kind: ent.kind, registry: registry)
                    return n == surface || n.split(separator: " ").first.map(String.init) == surface
                }
                let times = forms.compactMap { knownSince[other + "\u{1F}" + FactsText.normName($0, kind: ent.kind, registry: registry)] }
                return times.min() ?? createdAt[other] ?? .distantFuture
            }.max()
            if let read = readAt[key], let since, read > since { continue }       // read knowing the namesake
            g.names[key] = NameLink(entity: nil, basis: .ambiguous, candidates: Array(Set(sharing + [e])).sorted())
        }

        for c in counted.values {
            g.memories[c.memory.id] = c.memory
            g.memoryOrder[c.memory.id] = c.seq
        }
        if uses.hidesRecorded { g.hideUnrecorded() }
        return Loaded(graph: g, toCheck: toCheck, factIDs: factIDs, factKeys: factKeys, sensitivity: hidden?.sensitivity ?? [:])
    }

    // MARK: Apply one memory's extraction

    enum ApplyError: Error, Equatable {
        case memoryChanged          // the memory isn't at the version the call read
        case rosterChanged          // a roster entry the call used has changed since
    }

    struct ApplyResult: Equatable {
        var entities = 0
        var facts = 0
        var evidence = 0
        var decisions = 0
        /// "Also called" naming two entities: merge suggestions for To check.
        var mergeSuggestions = 0
        /// Names the model left ambiguous between known people.
        var ambiguousNames = 0
    }

    /// A fact's evidence for one memory version and call group, as a comparable set.
    private static func signatures(_ db: Database, memoryID: String, version: Int, callGroup: String) throws -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT fact_id, target_kind, qualifier, direction, asserted, polarity, states FROM fact_evidence
            WHERE memory_id = ? AND memory_version = ? AND call_group = ?
            """, arguments: [memoryID, version, callGroup]) {
            let kind: String = r["target_kind"], qualifier: String = r["qualifier"] ?? "", direction: String = r["direction"] ?? ""
            let asserted: String = r["asserted"], polarity: String = r["polarity"], states: Int = r["states"]
            let sig = [kind, qualifier, direction, asserted, polarity, String(states)].joined(separator: "\u{1F}")
            out[r["fact_id"], default: []].insert(sig)
        }
        return out
    }

    /// Writes one memory version's extraction for one call group, in the caller's transaction: earlier evidence of
    /// that version and group is replaced, so a re-read is idempotent, and one that changes nothing touches nothing.
    /// A partial scope (reconciliation) replaces only the role phrases the answer decided and the names it re-asked;
    /// everything else the earlier reading found stays. Records what the reading was asked knowing (`facts_asked`).
    /// Fails if the memory or a roster entry changed.
    @discardableResult
    static func apply(_ db: Database, memoryID: String, version: Int, extraction original: FactsExtraction, callGroup: String,
                      runID: String? = nil, registry: FactsRegistry, userAliases: [String] = [], uses: FactsUses,
                      now: Date = Date(), readAt: Date? = nil, sendable: CloudLimit? = nil) throws -> ApplyResult {
        guard let m = try Row.fetchOne(db, sql: "SELECT * FROM memory WHERE id = ?", arguments: [memoryID]),
              (m["version"] as Int) == version, (m["status"] as String) != "deleted" else {
            throw ApplyError.memoryChanged
        }
        for (id, updated) in original.roster {
            let now = try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [id])
            if now != updated { throw ApplyError.rosterChanged }
        }
        for (predicate, version) in original.predicateVersions where try predicateVersion(db, predicate) != version {
            throw ApplyError.rosterChanged
        }
        // A partial answer for a version the model hasn't read in this group (it was edited since the job planned) is
        // applied whole: the call asked everything, as every Facts call does.
        var original = original
        if case .partial = original.scope, try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS (SELECT 1 FROM facts_asked WHERE memory_id = ? AND memory_version = ? AND call_group = ? AND mention_kind = 'read')
            """, arguments: [memoryID, version, callGroup]) == true {
            original.scope = .full
        }
        // The phrases the call was asked about: those of the group's recorded predicates (its answer's indices).
        let preds = Set(uses.predicates(.recorded, group: callGroup))
        let text = text(title: m["title"], body: m["body"])
        let created: Date = m["created_at"]
        let trusted = (m["trust"] as String) == "trusted"
        let sensitivity: Int = m["sensitivity"]
        let fm = FactsMemory(id: memoryID, text: text, written: writtenDay(created),
                             source: source((m["original_source"] as String?) ?? m["source"]), trusted: trusted)
        let trust = trusted ? "trusted" : "untrusted"
        let phrases = FactsGraph(registry: registry, userAliases: userAliases, uses: uses).rolePhrases(text, predicates: preds)

        // A partial re-read keeps only what it re-asked: the role phrases it asked about that the answer decided (an
        // answer validation dropped leaves the earlier decision), and the names it re-asked.
        var x = original
        var replaced: FactsScope.Replaced?
        if case let .partial(roles, names) = original.scope {
            func scalarStart(_ i: Int) -> Int? { phrases.indices.contains(i) ? scalarOffset(text, utf16: phrases[i].start) : nil }
            x.facts = []
            x.things = []
            x.roles = original.roles.filter { scalarStart($0.phrase).map(roles.contains) ?? false }
            x.people = original.people.filter { names.contains(FactsText.fold($0.name)) }
            replaced = .init(roles: Set(x.roles.compactMap { scalarStart($0.phrase) }), names: Set(x.people.map { FactsText.fold($0.name) }))
        }
        var exclusion = Exclusion(memoryID: memoryID, version: version, callGroup: callGroup, scope: replaced)
        // What this reading wasn't asked (§11.10): the group's predicates that aren't recorded keep their earlier rows,
        // facts and role decisions, so turning *recorded* off hides them without a re-read losing them.
        let unasked = Set(registry.groupPredicates(callGroup)).subtracting(preds)
        if !unasked.isEmpty {
            let marks = Array(repeating: "?", count: unasked.count).joined(separator: ",")
            exclusion.keptFacts = Set(try String.fetchAll(db, sql: "SELECT id FROM fact WHERE predicate IN (\(marks))",
                                                          arguments: StatementArguments(Array(unasked))))
            exclusion.keptStarts = Set(FactsGraph(registry: registry, userAliases: userAliases, uses: .everyDeclared(registry))
                .rolePhrases(text, predicates: unasked).map { scalarOffset(text, utf16: $0.start) })
        }
        // The graph without the rows being replaced (its names stay matchable, so a re-read finds them).
        let stored = FactsUses.everyDeclared(registry)
        var before = try load(db, registry: registry, userAliases: userAliases, uses: stored, excluding: exclusion).graph
        if let r = replaced, !r.names.isEmpty {
            // A re-asked name the answer resolves differently from the earlier reading (someone else, or ambiguous where
            // it named someone, or someone where it was ambiguous): the facts this memory states about that name rest on
            // who it is, so the reading is replaced whole, and only if validation dropped nothing; otherwise that name
            // keeps its earlier rows.
            var probe = before
            probe.apply(fm, people: x.people, roster: Set(x.roster.keys))
            let moved = Set(x.people.compactMap { p -> String? in
                let f = FactsText.fold(p.name)
                guard let link = probe.names[FactsGraph.NameKey(memoryID: memoryID, surface: p.name)] else { return nil }
                return link.entity == before.reread[f] ? nil : f
            })
            if !moved.isEmpty {
                if original.clean {
                    var whole = original
                    whole.scope = .full
                    return try apply(db, memoryID: memoryID, version: version, extraction: whole, callGroup: callGroup, runID: runID,
                                     registry: registry, userAliases: userAliases, uses: uses, now: now, readAt: readAt,
                                     sendable: sendable)
                }
                x.people.removeAll { moved.contains(FactsText.fold($0.name)) }
                replaced?.names.subtract(moved)
                exclusion.scope = replaced
                before = try load(db, registry: registry, userAliases: userAliases, uses: stored, excluding: exclusion).graph
            }
        }

        // What this version and group said before, to replace it and to tell what changed.
        let oldSignatures = try signatures(db, memoryID: memoryID, version: version, callGroup: callGroup)
        // A hand-over is decided when a memory is first read: a re-read keeps it (holders learned since don't make
        // this one "new").
        var oldHandover: [String: Bool] = [:]        // by fact id and statement ordinal
        for r in try Row.fetchAll(db, sql: """
            SELECT fact_id, asserted FROM fact_evidence WHERE memory_id = ? AND memory_version = ? AND call_group = ?
              AND target_kind = 'fact' AND polarity = 'affirmed'
            """, arguments: [memoryID, version, callGroup]) {
            let o = object(r["asserted"])
            oldHandover[(r["fact_id"] as String) + ":" + String(o["n"] as? Int ?? 0)] = o["handover"] as? Bool ?? false
        }
        // This group's alias evidence for this version that is being replaced (another group's, or code's, is its own).
        // A model's whole reading also retires code-only links of this version and group.
        let oldAliasRows = try Row.fetchAll(db, sql: """
            SELECT ev.alias_id, a.entity_id, ev.first_read_at, ev.span_start, ev.span_end FROM alias_evidence ev
            JOIN entity_alias a ON a.id = ev.alias_id
            WHERE ev.memory_id = ? AND ev.memory_version = ? AND ev.call_group = ?
            """, arguments: [memoryID, version, callGroup]).filter { r in
            let a = utf16Offset(text, scalar: r["span_start"]), b = utf16Offset(text, scalar: r["span_end"])
            return exclusion.alias(surface: b > a ? FactsText.substring(text, a, b) : "")
        }
        // When this version first gave each alias: a re-read doesn't make a name newer than it is.
        var firstRead: [String: Date] = [:]
        for r in oldAliasRows { if let d: Date = r["first_read_at"] { firstRead[r["alias_id"]] = min(firstRead[r["alias_id"]] ?? d, d) } }
        let oldAliases = Set(oldAliasRows.map { $0["alias_id"] as String })
        let affected = try supportedBy(db, memoryIDs: [memoryID])
        for r in oldAliasRows {
            try db.execute(sql: """
                DELETE FROM alias_evidence WHERE alias_id = ? AND memory_id = ? AND memory_version = ? AND call_group = ? AND span_start = ?
                """, arguments: [r["alias_id"] as String, memoryID, version, callGroup, r["span_start"] as Int])
        }
        if exclusion.factEvidence {
            let kept = exclusion.keptFacts.sorted()
            let marks = Array(repeating: "?", count: kept.count).joined(separator: ",")
            let args: [any DatabaseValueConvertible] = [memoryID, version, callGroup] + kept.map { $0 as any DatabaseValueConvertible }
            try db.execute(sql: "DELETE FROM fact_evidence WHERE memory_id = ? AND memory_version = ? AND call_group = ?"
                               + (kept.isEmpty ? "" : " AND fact_id NOT IN (\(marks))"),
                           arguments: StatementArguments(args))
        }
        let oldDecisions = try Row.fetchAll(db, sql: """
            SELECT id, mention, outcome, basis, span_start FROM mention_decision
            WHERE memory_id = ? AND memory_version = ? AND call_group = ? AND source = 'model'
            """, arguments: [memoryID, version, callGroup]).filter {
            exclusion.decision(outcome: $0["outcome"], start: $0["span_start"], mention: $0["mention"])
        }
        let oldAmbiguous = Set(oldDecisions.compactMap { d -> String? in
            (d["outcome"] as String) == "unknown" && (d["basis"] as String) == LinkBasis.ambiguous.rawValue ? d["mention"] : nil
        })
        for d in oldDecisions { try db.execute(sql: "DELETE FROM mention_decision WHERE id = ?", arguments: [d["id"] as String]) }

        var g = before
        let groupFacts = x.facts.filter { preds.contains($0.predicate) }
        // A partial re-read's `name:` answers resolve through the names this memory's reading already has.
        var knownNames: [String: String] = [:]
        if replaced != nil {
            for (key, link) in before.names where key.memoryID == memoryID { if let e = link.entity { knownNames[FactsText.fold(key.surface)] = e } }
        }
        g.apply(fm, phrases: phrases, people: x.people, facts: groupFacts, roles: x.roles, roster: Set(x.roster.keys),
                knownNames: knownNames)
        // Named things: entities of their kind, matched by its rule (an organization the work call also names is one).
        let thingIDs = x.things.map { g.entityFor($0.name, kind: $0.kind, trusted: trusted) }
        var result = ApplyResult(mergeSuggestions: g.mergeSuggestions.count)
        var touchedEntities = Set<String>(), newAliases = Set<String>()
        var pendingDependencies: [(String, String, Set<String>)] = []
        var pendingAmbiguous: [(String, [String])] = []

        // New entities, and names learned for unnamed ones.
        for e in g.orderedEntities where before.entities[e.id] == nil {
            try db.execute(sql: """
                INSERT INTO entity (id, kind, name, group_predicate, group_label, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [e.id, e.kind, e.name, e.group?.predicate, e.group?.cls, now, now])
            result.entities += 1
        }
        for e in g.entities.values {
            guard let old = before.entities[e.id], old.name == nil, let n = e.name else { continue }
            try db.execute(sql: "UPDATE entity SET name = ?, tombstone = 0 WHERE id = ?", arguments: [n, e.id])
            touchedEntities.insert(e.id)
        }

        // Aliases with this memory's evidence: names the memory used, and non-person objects' names.
        func addAlias(_ entity: String, _ alias: String, quote: String, span quoteSpan: NSRange? = nil) throws {
            guard let kind = g.entities[entity]?.kind else { return }
            let norm = FactsText.normName(alias, kind: kind, registry: registry)
            let aid = try String.fetchOne(db, sql: "SELECT id FROM entity_alias WHERE entity_id = ? AND normalized = ? ORDER BY rowid",
                                          arguments: [entity, norm]) ?? {
                let id = UUID().db
                try db.execute(sql: "INSERT INTO entity_alias (id, entity_id, alias, normalized) VALUES (?, ?, ?, ?)",
                               arguments: [id, entity, alias, norm])
                return id
            }()
            try db.execute(sql: "UPDATE entity_alias SET alias = COALESCE(alias, ?) WHERE id = ?", arguments: [alias, aid])
            // The name inside its quote's span when validation found the quote; else the first place it's written.
            let span = quoteSpan.flatMap { q -> (start: Int, end: Int)? in
                FactsSentText.findWord(alias, in: text, within: q).map { (start: $0.location, end: $0.location + $0.length) }
                    ?? (start: q.location, end: q.location + q.length)
            } ?? locate(alias, in: text, near: nil) ?? locate(quote, in: text, near: nil) ?? (start: 0, end: 0)
            try db.execute(sql: """
                INSERT OR REPLACE INTO alias_evidence (alias_id, memory_id, memory_version, span_start, span_end, quote, sensitivity, trust,
                  run_id, call_group, source, read_at, first_read_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'model', ?, ?)
                """, arguments: [aid, memoryID, version, scalarOffset(text, utf16: span.start), scalarOffset(text, utf16: span.end),
                                 quote, sensitivity, trust, runID, callGroup, readAt ?? now, firstRead[aid] ?? now])
            if try Int.fetchOne(db, sql: "SELECT tombstone FROM entity WHERE id = ?", arguments: [entity]) == 1 {
                try db.execute(sql: "UPDATE entity SET tombstone = 0 WHERE id = ?", arguments: [entity])
                touchedEntities.insert(entity)
            }
            newAliases.insert(aid)
            if !oldAliases.contains(aid) { touchedEntities.insert(entity) }
        }
        for p in x.people {
            if let link = g.names[FactsGraph.NameKey(memoryID: memoryID, surface: p.name)], let e = link.entity {
                try addAlias(e, p.name, quote: p.quote, span: p.span)
            }
        }
        for (t, id) in zip(x.things, thingIDs) { try addAlias(id, t.name, quote: t.quote, span: t.span) }

        // Facts: only the assertions this apply added, and the denials it made.
        var newFacts = Set<String>()
        var ordinal: [String: Int] = [:]
        func factID(_ pred: String, _ entity: String) throws -> String {
            if let id = try String.fetchOne(db, sql: "SELECT id FROM fact WHERE predicate = ? AND entity_id = ?", arguments: [pred, entity]) {
                try db.execute(sql: "UPDATE fact SET tombstone = 0 WHERE id = ?", arguments: [id])
                return id
            }
            let id = UUID().db
            try db.execute(sql: "INSERT INTO fact (id, predicate, entity_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                           arguments: [id, pred, entity, now, now])
            result.facts += 1
            newFacts.insert(id)
            return id
        }
        func evidenceRow(_ fid: String, kind: String, qualifier: String? = nil, direction: String? = nil,
                         asserted: [String: Any], states: Bool, polarity: String, quote: String, span known: NSRange? = nil) throws {
            let span = known.map { (start: $0.location, end: $0.location + $0.length) } ?? locate(quote, in: text, near: nil) ?? (start: 0, end: 0)
            try db.execute(sql: """
                INSERT INTO fact_evidence (id, target_kind, fact_id, qualifier, direction, source, memory_id, memory_version,
                  span_start, span_end, quote, asserted, states, polarity, sensitivity, trust, call_group, run_id)
                VALUES (?, ?, ?, ?, ?, 'memory', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().db, kind, fid, qualifier, direction, memoryID, version,
                                 scalarOffset(text, utf16: span.start), scalarOffset(text, utf16: span.end), quote, json(asserted),
                                 states, polarity, sensitivity, trust, callGroup, runID])
            result.evidence += 1
        }
        for (i, f) in g.facts.enumerated() where preds.contains(f.predicate) {
            let oldCount = i < before.facts.count ? before.facts[i].assertions.count : 0
            let added = Array(f.assertions.dropFirst(oldCount))
            // Denied in this apply: an existing incarnation, or one this same apply created and then denied.
            let newlyNegated = f.negated && (i >= before.facts.count || !before.facts[i].negated)
            guard !added.isEmpty || newlyNegated else { continue }
            if let e = g.entities[f.entity], e.kind != "person" {
                // Aliases go to the entity each statement landed on, never one rediscovered by name.
                for (idx, r) in groupFacts.enumerated() where g.landed[idx] == f.entity {
                    try addAlias(f.entity, r.name, quote: r.quote, span: r.span)
                    if let also = r.alsoCalled, g.entities[f.entity]?.aliases.contains(also) == true {
                        try addAlias(f.entity, also, quote: r.quote, span: r.span)
                    }
                }
            }
            let fid = try factID(f.predicate, f.entity)
            for a in added {
                let n = ordinal[fid, default: 0]
                ordinal[fid] = n + 1
                var asserted: [String: Any] = ["status": a.status.rawValue, "n": n]
                if let v = a.start { asserted["start"] = v }
                if let v = a.end { asserted["end"] = v }
                if let v = a.time { asserted["time"] = v }
                if oldHandover[fid + ":" + String(n)] ?? a.handover { asserted["handover"] = true }
                if a.only { asserted["only"] = true }      // this statement's own, never the fact's aggregate
                try evidenceRow(fid, kind: "fact", asserted: asserted, states: a.states, polarity: "affirmed", quote: a.quote, span: a.span)
                if let l = a.label {
                    try evidenceRow(fid, kind: "qualifier", qualifier: "label", asserted: ["value": l, "n": n], states: a.states,
                                    polarity: "affirmed", quote: a.quote, span: a.span)
                }
                for (q, v) in a.qualifiers.sorted(by: { $0.key < $1.key }) {
                    try evidenceRow(fid, kind: "qualifier", qualifier: q, asserted: ["value": v, "n": n], states: a.states,
                                    polarity: "affirmed", quote: a.quote, span: a.span)
                }
                if a.deceased {
                    try evidenceRow(fid, kind: "qualifier", qualifier: "deceased", asserted: ["value": "true", "n": n], states: a.states,
                                    polarity: "affirmed", quote: a.quote, span: a.span)
                }
                if let v = a.precededBy {
                    try evidenceRow(fid, kind: "order", direction: "preceded_by", asserted: ["value": v, "n": n], states: a.states,
                                    polarity: "affirmed", quote: a.quote, span: a.span)
                }
                if let v = a.followedBy {
                    try evidenceRow(fid, kind: "order", direction: "followed_by", asserted: ["value": v, "n": n], states: a.states,
                                    polarity: "affirmed", quote: a.quote, span: a.span)
                }
            }
            if newlyNegated {         // a denial is a statement too: its ordinal keeps it apart from a later affirmation
                let denial = x.facts.first { !$0.positive && $0.predicate == f.predicate }
                let n = ordinal[fid, default: 0]
                ordinal[fid] = n + 1
                try evidenceRow(fid, kind: "fact", asserted: ["n": n], states: true, polarity: "denied", quote: denial?.quote ?? "",
                                span: denial?.span)
            }
        }
        // Role groups this memory states, with their counts, as evidence on the group's fact: so a group goes with its
        // memory, and a cloud roster shows it only when a sendable memory is behind it (memory processing §11.9).
        var counted: [String: (Int?, String)] = [:]         // group id → (the count this statement gives, its quote)
        for r in x.facts where preds.contains(r.predicate) && (r.positive || r.count != nil || r.only || r.entity == "none") {
            let cls = g.labelClass(r.predicate, r.label)
            let gid: String? = {
                if let e = g.entities[r.entity], e.group != nil, e.name == nil { return r.entity }
                if r.entity == "none" || r.entity == "group" || r.count != nil || r.only {
                    return g.groups[FactsEntity.RoleGroup(predicate: r.predicate, cls: cls)]
                }
                return nil
            }()
            let n: Int? = r.entity == "none" ? 0 : r.only ? 1 : r.count
            if let gid, n != nil || counted[gid]?.0 == nil { counted[gid] = (n, r.quote) }
        }
        for (gid, (n, quote)) in counted.sorted(by: { $0.key < $1.key }) {
            guard let group = g.entities[gid]?.group else { continue }
            let fid = try factID(group.predicate, gid)
            try evidenceRow(fid, kind: "fact", asserted: n.map { ["count": $0] } ?? [:], states: true, polarity: "affirmed", quote: quote)
        }

        // What changed: facts whose evidence from this version and group differs, and their entities.
        let newSignatures = try signatures(db, memoryID: memoryID, version: version, callGroup: callGroup)
        var touchedFacts = newFacts
        for fid in Set(oldSignatures.keys).union(newSignatures.keys) where oldSignatures[fid] != newSignatures[fid] {
            touchedFacts.insert(fid)
        }
        for r in oldAliasRows where !newAliases.contains(r["alias_id"] as String) { touchedEntities.insert(r["entity_id"]) }

        // The model's decisions, with what they depend on.
        for (key, d) in g.decisions where key.memoryID == memoryID && before.decisions[key] == nil {
            guard let ph = phrases.first(where: { $0.start == key.start }) else { continue }
            let did = UUID().db
            let outcome = d.basis == .someoneElse ? "someone_else" : d.basis == .group ? "group" : "entity"
            try db.execute(sql: """
                INSERT INTO mention_decision (id, memory_id, memory_version, mention, quote, span_start, span_end, outcome,
                  entity_id, basis, source, call_group, run_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'model', ?, ?, ?)
                """, arguments: [did, memoryID, version, ph.surface, ph.surface, scalarOffset(text, utf16: ph.start),
                                 scalarOffset(text, utf16: ph.end), outcome, d.entity, d.basis.rawValue, callGroup, runID, now])
            result.decisions += 1
            pendingDependencies.append((did, ph.predicate, Set(x.roster.keys).union(d.entity.map { [$0] } ?? [])))
        }

        // Names the model couldn't decide between ("ambiguous"): kept so the name link reads as ambiguous.
        var newAmbiguous = Set<String>()
        for p in x.people where p.person == "ambiguous" {
            guard let link = g.names[FactsGraph.NameKey(memoryID: memoryID, surface: p.name)], link.basis == .ambiguous else { continue }
            let span = p.span.flatMap { q -> NSRange? in
                FactsSentText.findWord(p.name, in: text, within: q)
            } ?? locate(p.name, in: text, near: nil).map { NSRange(location: $0.start, length: $0.end - $0.start) }
            let mention = span.map { (text as NSString).substring(with: $0) } ?? p.name      // as the text writes it
            newAmbiguous.insert(mention)
            let did = UUID().db
            try db.execute(sql: """
                INSERT INTO mention_decision (id, memory_id, memory_version, mention, quote, span_start, span_end, outcome,
                  entity_id, basis, source, call_group, run_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'unknown', NULL, ?, 'model', ?, ?, ?)
                """, arguments: [did, memoryID, version, mention, mention, span.map { scalarOffset(text, utf16: $0.location) },
                                 span.map { scalarOffset(text, utf16: $0.location + $0.length) }, LinkBasis.ambiguous.rawValue,
                                 callGroup, runID, now])
            try db.execute(sql: "INSERT INTO decision_dependency (decision_id, kind, ref_id, ref_version) VALUES (?, 'memory', ?, ?)",
                           arguments: [did, memoryID, String(version)])
            // A new fact about a candidate, or a candidate gone, is a reason to ask again (§11.3 reconciliation).
            pendingAmbiguous.append((did, link.candidates))
            result.ambiguousNames += 1
        }

        try touch(db, facts: touchedFacts, entities: touchedEntities, except: memoryID, now: now)
        for (did, candidates) in pendingAmbiguous {
            for e in candidates {
                let v = try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [e]) ?? ""
                try db.execute(sql: "INSERT OR IGNORE INTO decision_dependency (decision_id, kind, ref_id, ref_version) VALUES (?, 'entity', ?, ?)",
                               arguments: [did, e, v])
            }
        }
        // What this version no longer supports goes (or becomes a tombstone).
        if !affected.facts.isEmpty || !affected.entities.isEmpty { try collectGarbage(db, now: now) }
        // Dependencies are recorded after the touch, at the versions this apply leaves.
        for (did, predicate, entities) in pendingDependencies {
            try recordDependencies(db, decisionID: did, memoryID: memoryID, version: version, predicate: predicate, entities: entities)
        }
        // What the reading was asked knowing, on the graph it leaves: reconciliation re-asks only what changed since.
        // A cloud reading knew only what's sendable, and every reading only what's recorded: its knowledge is recorded on
        // the graph it saw.
        let knew = sendable != nil || uses.hidesRecorded
            ? try load(db, registry: registry, userAliases: userAliases, uses: uses, sendable: sendable).graph : g
        try FactsReconciler.recordAsked(db, graph: knew, memory: fm, version: version, group: callGroup, phrases: phrases,
                                        scope: original.scope, decisions: pendingDependencies.map(\.0), readKey: original.readKey,
                                        now: now)
        if result.evidence > 0 || result.decisions > 0 || newAmbiguous != oldAmbiguous || !newAliases.isEmpty || !oldAliasRows.isEmpty
            || !touchedFacts.isEmpty || !touchedEntities.isEmpty { try bumpRevision(db) }
        return result
    }

    /// A model decision's dependencies, at their current versions: its memory version, the roster entries and the
    /// entity it rested on, and its predicate's facts and count (a new candidate holder).
    static func recordDependencies(_ db: Database, decisionID did: String, memoryID: String, version: Int, predicate: String,
                                   entities: Set<String>) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO decision_dependency (decision_id, kind, ref_id, ref_version) VALUES (?, 'memory', ?, ?)",
                       arguments: [did, memoryID, String(version)])
        for e in entities.sorted() {
            guard let v = try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [e]) else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO decision_dependency (decision_id, kind, ref_id, ref_version) VALUES (?, 'entity', ?, ?)",
                           arguments: [did, e, v])
        }
        for f in try Row.fetchAll(db, sql: "SELECT id, updated_at FROM fact WHERE predicate = ?", arguments: [predicate]) {
            try db.execute(sql: "INSERT OR IGNORE INTO decision_dependency (decision_id, kind, ref_id, ref_version) VALUES (?, 'fact', ?, ?)",
                           arguments: [did, f["id"] as String, f["updated_at"] as String])
        }
        try db.execute(sql: "INSERT OR IGNORE INTO decision_dependency (decision_id, kind, ref_id, ref_version) VALUES (?, 'fact', ?, ?)",
                       arguments: [did, predicateRef(predicate), try predicateVersion(db, predicate)])
    }

    /// Memory versions and call groups whose model decisions no longer count (invalidated, or a dependency changed):
    /// reconciliation reads them again (memory processing §11.3). Current versions of active and archived memories only.
    static func staleDecisions(_ db: Database) throws -> [(memoryID: String, callGroup: String)] {
        var out: [(String, String)] = [], seen = Set<String>()
        var dependencies: [String: [Row]] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT * FROM decision_dependency") { dependencies[r["decision_id"], default: []].append(r) }
        for d in try Row.fetchAll(db, sql: """
            SELECT d.id, d.memory_id, d.call_group, d.invalidated_at FROM mention_decision d JOIN memory m ON m.id = d.memory_id
            WHERE d.source = 'model' AND d.memory_version = m.version AND m.status IN ('active','archived') AND d.call_group IS NOT NULL
            ORDER BY m.seq, d.rowid
            """) {
            let mid: String = d["memory_id"], group: String = d["call_group"]
            guard !seen.contains(mid + "\u{1F}" + group) else { continue }
            let stale = try (d["invalidated_at"] as Date?) != nil || (dependencies[d["id"]] ?? []).contains { dep in
                try currentVersion(db, kind: dep["kind"], ref: dep["ref_id"]) != (dep["ref_version"] as String)
            }
            if stale {
                seen.insert(mid + "\u{1F}" + group)
                out.append((mid, group))
            }
        }
        return out
    }

    /// Marks facts and entities changed (a new `updated_at`), and the model decisions that depended on them stale
    /// (memory processing §11.4): their memories are queued again (13a.2).
    static func touch(_ db: Database, facts: Set<String>, entities: Set<String>, except memoryID: String? = nil, now: Date) throws {
        var predicates = Set<String>(), entities = entities
        for f in facts {
            try db.execute(sql: "UPDATE fact SET updated_at = ? WHERE id = ?", arguments: [now, f])
            if let row = try Row.fetchOne(db, sql: "SELECT predicate, entity_id FROM fact WHERE id = ?", arguments: [f]) {
                predicates.insert(row["predicate"])
                entities.insert(row["entity_id"])        // a roster entry is its entity and its facts: its token moves
            }
        }
        for e in entities { try db.execute(sql: "UPDATE entity SET updated_at = ? WHERE id = ?", arguments: [now, e]) }
        var refs = facts.map { ("fact", $0) } + entities.map { ("entity", $0) }
        refs += predicates.map { ("fact", predicateRef($0)) }
        for (kind, id) in refs {
            let current = try currentVersion(db, kind: kind, ref: id)
            try db.execute(sql: """
                UPDATE mention_decision SET invalidated_at = ?
                WHERE invalidated_at IS NULL AND source = 'model' AND memory_id IS NOT ?
                  AND id IN (SELECT decision_id FROM decision_dependency WHERE kind = ? AND ref_id = ? AND ref_version IS NOT ?)
                """, arguments: [now, memoryID, kind, id, current])
        }
    }

    /// The facts and entities a memory's evidence supports (before it's removed, to touch them after).
    static func supportedBy(_ db: Database, memoryIDs: [String]) throws -> (facts: Set<String>, entities: Set<String>) {
        var facts = Set<String>(), entities = Set<String>()
        for start in stride(from: 0, to: memoryIDs.count, by: 500) {
            let chunk = Array(memoryIDs[start..<min(start + 500, memoryIDs.count)])
            let marks = databaseQuestionMarks(count: chunk.count)
            let args = StatementArguments(chunk)
            facts.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT fact_id FROM fact_evidence WHERE memory_id IN (\(marks))", arguments: args))
            entities.formUnion(try String.fetchAll(db, sql: """
                SELECT DISTINCT a.entity_id FROM alias_evidence ev JOIN entity_alias a ON a.id = ev.alias_id WHERE ev.memory_id IN (\(marks))
                """, arguments: args))
            // Corrections made from these memories (their quoted span may go with them) change what they correct.
            for r in try Row.fetchAll(db, sql: "SELECT target_kind, target_id FROM manual_override WHERE memory_id IN (\(marks))", arguments: args) {
                let kind: String = r["target_kind"], id: String = r["target_id"]
                if kind == "entity" || kind == "alias" {
                    entities.insert(id)
                } else if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM fact WHERE id = ?)", arguments: [id]) == true {
                    facts.insert(id)
                }
            }
        }
        for f in facts {
            if let e = try String.fetchOne(db, sql: "SELECT entity_id FROM fact WHERE id = ?", arguments: [f]) { entities.insert(e) }
        }
        return (facts, entities)
    }
}
