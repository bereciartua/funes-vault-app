import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 13e.1, the timeline round (memory processing §11.4–§11.7, §11.9): a never-denial reaching an agent's claim,
/// the placeholder fold, an import's "current", a stated rename read as one entity, answers resting on untrusted text
/// told, slot words, anchor dates, and the grammar's minimal pairs. Each rule is tested with its counterexample.
@Suite struct FactsTimelineRoundTests {
    let d = FX.dated

    /// One memory per row: (id, text, written, trusted, source, facts).
    func graph(_ rows: [(String, String, String, Bool, FactsMemory.Source, [ExtractedFact])]) -> FactsGraph {
        var g = FactsGraph(registry: FX.registry)
        for (id, text, written, trusted, source, facts) in rows {
            g.apply(FactsMemory(id: id, text: text, written: written, source: source, trusted: trusted), facts: facts)
        }
        return g
    }

    func named(_ g: FactsGraph, _ name: String) -> [LearnedFact] {
        g.facts.filter { f in f.predicate == d && g.entities[f.entity]?.name == name }
    }

    // MARK: A never-denial

    var claim: (String, String, String, Bool, FactsMemory.Source, [ExtractedFact]) {
        ("a", "The user left Brindle Systems and joined Orlin Labs in July 2020.", "2021-01-09", false, .agent,
         [fact(d, "Orlin Labs", "July 2020", status: .current, slot: FX.emp, quote: "joined Orlin Labs in July 2020")])
    }

    func denial(_ text: String = "Correction: I never worked at Orlin Labs.", status: FactAssertion.Status = .unknown,
                written: String = "2022-04-08") -> (String, String, String, Bool, FactsMemory.Source, [ExtractedFact]) {
        ("u", text, written, true, .capture, [fact(d, "Orlin Labs", status: status, quote: "Orlin Labs", positive: false)])
    }

    @Test func aNeverDenialReachesAnAgentsClaimInEitherOrder() {
        for rows in [[claim, denial()], [denial(), claim]] {
            let g = graph(rows)
            #expect(named(g, "Orlin Labs").allSatisfy { $0.negated }, "\(rows.map(\.0))")
            #expect(!g.episodes(d).contains { g.entities[$0.entity ?? ""]?.name == "Orlin Labs" })
        }
        // Spanish, and the word elsewhere in the quote's sentence.
        let es = graph([claim, ("u", "Nunca trabajé en Orlin Labs.", "2022-04-08", true, .capture,
                                [fact(d, "Orlin Labs", quote: "Orlin Labs", positive: false)])])
        #expect(named(es, "Orlin Labs").allSatisfy { $0.negated })
    }

    @Test func aNoLongerOrAnotherNameNeverReachesIt() {
        // "No longer" is an end, not a never: the agent's claim stays (marked untrusted).
        let ended = graph([claim, denial("I no longer work at Orlin Labs.", status: .current)])
        #expect(named(ended, "Orlin Labs").contains { !$0.negated })
        // Not a never-word in its sentence: the claim stays.
        let other = graph([claim, denial("I didn't work at Orlin Labs in 2019.")])
        #expect(named(other, "Orlin Labs").contains { !$0.negated })
        // The never-word must be in the denied name's own sentence, even when the quote spans more.
        let text = "I have never visited Vela. Orlin Labs was not my employer."
        let apart = graph([claim, ("u", text, "2022-04-08", true, .capture, [fact(d, "Orlin Labs", quote: text, positive: false)])])
        #expect(named(apart, "Orlin Labs").contains { !$0.negated })
        // Only exactly the same name: "Orlin" doesn't reach "Orlin Labs".
        let short = graph([claim, ("u", "I never worked at Orlin.", "2022-04-08", true, .capture,
                                   [fact(d, "Orlin", quote: "Orlin", positive: false)])])
        #expect(named(short, "Orlin Labs").contains { !$0.negated })
    }

    @Test func aTrustedHireAfterTheDenialStillCounts() {
        let g = graph([claim, denial(), ("v", "I joined Orlin Labs in March 2024.", "2024-03-10", true, .capture,
                                         [fact(d, "Orlin Labs", "March 2024", status: .current, slot: FX.emp, quote: "joined Orlin Labs in March 2024")])])
        #expect(named(g, "Orlin Labs").contains { !$0.negated && $0.trusted })
        // An agent's claim after the denial doesn't.
        let again = graph([denial(), claim])
        #expect(named(again, "Orlin Labs").allSatisfy { $0.negated })
    }

    // MARK: The placeholder fold

    var business: (String, String, String, Bool, FactsMemory.Source, [ExtractedFact]) {
        ("b", "Desde 2018 trabajo por cuenta propia con mi negocio Nudo Estudio.", "2018-11-09", true, .capture,
         [fact(d, "Nudo Estudio", "2018", status: .current, slot: FX.own, quote: "mi negocio Nudo Estudio")])
    }

    @Test func aPlaceholderTiedToAKnownBusinessIsThatBusiness() {
        let g = graph([business, ("c", "Sigo trabajando por cuenta propia con Nudo Estudio.", "2026-10-06", true, .capture,
                                  [fact(d, "Self-employed", status: .current, slot: FX.own, quote: "Sigo trabajando por cuenta propia")])])
        #expect(named(g, "Self-employed").isEmpty)
        #expect(named(g, "Nudo Estudio").first?.assertions.count == 2)
    }

    @Test func aPlaceholderStaysItselfWithoutTheTieOrForAClosedBusiness() {
        // No linking word in its clause.
        let loose = graph([business, ("c", "Sigo por cuenta propia. Nudo Estudio va bien.", "2026-10-06", true, .capture,
                                      [fact(d, "Self-employed", status: .current, slot: FX.own, quote: "Sigo por cuenta propia")])])
        #expect(!named(loose, "Self-employed").isEmpty)
        // The same memory ends the business.
        let closed = graph([business, ("c", "Cerré Nudo Estudio en 2024; sigo por cuenta propia con Nudo Estudio como marca vieja.",
                                       "2026-10-06", true, .capture,
                                       [fact(d, "Nudo Estudio", nil, "2024", status: .former, slot: FX.own, quote: "Cerré Nudo Estudio en 2024"),
                                        fact(d, "Self-employed", status: .current, slot: FX.own, quote: "sigo por cuenta propia")])])
        #expect(!named(closed, "Self-employed").isEmpty)
        // An agent's note never folds.
        let agent = graph([business, ("c", "The user still works por cuenta propia con Nudo Estudio.", "2026-10-06", false, .agent,
                                      [fact(d, "Self-employed", status: .current, slot: FX.own, quote: "works por cuenta propia")])])
        #expect(!named(agent, "Self-employed").isEmpty)
    }

    // MARK: An import's "current"

    @Test func anImportsCurrentHoldsAsOfItsOwnTime() {
        let rows: [(String, String, String, Bool, FactsMemory.Source, [ExtractedFact])] = [
            ("m1", "I joined Pollen House in February 2018.", "2018-03-01", true, .capture,
             [fact(d, "Pollen House", "February 2018", status: .current, slot: FX.emp, quote: "joined Pollen House")]),
            ("m2", "After leaving Pollen House in May 2021, I joined Sable Editions in June 2021.", "2022-02-04", true, .capture,
             [fact(d, "Pollen House", nil, "May 2021", status: .former, slot: FX.emp, quote: "leaving Pollen House"),
              fact(d, "Sable Editions", "June 2021", status: .current, slot: FX.emp, quote: "joined Sable Editions")]),
        ]
        let page = ("m3", "Imported notebook page from February 2018: I started at Pollen House.", "2025-11-07", true,
                    FactsMemory.Source.import, [fact(d, "Pollen House", status: .current, slot: FX.emp, time: "February 2018", quote: "started at Pollen House")])
        let g = graph(rows + [page])
        let ph = g.episodes(d).filter { g.entities[$0.entity ?? ""]?.name == "Pollen House" }
        #expect(ph.count == 1 && ph[0].conflictEnd == false && ph[0].former)
        #expect(g.ask("What company was I at before Sable Editions?")?.entity == g.ent("Pollen House"))
        // A capture's "current" still holds as of its date: written after the end, it's a conflict as before.
        let late = graph(rows + [("m3", "I'm still at Pollen House.", "2025-11-07", true, .capture,
                                  [fact(d, "Pollen House", status: .current, slot: FX.emp, quote: "still at Pollen House")])])
        #expect(late.episodes(d).contains { late.entities[$0.entity ?? ""]?.name == "Pollen House" && $0.conflictEnd })
    }

    // MARK: A stated rename

    func renamed(extra: [(String, String, String, Bool, FactsMemory.Source, [ExtractedFact])] = []) -> FactsGraph {
        var renamedFact = fact(d, "Lattice Harbor", "2017", status: .current, slot: FX.emp, quote: "joined Lattice Harbor in 2017")
        renamedFact.alsoCalled = "Lattice Harbor Labs"
        return graph([
            ("m1", "Before joining Lattice Harbor, I worked at Ember Circuit.", "2018-02-17", true, .capture,
             [fact(d, "Ember Circuit", "2014", "2016", status: .former, slot: FX.emp, quote: "worked at Ember Circuit"),
              fact(d, "Lattice Harbor", status: .current, slot: FX.emp, quote: "joining Lattice Harbor")]),
            ("m2", "I'm still the lab coordinator at Lattice Harbor Labs.", "2019-03-14", true, .capture,
             [fact(d, "Lattice Harbor Labs", status: .current, slot: FX.emp, quote: "at Lattice Harbor Labs")]),
            ("m3", "I joined Lattice Harbor in 2017. Renamed Lattice Harbor Labs in 2020; my employment did not restart.", "2020-11-20",
             true, .capture, [renamedFact]),
            ("m4", "After leaving Lattice Harbor Labs in December 2024, I joined Alder Signal in January 2025.", "2026-08-12", true, .capture,
             [fact(d, "Lattice Harbor Labs", nil, "December 2024", status: .former, slot: FX.emp, quote: "leaving Lattice Harbor Labs"),
              fact(d, "Alder Signal", "January 2025", status: .current, slot: FX.emp, quote: "joined Alder Signal")]),
        ] + extra)
    }

    @Test func aStatedRenameIsOneEntityOnTheTimeline() {
        let g = renamed()
        let short = g.ent("Lattice Harbor"), long = g.entityMatches(d, "Lattice Harbor Labs").first!
        #expect(short != long)                                              // links keep both
        #expect(g.statedGroups(d) == [[short, long]])
        let eps = g.episodes(d).filter { $0.entity == short || $0.entity == long }
        #expect(eps.count == 1 && !eps[0].inferredEnd && eps[0].end?.precision == .month)
        let a = g.ask("What was my job before Alder Signal?")
        #expect(a.map { g.timelineEntity(d, $0.entity ?? "") } == g.timelineEntity(d, long) && a?.basis == .inferred)
        #expect(g.ask("Where did I go after Ember Circuit?")?.entity == g.timelineEntity(d, long))
    }

    @Test func aRenameIsntOneEntityWhenTheUserSaysNotTheSameOrAJobSitsBetween() {
        var g = renamed()
        let short = g.ent("Lattice Harbor"), long = g.entityMatches(d, "Lattice Harbor Labs").first!
        g.notSame.insert([short, long])
        #expect(g.statedGroups(d).isEmpty)
        // A trusted job of the same kind between the two: separate stints, never one entity.
        var a = fact(d, "Lattice Harbor", "2010", "2011", status: .former, slot: FX.emp, quote: "Lattice Harbor 2010 to 2011")
        a.alsoCalled = "Kite Labs"
        let between = graph([
            ("m1", "Lattice Harbor 2010 to 2011.", "2012-01-01", true, .capture, [a]),
            ("m2", "Mosaic 2012 to 2014.", "2015-01-01", true, .capture,
             [fact(d, "Mosaic", "2012", "2014", status: .former, slot: FX.emp, quote: "Mosaic 2012 to 2014")]),
            ("m3", "Kite Labs since 2016.", "2017-01-01", true, .capture,
             [fact(d, "Kite Labs", "2016", status: .current, slot: FX.emp, quote: "Kite Labs since 2016")]),
        ])
        #expect(between.statedGroups(d).isEmpty)
    }

    // MARK: Answers resting on untrusted text

    @Test func anAnswerOnlyAnAgentsNoteGivesIsTold() {
        let g = graph([("a", "The user works at Vela Metrics.", "2024-05-01", false, .agent,
                        [fact(d, "Vela Metrics", "2023", status: .current, slot: FX.emp, quote: "works at Vela Metrics")])])
        #expect(g.ask("Where do I work now?")?.isAmbiguous == true)
    }

    // MARK: Anchor dates

    func rehire() -> FactsGraph {
        graph([
            ("m1", "From 2016 to May 2018 I worked at North Kestrel.", "2023-02-01", true, .capture,
             [fact(d, "North Kestrel", "2016", "May 2018", status: .former, slot: FX.emp, quote: "worked at North Kestrel")]),
            ("m2", "From June 2018 through 2020 I worked at Copper Delta.", "2023-02-02", true, .capture,
             [fact(d, "Copper Delta", "June 2018", "2020", status: .former, slot: FX.emp, quote: "worked at Copper Delta")]),
            ("m3", "I rejoined North Kestrel in January 2021.", "2023-02-03", true, .capture,
             [fact(d, "North Kestrel", "January 2021", status: .current, slot: FX.emp, quote: "rejoined North Kestrel in January 2021")]),
        ])
    }

    @Test func anAnchorsDatePicksItsEpisode() {
        let g = rehire()
        #expect(g.ask("Where did I work before rejoining North Kestrel in January 2021?")?.entity == g.ent("Copper Delta"))
        #expect(g.ask("Which employer did I join after leaving North Kestrel in May 2018?")?.entity == g.ent("Copper Delta"))
        // A date no stated boundary of the anchor fits, or one that clashes with an episode cue: told.
        #expect(g.ask("Where did I work before rejoining North Kestrel in 2019?")?.isAmbiguous == true)
        #expect(g.ask("Where did I work before joining North Kestrel the first time in January 2021?").map(\.isAmbiguous) ?? true)
        // Without the date, two episodes and no cue: told, as before.
        #expect(g.ask("Where did I work before North Kestrel?")?.isAmbiguous == true)
    }

    // MARK: The grammar's minimal pairs

    @Test func newWordingsAndTheirCounterexamples() {
        let g = rehire()
        let yes = ["Employer immediately before Copper Delta?",                       // a noun phrase takes the adverb
                   "Company I worked for right before Copper Delta",
                   "Which employer preceded Copper Delta?",
                   "What was my next employer after leaving Copper Delta?",
                   "Last employer before Copper Delta?",
                   "Where did I go after Copper Delta?",                              // the anchor is the cue
                   "Before I joined Copper Delta, where did I work?",                 // a leading operator clause
                   "¿Qué empleo vino después de Copper Delta?",
                   "Mi empleador anterior a Copper Delta",
                   "¿Qué compañía me contrató tras dejar Copper Delta?",
                   "My payroll employer in October 2019?",
                   "October 2019: which company employed me?",
                   "En el año 2019, ¿qué empresa me tenía en plantilla?",
                   "Which organization currently employs me?",
                   "¿En qué empresa sigo trabajando?"]
        for q in yes { #expect(g.intent(q) != nil, "\(q)") }
        let no = ["Did I start work immediately after leaving Copper Delta?",          // yes/no: a gap question
                  "¿Trabajé inmediatamente después de dejar Copper Delta?",
                  "Who did I call after Copper Delta?",                               // no cue: every word must be the user's
                  "Who did I hire after Copper Delta?",
                  "Before Copper Delta, who fixed my laptop?",
                  "Which firm did I hire in 2021?",                                   // a verb outside its frame
                  "What company did I pay in 2020?",
                  "What was I paid before Copper Delta?",
                  "In 2021, where did I work before Copper Delta?",                   // a date the anchor doesn't explain
                  "Where did I go after the Copper Delta offsite?",
                  "Which bookkeeping business do I currently operate?",               // an unknown content word
                  "What was my summer job before Copper Delta?",
                  "Where did my sister work before Copper Delta?"]
        for q in no { #expect(g.intent(q) == nil, "\(q)") }
        // Slot words in the user's clause set the slot; describing the anchor, they don't.
        #expect(g.intent("Which day job came before Copper Delta?")?.slot == FX.emp)
        #expect(g.intent("Where did I work before my day job at Copper Delta?")?.slot == nil)
        #expect(g.intent("What's the name of my ongoing freelance operation?")?.slot == FX.own)
    }
}

/// The diff reviews' counterexamples (13e.1, GPT-6-Astra and Fable 5.2): none of these may answer.
@Suite struct FactsTimelineRoundReviewTests {
    let d = FX.dated
    typealias Row = (String, String, String, Bool, FactsMemory.Source, [ExtractedFact])
    func graph(_ rows: [Row]) -> FactsGraph {
        var g = FactsGraph(registry: FX.registry)
        for (id, text, written, trusted, source, facts) in rows {
            g.apply(FactsMemory(id: id, text: text, written: written, source: source, trusted: trusted), facts: facts)
        }
        return g
    }
    func jobs() -> FactsGraph {
        graph([
            ("m1", "From 2012 to 2015 I worked at Brindle.", "2023-02-01", true, .capture,
             [fact(d, "Brindle", "2012", "2015", status: .former, slot: FX.emp, quote: "worked at Brindle")]),
            ("m2", "Since 2016 I run my own business Nudo Estudio.", "2023-02-02", true, .capture,
             [fact(d, "Nudo Estudio", "2016", status: .current, slot: FX.own, quote: "my own business Nudo Estudio")]),
            ("m3", "From 2016 to 2019 I worked at Copper Delta.", "2023-02-03", true, .capture,
             [fact(d, "Copper Delta", "2016", "2019", status: .former, slot: FX.emp, quote: "worked at Copper Delta")]),
            ("m4", "I joined Alder Signal in January 2020.", "2023-02-04", true, .capture,
             [fact(d, "Alder Signal", "January 2020", status: .current, slot: FX.emp, quote: "joined Alder Signal")]),
        ])
    }

    @Test func questionsThatArentAboutWhereIWorkedNeverAnswer() {
        let g = jobs()
        let qs = ["Where did I move after leaving Copper Delta?", "What did I get after leaving Copper Delta?",
                  "What did I keep after Copper Delta?", "What did I take after Copper Delta?", "Who was I with before Copper Delta?",
                  "What did I run before Copper Delta?", "Which firm is still handling my taxes?", "What work do I still have to finish today?",
                  "Which business still owes me a refund?", "Is my business still profitable?", "What company did I call today?",
                  "What work do I have today?", "¿Qué empresa era antes mi cliente?", "Does my job still pay well?", "Is the company still hiring?",
                  "In 2019, what did I set up at work?", "Which company did I found in 2019?", "What's still on my work laptop?",
                  "What did I work on before Copper Delta?", "Who did I work with before Copper Delta?", "¿Con quién trabajaba antes de Copper Delta?",
                  "¿Qué empresa sigue debiéndome dinero?", "Who came after me at Copper Delta?", "Who was there before me at Copper Delta?",
                  "Who did I freelance for in 2018?", "Who was on my payroll in 2019?", "Who was my employee in 2019?",
                  "Who did I have on payroll in 2019?", "Where did I work after my Copper Delta job started in 2016?",
                  "Where did I work before my Copper Delta job ended in 2019?", "¿A qué empleo precedió Copper Delta?",
                  "Which job was preceded by Copper Delta?", "What was my last day at work?", "Who is now my employer's CEO?",
                  "Once I left Copper Delta, where did I move?", "Upon leaving Copper Delta, what did I get?", "After Copper Delta, what did I get?",
                  "Who paid me after Copper Delta?", "Who took over my business after Copper Delta?", "Which company took me to court in 2019?",
                  "Is work still stressful?", "What job am I still waiting to hear back from?", "Which employer still has my pension?",
                  "What freelance work is still unpaid?", "Which company is active on my account today?", "What am I working on today?",
                  "What am I working on now?", "Who am I working with now?", "Which business did I open an account with in 2019?",
                  "Where did I go on my first day after Copper Delta?", "Where was my employer based before Copper Delta?",
                  "Which company was I at when I left Copper Delta?", "Where did I work when I left Copper Delta?",
                  "¿Dónde trabajé cuando dejé Copper Delta?", "What did I do when I quit Copper Delta?", "Who was following me at Copper Delta?",
                  "Did I work at Brindle before Copper Delta?", "Which one came first, Brindle or Copper Delta?", "Employee of the month, 2018",
                  "Who was employee of the month in 2018?", "What business did I run from my place before Copper Delta?",
                  "What did I go by before Copper Delta?", "What do I do for work these days?", "What did I previously call my business?",
                  "Which company did I call before Alder Signal?", "¿A quién llamaba mi empresa antes de Alder Signal?",
                  "Am I still employed?", "¿Sigo trabajando?", "How does my business operate now?", "Did I work in 2017?",
                  // Round 2: events in a year, and questions about other people or things at work.
                  "Which company did I join in 2019?", "Which company did I leave in 2019?", "Where did I start working in 2019?",
                  "Which company did I return to in 2019?", "¿Qué empresa dejé en 2019?", "¿En qué empresa entré en 2019?",
                  "Which company did I join last?", "What did I leave at work today?", "What did I do at work today?",
                  "What job do I have to do today?", "What is new at my company today?", "Who is at my company now?",
                  "Who is running my company now?", "What is my company working on now?", "Which company is my employer working with now?",
                  "¿Qué me dejé en el trabajo hoy?", "¿Qué trabajo tengo hoy?", "Who left the company in 2019?", "Who joined the company in 2019?",
                  "Who took my job in 2019?", "Who was behind my company in 2019?", "What did I work on at my job in 2019?",
                  "¿Quién se fue de la empresa en 2019?", "¿Con quién trabajaba en la empresa en 2019?", "Who had my job before Copper Delta?",
                  "Who held my role before Copper Delta?", "Who took my role after Copper Delta?", "Who was at the company with me before Copper Delta?",
                  "Where did I go after work at Copper Delta?", "Where is my company now?", "Who worked for my employer in 2019?",
                  "¿Quién trabajaba para mi empresa en 2019?", "Who was my employer's employer in 2019?",
                  "What was my previous employer in 2019?", "¿Cuál era mi empleador anterior en 2019?",
                  // Round 3.
                  "¿De qué empresa me fui en 2019?", "Whose company did I work for in 2019?", "Where is my last job now?",
                  "Which job did I take in 2019?", "What was the last job I took?", "What job did I take last?",
                  "Which company did I set up in 2019?", "Which company did I move from in 2019?", "Which company did I come from in 2019?",
                  "¿A qué empresa fui en 2019?", "Which company did I leave after Copper Delta?", "¿Qué empresa dejé después de Copper Delta?",
                  "Which company did I join after 2018?", "Which company did I leave before 2019?", "What do I do at my current job?",
                  "What did I do at my last job?", "What did I do at my job in 2019?", "What did I do at my job before Copper Delta?",
                  "¿Qué fue de mi empresa anterior?", "¿Qué tengo en el trabajo ahora?", "¿En qué trabajo ahora?", "What was my role in 2019?",
                  "What was my second job in 2019?", "Who did I work for at my last job?", "Who did I work for at my company in 2019?",
                  "Where do I work from now?", "Where am I currently working from?", "Where is my employer now?", "Where was my job in 2019?",
                  "¿Dónde estaba mi empresa en 2019?", "¿Cómo era mi trabajo anterior?", "¿Sigo en mi empresa?",
                  "Where did I work before Copper Delta moved?", "Where did I work before Copper Delta opened?",
                  "Which company is still working for me?", "¿Qué empresa sigue trabajando para mí?",
                  "What was my first day job before Alder Signal?", "¿Cuál fue mi primer empleo de día antes de Alder Signal?"]
        // No intent at all: a told answer would still be a timeline question read where there's none.
        for q in qs {
            let it = g.intent(q)
            #expect(it == nil, "\(q) → \(it.map { g.answer($0, query: q).entities.compactMap { g.name($0) } } ?? [])")
        }
    }

    @Test func theAnchorsOtherKindIsNoCandidate() {
        // Employee Brindle 2010–2011, self-employed as Acme 2012–2013, then employed at Acme from 2014.
        let g = graph([
            ("m1", "Brindle 2010 to 2011.", "2015-01-01", true, .capture, [fact(d, "Brindle", "2010", "2011", status: .former, slot: FX.emp, quote: "Brindle")]),
            ("m2", "Freelanced as Acme 2012 to 2013.", "2015-01-02", true, .capture, [fact(d, "Acme", "2012", "2013", status: .former, slot: FX.own, quote: "Acme")]),
            ("m3", "I rejoined Acme in 2014 as an employee.", "2015-01-03", true, .capture,
             [fact(d, "Acme", "2014", status: .current, slot: FX.emp, quote: "rejoined Acme in 2014")]),
        ])
        let a = g.ask("Which employer came before rejoining Acme in 2014?")
        #expect(a.map { $0.entity == g.ent("Brindle") || $0.entities.isEmpty } ?? true)
    }

    @Test func anAgentOnlyCurrentEpisodeIsToldThoughTheEntityHadATrustedOne() {
        let g = graph([
            ("m1", "I worked at Acme from 2010 to 2012.", "2013-01-01", true, .capture,
             [fact(d, "Acme", "2010", "2012", status: .former, slot: FX.emp, quote: "worked at Acme")]),
            ("a", "The user rejoined Acme in 2024.", "2024-05-01", false, .agent,
             [fact(d, "Acme", "2024", status: .current, slot: FX.emp, quote: "rejoined Acme in 2024")]),
        ])
        #expect(g.ask("Where do I work now?").map { $0.entities.isEmpty } ?? true)
    }

    @Test func aCueThatCantBeMetIsNeverOverriddenByADate() {
        let g = graph([
            ("m1", "Acme 2014 to 2016.", "2017-01-01", true, .capture, [fact(d, "Acme", "2014", "2016", status: .former, slot: FX.emp, quote: "Acme")]),
            ("m2", "Beta 2017 to 2020.", "2020-06-01", true, .capture, [fact(d, "Beta", "2017", "2020", status: .former, slot: FX.emp, quote: "Beta")]),
            ("m3", "I rejoined Acme in January 2021.", "2021-02-01", true, .capture,
             [fact(d, "Acme", "January 2021", status: .current, slot: FX.emp, quote: "rejoined Acme in January 2021")]),
        ])
        #expect(g.ask("Where did I work before my third stint at Acme in January 2021?").map { $0.entities.isEmpty } ?? true)
    }

    @Test func aDateAnchorRestingOnAnAgentsEpisodeIsTold() {
        let g = graph([
            ("m1", "Acme 2010 to 2011.", "2012-01-01", true, .capture, [fact(d, "Acme", "2010", "2011", status: .former, slot: FX.emp, quote: "Acme")]),
            ("a", "The user worked at Acme from 2020 to 2022.", "2023-01-01", false, .agent,
             [fact(d, "Acme", "2020", "2022", status: .former, slot: FX.emp, quote: "worked at Acme from 2020 to 2022")]),
        ])
        // Never from the agent's stint: told, or the user's own 2010–2011 stint with its gap told.
        #expect(g.ask("Where did I work before January 2021?").map { $0.entities.isEmpty || $0.basis == .gap } ?? true)
    }

    @Test func qualifiedNeversArentNeverDenials() {
        let trusted: Row = ("t", "I joined Orlin Labs in July 2020.", "2020-08-01", true, .capture,
                            [fact(d, "Orlin Labs", "July 2020", status: .current, slot: FX.emp, quote: "joined Orlin Labs")])
        for text in ["I never worked at Orlin Labs before 2020.", "I never worked at Orlin Labs as an employee, only as a contractor.",
                     "I never worked full-time at Orlin Labs.", "Nunca trabajé en Orlin Labs a tiempo completo.",
                     "I never stopped working at Orlin Labs.", "My brother never worked at Orlin Labs but I did.",
                     "Until last year, I had never worked at Orlin Labs.", "Before 2020, I never worked at Orlin Labs.",
                     "I never worked at Orlin Labs, except for a summer internship.", "As an employee, I never worked at Orlin Labs.",
                     "My brother, unlike me, never worked at Orlin Labs.", "I never worked at Orlin Labs: I was a contractor there for years",
                     "I never left Orlin Labs.", "Nunca dejé Orlin Labs.", "Nunca trabajó en Orlin Labs."] {
            var g = graph([trusted])
            let r = fact(d, "Orlin Labs", quote: text, positive: false)
            #expect(!g.isNeverDenial(r, text: text), "\(text)")
            g.apply(FactsMemory(id: "u", text: text, written: "2022-01-01", trusted: true), facts: [r])
            #expect(!g.facts.contains { $0.neverDenied }, "\(text)")
        }
        for text in ["I never worked at Orlin Labs.", "I have never worked at Orlin Labs.", "Nunca trabajé en Orlin Labs.",
                     "Orlin Labs has never been my employer.", "Correction: I never worked at Orlin Labs."] {
            #expect(FactsGraph(registry: FX.registry).isNeverDenial(fact(d, "Orlin Labs", quote: text, positive: false), text: text), "\(text)")
        }
    }

    @Test func neverWordsThatDontDenyHoldingIt() {
        let claim: Row = ("a", "The user joined Orlin Labs in July 2020.", "2021-01-09", false, .agent,
                          [fact(d, "Orlin Labs", "July 2020", status: .current, slot: FX.emp, quote: "joined Orlin Labs in July 2020")])
        for (text, st) in [("I no longer work at Orlin Labs and I'm never going back.", FactAssertion.Status.current),
                           ("I never went back to Orlin Labs after the layoffs.", .unknown),
                           ("I no longer work at Orlin Labs because I never liked it.", .current),
                           ("Ya no trabajo en Orlin Labs y nunca volveré.", .current),
                           ("Ya no trabajo en Orlin Labs porque nunca me gustó.", .unknown)] {
            let g = graph([claim, ("u", text, "2022-04-08", true, .capture, [fact(d, "Orlin Labs", status: st, quote: text, positive: false)])])
            #expect(g.facts.contains { $0.predicate == d && g.entities[$0.entity]?.name == "Orlin Labs" && !$0.negated }, "\(text)")
        }
    }

    @Test func aFoldNeverCrossesASentenceOrANegation() {
        let biz: Row = ("b", "Mi negocio Nudo Estudio.", "2018-11-09", true, .capture,
                        [fact(d, "Nudo Estudio", "2018", status: .current, slot: FX.own, quote: "Nudo Estudio")])
        for text in ["I now freelance through a new business. I had a meeting with Nudo Estudio.",
                     "Sigo por cuenta propia pero ya no con Nudo Estudio.",
                     "I'm still self-employed but no longer with Nudo Estudio.",
                     "I am self-employed and have a meeting with Nudo Estudio tomorrow.",
                     "Trabajo por cuenta propia y tengo una reunión con Nudo Estudio mañana.",
                     "I'm now freelancing on my own instead of with Nudo Estudio.", "Ahora soy autónomo en vez de con Nudo Estudio.",
                     "I'm freelancing again after my time with Nudo Estudio.", "I stopped freelancing with Nudo Estudio.",
                     "I'm self-employed as Nudo Estudio's competitor.", "I quit freelancing with Nudo Estudio.",
                     "I'm done freelancing with Nudo Estudio.", "Antes era autónomo con Nudo Estudio.", "My wife is freelancing with Nudo Estudio.",
                     "I miss being self-employed with Nudo Estudio.", "I'm thinking of going freelance with Nudo Estudio next year.",
                     "I'm freelancing with Nudo Estudio clients now.",
                     "Ana is freelancing through Nudo Estudio and I am self-employed independently."] {
            let g = graph([biz, ("c", text, "2026-10-06", true, .capture,
                                 [fact(d, "Self-employed", status: .current, slot: FX.own, quote: text)])])
            #expect(g.facts.contains { g.entities[$0.entity]?.name == "Self-employed" }, "\(text)")
        }
    }
}

/// The never-denial through the store: stored with the denial, the same in either order, gone with it.
@Suite struct FactsNeverDenialStoreTests {
    let v: TestVault
    let d = FX.dated
    var work: String { FX.registry.predicate(d)!.callGroup }
    init() throws { v = try TestVault() }

    func memory(_ body: String, at days: Double = 0, untrusted: Bool = false) throws -> Memory {
        let m = try v.memory("Note", body, now: t0.plus(days: days))
        if untrusted { try v.store.writer.write { db in try db.execute(sql: "UPDATE memory SET trust = 'untrusted' WHERE id = ?", arguments: [m.id.db]) } }
        return m
    }

    func apply(_ m: Memory, _ facts: [ExtractedFact], at days: Double) throws {
        let current = try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
        _ = try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: current.version, extraction: FactsExtraction(facts: facts),
                                callGroup: work, now: t0.plus(days: days))
        }
    }

    func orlin() throws -> [LearnedFact] {
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        return g.facts.filter { f in f.predicate == d && g.entities[f.entity]?.name == "Orlin Labs" }
    }

    func anyOpen() throws -> Bool { try orlin().contains { !$0.negated } }
    func allDenied() throws -> Bool { try orlin().allSatisfy { $0.negated } }

    let claimFact = fact(FX.dated, "Orlin Labs", "July 2020", status: .current, slot: FX.emp, quote: "joined Orlin Labs in July 2020")
    let denialFact = fact(FX.dated, "Orlin Labs", quote: "Orlin Labs", positive: false)

    @Test func theDenialHoldsInEitherOrderAndGoesWithItsMemory() throws {
        let a = try memory("The user joined Orlin Labs in July 2020.", untrusted: true)
        try apply(a, [claimFact], at: 0)
        #expect(try anyOpen())
        let u = try memory("Correction: I never worked at Orlin Labs.", at: 1)
        try apply(u, [denialFact], at: 1)
        #expect(try allDenied())
        // An agent saying it again later doesn't bring it back.
        let b = try memory("The user works at Orlin Labs.", at: 2, untrusted: true)
        try apply(b, [fact(d, "Orlin Labs", status: .current, slot: FX.emp, quote: "works at Orlin Labs")], at: 2)
        #expect(try allDenied())
        // Deleting the denial brings the claims back (marked untrusted).
        _ = try v.store.deleteMemory(id: u.id, now: t0.plus(days: 3))
        try v.store.purgeMemory(id: u.id, now: t0.plus(days: 4))
        #expect(try anyOpen())
    }

    @Test func aSecondDenialHoldsWhenTheFirstIsDeleted() throws {
        let a = try memory("The user joined Orlin Labs in July 2020.", untrusted: true)
        try apply(a, [claimFact], at: 0)
        let u1 = try memory("Correction: I never worked at Orlin Labs.", at: 1)
        try apply(u1, [denialFact], at: 1)
        let u2 = try memory("I have never worked at Orlin Labs.", at: 2)
        try apply(u2, [denialFact], at: 2)
        _ = try v.store.deleteMemory(id: u1.id, now: t0.plus(days: 3))
        try v.store.purgeMemory(id: u1.id, now: t0.plus(days: 4))
        #expect(try allDenied())
    }

    @Test func eachDenialOfAMemoryKeepsItsOwnNever() throws {
        let u = try memory("I didn't work at Brindle in 2019. And I never worked at Orlin Labs.")
        try apply(u, [fact(d, "Brindle", time: "2019", quote: "Brindle", positive: false), denialFact], at: 0)
        let a = try memory("The user joined Orlin Labs in July 2020.", at: 1, untrusted: true)
        try apply(a, [claimFact], at: 1)
        #expect(try allDenied())
    }

    @Test func aDenialReadFirstHoldsAgainstTheClaimReadLater() throws {
        let u = try memory("Correction: I never worked at Orlin Labs.")
        try apply(u, [denialFact], at: 0)
        let a = try memory("The user joined Orlin Labs in July 2020.", at: 1, untrusted: true)
        try apply(a, [claimFact], at: 1)
        #expect(try allDenied())
    }
}
