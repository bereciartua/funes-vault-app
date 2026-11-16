import Foundation
import FunesProtocol
import GRDB

/// One memory's validated extraction for one call group (13a.2 produces it from the model's output).
public struct FactsExtraction: Sendable {
    public var people: [ExtractedPerson]
    public var facts: [ExtractedFact]
    public var roles: [ExtractedRole]
    /// Roster entries the call used, with the `updated_at` each had (the apply checks they're unchanged).
    public var roster: [String: String]

    public init(people: [ExtractedPerson] = [], facts: [ExtractedFact] = [], roles: [ExtractedRole] = [],
                roster: [String: String] = [:]) {
        self.people = people
        self.facts = facts
        self.roles = roles
        self.roster = roster
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
            SELECT id, seq, title, body, created_at, source, trust, status, version, sensitivity FROM memory
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

    static func bumpRevision(_ db: Database) throws {
        try db.execute(sql: "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'facts_revision'")
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
    struct Exclusion { var memoryID: String; var version: Int; var callGroup: String }

    static func load(_ db: Database, registry: FactsRegistry = .bundled, userAliases: [String] = [],
                     excluding: Exclusion? = nil) throws -> Loaded {
        var g = FactsGraph(registry: registry, userAliases: userAliases)
        g.idStyle = .uuid
        let counted = try countedMemories(db)
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
        for e in try Row.fetchAll(db, sql: "SELECT alias_id, memory_id, memory_version FROM alias_evidence") {
            guard let c = counts(e["memory_id"], e["memory_version"]) else { continue }
            supported.insert(e["alias_id"])
            if c.memory.trusted { trustedSupport.insert(e["alias_id"]) }
        }
        var groupEntities = Set<String>()
        for e in try Row.fetchAll(db, sql: "SELECT * FROM entity WHERE is_you = 0 ORDER BY rowid") {
            let id: String = e["id"]
            // A tombstone's confirmed alias has no text, only its normalised form: enough to re-attach by.
            let aliases = (aliasRows[id] ?? []).filter { a in
                supported.contains(a["id"] as String) || (a["manual"] as Int) == 1 || (a["confirmed"] as Int) == 1
            }.map { ($0["alias"] as String?) ?? ($0["normalized"] as String) }
            let trustedAliases = (aliasRows[id] ?? []).filter { a in
                trustedSupport.contains(a["id"] as String) || (a["manual"] as Int) == 1 || (a["confirmed"] as Int) == 1
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
            if let x = excluding, (r["memory_id"] as String?) == x.memoryID, (r["memory_version"] as Int?) == x.version,
               (r["call_group"] as String?) == x.callGroup { continue }
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
            guard g.entities[ent] != nil, !rejectedEverywhere.contains(fid) else { continue }
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
                    pending[key] = Pending(a: FactAssertion(memoryID: c?.memory.id ?? "user", trusted: c?.memory.trusted ?? true,
                                                            written: c?.memory.written ?? userDay, status: .unknown,
                                                            qualifiers: [:], states: true, quote: r["quote"] ?? "", handover: false),
                                           denied: false, only: false)
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
                            if v == "true", c?.memory.trusted == true { deceasedByEvidence.insert(ent) }
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
        for o in overrides {
            let kind: String = o["target_kind"], field: String = o["field"], target: String = o["target_id"]
            // A correction made from a memory holds while that memory and its quoted span do.
            if let mid: String = o["memory_id"] {
                guard let c = counted[mid], locate(o["quote"], in: c.memory.text, near: nil) != nil else { continue }
            }
            let value = decoded(o["value"])
            switch (kind, field) {
            case ("entity", "name"):
                if let n = value as? String, g.entities[target] != nil {
                    g.entities[target]?.name = n
                    g.addAlias(target, n, trusted: true)
                }
            case ("entity", "not_same"):
                if let other = value as? String { g.notSame.insert([target, other]) }
            case ("entity", "deceased"):
                if let b = value as? Bool { g.entities[target]?.deceased = b }
            case ("entity", "merged_into"):
                // Merge With…: one entity, and one fact per predicate, its evidence fused.
                if let into = value as? String, let from = g.entities[target], g.entities[into] != nil, into != target {
                    g.entities[into]?.aliases.formUnion(from.aliases)
                    g.entities[into]?.trustedAliases.formUnion(from.trustedAliases)
                    let dead = (g.entities[into]?.deceased ?? false) || from.deceased
                    g.entities[into]?.deceased = dead
                    for i in g.facts.indices where g.facts[i].entity == target {
                        if let j = g.facts.indices.last(where: { g.facts[$0].entity == into && g.facts[$0].predicate == g.facts[i].predicate
                                                                && !g.facts[$0].negated }), !g.facts[i].negated {
                            g.facts[j].assertions += g.facts[i].assertions
                            g.facts[j].only = g.facts[j].only || g.facts[i].only
                            if g.facts[j].label == nil { g.facts[j].label = g.facts[i].label; g.facts[j].cls = g.facts[i].cls }
                            g.facts[i].negated = true          // folded into the survivor's fact
                            g.facts[i].assertions = []
                        }
                        g.facts[i].entity = into
                    }
                    g.facts.removeAll { $0.entity == into && $0.negated && $0.assertions.isEmpty }
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
            guard let c = counted[mid] else { continue }
            if src == "model" {
                if let x = excluding, mid == x.memoryID, (d["call_group"] as String?) == x.callGroup { continue }
                if (d["memory_version"] as Int?) != c.version || (d["invalidated_at"] as Date?) != nil { continue }
                let stale = try (dependencies[d["id"]] ?? []).contains { dep in
                    try currentVersion(db, kind: dep["kind"], ref: dep["ref_id"]) != (dep["ref_version"] as String)
                }
                if stale { continue }
            }
            guard let span = locate(d["quote"], in: c.memory.text, near: d["span_start"]) else { continue }
            let key = FactsGraph.DecisionKey(memoryID: mid, start: span.start)
            let entity: String? = d["entity_id"]
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
        for c in counted.values { g.memories[c.memory.id] = c.memory }
        return Loaded(graph: g, toCheck: toCheck, factIDs: factIDs, factKeys: factKeys)
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
    /// Fails if the memory or a roster entry changed.
    @discardableResult
    static func apply(_ db: Database, memoryID: String, version: Int, extraction x: FactsExtraction, callGroup: String,
                      runID: String? = nil, registry: FactsRegistry = .bundled, userAliases: [String] = [],
                      now: Date = Date()) throws -> ApplyResult {
        guard let m = try Row.fetchOne(db, sql: "SELECT * FROM memory WHERE id = ?", arguments: [memoryID]),
              (m["version"] as Int) == version, (m["status"] as String) != "deleted" else {
            throw ApplyError.memoryChanged
        }
        for (id, updated) in x.roster {
            let now = try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [id])
            if now != updated { throw ApplyError.rosterChanged }
        }
        let preds = Set(registry.groupPredicates(callGroup))
        let kinds = Set(preds.map { registry.kindOf($0) })
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
        let oldAliasRows = try Row.fetchAll(db, sql: """
            SELECT ev.alias_id, a.entity_id FROM alias_evidence ev JOIN entity_alias a ON a.id = ev.alias_id JOIN entity e ON e.id = a.entity_id
            WHERE ev.memory_id = ? AND ev.memory_version = ? AND e.kind IN (\(databaseQuestionMarks(count: kinds.count)))
            """, arguments: StatementArguments([memoryID, String(version)] + Array(kinds)))
        let oldAliases = Set(oldAliasRows.map { $0["alias_id"] as String })
        let affected = try supportedBy(db, memoryIDs: [memoryID])
        // The graph without this version's rows in this group (its names stay matchable, so a re-read finds them).
        let before = try load(db, registry: registry, userAliases: userAliases,
                              excluding: Exclusion(memoryID: memoryID, version: version, callGroup: callGroup)).graph
        for r in oldAliasRows {
            try db.execute(sql: "DELETE FROM alias_evidence WHERE alias_id = ? AND memory_id = ? AND memory_version = ?",
                           arguments: [r["alias_id"] as String, memoryID, version])
        }
        try db.execute(sql: "DELETE FROM fact_evidence WHERE memory_id = ? AND memory_version = ? AND call_group = ?",
                       arguments: [memoryID, version, callGroup])
        try db.execute(sql: "DELETE FROM mention_decision WHERE memory_id = ? AND memory_version = ? AND call_group = ? AND source = 'model'",
                       arguments: [memoryID, version, callGroup])
        let created: Date = m["created_at"]
        let text = text(title: m["title"], body: m["body"])
        let trusted = (m["trust"] as String) == "trusted"
        let sensitivity: Int = m["sensitivity"]
        let fm = FactsMemory(id: memoryID, text: text, written: writtenDay(created), source: source(m["source"]), trusted: trusted)
        let trust = trusted ? "trusted" : "untrusted"

        var g = before
        let phrases = g.rolePhrases(text, predicates: preds)
        let groupFacts = x.facts.filter { preds.contains($0.predicate) }
        g.apply(fm, phrases: phrases, people: x.people, facts: groupFacts, roles: x.roles, roster: Set(x.roster.keys))
        var result = ApplyResult(mergeSuggestions: g.mergeSuggestions.count)
        var touchedEntities = Set<String>(), newAliases = Set<String>()
        var pendingDependencies: [(String, String, Set<String>)] = []

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
        func addAlias(_ entity: String, _ alias: String, quote: String) throws {
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
            let span = locate(alias, in: text, near: nil) ?? locate(quote, in: text, near: nil) ?? (0, 0)
            try db.execute(sql: """
                INSERT OR REPLACE INTO alias_evidence (alias_id, memory_id, memory_version, span_start, span_end, quote, sensitivity, trust, run_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [aid, memoryID, version, scalarOffset(text, utf16: span.start), scalarOffset(text, utf16: span.end),
                                 quote, sensitivity, trust, runID])
            if try Int.fetchOne(db, sql: "SELECT tombstone FROM entity WHERE id = ?", arguments: [entity]) == 1 {
                try db.execute(sql: "UPDATE entity SET tombstone = 0 WHERE id = ?", arguments: [entity])
                touchedEntities.insert(entity)
            }
            newAliases.insert(aid)
            if !oldAliases.contains(aid) { touchedEntities.insert(entity) }
        }
        for p in x.people {
            if let link = g.names[FactsGraph.NameKey(memoryID: memoryID, surface: p.name)], let e = link.entity {
                try addAlias(e, p.name, quote: p.quote)
            }
        }

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
                         asserted: [String: Any], states: Bool, polarity: String, quote: String) throws {
            let span = locate(quote, in: text, near: nil) ?? (0, 0)
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
                    try addAlias(f.entity, r.name, quote: r.quote)
                    if let also = r.alsoCalled, g.entities[f.entity]?.aliases.contains(also) == true {
                        try addAlias(f.entity, also, quote: r.quote)
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
                try evidenceRow(fid, kind: "fact", asserted: asserted, states: a.states, polarity: "affirmed", quote: a.quote)
                if let l = a.label {
                    try evidenceRow(fid, kind: "qualifier", qualifier: "label", asserted: ["value": l, "n": n], states: a.states,
                                    polarity: "affirmed", quote: a.quote)
                }
                for (q, v) in a.qualifiers.sorted(by: { $0.key < $1.key }) {
                    try evidenceRow(fid, kind: "qualifier", qualifier: q, asserted: ["value": v, "n": n], states: a.states,
                                    polarity: "affirmed", quote: a.quote)
                }
                if a.deceased {
                    try evidenceRow(fid, kind: "qualifier", qualifier: "deceased", asserted: ["value": "true", "n": n], states: a.states,
                                    polarity: "affirmed", quote: a.quote)
                }
                if let v = a.precededBy {
                    try evidenceRow(fid, kind: "order", direction: "preceded_by", asserted: ["value": v, "n": n], states: a.states,
                                    polarity: "affirmed", quote: a.quote)
                }
                if let v = a.followedBy {
                    try evidenceRow(fid, kind: "order", direction: "followed_by", asserted: ["value": v, "n": n], states: a.states,
                                    polarity: "affirmed", quote: a.quote)
                }
            }
            if newlyNegated {         // a denial is a statement too: its ordinal keeps it apart from a later affirmation
                let quote = x.facts.first { !$0.positive && $0.predicate == f.predicate }?.quote ?? ""
                let n = ordinal[fid, default: 0]
                ordinal[fid] = n + 1
                try evidenceRow(fid, kind: "fact", asserted: ["n": n], states: true, polarity: "denied", quote: quote)
            }
        }
        // Role groups' counts this memory states, as evidence on the group's fact (so they go with their memory).
        var counted: [String: (Int, String)] = [:]          // group id → (the count this statement gives, its quote)
        for r in x.facts where preds.contains(r.predicate) && (r.count != nil || r.only || r.entity == "none") {
            let cls = g.labelClass(r.predicate, r.label)
            let gid: String? = {
                if let e = g.entities[r.entity], e.group != nil, e.name == nil { return r.entity }
                if r.entity == "none" || r.entity == "group" || r.count != nil || r.only {
                    return g.groups[FactsEntity.RoleGroup(predicate: r.predicate, cls: cls)]
                }
                return nil
            }()
            let n = r.entity == "none" ? 0 : r.only ? 1 : r.count ?? 0
            if let gid { counted[gid] = (n, r.quote) }
        }
        for (gid, (n, quote)) in counted.sorted(by: { $0.key < $1.key }) {
            guard let group = g.entities[gid]?.group else { continue }
            let fid = try factID(group.predicate, gid)
            try evidenceRow(fid, kind: "fact", asserted: ["count": n], states: true, polarity: "affirmed", quote: quote)
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

        try touch(db, facts: touchedFacts, entities: touchedEntities, except: memoryID, now: now)
        // What this version no longer supports goes (or becomes a tombstone).
        if !affected.facts.isEmpty || !affected.entities.isEmpty { try collectGarbage(db, now: now) }
        // Dependencies are recorded after the touch, at the versions this apply leaves.
        for (did, predicate, entities) in pendingDependencies {
            try db.execute(sql: "INSERT INTO decision_dependency (decision_id, kind, ref_id, ref_version) VALUES (?, 'memory', ?, ?)",
                           arguments: [did, memoryID, String(version)])
            for e in entities {
                let v = try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [e]) ?? ""
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
        if result.evidence > 0 || result.decisions > 0 || !touchedFacts.isEmpty || !touchedEntities.isEmpty { try bumpRevision(db) }
        return result
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
        guard !memoryIDs.isEmpty else { return ([], []) }
        let marks = databaseQuestionMarks(count: memoryIDs.count)
        let args = StatementArguments(memoryIDs)
        let facts = Set(try String.fetchAll(db, sql: "SELECT DISTINCT fact_id FROM fact_evidence WHERE memory_id IN (\(marks))", arguments: args))
        var entities = Set(try String.fetchAll(db, sql: """
            SELECT DISTINCT a.entity_id FROM alias_evidence ev JOIN entity_alias a ON a.id = ev.alias_id WHERE ev.memory_id IN (\(marks))
            """, arguments: args))
        for f in facts {
            if let e = try String.fetchOne(db, sql: "SELECT entity_id FROM fact WHERE id = ?", arguments: [f]) { entities.insert(e) }
        }
        return (facts, entities)
    }
}
