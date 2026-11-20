import Foundation
import FunesProtocol
import GRDB

/// Why a memory was archived, for learned facts (memory processing §11.8).
public enum FactsArchiveReason: Sendable, Equatable {
    /// Superseded (the tidy-up, or the user): it keeps supporting former and dated facts.
    case superseded
    /// The losing side of a conflict: it stops supporting these facts (fact row ids).
    case conflict(facts: [String])
    /// Expired: it stops supporting the facts it stated.
    case expired
}

/// What Remove learned facts removed (counts only, for the `facts_removed` Activity row).
public struct FactsRemoval: Sendable, Equatable {
    public var entities = 0
    public var facts = 0
    public var evidence = 0
    public var decisions = 0
}

extension FactStore {
    // MARK: Memory changes

    /// Called where a memory's version changes (`MemoryStore.update`, `setStatus`). A text edit drops the evidence and
    /// model decisions at the old version (a new job re-reads it); any other change carries them forward.
    static func versionChanged(_ db: Database, memoryID: String, from old: Int, to new: Int, textChanged: Bool,
                               now: Date) throws {
        guard try hasLearnedFacts(db, memoryID: memoryID) else { return }
        if textChanged {
            let affected = try supportedBy(db, memoryIDs: [memoryID])
            try db.execute(sql: "DELETE FROM fact_evidence WHERE memory_id = ? AND memory_version = ?", arguments: [memoryID, old])
            try db.execute(sql: "DELETE FROM alias_evidence WHERE memory_id = ? AND memory_version = ?", arguments: [memoryID, old])
            try db.execute(sql: "DELETE FROM mention_decision WHERE memory_id = ? AND memory_version = ? AND source = 'model'",
                           arguments: [memoryID, old])
            try db.execute(sql: "DELETE FROM facts_asked WHERE memory_id = ? AND memory_version = ?", arguments: [memoryID, old])
            try collectGarbage(db, now: now, touching: affected)
        } else {
            // Status or trust may have changed what counts (a delete, an archive, an owner's edit): what this memory
            // supports changed for the decisions resting on it.
            let affected = try supportedBy(db, memoryIDs: [memoryID])
            try db.execute(sql: "UPDATE fact_evidence SET memory_version = ? WHERE memory_id = ? AND memory_version = ?",
                           arguments: [new, memoryID, old])
            try db.execute(sql: "UPDATE OR REPLACE alias_evidence SET memory_version = ? WHERE memory_id = ? AND memory_version = ?",
                           arguments: [new, memoryID, old])
            try db.execute(sql: "UPDATE mention_decision SET memory_version = ? WHERE memory_id = ? AND memory_version = ? AND source = 'model'",
                           arguments: [new, memoryID, old])
            try db.execute(sql: "UPDATE decision_dependency SET ref_version = ? WHERE kind = 'memory' AND ref_id = ? AND ref_version = ?",
                           arguments: [String(new), memoryID, String(old)])
            try db.execute(sql: "UPDATE OR REPLACE facts_asked SET memory_version = ? WHERE memory_id = ? AND memory_version = ?",
                           arguments: [new, memoryID, old])
            try touch(db, facts: affected.facts, entities: affected.entities, except: memoryID, now: now)
        }
        try bumpRevision(db)
    }

    static func hasLearnedFacts(_ db: Database, memoryID: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM fact_evidence WHERE memory_id = ?1) OR EXISTS (SELECT 1 FROM alias_evidence WHERE memory_id = ?1)
              OR EXISTS (SELECT 1 FROM mention_decision WHERE memory_id = ?1) OR EXISTS (SELECT 1 FROM manual_override WHERE memory_id = ?1)
              OR EXISTS (SELECT 1 FROM facts_asked WHERE memory_id = ?1)
            """, arguments: [memoryID]) ?? false
    }

    /// An archive's effect on learned facts depends on why (memory processing §11.8). Call after `setStatus`.
    static func archived(_ db: Database, memoryID: String, reason: FactsArchiveReason, now: Date) throws {
        let affected = try supportedBy(db, memoryIDs: [memoryID])
        switch reason {
        case .superseded:
            return                       // `load` keeps its former and dated facts, not a current status
        case .conflict(let facts):
            for f in facts {
                try db.execute(sql: "DELETE FROM fact_evidence WHERE memory_id = ? AND fact_id = ?", arguments: [memoryID, f])
            }
        case .expired:
            try db.execute(sql: "DELETE FROM fact_evidence WHERE memory_id = ?", arguments: [memoryID])
        }
        try collectGarbage(db, now: now, touching: affected)
        try bumpRevision(db)
    }

    /// Before memories are hard-deleted: their evidence and model decisions go, and the user's corrections made from
    /// them lose their text (keeping their ids). Then what nothing supports any more goes, or becomes a tombstone.
    static func purge(_ db: Database, memoryIDs: [String], now: Date) throws {
        guard !memoryIDs.isEmpty else { return }
        let affected = try supportedBy(db, memoryIDs: memoryIDs)
        for chunk in stride(from: 0, to: memoryIDs.count, by: 500).map({ Array(memoryIDs[$0..<min($0 + 500, memoryIDs.count)]) }) {
            let marks = databaseQuestionMarks(count: chunk.count)
            let args = StatementArguments(chunk)
            try db.execute(sql: "DELETE FROM fact_evidence WHERE memory_id IN (\(marks))", arguments: args)
            try db.execute(sql: "DELETE FROM alias_evidence WHERE memory_id IN (\(marks))", arguments: args)
            try db.execute(sql: "DELETE FROM mention_decision WHERE source = 'model' AND memory_id IN (\(marks))", arguments: args)
            try db.execute(sql: "DELETE FROM facts_asked WHERE memory_id IN (\(marks))", arguments: args)
            // A skip (To check) holds nothing once its memory is gone.
            try db.execute(sql: "DELETE FROM mention_decision WHERE source = 'user' AND outcome = 'unknown' AND memory_id IN (\(marks))",
                           arguments: args)
            try db.execute(sql: "UPDATE mention_decision SET mention = NULL, quote = NULL WHERE memory_id IN (\(marks))", arguments: args)
            try db.execute(sql: "UPDATE manual_override SET quote = NULL WHERE memory_id IN (\(marks))", arguments: args)
        }
        try collectGarbage(db, now: now, touching: affected)
        try bumpRevision(db)
    }

    /// What nothing supports any more goes, names included; what the user made, or a correction references, stays as
    /// a tombstone (its id, predicate, the user's own values and the alias the user typed or confirmed).
    static func collectGarbage(_ db: Database, now: Date,
                               touching affected: (facts: Set<String>, entities: Set<String>) = ([], [])) throws {
        var touchedEntities = affected.entities, touchedFacts = affected.facts
        // Inferred aliases with no evidence.
        try db.execute(sql: """
            DELETE FROM entity_alias WHERE manual = 0 AND confirmed = 0
              AND NOT EXISTS (SELECT 1 FROM alias_evidence e WHERE e.alias_id = entity_alias.id)
            """)
        // Facts with no memory evidence: kept as tombstones when the user made them or something references them.
        let referencedFacts = """
            SELECT target_id FROM manual_override WHERE target_kind IN ('fact','qualifier','date','status','order')
            UNION SELECT fact_id FROM fact_evidence WHERE source = 'user'
            UNION SELECT other_fact_id FROM fact_evidence WHERE source = 'user' AND other_fact_id IS NOT NULL
            UNION SELECT json_extract(value, '$.before') FROM manual_override WHERE target_kind = 'order' AND value IS NOT NULL
            UNION SELECT json_extract(value, '$.after') FROM manual_override WHERE target_kind = 'order' AND value IS NOT NULL
            """
        for f in try Row.fetchAll(db, sql: """
            SELECT id, manual, tombstone, entity_id FROM fact
            WHERE NOT EXISTS (SELECT 1 FROM fact_evidence e WHERE e.fact_id = fact.id AND e.source = 'memory')
            """) {
            let id: String = f["id"]
            let referenced = try Bool.fetchOne(db, sql: "SELECT ? IN (\(referencedFacts))", arguments: [id]) ?? false
            if (f["manual"] as Int) == 1 {
                continue
            } else if referenced {
                if (f["tombstone"] as Int) == 0 {
                    try db.execute(sql: "UPDATE fact SET tombstone = 1, updated_at = ? WHERE id = ?", arguments: [now, id])
                    touchedFacts.insert(id)
                }
            } else {
                try db.execute(sql: "DELETE FROM fact WHERE id = ?", arguments: [id])
                touchedFacts.insert(id)
                touchedEntities.insert(f["entity_id"])
            }
        }
        // Entities: supported by an alias with evidence or a fact with memory evidence; otherwise a tombstone if the user
        // made it or something references it, else deleted.
        let referencedEntities = """
            SELECT target_id FROM manual_override WHERE target_kind IN ('entity','alias')
            UNION SELECT entity_id FROM mention_decision WHERE source = 'user' AND entity_id IS NOT NULL
            UNION SELECT json_extract(value, '$') FROM manual_override WHERE field IN ('merged_into','not_same') AND value IS NOT NULL
            UNION SELECT entity_id FROM fact
            """
        for e in try Row.fetchAll(db, sql: "SELECT id, name, manual, tombstone, group_predicate FROM entity WHERE is_you = 0") {
            let id: String = e["id"]
            let supported = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM entity_alias a JOIN alias_evidence ev ON ev.alias_id = a.id WHERE a.entity_id = ?1)
                    OR EXISTS (SELECT 1 FROM fact f JOIN fact_evidence ev ON ev.fact_id = f.id
                               WHERE f.entity_id = ?1 AND ev.source = 'memory')
                """, arguments: [id]) ?? false
            let kept = try String.fetchAll(db, sql: "SELECT alias FROM entity_alias WHERE entity_id = ? AND alias IS NOT NULL ORDER BY rowid",
                                           arguments: [id])
            let typedName = try String.fetchOne(db, sql: """
                SELECT value FROM manual_override WHERE target_kind = 'entity' AND target_id = ? AND field = 'name'
                ORDER BY created_at DESC LIMIT 1
                """, arguments: [id]).flatMap { object("{\"v\":\($0)}")["v"] as? String }
            if supported {
                let name: String? = e["name"]
                if (e["tombstone"] as Int) == 1 || (name != nil && !kept.contains(name!)) {
                    try db.execute(sql: "UPDATE entity SET tombstone = 0, name = ?, updated_at = ? WHERE id = ?",
                                   arguments: [name.flatMap { kept.contains($0) ? $0 : nil } ?? typedName ?? kept.first, now, id])
                    touchedEntities.insert(id)
                }
                continue
            }
            let isGroup = (e["group_predicate"] as String?) != nil && (e["name"] as String?) == nil
            let referenced = try Bool.fetchOne(db, sql: "SELECT ? IN (\(referencedEntities))", arguments: [id]) ?? false
            if (e["manual"] as Int) == 1 || referenced {
                if isGroup {   // a group's label and count were inferred: they go too
                    try db.execute(sql: "UPDATE entity SET group_label = NULL, group_count = NULL WHERE id = ?", arguments: [id])
                }
                // A tombstone keeps only what the user typed, and the normalised alias the user confirmed.
                try db.execute(sql: "UPDATE entity_alias SET alias = NULL WHERE entity_id = ? AND manual = 0", arguments: [id])
                let typedAlias = try String.fetchOne(db, sql: """
                    SELECT alias FROM entity_alias WHERE entity_id = ? AND manual = 1 AND alias IS NOT NULL ORDER BY rowid
                    """, arguments: [id])
                let name: String? = e["name"]
                let keepName = typedName ?? typedAlias
                let tomb = 1
                if (e["tombstone"] as Int) != tomb || name != keepName {
                    try db.execute(sql: "UPDATE entity SET tombstone = ?, name = ?, updated_at = ? WHERE id = ?",
                                   arguments: [tomb, keepName, now, id])
                    touchedEntities.insert(id)
                }
            } else {
                try db.execute(sql: "DELETE FROM entity WHERE id = ?", arguments: [id])
                touchedEntities.insert(id)
            }
        }
        try touch(db, facts: touchedFacts.filter { id in (try? Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM fact WHERE id = ?)", arguments: [id])) == true },
                  entities: touchedEntities.filter { id in (try? Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM entity WHERE id = ?)", arguments: [id])) == true },
                  now: now)
        // Decisions that pointed at what's gone (a memory included) are stale too.
        try db.execute(sql: """
            UPDATE mention_decision SET invalidated_at = ? WHERE invalidated_at IS NULL AND source = 'model' AND id IN (
              SELECT decision_id FROM decision_dependency d WHERE (d.kind = 'entity' AND d.ref_id NOT IN (SELECT id FROM entity))
                 OR (d.kind = 'fact' AND d.ref_id NOT LIKE 'predicate:%' AND d.ref_id NOT IN (SELECT id FROM fact))
                 OR (d.kind = 'memory' AND d.ref_id NOT IN (SELECT id FROM memory)))
            """, arguments: [now])
    }

    /// Remove learned facts: every inferred row goes; manual entries, the user's rows, corrections, the tombstones
    /// they need and *you* stay. Qualification rows aren't touched.
    @discardableResult
    static func removeLearnedFacts(_ db: Database, now: Date) throws -> FactsRemoval {
        var out = FactsRemoval()
        let entitiesBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entity WHERE is_you = 0 AND tombstone = 0") ?? 0
        let factsBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fact WHERE tombstone = 0") ?? 0
        out.evidence = try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM fact_evidence WHERE source = 'memory') + (SELECT COUNT(*) FROM alias_evidence)") ?? 0
        out.decisions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mention_decision WHERE source = 'model'") ?? 0
        try db.execute(sql: "DELETE FROM fact_evidence WHERE source = 'memory'")
        try db.execute(sql: "DELETE FROM alias_evidence")
        try db.execute(sql: "DELETE FROM mention_decision WHERE source = 'model'")
        try db.execute(sql: "DELETE FROM facts_asked")
        try db.execute(sql: "DELETE FROM facts_run")
        // The first backfill's state stays: the exemption was used. An unfinished one ends here, with its jobs.
        try FactsBackfill.endForRemoval(db, now: now)
        try collectGarbage(db, now: now)
        out.entities = entitiesBefore - (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entity WHERE is_you = 0 AND tombstone = 0") ?? 0)
        out.facts = factsBefore - (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fact WHERE tombstone = 0") ?? 0)
        try bumpRevision(db)
        // Learning turns off with it: no job is left to read anything again, the sweep `bumpRevision` just queued
        // included. Any job still running was waited for first (`VaultStore.removeLearnedFactsStoppingLearning`).
        try db.execute(sql: "DELETE FROM processing_job WHERE kind = 'facts'")
        return out
    }

    // MARK: Corrections and the user's own entries (manual entries win over inference)

    /// "Not <name>" (or a confirmation) on a mention, keyed to the memory and the quoted span's text.
    @discardableResult
    static func decideMention(_ db: Database, memoryID: String, quote: String, near scalarStart: Int? = nil,
                              entityID: String?, outcome: String, now: Date) throws -> String {
        let text = try Row.fetchOne(db, sql: "SELECT title, body FROM memory WHERE id = ?", arguments: [memoryID])
            .map { FactStore.text(title: $0["title"], body: $0["body"]) } ?? ""
        let span = locate(quote, in: text, near: scalarStart)
        let id = UUID().db
        try db.execute(sql: """
            INSERT INTO mention_decision (id, memory_id, mention, quote, span_start, span_end, outcome, entity_id, basis, source, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'confirmed', 'user', ?)
            """, arguments: [id, memoryID, quote, quote, span.map { scalarOffset(text, utf16: $0.start) },
                             span.map { scalarOffset(text, utf16: $0.end) }, outcome, entityID, now])
        try bumpRevision(db)
        return id
    }

    /// A manual override (memory processing §11.8): it outlives what it corrects and wins over inference.
    @discardableResult
    static func override(_ db: Database, targetKind: String, targetID: String, field: String, value: Any?,
                         selector: DateRange? = nil, sensitivity: Int, memoryID: String? = nil, quote: String? = nil,
                         now: Date) throws -> String {
        let id = UUID().db
        let encoded = value.flatMap { v -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) else { return nil }
            return String(decoding: d, as: UTF8.self)
        }
        try db.execute(sql: """
            INSERT INTO manual_override (id, target_kind, target_id, field, value, episode_selector, sensitivity, memory_id, quote,
              created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, targetKind, targetID, field, encoded, selectorJSON(selector), sensitivity, memoryID, quote, now, now])
        // What it corrects changed: decisions resting on it are stale.
        if ["entity", "alias"].contains(targetKind) {
            try touch(db, facts: [], entities: try String.fetchAll(db, sql: "SELECT id FROM entity WHERE id = ?", arguments: [targetID]).reduce(into: Set()) { $0.insert($1) }, now: now)
        } else {
            try touch(db, facts: try String.fetchAll(db, sql: "SELECT id FROM fact WHERE id = ?", arguments: [targetID]).reduce(into: Set()) { $0.insert($1) }, entities: [], now: now)
        }
        try bumpRevision(db)
        return id
    }

    /// A date, status, qualifier or order the user entered: an evidence row from the user, with an optional episode
    /// selector (the date range of the episode the user acted on).
    @discardableResult
    static func addUserEvidence(_ db: Database, factID: String, kind: String = "fact", asserted: [String: Any],
                                qualifier: String? = nil, otherFactID: String? = nil, direction: String? = nil,
                                selector: DateRange? = nil, otherSelector: DateRange? = nil, sensitivity: Int,
                                now: Date) throws -> String {
        let id = UUID().db
        var asserted = asserted
        asserted["written"] = writtenDay(now)        // the day the user said it, kept with it
        asserted["at"] = actionStamp(now)            // the action it belongs to (People & history's Undo)
        try db.execute(sql: """
            INSERT INTO fact_evidence (id, target_kind, fact_id, qualifier, other_fact_id, direction, episode_selector,
              other_episode_selector, source, asserted, states, polarity, sensitivity, trust)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'user', ?, 1, 'affirmed', ?, 'trusted')
            """, arguments: [id, kind, factID, qualifier, otherFactID, direction, selectorJSON(selector), selectorJSON(otherSelector),
                             json(asserted), sensitivity])
        try db.execute(sql: "UPDATE fact SET tombstone = 0 WHERE id = ?", arguments: [factID])
        try touch(db, facts: [factID], entities: [], now: now)
        try bumpRevision(db)
        return id
    }

    /// A manual entry: an entity (new, by name) and a fact the user made, with its first evidence row.
    @discardableResult
    static func addManualFact(_ db: Database, predicate: String, entityID: String? = nil, name: String? = nil,
                              asserted: [String: Any] = [:], sensitivity: Int, registry: FactsRegistry = .bundled,
                              now: Date) throws -> (entity: String, fact: String) {
        let kind = registry.kindOf(predicate)
        let eid: String
        if let entityID {
            eid = entityID
        } else {
            eid = UUID().db
            try db.execute(sql: "INSERT INTO entity (id, kind, name, manual, created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?)",
                           arguments: [eid, kind, name, now, now])
            if let name {
                try db.execute(sql: "INSERT INTO entity_alias (id, entity_id, alias, normalized, manual, confirmed_at) VALUES (?, ?, ?, ?, 1, ?)",
                               arguments: [UUID().db, eid, name, FactsText.normName(name, kind: kind, registry: registry), now])
            }
        }
        let fid = try String.fetchOne(db, sql: "SELECT id FROM fact WHERE predicate = ? AND entity_id = ?", arguments: [predicate, eid])
            ?? {
                let id = UUID().db
                try db.execute(sql: "INSERT INTO fact (id, predicate, entity_id, manual, created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?)",
                               arguments: [id, predicate, eid, now, now])
                return id
            }()
        try db.execute(sql: "UPDATE fact SET manual = 1 WHERE id = ?", arguments: [fid])
        try addUserEvidence(db, factID: fid, asserted: asserted, sensitivity: sensitivity, now: now)
        return (eid, fid)
    }

    /// A tidy-up merge or split: the user's decisions and corrections move to the memory that inherits their quoted
    /// span. The new memory gets a job (13a.2).
    static func moveCorrections(_ db: Database, from sources: [String], to target: String, now: Date) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT title, body FROM memory WHERE id = ?", arguments: [target]) else { return }
        let text = FactStore.text(title: row["title"], body: row["body"])
        var moved = false
        for table in ["mention_decision", "manual_override"] {
            let extra = table == "mention_decision" ? " AND source = 'user'" : ""
            for src in sources {
                for r in try Row.fetchAll(db, sql: "SELECT id, quote FROM \(table) WHERE memory_id = ?\(extra)", arguments: [src]) {
                    guard let quote: String = r["quote"], locate(quote, in: text, near: nil) != nil else { continue }
                    try db.execute(sql: "UPDATE \(table) SET memory_id = ? WHERE id = ?", arguments: [target, r["id"] as String])
                    moved = true
                }
            }
        }
        if moved { try bumpRevision(db) }
    }

    /// **Not this** with no memory: every fact row that folds into this one (a merge joins two entities' rows of one
    /// predicate) is rejected, at the highest sensitivity behind any of them, so the fact can't come back through the
    /// other row.
    @discardableResult
    static func rejectFactEverywhere(_ db: Database, factID: String, now: Date) throws -> [String] {
        let rows = try foldedFactRows(db, factID: factID)
        guard !rows.isEmpty else { return [] }
        let marks = databaseQuestionMarks(count: rows.count)
        let level = try Int.fetchOne(db, sql: "SELECT MAX(sensitivity) FROM fact_evidence WHERE fact_id IN (\(marks))",
                                     arguments: StatementArguments(rows)) ?? Sensitivity.internal.rawValue
        for fid in rows {
            try override(db, targetKind: "fact", targetID: fid, field: "rejected", value: true, sensitivity: level, now: now)
        }
        return rows
    }

    /// The fact rows that read as one fact with `factID`: the same predicate, on entities merged together.
    static func foldedFactRows(_ db: Database, factID: String) throws -> [String] {
        guard let f = try Row.fetchOne(db, sql: "SELECT predicate, entity_id FROM fact WHERE id = ?", arguments: [factID]) else { return [] }
        let merged = try mergedInto(db)
        let target = canonical(f["entity_id"], merged)
        return try Row.fetchAll(db, sql: "SELECT id, entity_id FROM fact WHERE predicate = ? ORDER BY rowid", arguments: [f["predicate"] as String])
            .filter { canonical($0["entity_id"], merged) == target }.map { $0["id"] }
    }

    /// Merge With…: each entity merged away → the one it was merged into.
    static func mergedInto(_ db: Database) throws -> [String: String] {
        var out: [String: String] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT target_id, value FROM manual_override WHERE target_kind = 'entity' AND field = 'merged_into' ORDER BY created_at, rowid") {
            if let into = decodedString(r["value"]) { out[r["target_id"]] = into }
        }
        return out
    }

    static func canonical(_ id: String, _ merged: [String: String]) -> String {
        var id = id, hops = 0
        while let next = merged[id], hops < 16 { id = next; hops += 1 }
        return id
    }

    /// The stamp every row of one People & history action carries (`created_at`, and `asserted.at` on your evidence
    /// rows), so Undo takes back the whole action.
    static func actionStamp(_ d: Date) -> String { String.fromDatabaseValue(d.databaseValue) ?? "" }

    /// The user confirmed an entity's alias (To check, Merge With…): a tombstone keeps it, normalised.
    static func confirmAlias(_ db: Database, entityID: String, alias: String, registry: FactsRegistry = .bundled,
                             now: Date) throws {
        let kind = try String.fetchOne(db, sql: "SELECT kind FROM entity WHERE id = ?", arguments: [entityID]) ?? "person"
        let norm = FactsText.normName(alias, kind: kind, registry: registry)
        try db.execute(sql: """
            UPDATE entity_alias SET confirmed = 1, confirmed_at = COALESCE(confirmed_at, ?) WHERE entity_id = ? AND normalized = ?
            """, arguments: [now, entityID, norm])
        if db.changesCount == 0 {
            try db.execute(sql: "INSERT INTO entity_alias (id, entity_id, alias, normalized, confirmed, confirmed_at) VALUES (?, ?, ?, ?, 1, ?)",
                           arguments: [UUID().db, entityID, alias, norm, now])
        }
        try bumpRevision(db)
    }

    /// Records a facts run with the registry and prompt versions it used.
    @discardableResult
    static func startRun(_ db: Database, kind: String, callGroup: String, registryVersion: String, promptVersion: String,
                         engine: String, capExempt: Bool = false, now: Date) throws -> String {
        let id = UUID().db
        try db.execute(sql: """
            INSERT INTO facts_run (id, kind, call_group, registry_version, prompt_version, engine, cap_exempt, started_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, kind, callGroup, registryVersion, promptVersion, engine, capExempt, now])
        return id
    }
}

extension VaultStore {
    /// Remove learned facts without the lane's barrier: writes a `facts_removed` Activity row with counts only. Internal:
    /// the app uses `removeLearnedFactsStoppingLearning`, which waits for a running facts job first.
    @discardableResult
    func removeLearnedFacts(activity: any ActivityRecorder, now: Date = Date()) throws -> FactsRemoval {
        let out = try writer.write { db in try FactStore.removeLearnedFacts(db, now: now) }
        activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "facts_removed",
                                      counts: ["entities": out.entities, "facts": out.facts, "evidence": out.evidence,
                                               "decisions": out.decisions]))
        return out
    }

    /// Remove learned facts from Settings: learning off first (no commit queues a job, no job starts, a running one
    /// sends nothing more), then once no facts job is running, everything inferred and every facts job go in one
    /// transaction (FR-F-01, memory processing §11.8). The caller turns *Learn from memories* off in the settings too.
    @discardableResult
    public func removeLearnedFactsStoppingLearning(activity: any ActivityRecorder, now: Date = Date()) async throws -> FactsRemoval {
        factsLane.setLearning(false)
        await factsLane.close(.removing)
        defer { factsLane.open(.removing) }
        let out = try removeLearnedFacts(activity: activity, now: now)
        factsLane.setBackfillPaused(false)
        return out
    }

    /// **Not <name>** (a why line, 13b): this memory isn't about that entity. Every link of the memory to it is rejected
    /// for this memory only, keyed to the memory and each quoted span (memory processing §11.8): each role phrase that
    /// resolves to it, the name where the memory uses it, and the facts the memory states about it. Dependent links
    /// recompute at once (the facts revision moves). Activity: `facts_corrected`, counts only. Returns how many links.
    @discardableResult
    public func rejectLink(memoryID: UUID, entity: String, config: FactsSearchConfig, activity: any ActivityRecorder,
                           now: Date = Date()) throws -> Int {
        let n = try writer.write { db -> Int in
            let uses = try config.uses(db)
            let loaded = try FactStore.load(db, registry: config.registry, userAliases: config.userAliases, uses: uses)
            var g = loaded.graph
            let mid = memoryID.db
            guard let row = try Row.fetchOne(db, sql: """
                SELECT title, body, created_at, COALESCE(original_source, source) AS source, trust, sensitivity FROM memory WHERE id = ?
                """, arguments: [mid]) else { return 0 }
            let text = FactStore.text(title: row["title"], body: row["body"])
            let created: Date = row["created_at"]
            let mem = g.memories[mid] ?? FactsMemory(id: mid, text: text, written: FactStore.writtenDay(created),
                                                     source: FactStore.source(row["source"]), trusted: (row["trust"] as String) == "trusted")
            var count = 0
            let linked = Set(uses.predicates(.linked)).intersection(uses.predicates(.recorded))
            // Each role phrase that resolves to them, or leaves them among its candidates.
            for ph in g.rolePhrases(text, predicates: linked) {
                let r = g.resolution(mem, ph)
                guard r.entity == entity || (r.entity == nil && r.candidates.contains(entity)) else { continue }
                try FactStore.decideMention(db, memoryID: mid, quote: ph.surface, near: FactStore.scalarOffset(text, utf16: ph.start),
                                            entityID: entity, outcome: "rejected", now: now)
                count += 1
            }
            for (key, link) in g.names where key.memoryID == mid && (link.entity == entity || link.candidates.contains(entity)) {
                // The text's own words at the name ("Lucía", "MARIA"), so the span is found again exactly.
                guard let r = FactsText.wholeWordRanges(key.surface, in: text).first else { continue }
                let written = FactsText.substring(text, r.location, r.location + r.length)
                try FactStore.decideMention(db, memoryID: mid, quote: written, near: FactStore.scalarOffset(text, utf16: r.location),
                                            entityID: entity, outcome: "rejected", now: now)
                count += 1
            }
            for f in g.facts where f.entity == entity {
                // Every fact row folded into this one (a merge), each where this memory's evidence is.
                let rows = loaded.factKeys.filter { $0.value.predicate == f.predicate && $0.value.entity == f.entity }.map(\.key)
                for a in f.assertions where a.memoryID == mid && !a.fromUser {
                    for fid in rows.sorted() {
                        let has = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM fact_evidence WHERE fact_id = ? AND memory_id = ?)",
                                                    arguments: [fid, mid]) ?? false
                        guard has else { continue }
                        try FactStore.override(db, targetKind: "fact", targetID: fid, field: "rejected", value: true,
                                               sensitivity: row["sensitivity"], memoryID: mid, quote: a.quote, now: now)
                    }
                    count += 1
                }
            }
            // The names of an organization, place or thing (people's are above): each occurrence in this memory.
            let merged = try FactStore.mergedInto(db)
            for r in try Row.fetchAll(db, sql: """
                SELECT ev.span_start, ev.span_end, a.entity_id FROM alias_evidence ev JOIN entity_alias a ON a.id = ev.alias_id
                JOIN entity e ON e.id = a.entity_id JOIN memory m ON m.id = ev.memory_id AND m.version = ev.memory_version
                WHERE ev.memory_id = ? AND e.kind != ?
                """, arguments: [mid, FactsValidator.personKind]) {
                guard FactStore.canonical(r["entity_id"], merged) == entity else { continue }
                let a = FactStore.utf16Offset(text, scalar: r["span_start"]), b = FactStore.utf16Offset(text, scalar: r["span_end"])
                guard b > a else { continue }
                try FactStore.decideMention(db, memoryID: mid, quote: FactsText.substring(text, a, b), near: r["span_start"],
                                            entityID: entity, outcome: "rejected", now: now)
                count += 1
            }
            return count
        }
        if n > 0 {
            activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "facts_corrected",
                                          counts: ["links": n]))
        }
        return n
    }

    /// **Not this** (a why line, 13b): the fact is wrong ("Maria isn't your sister"), for every memory: a rejection with
    /// no memory, at the highest sensitivity behind the fact. Dependent links and the timeline recompute at once.
    /// Activity: `facts_corrected`, counts only.
    public func rejectFact(factID: String, activity: any ActivityRecorder, now: Date = Date()) throws {
        _ = try writer.write { db in try FactStore.rejectFactEverywhere(db, factID: factID, now: now) }
        activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "facts_corrected",
                                      counts: ["facts": 1]))
    }

    /// The UI-review build's sample facts (never the real vault): a memory read by the people call, naming `person` with
    /// a fact whose lexicon word is `word` ("sister"), or read with nothing found when `person` is nil.
    @_spi(FactsReview) public func reviewLearn(memoryID: UUID, person: String?, word: String = "", quote: String = "",
                                               registry: FactsRegistry = .bundled, now: Date = Date()) throws {
        guard let p = registry.predicates.first(where: { $0.lexicon.contains { $0.words.contains(word) } })
            ?? registry.predicates.first(where: { $0.objectKind == FactsValidator.personKind }) else { return }
        let x = person.map { n in
            FactsExtraction(people: [ExtractedPerson(name: n, quote: quote)],
                            facts: [ExtractedFact(predicate: p.id, name: n, label: word, quote: quote)])
        } ?? FactsExtraction()
        try writer.write { db in
            let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [memoryID.db]) ?? 1
            try FactStore.apply(db, memoryID: memoryID.db, version: version, extraction: x, callGroup: p.callGroup, registry: registry,
                                uses: .everyDeclared(registry), now: now)
        }
    }

    /// The UI-review build's sample facts (never the real vault): one memory's extraction, applied as its call group
    /// would, every declared use on.
    @_spi(FactsReview) public func reviewApply(memoryID: UUID, extraction: FactsExtraction, callGroup: String,
                                               registry: FactsRegistry = .bundled, now: Date = Date()) throws {
        try writer.write { db in
            let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [memoryID.db]) ?? 1
            try FactStore.apply(db, memoryID: memoryID.db, version: version, extraction: extraction, callGroup: callGroup,
                                registry: registry, uses: .everyDeclared(registry), now: now)
        }
    }

    /// `status.get`'s factsRevision: "<epoch>.<counter>".
    public func factsRevision() throws -> String {
        try writer.read { db in try FactStore.revision(db) }
    }
}
