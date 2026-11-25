import CryptoKit
import Foundation
import FunesProtocol
import GRDB

/// Reconciliation (memory processing §11.3): which earlier readings to ask again, found from the store. A reading
/// records what it was asked knowing (`facts_asked`): for each role phrase, who might hold the role and what was known
/// about them; for each name, who shares it. A new holder of a role, a new fact about a candidate, or a name now shared
/// changes that knowledge, and the memory is asked again about just that phrase or name (a partial re-read), once.
/// A model decision 13a.1 invalidated because something about its predicate changed is revalidated in code when what
/// it rested on hasn't changed (the knowledge it was made with, or the name the memory pairs it with), with no call.
///
/// Ported from the spike's `needs_reconcile` (`spikes/people/facts.py`), with the asked records persisted.
enum FactsReconciler {
    /// What one memory version should be asked again in one call group.
    struct Due: Equatable {
        var roles = Set<Int>()          // scalar starts
        var names = Set<String>()       // folded surfaces
        var isEmpty: Bool { roles.isEmpty && names.isEmpty }
    }

    struct Key: Hashable { var memoryID: String; var group: String }

    // MARK: Knowledge (fingerprints with no timestamps and no quotes: a restatement changes nothing)

    /// One known person as a call saw them: id, names in the call's view, and their facts of the predicates given.
    static func summary(_ g: FactsGraph, _ e: FactsEntity, trusted: Bool, predicates: Set<String>?) -> String {
        let aliases = (trusted ? e.trustedAliases : e.aliases).map { FactsText.fold($0) }.sorted().joined(separator: ",")
        let facts = g.facts.filter { $0.entity == e.id && !$0.negated && (predicates?.contains($0.predicate) ?? true) && ($0.trusted || !trusted) }
            .map { f in [f.predicate, f.label.map { FactsText.fold($0) } ?? "", g.status(of: f).rawValue, f.trusted ? "t" : "u"].joined(separator: ":") }
            .sorted().joined(separator: ",")
        return [e.id, aliases, facts, e.deceased ? "d" : ""].joined(separator: "|")
    }

    /// What a role phrase's resolution rests on: who may hold the role then, as the call saw them, and how many more
    /// a group count says exist.
    static func roleKnowledge(_ g: FactsGraph, _ mem: FactsMemory, _ ph: RolePhrase) -> String {
        let (d, w) = g.asOf(mem, ph)
        let h = g.holders(ph, asOf: d, written: w, rejected: g.rejections[FactsGraph.DecisionKey(memoryID: mem.id, start: ph.start)] ?? [])
        // Everything the roster shows about each holder: another relation can be what tells two of them apart.
        let parts = h.holders.map { summary(g, $0.entity, trusted: mem.trusted, predicates: nil) }.sorted()
        return (parts + ["+\(h.extra)"]).joined(separator: "\u{1E}")
    }

    /// What a name's link rests on: the people it could mean, as the memory's trust sees them, with their facts (a
    /// new fact about a candidate is a reason to ask again).
    static func nameKnowledge(_ g: FactsGraph, _ mem: FactsMemory, _ surface: String) -> String {
        g.byName(surface, onlyTrusted: mem.trusted).map { summary(g, $0, trusted: mem.trusted, predicates: nil) }.sorted()
            .joined(separator: "\u{1E}")
    }

    /// What `facts_asked` keeps of a knowledge string: a digest, since reconciliation only compares them.
    static func digest(_ knowledge: String) -> String {
        SHA256.hash(data: Data(knowledge.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func peopleGroup(_ group: String, _ registry: FactsRegistry) -> Bool {
        registry.groupPredicates(group).contains { registry.kindOf($0) == FactsValidator.personKind }
    }

    // MARK: Recording what a reading was asked

    /// Called by `FactStore.apply` on the graph it leaves. A whole reading replaces this version and group's records;
    /// a partial one updates the phrases and names it re-asked. Decisions made now record the knowledge they rest on.
    static func recordAsked(_ db: Database, graph g: FactsGraph, memory fm: FactsMemory, version: Int, group: String,
                            phrases: [RolePhrase], scope: FactsScope, decisions: [String], readKey: String = "",
                            now: Date) throws {
        // Knowledge is stored as its digest (it's only compared): no name or label of anyone outlives a purge here.
        func put(_ kind: String, _ key: String, _ knowledge: String) throws {
            try db.execute(sql: """
                INSERT OR REPLACE INTO facts_asked (memory_id, memory_version, call_group, mention_kind, mention_key, knowledge, asked_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [fm.id, version, group, kind, key, kind == "read" ? knowledge : digest(knowledge), now])
        }
        try put("read", "", readKey)
        let roles: Set<Int>?, names: Set<String>?
        switch scope {
        case .full:
            try db.execute(sql: "DELETE FROM facts_asked WHERE memory_id = ? AND memory_version = ? AND call_group = ? AND mention_kind IN ('phrase','name')",
                           arguments: [fm.id, version, group])
            roles = nil
            names = nil
        case let .partial(r, n):
            roles = r
            names = n
        }
        for ph in phrases {
            let start = FactStore.scalarOffset(fm.text, utf16: ph.start)
            if let roles, !roles.contains(start) { continue }
            try put("phrase", String(start), roleKnowledge(g, fm, ph))
        }
        if peopleGroup(group, g.registry) {
            var asked = Set<String>()
            for (key, _) in g.names where key.memoryID == fm.id {
                let f = FactsText.fold(key.surface)
                if let names, !names.contains(f) { continue }
                asked.insert(f)
                try put("name", f, nameKnowledge(g, fm, key.surface))
            }
            for f in names ?? [] where !asked.contains(f) { try put("name", f, nameKnowledge(g, fm, f)) }
        }
        for did in decisions {
            guard let d = try Row.fetchOne(db, sql: "SELECT quote, span_start FROM mention_decision WHERE id = ?", arguments: [did]),
                  let span = FactStore.locate(d["quote"], in: fm.text, near: d["span_start"]),
                  let ph = phrases.first(where: { $0.start == span.start }) else { continue }
            try put("decision", did, roleKnowledge(g, fm, ph))
        }
        // Records of decisions that are gone.
        try db.execute(sql: """
            DELETE FROM facts_asked WHERE memory_id = ? AND mention_kind = 'decision' AND mention_key NOT IN (SELECT id FROM mention_decision)
            """, arguments: [fm.id])
    }

    // MARK: Finding what's due

    /// Revalidates in code what can be, and returns what's due to be asked again, for every memory version a model has
    /// read (or only `memoryID`'s). In the caller's write transaction.
    /// `sendable`: the limit the model that will read works under (a cloud model's): knowledge is compared on the graph
    /// it may see, so what's above the limit selects no memory for a call, and a memory above it isn't reconciled.
    /// `uses`: what's on (§11.10). A group with no recorded predicate (no model, or switched off) has nothing due, and
    /// a predicate that isn't recorded has no phrase to ask about.
    static func reconcile(_ db: Database, only memoryID: String? = nil, registry: FactsRegistry,
                          userAliases: [String] = [], uses: FactsUses, sendable: CloudLimit? = nil) throws -> [(key: Key, due: Due)] {
        var g = try FactStore.load(db, registry: registry, userAliases: userAliases, uses: uses, sendable: sendable).graph
        // Memory versions a model read, per group (a memory the model couldn't read is never reconciled).
        var reads: [String: [String]] = [:]                 // memory → groups
        var order: [String] = []                            // memories in the order they were added
        for r in try Row.fetchAll(db, sql: """
            SELECT a.memory_id, a.call_group, m.sensitivity FROM facts_asked a JOIN memory m ON m.id = a.memory_id
            WHERE a.mention_kind = 'read' AND a.memory_version = m.version AND m.status IN ('active','archived')
              AND (?1 IS NULL OR a.memory_id = ?1)
            ORDER BY m.seq, a.call_group
            """, arguments: [memoryID]) {
            if let sendable, !(Sensitivity(rawValue: r["sensitivity"]).map(sendable.allows) ?? false) { continue }
            if uses.predicates(.recorded, group: r["call_group"]).isEmpty { continue }
            if reads[r["memory_id"]] == nil { order.append(r["memory_id"]) }
            reads[r["memory_id"], default: []].append(r["call_group"])
        }
        var asked: [String: String] = [:]                   // memory, group, kind, key → knowledge
        func k(_ m: String, _ grp: String, _ kind: String, _ key: String) -> String { [m, grp, kind, key].joined(separator: "\u{1F}") }
        for r in try Row.fetchAll(db, sql: """
            SELECT a.* FROM facts_asked a JOIN memory m ON m.id = a.memory_id
            WHERE a.memory_version = m.version AND a.mention_kind != 'read' AND (?1 IS NULL OR a.memory_id = ?1)
            """, arguments: [memoryID]) {
            asked[k(r["memory_id"], r["call_group"], r["mention_kind"], r["mention_key"])] = r["knowledge"]
        }
        // A memory read with nothing learned from it isn't in the graph `load` builds; reconciliation still sees it.
        func withReadMemories(_ g: inout FactsGraph) throws {
            for mid in order where g.memories[mid] == nil {
                guard let r = try Row.fetchOne(db, sql: """
                    SELECT title, body, created_at, COALESCE(original_source, source) AS source, trust FROM memory WHERE id = ?
                    """, arguments: [mid]) else { continue }
                g.memories[mid] = FactsMemory(id: mid, text: FactStore.text(title: r["title"], body: r["body"]),
                                              written: FactStore.writtenDay(r["created_at"]), source: FactStore.source(r["source"]),
                                              trusted: (r["trust"] as String) == "trusted")
            }
        }
        try withReadMemories(&g)
        var due: [Key: Due] = [:]
        var revalidated = false
        // Under a limit, a decision is revalidated only if the graph it was compared on has every holder the whole
        // graph has: otherwise the whole graph would get a firm link made without someone (it stays invalidated, and
        // code resolves the phrase).
        let whole = try sendable.map { _ in try FactStore.load(db, registry: registry, userAliases: userAliases, uses: uses).graph }
        func sawEveryHolder(_ mem: FactsMemory, _ ph: RolePhrase) -> Bool {
            guard let whole else { return true }
            let (d, w) = whole.asOf(mem, ph), (sd, sw) = g.asOf(mem, ph)
            let all = whole.holders(ph, asOf: d, written: w), seen = g.holders(ph, asOf: sd, written: sw)
            // Named holders, and those a count says exist ("my three sisters").
            return Set(all.holders.map(\.entity.id)).isSubset(of: Set(seen.holders.map(\.entity.id))) && all.extra <= seen.extra
        }

        // Decisions 13a.1 invalidated (a dependency changed): revalidated in code when what they rest on stands.
        var dependencies: [String: [Row]] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT * FROM decision_dependency") { dependencies[r["decision_id"], default: []].append(r) }
        for d in try Row.fetchAll(db, sql: """
            SELECT d.* FROM mention_decision d JOIN memory m ON m.id = d.memory_id
            WHERE d.source = 'model' AND d.outcome != 'unknown' AND d.memory_version = m.version AND m.status IN ('active','archived')
              AND d.call_group IS NOT NULL AND (?1 IS NULL OR d.memory_id = ?1)
            ORDER BY m.seq, d.rowid
            """, arguments: [memoryID]) {
            let did: String = d["id"], mid: String = d["memory_id"], group: String = d["call_group"]
            guard reads[mid]?.contains(group) == true, let mem = g.memories[mid] else { continue }
            let stale = try (d["invalidated_at"] as Date?) != nil || (dependencies[did] ?? []).contains { dep in
                try FactStore.currentVersion(db, kind: dep["kind"], ref: dep["ref_id"]) != (dep["ref_version"] as String)
            }
            guard stale else { continue }
            let phrases = g.rolePhrases(mem.text, predicates: Set(registry.groupPredicates(group)))
            guard let span = FactStore.locate(d["quote"], in: mem.text, near: d["span_start"]),
                  let ph = phrases.first(where: { $0.start == span.start }) else { continue }
            // A `named` decision rests on the name the memory pairs with the phrase, not on who else holds the role.
            let entity: String? = d["entity_id"]
            let named = (d["basis"] as String) == LinkBasis.named.rawValue && entity.map { e in
                g.names.contains { $0.key.memoryID == mid && $0.value.entity == e && $0.value.basis == .named }
            } == true
            let knowledge = digest(roleKnowledge(g, mem, ph))
            if named || (asked[k(mid, group, "decision", did)] == knowledge && sawEveryHolder(mem, ph)) {
                try revalidate(db, decision: d, predicate: ph.predicate, roster: (dependencies[did] ?? []).compactMap { dep in
                    (dep["kind"] as String) == "entity" ? dep["ref_id"] as String : nil
                })
                revalidated = true
            } else if asked[k(mid, group, "phrase", String(d["span_start"] as Int))] != knowledge {
                // (Knowledge unchanged but a holder the reading couldn't see: it stays invalidated, not asked again.)
                // Asked again unless it already was, knowing what's known now (an answer validation dropped).
                due[Key(memoryID: mid, group: group), default: Due()].roles.insert(d["span_start"])
            }
        }
        if revalidated {
            g = try FactStore.load(db, registry: registry, userAliases: userAliases, uses: uses, sendable: sendable).graph
            try withReadMemories(&g)
        }

        for mid in order {
            guard let mem = g.memories[mid], let groups = reads[mid] else { continue }
            for group in groups {
                let key = Key(memoryID: mid, group: group)
                // Role phrases left undecided (or decided as the group) whose knowledge changed since they were asked.
                for ph in g.rolePhrases(mem.text, predicates: Set(registry.groupPredicates(group))) {
                    let start = FactStore.scalarOffset(mem.text, utf16: ph.start)
                    if let dec = g.decisions[FactsGraph.DecisionKey(memoryID: mid, start: ph.start)], dec.basis != .group { continue }
                    if due[key]?.roles.contains(start) == true { continue }
                    let (d, w) = g.asOf(mem, ph)
                    let h = g.holders(ph, asOf: d, written: w, rejected: g.rejections[FactsGraph.DecisionKey(memoryID: mid, start: ph.start)] ?? [])
                    guard h.holders.count + h.extra > 1 else { continue }
                    if asked[k(mid, group, "phrase", String(start))] != digest(roleKnowledge(g, mem, ph)) {
                        due[key, default: Due()].roles.insert(start)
                    }
                }
                // Names that read as ambiguous (the model left them so, or a namesake came since the reading) whose
                // candidates changed since they were asked (the alias-evidence reopen of §11.4).
                guard peopleGroup(group, registry) else { continue }
                for (nk, link) in g.names where nk.memoryID == mid && link.basis == .ambiguous {
                    let f = FactsText.fold(nk.surface)
                    if asked[k(mid, group, "name", f)] != digest(nameKnowledge(g, mem, nk.surface)) {
                        due[key, default: Due()].names.insert(f)
                    }
                }
            }
        }
        return order.flatMap { mid in
            (reads[mid] ?? []).compactMap { grp in due[Key(memoryID: mid, group: grp)].flatMap { $0.isEmpty ? nil : (Key(memoryID: mid, group: grp), $0) } }
        }
    }

    /// Re-records a decision's dependencies at their current versions and makes it count again.
    static func revalidate(_ db: Database, decision d: Row, predicate: String, roster: [String]) throws {
        let did: String = d["id"]
        var entities = Set(roster)
        if let e: String = d["entity_id"] { entities.insert(e) }
        try db.execute(sql: "DELETE FROM decision_dependency WHERE decision_id = ?", arguments: [did])
        try FactStore.recordDependencies(db, decisionID: did, memoryID: d["memory_id"], version: d["memory_version"],
                                         predicate: predicate, entities: entities)
        try db.execute(sql: "UPDATE mention_decision SET invalidated_at = NULL WHERE id = ?", arguments: [did])
        try FactStore.bumpRevision(db, reconcile: false)
    }

    /// The sweep: revalidates what it can and queues a job for each memory version and group with something due.
    /// Returns how many it queued.
    @discardableResult
    static func sweep(_ db: Database, registry: FactsRegistry, userAliases: [String] = [], uses: FactsUses,
                      sendable: CloudLimit? = nil, now: Date) throws -> Int {
        let due = try reconcile(db, registry: registry, userAliases: userAliases, uses: uses, sendable: sendable)
        for (key, _) in due {
            guard let id = UUID(uuidString: key.memoryID),
                  let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [key.memoryID]) else { continue }
            try ProcessingQueue.enqueueFacts(db, memoryID: id, version: version, group: key.group, reason: .reconcile, now: now)
        }
        return due.count
    }
}
