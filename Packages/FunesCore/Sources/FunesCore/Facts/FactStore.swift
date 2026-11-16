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
        case .importChatGPT, .importClaude, .importMarkdown, .importFunes: return .import
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
        /// User rows whose episode selector matches no episode, or several: To check.
        var toCheck: [String]
        /// fact row id by (predicate, entity id), and back.
        var factIDs: [String: String]
        var factKeys: [String: (predicate: String, entity: String)]

        static func key(_ predicate: String, _ entity: String) -> String { predicate + "\u{1F}" + entity }
    }

    /// The learned facts as the graph reads them. Counts memory evidence only from active and archived memories at
    /// their current version (an archived memory keeps its former and dated facts, not a current status), plus the
    /// user's own rows; applies manual overrides and corrections on top, so they win over inference.
    static func load(_ db: Database, registry: FactsRegistry = .bundled, userAliases: [String] = []) throws -> Loaded {
        var g = FactsGraph(registry: registry, userAliases: userAliases)
        g.idStyle = .uuid
        let counted = try countedMemories(db)
        func counts(_ memoryID: String?, _ version: Int?) -> Counted? {
            guard let memoryID, let c = counted[memoryID], c.version == version else { return nil }
            return c
        }
        let overrides = try Row.fetchAll(db, sql: "SELECT * FROM manual_override ORDER BY created_at, rowid")

        // Entities and their aliases.
        var aliasRows: [String: [Row]] = [:]
        for a in try Row.fetchAll(db, sql: "SELECT * FROM entity_alias ORDER BY rowid") {
            aliasRows[a["entity_id"], default: []].append(a)
        }
        var supported = Set<String>()     // alias ids with counting evidence
        for e in try Row.fetchAll(db, sql: "SELECT alias_id, memory_id, memory_version FROM alias_evidence")
        where counts(e["memory_id"], e["memory_version"]) != nil {
            supported.insert(e["alias_id"])
        }
        for e in try Row.fetchAll(db, sql: "SELECT * FROM entity WHERE is_you = 0 ORDER BY rowid") {
            let id: String = e["id"]
            // A tombstone's confirmed alias has no text, only its normalised form: enough to re-attach by.
            let aliases = (aliasRows[id] ?? []).filter { a in
                supported.contains(a["id"] as String) || (a["manual"] as Int) == 1 || (a["confirmed"] as Int) == 1
            }.map { ($0["alias"] as String?) ?? ($0["normalized"] as String) }
            var name: String? = e["name"]
            if let n = name, !aliases.contains(n) { name = aliases.first }
            if name == nil, !aliases.isEmpty { name = aliases.first }
            let gp: String? = e["group_predicate"]
            let group = gp.map { FactsEntity.RoleGroup(predicate: $0, cls: e["group_label"]) }
            g.insert(FactsEntity(id: id, seq: 0, kind: e["kind"], name: name, aliases: Set(aliases), group: group,
                                 count: e["group_count"], deceased: (e["deceased"] as Int) == 1))
        }

        // Facts from their evidence, replayed in the order it was written (incarnations: a denial ends one, a later
        // affirmation starts the next, as `FactsGraph.apply` does).
        var factIDs: [String: String] = [:], factKeys: [String: (predicate: String, entity: String)] = [:]
        let factRows = try Row.fetchAll(db, sql: "SELECT * FROM fact ORDER BY rowid")
        var entityOfFact: [String: String] = [:]
        for f in factRows { entityOfFact[f["id"]] = f["entity_id"] }
        var evidence: [String: [Row]] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT rowid AS rid, * FROM fact_evidence ORDER BY rowid") {
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
        for f in factRows {
            let fid: String = f["id"], pred: String = f["predicate"], ent: String = f["entity_id"]
            guard g.entities[ent] != nil, !rejectedEverywhere.contains(fid) else { continue }
            factIDs[Loaded.key(pred, ent)] = fid
            factKeys[fid] = (pred, ent)
            let rows = evidence[fid] ?? []
            // One assertion per memory (or user row): its fact row, with its qualifiers and order edges.
            struct Pending { var a: FactAssertion; var denied: Bool; var only: Bool }
            var order: [String] = [], pending: [String: Pending] = [:]
            for r in rows {
                let src: String = r["source"]
                let key: String
                var trusted = true
                let written: String
                if src == "memory" {
                    guard let c = counts(r["memory_id"], r["memory_version"]) else { continue }
                    if rejectedFromMemory[fid]?.contains(c.memory.id) == true { continue }
                    key = "m:" + c.memory.id
                    trusted = c.memory.trusted
                    written = c.memory.written
                } else {
                    key = "u:" + (r["id"] as String)
                    written = writtenDay(Date())
                }
                if pending[key] == nil {
                    order.append(key)
                    pending[key] = Pending(a: FactAssertion(memoryID: src == "memory" ? r["memory_id"] : "user", trusted: trusted,
                                                            written: written, status: .unknown, qualifiers: [:], states: true,
                                                            quote: r["quote"] ?? "", handover: false), denied: false, only: false)
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
                    p.a.handover = asserted["handover"] as? Bool ?? false
                    p.only = asserted["only"] as? Bool ?? false
                    p.a.states = (r["states"] as Int) == 1
                    if src == "memory", let c = counted[p.a.memoryID], c.status == "archived", p.a.status == .current {
                        p.a.status = .unknown        // an archived memory keeps its former and dated facts only
                    }
                case "qualifier":
                    if let q: String = r["qualifier"], let v = asserted["value"] as? String {
                        if q == "label" { p.a.label = v } else { p.a.qualifiers[q] = v }
                    }
                case "order":
                    let before = (r["direction"] as String?) == "preceded_by"
                    let other = (r["other_fact_id"] as String?).flatMap { entityOfFact[$0] }
                    let name = asserted["value"] as? String
                    if before { p.a.precededBy = name; p.a.precededByEntity = other } else { p.a.followedBy = name; p.a.followedByEntity = other }
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
                    if let last = incarnations.indices.last, !incarnations[last].negated,
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
                if incarnations[i].label == nil, let l = p.a.label {
                    incarnations[i].label = l
                    incarnations[i].cls = g.labelClass(pred, l)
                }
                incarnations[i].only = incarnations[i].only || p.only
                incarnations[i].assertions.append(p.a)
            }
            g.facts += incarnations
        }

        // Overrides win: names, deceased, labels, merges.
        for o in overrides {
            let kind: String = o["target_kind"], field: String = o["field"], target: String = o["target_id"]
            let value = (o["value"] as String?).flatMap { s -> Any? in
                guard let data = s.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            }
            switch (kind, field) {
            case ("entity", "name"):
                if let n = value as? String, g.entities[target] != nil {
                    g.entities[target]?.name = n
                    g.entities[target]?.aliases.insert(n)
                }
            case ("entity", "deceased"):
                if let b = value as? Bool { g.entities[target]?.deceased = b }
            case ("entity", "merged_into"):
                if let into = value as? String, let from = g.entities[target], g.entities[into] != nil, into != target {
                    g.entities[into]?.aliases.formUnion(from.aliases)
                    for i in g.facts.indices where g.facts[i].entity == target { g.facts[i].entity = into }
                    g.entities[target] = nil
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

        // User rows whose selector matches no episode or several go to To check, and don't apply.
        for i in g.facts.indices {
            let userRows = g.facts[i].assertions.filter { $0.fromUser && $0.selector != nil }
            guard !userRows.isEmpty else { continue }
            var plain = g.facts[i]
            plain.assertions.removeAll { $0.fromUser && $0.selector != nil }
            let eps = g.factEpisodes(plain)
            g.facts[i].assertions.removeAll { a in
                guard a.fromUser, let sel = a.selector else { return false }
                let hits = eps.filter { e in
                    let lo = e.start?.lo ?? DateRange.minDay, hi = e.end?.hi ?? DateRange.maxDay
                    return lo <= sel.hi && sel.lo <= hi
                }
                if hits.count != 1 { toCheck.append(a.quote); return true }
                return false
            }
        }

        // Decisions: the model's at the memory's current version, and the user's keyed to the quote.
        for d in try Row.fetchAll(db, sql: "SELECT * FROM mention_decision ORDER BY created_at, rowid") {
            let mid: String = d["memory_id"], src: String = d["source"], outcome: String = d["outcome"]
            guard let c = counted[mid] else { continue }
            if src == "model", (d["memory_version"] as Int?) != c.version || (d["invalidated_at"] as Date?) != nil { continue }
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
    }

    /// Writes one memory version's extraction for one call group, in the caller's transaction: earlier evidence of
    /// that version and group is replaced, so a re-read is idempotent. Fails if the memory or a roster entry changed.
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

        let before = try load(db, registry: registry, userAliases: userAliases).graph
        var g = before
        let preds = Set(registry.groupPredicates(callGroup))
        let phrases = g.rolePhrases(text, predicates: preds)
        g.apply(fm, phrases: phrases, people: x.people, facts: x.facts.filter { preds.contains($0.predicate) },
                roles: x.roles, roster: Set(x.roster.keys))
        var result = ApplyResult()
        var touchedEntities = Set<String>(), touchedFacts = Set<String>()

        // Entities: new, merged away, changed.
        for e in g.orderedEntities where before.entities[e.id] == nil {
            try db.execute(sql: """
                INSERT INTO entity (id, kind, name, group_predicate, group_label, group_count, deceased, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [e.id, e.kind, e.name, e.group?.predicate, e.group?.cls, e.count, e.deceased, now, now])
            result.entities += 1
        }
        for (id, _) in before.entities where g.entities[id] == nil {
            // merged by "also called": the survivor took its aliases and facts
            guard let into = g.facts.first(where: { f in before.facts.contains { $0.entity == id && $0.predicate == f.predicate } })?.entity
                    ?? g.entities.values.first(where: { $0.aliases.isSuperset(of: before.entities[id]!.aliases) })?.id else { continue }
            try mergeEntity(db, from: id, into: into, now: now)
            touchedEntities.insert(into)
        }
        for e in g.entities.values {
            guard let old = before.entities[e.id] else { continue }
            if old.name == nil, let n = e.name {
                try db.execute(sql: "UPDATE entity SET name = ?, tombstone = 0, updated_at = ? WHERE id = ?", arguments: [n, now, e.id])
                touchedEntities.insert(e.id)
            }
            if !old.deceased, e.deceased {
                try db.execute(sql: "UPDATE entity SET deceased = 1, updated_at = ? WHERE id = ?", arguments: [now, e.id])
                touchedEntities.insert(e.id)
            }
            if old.count != e.count {
                try db.execute(sql: "UPDATE entity SET group_count = ?, updated_at = ? WHERE id = ?", arguments: [e.count, now, e.id])
                touchedEntities.insert(e.id)
            }
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
            try db.execute(sql: "UPDATE entity SET tombstone = 0 WHERE id = ?", arguments: [entity])
            touchedEntities.insert(entity)
        }
        for p in x.people {
            if let link = g.names[FactsGraph.NameKey(memoryID: memoryID, surface: p.name)], let e = link.entity {
                try addAlias(e, p.name, quote: p.quote)
            }
        }

        // Facts: this memory's assertions, and the denials it made.
        func factID(_ pred: String, _ entity: String) throws -> String {
            if let id = try String.fetchOne(db, sql: "SELECT id FROM fact WHERE predicate = ? AND entity_id = ?", arguments: [pred, entity]) {
                try db.execute(sql: "UPDATE fact SET tombstone = 0, updated_at = ? WHERE id = ?", arguments: [now, id])
                return id
            }
            let id = UUID().db
            try db.execute(sql: "INSERT INTO fact (id, predicate, entity_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                           arguments: [id, pred, entity, now, now])
            result.facts += 1
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
            touchedFacts.insert(fid)
        }
        for (i, f) in g.facts.enumerated() {
            let mine = f.assertions.filter { $0.memoryID == memoryID }
            let newlyNegated = i < before.facts.count && !before.facts[i].negated && f.negated
            guard !mine.isEmpty || newlyNegated else { continue }
            if g.registry.kindOf(f.predicate) != "person", let e = g.entities[f.entity] {
                for r in x.facts where r.predicate == f.predicate
                    && g.byName(g.placeholder(f.predicate, r.name) ?? r.name, kind: e.kind).contains(where: { $0.id == f.entity }) {
                    try addAlias(f.entity, r.name, quote: r.quote)
                    if let also = r.alsoCalled { try addAlias(f.entity, also, quote: r.quote) }
                }
            }
            let fid = try factID(f.predicate, f.entity)
            for a in mine {
                var asserted: [String: Any] = ["status": a.status.rawValue]
                if let v = a.start { asserted["start"] = v }
                if let v = a.end { asserted["end"] = v }
                if let v = a.time { asserted["time"] = v }
                if a.handover { asserted["handover"] = true }
                if f.only { asserted["only"] = true }
                try evidenceRow(fid, kind: "fact", asserted: asserted, states: a.states, polarity: "affirmed", quote: a.quote)
                if let l = a.label {
                    try evidenceRow(fid, kind: "qualifier", qualifier: "label", asserted: ["value": l], states: a.states,
                                    polarity: "affirmed", quote: a.quote)
                }
                for (q, v) in a.qualifiers.sorted(by: { $0.key < $1.key }) {
                    try evidenceRow(fid, kind: "qualifier", qualifier: q, asserted: ["value": v], states: a.states,
                                    polarity: "affirmed", quote: a.quote)
                }
                if let v = a.precededBy {
                    try evidenceRow(fid, kind: "order", direction: "preceded_by", asserted: ["value": v], states: a.states,
                                    polarity: "affirmed", quote: a.quote)
                }
                if let v = a.followedBy {
                    try evidenceRow(fid, kind: "order", direction: "followed_by", asserted: ["value": v], states: a.states,
                                    polarity: "affirmed", quote: a.quote)
                }
            }
            if newlyNegated {
                let quote = x.facts.first { !$0.positive && $0.predicate == f.predicate }?.quote ?? ""
                try evidenceRow(fid, kind: "fact", asserted: [:], states: true, polarity: "denied", quote: quote)
            }
        }

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
            try db.execute(sql: "INSERT INTO decision_dependency (decision_id, kind, ref_id, ref_version) VALUES (?, 'memory', ?, ?)",
                           arguments: [did, memoryID, String(version)])
            let entities = Set(x.roster.keys).union(d.entity.map { [$0] } ?? [])
            for e in entities {
                let v = try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [e]) ?? ""
                try db.execute(sql: "INSERT OR IGNORE INTO decision_dependency (decision_id, kind, ref_id, ref_version) VALUES (?, 'entity', ?, ?)",
                               arguments: [did, e, v])
            }
            for f in try Row.fetchAll(db, sql: "SELECT id, updated_at FROM fact WHERE predicate = ?", arguments: [ph.predicate]) {
                try db.execute(sql: "INSERT OR IGNORE INTO decision_dependency (decision_id, kind, ref_id, ref_version) VALUES (?, 'fact', ?, ?)",
                               arguments: [did, f["id"] as String, f["updated_at"] as String])
            }
            result.decisions += 1
        }

        for e in touchedEntities { try db.execute(sql: "UPDATE entity SET updated_at = ? WHERE id = ?", arguments: [now, e]) }
        try invalidateDependents(db, entities: touchedEntities, facts: touchedFacts, except: memoryID, now: now)
        if result != ApplyResult() || !touchedEntities.isEmpty { try bumpRevision(db) }
        return result
    }

    /// Moves an entity's aliases and facts into another, then deletes it.
    static func mergeEntity(_ db: Database, from: String, into: String, now: Date) throws {
        try db.execute(sql: "UPDATE entity_alias SET entity_id = ? WHERE entity_id = ?", arguments: [into, from])
        for f in try Row.fetchAll(db, sql: "SELECT id, predicate FROM fact WHERE entity_id = ?", arguments: [from]) {
            let fid: String = f["id"], pred: String = f["predicate"]
            if let keep = try String.fetchOne(db, sql: "SELECT id FROM fact WHERE predicate = ? AND entity_id = ?", arguments: [pred, into]) {
                try db.execute(sql: "UPDATE fact_evidence SET fact_id = ? WHERE fact_id = ?", arguments: [keep, fid])
                try db.execute(sql: "UPDATE fact_evidence SET other_fact_id = ? WHERE other_fact_id = ?", arguments: [keep, fid])
                try db.execute(sql: "DELETE FROM fact WHERE id = ?", arguments: [fid])
            } else {
                try db.execute(sql: "UPDATE fact SET entity_id = ?, updated_at = ? WHERE id = ?", arguments: [into, now, fid])
            }
        }
        try db.execute(sql: "UPDATE mention_decision SET entity_id = ? WHERE entity_id = ?", arguments: [into, from])
        try db.execute(sql: "DELETE FROM entity WHERE id = ?", arguments: [from])
    }

    /// Marks decisions stale when a fact or entity they depend on changed (memory processing §11.4): the memory is
    /// queued again (13a.2).
    static func invalidateDependents(_ db: Database, entities: Set<String>, facts: Set<String>, except memoryID: String? = nil,
                                     now: Date) throws {
        for (kind, ids) in [("entity", entities), ("fact", facts)] {
            for id in ids {
                let current = try String.fetchOne(db, sql: "SELECT updated_at FROM \(kind) WHERE id = ?", arguments: [id])
                try db.execute(sql: """
                    UPDATE mention_decision SET invalidated_at = ?
                    WHERE invalidated_at IS NULL AND source = 'model' AND memory_id IS NOT ?
                      AND id IN (SELECT decision_id FROM decision_dependency WHERE kind = ? AND ref_id = ? AND ref_version IS NOT ?)
                    """, arguments: [now, memoryID, kind, id, current])
            }
        }
    }
}
