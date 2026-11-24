import Foundation
import Testing
@testable import FunesCore

/// Phase 13e.2 fix round 4: the shapes the r3 gate set turned up (r3 is retired, so its cases are fixtures here). Each
/// rule is tested with its counterexample.
@Suite struct FactsTimelineRound4Tests {
    let d = FX.dated
    typealias Row = (String, String, String, Bool, FactsMemory.Source, [ExtractedFact])

    func graph(_ rows: [Row]) -> FactsGraph {
        var g = FactsGraph(registry: FX.registry)
        for (id, text, written, trusted, source, facts) in rows {
            g.apply(FactsMemory(id: id, text: text, written: written, source: source, trusted: trusted), facts: facts)
        }
        return g
    }

    func named(_ g: FactsGraph, _ name: String) -> [LearnedFact] {
        g.facts.filter { f in f.predicate == d && g.entities[f.entity]?.name == name }
    }

    // MARK: A slot-limited never-denial (r3's g08)

    var agentHire: Row {
        ("a", "Alex Soler closed Alderpixel Office in 2023-02 and became an employee of Juniperwake Retail in 2023-03.",
         "2024-05-04", false, .agent,
         [fact(d, "Juniperwake Retail", "2023-03", status: .current, slot: FX.emp,
               quote: "became an employee of Juniperwake Retail in 2023-03")])
    }

    func correction(_ sentence: String = "I have never been an employee of Juniperwake Retail.") -> Row {
        ("u", "Correction to the saved summary: Juniperwake Retail was a client of my business from 2023-03 through 2024-06. \(sentence)",
         "2025-01-13", true, .capture, [fact(d, "Juniperwake Retail", slot: FX.emp, quote: sentence, positive: false)])
    }

    @Test func aNeverDenialOfOneSlotReachesAnAgentsClaimInThatSlot() {
        for rows in [[agentHire, correction()], [correction(), agentHire]] {
            let g = graph(rows)
            #expect(named(g, "Juniperwake Retail").allSatisfy { $0.negated }, "\(rows.map(\.0))")
            #expect(!g.episodes(d).contains { g.entities[$0.entity ?? ""]?.name == "Juniperwake Retail" }, "\(rows.map(\.0))")
        }
        let g = FactsGraph(registry: FX.registry)
        for text in ["I have never been an employee of Orlin Labs.", "Honestly, I have never been an employee of Orlin Labs.",
                     "Correction: I've never been an employee of Orlin Labs."] {
            let r = fact(d, "Orlin Labs", quote: text, positive: false)
            #expect(g.neverDenial(r, text: text) == .some(FX.emp), "\(text)")
        }
        // A plain never stays a never of every slot.
        #expect(g.neverDenial(fact(d, "Orlin Labs", quote: "I never worked at Orlin Labs.", positive: false),
                              text: "I never worked at Orlin Labs.") == .some(nil))
    }

    @Test func aSlotNeverLeavesTheOtherSlotAndQualifiedShapesStayOut() {
        // The agent says the user ran it as their own business: an "employee" never doesn't reach that.
        let ownBusiness: Row = ("a", "The user has run Juniperwake Retail as a side business since 2023-03.", "2024-05-04",
                                false, .agent, [fact(d, "Juniperwake Retail", "2023-03", status: .current, slot: FX.own,
                                                     quote: "has run Juniperwake Retail as a side business since 2023-03")])
        let g = graph([ownBusiness, correction()])
        #expect(named(g, "Juniperwake Retail").contains { !$0.negated })
        // The slot phrase must sit whole right before the name, with nothing after it.
        let e = FactsGraph(registry: FX.registry)
        for text in ["I never worked at Orlin Labs as an employee, only as a contractor.",
                     "I have never been an employee of Orlin Labs before 2020.",
                     "I have never been an employee of the year at Orlin Labs.",
                     "My brother has never been an employee of Orlin Labs.",
                     "As an employee of Orlin Labs, I never travelled."] {
            #expect(e.neverDenial(fact(d, "Orlin Labs", quote: text, positive: false), text: text) == nil, "\(text)")
        }
    }

    // MARK: Two stints at one employer (r3's g01)

    /// r3's g01, with m3 read as two rows when `returned` is true (the read prompt's ask), else as its departure alone.
    func twoStints(returned: Bool) -> FactsGraph {
        let m3 = "I left my first Vellicore Maps stint in 2014-06. My next employer was Orpin Ledger, from 2014-07 through 2017-08. I returned directly to Vellicore Maps in 2017-09."
        var m3Facts = [fact(d, "Vellicore Maps", nil, "2014-06", status: .former, slot: FX.emp, quote: "I left my first Vellicore Maps stint in 2014-06."),
                       fact(d, "Orpin Ledger", "2014-07", "2017-08", status: .former, slot: FX.emp, precededBy: "Vellicore Maps",
                            followedBy: "Vellicore Maps", quote: "My next employer was Orpin Ledger, from 2014-07 through 2017-08.")]
        if returned {
            m3Facts.append(fact(d, "Vellicore Maps", "2017-09", status: .unknown, slot: FX.emp, precededBy: "Orpin Ledger",
                                quote: "I returned directly to Vellicore Maps in 2017-09."))
        }
        return graph([
            ("m1", "My first job was at Brindle Quay from 2010-02 through 2011-12. I then joined Vellicore Maps in 2012-01, with no intervening employer.",
             "2013-02-06", true, .import,
             [fact(d, "Brindle Quay", "2010-02", "2011-12", status: .former, slot: FX.emp, quote: "My first job was at Brindle Quay from 2010-02 through 2011-12."),
              fact(d, "Vellicore Maps", "2012-01", status: .unknown, slot: FX.emp, precededBy: "Brindle Quay",
                   quote: "I then joined Vellicore Maps in 2012-01, with no intervening employer.")]),
            ("m3", m3, "2017-10-12", true, .capture, m3Facts),
            ("m5", "My second Vellicore Maps stint ended in 2020-02. I moved directly to Tessel Finch in 2020-03 as a data steward.",
             "2021-01-19", true, .capture,
             [fact(d, "Vellicore Maps", nil, "2020-02", status: .former, slot: FX.emp, followedBy: "Tessel Finch",
                   quote: "My second Vellicore Maps stint ended in 2020-02."),
              fact(d, "Tessel Finch", "2020-03", status: .current, slot: FX.emp, precededBy: "Vellicore Maps",
                   quote: "I moved directly to Tessel Finch in 2020-03 as a data steward.")]),
        ])
    }

    @Test func aDepartureAndAReturnAreTwoStints() {
        for returned in [true, false] {
            let g = twoStints(returned: returned)
            let vm = g.episodes(d).filter { g.entities[$0.entity ?? ""]?.name == "Vellicore Maps" }
            #expect(vm.count == 2, "returned=\(returned): \(vm.map { ($0.start?.lo, $0.end?.hi) })")
            #expect(g.ask("Where did I go straight after my first stint at Vellicore Maps?")?.entity == g.ent("Orpin Ledger"), "returned=\(returned)")
            // The answer's comparison names the stint (13e.2's check): the job just before the second one.
            let back = TimelineIntent(predicate: d, op: .before, anchor: .entity(g.ent("Vellicore Maps")), stint: 2)
            #expect(g.answer(back, query: "").entities == [g.ent("Orpin Ledger")], "returned=\(returned)")
            #expect(g.ask("Where did I work next after Vellicore Maps?")?.isAmbiguous == true, "returned=\(returned)")
        }
    }

    // MARK: A time its quote contradicts (r3's g01 read)

    func validate(_ text: String, _ facts: [[String: Any]]) -> FactsValidated {
        let g = FactsGraph(registry: FX.registry)
        return FactsValidator(graph: g, sent: FactsSentText(text, userAliases: [], registry: .bundled), roster: [:],
                              phrases: [], predicates: [d], knownThings: [])
            .validate(FactsJSON(["facts": facts, "people": [] as [Any], "roles": [] as [Any], "things": [] as [Any]]))
    }

    func row(_ quote: String, _ name: String, time: String? = nil, start: String? = nil, status: String = "unknown") -> [String: Any] {
        ["quote": quote, "predicate": d, "entity": "name", "name": name, "label": NSNull(), "polarity": "positive",
         "status": status, "deceased": false, "only": false, "count": NSNull(), "time": time ?? NSNull(),
         "start": start ?? NSNull(), "end": NSNull(), "preceded_by": NSNull(), "followed_by": NSNull(),
         "also_called": NSNull(), "qualifiers": [String: Any]()]
    }

    @Test func aTimeTheQuoteContradictsIsDroppedOrRepaired() {
        let text = "I left my first Vellicore Maps stint in 2014-06. My next employer was Orpin Ledger, from 2014-07 through 2017-08. I returned directly to Vellicore Maps in 2017-09."
        let v = validate(text, [row("I left my first Vellicore Maps stint in 2014-06.", "Vellicore Maps", time: "2017-09")])
        #expect(v.facts.count == 1 && v.facts[0].time == nil && v.facts[0].end == "2014-06" && v.facts[0].status == .former)
        #expect(v.dropped.map(\.reason) == ["time_not_in_quote"])
        // Its own dates, a coarser form of one, or a quote with no date: kept.
        for (q, t) in [("I worked continuously for Umberkite Supply from 2012 until 2017.", "2012 until 2017"),
                       ("I was at Umberkite Supply in 2017-09.", "2017"),
                       ("Umberkite Supply remains my only employer.", "2017-09")] {
            let k = validate("\(text) \(q)", [row(q, "Umberkite Supply", time: t)])
            #expect(k.facts.first?.time == t, "\(q)")
        }
        // Two dates of its own and none of the time's: dropped, nothing guessed.
        let two = "I left Umberkite Supply in 2014-06 and came back in 2016-02."
        let w = validate(two, [row(two, "Umberkite Supply", time: "2019")])
        #expect(w.facts.first.map { $0.time == nil && $0.start == nil && $0.end == nil } == true)
    }

    @Test func twoEndsWithoutALaterStintWordStayOneConflictingStint() {
        let g = graph([
            ("m1", "I joined Umberkite Supply in 2012.", "2013-01-01", true, .capture,
             [fact(d, "Umberkite Supply", "2012", status: .current, slot: FX.emp, quote: "I joined Umberkite Supply in 2012.")]),
            ("m2", "I left Umberkite Supply in 2016.", "2017-01-01", true, .capture,
             [fact(d, "Umberkite Supply", nil, "2016", status: .former, slot: FX.emp, quote: "I left Umberkite Supply in 2016.")]),
            ("m3", "My Umberkite Supply job ended in 2018.", "2019-01-01", true, .capture,
             [fact(d, "Umberkite Supply", nil, "2018", status: .former, slot: FX.emp, quote: "My Umberkite Supply job ended in 2018.")]),
        ])
        #expect(g.episodes(d).filter { g.entities[$0.entity ?? ""]?.name == "Umberkite Supply" }.count == 1)
    }

    // MARK: When a job is known to have held (r3's g07, g20)

    /// The answer's comparison for a day ("in", one date), as the check reads it.
    func on(_ g: FactsGraph, _ day: String) -> TimelineAnswer {
        g.answer(TimelineIntent(predicate: d, op: .year, anchor: .date(g.parser.parse(day)!)), query: "")
    }

    /// r3's g07: own evidence of Copperfern Index runs to 2018; an agent's note says the user left in 2019 and joined
    /// Vespercoil Media in 2020.
    func copperfern(contract: Bool = true) -> FactsGraph {
        var rows: [Row] = [
            ("m1", "I started at Copperfern Index in 2016-06 as an archive analyst. This is my sole job.", "2016-07-02", true, .capture,
             [fact(d, "Copperfern Index", "2016-06", status: .unknown, slot: FX.emp, quote: "I started at Copperfern Index in 2016-06 as an archive analyst.")]),
            ("m3", "Year-end note: Copperfern Index was my sole employer throughout 2017 and 2018. I am still there, in the same archive analyst role.",
             "2018-12-31", true, .import,
             [fact(d, "Copperfern Index", status: .current, slot: FX.emp, quote: "Copperfern Index was my sole employer throughout 2017 and 2018. I am still there, in the same archive analyst role.")]),
            ("m4", "Alex Soler left Copperfern Index in 2019. After leaving Copperfern Index, the user joined Vespercoil Media in 2020 and still works there.",
             "2021-03-06", false, .agent,
             [fact(d, "Copperfern Index", nil, "2019", status: .former, time: "2019", quote: "Alex Soler left Copperfern Index in 2019"),
              fact(d, "Vespercoil Media", "2020", status: .current, slot: FX.emp, quote: "the user joined Vespercoil Media in 2020 and still works there")]),
        ]
        if contract {
            rows.append(("m6", "Found my 2018 Copperfern Index contract. The printed title is archive analyst. This old document says nothing about my work after that year.",
                         "2026-10-20", true, .capture,
                         [fact(d, "Copperfern Index", status: .unknown, time: "2018", quote: "Found my 2018 Copperfern Index contract. The printed title is archive analyst.")]))
        }
        return graph(rows)
    }

    @Test func aDatedRowHoldsAsOfItsOwnTime() {
        let g = copperfern()
        #expect(g.ask("Which company employed me in 2017?")?.entity == g.ent("Copperfern Index"))
        // "My 2018 contract" says it held sometime in 2018, not on a given day of it (the reviews of round 4).
        #expect(on(g, "2018-09-15").entities.isEmpty)
        // An agent's later employer is still running: "now" is told.
        #expect(g.ask("What's my current employer?")?.isAmbiguous == true)
        // Without the dated contract, nothing says it held past 2016: told, as before.
        #expect(copperfern(contract: false).ask("Which company employed me in 2017?")?.isAmbiguous == true)
    }

    /// r3's g20: "from 2015 to 2018 … still employed there on 2018-09-10", and an agent's note moving the end to 2017.
    func vikzuno(heldDay: Bool) -> FactsGraph {
        let m3 = "My next employer after Huzqari Rail was Vikzuno Analytics, where I worked as a data reviewer from 2015 to 2018. I was still employed there on 2018-09-10."
        var m3Facts = [fact(d, "Vikzuno Analytics", "2015", "2018", status: .former, slot: FX.emp, precededBy: "Huzqari Rail",
                            quote: "My next employer after Huzqari Rail was Vikzuno Analytics, where I worked as a data reviewer from 2015 to 2018.")]
        if heldDay {
            m3Facts.append(fact(d, "Vikzuno Analytics", status: .current, slot: FX.emp, time: "2018-09-10",
                                quote: "I was still employed there on 2018-09-10."))
        }
        return graph([
            ("m1", "I was an employee of Huzqari Rail from 2012 to 2014, working as a timetable assistant.", "2015-02-06", true, .import,
             [fact(d, "Huzqari Rail", "2012", "2014", status: .former, slot: FX.emp, quote: "I was an employee of Huzqari Rail from 2012 to 2014")]),
            ("m3", m3, "2019-01-14", true, .capture, m3Facts),
            ("m5", "A. Soler left Vikzuno Analytics in 2017 and next worked at Raqemi Security as an office coordinator from 2019 to 2020.",
             "2021-02-12", false, .agent,
             [fact(d, "Vikzuno Analytics", nil, "2017", status: .former, followedBy: "Raqemi Security", quote: "A. Soler left Vikzuno Analytics in 2017"),
              fact(d, "Raqemi Security", "2019", "2020", status: .former, slot: FX.emp, quote: "next worked at Raqemi Security as an office coordinator from 2019 to 2020")]),
        ])
    }

    @Test func aDayItStillHeldNarrowsItsEnd() {
        let g = vikzuno(heldDay: true)
        #expect(on(g, "2018-09-10").entities == [g.ent("Vikzuno Analytics")])
        let vk = g.episodes(d).filter { g.entities[$0.entity ?? ""]?.name == "Vikzuno Analytics" && $0.trusted }
        #expect(vk.count == 1 && vk[0].conflictEnd == false && vk[0].former)
        // A later day in 2018 is still unknown, and without the held day so is that one.
        #expect(on(g, "2018-11-20").entities.isEmpty)
        #expect(on(vikzuno(heldDay: false), "2018-09-10").entities.isEmpty)
    }

    // MARK: "Now" with an agent's newer job (r3's g07 q3)

    func check(_ g: FactsGraph, _ op: String, answer: String) -> TimelineCheckResult {
        let c = TimelineCheck(graph: g, local: nil, rows: TimelineRows.build(g, predicate: d))
        let alias = c.rows.rows.first { $0.name == answer }!.alias
        return c.check(TimelineComparison(predicate: d, op: op, answer: alias), search: "What's my current employer?")
    }

    @Test func nowIsToldWhenAnAgentsNewerJobOutlivesTheUsersEvidence() {
        let r = check(copperfern(), "current", answer: "Copperfern Index")
        #expect(r.verdict == .notSure && r.reason == .cantTell)
        // The user's own memory saying it still holds after the agent's start: the user's word stands (marked).
        var rows: [Row] = []
        rows.append(("m7", "As of 2026-10-28 I'm still at Copperfern Index.", "2026-10-28", true, .capture,
                     [fact(d, "Copperfern Index", status: .current, slot: FX.emp, time: "2026-10-28", quote: "As of 2026-10-28 I'm still at Copperfern Index.")]))
        var g = copperfern()
        for (id, text, written, trusted, source, facts) in rows {
            g.apply(FactsMemory(id: id, text: text, written: written, source: source, trusted: trusted), facts: facts)
        }
        #expect(check(g, "current", answer: "Copperfern Index").verdict == .agreesTrusted)
    }

    // MARK: The search's own reading of a comparison (r3's g13, g16, g17, g18, g23)

    func job(_ id: String, _ name: String, _ start: String?, _ end: String?, status: FactAssertion.Status = .former,
             precededBy: String? = nil, followedBy: String? = nil, quote: String? = nil, written: String = "2024-01-01") -> Row {
        let q = quote ?? "I worked at \(name)" + (start.map { " from \($0)" } ?? "") + (end.map { " to \($0)" } ?? "") + "."
        return (id, q, written, true, .capture,
                [fact(d, name, start, end, status: status, slot: FX.emp, precededBy: precededBy, followedBy: followedBy, quote: q)])
    }

    func verdict(_ g: FactsGraph, _ op: String, anchor: String? = nil, answer: String, date: String = "", stint: String = "",
                 search: String) -> TimelineCheckResult {
        let c = TimelineCheck(graph: g, local: nil, rows: TimelineRows.build(g, predicate: d))
        func alias(_ n: String) -> String { c.rows.rows.first { $0.name == n }!.alias }
        return c.check(TimelineComparison(predicate: d, op: op, anchor: anchor.map(alias) ?? "", stint: stint, anchorDate: date,
                                          answer: alias(answer)), search: search)
    }

    @Test func justBeforeAReturnFallsBackToTheStatedOrder() {
        // r3's g13: year-only stints; m6 states the return came directly after Daskuna.
        let rows: [Row] = [job("m1", "Zeruvo Cartography", "2012", "2013"),
                           job("m3", "Peltrix Ceramics", "2014", "2016"),
                           job("m5", "Daskuna Robotics", "2017", "2019", precededBy: "Peltrix Ceramics")]
        let back = job("m6", "Zeruvo Cartography", "2020", "2022", precededBy: "Daskuna Robotics",
                       quote: "I returned to Zeruvo Cartography directly after Daskuna Robotics, as a map editor again, from 2020 to 2022.",
                       written: "2026-10-28")
        let q = "Who employed me just before I came back to Zeruvo Cartography?"
        let r = verdict(graph(rows + [back]), "at_start", anchor: "Zeruvo Cartography", answer: "Daskuna Robotics", stint: "second", search: q)
        #expect(r.stands && r.op == "before", "\(r)")
        // No stated order: "still employed when I came back" stays can't tell on year-only dates.
        let plain = job("m6", "Zeruvo Cartography", "2020", "2022", quote: "I returned to Zeruvo Cartography from 2020 to 2022.", written: "2026-10-28")
        let n = verdict(graph(rows + [plain]), "at_start", anchor: "Zeruvo Cartography", answer: "Daskuna Robotics", stint: "second", search: q)
        #expect(!n.stands)
    }

    @Test func aJobLeftBeforeAnotherMustHaveEndedFirst() {
        // r3's g16: Ruzeki 2015–2018, Mavuno 2018–2020, and "a short overlap is possible".
        let g = graph([job("m1", "Ruzeki Textiles", "2015", "2018"), job("m3", "Mavuno Testing", "2018", "2020")])
        #expect(!verdict(g, "before", anchor: "Mavuno Testing", answer: "Ruzeki Textiles",
                         search: "Which company had I left immediately before starting at Mavuno Testing?").stands)
        #expect(verdict(g, "before", anchor: "Mavuno Testing", answer: "Ruzeki Textiles",
                        search: "Where did I work before Mavuno Testing?").stands)
        // r3's g23 the other way: "after leaving" Ezvuno, with Parzuki begun in March of Ezvuno's last year.
        let h = graph([job("m1", "Ezvuno Labs", "2015", "2017"), job("m3", "Parzuki Studio", "March 2017", "2020")])
        #expect(!verdict(h, "after", anchor: "Ezvuno Labs", answer: "Parzuki Studio",
                         search: "What salaried employer did I next join after leaving Ezvuno Labs?").stands)
        // A stated order settles it, overlap or not.
        let stated = graph([job("m1", "Ezvuno Labs", "2015", "2017"),
                            job("m3", "Parzuki Studio", "March 2017", "2020", precededBy: "Ezvuno Labs",
                                quote: "After leaving Ezvuno Labs, my next employer was Parzuki Studio, from March 2017 to 2020.")])
        #expect(verdict(stated, "after", anchor: "Ezvuno Labs", answer: "Parzuki Studio",
                        search: "What salaried employer did I next join after leaving Ezvuno Labs?").stands)
    }

    @Test func afterADatedBreakIsAfterThatDate() {
        // r3's g17: Nuvexa to 2019, a study break in 2020 and 2021, Zadrumi from 2022.
        let g = graph([job("m3", "Nuvexa Packaging", "2017", "2019"),
                       job("m6", "Zadrumi Energy", "2022", nil, status: .current)])
        let es = "¿Dónde trabajé después de la pausa para estudiar de 2020 y 2021?"
        let r = verdict(g, "in", answer: "Zadrumi Energy", date: "2022", search: es)
        #expect(r.stands && r.op == "after", "\(r)")
        // r3's g18: Dulqira to December 2021, a study year in 2022, Wazeko from 2023.
        let w = graph([job("m5", "Dulqira Printing", "March 2019", "December 2021"),
                       job("m6", "Wazeko Instruments", "2023", nil, status: .current)])
        #expect(verdict(w, "in", answer: "Wazeko Instruments", date: "2023",
                        search: "¿Qué empresa me contrató después del año de estudio de 2022?").stands)
        // Asked about the year itself: still can't tell (it may have begun late in 2022).
        #expect(!verdict(g, "in", answer: "Zadrumi Energy", date: "2022", search: "Where did I work in 2022?").stands)
    }

    // MARK: The reviews' counterexamples (GPT-6-Astra, Fable)

    @Test func reviewCounterexamplesForTheRead() {
        // A time contradicting a quote with two kinds of event word: dropped, nothing guessed.
        let q = "I joined Acme Tools in 2014 after leaving Birch Labs."
        let v = validate(q + " In 2017 I moved desks.", [row(q, "Acme Tools", time: "2017")])
        #expect(v.facts.first.map { $0.time == nil && $0.end == nil && $0.start == nil } == true)
        // A second stint's end given twice is a conflict in that stint, not a third one.
        let twice = graph([job("a1", "Acme Tools", "2010", "2012"),
                           job("a2", "Acme Tools", "2015", "2018", quote: "I went back to Acme Tools from 2015 to 2018."),
                           ("a3", "My second Acme Tools stint ended in 2019.", "2020-01-01", true, .capture,
                            [fact(d, "Acme Tools", nil, "2019", status: .former, slot: FX.emp, quote: "My second Acme Tools stint ended in 2019.")])])
        #expect(twice.episodes(d).filter { twice.entities[$0.entity ?? ""]?.name == "Acme Tools" }.count == 2)
        // An ordinal that isn't about a stint splits nothing.
        let quarter = graph([job("a1", "Acme Tools", "2012", "2016"),
                             ("a2", "My job at Acme Tools ended in the second quarter of 2019.", "2020-01-01", true, .capture,
                              [fact(d, "Acme Tools", nil, "2019", status: .former, slot: FX.emp, quote: "My job at Acme Tools ended in the second quarter of 2019.")])])
        #expect(quarter.episodes(d).filter { quarter.entities[$0.entity ?? ""]?.name == "Acme Tools" }.count == 1)
        // A dated contract goes to the stint of its year, not the first one, and doesn't open an end.
        let stints = graph([job("a1", "Acme Tools", "2012", "2014"),
                            job("a2", "Acme Tools", "2018", "2020", quote: "I went back to Acme Tools from 2018 to 2020."),
                            ("a3", "Found my 2019 Acme Tools contract.", "2026-01-01", true, .capture,
                             [fact(d, "Acme Tools", status: .unknown, time: "2019", quote: "Found my 2019 Acme Tools contract.")])])
        let acme = stints.episodes(d).filter { stints.entities[$0.entity ?? ""]?.name == "Acme Tools" }
        #expect(acme.count == 2 && acme.allSatisfy { !$0.conflictEnd }, "\(acme.map { ($0.start?.lo, $0.end?.hi, $0.conflictEnd) })")
        // A contract of the year it ended in is no conflict with that end.
        let left = graph([job("a1", "Acme Tools", "2015", "June 2018"),
                          ("a2", "Found my 2018 Acme Tools contract.", "2026-01-01", true, .capture,
                           [fact(d, "Acme Tools", status: .unknown, time: "2018", quote: "Found my 2018 Acme Tools contract.")])])
        #expect(left.episodes(d).filter { left.entities[$0.entity ?? ""]?.name == "Acme Tools" }.allSatisfy { !$0.conflictEnd && $0.former })
    }

    @Test func reviewCounterexamplesForTheCheck() {
        // at_start with a known gap, or asking who was "still" employing the user: no fallback to the stated order.
        let gap = graph([job("a", "Alder Works", "2016-01", "2019-01"),
                         job("b", "Birch Labs", "2019-03", nil, status: .current, precededBy: "Alder Works",
                             quote: "After Alder Works I joined Birch Labs in 2019-03.")])
        #expect(!verdict(gap, "at_start", anchor: "Birch Labs", answer: "Alder Works", search: "Who employed me right before I joined Birch Labs?").stands)
        let years = graph([job("a", "Alder Works", "2016", "2018"),
                           job("b", "Birch Labs", "2019", nil, status: .current, precededBy: "Alder Works",
                               quote: "After Alder Works I joined Birch Labs in 2019.")])
        #expect(!verdict(years, "at_start", anchor: "Birch Labs", answer: "Alder Works",
                         search: "Who was still employing me right before my first day at Birch Labs?").stands)
        // "After leaving" a job ended by the next one's start (succession): it stands.
        let succ = graph([job("a", "Alder Works", "2015", nil, status: .current, written: "2018-01-01"),
                          job("b", "Birch Labs", "2019-03", nil, status: .current, written: "2024-06-01")])
        #expect(verdict(succ, "after", anchor: "Alder Works", answer: "Birch Labs", search: "Where did I work after leaving Alder Works?").stands)
        // A day after "after" stays a day: no reread to the year.
        let day = graph([job("a", "Alder Works", "2019", "October 2020"), job("b", "Birch Labs", "June 2021", nil, status: .current)])
        #expect(!verdict(day, "in", answer: "Birch Labs", date: "2021", search: "Where was I working after 2020-03-15?").stands)
        // "Now": the user's own business confirmed today doesn't refresh the salaried job; an agent's job with no start
        // that its text last says held before the user's newest word doesn't make it stale.
        var g = copperfern()
        g.apply(FactsMemory(id: "m8", text: "As of 2026-10-28 I still run Tallow Prints, my own business.", written: "2026-10-28", source: .capture, trusted: true),
                facts: [fact(d, "Tallow Prints", "2019", status: .current, slot: FX.own, time: "2026-10-28", quote: "As of 2026-10-28 I still run Tallow Prints, my own business.")])
        #expect(check(g, "current", answer: "Copperfern Index").reason == .cantTell)
    }
}
