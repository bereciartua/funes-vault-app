import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 13 (Fable 5.2).
@Suite struct ReviewRound13Tests {
    let d = FX.dated
    var job: String { "At my \(FX.word(d)) I use Emacs." }
    let current = TimelineIntent(predicate: FX.dated, op: .current, anchor: nil)
    func year(_ y: Int) -> DateRange {
        DateRange(lo: DayNumber.from(year: y, month: 1, day: 1)!, hi: DayNumber.from(year: y, month: 12, day: 31)!, precision: .year)
    }

    // V1: an open conflicting end ("still current" after a stated end, no return) may hold today: role resolution says
    // so (candidates), but "current" leaves it out and answers the other job alone at `ordered`.
    @Test func v1_anOpenConflictingEndIsNotSilentlyOverForCurrent() {
        var s = stateWith([fact(d, "Acme", "2010", "2012", status: .former).at("2012-06-01"),
                           fact(d, "Acme", status: .current).at("2016-06-01"),
                           fact(d, "Initech", "2019", status: .current, slot: FX.own).at("2019-06-01")])
        let cur = s.answer(current)
        let link = s.resolveText(job, "2024-06-01")
        #expect(link.1 == .candidates)                                   // Acme may hold today
        #expect(!(cur.entities.map { s.name($0)! } == ["Initech"] && cur.basis == .ordered))
    }

    // V2 (probe): the three kinds of conflicting end, across links, years and before.
    @Test func v2_theThreeKindsOfConflictingEnd() {
        let initech = fact(d, "Initech", "2019", status: .current).at("2019-06-01")
        // (a) two stated ends disagree: over after the later one.
        var a = stateWith([fact(d, "Acme", "2010", "2012", status: .former), fact(d, "Acme", nil, "2018", status: .former), initech])
        #expect(a.resolveText(job, "2024-06-01").0 == "Initech")
        #expect(a.inRange(d, year(2011)).entities.map { a.name($0)! } == ["Acme"])
        #expect(a.inRange(d, year(2015)).isAmbiguous)                    // may or may not have held
        #expect(a.beforeName("Initech").1 == .ambiguous)                 // the conflicting end decides nothing
        // (b) "still current" after a stated end: open.
        var b = stateWith([fact(d, "Acme", "2010", "2012", status: .former).at("2012-06-01"), fact(d, "Acme", status: .current).at("2016-06-01"), initech])
        #expect(b.resolveText(job, "2024-06-01").1 == .candidates)
        #expect(b.inRange(d, year(2021)).isAmbiguous)
        #expect(b.beforeName("Initech").1 == .ambiguous)
        // (c) "no longer" written before the stated start: open.
        var c = stateWith([fact(d, "Acme", "2016", status: .former).at("2015-06-01"), initech])
        #expect(c.resolveText(job, "2024-06-01").1 == .candidates)
        #expect(c.beforeName("Initech").1 == .ambiguous)
    }

    // V3 (probe): same-year hand-overs at stated precisions only.
    @Test func v3_handOversNeedStatedBoundaries() {
        // year / year: inferred
        #expect(stateWith([fact(d, "Acme", "2015", "2019", status: .former), fact(d, "Initech", "2019", status: .current)]).beforeName("Initech")
                == ("Acme", .inferred))
        // month / month, same month: inferred
        #expect(stateWith([fact(d, "Acme", "2015", "March 2019", status: .former), fact(d, "Initech", "March 2019", status: .current)])
                    .beforeName("Initech") == ("Acme", .inferred))
        // month end, year start (the month is inside the year): inferred
        #expect(stateWith([fact(d, "Acme", "2015", "March 2019", status: .former), fact(d, "Initech", "2019", status: .current)])
                    .beforeName("Initech").1 == .inferred)
        // an "ended by" bound isn't a hand-over
        #expect(stateWith([fact(d, "Acme", "2015", status: .former).at("2019-06-01"), fact(d, "Initech", "2019", status: .current)])
                    .beforeName("Initech").1 == .ambiguous)
        // a third job that could fit the window: told
        #expect(stateWith([fact(d, "Acme", "2015", "2019", status: .former), fact(d, "Globex", "2014", "2019", status: .former),
                           fact(d, "Initech", "2019", status: .current)]).beforeName("Initech").1 == .ambiguous)
    }
}

/// Adversarial review, round 13 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound13AstraTests {
    let d = FX.dated

    @Test func n1_anOpenConflictingEndMakesCurrentAmbiguous() {
        let s = stateWith([fact(d, "Globex", "2010", "2018", status: .former).at("2019-01-01"),
                           fact(d, "Globex", status: .current).at("2024-01-01"),
                           fact(d, "Initech", "2019", status: .current).at("2026-01-01")])
        #expect(s.answer(TimelineIntent(predicate: d, op: .current, anchor: nil)).isAmbiguous)
    }

    @Test func n2_aPromotionAtAnEmployerIsNotAnEmployerAnchor() {
        let s = stateWith([fact(d, "Acme", "2010", "2019", status: .former), fact(d, "Initech", "2020", status: .current)])
        #expect(s.intent("What was my job title before the promotion at Initech?") == nil)
        #expect(s.intent("What was I doing right before joining Initech?")?.op == .before)
    }

    @Test func n3_aNameCorrectionFollowsAMerge() throws {
        let v = try TestVault()
        let a = try v.store.writer.write { db -> String in
            let a = try FactStore.addManualFact(db, predicate: FX.dated, name: "Kiteworks", sensitivity: 1, now: t0)
            let b = try FactStore.addManualFact(db, predicate: FX.dated, name: "KW", sensitivity: 1, now: t0)
            _ = try FactStore.override(db, targetKind: "entity", targetID: b.entity, field: "name", value: "Northstar", sensitivity: 1, now: t0)
            _ = try FactStore.override(db, targetKind: "entity", targetID: b.entity, field: "merged_into", value: a.entity, sensitivity: 1,
                                       now: t0.plus(days: 1))
            return a.entity
        }
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        #expect(g.entityMatches(FX.dated, "Northstar", onlyTrusted: true) == [a])
    }
}
