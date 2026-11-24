import Foundation
import Testing
@testable import FunesCore

/// 13e.2's fix round (after the first gate set): renames in the rows, a later "still there" settling an open stint, the
/// operators for "still at when X began", "already left by then" and "first", the stint read, the answer's own kind of
/// work for a date, and a gap only the user's memories leave. Every name is invented.
@Suite struct FactsTimelineFixRoundTests {
    let d = FX.dated
    typealias Row = (String, String, String, Bool, FactsMemory.Source, [ExtractedFact])

    func graph(_ rows: [Row]) -> FactsGraph {
        var g = FactsGraph(registry: FX.registry)
        for (id, text, written, trusted, source, facts) in rows {
            g.apply(FactsMemory(id: id, text: text, written: written, source: source, trusted: trusted), facts: facts)
        }
        return g
    }

    func job(_ id: String, _ name: String, _ start: String?, _ end: String?, trusted: Bool = true, written: String = "2024-01-01",
             status: FactAssertion.Status = .unknown, slot: String? = nil, also: String? = nil) -> Row {
        let text = "I worked at \(name)" + (start.map { " from \($0)" } ?? "") + (end.map { " until \($0)" } ?? "")
            + (also.map { ". \(name) is also called \($0)" } ?? "") + "."
        var f = fact(d, name, start, end, status: status, slot: slot ?? FX.emp, quote: "worked at \(name)" + (also.map { ", also called \($0)" } ?? ""))
        f.alsoCalled = also
        return (id, text, written, trusted, trusted ? .capture : .agent, [f])
    }

    func checker(_ g: FactsGraph) -> TimelineCheck {
        TimelineCheck(graph: g, local: nil, rows: TimelineRows.build(g, predicate: d))
    }

    func alias(_ c: TimelineCheck, _ name: String) -> String {
        c.rows.rows.first { $0.name == name || $0.renames.contains(name) }!.alias
    }

    func compare(_ c: TimelineCheck, _ op: String, anchor: String? = nil, answer: String, date: String = "", stint: String = "") -> TimelineComparison {
        TimelineComparison(predicate: d, op: op, anchor: anchor.map { alias(c, $0) } ?? "", stint: stint, anchorDate: date, answer: alias(c, answer))
    }

    // MARK: Renames

    @Test func aRenameOnOneHolderNamesTheRowByItsNewestName() {
        // The rename's statement gives the new name as another name of the one holder: no second holder, no stated group.
        let g = graph([job("m1", "Faro Lumen", "2013-02", "2015-08", written: "2015-09-04"),
                       job("m5", "Faro Lumen", "2018-05-01", nil, written: "2020-02-09", status: .current),
                       job("m6", "Faro Lumen", nil, nil, written: "2026-10-28", status: .current, also: "Prisma Lumen")])
        let row = TimelineRows.build(g, predicate: d).rows.first!
        #expect(row.name == "Prisma Lumen")
        #expect(row.renames == ["Faro Lumen"])
        #expect(TimelineRows.build(g, predicate: d).block().contains("also_called=\"Faro Lumen\""))
    }

    @Test func aStatedGroupNamesItsRowsByTheNameFirstWrittenLast() {
        let g = graph([job("m1", "Quay Works", "2014-01-01", "2016-12-31", written: "2017-01-08"),
                       job("m5", "Quay Works", "2020-07-01", nil, written: "2022-06-03", status: .current),
                       job("m6", "Arc Works", nil, nil, written: "2026-10-28", status: .current, also: "Quay Works")])
        let rows = TimelineRows.build(g, predicate: d)
        #expect(Set(rows.rows.map(\.name)) == ["Arc Works"])
        let c = checker(g)
        let id = rows.rows[0].entity
        #expect(rows.label(id, graph: g) == "Arc Works (also called Quay Works)")
        let r = c.check(compare(c, "current", answer: "Arc Works"), search: "Where do I work now?")
        #expect(r.verdict == .agrees)
    }

    @Test func oneMemoryIntroducingBothNamesKeepsTheHoldersOwnName() {
        let g = graph([job("m1", "Kite Labs", "2019", nil, written: "2024-01-01", status: .current, also: "Kite Laboratories")])
        let row = TimelineRows.build(g, predicate: d).rows.first!
        #expect(row.name == "Kite Labs" && row.renames == ["Kite Laboratories"])
    }

    // MARK: A later "still there"

    func returned(laterHold: Bool, laterDenial: Bool = false) -> FactsGraph {
        var rows: [Row] = [
            job("a1", "Alder Works", "2013-02-01", "2015-08-31", written: "2015-09-04"),
            job("b", "Birch Labs", "2015-09-01", "2018-04-30", written: "2018-05-02"),
            job("a2", "Alder Works", "2018-05-01", nil, written: "2018-05-03", status: .current),
            // An undated "after leaving Alder the first time", written after the return began.
            ("n1", "After I first left Alder Works I joined Birch Labs.", "2018-05-04", true, .capture,
             [fact(d, "Alder Works", nil, nil, status: .former, slot: FX.emp, quote: "After I first left Alder Works")]),
        ]
        if laterHold { rows.append(job("a3", "Alder Works", nil, nil, written: "2020-02-09", status: .current)) }
        if laterDenial {
            rows.append(("n2", "Back when I first left Alder Works it was a hard year.", "2022-03-01", true, .capture,
                         [fact(d, "Alder Works", nil, nil, status: .former, slot: FX.emp, quote: "when I first left Alder Works")]))
        }
        return graph(rows)
    }

    func open(_ g: FactsGraph) -> Episode? {
        let alder = g.entities.first { $0.value.name == "Alder Works" }!.key
        return g.episodes(d).filter { $0.entity == alder }.max { $0.sortKey < $1.sortKey }
    }

    @Test func aLaterStillThereSettlesAnOpenStintADenialLeftUncertain() {
        #expect(open(returned(laterHold: false))?.uncertain == true)
        #expect(open(returned(laterHold: true))?.uncertain == false)
        #expect(open(returned(laterHold: true))?.ongoing == true)
        // A denial written after that "still there" leaves it open again.
        #expect(open(returned(laterHold: true, laterDenial: true))?.uncertain == true)
    }

    // MARK: Still at, already left, first

    var dayPrecise: [Row] {
        [job("a", "Alder Works", "2012-01-01", "2015-02-28"), job("b", "Birch Labs", "2015-03-01", "2018-06-30"),
         job("c", "Cedar Systems", "2018-07-01", nil, status: .current)]
    }

    var yearOnly: [Row] {
        [job("a", "Alder Works", "2012", "2015"), job("b", "Birch Labs", "2015", "2018"),
         job("c", "Cedar Systems", "2018", nil, status: .current)]
    }

    @Test func stillAtWhenAJobBeganNeedsDatesThatSettleIt() {
        let c = checker(graph(dayPrecise))
        #expect(c.check(compare(c, "at_start", anchor: "Cedar Systems", answer: "Birch Labs"), search: "x").verdict == .agrees)
        let y = checker(graph(yearOnly))
        let r = y.check(compare(y, "at_start", anchor: "Cedar Systems", answer: "Birch Labs"), search: "x")
        #expect(r.verdict == .notSure && r.reason == .cantTell)
    }

    @Test func alreadyLeftNeedsAnEndBeforeTheStartAndNoNewerUncertainOne() {
        let c = checker(graph(dayPrecise))
        #expect(c.check(compare(c, "ended_before", anchor: "Cedar Systems", answer: "Birch Labs"), search: "x").verdict == .agrees)
        #expect(c.check(compare(c, "ended_before", anchor: "Cedar Systems", answer: "Alder Works"), search: "x").verdict == .disagrees)
        let y = checker(graph(yearOnly))
        #expect(y.check(compare(y, "ended_before", anchor: "Cedar Systems", answer: "Birch Labs"), search: "x").verdict == .notSure)
        // Alder certainly ended before Cedar, but Birch's end may fall on either side: never the older one.
        #expect(y.check(compare(y, "ended_before", anchor: "Cedar Systems", answer: "Alder Works"), search: "x").verdict == .notSure)
    }

    @Test func firstIsTheEarliestRecordedWhenNothingMayBeEarlier() {
        let c = checker(graph(yearOnly))
        #expect(c.check(compare(c, "first", answer: "Alder Works"), search: "My first job?").verdict == .agrees)
        let u = checker(graph(yearOnly + [job("x", "Xylem Co", nil, "2014")]))
        #expect(u.check(compare(u, "first", answer: "Alder Works"), search: "My first job?").verdict == .notSure)
    }

    // MARK: The stint read, and the line

    @Test func theLineNamesTheStintTheCheckRead() {
        let g = graph([job("a1", "Alder Works", "2012", "2014-03"), job("b", "Birch Labs", "2014-04", "2016-05"),
                       ("a2", "I went back to Alder Works in June 2016 and I'm still there.", "2019-06-01", true, .capture,
                        [fact(d, "Alder Works", "June 2016", nil, status: .current, slot: FX.emp, quote: "went back to Alder Works")])])
        let c = checker(g)
        let r = c.check(compare(c, "before", anchor: "Alder Works", answer: "Birch Labs"), search: "Where did I work before returning to Alder Works?")
        #expect(r.verdict == .agrees && r.stint == 2 && r.stintCount == 2)
        let line = TimelineCheckWording.english.line(r, { id in id.flatMap { c.rows.label($0, graph: g) } }, "job")
        #expect(line == "Before your return to Alder Works: Birch Labs.")
    }

    // MARK: A date and the answer's kind of work

    @Test func aDateClaimIsNotBlockedByAJobOfAnotherKind() {
        let g = graph([job("c", "Cavren Metrics", "2014", "2020"), job("p", "Pezulo Studio", "2018", nil, status: .current, slot: FX.own)])
        let c = checker(g)
        #expect(c.check(compare(c, "in", answer: "Cavren Metrics", date: "2018-03-31"), search: "Which employer on 2018-03-31?").verdict == .agrees)
    }

    // MARK: A claim with no comparison, on a selection search

    @Test func theSearchsOwnComparisonChecksAClaimThatMadeNone() {
        let y = checker(graph(yearOnly))
        let g = y.graph
        // An abstention naming both jobs of a year-only handover: can't tell.
        let r = SearchAnswerer.derived("Your notes don't settle whether you were at Alder Works or Birch Labs in 2015.", rows: y.rows, check: y,
                                       query: "Which company was my employer in 2015?", graph: g)
        #expect(r?.verdict == .notSure && r?.reason == .cantTell)
        // An answer given without a comparison: checked, and agreeing.
        let c = checker(graph(dayPrecise))
        let a = SearchAnswerer.derived("You were working at Birch Labs then.", rows: c.rows, check: c,
                                       query: "Which company was my employer in March 2016?", graph: c.graph)
        #expect(a?.verdict == .agrees && a?.op == "in" && a?.anchorDate == "2016-03")
        let wrong = SearchAnswerer.derived("You were working at Alder Works then.", rows: c.rows, check: c,
                                           query: "Which company was my employer in March 2016?", graph: c.graph)
        #expect(wrong?.verdict == .disagrees)
    }

    @Test func noComparisonIsMadeForAQualifierOrAnotherTime() {
        let c = checker(graph(dayPrecise))
        // A title question doesn't ask for the organization.
        #expect(SearchAnswerer.derived("In 2016 at Birch Labs you were a designer.", rows: c.rows, check: c,
                                       query: "What was my title in 2016?", graph: c.graph) == nil)
        // "Before …": the date isn't the time asked about, and "before" may mean "had already left by" (left to `owes`).
        #expect(SearchAnswerer.derived("You were at Birch Labs before Cedar Systems.", rows: c.rows, check: c,
                                       query: "Where did I work before joining Cedar Systems in July 2018?", graph: c.graph) == nil)
        // A claim naming no holder.
        #expect(SearchAnswerer.derived("Your notes say little about that year.", rows: c.rows, check: c,
                                       query: "Which company was my employer in March 2016?", graph: c.graph) == nil)
    }

    @Test func aJobOnlyAnAgentsNoteNamesIsNotSure() {
        let c = checker(graph(dayPrecise + [job("x", "Xeno Corp", "2016-01", "2016-12", trusted: false)]))
        let r = SearchAnswerer.derived("An agent's note says you were at Xeno Corp then.", rows: c.rows, check: c,
                                       query: "Which company was my employer in March 2016?", graph: c.graph)
        #expect(r?.verdict == .notSure && r?.reason == .cantTell && r?.anchorDate == "2016-03")
        // With the trusted holder beside it: context about a disputed holder, not checked.
        #expect(SearchAnswerer.derived("An agent's note says you left Birch Labs for Xeno Corp then.", rows: c.rows, check: c,
                                       query: "Which company was my employer in March 2016?", graph: c.graph) == nil)
    }

    /// A claim through `checked` with a comparison the model didn't make, on a search with no rows memory cited.
    func checked(_ c: TimelineCheck, _ text: String, _ query: String) -> SearchAnswerer.Checked {
        let claim = SearchAnswer.Claim(text: text, citations: [])
        let v = SearchAnswerer.Validated(claim: claim, sent: [], comparison: TimelineComparison(made: false, predicate: "", op: "", answer: ""))
        let view = FactsSearchIndex(graph: c.graph, links: [:], eligible: [], linked: [], factIDs: [:])
        return SearchAnswerer.checked(claim, validated: v, cited: [], rows: c.rows, check: c, query: query, view: view, wording: .english)
    }

    @Test func anOffsetAnswerToAWhichBeforeSearchOwesItsCheck() {
        let c = checker(graph(dayPrecise))
        let q = "Which company employed me six months before I joined Cedar Systems?"
        // Names a holder the search doesn't: it answers the ask, so it's checked (and, with no comparison, can't be).
        guard case let .checked(line, r) = checked(c, "Birch Labs employed you then.", q) else { Issue.record("not checked"); return }
        #expect(r.verdict == .notSure && line.check != nil)
        // Names only the search's own holder: context, kept.
        guard case .keep = checked(c, "Cedar Systems hired you as a lead.", q) else { Issue.record("not kept"); return }
        // A title question with a "before" names a holder too, but doesn't ask for one.
        guard case .keep = checked(c, "At Birch Labs you were a designer.", "What was my title before I joined Cedar Systems?") else {
            Issue.record("title checked"); return
        }
    }

    @Test func aStretchOfTimeIsNotOneAskedDate() {
        let c = checker(graph(dayPrecise))
        #expect(c.askedDate("Which companies employed me from 2016 to 2019?") == nil)
        #expect(c.askedDate("Which company was my employer from March to June 2017?") == nil)
        #expect(c.askedDate("Which company was my employer in March 2016?") != nil)
    }

    @Test func theSearchsKindOfWorkNotTheAnswersDecides() {
        let c = checker(graph([job("c", "Cavren Metrics", "2014", "2020"), job("p", "Pezulo Studio", "2018", nil, status: .current, slot: FX.own)]))
        let r = SearchAnswerer.derived("You also ran Pezulo Studio.", rows: c.rows, check: c, query: "Which employer did I have in 2018?", graph: c.graph)
        #expect(r?.stands != true)
    }

    @Test func contextIsNeitherDroppedNorReworded() {
        let c = checker(graph(dayPrecise))
        let q = "Which company was my employer in March 2016?"
        // About another time: not checked against the search's date.
        #expect(SearchAnswerer.derived("You worked at Alder Works in 2013.", rows: c.rows, check: c, query: q, graph: c.graph) == nil)
        // A stretch around the search's date is about it.
        #expect(SearchAnswerer.derived("You joined Birch Labs on 2015-03-01 and were still there in 2017.", rows: c.rows, check: c, query: q,
                                       graph: c.graph)?.stands == true)
        // A title at the right holder keeps its words, checked.
        guard case let .checked(title, r) = checked(c, "At Birch Labs you were a senior designer.", q) else { Issue.record("not checked"); return }
        #expect(title.text == "At Birch Labs you were a senior designer." && r.stands)
        // A claim about a job that didn't hold then stays, unchecked.
        guard case let .keep(kept) = checked(c, "At Alder Works you were a designer.", q) else { Issue.record("not kept"); return }
        #expect(kept.check == nil)
    }

    @Test func aTrustedJobBeyondTheRowsIsNotUnrecorded() {
        let g = graph(dayPrecise)
        let c = TimelineCheck(graph: g, local: nil, rows: TimelineRows.build(g, predicate: d, limit: 2))
        #expect(!c.rows.rows.contains { $0.name == "Alder Works" })
        let r = SearchAnswerer.derived("You were at Alder Works then.", rows: c.rows, check: c, query: "Which company was my employer in March 2013?",
                                       graph: g)
        #expect(r?.reason != .cantTell)
    }

    // MARK: A gap only the user's memories leave

    @Test func aGapWhereAnAgentsNoteNamesAJobIsNotTold() {
        let trustedOnly = [job("a", "Alder Works", "2012-01", "2014-06"), job("b", "Birch Labs", "2017-03", nil, status: .current)]
        let plain = checker(graph(trustedOnly))
        #expect(plain.check(compare(plain, "before", anchor: "Birch Labs", answer: "Alder Works"), search: "x").basis == .gap)
        let c = checker(graph(trustedOnly + [job("x", "Xeno Corp", "2015-01", "2016-12", trusted: false)]))
        let r = c.check(compare(c, "before", anchor: "Birch Labs", answer: "Alder Works"), search: "x")
        #expect(r.verdict == .notSure && r.reason == .cantTell)
    }

    // MARK: Fix round 3 (r2)

    /// A note read as "former" with no end date ("my next employer was Udequin: I started on 2020-09-01") and a later
    /// "still there since 2020-09-01": the later memory says it held through the note's date, so the job still holds.
    /// A later "still there" with no start keeps the conflict (no return was stated, and nothing says it held across).
    @Test func aLaterStillThereSinceBeforeAStatusOnlyEndKeepsTheJob() {
        let s = stateWith([fact(d, "Udequin", "2020-09-01", status: .former).at("2020-09-05"),
                           fact(d, "Udequin", "2020-09-01", status: .current).at("2026-10-28")])
        let e = s.episodes(of: "Udequin")
        #expect(e.count == 1 && e[0].ongoing && !e[0].conflictEnd)
        #expect(s.inRange(d, DateParser(registry: FX.registry).parse("2023")!).entities == [s.ent("Udequin")])
        let year = stateWith([fact(d, "Ruzento", "2020", status: .former).at("2021-03-02"),
                              fact(d, "Ruzento", "2020", status: .current).at("2026-10-28")])
        #expect(year.episodes(of: "Ruzento").first?.ongoing == true)
        let noStart = stateWith([fact(d, "Udequin", "2020-09-01", status: .former).at("2020-09-05"),
                                 fact(d, "Udequin", status: .current).at("2026-10-28")])
        #expect(noStart.episodes(of: "Udequin").first?.conflictEnd == true)
        // The same start in the bound's own year counts too.
        let sameYear = stateWith([fact(d, "Ruzento", "2020", status: .former, quote: "my next employer was Ruzento").at("2020-09-05"),
                                  fact(d, "Ruzento", "2020", status: .current).at("2026-10-28")])
        #expect(sameYear.episodes(of: "Ruzento").first?.ongoing == true)
        // A real exit ("I left Acme"), or a bound row with no start of its own, stays a conflict: maybe a return.
        let left = stateWith([fact(d, "Acme", "2014", status: .former, quote: "I left Acme").at("2018-05-01"),
                              fact(d, "Acme", "2014", status: .current).at("2022-01-01")])
        #expect(left.episodes(of: "Acme").first?.conflictEnd == true)
        let bare = stateWith([fact(d, "Acme", status: .former, quote: "my employer was Acme").at("2018-05-01"),
                              fact(d, "Acme", "2014", status: .current).at("2022-01-01")])
        #expect(bare.episodes(of: "Acme").first?.conflictEnd == true)
        // A "former" written after the correction still ends the job.
        let after = stateWith([fact(d, "Udequin", "2020-09-01", status: .former).at("2020-09-05"),
                               fact(d, "Udequin", "2020-09-01", status: .current).at("2022-01-01"),
                               fact(d, "Udequin", "2020-09-01", status: .former).at("2024-01-01")])
        #expect(after.episodes(of: "Udequin").first?.ongoing == false)
        // A stated end isn't a status's bound: "2010 to 2018", then "still at Globex" stays a conflict.
        let stated = stateWith([fact(d, "Globex", "2010", "2018", status: .former).at("2019-01-01"),
                                fact(d, "Globex", "2010", status: .current).at("2024-01-01")])
        #expect(stated.episodes(of: "Globex").first?.conflictEnd == true)
    }
}
