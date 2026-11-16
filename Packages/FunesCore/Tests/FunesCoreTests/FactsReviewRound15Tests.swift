import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 15 (Fable 5.2).
@Suite struct ReviewRound15Tests {
    let d = FX.dated

    func jobs() -> FactsGraph {
        stateWith([fact(d, "Globex", "2010", "2014", status: .former), fact(d, "BBC", "2015", "2018", status: .former),
                   fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
    }

    // H1: a determiner that belongs to the anchor itself ("the BBC", "la BBC") blocks the anchor.
    @Test func h1_aDeterminerRightBeforeTheAnchorIsPartOfIt() {
        let s = jobs()
        var missed: [String] = []
        for q in ["Where did I work before the BBC?", "Where did I work after I left the BBC?", "Where did I work before joining the BBC?",
                  "¿Dónde trabajé antes de la BBC?", "¿Dónde trabajé después de dejar la BBC?"] {
            var ok = false
            if case .entity(let id)? = s.intent(q)?.anchor { ok = s.name(id) == "BBC" }
            if !ok { missed.append(q) }
        }
        #expect(missed.isEmpty, "\(missed)")
    }

    // H2: a determiner inside the date itself ("the 15th of March 2019", "el 15 de marzo de 2019", "the year 2016") blocks a date anchor.
    @Test func h2_aDeterminerInsideTheDateIsPartOfIt() {
        let s = jobs()
        var missed: [String] = []
        for q in ["Where did I work before the 15th of March 2019?", "Where did I work after the 3rd of May 2016?",
                  "¿Dónde trabajaba antes del 15 de marzo de 2019?", "¿Dónde trabajaba antes de el 15 de marzo de 2019?",
                  "Where did I work before March 2019?", "Where did I work before 2019?"] {
            var ok = false
            if case .date? = s.intent(q)?.anchor { ok = true }
            if !ok { missed.append(q) }
        }
        #expect(missed.isEmpty, "\(missed)")
    }

    // H3 (probe): what the determiner rule is for stays out, in both languages and for both anchor kinds.
    @Test func h3_anotherNounPhraseStaysOut() {
        let s = jobs()
        for q in ["What was my job title before the promotion at Initech?", "Where did I work before the reorg at the BBC?",
                  "What did I do before the promotion in 2020?", "¿Qué hacía antes de la reunión con Initech?",
                  "¿Dónde trabajaba antes de la mudanza en 2016?"] {
            let it = s.intent(q)
            #expect(it?.anchor == nil, "\(q)")
        }
    }

    // H4 (probe): contractions aren't unknown names, and the round 14 list still anchors.
    @Test func h4_contractionsAndAuxiliaries() {
        let s = jobs()
        for q in ["Where did I work after I'd left Initech?", "Where did I work before I was at Initech?",
                  "Where did I work after I’d left Initech?", "Where did I work before my time at Initech?"] {
            var ok = false
            if case .entity? = s.intent(q)?.anchor { ok = true }
            #expect(ok, "\(q)")
        }
    }
}

/// Adversarial review, round 15 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound15AstraTests {
    let d = FX.dated

    @Test func p1_aQuotedContractionMakesNoRoleLink() {
        let w = FX.word(FX.personExclusive)
        #expect(FactsGraph().rolePhrases("The witness said, \"my \(w) doesn't drink coffee\".").isEmpty)
        #expect(FactsGraph().rolePhrases("The witness said, “my \(w) doesn’t drink coffee”.").isEmpty)
    }

    @Test func p2_theUsersLatestSlotValueWins() throws {
        var s = stateWith([fact(d, "Acme", "2015", status: .current, slot: FX.emp).at("2016-01-01"),
                           fact(d, "Initech", "2019", status: .current, slot: FX.emp).at("2020-01-01")])
        let acme = s.ent("Acme")
        let i = try #require(s.facts.firstIndex { $0.entity == acme })
        for (value, written) in [(FX.emp, "2026-11-15"), (FX.own, "2026-11-16")] {
            var a = FactAssertion(memoryID: "user", trusted: true, written: written, status: .unknown, qualifiers: [FX.slot: value],
                                  states: true, quote: "", handover: false)
            a.fromUser = true
            s.facts[i].assertions.append(a)
        }
        let e = try #require(s.episodes(of: "Acme").first)
        #expect(e.slot == FX.own && !e.inferredEnd)
        #expect(s.resolveText("At my \(FX.word(d)) I use Emacs.", "2021-01-01").1 == .candidates)
    }

    @Test func p3_aPromotionQuestionIsNotAnEmployerTimeline() {
        let s = stateWith([fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Initech", "2019", status: .current)])
        #expect(s.intent("What was my job title before being promoted at Initech?") == nil)
        #expect(s.intent("Where did I work before Initech?")?.op == .before)
    }

    @Test func p4_aModifiedPossessiveChainIsSkipped() throws {
        let sib = try #require(FX.registry.predicates.first { p in p.objectKind == "person" && p.lexicon.contains { $0.cls != nil } })
        let w = sib.lexicon.first { $0.cls != nil }!.words[0]
        let noun = FX.registry.language.personNouns[0]
        #expect(FactsGraph().rolePhrases("My \(w)'s very kind \(noun) drinks mate.").isEmpty)
        #expect(FactsGraph().rolePhrases("My \(w)'s \(noun) drinks mate.").isEmpty)
    }
}
