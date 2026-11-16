import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 11 (Fable 5.2).
@Suite struct ReviewRound11Tests {
    let d = FX.dated
    let pp = FX.personSuccession
    let px = FX.personExclusive

    // K1: the commonest return for a partner, "back together", is no longer a return cue (it was matched by "again" /
    // "back" forms before the lists were split). A break-up then "we're back together" is now a conflicting end, and
    // "my <partner word>" written afterwards no longer finds them.
    @Test func k1_backTogetherIsAReturn() {
        var s = FactsGraph(registry: FX.registry)
        s.apply(FactsMemory(id: "m0", text: "Ana", written: "2016-01-01"), people: [ExtractedPerson(name: "Ana")],
                facts: [fact(px, "Ana", "2015", status: .current)])
        let ana = s.entities.values.first { $0.name == "Ana" }!.id
        s.apply(FactsMemory(id: "m1", text: "Ana and I broke up", written: "2018-01-01"), people: [ExtractedPerson(name: "Ana", person: ana)],
                facts: [fact(px, "Ana", status: .former, quote: "Ana and I broke up")], roster: [ana])
        s.apply(FactsMemory(id: "m2", text: "Ana and I are back together", written: "2021-01-01"), people: [ExtractedPerson(name: "Ana", person: ana)],
                facts: [fact(px, "Ana", status: .current, quote: "Ana and I are back together")], roster: [ana])
        let eps = s.episodes(px)
        let link = s.resolveText("My \(FX.word(px)) and I went hiking.", "2022-01-01")
        #expect(eps.count == 2 && eps.last?.ongoing == true && !eps.contains { $0.conflictEnd })
        #expect(link.0 == "Ana")
    }

    // K2 (probe): the same for a job, with cues that are in the list, and one that isn't ("returning to").
    @Test func k2_returnCuesForAJob() {
        for (quote, isReturn) in [("I went back to Acme", true), ("I'm back at Acme", true), ("I rejoined Acme", true),
                                  ("I'm returning to Acme", true), ("The Acme printer broke again", false),
                                  ("My second Acme laptop arrived", false)] {
            let s = stateWith([fact(d, "Acme", "2010", "2012", status: .former).at("2012-06-01"),
                               fact(d, "Acme", status: .current, quote: quote).at("2016-06-01")])
            let n = s.episodes(of: "Acme").count
            #expect((n == 2) == isReturn, "\(quote)")
        }
    }

    // K3 (probe): question words still pick an episode ("again", "the second time", "first").
    @Test func k3_questionWordsStillPickAnEpisode() {
        let s = stateWith([fact(d, "Globex", "2008", "2009", status: .former), fact(d, "Acme", "2010", "2012", status: .former),
                           fact(d, "Initech", "2013", "2014", status: .former),
                           fact(d, "Acme", "2015", "2018", status: .former, quote: "rejoined Acme in 2015")])
        #expect(s.beforeName("Acme", "Where did I work before Acme the first time?").0 == "Globex")
        #expect(s.beforeName("Acme", "Where did I work before I joined Acme again?").0 == "Initech")
        #expect(s.beforeName("Acme", "Where did I work before Acme?").1 == .ambiguous)
    }

    // K4 (probe): day and time prepositions.
    @Test func k4_dayAndTimePrepositions() {
        let s = FactsGraph(registry: FX.registry)
        let p = DateParser(registry: FX.registry)
        let w = FX.word(pp)
        for (tail, want) in [("on 3rd May 2019", DateRange.Precision.day as DateRange.Precision?), ("on 15th of March 2019", .day),
                             ("on March 2019", nil), ("on 2019 numbers", nil), ("el 2019", nil), ("in 15 March 2019", .day),
                             ("in Mar. 2019", .month), ("since March 3rd, 2019", .day), ("on May 2019 plans", nil)] {
            let cue = s.rolePhrases("I met my \(w) \(tail) at the office.")[0].timeCue
            #expect(p.parse(cue)?.precision == want, "\(tail)")
        }
        // A month abbreviation's period doesn't end the sentence; a real one does.
        #expect(s.rolePhrases("In Mar. 2019, my \(w) left.")[0].timeCue != nil)
        #expect(s.rolePhrases("Sales dropped in 2019. My \(w) left.")[0].timeCue == nil)
    }
}

/// Adversarial review, round 11 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound11AstraTests {
    let d = FX.dated

    @Test func l1_aConflictingEndCannotEliminateAHolder() {
        let p = FX.personSuccession
        var s = peopleState(p, [("Ana", "2015", "2018", .former, "2019-01-01"), ("Ana", nil, nil, .current, "2024-01-01"),
                                ("Bo", "2020", nil, .current, "2024-01-01")])
        #expect(s.episodes(of: "Ana", p)[0].conflictEnd)
        let got = s.resolveText("My \(FX.word(p)) approved it.", "2025-01-01")
        #expect(got.0 == nil && got.1 == .candidates)
    }

    @Test func l4_anUndatedAnchorCannotHideAnOngoingPredecessor() {
        let s = stateWith([fact(d, "Acme", "2015", status: .current), fact(d, "Initech", status: .current, precededBy: "Acme")])
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
        #expect(s.after(d, .entity(s.ent("Acme"))).isAmbiguous)
    }
}

@Suite struct ReviewRound11AstraStoreTests {
    let d = FX.dated
    var work: String { FX.registry.predicate(d)!.callGroup }

    func ids(_ v: TestVault) throws -> [String: (entity: String, fact: String)] {
        try v.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT a.alias, f.entity_id, f.id FROM fact f JOIN entity_alias a ON a.entity_id = f.entity_id")
                .reduce(into: [:]) { out, r in out[r["alias"] as String] = (r["entity_id"] as String, r["id"] as String) }
        }
    }

    @Test func l2_aMergeKeepsARejectedOrder() throws {
        let v = try TestVault()
        for (text, f) in [("I worked at Acme until December 2018.", fact(d, "Acme", "2015", "December 2018", status: .former, quote: "I worked at Acme until December 2018")),
                          ("I joined Initech on 1 January 2019.", fact(d, "Initech", "2019-01-01", status: .current, quote: "I joined Initech on 1 January 2019"))] {
            let m = try v.memory("Note", text)
            _ = try v.store.writer.write { db in
                try FactStore.apply(db, memoryID: m.id.db, version: m.version, extraction: FactsExtraction(facts: [f]), callGroup: work, now: t0)
            }
        }
        let apex = try v.store.writer.write { db in try FactStore.addManualFact(db, predicate: d, name: "Apex", sensitivity: 1, now: t0) }
        let x = try ids(v)
        try v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "order", targetID: x["Initech"]!.fact, field: "rejected",
                                       value: ["before": x["Acme"]!.fact, "after": x["Initech"]!.fact], sensitivity: 1, now: t0)
            _ = try FactStore.override(db, targetKind: "entity", targetID: x["Acme"]!.entity, field: "merged_into", value: apex.entity,
                                       sensitivity: 1, now: t0.plus(days: 1))
        }
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        #expect(g.before(d, .entity(x["Initech"]!.entity)).isAmbiguous)
    }

    @Test func l3_aMergeKeepsTheUsersLatestStatus() throws {
        let v = try TestVault()
        let made = try v.store.writer.write { db -> ((entity: String, fact: String), (entity: String, fact: String)) in
            let acme = try FactStore.addManualFact(db, predicate: d, name: "Acme", asserted: ["status": "current"], sensitivity: 1, now: t0)
            let apex = try FactStore.addManualFact(db, predicate: d, name: "Apex", asserted: ["status": "former"], sensitivity: 1,
                                                   now: t0.plus(days: 1))
            return (acme, apex)
        }
        try v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "entity", targetID: made.0.entity, field: "merged_into", value: made.1.entity,
                                       sensitivity: 1, now: t0.plus(days: 2))
        }
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        #expect(g.answer(TimelineIntent(predicate: d, op: .current, anchor: nil)).entities.isEmpty)
    }
}
