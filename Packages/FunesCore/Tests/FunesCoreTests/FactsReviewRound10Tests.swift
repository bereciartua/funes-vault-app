import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 10 (Fable 5.2).
@Suite struct ReviewRound10Tests {
    let pp = FX.personSuccession
    var word: String { FX.word(pp) }

    func bosses() -> FactsGraph {
        peopleState(pp, [("Bo", "2015", "2020", .former, "2020-06-01"), ("Ana", "2020", nil, .current, "2024-01-01")])
    }

    // D1: "on" is now a time preposition, so "my boss on 2019 numbers" reads 2019 as when the phrase is about. The
    // link moves from the current boss to the one who held the role in 2019.
    @Test func d1_onBeforeABareYearIsNotATimeCue() {
        var s = bosses()
        let plain = s.resolveText("I went through the numbers with my \(word).", "2024-11-01")
        let text = "I went through it with my \(word) on 2019 numbers."
        let cue = s.rolePhrases(text)[0].timeCue
        let got = s.resolveText(text, "2024-11-01")
        #expect(cue == nil)
        #expect(got.0 == plain.0)
    }

    // D2 (probe): the cue forms the parser reads, at their precision; "on"/"el" with a real day still work.
    @Test func d2_dayMonthAndYearCuesKeepTheirPrecision() {
        let s = bosses()
        let p = DateParser(registry: FX.registry)
        for (tail, precision) in [("on 15 March 2019", DateRange.Precision.day), ("on March 15, 2019", .day), ("on 2019-03-15", .day),
                                  ("in March 2019", .month), ("in 2019", .year), ("el 15 de marzo de 2019", .day),
                                  ("on 3rd May 2019", .day)] {
            let cue = s.rolePhrases("I met my \(word) \(tail) at the office.")[0].timeCue
            #expect(p.parse(cue)?.precision == precision, "\(tail)")
        }
        let before = s.rolePhrases("On 15 March 2019, my \(word) left.")[0].timeCue
        #expect(p.parse(before)?.precision == .day)
    }

    // D3 (probe): a rejected order stops succession for that pair only; a later job still ends nothing it shouldn't,
    // and the user's own status on the first job still wins.
    @Test func d3_aRejectedOrderWithUserRowsAndReturns() {
        let d = FX.dated
        var s = stateWith([fact(d, "Acme", "2012", status: .current).at("2013-06-01"),
                           fact(d, "Initech", "2020", status: .current).at("2020-06-01")])
        s.rejectedEdges.append(FactsGraph.EdgeRejection(from: s.ent("Acme"), to: s.ent("Initech")))
        #expect(!s.episodes(of: "Acme")[0].inferredEnd)
        var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-11-15", status: .former, qualifiers: [:], states: true,
                              quote: "", handover: false)
        a.fromUser = true
        let i = s.facts.firstIndex { $0.entity == s.ent("Acme") }!
        s.facts[i].assertions.append(a)
        let cur = s.answer(TimelineIntent(predicate: d, op: .current, anchor: nil))
        #expect(cur.entities.map { s.name($0)! } == ["Initech"])       // the user said Acme is over
        #expect(s.beforeName("Initech").0 == nil)                       // and the rejected order stays rejected
    }
}

/// Adversarial review, round 10 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound10AstraTests {
    let d = FX.dated

    @Test func k1_anUnrelatedAgainIsNoReturn() {
        let s = stateWith([fact(d, "Acme", "2015", "2018", status: .former).at("2019-01-01"),
                           fact(d, "Acme", status: .current, quote: "I still work at Acme; the printer broke again.").at("2020-06-01"),
                           fact(d, "Initech", "2019", status: .current).at("2020-06-01")])
        #expect(s.beforeName("Initech").1 == .ambiguous)
    }

    @Test func k2_aDayFirstOrdinalKeepsItsDay() throws {
        let s = stateWith([fact(d, "Acme", "2018", "2019-03-09", status: .former).at("2019-03-10"),
                           fact(d, "Initech", "2019-03-10", status: .current).at("2020-01-01")])
        let got = try #require(s.ask("Where did I work before 15th March 2019?"))
        #expect(s.name(got.entity) == "Initech" && got.basis == .ordered)
    }

    @Test(arguments: ["At my JOB in Mar. 2019 I used Emacs.", "In Mar. 2019, my JOB paid for it."])
    func k3_anAbbreviatedMonthKeepsItsCue(_ template: String) {
        var s = stateWith([fact(d, "Acme", "2018", "2019-03-31", status: .former).at("2019-04-01"),
                           fact(d, "Initech", "2019-04-01", status: .current).at("2020-01-01")])
        let got = s.resolveText(template.replacingOccurrences(of: "JOB", with: FX.word(d)), "2020-01-01")
        #expect(got.0 == "Acme" && got.1 == .soleKnown)
    }
}

@Suite struct ReviewRound10AstraStoreTests {
    @Test func k4_theUsersLabelWinsAfterAMerge() throws {
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
            _ = try FactStore.addUserEvidence(db, factID: lex.fact, kind: "qualifier", asserted: ["value": words[0]], qualifier: "label",
                                              sensitivity: 1, now: t0)
            _ = try FactStore.override(db, targetKind: "entity", targetID: lex.entity, field: "merged_into", value: alex, sensitivity: 1, now: t0)
        }
        var g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        #expect(g.resolveText("My \(words[0]) recommended it.", "2026-06-01").1 == .candidates)
    }
}
