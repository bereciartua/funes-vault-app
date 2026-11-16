import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Learned facts in the vault (storage §2 `v9_facts`, memory processing §11.8): the migration, apply and load, and
/// the lifecycle, with a test per rule in Phase 13a.1.
@Suite struct FactsStoreTests {
    let v: TestVault
    let d = FX.dated
    let pp = FX.personSuccession
    var work: String { FX.registry.predicate(d)!.callGroup }
    var people: String { FX.registry.predicate(pp)!.callGroup }

    init() throws { v = try TestVault() }

    /// A memory whose text (title and body) carries the sentence.
    func memory(_ body: String, at days: Double = 0) throws -> Memory {
        try v.memory("Note", body, now: t0.plus(days: days))
    }

    @discardableResult
    func apply(_ m: Memory, _ x: FactsExtraction, group: String? = nil, at days: Double = 0) throws -> FactStore.ApplyResult {
        let current = try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
        return try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: current.version, extraction: x, callGroup: group ?? work,
                                now: t0.plus(days: days))
        }
    }

    func str(_ sql: String, _ args: StatementArguments = []) throws -> String? {
        try v.store.writer.read { db in try String.fetchOne(db, sql: sql, arguments: args) }
    }

    func load() throws -> FactStore.Loaded { try v.store.writer.read { db in try FactStore.load(db) } }

    func write<T>(_ body: (Database) throws -> T) throws -> T { try v.store.writer.write(body) }

    func entityID(_ name: String) throws -> String? {
        try v.store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT entity_id FROM entity_alias WHERE alias = ? OR normalized = ?",
                                arguments: [name, FactsText.fold(name)])
        }
    }

    func factID(_ name: String, _ pred: String? = nil) throws -> String? {
        try v.store.writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT f.id FROM fact f JOIN entity_alias a ON a.entity_id = f.entity_id
                WHERE (a.alias = ? OR a.normalized = ?) AND f.predicate = ?
                """, arguments: [name, FactsText.fold(name), pred ?? d])
        }
    }

    // MARK: The migration

    @Test func theMigrationCreatesYouTheEpochAndFactsJobs() throws {
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE is_you = 1") == 1)
        let rev = try v.store.factsRevision()
        #expect(rev.hasSuffix(".0") && rev.count > 30)
        _ = try write { db in
            for group in ["people", "work", "people"] {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO processing_job (id, subject, kind, memory_version, call_group, created_at, updated_at)
                    VALUES (?, 'm1', 'facts', 1, ?, ?, ?)
                    """, arguments: [UUID().db, group, t0, t0])
            }
        }
        #expect(try v.count("SELECT COUNT(*) FROM processing_job WHERE kind = 'facts'") == 2)   // one per call group
    }

    @Test func aVersion8VaultMigratesWithItsJobs() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "funes-v8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "vault.sqlite")
        do {
            let queue = try DatabaseQueue(path: file.path)
            try Schema.migrator.migrate(queue, upTo: "v8_tidy_up_scope")
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO processing_job (id, subject, kind, created_at, updated_at) VALUES ('j1', 's1', 'new_memory', ?, ?)
                    """, arguments: [t0, t0])
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = try VaultStore.open(directory: directory)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Backups").path)
        #expect(backups.contains { $0.hasPrefix("pre-v9_facts") })
        let (kind, you, revision) = try await store.writer.read { db in
            (try String.fetchOne(db, sql: "SELECT kind FROM processing_job WHERE id = 'j1'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entity WHERE is_you = 1"),
             try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'facts_revision'"))
        }
        #expect(kind == "new_memory" && you == 1 && revision == "0")
    }

    // MARK: Apply and load

    @Test func anExtractionRoundTripsThroughTheStore() throws {
        let m = try memory("I joined Acme in 2018 and still work there.")
        let r = try apply(m, FactsExtraction(facts: [fact(d, "Acme", "2018", status: .current, quote: "I joined Acme in 2018")]))
        #expect(r.entities == 1 && r.facts == 1 && r.evidence == 1)
        let g = try load().graph
        let acme = try #require(g.entityMatches(d, "Acme").first)
        let eps = g.episodes(d)
        #expect(eps.count == 1 && eps[0].entity == acme && eps[0].tstart?.precision == .year && eps[0].ongoing)
        #expect(try v.count("SELECT COUNT(*) FROM alias_evidence") == 1)
        #expect(try v.store.factsRevision().hasSuffix(".1"))
        // A re-read of the same version replaces its evidence rather than adding to it.
        try apply(m, FactsExtraction(facts: [fact(d, "Acme", "2018", status: .current, quote: "I joined Acme in 2018")]))
        #expect(try v.count("SELECT COUNT(*) FROM fact_evidence") == 1)
    }

    @Test func applyRefusesAChangedMemoryOrRoster() throws {
        let m = try memory("I joined Acme in 2018.")
        #expect(throws: FactStore.ApplyError.memoryChanged) {
            try write { db in try FactStore.apply(db, memoryID: m.id.db, version: m.version + 1, extraction: FactsExtraction(),
                                                  callGroup: work) }
        }
        try apply(m, FactsExtraction(facts: [fact(d, "Acme", "2018", quote: "I joined Acme in 2018")]))
        let acme = try #require(try entityID("Acme"))
        #expect(throws: FactStore.ApplyError.rosterChanged) {
            try apply(m, FactsExtraction(roster: [acme: "stale"]))
        }
    }

    // MARK: Lifecycle

    @Test func anEditDropsOldEvidenceAndAStatusChangeCarriesItForward() throws {
        let edited = try memory("I joined Acme in 2018.")
        try apply(edited, FactsExtraction(facts: [fact(d, "Acme", "2018", quote: "I joined Acme in 2018")]))
        let kept = try memory("I joined Globex in 2010 and left in 2014.")
        try apply(kept, FactsExtraction(facts: [fact(d, "Globex", "2010", "2014", status: .former, quote: "I joined Globex in 2010")]))

        _ = try v.store.updateMemory(id: edited.id, MemoryEdit(body: "I joined Initech in 2018."), now: t0.plus(days: 1))
        #expect(try v.count("SELECT COUNT(*) FROM fact_evidence WHERE memory_id = ?", [edited.id.db]) == 0)
        #expect(try entityID("Acme") == nil)                            // nothing else supported it

        let archived = try v.store.archiveMemory(id: kept.id, now: t0.plus(days: 1))
        #expect(try v.count("SELECT COUNT(*) FROM fact_evidence WHERE memory_id = ? AND memory_version = ?",
                            [kept.id.db, archived.version]) == 1)
        let restored = try v.store.restoreMemory(id: kept.id, now: t0.plus(days: 2))
        #expect(try v.count("SELECT COUNT(*) FROM alias_evidence WHERE memory_id = ? AND memory_version = ?",
                            [kept.id.db, restored.version]) == 1)
        #expect(try load().graph.entityMatches(d, "Globex").count == 1)
    }

    @Test func anArchivesEffectDependsOnWhy() throws {
        let superseded = try memory("I joined Acme in 2018 and work there now.")
        try apply(superseded, FactsExtraction(facts: [fact(d, "Acme", "2018", status: .current, quote: "I joined Acme in 2018")]))
        let conflict = try memory("I work at Globex since 2019.")
        try apply(conflict, FactsExtraction(facts: [fact(d, "Globex", "2019", status: .current, quote: "I work at Globex since 2019")]))
        let expired = try memory("I work at Hooli since 2020.")
        try apply(expired, FactsExtraction(facts: [fact(d, "Hooli", "2020", status: .current, quote: "I work at Hooli since 2020")]))
        for m in [superseded, conflict, expired] { _ = try v.store.archiveMemory(id: m.id, now: t0.plus(days: 1)) }
        let globex = try #require(try factID("Globex"))
        _ = try write { db in
            try FactStore.archived(db, memoryID: superseded.id.db, reason: .superseded, now: t0.plus(days: 1))
            try FactStore.archived(db, memoryID: conflict.id.db, reason: .conflict(facts: [globex]), now: t0.plus(days: 1))
            try FactStore.archived(db, memoryID: expired.id.db, reason: .expired, now: t0.plus(days: 1))
        }
        let g = try load().graph
        let acme = g.episodes(of: "Acme")
        #expect(acme.count == 1 && acme[0].tstart != nil && acme[0].heldAt == nil)   // the date stays, "current" doesn't
        #expect(g.entityMatches(d, "Globex").isEmpty && g.entityMatches(d, "Hooli").isEmpty)
    }

    @Test func aPurgeRemovesInferredNamesEverywhere() throws {
        let m = try memory("My boss Robin approved the plan.")
        try apply(m, FactsExtraction(people: [ExtractedPerson(name: "Robin")],
                                     facts: [fact(pp, "Robin", label: FX.word(pp), quote: "My boss Robin")]), group: people)
        #expect(try entityID("Robin") != nil)
        _ = try v.store.deleteMemory(id: m.id, now: t0.plus(days: 1))
        try v.store.purgeMemory(id: m.id, now: t0.plus(days: 2))
        for sql in ["SELECT COUNT(*) FROM entity WHERE name LIKE '%Robin%'", "SELECT COUNT(*) FROM entity_alias WHERE alias LIKE '%Robin%'",
                    "SELECT COUNT(*) FROM alias_evidence", "SELECT COUNT(*) FROM fact_evidence", "SELECT COUNT(*) FROM fact",
                    "SELECT COUNT(*) FROM mention_decision WHERE quote LIKE '%Robin%'", "SELECT COUNT(*) FROM entity WHERE is_you = 0"] {
            #expect(try v.count(sql) == 0, "\(sql)")
        }
    }

    @Test func aPurgeKeepsWhatTheUserMadeAsATombstoneThatReattaches() throws {
        let m = try memory("My boss Robin approved the plan.")
        try apply(m, FactsExtraction(people: [ExtractedPerson(name: "Robin")],
                                     facts: [fact(pp, "Robin", label: FX.word(pp), quote: "My boss Robin")]), group: people)
        let robin = try #require(try entityID("Robin"))
        let fid = try #require(try factID("Robin", pp))
        _ = try write { db in
            try FactStore.confirmAlias(db, entityID: robin, alias: "Robin", now: t0)
            try FactStore.override(db, targetKind: "entity", targetID: robin, field: "deceased", value: false, sensitivity: 1, now: t0)
            try FactStore.addUserEvidence(db, factID: fid, asserted: ["start": "2015"], sensitivity: 1, now: t0)
        }
        _ = try v.store.deleteMemory(id: m.id, now: t0.plus(days: 1))
        try v.store.purgeMemory(id: m.id, now: t0.plus(days: 2))
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE id = ? AND tombstone = 1 AND name IS NULL", [robin]) == 1)
        #expect(try v.count("SELECT COUNT(*) FROM entity_alias WHERE entity_id = ?", [robin]) == 1)
        #expect(try v.count("SELECT COUNT(*) FROM entity_alias WHERE entity_id = ? AND alias IS NULL AND normalized = 'robin'", [robin]) == 1)
        #expect(try v.count("SELECT tombstone FROM fact WHERE id = ?", [fid]) == 1)
        #expect(try v.count("SELECT COUNT(*) FROM fact_evidence WHERE fact_id = ? AND source = 'user'", [fid]) == 1)
        // A memory supports the same predicate and alias again: the tombstone re-attaches, same ids.
        let again = try memory("My boss Robin called today.", at: 3)
        try apply(again, FactsExtraction(people: [ExtractedPerson(name: "Robin")],
                                         facts: [fact(pp, "Robin", label: FX.word(pp), quote: "My boss Robin")]),
                  group: people, at: 3)
        #expect(try v.count("SELECT tombstone FROM entity WHERE id = ?", [robin]) == 0)
        #expect(try str("SELECT alias FROM entity_alias WHERE entity_id = ?", [robin]) == "Robin")
        #expect(try str("SELECT id FROM fact WHERE entity_id = ? AND predicate = ?", [robin, pp]) == fid)
        #expect(try v.count("SELECT tombstone FROM fact WHERE id = ?", [fid]) == 0)
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE is_you = 0") == 1)
    }

    /// Two managers, and a memory whose "my boss" the model decided was Ana.
    private func decidedState() throws -> (decision: String, ana: String, bo: String, memory: Memory) {
        let a = try memory("Ana became my boss.")
        try apply(a, FactsExtraction(people: [ExtractedPerson(name: "Ana")],
                                     facts: [fact(pp, "Ana", status: .current, quote: "Ana became my boss")]), group: people)
        let b = try memory("Bo is my boss too.")
        try apply(b, FactsExtraction(people: [ExtractedPerson(name: "Bo")],
                                     facts: [fact(pp, "Bo", status: .current, quote: "Bo is my boss")]), group: people)
        let ana = try #require(try entityID("Ana")), bo = try #require(try entityID("Bo"))
        let m = try memory("Yesterday my boss approved the budget.")
        let rosterAt = try v.store.writer.read { db in
            try Dictionary(uniqueKeysWithValues: [ana, bo].map { ($0, try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [$0])!) })
        }
        let r = try apply(m, FactsExtraction(roles: [ExtractedRole(phrase: 0, refersTo: ana)], roster: rosterAt), group: people)
        #expect(r.decisions == 1)
        let decision = try v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM mention_decision WHERE source = 'model'")! }
        return (decision, ana, bo, m)
    }

    @Test func aDecisionIsInvalidatedWhenAFactItDependsOnChanges() throws {
        let (decision, _, bo, m) = try decidedState()
        var loaded = try load().graph
        let mem = loaded.memories[m.id.db]!
        #expect(loaded.resolve(mem, loaded.rolePhrases(mem.text)[0]).basis == .context)
        // A new memory about Bo changes a fact the decision depends on.
        let more = try memory("Bo has been my boss since 2019.", at: 2)
        try apply(more, FactsExtraction(people: [ExtractedPerson(name: "Bo", person: bo)],
                                        facts: [fact(pp, "Bo", "2019", status: .current, quote: "Bo has been my boss since 2019")],
                                        roster: [bo: try v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [bo])! }]),
                  group: people, at: 2)
        #expect(try v.count("SELECT COUNT(*) FROM mention_decision WHERE id = ? AND invalidated_at IS NOT NULL", [decision]) == 1)
        loaded = try load().graph
        #expect(loaded.resolve(mem, loaded.rolePhrases(mem.text)[0]).basis == .candidates)
    }

    @Test func aDecisionGoesWhenItsMemorysTextChanges() throws {
        let (decision, _, _, m) = try decidedState()
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(body: "Yesterday my boss approved the new budget."), now: t0.plus(days: 1))
        #expect(try v.count("SELECT COUNT(*) FROM mention_decision WHERE id = ?", [decision]) == 0)
    }

    @Test func aCorrectionKeyedToItsSpanSurvivesEditsMergesAndSplits() throws {
        let (_, ana, bo, m) = try decidedState()
        _ = try write { db in
            _ = try FactStore.decideMention(db, memoryID: m.id.db, quote: "my boss", entityID: ana, outcome: "rejected", now: t0)
        }
        func resolved(_ id: UUID) throws -> String? {
            var g = try load().graph
            guard let mem = g.memories[id.db], let ph = g.rolePhrases(mem.text).first else { return nil }
            return g.resolve(mem, ph).entity
        }
        #expect(try resolved(m.id) == bo)                                         // Not Ana
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(body: "Last week my boss approved the budget."), now: t0.plus(days: 1))
        #expect(try resolved(m.id) == bo)                                         // the span survived the edit
        // A tidy-up merge moves it to the memory that inherits the span.
        let merged = try memory("Last week my boss approved the budget, and the hires.", at: 2)
        try write { db in try FactStore.moveCorrections(db, from: [m.id.db], to: merged.id.db, now: t0.plus(days: 2)) }
        #expect(try v.count("SELECT COUNT(*) FROM mention_decision WHERE source = 'user' AND memory_id = ?", [merged.id.db]) == 1)
        #expect(try resolved(merged.id) == bo)
        // An edit that drops the span drops the correction's effect.
        _ = try v.store.updateMemory(id: merged.id, MemoryEdit(body: "The budget was approved."), now: t0.plus(days: 3))
        #expect(try load().graph.rejections.isEmpty)
    }

    @Test func manualOverridesWinOverInference() throws {
        let m = try memory("I joined Acme in 2018. My boss Robert is kind.")
        try apply(m, FactsExtraction(facts: [fact(d, "Acme", "2018", status: .current, quote: "I joined Acme in 2018")]))
        try apply(m, FactsExtraction(people: [ExtractedPerson(name: "Robert")],
                                     facts: [fact(pp, "Robert", label: FX.word(pp), quote: "My boss Robert")]), group: people)
        let robert = try #require(try entityID("Robert"))
        let acme = try #require(try factID("Acme"))
        let robertFact = try #require(try factID("Robert", pp))
        _ = try write { db in
            try FactStore.override(db, targetKind: "entity", targetID: robert, field: "name", value: "Bob", sensitivity: 1, now: t0)
            try FactStore.addUserEvidence(db, factID: acme, asserted: ["start": "2017"], sensitivity: 1, now: t0)
            try FactStore.override(db, targetKind: "fact", targetID: robertFact, field: "rejected", value: true, sensitivity: 1, now: t0)
        }
        let g = try load().graph
        #expect(g.entities[robert]?.name == "Bob")
        #expect(g.episodes(of: "Acme").first?.tstart == DateParser(registry: FX.registry).parse("2017"))   // the user's date
        #expect(!g.facts.contains { $0.entity == robert })                     // rejected everywhere
    }

    @Test func removeLearnedFactsKeepsWhatTheUserMade() throws {
        let m = try memory("I joined Acme in 2018. My boss Robin is kind.")
        try apply(m, FactsExtraction(facts: [fact(d, "Acme", "2018", status: .current, quote: "I joined Acme in 2018")]))
        try apply(m, FactsExtraction(people: [ExtractedPerson(name: "Robin")],
                                     facts: [fact(pp, "Robin", quote: "My boss Robin")]), group: people)
        let robin = try #require(try entityID("Robin"))
        let manual = try write { db in
            let made = try FactStore.addManualFact(db, predicate: d, name: "Globex", asserted: ["start": "2010", "end": "2014"],
                                                   sensitivity: 1, now: t0)
            try FactStore.override(db, targetKind: "entity", targetID: robin, field: "deceased", value: true, sensitivity: 1, now: t0)
            try db.execute(sql: """
                INSERT INTO fact_qualification (predicate, use, model, prompt_version, registry_version, adapter, batching, gate, passed, recorded_at)
                VALUES (?, 'linked', 'anthropic/haiku', 'p1', 'v1', 'a', 'b', 'links', 0, ?)
                """, arguments: [d, t0])
            return made
        }
        let activity = InMemoryActivityLog()
        let removed = try v.store.removeLearnedFacts(activity: activity, now: t0.plus(days: 1))
        #expect(removed.facts >= 1 && removed.evidence >= 2)
        #expect(try v.count("SELECT COUNT(*) FROM fact_evidence WHERE source = 'memory'") == 0)
        #expect(try v.count("SELECT COUNT(*) FROM alias_evidence") == 0)
        #expect(try factID("Acme") == nil)
        #expect(try v.count("SELECT COUNT(*) FROM fact WHERE id = ? AND manual = 1", [manual.fact]) == 1)
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE id = ? AND tombstone = 1 AND name IS NULL", [robin]) == 1)
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE is_you = 1") == 1)
        #expect(try v.count("SELECT COUNT(*) FROM fact_qualification") == 1)
        let event = try #require(activity.events.first)
        #expect(event.event == "facts_removed" && event.counts["facts"] == removed.facts)
        #expect(try load().graph.entityMatches(d, "Globex").count == 1)
    }

    @Test func aUsersDateFollowsTheEpisodeItsSelectorOverlapsOrGoesToCheck() throws {
        let a = try memory("I worked at Acme from 2014 to 2016.")
        try apply(a, FactsExtraction(facts: [fact(d, "Acme", "2014", "2016", status: .former, quote: "I worked at Acme from 2014 to 2016")]))
        let b = try memory("I went back to Acme in 2020.", at: 1)
        try apply(b, FactsExtraction(facts: [fact(d, "Acme", "2020", status: .current, quote: "I went back to Acme in 2020")]), at: 1)
        let fid = try #require(try factID("Acme"))
        let p = DateParser(registry: FX.registry)
        _ = try write { db in
            try FactStore.addUserEvidence(db, factID: fid, asserted: ["end": "2022", "status": "former"],
                                          selector: p.parse("2020"), sensitivity: 1, now: t0)
        }
        var loaded = try load()
        var eps = loaded.graph.episodes(of: "Acme").stableSorted { $0.sortKey }
        #expect(eps.count == 2 && eps[0].end == p.parse("2016") && eps[1].end == p.parse("2022"))
        #expect(loaded.toCheck.isEmpty)
        _ = try write { db in       // overlaps neither episode
            try FactStore.addUserEvidence(db, factID: fid, asserted: ["start": "2017"], selector: p.parse("2018"), sensitivity: 1, now: t0)
        }
        loaded = try load()
        eps = loaded.graph.episodes(of: "Acme").stableSorted { $0.sortKey }
        #expect(loaded.toCheck.count == 1 && eps.count == 2 && eps[0].tstart == p.parse("2014"))
    }

    @Test func aRunRecordsItsRegistryAndPromptVersions() throws {
        let id = try write { db in
            try FactStore.startRun(db, kind: "backfill", callGroup: work, registryVersion: FX.registry.version,
                                   promptVersion: "work-1", engine: "anthropic/haiku", capExempt: true, now: t0)
        }
        #expect(try str("SELECT registry_version FROM facts_run WHERE id = ?", [id]) == FX.registry.version)
        #expect(try str("SELECT prompt_version FROM facts_run WHERE id = ?", [id]) == "work-1")
    }

    @Test func aRestoreSetsANewFactsEpoch() throws {
        let before = try v.store.factsRevision()
        try write { db in try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('facts_epoch', ?)", arguments: [UUID().db]) }
        #expect(try v.store.factsRevision() != before)
    }
}

/// Storage §5.2: an export round-trips the learned facts, as a purge of what it leaves out would leave them.
@Suite struct FactsExportTests {
    let d = FX.dated

    private func vaultWithFacts() throws -> (TestVault, kept: Memory, left: Memory) {
        let v = try TestVault()
        let kept = try v.memory("Note", "I joined Acme in 2018.")
        let left = try v.memory("Note", "I worked at Globex until 2017.")
        try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: kept.id.db, version: kept.version,
                                extraction: FactsExtraction(facts: [fact(d, "Acme", "2018", status: .current, quote: "I joined Acme in 2018")]),
                                callGroup: FX.registry.predicate(d)!.callGroup, now: t0)
            try FactStore.apply(db, memoryID: left.id.db, version: left.version,
                                extraction: FactsExtraction(facts: [fact(d, "Globex", nil, "2017", status: .former, quote: "I worked at Globex until 2017")]),
                                callGroup: FX.registry.predicate(d)!.callGroup, now: t0)
            _ = try FactStore.addManualFact(db, predicate: d, name: "Initech", asserted: ["start": "2005"], sensitivity: 1, now: t0)
        }
        _ = try v.store.archiveMemory(id: left.id, now: t0)
        return (v, kept, left)
    }

    @Test func anExportRoundTripsTheLearnedFactsOfWhatItHolds() async throws {
        let (v, kept, _) = try vaultWithFacts()
        let data = try await ImportService(store: v.store, activity: InMemoryActivityLog()).export(now: t0)
        let export = try ImportParser.funesExport(data)
        let facts = try #require(export.facts)
        let names = Set(facts.aliases.compactMap { $0["alias"]?.string })
        #expect(names == ["Acme", "Initech"])                         // Globex's memory was left out (archived)
        #expect(!String(decoding: data, as: UTF8.self).contains("Globex"))
        #expect(try v.count("SELECT COUNT(*) FROM entity_alias WHERE alias = 'Globex'") == 1)   // the vault is unchanged

        let fresh = try TestVault()
        let importer = ImportService(store: fresh.store, activity: InMemoryActivityLog())
        let preview = try await importer.preview(funesExport: export)
        #expect(!preview.factsNotRestored)
        let result = try await importer.commit(preview, asMemories: true, now: t0)
        #expect(result.restoredFacts)
        let g = try await fresh.store.writer.read { db in try FactStore.load(db).graph }
        #expect(g.entityMatches(d, "Acme").count == 1 && g.entityMatches(d, "Initech").count == 1)
        #expect(g.episodes(of: "Acme").first?.ongoing == true)
        #expect(try fresh.count("SELECT COUNT(*) FROM fact_evidence WHERE memory_id = ?", [kept.id.db]) == 1)
    }

    @Test func restoredAsSuggestionsOnlyWhatTheUserMadeComesBack() async throws {
        let (v, _, _) = try vaultWithFacts()
        let export = try ImportParser.funesExport(try await ImportService(store: v.store, activity: InMemoryActivityLog()).export(now: t0))
        let fresh = try TestVault()
        let importer = ImportService(store: fresh.store, activity: InMemoryActivityLog())
        _ = try await importer.commit(try await importer.preview(funesExport: export), now: t0)
        #expect(try fresh.count("SELECT COUNT(*) FROM fact_evidence WHERE source = 'memory'") == 0)
        #expect(try fresh.count("SELECT COUNT(*) FROM entity_alias WHERE alias = 'Acme'") == 0)
        #expect(try fresh.count("SELECT COUNT(*) FROM fact WHERE manual = 1") == 1)
    }

    @Test func factsArentRestoredIntoAVaultThatHasItsOwn() async throws {
        let (v, _, _) = try vaultWithFacts()
        let export = try ImportParser.funesExport(try await ImportService(store: v.store, activity: InMemoryActivityLog()).export(now: t0))
        let other = try vaultWithFacts().0
        let importer = ImportService(store: other.store, activity: InMemoryActivityLog())
        let preview = try await importer.preview(funesExport: export)
        #expect(preview.factsNotRestored)
        #expect(try await !importer.commit(preview, asMemories: true, now: t0).restoredFacts)
    }
}
