import Foundation
import FunesProtocol
import GRDB
@testable import FunesCore

/// Phase 13b's search gate harness (acceptance: "Search with links on"): the spike's search fixtures
/// (`spikes/people/fixtures/search-vault*.json`, `work-vault.json`) in a fresh vault, with learned facts from the spike's
/// recorded r3 reads (`results-search/backfill-*-r3.json`, `work-extract-fixture.jsonl`) applied through
/// `FactStore.apply` as per-memory extractions, so the store holds what `apply` writes and Swift resolves every link it
/// resolves in the app (only the model's own decisions come from the file). Then every query, plain and with links.
enum SearchGate {
    // MARK: Fixtures

    struct VaultFile: Decodable {
        struct M: Decodable {
            let id: String, title: String, body: String, kind: String, categories: [String], sensitivity: String
            let createdAt: String
            let source: String?
            let trust: String?
        }
        let memories: [M]
    }

    struct QueryFile: Decodable {
        struct Q: Decodable {
            let id: String
            let set: String?
            let kind: String?
            let query: String
            let targets: [String]?
            let decoys: [String]?
            let family: String?
        }
        let queries: [Q]
    }

    struct Backfill: Decodable {
        struct P: Decodable { let id: String; let name: String?; let aliases: [String]; let group: [String?]?; let count: Int? }
        struct R: Decodable {
            let person: String, type: String, label: String?, status: String?
            let negated: Bool
            let evidence: [String]
            let stating: [String]?
        }
        struct L: Decodable {
            let memory: String, kind: String, start: Int?, surface: String, person: String?, basis: String
            let candidates: [String]?
        }
        let people: [P]
        let relations: [R]
        let links: [L]
    }

    struct WorkLine: Decodable {
        struct Job: Decodable {
            let org: String, role: String?, status: String?, start: String?, end: String?, before: String?, after: String?
            let kind: String?
            let also_called: String?
            let quote: String
        }
        let id: String
        let jobs: [Job]?
    }

    static var repo: URL { Fixtures.repoRoot }
    static func spike(_ path: String) -> URL { repo.appending(path: "spikes/people/" + path) }

    static func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = s.count > 10 ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd"
        return f.date(from: String(s.prefix(19))) ?? t0
    }

    /// The fixture's memories in a fresh vault, at their written dates, with their source and trust. Fixture id → id.
    static func vault(_ file: URL) throws -> (TestVault, [String: UUID], [String: String]) {
        let v = try TestVault()
        let vf = try JSONDecoder().decode(VaultFile.self, from: Data(contentsOf: file))
        var ids: [String: UUID] = [:], texts: [String: String] = [:]
        try v.store.writer.write { db in
            for (i, m) in vf.memories.enumerated() {
                let id = UUID()
                let created = date(m.createdAt).addingTimeInterval(Double(i))
                _ = try MemoryStore.insert(db, MemoryDraft(title: m.title, body: m.body, kind: MemoryKind(rawValue: m.kind) ?? .fact,
                                                           categoryKeys: m.categories, sensitivity: Sensitivity(name: m.sensitivity) ?? .low),
                                           actor: .user, now: created, id: id)
                let source = m.source.flatMap(MemorySource.init(rawValue:)) ?? .manual
                let trusted = (m.trust ?? "trusted") == "trusted"
                try db.execute(sql: "UPDATE memory SET source = ?, trust = ? WHERE id = ?",
                               arguments: [source.rawValue, trusted ? "trusted" : "untrusted", id.db])
                ids[m.id] = id
                texts[m.id] = FactStore.text(title: m.title, body: m.body)
            }
        }
        return (v, ids, texts)
    }

    // MARK: Learned facts from the recorded reads

    /// The people reads as per-memory extractions, in written order: the names a memory uses (name links), the facts
    /// it states or mentions (relations, quoted by the name or role phrase it uses), and the model's role decisions
    /// (`named`, `context`, `group`); everything code decides (`stated_unique`, `sole_known`, candidates) is Swift's.
    static func applyPeople(_ v: TestVault, ids: [String: UUID], texts: [String: String], backfill: URL) throws {
        let b = try JSONDecoder().decode(Backfill.self, from: Data(contentsOf: backfill))
        let reg = FactsRegistry.bundled
        let people = Dictionary(uniqueKeysWithValues: b.people.map { ($0.id, $0) })
        let group = reg.predicates.first { $0.objectKind == FactsValidator.personKind }!.callGroup
        let preds = Set(reg.predicates.filter { $0.callGroup == group }.map(\.id))
        let probe = FactsGraph(registry: reg, uses: .everyDeclared(reg))
        let order = try v.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM memory ORDER BY created_at, seq").compactMap { $0["id"] as String? }
        }
        let fixtureOf = Dictionary(uniqueKeysWithValues: ids.map { ($1.db, $0) })
        var storeID: [String: String] = [:]           // spike person → entity id
        for mid in order {
            guard let fid = fixtureOf[mid], let text = texts[fid] else { continue }
            let links = b.links.filter { $0.memory == fid }
            var x = FactsExtraction()
            var roster: [String: String] = [:]
            func rostered(_ p: String) throws -> String? {
                guard let e = storeID[p] else { return nil }
                roster[e] = try v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [e]) }
                return e
            }
            var named: [String: String] = [:]           // spike person → surface
            for l in links where l.kind == "name" {
                if let p = l.person, people[p]?.name != nil {
                    x.people.append(ExtractedPerson(name: l.surface, quote: l.surface))
                    named[p] = l.surface
                } else if l.basis == "ambiguous" {
                    x.people.append(ExtractedPerson(name: l.surface, quote: l.surface, person: "ambiguous"))
                }
            }
            let phrases = probe.rolePhrases(text, predicates: preds)
            let mine = b.relations.filter { r in
                let about = r.evidence.contains(fid) || (r.stating ?? []).contains(fid)
                return !r.negated && preds.contains(r.type) && about
            }
            for r in mine {
                guard let p = people[r.person], p.name != nil else { continue }
                let stating = (r.stating ?? []).contains(fid)
                let status = stating ? FactAssertion.Status(rawValue: r.status ?? "unknown") ?? .unknown : .unknown
                if let surface = named[r.person] {
                    x.facts.append(ExtractedFact(predicate: r.type, name: surface, label: r.label, quote: surface, status: status))
                } else if let role = links.first(where: { $0.kind == "role" && $0.person == r.person }), let e = try rostered(r.person) {
                    x.facts.append(ExtractedFact(predicate: r.type, name: p.name!, entity: e, label: r.label, quote: role.surface, status: status))
                }
            }
            for l in links where l.kind == "role" && ["named", "context", "group"].contains(l.basis) {
                guard let i = phrases.firstIndex(where: { $0.start == l.start || $0.surface == l.surface }) else { continue }
                if l.basis == "group" || (l.person.flatMap { people[$0]?.name } == nil) {
                    x.roles.append(ExtractedRole(phrase: i, refersTo: "group"))
                } else if let p = l.person, let surface = named[p] {
                    x.roles.append(ExtractedRole(phrase: i, refersTo: "name:" + surface))
                } else if let p = l.person, let e = try rostered(p) {
                    x.roles.append(ExtractedRole(phrase: i, refersTo: e))
                }
            }
            x.roster = roster
            guard let m = try v.store.writer.read({ db in try MemoryStore.fetch(db, id: UUID(uuidString: mid)!) }) else { continue }
            try v.store.writer.write { db in
                try FactStore.apply(db, memoryID: mid, version: m.version, extraction: x, callGroup: group, registry: reg,
                                    uses: .everyDeclared(reg), now: m.createdAt)
            }
            // Which entity each spike person became.
            for (p, surface) in named where storeID[p] == nil {
                storeID[p] = try v.store.writer.read { db in
                    try String.fetchOne(db, sql: """
                        SELECT a.entity_id FROM alias_evidence ev JOIN entity_alias a ON a.id = ev.alias_id
                        WHERE ev.memory_id = ? AND a.alias = ? LIMIT 1
                        """, arguments: [mid, surface])
                }
            }
        }
    }

    /// The work reads (Spike H2's work extraction) as works-at facts per memory (a client stays a client).
    static func applyWork(_ v: TestVault, ids: [String: UUID], jsonl: URL) throws {
        let reg = FactsRegistry.bundled
        let dated = reg.timelinePredicates[0]
        let p = reg.predicate(dated)!
        let client = reg.predicates.first { !$0.uses.contains(FactsUse.linked.rawValue) }?.id
        let slot = p.slot!
        let slotValues = Set(p.qualifiers[slot]?.values ?? [])
        for line in try String(contentsOf: jsonl, encoding: .utf8).split(separator: "\n") {
            let w = try JSONDecoder().decode(WorkLine.self, from: Data(line.utf8))
            guard let id = ids[w.id], let jobs = w.jobs, !jobs.isEmpty else { continue }
            var facts: [ExtractedFact] = []
            for j in jobs {
                let kind = j.kind ?? "employee"
                let pred = kind == "client" ? (client ?? dated) : dated
                if pred == dated, !slotValues.contains(kind) { continue }
                facts.append(ExtractedFact(predicate: pred, name: j.org, quote: j.quote,
                                           status: FactAssertion.Status(rawValue: j.status ?? "unknown") ?? .unknown,
                                           start: j.start, end: j.end, precededBy: j.before, followedBy: j.after,
                                           alsoCalled: j.also_called, qualifiers: pred == dated ? [slot: kind] : [:]))
            }
            guard let m = try v.store.writer.read({ db in try MemoryStore.fetch(db, id: id) }) else { continue }
            try v.store.writer.write { db in
                try FactStore.apply(db, memoryID: id.db, version: m.version, extraction: FactsExtraction(facts: facts),
                                    callGroup: p.callGroup, registry: reg, uses: .everyDeclared(reg), now: m.createdAt)
            }
        }
    }

    // MARK: Ranks

    struct RankRow: Sendable {
        var id: String
        var query: String
        var plain: Int?
        var links: Int?
        var targets: Int
        var admitted: Int
        var demoted: Int
    }

    struct Tally: CustomStringConvertible {
        var queries = 0, targets = 0, worse = 0, outOfTop3 = 0, outOfTop10 = 0, better = 0, admitted = 0, demoted = 0, matched = 0
        var description: String {
            "\(queries) queries, \(targets) targets: worse \(worse) · out of top 3 \(outOfTop3) · out of top 10 \(outOfTop10) · better \(better); "
                + "matched \(matched) queries, \(admitted) admitted, \(demoted) demoted"
        }
        var passes: Bool { worse == 0 && outOfTop3 == 0 && outOfTop10 == 0 }
    }

    /// Every query with targets, plain and with links: each target's rank both ways.
    static func compare(_ search: SearchService, facts: FactsSearchConfig, queries: [QueryFile.Q], ids: [String: UUID],
                        now: Date) async throws -> (Tally, [String]) {
        var t = Tally(), lines: [String] = []
        let fixture = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
        // The same indexes, with learned facts on: a second service, so the facts index stays cached between queries.
        let withFacts = SearchService(store: search.store, indexer: search.indexer)
        withFacts.secondIndex = search.secondIndex
        withFacts.facts = facts
        search.facts = nil
        for q in queries {
            let plain = try await search.vaultSearch(q.query, filter: MemoryFilter(status: .active), now: now).map(\.memoryID)
            let hits = try await withFacts.vaultSearch(q.query, filter: MemoryFilter(status: .active), now: now)
            let linked = hits.map(\.memoryID)
            let admitted = hits.filter { $0.admission != nil }.count, demoted = hits.filter(\.demoted).count
            t.admitted += admitted
            t.demoted += demoted
            if admitted + demoted > 0 { t.matched += 1 }
            guard let targets = q.targets, !targets.isEmpty else { continue }
            t.queries += 1
            for target in targets {
                guard let id = ids[target] else { continue }
                t.targets += 1
                let a = plain.firstIndex(of: id).map { $0 + 1 }, b = linked.firstIndex(of: id).map { $0 + 1 }
                if (b ?? 9999) > (a ?? 9999) { t.worse += 1 }
                if (b ?? 9999) < (a ?? 9999) { t.better += 1 }
                if (a ?? 99) <= 3 && (b ?? 99) > 3 { t.outOfTop3 += 1 }
                if (a ?? 99) <= 10 && (b ?? 99) > 10 { t.outOfTop10 += 1 }
                if a != b {
                    lines.append("- \(q.id) \(target): \(a.map(String.init) ?? "–") → \(b.map(String.init) ?? "–")"
                                 + " (top 3 with links: \(linked.prefix(3).compactMap { fixture[$0] }.joined(separator: ", ")))")
                }
            }
        }
        return (t, lines)
    }

    static func queries(_ file: URL) throws -> [QueryFile.Q] {
        try JSONDecoder().decode(QueryFile.self, from: Data(contentsOf: file)).queries
    }

    /// The shipped uses: the bundled records for the Claude plan's Claude Haiku 5.5 in every call group.
    static var shipped: FactsSearchConfig {
        let haiku = FactsEngine(model: "claude-code/claude-haiku-5-5", adapter: "claude-code/1;effort=low")
        return FactsSearchConfig(engines: Dictionary(uniqueKeysWithValues: FactsRegistry.bundled.callGroups.keys.map { ($0, haiku) }),
                                 userAliases: ["Sam"], cloudLimit: .upTo(.internal))
    }

    /// Every declared use on (what the next records would turn on): exercises works at and the timeline.
    static var everyDeclared: FactsSearchConfig {
        var c = shipped
        c.measuredUses = .everyDeclared(.bundled)
        return c
    }
}
