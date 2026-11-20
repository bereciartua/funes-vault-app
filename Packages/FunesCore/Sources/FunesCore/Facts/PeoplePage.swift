import Foundation
import GRDB

extension PeopleRead {
    // MARK: An entity's page

    func page(_ db: Database, id: String) throws -> PeopleEntityPage? {
        guard let entry = entry(id) else { return nil }
        let g = graph
        let linked = Set(uses.predicates(.linked))
        let entityName = entry.name ?? entry.group?.attribute ?? ""

        // Aliases, each with its memories; yours are the ones you typed or confirmed.
        let members = Set(columns.keys.filter { canonical($0) == id })
        var yoursAliases = Set<String>()
        if !members.isEmpty {
            let marks = databaseQuestionMarks(count: members.count)
            for r in try Row.fetchAll(db, sql: "SELECT alias, normalized FROM entity_alias WHERE entity_id IN (\(marks)) AND (manual = 1 OR confirmed = 1)",
                                      arguments: StatementArguments(Array(members))) {
                yoursAliases.insert((r["alias"] as String?) ?? (r["normalized"] as String))
            }
        }
        let aliases = (g.entities[id]?.aliases ?? []).sorted().map { a in
            PeopleEntityPage.Alias(alias: a, memories: aliasMemories[id]?[a]?.count ?? 0, yours: yoursAliases.contains(a))
        }.sorted { $0.memories != $1.memories ? $0.memories > $1.memories : $0.alias < $1.alias }

        // About you.
        let facts = self.facts(of: id).map { f -> PeopleEntityPage.Fact in
            let memoryRows = f.assertions.filter { !$0.fromUser }
            let basis: PeopleEntityPage.Fact.Basis =
                memoryRows.contains(where: { $0.trusted && $0.states }) ? .named
                : f.assertions.contains(where: \.fromUser) ? .confirmed
                : memoryRows.contains(where: \.trusted) ? .context : .untrusted
            return PeopleEntityPage.Fact(factID: factID(f) ?? "", predicate: f.predicate, attribute: attribute(f.predicate, label: f.label ?? f.cls),
                                         label: f.label, status: status(f), basis: basis,
                                         recordedOnly: !uses.isOn(f.predicate, .linked), episodes: timelineEpisodes(f),
                                         dated: declaresTimeline(f.predicate))
        }

        // Memories: every one linked to it, with its why line where a linked predicate explains the link.
        var rows: [PeopleEntityPage.MemoryRow] = []
        for (mid, ls) in links {
            let mine = ls.filter { $0.entity == id }
            guard !mine.isEmpty, let uuid = UUID(uuidString: mid), let t = titles[mid] else { continue }
            let best = mine.max { FactsSearchIndex.strength($0.basis) < FactsSearchIndex.strength($1.basis) }!
            var line: WhyLine?
            let notName = WhyLine.NotName(memoryID: uuid, entity: id, name: entityName)
            let role = mine.first { $0.kind == .role && $0.predicate.map(linked.contains) == true }
            let statement = mine.first { $0.kind == .fact && $0.predicate.map(linked.contains) == true }
            // A memory that names it needs no role line: its statement's, if it states the fact, else none.
            let names = mine.contains { $0.kind == .name }
            if let l = role, !names {
                let f = self.facts(of: id).first { $0.predicate == l.predicate }
                if g.entities[id]?.name == nil, let group = g.entities[id]?.group {
                    line = WhyLine(form: .group(attribute: attribute(group.predicate, label: group.cls ?? l.word)), basis: .link(.group),
                                   label: group.cls ?? l.word ?? "", untrusted: l.basis == .untrusted, notName: nil, notThis: nil)
                } else {
                    line = WhyLine(form: .role(surface: l.surface, name: entityName), basis: .link(l.basis),
                                   label: f?.label ?? f?.cls ?? l.word ?? "", untrusted: l.basis == .untrusted,
                                   notName: notName, notThis: f.flatMap(factID))
                }
            } else if let l = statement, let f = self.facts(of: id).first(where: { $0.predicate == l.predicate }) {
                let label = f.label ?? f.cls ?? noun(f.predicate)
                line = WhyLine(form: .name(name: entityName, attribute: attribute(f.predicate, label: f.label ?? f.cls)),
                               basis: .link(l.basis), label: label, untrusted: l.basis == .untrusted, notName: notName,
                               notThis: factID(f))
            }
            rows.append(PeopleEntityPage.MemoryRow(memoryID: uuid, title: t.title, updatedAt: t.updatedAt, whyLine: line,
                                                   notName: notName, untrusted: best.basis == .untrusted))
        }
        rows.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.memoryID.uuidString < $1.memoryID.uuidString }

        let candidates = entries.filter { $0.id != id && $0.kind == entry.kind && $0.name != nil }
        return PeopleEntityPage(entry: entry, aliases: aliases, facts: facts, memories: rows,
                                corrections: try corrections(db, entity: id, members: members.union([id])),
                                mergeCandidates: candidates)
    }

    // MARK: Corrections

    private struct Piece {
        var group: String
        var at: Date
        var priority: Int
        var what: PeopleEntityPage.Correction.What
        var memory: String?
    }

    /// What you changed about an entity (it and everything merged into it, its facts found in the store whether or not
    /// they're shown), one entry per action, newest first.
    func corrections(_ db: Database, entity: String, members: Set<String>) throws -> [PeopleEntityPage.Correction] {
        let ms = Array(members)
        let marks = databaseQuestionMarks(count: ms.count)
        var factPredicate: [String: String] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT id, predicate FROM fact WHERE entity_id IN (\(marks))", arguments: StatementArguments(ms)) {
            factPredicate[r["id"]] = r["predicate"]
        }
        func attr(_ fid: String) -> String { factPredicate[fid].map { attribute($0, label: nil) } ?? "" }
        var pieces: [Piece] = []

        for o in try Row.fetchAll(db, sql: "SELECT * FROM manual_override ORDER BY created_at, rowid") {
            let kind: String = o["target_kind"], target: String = o["target_id"], field: String = o["field"]
            let value: String? = o["value"]
            let stamp: String = o["created_at"], at: Date = o["created_at"]
            func object() -> [String: Any] {
                guard let v = value, let d = v.data(using: .utf8) else { return [:] }
                return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            }
            var what: PeopleEntityPage.Correction.What?
            var priority = 5
            switch (kind, field) {
            case ("entity", "merged_into"):
                let into = FactStore.decodedString(value).map(canonical)
                if into == entity, !members.subtracting([entity]).isEmpty, members.contains(target) {
                    what = .mergedFrom(columns[target]?.name ?? name(target)); priority = 2
                }
            case ("entity", "not_same"):
                let other = FactStore.decodedString(value)
                if members.contains(target) { what = .notSame(other.flatMap(name)) }
                else if let other, canonical(other) == entity { what = .notSame(name(target)) }
            case ("entity", _) where members.contains(target):
                switch field {
                case "name": what = .renamed(FactStore.decodedString(value) ?? ""); priority = 3
                case "kind": what = .kind((object()["kind"] as? String) ?? ""); priority = 3
                case "deceased": what = .deceased(value == "true")
                case "hidden": what = .hidden(value == "true")
                case "created": what = nil
                default: what = .other
                }
            case ("alias", _):
                let owner = try String.fetchOne(db, sql: "SELECT entity_id FROM entity_alias WHERE id = ?", arguments: [target])
                if let owner, members.contains(owner) { what = .alias(FactStore.decodedString(value) ?? "") }
            case ("fact", "rejected") where factPredicate[target] != nil:
                what = (o["memory_id"] as String?) == nil ? .factRejected(attribute: attr(target)) : .linkRejected
                priority = (o["memory_id"] as String?) == nil ? 2 : 4
            case ("qualifier", "label") where factPredicate[target] != nil:
                what = .label(attribute: attr(target), label: FactStore.decodedString(value) ?? ""); priority = 3
            case ("order", "rejected"):
                let v = object()
                if [v["before"], v["after"]].contains(where: { ($0 as? String).map { factPredicate[$0] != nil } ?? false }) {
                    what = .orderRejected
                }
            case (_, _) where factPredicate[target] != nil:
                what = .other
            default: break
            }
            if let what { pieces.append(Piece(group: stamp, at: at, priority: priority, what: what, memory: o["memory_id"])) }
        }

        for d in try Row.fetchAll(db, sql: """
            SELECT outcome, entity_id, memory_id, created_at FROM mention_decision
            WHERE source = 'user' AND entity_id IN (\(marks))
            """, arguments: StatementArguments(ms)) {
            let outcome: String = d["outcome"]
            let what: PeopleEntityPage.Correction.What = outcome == "rejected" ? .linkRejected : .linkConfirmed
            pieces.append(Piece(group: d["created_at"], at: d["created_at"], priority: 4, what: what, memory: d["memory_id"]))
        }

        if !factPredicate.isEmpty {
            let fids = Array(factPredicate.keys)
            for r in try Row.fetchAll(db, sql: """
                SELECT id, fact_id, target_kind, asserted FROM fact_evidence
                WHERE source = 'user' AND fact_id IN (\(databaseQuestionMarks(count: fids.count))) ORDER BY rowid
                """, arguments: StatementArguments(fids)) {
                let a = FactStore.object(r["asserted"])
                let fid: String = r["fact_id"]
                if let retired = a["retired_at"] as? String {
                    // Listed under the To check answer that retired it, not under the action that wrote it.
                    pieces.append(Piece(group: retired, at: Date.fromDatabaseValue(retired.databaseValue) ?? .distantPast, priority: 5,
                                        what: .retired, memory: nil))
                    continue
                }
                let stamp = (a["at"] as? String) ?? ("row:" + (r["id"] as String))
                let at = (a["at"] as? String).flatMap { Date.fromDatabaseValue($0.databaseValue) } ?? .distantPast
                var what: PeopleEntityPage.Correction.What
                var priority = 3
                if (r["target_kind"] as String) == "order" {
                    what = .order(attribute: attr(fid))
                } else if a["created"] as? Bool == true {
                    what = .factAdded(attribute: attr(fid)); priority = 1
                } else if a["start"] != nil || a["end"] != nil {
                    what = .dates(attribute: attr(fid), start: a["start"] as? String, end: a["end"] as? String)
                } else if let st = (a["status"] as? String).flatMap(FactAssertion.Status.init) {
                    what = .status(attribute: attr(fid), st)
                } else {
                    what = .other; priority = 6
                }
                pieces.append(Piece(group: stamp, at: at, priority: priority, what: what, memory: nil))
            }
        }

        var groups: [String: [Piece]] = [:]
        for p in pieces { groups[p.group, default: []].append(p) }
        return groups.map { stamp, ps in
            let lead = ps.min { $0.priority < $1.priority }!
            let memory = ps.compactMap(\.memory).first
            return PeopleEntityPage.Correction(id: stamp, what: lead.what, memoryTitle: memory.flatMap { titles[$0]?.title },
                                               createdAt: ps.map(\.at).max() ?? .distantPast)
        }.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id > $1.id }
    }

    /// To check's answers that name no one: Skip and Someone Else.
    func answered(_ db: Database) throws -> [PeopleDirectory.Answered] {
        try Row.fetchAll(db, sql: """
            SELECT outcome, memory_id, quote, created_at FROM mention_decision
            WHERE source = 'user' AND outcome IN ('unknown','someone_else') AND quote IS NOT NULL ORDER BY created_at DESC, rowid DESC
            """).compactMap { d in
            guard let title = titles[d["memory_id"]]?.title else { return nil }
            return PeopleDirectory.Answered(group: d["created_at"], memoryTitle: title, surface: d["quote"],
                                            skipped: (d["outcome"] as String) == "unknown")
        }
    }
}
