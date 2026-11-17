import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Restoring an export while skipping some of its memories is restoring all of them and then purging the skipped ones
/// (storage §5.2). A differential fuzz over random vaults with facts (some from untrusted memories), model decisions
/// resting on them, corrections made from memories, and memories purged before the export: restoring the subset leaves
/// the same decided state as restoring everything and then deleting and purging the skipped memories as the user
/// would, and as deleting and purging them in the source vault (so a complete restore is a round trip).
///
/// Routine size: 20 vaults per seed. Full size: 300 vaults per seed, with `FUNES_FULL_FUZZ=1`.
@Suite struct FactsRestoreSubsetTests {
    static let vaultsPerSeed = ProcessInfo.processInfo.environment["FUNES_FULL_FUZZ"] == "1" ? 300 : 20
    static let d = FX.dated, pp = FX.personSuccession

    struct Coverage {
        var vaults = 0, skippedDecisions = 0, skippedCorrections = 0, skippedEvidence = 0, invalidated = 0, suggestions = 0
        var purgedBeforeExport = 0, occupied = 0
    }

    /// A memory as the export carries it: its text, date and trust.
    struct Source { var id: String; var title: String; var body: String; var created: Date; var trust: String }

    // MARK: Random vaults

    static func roster(_ v: TestVault, _ predicate: String) throws -> [String: String] {
        try v.store.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT e.id, e.updated_at FROM entity e JOIN fact f ON f.entity_id = e.id
                WHERE f.predicate = ? AND f.tombstone = 0 AND e.tombstone = 0 ORDER BY e.rowid
                """, arguments: [predicate]).reduce(into: [:]) { $0[$1["id"] as String] = $1["updated_at"] as String }
        }
    }

    static func decideRole(_ v: TestVault, _ g: inout R6RNG, at: Date) throws -> Memory {
        let person = g.next(2) == 0
        let predicate = person ? pp : d
        let text = person ? "Yesterday my \(FX.word(pp)) approved the budget." : "At my \(FX.word(d)) I use Emacs."
        let m = try v.memory("Note", text, now: at)
        let tokens = try roster(v, predicate)
        guard !tokens.isEmpty else { return m }
        let refersTo = g.next(5) == 0 ? "someone_else" : g.pick(tokens.keys.sorted())
        _ = try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: m.version,
                                extraction: FactsExtraction(roles: [ExtractedRole(phrase: 0, refersTo: refersTo)], roster: tokens),
                                callGroup: FX.registry.predicate(predicate)!.callGroup, now: at)
        }
        return m
    }

    /// Fact memories, memories with a role phrase a model decided, corrections made from memories (or by the user with
    /// none), and sometimes a memory purged before the export with a decision made after it. Returns the vault, its
    /// memories in order, and the ids of the memories purged.
    static func randomVault(_ g: inout R6RNG) throws -> (TestVault, [Memory], [String]) {
        var specs = (0..<(2 + g.next(4))).map { _ in R6.spec(&g, trusted: true) }
        for _ in 0..<g.next(3) { specs.insert(R6.spec(&g, trusted: false, extra: ["Hooli"]), at: g.next(specs.count + 1)) }
        let (v, ids) = try ReviewRound7Tests.vault(specs)
        var ms = try ids.map { id in try v.store.writer.read { db in try MemoryStore.fetch(db, id: id)! } }
        for i in 0..<(1 + g.next(3)) { ms.append(try decideRole(v, &g, at: t0.plus(days: 10 + Double(i)))) }
        for k in 0..<g.next(5) {
            let at = t0.plus(days: 20 + Double(k))
            let (facts, entities) = try v.store.writer.read { db in
                (try String.fetchAll(db, sql: "SELECT id FROM fact ORDER BY rowid"),
                 try String.fetchAll(db, sql: "SELECT id FROM entity WHERE is_you = 0 ORDER BY rowid"))
            }
            let m = g.pick(ms)
            let quote = String(m.body.prefix(10 + g.next(8)))
            let kind = g.next(5)
            let fact = facts.isEmpty ? nil : g.pick(facts)
            let entity = entities.isEmpty ? nil : g.pick(entities)
            let other = entities.isEmpty ? nil : g.pick(entities)
            let roles = ms.filter { $0.body.contains("my \(FX.word(pp))") || $0.body.contains("my \(FX.word(d))") }
            let role = roles.isEmpty ? nil : g.pick(roles)
            try v.store.writer.write { db in
                switch kind {
                case 0:
                    guard let fact else { return }
                    _ = try FactStore.override(db, targetKind: "fact", targetID: fact, field: "rejected", value: true, sensitivity: 1,
                                               memoryID: m.id.db, quote: quote, now: at)
                case 1:
                    guard let entity else { return }
                    _ = try FactStore.override(db, targetKind: "entity", targetID: entity, field: "name", value: "Northstar", sensitivity: 1,
                                               memoryID: m.id.db, quote: quote, now: at)
                case 2:
                    guard let entity, let other, entity != other else { return }
                    _ = try FactStore.override(db, targetKind: "entity", targetID: entity, field: "merged_into", value: other, sensitivity: 1,
                                               memoryID: m.id.db, quote: quote, now: at)
                case 3:
                    guard let fact else { return }
                    _ = try FactStore.addUserEvidence(db, factID: fact, asserted: ["start": "2015"], sensitivity: 1, now: at)
                default:
                    guard let role, let entity else { return }
                    let word = role.body.contains("my \(FX.word(pp))") ? FX.word(pp) : FX.word(d)
                    _ = try FactStore.decideMention(db, memoryID: role.id.db, quote: "my \(word)", entityID: entity, outcome: "rejected", now: at)
                }
            }
        }
        // A memory purged before the export (its corrections stay, stripped), then a decision made after it.
        var gone: [String] = []
        if g.next(2) == 0, ms.count > 2 {
            let m = ms.remove(at: g.next(ms.count))
            let entities = try v.store.writer.read { db in try String.fetchAll(db, sql: "SELECT id FROM entity WHERE is_you = 0 ORDER BY rowid") }
            if !entities.isEmpty {
                let entity = g.pick(entities)
                try v.store.writer.write { db in
                    _ = try FactStore.override(db, targetKind: "entity", targetID: entity, field: "name", value: "Westway", sensitivity: 1,
                                               memoryID: m.id.db, quote: String(m.body.prefix(12)), now: t0.plus(days: 24))
                }
            }
            _ = try v.store.deleteMemory(id: m.id, now: t0.plus(days: 25))
            try v.store.purgeMemory(id: m.id, now: t0.plus(days: 25))
            gone.append(m.id.db)
            ms.append(try decideRole(v, &g, at: t0.plus(days: 26)))
        }
        return (v, ms, gone)
    }

    static func copy(_ s: Source, into v: TestVault) throws -> Memory {
        let m = try v.memory(s.title, s.body, now: s.created)
        try v.store.writer.write { db in try db.execute(sql: "UPDATE memory SET trust = ? WHERE id = ?", arguments: [s.trust, m.id.db]) }
        return m
    }

    // MARK: The decided state

    /// Every learned-facts row, with memory ids as their place in the source vault, timestamps left out, a decision's
    /// invalidation as valid or not, and each fact or entity dependency as current or stale; plus every answer the
    /// trust fuzz compares and how each role phrase resolves.
    static func decided(_ v: TestVault, labels: [String: String], kept: Set<String>, runs: Bool) throws -> [String: [String]] {
        try v.store.writer.read { db in
            var out: [String: [String]] = [:]
            let skip: Set<String> = ["updated_at"]
            func label(_ value: DatabaseValue) -> String {
                guard let id = String.fromDatabaseValue(value) else { return "∅" }
                return labels[id] ?? "unlabelled:\(id)"
            }
            for t in FactsExport.tables where runs || t.table != "facts_run" {
                out[t.table] = try Row.fetchAll(db, sql: "SELECT * FROM \(t.table) \(t.filter)").map { row in
                    var cells: [String] = []
                    for c in row.columnNames.sorted() where !skip.contains(c) {
                        let value: DatabaseValue = row[c]
                        var s = value.isNull ? "∅" : "\(value)"
                        if c == "invalidated_at" { s = value.isNull ? "valid" : "invalidated" }
                        if c == "memory_id" { s = label(value) }
                        if t.table == "decision_dependency" {
                            let kind: String = row["kind"], ref: String = row["ref_id"], version: String = row["ref_version"]
                            if c == "ref_id", kind == "memory" { s = label(value) }
                            if c == "ref_version", kind != "memory" {
                                s = try FactStore.currentVersion(db, kind: kind, ref: ref) == version ? "current" : "stale"
                            }
                        }
                        cells.append("\(c)=\(s)")
                    }
                    return cells.joined(separator: " ")
                }.sorted()
            }
            var g = try FactStore.load(db).graph
            out["answers"] = R6.answers(g).map { "\($0.key): \($0.value.0)" }.sorted()
            out["roles"] = try g.memories.values.filter { kept.contains(labels[$0.id] ?? "") }.flatMap { mem in
                try g.rolePhrases(mem.text).map { phrase in
                    let r = g.resolve(mem, phrase)
                    // A group is made up at each load, with a new id: only its basis compares.
                    let entity = "\(r.basis)" == "group" ? "a group" : r.entity ?? "∅"
                    return "\(labels[mem.id] ?? "?") \(phrase.predicate): \(entity) \(r.basis)"
                }
            }.sorted()
            return out
        }
    }

    // MARK: The fuzz

    static func run(seed: UInt64, vaults: Int, coverage: inout Coverage) throws -> [String] {
        var g = R6RNG(s: seed)
        var failures: [String] = []
        for iter in 0..<vaults where failures.count < 4 {
            let (v, ms, gone) = try randomVault(&g)
            let section = try #require(try v.store.writer.write { db in
                try FactsExport.section(db, exporting: Set(ms.map(\.id.db)), now: t0.plus(days: 30))
            })
            coverage.vaults += 1
            let sources = try v.store.writer.read { db in
                try ms.map { m in
                    let row = try Row.fetchOne(db, sql: "SELECT title, body, created_at, trust FROM memory WHERE id = ?", arguments: [m.id.db])!
                    return Source(id: m.id.db, title: row["title"], body: row["body"], created: row["created_at"], trust: row["trust"])
                }
            }
            let exported = Set(sources.map(\.id))
            let asSuggestions = iter % 6 == 5
            let skipped = asSuggestions ? Set(ms.indices) : Set(ms.indices.filter { _ in g.next(3) == 0 })
            let skippedIDs = Set(skipped.map { sources[$0].id })
            let kept = Set(ms.indices.filter { !skipped.contains($0) }.map { "m\($0)" })
            coverage.suggestions += asSuggestions ? 1 : 0
            coverage.skippedDecisions += section.decisions.filter { $0["source"]?.string == "model" && skippedIDs.contains($0["memory_id"]?.string ?? "") }.count
            coverage.skippedCorrections += section.manualOverrides.filter { skippedIDs.contains($0["memory_id"]?.string ?? "") }.count
            coverage.skippedEvidence += section.evidence.filter { skippedIDs.contains($0["memory_id"]?.string ?? "") }.count
            coverage.purgedBeforeExport += section.manualOverrides.filter { gone.contains($0["memory_id"]?.string ?? "") }.count
                + section.decisions.filter { gone.contains($0["memory_id"]?.string ?? "") }.count
            let at = t0.plus(days: 40)
            var common: [String: String] = [:]
            for (k, id) in gone.enumerated() { common[id] = "gone\(k)" }
            for (i, s) in sources.enumerated() { common[s.id] = "m\(i)" }

            // A: restore the subset, sometimes into a vault that already has a skipped memory's exported id.
            let a = try TestVault()
            var mapA: [String: (id: String, version: Int)] = [:], labelsA = common
            for (i, s) in sources.enumerated() {
                if skipped.contains(i) {
                    guard g.next(3) == 0 else { continue }
                    coverage.occupied += 1
                    _ = try a.store.writer.write { db in
                        try MemoryStore.insert(db, MemoryDraft(title: s.title, body: s.body, kind: .fact, categoryKeys: ["personal_preferences"],
                                                               sensitivity: .low), actor: .user, now: s.created, id: UUID(uuidString: s.id)!)
                    }
                    continue
                }
                let m = try copy(s, into: a)
                mapA[s.id] = (m.id.db, m.version)
                labelsA[m.id.db] = "m\(i)"
            }
            _ = try a.store.writer.write { db in
                try FactsExport.restore(db, section, memories: asSuggestions ? nil : mapA, exported: exported, now: at)
            }

            // B: restore everything, then delete and purge the skipped memories.
            let b = try TestVault()
            var mapB: [String: (id: String, version: Int)] = [:], labelsB = common, restoredB: [Int: UUID] = [:]
            for (i, s) in sources.enumerated() {
                let m = try copy(s, into: b)
                mapB[s.id] = (m.id.db, m.version)
                labelsB[m.id.db] = "m\(i)"
                restoredB[i] = m.id
            }
            _ = try b.store.writer.write { db in try FactsExport.restore(db, section, memories: mapB, exported: exported, now: at) }
            for i in skipped.sorted() {
                _ = try b.store.deleteMemory(id: restoredB[i]!, now: at)
                try b.store.purgeMemory(id: restoredB[i]!, now: at)
            }

            // C: the source vault itself, with the skipped memories deleted and purged.
            for i in skipped.sorted() {
                _ = try v.store.deleteMemory(id: ms[i].id, now: at)
                try v.store.purgeMemory(id: ms[i].id, now: at)
            }

            let runs = !asSuggestions
            let got = try decided(a, labels: labelsA, kept: kept, runs: runs)
            let viaRestore = try decided(b, labels: labelsB, kept: kept, runs: runs)
            let inSource = try decided(v, labels: common, kept: kept, runs: runs)
            coverage.invalidated += got["mention_decision"]?.filter { $0.contains("invalidated_at=invalidated") }.count ?? 0
            for (name, want) in [("restore all, then purge", viaRestore), ("purge in the source", inSource)] {
                for key in want.keys.sorted() where want[key] != got[key] {
                    let w = Set(want[key] ?? []), o = Set(got[key] ?? [])
                    failures.append("seed \(seed) #\(iter) \(key) vs \(name) (skipped \(skipped.sorted())\(asSuggestions ? ", as suggestions" : ""), "
                                    + "purged before export \(gone.count)): theirs only \(w.subtracting(o).sorted()) · subset only \(o.subtracting(w).sorted())")
                    break
                }
            }
        }
        return failures
    }

    @Test(arguments: [UInt64(11), 22, 33])
    func restoringASubsetIsRestoringAllThenPurging(seed: UInt64) throws {
        var coverage = Coverage()
        let failures = try Self.run(seed: seed, vaults: Self.vaultsPerSeed, coverage: &coverage)
        for f in failures { Issue.record("\(f)") }
        print("restore-subset fuzz seed \(seed): \(Self.vaultsPerSeed) vaults, coverage \(coverage)")
        // The fuzz isn't vacuous: every vault was compared; skipped memories carried evidence, model decisions and
        // corrections; decisions went stale; the export carried corrections purged before it; suggestions and occupied
        // ids came up.
        #expect(coverage.vaults == Self.vaultsPerSeed)
        #expect(coverage.skippedEvidence > 0 && coverage.skippedDecisions > 0 && coverage.skippedCorrections > 0)
        #expect(coverage.invalidated > 0 && coverage.purgedBeforeExport > 0 && coverage.suggestions > 0 && coverage.occupied > 0)
    }

    // MARK: Review findings (GPT-6-Astra and Fable 5.2)

    static func decidedExport() throws -> (FactsStoreTests, FunesExportFacts, decided: Memory) {
        let t = try FactsStoreTests()
        let (_, _, _, decided) = try t.decidedState()
        let section = try #require(try t.v.store.writer.write { db in
            try FactsExport.section(db, exporting: Set(try String.fetchAll(db, sql: "SELECT id FROM memory")), now: t0)
        })
        return (t, section, decided)
    }

    // A restore that fails (here, a damaged section) rolls back all it wrote, even when the caller catches the error
    // and commits: foreign keys are deferred only inside its own savepoint, and the setting is put back.
    @Test func aFailedRestoreLeavesNothingBehind() throws {
        var (t, section, _) = try Self.decidedExport()
        section.entities.removeAll { $0["id"]?.string == section.facts.first?["entity_id"]?.string }
        let fresh = try TestVault()
        var map: [String: (id: String, version: Int)] = [:]
        for row in try t.v.store.writer.read({ db in try Row.fetchAll(db, sql: "SELECT id, body FROM memory") }) {
            let m = try fresh.memory("Note", row["body"] as String)
            map[row["id"] as String] = (m.id.db, m.version)
        }
        let threw = try fresh.store.writer.write { db -> Bool in
            do { try FactsExport.restore(db, section, memories: map, now: t0); return false } catch { return true }
        }
        #expect(threw)
        for table in FactsExport.tables.map(\.table) {
            #expect(try fresh.count("SELECT COUNT(*) FROM \(table) \(table == "entity" ? "WHERE is_you = 0" : "")") == 0, "\(table)")
        }
        #expect(try fresh.count("PRAGMA defer_foreign_keys") == 0)
    }

    // A decision whose memory dependency names a memory that didn't come back goes stale, even when the target vault
    // has an unrelated memory under that id at the recorded version.
    @Test func aDependencyOnAMemoryThatDidntComeBackGoesStale() throws {
        // The memory it names carries no learned rows, so nothing but the dependency can make the decision stale.
        let t = try FactsStoreTests()
        _ = try t.decidedState()
        let plain = try t.memory("A note with nothing learned in it.")
        var section = try #require(try t.v.store.writer.write { db in
            try FactsExport.section(db, exporting: Set(try String.fetchAll(db, sql: "SELECT id FROM memory")), now: t0)
        })
        let rows = try t.v.store.writer.read { db in try Row.fetchAll(db, sql: "SELECT id, title, body FROM memory ORDER BY seq") }
        let other = try #require(rows.first { ($0["id"] as String) == plain.id.db })
        let decision = try #require(section.decisions.first { $0["source"]?.string == "model" })
        section.decisionDependencies.append(["decision_id": decision["id"]!, "kind": .string("memory"),
                                             "ref_id": .string(other["id"]), "ref_version": .string("1")])
        let fresh = try TestVault()
        var map: [String: (id: String, version: Int)] = [:]
        for row in rows where (row["id"] as String) != other["id"] as String {
            let m = try fresh.memory(row["title"] as String, row["body"] as String)
            map[row["id"] as String] = (m.id.db, m.version)
        }
        _ = try fresh.store.writer.write { db in
            try MemoryStore.insert(db, MemoryDraft(title: "Note", body: "Something else entirely.", kind: .fact, categoryKeys: ["personal_preferences"],
                                                   sensitivity: .low), actor: .user, now: t0, id: UUID(uuidString: other["id"] as String)!)
        }
        #expect(try fresh.store.writer.write { db in try FactsExport.restore(db, section, memories: map, now: t0.plus(days: 1)) })
        #expect(try fresh.count("SELECT COUNT(*) FROM mention_decision WHERE id = ? AND invalidated_at IS NOT NULL", [decision["id"]!.databaseValue]) == 1)
        #expect(try fresh.count("SELECT COUNT(*) FROM decision_dependency WHERE kind = 'memory' AND ref_id = ?", [other["id"] as String]) == 1)
    }
}
