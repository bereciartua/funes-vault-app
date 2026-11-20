import Foundation
import FunesProtocol
import GRDB

/// What a cloud call may see of the learned facts (memory processing §11.9): "a fact, qualifier, date, order edge or
/// decision may be sent … only if every memory behind it, decision dependencies included, is within the limit. Manual
/// entries use the sensitivity the user picked." `FactStore.load(_:sendable:)` reads the graph as if what's above the
/// limit didn't exist, so adding something above the limit changes nothing a cloud call sees.
///
/// - **Memories** above the limit contribute nothing: no names, facts, qualifiers, dates, order edges, counts,
///   decisions, links or quotes. A fact is what its sendable evidence says, and the user's rows count at the
///   sensitivity the user picked.
/// - **A fact is withheld whole** when a correction of it (a label, date, status, order, a rejection) is above the
///   limit: what's shown would rest on it.
/// - **An entity is withheld whole** when one of its names was introduced by a model reading of a memory above the
///   limit (that reading came first, or no sendable reading gives the name): sendable names may have been joined to it
///   only through that one ("Dr. Ruiz" and "Ana", joined by "Dr. Ana Ruiz"). Also when a correction of the entity
///   itself (its name, death, a merge) is above the limit, or a manual entry's typed name is (the highest of the user's
///   rows on it). A merge spreads both to everything merged together. Shown entities need something sendable behind
///   them (an unnamed group: the memory that stated it, a count or a decision).
/// - **Dependencies,** judged at the time each was made, as a decision's are: what's above the limit counts only if it
///   was known by then, so something added later changes nothing. A person is *partly hidden* at a time when withheld,
///   when one of their facts is withheld, or when something about them above the limit was read (or entered) by then.
///   A memory's link to a person is dropped while someone its name could mean (they included) was partly hidden when it
///   was read, since the reading told them apart knowing that; so is what that memory states about the person. A
///   memory's statement about someone it doesn't name came through that call's roster, so it's dropped when that person
///   or any holder of the predicate was partly hidden then. What's dropped makes that person partly hidden from then on
///   too, until nothing more is dropped. A model decision is withheld unless its memory is sendable and nothing it
///   depends on was hidden when it was made (a `predicate:` dependency: any holder of it).
/// - **Aliases the user confirmed** carry no sensitivity: they count only with sendable evidence. Code-only name links
///   add nothing a model learned and hide nothing. Not the Same only keeps two entities apart.
extension FactStore {
    struct Withheld {
        var entities = Set<String>()
        var facts = Set<String>()
        /// `alias_evidence` rows (`nameKey`) whose link rests on a hidden namesake.
        var names = Set<String>()
        /// A memory's evidence for a fact ("memory|fact") that rests on something hidden.
        var statements = Set<String>()
        /// The user's `fact_evidence` rows above the limit.
        var userRows = Set<String>()
        /// `mention_decision` ids.
        var decisions = Set<String>()
        /// The highest sensitivity behind what's shown of each entity: its roster line's, as a typed item.
        var sensitivity: [String: Int] = [:]

        static func nameKey(_ alias: String, _ memory: String, _ version: Int, _ start: Int) -> String {
            [alias, memory, String(version), String(start)].joined(separator: "|")
        }
    }

    /// `reader`: an empty graph of the vault's registry, user and uses, to find the role phrases a memory's text pairs
    /// with a name (a `named` decision's grounding, below).
    static func withheld(_ db: Database, counted: [String: Counted], limit: CloudLimit, reader: FactsGraph? = nil) throws -> Withheld {
        var out = Withheld()
        func allows(_ s: Int?) -> Bool { s.flatMap(Sensitivity.init(rawValue:)).map(limit.allows) ?? false }
        /// A memory at its current version, active or archived: nil when it doesn't count (so it's behind nothing).
        func memoryAllowed(_ id: String?, _ version: Int?) -> Bool? {
            guard let id, let c = counted[id], version == nil || c.version == version else { return nil }
            return allows(c.sensitivity)
        }
        var entities = Set<String>(), facts = Set<String>()
        // When something about an entity above the limit was first read or entered: dependencies made after that may
        // rest on it.
        var touchedSince: [String: Date] = [:]
        func touch(_ e: String, _ at: Date) { touchedSince[e] = min(touchedSince[e] ?? at, at) }
        var runStart: [String: Date] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT id, started_at FROM facts_run") { runStart[r["id"]] = r["started_at"] }
        func readAt(_ run: String?) -> Date? { run.flatMap { runStart[$0] } }
        // A memory's information is known no earlier than the memory: an above-limit touch is dated no later than its
        // memory's creation, so a re-read or an edit can't move it past what rested on it.
        var created: [String: Date] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT id, created_at FROM memory") { created[r["id"]] = r["created_at"] }
        func since(_ memory: String, _ at: Date?) -> Date { min(created[memory] ?? .distantPast, at ?? .distantPast) }
        // When each reading committed (memory, version, call group): a statement is dated by its own reading, never
        // earlier, so an above-limit reading earlier in the same run counts against it.
        var readings: [String: Date] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT memory_id, memory_version, call_group, asked_at FROM facts_asked WHERE mention_kind = 'read'") {
            readings[[r["memory_id"] as String, String(r["memory_version"] as Int), r["call_group"] as String].joined(separator: "|")] = r["asked_at"]
        }
        var entityOfFact: [String: String] = [:], predicateOfFact: [String: String] = [:]
        var factsOf: [String: [String]] = [:], holdersOf: [String: Set<String>] = [:]
        for f in try Row.fetchAll(db, sql: "SELECT id, predicate, entity_id FROM fact") {
            let id: String = f["id"], e: String = f["entity_id"], p: String = f["predicate"]
            entityOfFact[id] = e
            predicateOfFact[id] = p
            factsOf[e, default: []].append(id)
            holdersOf[p, default: []].insert(e)
        }
        var groups = Set<String>(), persons = Set<String>(), manualEntities = Set<String>(), all = Set<String>()
        for e in try Row.fetchAll(db, sql: "SELECT id, kind, name, group_predicate, manual FROM entity WHERE is_you = 0") {
            all.insert(e["id"])
            if (e["group_predicate"] as String?) != nil, (e["name"] as String?) == nil { groups.insert(e["id"]) }
            else if (e["kind"] as String) == FactsValidator.personKind { persons.insert(e["id"]) }
            if (e["manual"] as Int) == 1 { manualEntities.insert(e["id"]) }
        }
        // Who a name could mean: entities with an alias of that normalised form, or sharing its first name.
        var byForm: [String: Set<String>] = [:], byFirst: [String: Set<String>] = [:]
        for a in try Row.fetchAll(db, sql: "SELECT entity_id, normalized FROM entity_alias") {
            let n: String = a["normalized"], e: String = a["entity_id"]
            byForm[n, default: []].insert(e)
            if let first = n.split(separator: " ").first, first.count >= 3 { byFirst[String(first), default: []].insert(e) }
        }
        func sharing(_ n: String) -> Set<String> {
            var s = byForm[n] ?? []
            if n.count >= 3, !n.contains(" ") { s.formUnion(byFirst[n] ?? []) }
            if let first = n.split(separator: " ").first.map(String.init), first != n { s.formUnion(byForm[first] ?? []) }
            return s
        }
        // Whatever is merged together is one roster entry.
        var parent: [String: String] = [:]
        func root(_ x: String) -> String {
            var x = x, hops = 0
            while let p = parent[x], p != x, hops < 64 { x = p; hops += 1 }
            return x
        }

        // Names: who introduced each alias (the earliest model reading), and sendable readings.
        struct NameRow { var key: String; var memory: String; var entity: String; var normalized: String; var level: Int; var at: Date }
        var nameRows: [NameRow] = []
        var first: [String: (Date, Bool)] = [:]            // alias → earliest model reading, and whether it's sendable
        var sendableAlias = Set<String>(), restrictedAlias: [String: String] = [:]   // alias → entity
        for r in try Row.fetchAll(db, sql: """
            SELECT ev.alias_id, ev.memory_id, ev.memory_version, ev.span_start, ev.source, ev.read_at, ev.first_read_at,
              a.entity_id, a.normalized
            FROM alias_evidence ev JOIN entity_alias a ON a.id = ev.alias_id
            """) {
            // A reading with no time is judged as made after everything (it may rest on anything).
            let readTime: Date = (r["read_at"] as Date?) ?? .distantFuture
            guard let ok = memoryAllowed(r["memory_id"], r["memory_version"]) else { continue }
            let alias: String = r["alias_id"], entity: String = r["entity_id"], mid: String = r["memory_id"]
            if (r["source"] as String) == "model" {
                let at: Date = (r["first_read_at"] as Date?) ?? (r["read_at"] as Date?) ?? .distantPast
                if first[alias].map({ at < $0.0 }) ?? true { first[alias] = (at, ok) }
                if !ok {
                    restrictedAlias[alias] = entity
                    touch(entity, since(mid, at))
                }
            }
            if ok {
                sendableAlias.insert(alias)
                nameRows.append(NameRow(key: Withheld.nameKey(alias, mid, r["memory_version"], r["span_start"]), memory: mid,
                                        entity: entity, normalized: r["normalized"], level: counted[mid]?.sensitivity ?? 0, at: readTime))
            }
        }
        for (alias, entity) in restrictedAlias where first[alias]?.1 == false || !sendableAlias.contains(alias) {
            entities.insert(entity)
        }

        // Fact evidence: a memory's at its current version, the user's at the sensitivity picked.
        struct FactRow { var fact: String; var memory: String?; var level: Int; var at: Date }
        var factRows: [FactRow] = []
        var typedName: [String: Int] = [:]                // manual entity → the highest of the user's rows on it
        for r in try Row.fetchAll(db, sql: """
            SELECT id, fact_id, other_fact_id, source, memory_id, memory_version, sensitivity, asserted, run_id, call_group FROM fact_evidence
            """) {
            let fid: String = r["fact_id"]
            guard let entity = entityOfFact[fid] else { continue }
            let others = [fid] + [(r["other_fact_id"] as String?)].compactMap { $0 }
            if (r["source"] as String) == "user" {
                if object(r["asserted"])["retired_at"] != nil { continue }      // retired in To check: it counts nowhere
                let level: Int = r["sensitivity"]
                if manualEntities.contains(entity) { typedName[entity] = max(typedName[entity] ?? 0, level) }
                if allows(level) {
                    for f in others { factRows.append(FactRow(fact: f, memory: nil, level: level, at: .distantFuture)) }
                } else {
                    out.userRows.insert(r["id"])
                    // The day the user said it (kept with the row): from its start, to be safe.
                    let day = (object(r["asserted"])["written"] as? String).flatMap(Self.dayStart) ?? .distantPast
                    for f in others { if let e = entityOfFact[f] { touch(e, day) } }
                    // A correction of a fact above the limit (a date, a status, a qualifier, an order) withholds that
                    // fact whole, and both of an order's endpoints (§11.9).
                    for f in others where entityOfFact[f] != nil { facts.insert(f) }
                }
            } else {
                guard let ok = memoryAllowed(r["memory_id"], r["memory_version"]) else { continue }
                let mid: String = r["memory_id"]
                let run: String? = r["run_id"]
                if ok {
                    // Its reading's commit, else when nothing records it, after everything.
                    let reading = readings[[mid, String(r["memory_version"] as Int), (r["call_group"] as String?) ?? ""].joined(separator: "|")]
                    for f in others {
                        factRows.append(FactRow(fact: f, memory: mid, level: counted[mid]?.sensitivity ?? 0, at: reading ?? .distantFuture))
                    }
                } else {
                    for f in others { if let e = entityOfFact[f] { touch(e, since(mid, readAt(run))) } }
                }
            }
        }
        for (e, level) in typedName where !allows(level) { entities.insert(e) }

        // Corrections at the sensitivity picked (and their memory's, if keyed to one).
        var overrideLevels: [(entity: String?, fact: String?, level: Int)] = []
        for o in try Row.fetchAll(db, sql: "SELECT target_kind, target_id, field, value, sensitivity, memory_id FROM manual_override") {
            let field: String = o["field"], kind: String = o["target_kind"], target: String = o["target_id"]
            if field == "merged_into", let into = decodedString(o["value"]) {
                let ra = root(target), rb = root(into)
                if ra != rb { parent[ra] = rb }
            }
            if field == "not_same" || field == "hidden" { continue }        // Hide is for People & history's list only
            let memory: String? = o["memory_id"]
            let level = max(o["sensitivity"] as Int, memory.flatMap { counted[$0]?.sensitivity } ?? 0)
            let ok = allows(level)
            switch kind {
            case "entity", "alias":
                var targets = kind == "entity" ? [target]
                    : try String.fetchAll(db, sql: "SELECT entity_id FROM entity_alias WHERE id = ?", arguments: [target])
                if field == "merged_into", let into = decodedString(o["value"]) { targets.append(into) }
                for e in targets {
                    if !ok { entities.insert(e) }
                    overrideLevels.append((e, nil, level))
                }
            default:
                var targets = [target]
                if kind == "order" {
                    let v = object(o["value"])
                    targets += ["before", "after"].compactMap { v[$0] as? String }
                }
                for f in targets where entityOfFact[f] != nil {
                    if !ok { facts.insert(f) }
                    overrideLevels.append((nil, f, level))
                }
            }
        }

        // Decisions that resolved to a group make it exist.
        var groupDecisions: [(id: String, entity: String, level: Int)] = []
        for d in try Row.fetchAll(db, sql: """
            SELECT id, memory_id, memory_version, entity_id, source, created_at FROM mention_decision
            WHERE outcome = 'group' AND entity_id IS NOT NULL
            """) {
            guard let e: String = d["entity_id"], groups.contains(e),
                  let ok = memoryAllowed(d["memory_id"], (d["source"] as String) == "model" ? d["memory_version"] : nil) else { continue }
            if ok { groupDecisions.append((d["id"], e, counted[d["memory_id"] as String]?.sensitivity ?? 0)) }
            else { touch(e, since(d["memory_id"], d["created_at"])) }
        }

        // A merge spreads to the whole class: a withheld entity, and a withheld fact to the class's facts of its predicate.
        if !parent.isEmpty {
            let members = Set(parent.keys).union(parent.values)
            let roots = Set(entities.map(root))
            var since: [String: Date] = [:]
            for (e, at) in touchedSince { since[root(e)] = min(since[root(e)] ?? at, at) }
            let factRoots = Set(facts.compactMap { f in entityOfFact[f].map { root($0) + "|" + (predicateOfFact[f] ?? "") } })
            for e in members {
                if roots.contains(root(e)) { entities.insert(e) }
                if let at = since[root(e)] { touch(e, at) }
                for f in factsOf[e] ?? [] where factRoots.contains(root(e) + "|" + (predicateOfFact[f] ?? "")) { facts.insert(f) }
            }
        }
        // When what was dropped about an entity was first read: later dependencies may rest on it.
        var droppedSince: [String: Date] = [:]
        /// Whether an entity was partly hidden at a time.
        func hidden(_ e: String, at: Date) -> Bool {
            entities.contains(e) || (factsOf[e] ?? []).contains(where: facts.contains)
                || (touchedSince[e].map { $0 <= at } ?? false) || (droppedSince[e].map { $0 <= at } ?? false)
        }
        func drop(_ e: String, _ at: Date) { droppedSince[e] = min(droppedSince[e] ?? at, at) }

        // Name links resting on a partly hidden namesake (or the person themselves), and what that memory states
        // about the person; statements about someone the memory doesn't name, which came through the roster. Repeated
        // until nothing more is dropped (a dropped statement can be what a later reading rested on).
        var unsafe = Set<String>()                         // "memory|class"
        while true {
            let before = (out.names.count, out.statements.count)
            var namedBy: [String: Set<String>] = [:]       // memory → classes it names sendably
            for n in nameRows {
                let cls = root(n.entity)
                let others = sharing(n.normalized).filter { root($0) != cls }
                if out.names.contains(n.key) || (!others.isEmpty && others.union([n.entity]).contains(where: { hidden($0, at: n.at) })) {
                    if out.names.insert(n.key).inserted { drop(n.entity, n.at) }
                    unsafe.insert(n.memory + "|" + cls)
                } else {
                    namedBy[n.memory, default: []].insert(cls)
                }
            }
            for r in factRows {
                guard let m = r.memory, let e = entityOfFact[r.fact], persons.contains(e) else { continue }
                let cls = root(e), key = m + "|" + r.fact
                guard !out.statements.contains(key) else { continue }
                let throughRoster = namedBy[m]?.contains(cls) != true
                if unsafe.contains(m + "|" + cls)
                    || (throughRoster && (hidden(e, at: r.at)
                        || (holdersOf[predicateOfFact[r.fact] ?? ""] ?? []).contains(where: { hidden($0, at: r.at) }))) {
                    out.statements.insert(key)
                    drop(e, r.at)
                }
            }
            if before == (out.names.count, out.statements.count) { break }
        }

        // Model decisions and what they rest on, when they were made; the user's, on their memory and entity.
        var deps: [String: [Row]] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT decision_id, kind, ref_id FROM decision_dependency") { deps[r["decision_id"], default: []].append(r) }
        // Classes each memory names through a sendable link that wasn't dropped, with those names.
        var namedSendably: [String: [String: Set<String>]] = [:]          // memory → class → folded names
        for n in nameRows where !out.names.contains(n.key) {
            namedSendably[n.memory, default: [:]][root(n.entity), default: []].insert(n.normalized)
        }
        /// Whether the memory's own text pairs the phrase at this scalar offset with one of these names ("my sister
        /// Maria Lopez", "Maria is my sister"), and that name could mean nobody else in the vault (no namesake, no one
        /// sharing it as a first name): then any reader of the sendable text decides it the same way.
        func pairedInText(_ memory: String, _ start: Int?, _ names: Set<String>, _ cls: String) -> Bool {
            guard let reader, let start, !names.isEmpty,
                  let r = try? Row.fetchOne(db, sql: "SELECT title, body FROM memory WHERE id = ?", arguments: [memory]) else { return false }
            let text = FactStore.text(title: r["title"], body: r["body"])
            let at = FactStore.utf16Offset(text, scalar: start)
            guard let ph = reader.rolePhrases(text).first(where: { $0.start == at }), let paired = ph.paired else { return false }
            let norm = FactsText.normName(paired, kind: "person", registry: reader.registry), folded = FactsText.fold(paired)
            guard names.contains(norm) || names.contains(where: { FactsText.fold($0) == folded }) else { return false }
            return sharing(norm).allSatisfy { root($0) == cls }
        }
        for d in try Row.fetchAll(db, sql: "SELECT id, memory_id, memory_version, entity_id, basis, source, span_start, created_at FROM mention_decision") {
            let id: String = d["id"], at: Date = (d["created_at"] as Date?) ?? .distantFuture
            if let e: String = d["entity_id"], entities.contains(e) { out.decisions.insert(id); continue }
            if memoryAllowed(d["memory_id"], (d["source"] as String) == "model" ? d["memory_version"] : nil) == false {
                out.decisions.insert(id)
                continue
            }
            // A model's `named` decision whose phrase its own (sendable) memory's text pairs with that person's name ("my
            // sister Maria Lopez"): it rests on the text and that name link alone, which the rules above already judged
            // (dropped when a namesake was hidden), not on who else holds the role or what else is known about the
            // person. So its roster dependencies (recorded again when code revalidates it) don't withhold it, and
            // reconciliation's choice of what to ask again doesn't depend on them (§11.9). A name merely elsewhere in the
            // memory isn't enough: which of its people the reader picked may rest on what's above the limit.
            if (d["source"] as String) == "model", (d["basis"] as String?) == LinkBasis.named.rawValue, let e: String = d["entity_id"],
               let names = namedSendably[d["memory_id"] as String]?[root(e)], pairedInText(d["memory_id"], d["span_start"], names, root(e)) {
                continue
            }
            let hiddenDependency = (deps[id] ?? []).contains { dep in
                let ref: String = dep["ref_id"]
                switch dep["kind"] as String {
                case "entity": return hidden(ref, at: at)
                case "memory": return memoryAllowed(ref, nil) == false
                default:
                    if ref.hasPrefix("predicate:") {
                        return (holdersOf[String(ref.dropFirst("predicate:".count))] ?? []).contains { hidden($0, at: at) }
                    }
                    return facts.contains(ref) || entityOfFact[ref].map { hidden($0, at: at) } ?? false
                }
            }
            if hiddenDependency { out.decisions.insert(id) }
        }

        // The highest sensitivity behind what each entity shows; one with nothing sendable behind it isn't shown.
        var highest: [String: Int] = [:]
        func raise(_ e: String?, _ level: Int) {
            guard let e, !entities.contains(e) else { return }
            highest[e] = max(highest[e] ?? 0, level)
        }
        for n in nameRows where !out.names.contains(n.key) { raise(n.entity, n.level) }
        for r in factRows where !facts.contains(r.fact) && !out.statements.contains((r.memory ?? "") + "|" + r.fact) {
            guard let e = entityOfFact[r.fact] else { continue }
            // A group exists through what stated it; anyone else through their names (a fact alone shows nobody).
            if groups.contains(e) ? r.memory != nil : highest[e] != nil || manualEntities.contains(e) { raise(e, r.level) }
        }
        for d in groupDecisions where !out.decisions.contains(d.id) { raise(d.entity, d.level) }
        for o in overrideLevels {
            if let e = o.entity, highest[e] != nil || manualEntities.contains(e) { raise(e, o.level) }
            if let f = o.fact, !facts.contains(f), let e = entityOfFact[f], highest[e] != nil { raise(e, o.level) }
        }
        entities.formUnion(all.subtracting(highest.keys))
        out.entities = entities
        out.facts = facts
        out.sensitivity = highest
        return out
    }

    /// The start of an ISO day ("2026-11-17"), UTC.
    static func dayStart(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var c = DateComponents(year: p[0], month: p[1], day: p[2])
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c).map { $0.addingTimeInterval(-86_400) }   // a day early: any zone
    }

    /// A JSON-encoded string value (an override's), or nil.
    static func decodedString(_ s: String?) -> String? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }
}
