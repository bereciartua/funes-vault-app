import Foundation
import FunesProtocol
import GRDB

/// What People & history refuses (04-ux-mac.md).
public enum PeopleError: Error, Equatable, Sendable {
    /// Kind ▾: the entity holds a fact whose predicate is about another kind ("your sister" can't be an organization).
    case kindConflict
    case notFound
    /// A date Funes can't read: a year, a month or a day ("2019", "2019-03", "2019-03-15").
    case badDate
}

/// A manual entry from **+ ▾** or Relation… (04-ux-mac.md ▸ Manual entry).
public struct PeopleManualEntry: Sendable, Equatable {
    public var kind: String
    public var name: String
    /// The fact about you, if any, and your word for it.
    public var predicate: String?
    public var label: String?
    /// As you wrote them: "2019", "2019-03", "2019-03-15".
    public var start: String?
    public var end: String?
    public var status: FactAssertion.Status
    public var sensitivity: Sensitivity

    public init(kind: String, name: String, predicate: String? = nil, label: String? = nil, start: String? = nil,
                end: String? = nil, status: FactAssertion.Status = .unknown, sensitivity: Sensitivity = .internal) {
        self.kind = kind
        self.name = name
        self.predicate = predicate
        self.label = label
        self.start = start
        self.end = end
        self.status = status
        self.sensitivity = sensitivity
    }
}

/// How you answered an unsettled role phrase in To check.
public enum PeopleLinkAnswer: Sendable, Equatable {
    case entity(String)
    case someoneElse
    case skip
}

/// People & history's actions (04-ux-mac.md, FR-F-07, memory processing §11.8). Each is one transaction whose rows
/// share one stamp, so Undo takes back the whole action; each records `facts_corrected` with counts only. A
/// correction's sensitivity is the highest behind what it corrects (memory evidence and your rows), Internal when
/// nothing is; a manual entry takes the level you picked.
extension VaultStore {
    private func corrected(_ activity: any ActivityRecorder, _ now: Date, _ counts: [String: Int]) {
        activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "facts_corrected", counts: counts))
    }

    /// Rename…: your name for it wins over the names memories give (kept as an alias too).
    public func renameEntity(_ id: String, to name: String, activity: any ActivityRecorder, now: Date = Date()) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try writer.write { db in
            try FactStore.requireEntity(db, id)
            try FactStore.override(db, targetKind: "entity", targetID: id, field: "name", value: name,
                                   sensitivity: try FactStore.level(db, entities: [id]), now: now)
        }
        corrected(activity, now, ["entities": 1])
    }

    /// Kind ▾: the entity's kind changes, its aliases are normalised for the new kind, and an override records the
    /// change (with the old kind, for Undo). Refused while it holds a fact about another kind of thing.
    public func setEntityKind(_ id: String, to kind: String, registry: FactsRegistry = .bundled, activity: any ActivityRecorder,
                              now: Date = Date()) throws {
        guard registry.kinds[kind] != nil else { return }
        try writer.write { db in
            guard let old = try String.fetchOne(db, sql: "SELECT kind FROM entity WHERE id = ?", arguments: [id]) else { throw PeopleError.notFound }
            guard old != kind else { return }
            let merged = try FactStore.mergedInto(db)
            let members = try String.fetchAll(db, sql: "SELECT id FROM entity WHERE is_you = 0").filter { FactStore.canonical($0, merged) == id }
            let marks = databaseQuestionMarks(count: members.count)
            _ = marks
            let groups = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entity WHERE id = ? AND group_predicate IS NOT NULL", arguments: [id]) ?? 0
            guard groups == 0, try FactStore.liveFactPredicates(db, entity: id).allSatisfy({ registry.kindOf($0) == kind }) else {
                throw PeopleError.kindConflict
            }
            try FactStore.changeKind(db, entities: members, to: kind, registry: registry, now: now)
            try FactStore.override(db, targetKind: "entity", targetID: id, field: "kind", value: ["kind": kind, "previous_kind": old],
                                   sensitivity: try FactStore.level(db, entities: [id]), now: now)
        }
        corrected(activity, now, ["entities": 1])
    }

    /// Mark as Deceased, or Not Deceased (a memory may say so wrongly).
    public func setDeceased(_ id: String, _ deceased: Bool, activity: any ActivityRecorder, now: Date = Date()) throws {
        try writer.write { db in
            try FactStore.requireEntity(db, id)
            try FactStore.override(db, targetKind: "entity", targetID: id, field: "deceased", value: deceased,
                                   sensitivity: try FactStore.level(db, entities: [id]), now: now)
        }
        corrected(activity, now, ["entities": 1])
    }

    /// Merge With…: `other` becomes part of `into` (one entity, one fact per predicate). Kept as your correction, so a
    /// re-read never undoes it.
    public func mergeEntity(_ other: String, into: String, activity: any ActivityRecorder, now: Date = Date()) throws {
        guard other != into else { return }
        try writer.write { db in
            try FactStore.requireEntity(db, other)
            try FactStore.requireEntity(db, into)
            try FactStore.override(db, targetKind: "entity", targetID: other, field: "merged_into", value: into,
                                   sensitivity: try FactStore.level(db, entities: [other, into]), now: now)
        }
        corrected(activity, now, ["entities": 2])
    }

    /// Not the Same (To check): never suggested together again.
    public func markNotSame(_ a: String, _ b: String, activity: any ActivityRecorder, now: Date = Date()) throws {
        _ = try writer.write { db in
            try FactStore.override(db, targetKind: "entity", targetID: a, field: "not_same", value: b,
                                   sensitivity: try FactStore.level(db, entities: [a, b]), now: now)
        }
        corrected(activity, now, ["entities": 2])
    }

    /// Hide / Show: the list only (search and answers are unchanged). An override, so it follows merges and stays with
    /// a tombstone; it changes nothing a reading sees, so no reconciliation sweep.
    public func setHidden(_ id: String, _ hidden: Bool, now: Date = Date()) throws {
        try writer.write { db in
            try FactStore.requireEntity(db, id)
            try db.execute(sql: """
                INSERT INTO manual_override (id, target_kind, target_id, field, value, sensitivity, created_at, updated_at)
                VALUES (?, 'entity', ?, 'hidden', ?, ?, ?, ?)
                """, arguments: [UUID().db, id, hidden ? "true" : "false", try FactStore.level(db, entities: [id]), now, now])
            try FactStore.bumpRevision(db, reconcile: false)
        }
    }

    /// Relation…: the predicate and your word for it. The same predicate takes your label; another one is Not this on
    /// the old fact and a fact of yours with the new one, in one action. With no fact yet, a fact of yours.
    public func setRelation(entity: String, predicate: String, label: String?, replacing old: String?,
                            registry: FactsRegistry = .bundled, activity: any ActivityRecorder, now: Date = Date()) throws {
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        try writer.write { db in
            try FactStore.requireEntity(db, entity)
            // As private as anything behind the entity or the fact it replaces (a label carried over included).
            let level = try FactStore.level(db, entities: [entity], facts: old.map { [$0] } ?? [])
            if let old, let row = try Row.fetchOne(db, sql: "SELECT predicate FROM fact WHERE id = ?", arguments: [old]),
               (row["predicate"] as String) == predicate {
                // You're saying it: a row of yours (so it stays yours whatever is qualified), and your word.
                try FactStore.addUserEvidence(db, factID: old, asserted: [:], sensitivity: level, now: now)
                if let label {
                    try FactStore.override(db, targetKind: "qualifier", targetID: old, field: "label", value: label, sensitivity: level, now: now)
                }
                return
            }
            guard registry.kindOf(predicate) == (try String.fetchOne(db, sql: "SELECT kind FROM entity WHERE id = ?", arguments: [entity])) else {
                throw PeopleError.kindConflict
            }
            if let old { try FactStore.rejectFactEverywhere(db, factID: old, now: now) }
            let fid = try FactStore.addYourFact(db, predicate: predicate, entityID: entity, asserted: [:], sensitivity: level,
                                                registry: registry, now: now).fact
            if let label {
                try FactStore.override(db, targetKind: "qualifier", targetID: fid, field: "label", value: label, sensitivity: level, now: now)
            }
        }
        corrected(activity, now, ["facts": 1])
    }

    /// Mark as Former / Mark as Current: your status for the fact, on one episode when it has dated ones.
    public func setFactStatus(_ factID: String, _ status: FactAssertion.Status, selector: DateRange?, activity: any ActivityRecorder,
                              now: Date = Date()) throws {
        guard status != .unknown else { return }
        _ = try writer.write { db in
            try FactStore.addUserEvidence(db, factID: factID, asserted: ["status": status.rawValue], selector: selector,
                                          sensitivity: try FactStore.level(db, facts: [factID]), now: now)
        }
        corrected(activity, now, ["facts": 1])
    }

    /// Set Dates…: your start and end ("2019", "2019-03", "2019-03-15"), on one episode. Your later dates replace your
    /// earlier ones for that episode; Undo brings them back.
    public func setDates(_ factID: String, start: String?, end: String?, selector: DateRange?, activity: any ActivityRecorder,
                         now: Date = Date()) throws {
        var asserted: [String: Any] = [:]
        if let s = start?.trimmingCharacters(in: .whitespaces).nilIfEmpty { asserted["start"] = s }
        if let e = end?.trimmingCharacters(in: .whitespaces).nilIfEmpty { asserted["end"] = e }
        guard !asserted.isEmpty else { return }
        try Self.checkDates(asserted.values.compactMap { $0 as? String })
        _ = try writer.write { db in
            try FactStore.addUserEvidence(db, factID: factID, asserted: asserted, selector: selector,
                                          sensitivity: try FactStore.level(db, facts: [factID]), now: now)
        }
        corrected(activity, now, ["facts": 1])
    }

    /// Clear Dates: the dates you set on that episode stop counting. A row of yours per selector your rows used there
    /// takes them back (one action: Undo restores them); dates a memory gives are corrected with Not this on it.
    public func clearYourDates(_ factID: String, selectors: [DateRange?], activity: any ActivityRecorder, now: Date = Date()) throws {
        guard !selectors.isEmpty else { return }
        try writer.write { db in
            let level = try FactStore.level(db, facts: [factID])
            for sel in Set(selectors.map { $0.map { DateRange(lo: $0.lo, hi: $0.hi) } }) {
                try FactStore.addUserEvidence(db, factID: factID, asserted: ["clears_dates": true], selector: sel, sensitivity: level, now: now)
            }
        }
        corrected(activity, now, ["facts": 1])
    }

    /// Add Order…: `before` came just before `after` (each on one episode).
    public func addOrder(before: String, after: String, beforeSelector: DateRange?, afterSelector: DateRange?,
                         activity: any ActivityRecorder, now: Date = Date()) throws {
        guard before != after else { return }
        _ = try writer.write { db in
            // The other fact by id only: no learned name is copied into your row (it would outlive a purge).
            try FactStore.addUserEvidence(db, factID: after, kind: "order", asserted: [:], otherFactID: before,
                                          direction: "preceded_by", selector: afterSelector, otherSelector: beforeSelector,
                                          sensitivity: try FactStore.level(db, facts: [before, after]), now: now)
        }
        corrected(activity, now, ["orders": 1])
    }

    /// A manual entry (+ ▾): an entity of yours, with a fact about you if you gave one. Your name for it is kept at the
    /// sensitivity you picked. Returns the entity's id.
    @discardableResult
    public func addManualEntry(_ entry: PeopleManualEntry, registry: FactsRegistry = .bundled, activity: any ActivityRecorder,
                               now: Date = Date()) throws -> String {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, registry.kinds[entry.kind] != nil else { throw PeopleError.notFound }
        if let p = entry.predicate, registry.kindOf(p) != entry.kind { throw PeopleError.kindConflict }
        try Self.checkDates([entry.start, entry.end].compactMap { $0?.nilIfEmpty }, registry: registry)
        let level = entry.sensitivity.rawValue
        let id = try writer.write { db -> String in
            let eid = UUID().db
            try db.execute(sql: "INSERT INTO entity (id, kind, name, manual, created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?)",
                           arguments: [eid, entry.kind, name, now, now])
            try db.execute(sql: "INSERT INTO entity_alias (id, entity_id, alias, normalized, manual, confirmed_at) VALUES (?, ?, ?, ?, 1, ?)",
                           arguments: [UUID().db, eid, name, FactsText.normName(name, kind: entry.kind, registry: registry), now])
            try FactStore.override(db, targetKind: "entity", targetID: eid, field: "name", value: name, sensitivity: level, now: now)
            if let p = entry.predicate {
                var asserted: [String: Any] = [:]
                if let s = entry.start?.nilIfEmpty { asserted["start"] = s }
                if let e = entry.end?.nilIfEmpty { asserted["end"] = e }
                if entry.status != .unknown { asserted["status"] = entry.status.rawValue }
                let fid = try FactStore.addYourFact(db, predicate: p, entityID: eid, asserted: asserted, sensitivity: level,
                                                    registry: registry, now: now).fact
                if let l = entry.label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    try FactStore.override(db, targetKind: "qualifier", targetID: fid, field: "label", value: l, sensitivity: level, now: now)
                }
            }
            return eid
        }
        corrected(activity, now, ["entities": 1, "facts": entry.predicate == nil ? 0 : 1])
        return id
    }

    /// To check: who an unsettled role phrase means. A pick or Someone Else is your decision at that span (it wins over
    /// the model's); Skip only takes it off To check (its basis stays `candidates`) and changes nothing a reader sees.
    public func answerLink(memoryID: UUID, surface: String, start: Int, _ answer: PeopleLinkAnswer, activity: any ActivityRecorder,
                           now: Date = Date()) throws {
        try writer.write { db in
            let mid = memoryID.db
            guard let row = try Row.fetchOne(db, sql: "SELECT title, body FROM memory WHERE id = ?", arguments: [mid]) else { return }
            let text = FactStore.text(title: row["title"], body: row["body"])
            let near = FactStore.scalarOffset(text, utf16: start)
            switch answer {
            case let .entity(e):
                try FactStore.decideMention(db, memoryID: mid, quote: surface, near: near, entityID: e, outcome: "entity", now: now)
            case .someoneElse:
                try FactStore.decideMention(db, memoryID: mid, quote: surface, near: near, entityID: nil, outcome: "someone_else", now: now)
            case .skip:
                let span = FactStore.locate(surface, in: text, near: near)
                try db.execute(sql: """
                    INSERT INTO mention_decision (id, memory_id, mention, quote, span_start, span_end, outcome, basis, source, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'unknown', 'candidates', 'user', ?)
                    """, arguments: [UUID().db, mid, surface, surface, span.map { FactStore.scalarOffset(text, utf16: $0.start) },
                                     span.map { FactStore.scalarOffset(text, utf16: $0.end) }, now])
            }
        }
        if answer != .skip { corrected(activity, now, ["links": 1]) }
    }

    /// To check, a row of yours that lost its episode: **This one** points it (or the order's other endpoint) at an
    /// episode; **Remove** deletes it.
    public func retargetUserRow(_ rowID: String, otherEndpoint: Bool, to range: DateRange?, activity: any ActivityRecorder,
                                now: Date = Date()) throws {
        try writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM fact_evidence WHERE id = ? AND source = 'user'", arguments: [rowID]) else { return }
            let facts = Set([row["fact_id"] as String] + [(row["other_fact_id"] as String?)].compactMap { $0 })
            let stamp = FactStore.actionStamp(now)
            // The row retires (Undo brings it back); This one gives a copy pointed at the episode you picked.
            var old = FactStore.object(row["asserted"])
            old["retired_at"] = stamp
            try db.execute(sql: "UPDATE fact_evidence SET asserted = ? WHERE id = ?", arguments: [FactStore.json(old), rowID])
            if let range {
                var a = FactStore.object(row["asserted"])
                a["at"] = nil
                a["created"] = nil
                let sel = DateRange(lo: range.lo, hi: range.hi)
                try FactStore.addUserEvidence(db, factID: row["fact_id"], kind: row["target_kind"], asserted: a, qualifier: row["qualifier"],
                                              otherFactID: row["other_fact_id"], direction: row["direction"],
                                              selector: otherEndpoint ? FactStore.selector(row["episode_selector"]) : sel,
                                              otherSelector: otherEndpoint ? sel : FactStore.selector(row["other_episode_selector"]),
                                              sensitivity: row["sensitivity"], now: now)
            }
            // What rested on the old episode is stale now.
            try FactStore.touch(db, facts: facts, entities: [], now: now)
            try FactStore.bumpRevision(db)
        }
        corrected(activity, now, ["facts": 1])
    }

    /// A year, a month or a day, written as 2019, 2019-03 or 2019-03-15, and a real one; else `badDate`.
    static func checkDates(_ dates: [String], registry: FactsRegistry = .bundled) throws {
        for d in dates {
            let parts = d.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard (1...3).contains(parts.count), parts[0].count == 4, parts.dropFirst().allSatisfy({ $0.count == 2 }),
                  let y = Int(parts[0]), y >= 1 else { throw PeopleError.badDate }
            let m = parts.count > 1 ? Int(parts[1]) : 1, day = parts.count > 2 ? Int(parts[2]) : 1
            guard let m, let day, DayNumber.from(year: y, month: m, day: day) != nil else { throw PeopleError.badDate }
        }
    }

    /// Undo (Corrections, To check's Answered): every row the action wrote goes; a manual flag nothing of yours holds
    /// any more is cleared, a kind change is put back, and what nothing supports any more goes or becomes a tombstone.
    public func undoPeopleAction(_ stamp: String, registry: FactsRegistry = .bundled, activity: any ActivityRecorder,
                                 now: Date = Date()) throws {
        let n = try writer.write { db -> Int in
            var entities = Set<String>(), facts = Set<String>(), n = 0
            var kindChanged = Set<String>(), undoneKind: [String: String] = [:]
            if stamp.hasPrefix("row:") {
                let id = String(stamp.dropFirst(4))
                if let f = try String.fetchOne(db, sql: "SELECT fact_id FROM fact_evidence WHERE id = ? AND source = 'user'", arguments: [id]) {
                    facts.insert(f)
                    try db.execute(sql: "DELETE FROM fact_evidence WHERE id = ?", arguments: [id])
                    n += 1
                }
            } else {
                for o in try Row.fetchAll(db, sql: "SELECT * FROM manual_override WHERE created_at = ?", arguments: [stamp]) {
                    let kind: String = o["target_kind"], target: String = o["target_id"], field: String = o["field"]
                    if kind == "entity" || kind == "alias" { entities.insert(target) } else { facts.insert(target) }
                    if let other = FactStore.decodedString(o["value"]), field == "merged_into" || field == "not_same" { entities.insert(other) }
                    let v = FactStore.object(o["value"])
                    for k in ["before", "after"] { if let f = v[k] as? String { facts.insert(f) } }
                    if kind == "entity", field == "kind" {
                        kindChanged.insert(target)
                        if let was = v["previous_kind"] as? String, undoneKind[target] == nil { undoneKind[target] = was }
                        // The next change of this entity's kind now starts from what this one started from.
                        let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM manual_override WHERE id = ?", arguments: [o["id"] as String]) ?? 0
                        let at: String = o["created_at"]
                        if let was = v["previous_kind"] as? String, let next = try Row.fetchOne(db, sql: """
                            SELECT id, value FROM manual_override WHERE target_kind = 'entity' AND target_id = ? AND field = 'kind'
                              AND (created_at > ? OR (created_at = ? AND rowid > ?)) AND created_at != ?
                            ORDER BY created_at, rowid LIMIT 1
                            """, arguments: [target, at, at, rowid, stamp]) {
                            var nv = FactStore.object(next["value"])
                            nv["previous_kind"] = was
                            try db.execute(sql: "UPDATE manual_override SET value = ? WHERE id = ?", arguments: [FactStore.json(nv), next["id"] as String])
                        }
                    }
                    try db.execute(sql: "DELETE FROM manual_override WHERE id = ?", arguments: [o["id"] as String])
                    n += 1
                }
                for d in try Row.fetchAll(db, sql: "SELECT id, entity_id FROM mention_decision WHERE source = 'user' AND created_at = ?",
                                          arguments: [stamp]) {
                    if let e: String = d["entity_id"] { entities.insert(e) }
                    try db.execute(sql: "DELETE FROM mention_decision WHERE id = ?", arguments: [d["id"] as String])
                    n += 1
                }
                for r in try Row.fetchAll(db, sql: """
                    SELECT id, fact_id, other_fact_id, asserted FROM fact_evidence WHERE source = 'user' AND json_extract(asserted, '$.retired_at') = ?
                    """, arguments: [stamp]) {
                    var a = FactStore.object(r["asserted"])
                    a["retired_at"] = nil
                    try db.execute(sql: "UPDATE fact_evidence SET asserted = ? WHERE id = ?", arguments: [FactStore.json(a), r["id"] as String])
                    facts.insert(r["fact_id"])
                    n += 1
                }
                for r in try Row.fetchAll(db, sql: """
                    SELECT id, fact_id, other_fact_id FROM fact_evidence WHERE source = 'user' AND json_extract(asserted, '$.at') = ?
                    """, arguments: [stamp]) {
                    facts.insert(r["fact_id"])
                    if let o: String = r["other_fact_id"] { facts.insert(o) }
                    try db.execute(sql: "DELETE FROM fact_evidence WHERE id = ?", arguments: [r["id"] as String])
                    n += 1
                }
            }
            guard n > 0 else { return 0 }
            // A kind change undone: the kind your remaining changes give, else the kind before the first one.
            for e in kindChanged {
                let first = try Row.fetchOne(db, sql: "SELECT value FROM manual_override WHERE target_kind = 'entity' AND target_id = ? AND field = 'kind' ORDER BY created_at, rowid LIMIT 1",
                                             arguments: [e])
                let last = try Row.fetchOne(db, sql: "SELECT value FROM manual_override WHERE target_kind = 'entity' AND target_id = ? AND field = 'kind' ORDER BY created_at DESC, rowid DESC LIMIT 1",
                                            arguments: [e])
                let target = last.map { FactStore.object($0["value"])["kind"] as? String } ?? nil
                let original = first.map { FactStore.object($0["value"])["previous_kind"] as? String } ?? nil
                if let k = target ?? original ?? undoneKind[e] {
                    let merged = try FactStore.mergedInto(db)
                    let members = try String.fetchAll(db, sql: "SELECT id FROM entity WHERE is_you = 0").filter { FactStore.canonical($0, merged) == e }
                    try FactStore.changeKind(db, entities: members, to: k, registry: registry, now: now)
                }
            }
            // A fact of yours with none of your rows left, and an entity of yours with nothing of yours left, are no
            // longer yours.
            try FactStore.releaseManual(db, facts: facts)
            for f in facts {
                if let e = try String.fetchOne(db, sql: "SELECT entity_id FROM fact WHERE id = ?", arguments: [f]) { entities.insert(e) }
            }
            for e in entities {
                let mine = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM manual_override WHERE target_kind = 'entity' AND target_id = ?1 AND field = 'name')
                      OR EXISTS (SELECT 1 FROM fact WHERE entity_id = ?1 AND manual = 1)
                    """, arguments: [e]) ?? false
                if !mine {
                    try db.execute(sql: "UPDATE entity SET manual = 0 WHERE id = ?", arguments: [e])
                    try db.execute(sql: "UPDATE entity_alias SET manual = 0 WHERE entity_id = ? AND manual = 1", arguments: [e])
                }
            }
            // Nothing undone may leave a fact on an entity of another kind ("your sister" on an organization).
            for e in entities.union(kindChanged) where try FactStore.kindConflict(db, entity: e, registry: registry) {
                throw PeopleError.kindConflict
            }
            try FactStore.collectGarbage(db, now: now, touching: (facts, entities))
            let liveFacts = try facts.filter { try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM fact WHERE id = ?)", arguments: [$0]) == true }
            let liveEntities = try entities.filter { try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM entity WHERE id = ?)", arguments: [$0]) == true }
            try FactStore.touch(db, facts: Set(liveFacts), entities: Set(liveEntities), now: now)
            try FactStore.bumpRevision(db)
            return n
        }
        if n > 0 { corrected(activity, now, ["undone": n]) }
    }
}

extension FactStore {
    static func requireEntity(_ db: Database, _ id: String) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM entity WHERE id = ? AND is_you = 0)", arguments: [id]) == true else {
            throw PeopleError.notFound
        }
    }

    /// A correction's sensitivity: the highest behind what it corrects (memory evidence and your rows, on the entities,
    /// everything merged into them, and their facts), Internal when nothing is.
    static func level(_ db: Database, entities: [String] = [], facts: [String] = []) throws -> Int {
        let merged = try mergedInto(db)
        var ents = Set(entities)
        if !ents.isEmpty {
            for e in try String.fetchAll(db, sql: "SELECT id FROM entity WHERE is_you = 0") where ents.contains(canonical(e, merged)) {
                ents.insert(e)
            }
        }
        var fids = Set(facts)
        for f in facts { fids.formUnion(try foldedFactRows(db, factID: f)) }
        if !ents.isEmpty {       // every fact of the entities: your corrections of them count too
            let e = Array(ents)
            fids.formUnion(try String.fetchAll(db, sql: "SELECT id FROM fact WHERE entity_id IN (\(databaseQuestionMarks(count: e.count)))",
                                               arguments: StatementArguments(e)))
        }
        var best: Int?
        func take(_ v: Int?) { if let v { best = max(best ?? v, v) } }
        if !ents.isEmpty {
            let e = Array(ents), m = databaseQuestionMarks(count: e.count)
            take(try Int.fetchOne(db, sql: """
                SELECT MAX(ev.sensitivity) FROM alias_evidence ev JOIN entity_alias a ON a.id = ev.alias_id WHERE a.entity_id IN (\(m))
                """, arguments: StatementArguments(e)))
            take(try Int.fetchOne(db, sql: """
                SELECT MAX(ev.sensitivity) FROM fact_evidence ev JOIN fact f ON f.id = ev.fact_id WHERE f.entity_id IN (\(m))
                """, arguments: StatementArguments(e)))
            take(try Int.fetchOne(db, sql: "SELECT MAX(sensitivity) FROM manual_override WHERE target_kind = 'entity' AND target_id IN (\(m))",
                                  arguments: StatementArguments(e)))
        }
        if !fids.isEmpty {
            let f = Array(fids), m = databaseQuestionMarks(count: f.count)
            take(try Int.fetchOne(db, sql: "SELECT MAX(sensitivity) FROM fact_evidence WHERE fact_id IN (\(m))", arguments: StatementArguments(f)))
            take(try Int.fetchOne(db, sql: """
                SELECT MAX(sensitivity) FROM manual_override WHERE target_kind IN ('fact','qualifier','date','status','order') AND target_id IN (\(m))
                """, arguments: StatementArguments(f)))
        }
        return best ?? Sensitivity.internal.rawValue
    }

    static func exists(_ db: Database, _ table: String, _ id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(table) WHERE id = ?)", arguments: [id]) ?? false
    }

    /// A fact of yours with none of your rows left is no longer yours.
    static func releaseManual(_ db: Database, facts: Set<String>) throws {
        for f in facts {
            let mine = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM fact_evidence WHERE fact_id = ? AND source = 'user')",
                                         arguments: [f]) ?? false
            if !mine { try db.execute(sql: "UPDATE fact SET manual = 0 WHERE id = ?", arguments: [f]) }
        }
    }

    /// The predicates of the facts an entity (and what's merged into it) holds that a reader can see: not rejected
    /// everywhere, unless a later row of yours said them again.
    static func liveFactPredicates(_ db: Database, entity: String) throws -> [String] {
        let merged = try mergedInto(db)
        let entity = canonical(entity, merged)
        let members = try String.fetchAll(db, sql: "SELECT id FROM entity WHERE is_you = 0").filter { canonical($0, merged) == entity }
        guard !members.isEmpty else { return [] }
        let marks = databaseQuestionMarks(count: members.count)
        return try Row.fetchAll(db, sql: """
            SELECT f.predicate,
              (SELECT MAX(created_at) FROM manual_override o WHERE o.target_kind = 'fact' AND o.target_id = f.id AND o.field = 'rejected'
                 AND o.memory_id IS NULL) AS rejected_at,
              (SELECT MAX(json_extract(asserted, '$.at')) FROM fact_evidence e WHERE e.fact_id = f.id AND e.source = 'user') AS yours_at
            FROM fact f WHERE f.entity_id IN (\(marks))
              AND (f.tombstone = 0 OR EXISTS (SELECT 1 FROM fact_evidence u WHERE u.fact_id = f.id AND u.source = 'user'
                                                AND json_extract(u.asserted, '$.retired_at') IS NULL))
            """, arguments: StatementArguments(members)).compactMap { r in
            let rejected: String? = r["rejected_at"], yours: String? = r["yours_at"]
            if let rejected, (yours ?? "") <= rejected { return nil }
            return r["predicate"]
        }
    }

    /// Whether an entity holds a visible fact about another kind of thing than it is.
    static func kindConflict(_ db: Database, entity: String, registry: FactsRegistry) throws -> Bool {
        let entity = canonical(entity, try mergedInto(db))
        guard let kind = try String.fetchOne(db, sql: "SELECT kind FROM entity WHERE id = ?", arguments: [entity]) else { return false }
        return try liveFactPredicates(db, entity: entity).contains { registry.kindOf($0) != kind }
    }

    /// The entities' kind, and their aliases normalised for it.
    static func changeKind(_ db: Database, entities: [String], to kind: String, registry: FactsRegistry, now: Date) throws {
        for e in entities {
            try db.execute(sql: "UPDATE entity SET kind = ?, updated_at = ? WHERE id = ?", arguments: [kind, now, e])
            for a in try Row.fetchAll(db, sql: "SELECT id, alias, normalized FROM entity_alias WHERE entity_id = ?", arguments: [e]) {
                let text = (a["alias"] as String?) ?? (a["normalized"] as String)
                try db.execute(sql: "UPDATE entity_alias SET normalized = ? WHERE id = ?",
                               arguments: [FactsText.normName(text, kind: kind, registry: registry), a["id"] as String])
            }
        }
        try touch(db, facts: [], entities: Set(entities), now: now)
    }

    /// A fact of yours (manual entry, Relation…): `addManualFact`, with the founding row marked. A global rejection of
    /// the same fact made earlier is lifted by this later row of yours (`FactStore.load`), and comes back if it's undone.
    @discardableResult
    static func addYourFact(_ db: Database, predicate: String, entityID: String, asserted: [String: Any], sensitivity: Int,
                            registry: FactsRegistry, now: Date) throws -> (entity: String, fact: String) {
        var a = asserted
        a["created"] = true
        return try addManualFact(db, predicate: predicate, entityID: entityID, asserted: a, sensitivity: sensitivity,
                                 registry: registry, now: now)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
