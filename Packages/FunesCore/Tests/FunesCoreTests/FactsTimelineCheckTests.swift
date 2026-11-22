import Foundation
import Testing
@testable import FunesCore

/// 13e.2's check (memory processing §10.3–§10.4; ADR-0032 decision 5, amended 2026-11-21): the rows an answer reads,
/// and the time model checking a claim's comparison on the trusted and the full graph.
@Suite struct FactsTimelineCheckTests {
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
             status: FactAssertion.Status = .unknown) -> Row {
        let text = "I worked at \(name)" + (start.map { " from \($0)" } ?? "") + (end.map { " until \($0)" } ?? "") + "."
        return (id, text, written, trusted, trusted ? .capture : .agent,
                [fact(d, name, start, end, status: status, slot: FX.emp, quote: "worked at \(name)")])
    }

    /// Three jobs in a row: Alder Jan 2012–Feb 2015, Birch Mar 2015–Jun 2018, Cedar since Jul 2018. (Year-precision ends
    /// and starts in the same year are rightly undecided: a possible overlap.)
    var three: [Row] {
        [job("a", "Alder Works", "January 2012", "February 2015"), job("b", "Birch Labs", "March 2015", "June 2018"),
         job("c", "Cedar Systems", "July 2018", nil, status: .current)]
    }

    func checker(_ g: FactsGraph, local: FactsGraph? = nil, first: [String] = []) -> TimelineCheck {
        TimelineCheck(graph: g, local: local, rows: TimelineRows.build(g, predicate: d, first: first))
    }

    func alias(_ c: TimelineCheck, _ name: String) -> String { c.rows.rows.first { $0.name == name }!.alias }

    func compare(_ c: TimelineCheck, _ op: String, anchor: String? = nil, answer: String, date: String = "", end: String = "",
                 stint: String = "", subject: String = "user") -> TimelineComparison {
        TimelineComparison(subject: subject, predicate: d, op: op, anchor: anchor.map { alias(c, $0) } ?? "", stint: stint, anchorDate: date,
                           endDate: end, answer: alias(c, answer))
    }

    // MARK: The rows

    @Test func theRowsAreTrustedEpisodesWithAliasesAndTheSearchsEntitiesFirst() {
        let g = graph(three + [job("x", "Xeno Corp", "2016", "2017", trusted: false)])
        let rows = TimelineRows.build(g, predicate: d)
        #expect(rows.rows.map(\.name) == ["Cedar Systems", "Birch Labs", "Alder Works"])   // the most recent first
        #expect(!rows.names.contains("Xeno Corp"))                                          // untrusted-only: never sent
        #expect(rows.rows.first?.end == "ongoing" || rows.rows.first?.ongoing == true)
        #expect(rows.rows.map(\.alias) == ["e1", "e2", "e3"])
        let alder = g.entities.first { $0.value.name == "Alder Works" }!.key
        #expect(TimelineRows.build(g, predicate: d, first: [alder]).rows.first?.name == "Alder Works")
        #expect(rows.block().contains("<job entity=\"e2\" name=\"Birch Labs\""))
        #expect(rows.block().contains("start=\"2015-03\""))
        #expect(rows.citedMemoryIDs == ["c", "b", "a"])
        #expect(TimelineRows.build(g, predicate: d, limit: 2).rows.count == 2)
    }

    @Test func aStintKeepsItsEntitysAlias() {
        let g = graph([job("a1", "Alder Works", "January 2012", "March 2014"), job("b", "Birch Labs", "April 2014", "May 2016"),
                       ("a2", "I went back to Alder Works in June 2016 and stayed until 2019.", "2019-06-01", true, .capture,
                        [fact(d, "Alder Works", "June 2016", "2019", slot: FX.emp, quote: "went back to Alder Works")])])
        let rows = TimelineRows.build(g, predicate: d)
        let alder = rows.rows.filter { $0.name == "Alder Works" }
        #expect(alder.count == 2 && Set(alder.map(\.alias)).count == 1)
    }

    @Test func aBoundaryOnlyUntrustedTextStatesIsUnknown() {
        // The user says when Birch started; an agent's note says when it ended.
        let g = graph([job("b", "Birch Labs", "2015", nil),
                       ("n", "The user left Birch Labs in 2019.", "2020-01-01", false, .agent,
                        [fact(d, "Birch Labs", nil, "2019", status: .former, slot: FX.emp, quote: "left Birch Labs in 2019")])])
        let row = TimelineRows.build(g, predicate: d).rows.first { $0.name == "Birch Labs" }
        #expect(row?.start == "2015")
        #expect(row?.end != "2019")
    }

    // MARK: The check

    @Test func agreeDisagreeAndCantTell() {
        let c = checker(graph(three))
        let agree = c.check(compare(c, "before", anchor: "Cedar Systems", answer: "Birch Labs"), search: "Where did I work before Cedar?")
        #expect(agree.verdict == .agrees && agree.basis == .ordered)
        let wrong = c.check(compare(c, "before", anchor: "Cedar Systems", answer: "Alder Works"), search: "Where did I work before Cedar?")
        #expect(wrong.verdict == .disagrees)
        let none = c.check(compare(c, "before", anchor: "Alder Works", answer: "Birch Labs"), search: "Before Alder?")
        #expect(none.verdict == .notSure && none.reason == .cantTell)
        let year = c.check(compare(c, "in", answer: "Birch Labs", date: "2016"), search: "Where did I work in 2016?")
        #expect(year.verdict == .agrees)
        let span = c.check(compare(c, "between", answer: "Birch Labs", date: "2016", end: "2017"), search: "between 2016 and 2017")
        #expect(span.verdict == .agrees)
        let now = c.check(compare(c, "current", answer: "Cedar Systems"), search: "Where do I work now?")
        #expect(now.verdict == .agrees)
        let after = c.check(compare(c, "after", anchor: "Alder Works", answer: "Birch Labs"), search: "after Alder")
        #expect(after.verdict == .agrees)
    }

    @Test func missingInvalidAndSomeoneElsesComparisonsAreNotSure() {
        let c = checker(graph(three))
        #expect(c.check(nil, search: "before Cedar").reason == .noComparison)
        var made = compare(c, "before", anchor: "Cedar Systems", answer: "Birch Labs")
        made.made = false
        #expect(c.check(made, search: "before Cedar").reason == .noComparison)
        for bad in [TimelineComparison(predicate: d, op: "before", anchor: "e9", answer: "e2"),
                    TimelineComparison(predicate: d, op: "sometime", anchor: "e1", answer: "e2"),
                    TimelineComparison(predicate: "partner", op: "before", anchor: "e1", answer: "e2"),
                    TimelineComparison(predicate: d, op: "in", anchorDate: "summer 2017", answer: "e2"),
                    TimelineComparison(predicate: d, op: "between", anchorDate: "2016", answer: "e2"),
                    TimelineComparison(predicate: d, op: "before", anchor: "e1", slot: "astronaut", answer: "e2"),
                    compare(c, "before", anchor: "Cedar Systems", answer: "Birch Labs", subject: "someone_else"),
                    compare(c, "before", anchor: "Cedar Systems", answer: "Birch Labs", subject: ""),
                    compare(c, "in", answer: "Birch Labs", date: "2016-02-31"),
                    compare(c, "before", anchor: "Cedar Systems", answer: "Birch Labs", stint: "third"),
                    compare(c, "current", answer: "Cedar Systems", date: "2020")] {
            let r = c.check(bad, search: "before Cedar")
            #expect(r.verdict == .notSure && r.reason == .invalid, "\(bad)")
        }
    }

    @Test func aDisputeOnlyUntrustedTextMakesIsMarkedNotDropped() {
        // An agent's note claims a job between Birch and Cedar: the trusted graph answers Birch, the full graph can't.
        let g = graph(three + [job("x", "Xeno Corp", "June 2018", "July 2018", trusted: false)])
        let c = checker(g)
        let r = c.check(compare(c, "before", anchor: "Cedar Systems", answer: "Birch Labs"), search: "before Cedar")
        #expect(r.verdict == .agreesTrusted)
        #expect(r.stands)
        // An import counts as untrusted too.
        var imported = three
        imported.append(("i", "Worked at Xeno Corp in June and July 2018.", "2024-01-01", false, .import,
                         [fact(d, "Xeno Corp", "June 2018", "July 2018", slot: FX.emp, quote: "Worked at Xeno Corp")]))
        let ci = checker(graph(imported))
        #expect(ci.check(compare(ci, "before", anchor: "Cedar Systems", answer: "Birch Labs"), search: "before Cedar").verdict == .agreesTrusted)
    }

    @Test func severalStintsWithoutACueAreNotSureNamingThem() {
        let g = graph([job("a1", "Alder Works", "January 2012", "March 2014"), job("b", "Birch Labs", "April 2014", "May 2016"),
                       ("a2", "I went back to Alder Works in June 2016 and stayed until 2019.", "2019-06-01", true, .capture,
                        [fact(d, "Alder Works", "June 2016", "2019", slot: FX.emp, quote: "went back to Alder Works")])])
        let c = checker(g)
        // The model picked a stint the search doesn't name (Spike T's r08 q3): not sure, by stint.
        let r = c.check(compare(c, "before", anchor: "Alder Works", answer: "Birch Labs", stint: "second"), search: "Where did I work before Alder?")
        #expect(r.verdict == .notSure && r.reason == .stints && r.stints.count == 2)
        let line = TimelineCheckWording.english.line(r, { id in id.flatMap { g.entities[$0]?.name } }, "job")
        #expect(line.contains("first stint") && line.contains("Birch Labs"))
        // The search names the stint ("when I went back"): it stands.
        let back = c.check(compare(c, "before", anchor: "Alder Works", answer: "Birch Labs", stint: "second"),
                           search: "Where did I work before I returned to Alder Works?")
        #expect(back.verdict == .agrees, "\(back)")
        // The search names one stint and the model another: invalid.
        let first = c.check(compare(c, "before", anchor: "Alder Works", answer: "Birch Labs", stint: "first"),
                            search: "Where did I work before I returned to Alder Works?")
        #expect(first.verdict == .notSure)
    }

    @Test func theLocalCheckAboveTheLimitMakesItNotSure() {
        // Above the limit, the owner's own memory puts Birch between Alder and Cedar; the sendable graph doesn't have it,
        // so there Alder looks like the job before Cedar.
        let sendable = graph([three[0], three[2]])
        // Entity ids are the store's, the same in both graphs (here: the same order of application).
        let c = checker(sendable, local: graph([three[0], three[2], three[1]]))
        let r = c.check(compare(c, "before", anchor: "Cedar Systems", answer: "Alder Works"), search: "before Cedar")
        #expect(r.verdict == .notSure && r.reason == .aboveLimit, "\(r)")
        // Nothing above the limit changes it: it stands.
        let same = checker(sendable, local: sendable)
        #expect(same.check(compare(same, "before", anchor: "Cedar Systems", answer: "Alder Works"), search: "before Cedar").stands)
    }

    @Test func theLocalCheckRunsBeforeTheSendableVerdict() {
        // Sendable: Birch before Cedar, so "Alder" disagrees; above the limit Dune is before Cedar, which disagrees too, but
        // differently: "not sure", never dropped on what the sendable graph alone says.
        let sendable = graph(three)
        let c = checker(sendable, local: graph(three + [job("p", "Dune Partners", "July 2018", "July 2018")]))
        let r = c.check(compare(c, "before", anchor: "Cedar Systems", answer: "Alder Works"), search: "before Cedar")
        #expect(r.verdict == .notSure && r.reason == .aboveLimit, "\(r)")
    }

    @Test func everyStintCantTellIsJustCantTell() {
        let g = graph([job("a1", "Alder Works", "2012", nil), job("b", "Birch Labs", "2014", "2016"),
                       ("a2", "I went back to Alder Works in 2016.", "2019-06-01", true, .capture,
                        [fact(d, "Alder Works", "2016", nil, slot: FX.emp, quote: "went back to Alder Works")])])
        let c = checker(g)
        let r = c.check(compare(c, "after", anchor: "Alder Works", answer: "Birch Labs"), search: "after Alder Works")
        #expect(r.verdict == .notSure && r.reason != .stints, "\(r)")
    }

    @Test func theLineIsWordedByCode() {
        let g = graph(three)
        let c = checker(g)
        let r = c.check(compare(c, "before", anchor: "Cedar Systems", answer: "Birch Labs"), search: "before Cedar")
        let name: (String?) -> String? = { id in id.flatMap { g.entities[$0]?.name } }
        #expect(TimelineCheckWording.english.line(r, name, "job") == "Before Cedar Systems: Birch Labs.")
        let n = c.check(compare(c, "before", anchor: "Alder Works", answer: "Birch Labs"), search: "before Alder")
        #expect(TimelineCheckWording.english.line(n, name, "job") == "Funes can't tell which job you had before Alder Works.")
    }

    @Test func comparisonsDecodeLeniently() throws {
        let json = #"{"made": true, "subject": "user", "predicate": "works_at", "operator": "before", "anchor": "e1", "answer": 3}"#
        let c = try JSONDecoder().decode(TimelineComparison.self, from: Data(json.utf8))
        #expect(c.made && c.op == "before" && c.answer == "" && c.stint == "")
    }

    @Test func civilDatesRoundTrip() {
        for (y, m, dd) in [(2019, 3, 15), (2000, 2, 29), (1999, 12, 31), (2024, 1, 1)] {
            let n = DayNumber.from(year: y, month: m, day: dd)!
            #expect(TimelineDates.civil(n) == (y, m, dd))
        }
    }
}
