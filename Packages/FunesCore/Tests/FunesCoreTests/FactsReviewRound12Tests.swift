import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 12 (Fable 5.2).
@Suite struct ReviewRound12Tests {
    let d = FX.dated
    var job: String { "At my \(FX.word(d)) I use Emacs." }

    // Q1: two memories disagree on when a job ended (2012 or 2018). Either way it was over by 2018, but "a conflicting
    // end rules no one out" now keeps it a possible holder for ever: "my job" in 2024 is no longer the current one.
    @Test func q1_aJobWhoseEndDatesDisagreeIsStillOverAfterBoth() {
        let base = [fact(d, "Initech", "2019", status: .current).at("2024-01-01")] as [FactRowConvertible]
        var one = stateWith(base + [fact(d, "Acme", "2010", "2012", status: .former).at("2012-06-01")])
        var two = stateWith(base + [fact(d, "Acme", "2010", "2012", status: .former).at("2012-06-01"),
                                    fact(d, "Acme", nil, "2018", status: .former).at("2018-06-01")])
        #expect(two.episodes(of: "Acme").count == 1 && two.episodes(of: "Acme")[0].conflictEnd)
        let (a, b) = (one.resolveText(job, "2024-06-01"), two.resolveText(job, "2024-06-01"))
        print("Q1", a, "→", b, "mayHold 2024:", two.episodes(of: "Acme")[0].mayHold(.day(DayNumber.from(year: 2024, month: 6, day: 1)!)))
        #expect(b.0 == "Initech")
    }

    // Q2 (probe): the case the rule was made for still works: "still current" after a stated end keeps the holder possible.
    @Test func q2_aHeldAfterEndConflictStillKeepsTheHolder() {
        var s = stateWith([fact(d, "Acme", "2010", "2012", status: .former).at("2012-06-01"),
                           fact(d, "Acme", status: .current).at("2016-06-01")])
        #expect(s.episodes(of: "Acme")[0].conflictEnd)
        #expect(s.resolveText(job, "2017-06-01").0 == "Acme")
    }
}

@Suite struct ReviewRound12StoreTests {
    let v: TestVault
    let d = FX.dated
    init() throws { v = try TestVault() }

    func add(_ body: String, _ f: ExtractedFact, days: Double) throws {
        let m = try v.memory("Note", body, now: t0.plus(days: days))
        try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: m.version, extraction: FactsExtraction(facts: [f]),
                                callGroup: FX.registry.predicate(d)!.callGroup, now: t0.plus(days: days))
        }
    }
    func str(_ sql: String, _ args: StatementArguments = []) throws -> String? {
        try v.store.writer.read { db in try String.fetchOne(db, sql: sql, arguments: args) }
    }

    // Q3 (probe): after Merge With…, the user's latest status (whichever entity it was entered on) decides, and a
    // rejected order naming the merged-away entity still holds against the survivor.
    @Test func q3_mergesKeepTheUsersLatestStatusAndRejectedOrders() throws {
        try add("I joined Kiteworks in 2015.", fact(d, "Kiteworks", "2015", status: .current, quote: "I joined Kiteworks in 2015"), days: 0)
        try add("I work at KW.", fact(d, "KW", status: .current, quote: "KW"), days: 1)
        try add("I joined Initech in 2020.", fact(d, "Initech", "2020", status: .current, quote: "I joined Initech in 2020"), days: 2)
        func eid(_ n: String) throws -> String { try #require(try str("SELECT entity_id FROM entity_alias WHERE alias = ?", [n])) }
        func fid(_ n: String) throws -> String { try #require(try str("SELECT id FROM fact WHERE entity_id = ?", [try eid(n)])) }
        let (kite, kw) = (try eid("Kiteworks"), try eid("KW"))
        let (kiteFact, kwFact, initechFact) = (try fid("Kiteworks"), try fid("KW"), try fid("Initech"))
        try v.store.writer.write { db in
            _ = try FactStore.addUserEvidence(db, factID: kiteFact, asserted: ["status": "current"], sensitivity: 1, now: t0.plus(days: 3))
            _ = try FactStore.addUserEvidence(db, factID: kwFact, asserted: ["status": "former"], sensitivity: 1, now: t0.plus(days: 4))
            _ = try FactStore.override(db, targetKind: "order", targetID: kwFact, field: "rejected",
                                       value: ["before": kwFact, "after": initechFact], sensitivity: 1, now: t0.plus(days: 5))
            _ = try FactStore.override(db, targetKind: "entity", targetID: kw, field: "merged_into", value: kite, sensitivity: 1, now: t0.plus(days: 6))
        }
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        let f = try #require(g.facts.first { $0.entity == kite })
        let before = g.before(d, .entity(g.entityMatches(d, "Initech")[0]))
        #expect(g.facts.filter { $0.entity == kite }.count == 1)
        #expect(g.status(of: f) == .former)                // the later of the user's two statuses
        #expect(before.entity == nil)                       // the rejected order follows the merge
    }
}

/// Adversarial review, round 12 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound12AstraTests {
    let d = FX.dated

    @Test func m1_aConflictingEndCannotEliminateATimelineRival() {
        var s = stateWith([fact(d, "Globex", "2010", "2018", status: .former).at("2019-01-01"),
                           fact(d, "Globex", status: .current).at("2024-01-01"),
                           fact(d, "Acme", "2019", "2024-12-31", status: .former).at("2025-01-01"),
                           fact(d, "Initech", "2025-01-01", status: .current).at("2026-01-01")])
        #expect(s.episodes(of: "Globex")[0].conflictEnd)
        #expect(s.inRange(d, DateParser(registry: FX.registry).parse("2025")!).isAmbiguous)
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
        let link = s.resolveText("At my \(FX.registry.language.dateCueWords[0]) \(FX.word(d)) I used Emacs.", "2025-06-01")
        #expect(link.0 == nil && link.1 == .candidates)
    }

    @Test func m2_aWideDepartureBoundIsNoSameYearHandover() {
        let s = stateWith([fact(d, "Acme", "2010", status: .current).at("2011-01-01"),
                           fact(d, "Acme", status: .former).at("2026-01-01"),
                           fact(d, "Initech", "2019", status: .current).at("2026-01-01")])
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
        #expect(s.after(d, .entity(s.ent("Acme"))).isAmbiguous)
    }
}

@Suite struct ReviewRound12AstraStoreTests {
    @Test func m3_aLabelOverrideSurvivesALaterMerge() throws {
        let v = try TestVault()
        let sib = try #require(FX.registry.predicates.first { p in p.objectKind == "person" && p.lexicon.filter { $0.cls != nil && $0.exclusive != true }.count >= 2 })
        let words = sib.lexicon.filter { $0.cls != nil && $0.exclusive != true }.map { $0.words[0] }
        for (name, word) in [("Alex", words[1]), ("Bea", words[0])] {
            let m = try v.memory("Note", "My \(word) \(name) visited.")
            _ = try v.store.writer.write { db in
                try FactStore.apply(db, memoryID: m.id.db, version: m.version,
                                    extraction: FactsExtraction(people: [ExtractedPerson(name: name)],
                                                                facts: [fact(sib.id, name, label: word, quote: "My \(word) \(name)")]),
                                    callGroup: sib.callGroup, now: t0)
            }
        }
        let alex = try #require(try v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT entity_id FROM entity_alias WHERE alias = 'Alex'") })
        try v.store.writer.write { db in
            let lex = try FactStore.addManualFact(db, predicate: sib.id, name: "Lex", sensitivity: 1, now: t0)
            _ = try FactStore.override(db, targetKind: "qualifier", targetID: lex.fact, field: "label", value: words[0], sensitivity: 1, now: t0)
            _ = try FactStore.override(db, targetKind: "entity", targetID: lex.entity, field: "merged_into", value: alex, sensitivity: 1,
                                       now: t0.plus(days: 1))
        }
        var g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        #expect(g.resolveText("My \(words[0]) recommended it.", "2026-06-01").1 == .candidates)
    }
}
