import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 9 (Fable 5.2).
@Suite struct ReviewRound9Tests {
    let d = FX.dated

    func user(_ status: FactAssertion.Status = .unknown, start: String? = nil, end: String? = nil, selector: DateRange? = nil) -> FactAssertion {
        var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-11-15", status: status, qualifiers: [:], states: true,
                              quote: "", handover: false)
        a.fromUser = true; a.start = start; a.end = end; a.selector = selector
        return a
    }

    // G1: the user gives an end date (no status). A memory that said "current" after that date now makes the user's end
    // a conflict (the new held-after-end rule exempts only a user *status*): the user's date loses to inference.
    @Test func g1_aUsersEndDateWinsOverAMemorysLaterCurrent() {
        var s = stateWith([fact(d, "Acme", "2015", status: .current).at("2020-01-01")])
        s.facts[0].assertions.append(user(end: "2018"))
        let e = s.episodes(of: "Acme")
        #expect(e.count == 1 && e[0].end == DateParser(registry: FX.registry).parse("2018") && !e[0].conflictEnd)
    }

    // G2: the same with a selector on the episode.
    @Test func g2_aUsersSelectedEndDateWinsOverAMemorysLaterCurrent() {
        var s = stateWith([fact(d, "Acme", "2015", status: .current).at("2020-01-01")])
        let ep = s.factEpisodes(s.facts[0])[0]
        s.facts[0].assertions.append(user(end: "2018", selector: DateRange(lo: ep.start!.lo, hi: DateRange.maxDay)))
        let e = s.episodes(of: "Acme")
        #expect(e.count == 1 && !e[0].conflictEnd && e[0].end?.precision == .year)
    }

    // G3 (probe): a stated return is still its own stint, not a conflict, and the first stint keeps its end.
    @Test func g3_aStatedReturnIsNotAConflict() {
        let s = stateWith([fact(d, "Acme", "2010", "2012", status: .former).at("2012-06-01"),
                           fact(d, "Acme", status: .current, quote: "rejoined Acme").at("2016-06-01")])
        let e = s.episodes(of: "Acme")
        #expect(e.count == 2 && !e[0].conflictEnd && e[1].ongoing)
    }

    // G4 (probe): the user rejected "Acme before Initech". Succession still ends Acme at Initech's start: is Acme over?
    @Test func g4_aRejectedOrderAndSuccession() {
        var s = stateWith([fact(d, "Acme", "2012", status: .current).at("2013-06-01"),
                           fact(d, "Initech", "2020", status: .current).at("2020-06-01")])
        s.rejectedEdges.append(FactsGraph.EdgeRejection(from: s.ent("Acme"), to: s.ent("Initech")))
        let cur = s.answer(TimelineIntent(predicate: d, op: .current, anchor: nil))
        #expect(s.beforeName("Initech").0 == nil)                    // the rejection holds
        #expect(!s.episodes(of: "Acme")[0].inferredEnd)              // …and the inference it rejects isn't made elsewhere
    }
}

@Suite struct ReviewRound9StoreTests {
    let v: TestVault
    let d = FX.dated
    init() throws { v = try TestVault() }

    func add(_ body: String, _ f: ExtractedFact, days: Double) throws -> Memory {
        let m = try v.memory("Note", body, now: t0.plus(days: days))
        try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: m.version, extraction: FactsExtraction(facts: [f]),
                                callGroup: FX.registry.predicate(d)!.callGroup, now: t0.plus(days: days))
        }
        return m
    }

    // T1 (probe): a tombstone re-attaches on a normalised-exact name ("ACME Inc."), never on a contained one ("Acme Labs").
    @Test func t1_aTombstoneReattachesOnlyOnAnExactName() throws {
        let m = try add("I joined Acme in 2018.", fact(d, "Acme", "2018", quote: "I joined Acme in 2018"), days: 0)
        let acme = try #require(try v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT entity_id FROM entity_alias WHERE alias = 'Acme'") })
        let fid = try #require(try v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM fact WHERE entity_id = ?", arguments: [acme]) })
        try v.store.writer.write { db in
            try FactStore.confirmAlias(db, entityID: acme, alias: "Acme", now: t0)
            _ = try FactStore.addUserEvidence(db, factID: fid, asserted: ["start": "2017"], sensitivity: 1, now: t0)
        }
        _ = try v.store.deleteMemory(id: m.id, now: t0.plus(days: 1))
        try v.store.purgeMemory(id: m.id, now: t0.plus(days: 2))
        #expect(try v.count("SELECT tombstone FROM entity WHERE id = ?", [acme]) == 1)
        _ = try add("I consult for Acme Labs.", fact(d, "Acme Labs", quote: "Acme Labs"), days: 3)
        #expect(try v.count("SELECT tombstone FROM entity WHERE id = ?", [acme]) == 1)          // the contained name doesn't
        #expect(try v.count("SELECT COUNT(*) FROM fact_evidence WHERE fact_id = ? AND source = 'memory'", [fid]) == 0)
        _ = try add("ACME Inc. hired me back.", fact(d, "ACME Inc.", quote: "ACME Inc."), days: 4)
        #expect(try v.count("SELECT tombstone FROM entity WHERE id = ?", [acme]) == 0)          // the exact one does
        #expect(try v.count("SELECT COUNT(*) FROM fact_evidence WHERE fact_id = ? AND source = 'memory'", [fid]) == 1)
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        #expect(g.episodes(d).first { $0.entity == acme }?.start == DateParser(registry: FX.registry).parse("2017"))   // the user's date still wins
    }
}

/// Adversarial review, round 9 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound9AstraTests {
    let d = FX.dated

    func datedEmployers() -> FactsGraph {
        stateWith([fact(d, "Acme", "2018", "2019-03-31", status: .former).at("2019-04-01"),
                   fact(d, "Initech", "2019-04-01", status: .current).at("2020-01-01")])
    }

    @Test(arguments: ["At my JOB on 15 March 2019 I used Emacs.", "On 15 March 2019, my JOB paid for it.", "My JOB on March 15, 2019 was busy."])
    func j1_aDayCueSelectsTheHistoricalEmployer(_ template: String) {
        var s = datedEmployers()
        let got = s.resolveText(template.replacingOccurrences(of: "JOB", with: FX.word(d)), "2020-01-01")
        #expect(got.0 == "Acme" && got.1 == .soleKnown)
    }

    @Test func j2_anAmbiguousOrderNameCreatesNoEdges() {
        let s = stateWith([fact(d, "Acme North", status: .former).at("2018-01-01"),
                           fact(d, "Acme South", status: .former).at("2018-01-01"),
                           fact(d, "Initech", precededBy: "Acme").at("2019-01-01")])
        for name in ["Acme North", "Acme South"] { #expect(s.after(d, .entity(s.ent(name))).isAmbiguous) }
    }

    @Test func j3_aConflictingSuccessorEndsNothing() {
        var s = stateWith([fact(d, "Acme", "2010", status: .current).at("2011-01-01"),
                           fact(d, "Globex", "2015", status: .current).at("2016-01-01"),
                           fact(d, "Globex", "2019", status: .current).at("2020-01-01")])
        #expect(s.episodes(of: "Acme").first?.inferredEnd == false)
        let got = s.resolveText("At my \(FX.word(d)) I use Emacs.", "2021-01-01")
        #expect(got.0 == nil && got.1 == .candidates)
    }

    @Test func j5_aSharedFirstNameKeepsAllCandidates() throws {
        let p = FX.personExclusive
        let reg = try FX.registry { json in FX.editPredicate(&json, p) { $0["uses"] = ["recorded", "linked", "timeline"] } }
        var s = FactsGraph(registry: reg)
        for (i, (name, start, end)) in [("Alex", "2015", "2017"), ("Alex Smith", "2018", "2019"), ("Bea", "2013", "2014")].enumerated() {
            s.apply(FactsMemory(id: "m\(i)", text: name, written: "2020-01-01"), people: [ExtractedPerson(name: name)],
                    facts: [fact(p, name, start, end, status: .former)])
        }
        #expect(s.entityMatches(p, "Alex").count == 2)
        let q = "Who was my \(FX.word(p)) before Alex?"
        if let it = s.intent(q) { #expect(s.answer(it, query: q).isAmbiguous) }
    }
}

@Suite struct ReviewRound9AstraStoreTests {
    let d = FX.dated

    @Test func j4_aRestoreKeepsHistoricalResolution() async throws {
        let v = try TestVault()
        let day = { (y: Int, m: Int, dd: Int) in Calendar.current.date(from: DateComponents(year: y, month: m, day: dd, hour: 12))! }
        for (text, f, at) in [("I worked at Acme from 2018 to 31 March 2019.", fact(d, "Acme", "2018", "2019-03-31", status: .former, quote: "I worked at Acme from 2018 to 31 March 2019"), day(2019, 4, 1)),
                              ("I joined Initech on 1 April 2019.", fact(d, "Initech", "2019-04-01", status: .current, quote: "I joined Initech on 1 April 2019"), day(2020, 1, 1))] {
            let m = try v.memory("Note", text, now: at)
            _ = try await v.store.writer.write { db in
                try FactStore.apply(db, memoryID: m.id.db, version: m.version, extraction: FactsExtraction(facts: [f]),
                                    callGroup: FX.registry.predicate(d)!.callGroup, now: t0)
            }
        }
        let note = try v.memory("Note", "At my \(FX.word(d)) I use Emacs.", now: day(2019, 3, 15))
        func link(_ store: VaultStore, _ id: UUID) async throws -> String? {
            var g = try await store.writer.read { db in try FactStore.load(db).graph }
            let text = FactStore.text(title: "Note", body: "At my \(FX.word(d)) I use Emacs.")
            let (created, src, trust) = try await store.writer.read { db -> (Date, String, String) in
                let row = try Row.fetchOne(db, sql: "SELECT created_at, COALESCE(original_source, source) AS s, trust FROM memory WHERE id = ?",
                                           arguments: [id.db])!
                return (row["created_at"], row["s"], row["trust"])
            }
            let mem = FactsMemory(id: id.db, text: text, written: FactStore.writtenDay(created), source: FactStore.source(src),
                                  trusted: trust == "trusted")
            let r = g.resolve(mem, g.rolePhrases(text)[0])
            return g.name(r.entity)
        }
        #expect(try await link(v.store, note.id) == "Acme")
        let export = try ImportParser.funesExport(try await ImportService(store: v.store, activity: InMemoryActivityLog()).export(now: t0))
        let fresh = try TestVault()
        let importer = ImportService(store: fresh.store, activity: InMemoryActivityLog())
        _ = try await importer.commit(try await importer.preview(funesExport: export), asMemories: true, now: t0.plus(days: 400))
        #expect(try await link(fresh.store, note.id) == "Acme")
    }
}
