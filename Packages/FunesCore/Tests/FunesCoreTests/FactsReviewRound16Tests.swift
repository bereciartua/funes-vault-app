import Foundation
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 16 (GPT-6-Astra and Fable 5.2): each finding is a test.
@Suite struct FactsReviewRound16Tests {
    let d = FX.dated
    let pp = FX.personSuccession
    var w: String { FX.word(pp) }

    // Astra 1: "the second time" is the second episode, not the latest (inherited from the spike).
    @Test func secondMeansTheSecondEpisode() throws {
        let s = stateWith([
            fact(d, "Acme", "2010-01-01", "2011-12-31", status: .former),
            fact(d, "Globex", "2012-01-01", "2014-12-31", status: .former),
            fact(d, "Acme", "2015-01-01", "2016-12-31", status: .former),
            fact(d, "Initech", "2017-01-01", "2019-12-31", status: .former),
            fact(d, "Acme", "2020-01-01", status: .current),
        ])
        for (q, want) in [("Where did I work before Acme the second time?", "Globex"),
                          ("Where did I work before Acme the third time?", "Initech"),
                          ("Where did I work after Acme the first time?", "Globex")] {
            let it = try #require(s.intent(q), "\(q)")
            let a = s.answer(it, query: q)
            #expect(s.name(a.entity) == want && a.basis == .ordered, "\(q)")
        }
        // Past the episodes known, or cues that disagree: told, not guessed.
        for q in ["Where did I work before Acme the fourth time?", "Where did I work before I returned to Acme the first time?"] {
            if let it = s.intent(q) { #expect(s.answer(it, query: q).basis == .ambiguous, "\(q)") }
        }
    }

    // Astra 2: a contraction inside single quotes doesn't end the quote.
    @Test func aSingleQuotedContractionMakesNoRoleLink() {
        let s = FactsGraph(registry: FX.registry)
        #expect(s.rolePhrases("The witness said, 'my \(w) doesn't drink coffee'.").isEmpty)
        #expect(s.rolePhrases("The witness said, ‘my \(w) doesn’t drink coffee’.").isEmpty)
        #expect(!s.rolePhrases("The kids' toys are here and my \(w) called.").isEmpty)
    }

    // Astra 3: a second trusted entity sharing a bare name makes the earlier named mention ambiguous (§11.4).
    @Test func aNamesakeReopensAnEarlierBareName() {
        var s = FactsGraph(registry: FX.registry)
        s.apply(FactsMemory(id: "m0", text: "Alex recommended tea.", written: "2020-01-01"), people: [ExtractedPerson(name: "Alex")])
        #expect(s.names[.init(memoryID: "m0", surface: "Alex")]?.basis == .named)
        // An untrusted memory's namesake doesn't reopen it.
        var u = s
        u.apply(FactsMemory(id: "m1", text: "Alex Smith recommended coffee.", written: "2021-01-01", trusted: false),
                people: [ExtractedPerson(name: "Alex Smith")])
        #expect(u.names[.init(memoryID: "m0", surface: "Alex")]?.basis == .named)
        s.apply(FactsMemory(id: "m1", text: "Alex Smith recommended coffee.", written: "2021-01-01"),
                people: [ExtractedPerson(name: "Alex Smith")])
        let link = s.names[.init(memoryID: "m0", surface: "Alex")]
        #expect(link?.entity == nil && link?.basis == .ambiguous && link?.candidates.count == 2)
        #expect(s.names[.init(memoryID: "m1", surface: "Alex Smith")]?.basis == .named)
    }

    // Astra 4: a model decision whose memory isn't restored (a skipped duplicate) takes its dependencies with it.
    @Test func aSkippedDecisionsDependenciesArentRestored() throws {
        let t = try FactsStoreTests()
        let (_, _, _, decided) = try t.decidedState()
        let section = try #require(try t.v.store.writer.write { db in
            try FactsExport.section(db, exporting: Set(try String.fetchAll(db, sql: "SELECT id FROM memory")), now: t0)
        })
        #expect(!section.decisionDependencies.isEmpty)
        let fresh = try TestVault()
        var map: [String: (id: String, version: Int)] = [:]
        for row in try t.v.store.writer.read({ db in try Row.fetchAll(db, sql: "SELECT id, body FROM memory") })
        where (row["id"] as String) != decided.id.db {
            let m = try fresh.memory("Note", row["body"] as String)
            map[row["id"] as String] = (m.id.db, m.version)
        }
        let ok = try fresh.store.writer.write { db in try FactsExport.restore(db, section, memories: map, now: t0) }
        #expect(ok)
        #expect(try fresh.count("SELECT COUNT(*) FROM mention_decision WHERE source = 'model'") == 0)
        #expect(try fresh.count("SELECT COUNT(*) FROM decision_dependency") == 0)
        #expect(try fresh.count("SELECT COUNT(*) FROM fact") >= 2)
    }

    // Fable W1: "antes del" / "después del" are the operators with the article contracted, answered as in English.
    @Test func antesDelIsBefore() throws {
        let s = stateWith([fact(d, "Globex", "2010", "2014", status: .former), fact(d, "BBC", "2015", "2018", status: .former),
                           fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
        for (q, op, english) in [("¿Dónde trabajaba antes del 15 de marzo de 2019?", TimelineIntent.Operator.before,
                                  "Where did I work before 15 March 2019?"),
                                 ("¿Dónde trabajaba después del 3 de mayo de 2014?", .after, "Where did I work after 3 May 2014?"),
                                 ("¿Dónde trabajaba antes de 2015?", .before, "Where did I work before 2015?")] {
            let it = try #require(s.intent(q), "\(q)")
            let en = try #require(s.intent(english), "\(english)")
            #expect(it.op == op && it == en, "\(q)")
            #expect(s.answer(it, query: q) == s.answer(en, query: english), "\(q)")
        }
        let it = try #require(s.intent("¿Dónde trabajaba antes de 2015?"))
        #expect(s.name(s.answer(it, query: "").entity) == "Globex")
    }

    // Fable M1, M2 and the year noun: a possessive's chain stops at a function word or an owner; a straight quote
    // opens only at a boundary; "the year 2019" is a date.
    @Test func chainsQuotesAndTheYearNoun() {
        let s0 = FactsGraph(registry: FX.registry)
        for (text, want) in [("My \(w)'s note to my sister was kind.", true), ("My \(w)'s email about my brother arrived.", true),
                             ("My \(w)'s wife called.", false), ("My \(w)'s very kind wife called.", false),
                             ("I bought a 27\" monitor and my \(w) approved the \"premium\" stand.", true),
                             ("She said \"my \(w) is late\" and left.", false),
                             ("He said \"I don't know\" and then my \(w) arrived.", true)] {
            #expect(s0.rolePhrases(text).contains { $0.predicate == pp } == want, "\(text)")
        }
        let s = stateWith([fact(d, "Globex", "2010", "2014", status: .former), fact(d, "BBC", "2015", "2018", status: .former),
                           fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
        func kind(_ q: String) -> String {
            switch s.intent(q)?.anchor { case .entity?: "entity"; case .date?: "date"; default: "none" }
        }
        for (q, want) in [("Where did I work before the BBC?", "entity"), ("¿Dónde trabajé antes de la BBC?", "entity"),
                          ("Where did I work before the 15th of March 2019?", "date"), ("¿Dónde trabajaba antes del 15 de marzo de 2019?", "date"),
                          ("Where did I work before the year 2019?", "date"), ("¿Dónde trabajaba antes del año 2019?", "date"),
                          ("Where did I work before the reorg at the BBC?", "none"), ("¿Dónde trabajaba antes del despido en 2016?", "none"),
                          ("¿Dónde trabajaba antes del cierre de Initech?", "none"), ("Where did I work before he joined the BBC?", "none")] {
            #expect(kind(q) == want, "\(q)")
        }
        #expect(s.intent("What was my job title before Initech?") == nil)
        #expect(s.intent("¿Cuál era mi cargo antes de Initech?") == nil)
    }
}
