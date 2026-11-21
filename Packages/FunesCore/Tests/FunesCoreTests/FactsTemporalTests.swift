import Foundation
import Testing
@testable import FunesCore

/// Every counterexample GPT-6-Astra and Fable 5.2 found in Spike H3's and H3b's time model
/// (`spikes/people/test_temporal.py`), ported. No model calls.
@Suite struct FactsTemporalTests {
    let d = FX.dated
    let parser = DateParser(registry: FX.registry)

    // MARK: Dates are ranges

    @Test func sameYearHandOverIsNotSkipped() {
        let s = stateWith([fact(d, "Globex", "2015", "2018", status: .former), fact(d, "Acme", "2019", "2019", status: .former),
                           fact(d, "Initech", "2019")])
        #expect(s.beforeName("Initech").0 != "Globex")              // Acme may sit in between: told, not Globex
    }

    @Test func aCompetitorThatMayEndLaterCounts() {
        let s = stateWith([fact(d, "Acme", "2018", "March 2020", status: .former), fact(d, "Globex", "2017", "2020", status: .former),
                           fact(d, "Initech", "April 2020")])
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
    }

    @Test func halfDatedFormerCompetitorCounts() {
        let s = stateWith([fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Globex", "2016", status: .former),
                           fact(d, "Initech", "June 2019")])
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
    }

    @Test(arguments: [("married in 2015", "2015"), ("separated in 2019", "2019"), ("decided in 2018", "2018"),
                      ("2019-20", "2019"), ("marzo de 2019", "March 2019")])
    func monthsAreNotReadFromProse(_ written: String, _ same: String) {
        #expect(parser.parse(written) == parser.parse(same))
    }

    @Test func aMonthIsNotItsYear() {
        #expect(parser.parse("March 2019") != parser.parse("2019"))
    }

    // MARK: Episodes come from assertion intervals

    @Test func mergingDoesntEraseAnEpisode() {
        let s = stateWith([fact(d, "Acme", "2020", "March 2020", status: .former),
                           fact(d, "Globex", "April 2020", "August 2020", status: .former),
                           fact(d, "Acme", "September 2020", status: .current)])
        #expect(s.episodes(of: "Acme").count == 2)
    }

    @Test func anEndBeforeTheFirstStartIsKept() {
        let s = stateWith([fact(d, "Acme", nil, "December 2016", status: .former), fact(d, "Acme", "2020", status: .current),
                           fact(d, "Globex", "January 2017", "2019", status: .former)])
        let acme = s.episodes(of: "Acme").stableSorted { $0.sortKey }
        #expect(acme.count == 2 && acme[0].end != nil)
    }

    @Test func aRejoinReopensTheFactForRoleResolution() {
        var s = stateWith([fact(d, "Acme", "2014", "2016", status: .former), fact(d, "Globex", "2017", "2019", status: .former),
                           fact(d, "Acme", "2020", status: .current)])
        #expect(s.resolveText("At my \(FX.word(d)) I use Emacs.", "2021-06-01").0 == "Acme")
    }

    // MARK: Trust per date and edge

    @Test func anUntrustedStartNeverDrivesSuccession() {
        let s = stateWith([fact(d, "Acme", "2018", slot: FX.emp), fact(d, "Globex", slot: FX.emp),
                           fact(d, "Globex", "2020", slot: FX.emp).untrusted])
        #expect(!s.episodes(of: "Acme")[0].inferredEnd)
    }

    @Test func anUntrustedEdgeIsNeverStated() {
        let s = stateWith([fact(d, "Acme", "2015", "2017", status: .former), fact(d, "Globex", "2016", "2017", status: .former),
                           fact(d, "Initech", "2018", precededBy: "Globex").untrusted])
        #expect(s.beforeName("Initech").1 != .stated)
    }

    // MARK: Succession

    @Test func stillCurrentInTheSuccessorsMonthBlocksSuccession() {
        var s = stateWith([fact(d, "Acme", "2018", slot: FX.emp)])
        s.apply(FactsMemory(id: "late", text: "Acme", written: "2021-06-30", trusted: true),
                facts: [fact(d, "Acme", status: .current, slot: FX.emp)])
        s.apply(FactsMemory(id: "next", text: "Initech", written: "2021-07-01", trusted: true),
                facts: [fact(d, "Initech", "June 2021", slot: FX.emp)])
        #expect(!s.episodes(of: "Acme")[0].inferredEnd)
    }

    @Test func anAssumedHandoverStartNeverBoundsAnEnd() {
        let s = stateWith([fact(d, "Amber", "2016", "2018", status: .former), fact(d, "Kelp", "February 2023", status: .current),
                           fact(d, "Slate", status: .former)])     // undated, ended: could sit between Amber and Kelp
        #expect(s.beforeName("Kelp").0 != "Amber")
    }

    // MARK: Order edges per episode, with cycles

    @Test func aLongerCycleIsNotStated() {
        let s = stateWith([fact(d, "Acme", followedBy: "Globex"), fact(d, "Globex", followedBy: "Initech"),
                           fact(d, "Initech", followedBy: "Acme")])
        #expect(s.beforeName("Globex").1 != .stated)
    }

    @Test func aStatedPredecessorThatOverlapsDoesntWin() {
        let s = stateWith([fact(d, "Acme", "2015", status: .current), fact(d, "Initech", "2019", precededBy: "Acme")])
        #expect(s.beforeName("Initech").1 != .stated)
    }

    // MARK: One resolver for roles, previous, before / after

    @Test func aReferenceBeforeAStatedStartIsNotCertain() {
        let pe = FX.personExclusive
        var s = FactsGraph(registry: FX.registry)
        let text = "Sky is my partner since September 2021."
        s.apply(FactsMemory(id: "m0", text: text, written: "2021-10-01"), phrases: s.rolePhrases(text),
                people: [ExtractedPerson(name: "Sky")],
                facts: [fact(pe, "Sky", "September 2021", status: .current, quote: text)])
        #expect(s.resolveText("My \(FX.word(pe)) loves jazz.", "2021-03-01", id: "old").1 != .statedUnique)
    }

    @Test func previousUsesTheSameSafeguards() {
        let s = stateWith([fact(d, "Acme", "2015", "2019", status: .former), fact(d, "Globex", "2016", "March 2019", status: .former),
                           fact(d, "Initech", "2020", status: .current)])
        #expect(s.previousAsOf(d, written: "2020-06-01") == nil)
    }

    @Test func deceasedDoesntOverrideAnExplicitEnd() {
        var s = FactsGraph(registry: FX.registry)
        let text = "Robin was my former boss and later died."
        s.apply(FactsMemory(id: "m1", text: text, written: "2025-01-01"), phrases: s.rolePhrases(text),
                people: [ExtractedPerson(name: "Robin")],
                facts: [fact(FX.personSuccession, "Robin", status: .former, quote: text, deceased: true)])
        #expect(s.status(of: s.facts[0]) == .former)
    }

    @Test func aPresentNegativeEndsRatherThanDenies() {
        let pe = FX.personExclusive
        var s = FactsGraph(registry: FX.registry)
        let t0 = "Petra was my girlfriend.", t1 = "Petra and I have not resumed our relationship."
        s.apply(FactsMemory(id: "m0", text: t0, written: "2025-01-01"), people: [ExtractedPerson(name: "Petra")],
                facts: [fact(pe, "Petra", quote: t0)])
        s.apply(FactsMemory(id: "m1", text: t1, written: "2025-02-01"), people: [ExtractedPerson(name: "Petra", person: "p1")],
                facts: [fact(pe, "Petra", status: .current, quote: t1, positive: false)], roster: ["p1"])
        #expect(!s.facts[0].negated && s.status(of: s.facts[0]) == .former)
    }

    // MARK: Intent

    private func twoJobs() -> FactsGraph {
        stateWith([fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Initech", "2019", status: .current)])
    }

    private func withAda(_ s: inout FactsGraph) {
        s.apply(FactsMemory(id: "ma", text: "Ada Pell is a friend.", written: "2025-01-01"),
                people: [ExtractedPerson(name: "Ada Pell")])
    }

    @Test func someoneElsesFactForEveryOperator() {
        var s = twoJobs()
        withAda(&s)
        for q in ["Where does Ada work now?", "What was Ada's previous job?", "Where did Zoe work before Initech?",
                  "Where did my wife work before Initech?"] {
            #expect(s.intent(q) == nil, "\(q)")      // an unknown name is someone else too
        }
    }

    @Test func theAnchorEndsTheOperatorPhrase() {
        let s = twoJobs()
        #expect(s.intent("What did I work on before the Initech demo?") == nil)
        #expect(s.intent("What was my job before Initech moved offices?") == nil)
        #expect(s.intent("What was my job before Initech?")?.op == .before)
        #expect(s.intent("Where did I work after leaving Acme the first time?")?.op == .after)
    }

    @Test func dateAnchorsAndYearCurrentPrevious() {
        let s = twoJobs()
        let cases: [(String, TimelineIntent.Operator, String)] = [
            ("What job did I have before 2019?", .before, "Acme"), ("Where was I working in 2016?", .year, "Acme"),
            ("What is my current job?", .current, "Initech"), ("What was my previous job?", .previous, "Acme"),
        ]
        for (q, op, want) in cases {
            let it = s.intent(q)
            #expect(it?.op == op, "\(q)")
            #expect(it.map { s.answer($0, query: q).entity } == s.ent(want), "\(q)")
        }
    }

    // MARK: Round 2: counterexamples from the reviews of H3b

    private var pp: String { FX.personSuccession }

    @Test func currentCueIsEvaluatedAtTheMemoryDate() {
        var s = peopleState(pp, [("Ana", "2015", "2019", .former, "2020-01-01"), ("Bo", "2021", nil, .current, "2021-06-01")])
        #expect(s.resolveText("My current \(FX.word(pp)) likes tea.", "2018-06-01").0 != "Bo")
    }

    @Test func aMonthCueIsARangeAndNeedsAPreposition() {
        var s = peopleState(pp, [("Ana", "2015", "March 2019", .former, "2019-04-01"),
                                 ("Bo", "March 2019", nil, .current, "2019-04-02")])
        let w = FX.word(pp)
        #expect(s.resolveText("In February 2019 my \(w) approved the plan.", "2019-05-01").0 != "Bo")
        #expect(s.resolveText("My \(w) approved the 2030 roadmap.", "2018-06-01").0 != "Bo")
    }

    @Test func anUndatedDepartureWithTwoPossibleEpisodesIsUncertain() {
        let s = stateWith([fact(d, "Acme", "2010", "2012", status: .former), fact(d, "Acme", "2020", status: .current).at("2020-06-01"),
                           fact(d, "Acme", status: .former).at("2023-06-01")])
        let got = s.ask("What is my current job?")!
        #expect(got.entities.isEmpty || got.basis != .ordered)
    }

    @Test func untrustedStatusNeverEnablesSuccession() {
        let s = stateWith([fact(d, "Acme", "2018", slot: FX.emp).at("2018-06-01"),
                           fact(d, "Initech", "2020", status: .current, slot: FX.emp).at("2020-06-01"),
                           fact(d, "Acme", status: .current, slot: FX.emp).untrusted(at: "2018-07-01")])
        #expect(!s.episodes(of: "Acme")[0].inferredEnd)
    }

    @Test func anotherHolderAsSubjectIsSomeoneElse() {
        var s = twoJobs()
        withAda(&s)
        #expect(s.intent("Where did Ada work before Initech?") == nil)
    }

    @Test func aHolderAsSubjectIsSomeoneElse() throws {
        // The canary's partner timeline, as a data-only registry change.
        let pe = FX.personExclusive
        let reg = try FX.registry { json in
            FX.editPredicate(&json, pe) { p in
                p["uses"] = ["recorded", "linked", "timeline"]
                p["exclusive"] = false
                p["gap_months"] = 12
                p["query_cues"] = (p["query_cues"] as? [String] ?? []) + ["dating", "dated"]
            }
        }
        let part = reg.timelinePredicates.first { reg.kindOf($0) == "person" }!
        var s = FactsGraph(registry: reg)
        for (i, (nm, st, en, status)) in [("Ada", "2018", "2019", FactAssertion.Status.former),
                                          ("Bea", "2020", nil, .current)].enumerated() {
            s.apply(FactsMemory(id: "m\(i)", text: nm, written: "2021-01-01"), people: [ExtractedPerson(name: nm)],
                    facts: [fact(part, nm, st, en, status: status)])
        }
        #expect(s.intent("Who was Ada dating before Bea?") == nil)
        #expect(s.intent("Who was I dating before Bea?") != nil)
    }

    @Test func aMonthInAYearQuestionIsKept() {
        let s = stateWith([fact(d, "Acme", "2018", "January 2019", status: .former),
                           fact(d, "Initech", "February 2019", status: .current)])
        #expect(s.ask("Where was I working in March 2019?")?.entity == s.ent("Initech"))
    }

    @Test func previousAndBeforeAgree() {
        let s = stateWith([fact(d, "Acme", "2018", status: .current, slot: FX.emp).at("2018-06-01"),
                           fact(d, "Globex", "2020", status: .current, slot: FX.emp).at("2020-06-01"),
                           fact(d, "Initech", "2022", status: .current, slot: FX.emp).at("2022-06-01")])
        let previous = s.ask("What was my previous job?")?.entity
        #expect(previous == s.before(d, .entity(s.ent("Initech"))).entity)
        #expect(previous == s.ent("Globex"))
    }

    @Test func dayDatesKeepTheirDay() {
        #expect(parser.parse("March 15, 2019")?.precision == .day)
    }

    @Test(arguments: ["What job did I have before 2019?", "What job did I have after 2012?"])
    func aDateAnchorAnswersWithTheJobHeldThen(_ q: String) {
        let s = stateWith([fact(d, "Old", "2005", "2009", status: .former), fact(d, "Acme", "2010", "2020", status: .former),
                           fact(d, "New", "2021", status: .current)])
        #expect(s.ask(q)?.entity == s.ent("Acme"))
    }

    @Test func aStatedEdgeLosesToAJobCertainlyBetween() {
        let s = stateWith([fact(d, "Acme", "2014", "April 2016", status: .former),
                           fact(d, "Globex", "May 2016", "May 2016", status: .former),
                           fact(d, "Initech", "June 2016", precededBy: "Acme")])
        #expect(s.beforeName("Initech").0 != "Acme")
    }

    @Test func aBoundEndStartsAfterTheLastHeldDay() {
        var s = peopleState(pp, [("Ana", nil, nil, .current, "2016-06-01"), ("Ana", nil, nil, .former, "2020-06-01")])
        #expect(s.resolveText("My former \(FX.word(pp)) called.", "2015-06-01").0 != "Ana")
    }

    @Test func aTimeValueIsntAnEnd() {
        var s = peopleState(pp, [("Ana", nil, nil, .current, "2020-01-01"), ("Bo", nil, nil, .current, "2020-01-02")])
        let ana = s.entities.values.first { $0.name == "Ana" }!.id
        s.apply(FactsMemory(id: "t", text: "In 2019 Ana gave me a raise", written: "2021-01-01"),
                people: [ExtractedPerson(name: "Ana", person: ana)], facts: [fact(pp, "Ana", time: "2019")], roster: [ana])
        #expect(s.resolveText("My \(FX.word(pp)) is on leave.", "2022-01-01").1 == .candidates)
    }

    @Test func afterAndBeforeTreatUndatedFactsAlike() {
        let s = stateWith([fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Initech", "2019", status: .current),
                           fact(d, "Mystery", status: .former)])
        #expect(s.afterName("Acme").0 == nil && s.beforeName("Initech").0 == nil)
    }

    @Test func aReturnDoesntSucceedItself() {
        let s = stateWith([fact(d, "Acme", "2010", status: .current).at("2011-01-01"),
                           fact(d, "Acme", "2015", status: .current, quote: "I rejoined Acme in 2015").at("2015-06-01")])
        #expect(!s.episodes(of: "Acme").stableSorted { $0.sortKey }[0].inferredEnd)
    }

    @Test func aSameYearHandOverWithNothingElseIsAnswered() {
        let s = stateWith([fact(d, "Acme", "2015", "2019", status: .former), fact(d, "Initech", "2019", status: .current)])
        #expect(s.beforeName("Initech").0 == "Acme" && s.afterName("Acme").0 == "Initech")
    }

    @Test func sentenceInitialCapitalsDontKillIntent() {
        #expect(twoJobs().intent("My job. What was my job before Initech?") != nil)
        // 13e.1: every word of the question counts, so a preface of other words fails closed.
        #expect(twoJobs().intent("Quick one. What was my job before Initech?") == nil)
    }

    // MARK: Round 3: Fable's final check of round 2

    @Test func aDistantYearDoesntRedateThePhrase() {
        var s = peopleState(pp, [("Ana", "2015", "2020", .former, "2020-12-01"), ("Bo", "2021", nil, .current, "2021-06-01")])
        let w = FX.word(pp)
        #expect(s.resolveText("My \(w) said sales dropped in 2019.", "2022-03-01").0 == "Bo")
        #expect(s.resolveText("My \(w) in 2019 was strict.", "2022-03-01").0 == "Ana")
    }

    @Test func anEntityHoldsThroughAnyEpisodeCoveringTheDate() {
        var s = stateWith([fact(d, "Initech", "2010", "2018", status: .former), fact(d, "Acme", "2014", "2016", status: .former),
                           fact(d, "Acme", "2020", status: .current).at("2020-06-01")])
        #expect(s.resolveText("At my \(FX.word(d)) I use Emacs.", "2015-06-01").1 == .candidates)
    }

    @Test func noHandoverWhenTheMemoryGivesATime() {
        var s = peopleState(pp, [("Ana", nil, nil, .current, "2020-01-01")])
        s.apply(FactsMemory(id: "t", text: "Bob", written: "2022-01-01"), people: [ExtractedPerson(name: "Bob")],
                facts: [fact(pp, "Bob", time: "2015")])
        #expect(!s.episodes(pp).contains { $0.handover })
    }

    @Test func anUntrustedDepartureDoesntHideACurrentJob() {
        let s = stateWith([fact(d, "Acme", "2014", "2016", status: .former, slot: FX.emp),
                           fact(d, "Acme", "2020", status: .current, slot: FX.emp).at("2020-06-01"),
                           fact(d, "MyShop", "2021", status: .current, slot: FX.own).at("2021-06-01"),
                           fact(d, "Acme", status: .former).untrusted(at: "2023-01-01")])
        let got = s.ask("Where do I work now?")!
        #expect(got.entities.isEmpty || (got.entities.count > 1 && got.entities.contains(s.ent("Acme"))))
    }

    @Test func aDateAnchorWithAJobThatMayHaveStartedIsTold() {
        let s = stateWith([fact(d, "Acme", "2015", "February 2019", status: .former),
                           fact(d, "Globex", "March 2019", status: .current)])
        #expect(s.ask("Where did I work before March 20, 2019?")?.entity == nil)
        #expect(parser.parse("15 March 2019")?.precision == .day)
    }

    @Test func afterAndBeforeDontContradict() {
        let s = stateWith([fact(d, "Acme", "2015", "December 2018", status: .former),
                           fact(d, "Hooli", nil, "January 2019", status: .former),
                           fact(d, "Globex", "2019-02-01", status: .current)])
        #expect(!(s.beforeName("Globex").0 == "Hooli" && s.afterName("Acme").0 == "Globex"))
    }

    @Test func intentRound3() {
        let s = stateWith([fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Globex", "2019", "2021", status: .former),
                           fact(d, "Initech", "2022", status: .current)])
        #expect(s.intent("Where did I work last year?")?.op != .previous)
        #expect(s.intent("Where did she work before Globex?") == nil)
        let q = "Where did I work from 2015 to 2019?"
        if let it = s.intent(q), it.op == .year {
            #expect(s.answer(it, query: q).entity != s.ent("Acme"))
        }
    }
}
