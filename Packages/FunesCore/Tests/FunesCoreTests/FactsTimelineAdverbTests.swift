import Foundation
import Testing
@testable import FunesCore

/// The Gates step's language round (memory processing §11.7): an adverb right before a timeline operator ("immediately
/// before Acme", "justo antes de Acme") is read as part of the operator, with the same answer as the bare operator. Only
/// the registry's adverbs, only one, and only right next to the operator; everything else still fails closed.
@Suite struct FactsTimelineAdverbTests {
    var d: String { FX.dated }

    /// Acme 2014–2016, Globex 2017–2019, Initech since 2020, each a trusted memory written in its time: before Initech is
    /// Globex, and after Acme is Globex.
    func threeJobs() -> FactsGraph {
        stateWith([fact(d, "Acme", "2014", "2016", status: .former).at("2016-12-01"),
                   fact(d, "Globex", "2017", "2019", status: .former).at("2019-12-01"),
                   fact(d, "Initech", "2020", status: .current).at("2020-06-01")])
    }

    @Test func eachAdverbAnswersAsTheBareOperator() throws {
        let s = threeJobs()
        let adverbs = try #require(s.registry.language.operatorAdverbs)
        #expect(!adverbs.isEmpty)
        let plainBefore = try #require(s.ask("Where did I work before Initech?"))
        let plainAfter = try #require(s.ask("Where did I work after leaving Acme?"))
        #expect(plainBefore.entity == s.ent("Globex") && plainAfter.entity == s.ent("Globex"))
        for a in adverbs where !["inmediatamente", "justo"].contains(a) {
            let before = s.ask("Where did I work \(a) before Initech?"), after = s.ask("Where did I work \(a) after leaving Acme?")
            #expect(before?.entity == plainBefore.entity && before?.basis == plainBefore.basis, "\(a) before")
            #expect(after?.entity == plainAfter.entity && after?.basis == plainAfter.basis, "\(a) after")
        }
        for a in ["justo", "inmediatamente"] {
            #expect(s.ask("¿Dónde trabajaba \(a) antes de Initech?")?.entity == s.ent("Globex"), "\(a)")
            #expect(s.ask("¿Dónde trabajé \(a) después de dejar Acme?")?.entity == s.ent("Globex"), "\(a) después")
        }
        #expect(s.ask("What was my job immediately before Initech?")?.entity == s.ent("Globex"))
        #expect(s.intent("Where did I go straight after leaving Acme?")?.op == .after)
        // The registry's other operator words, and date anchors.
        #expect(s.ask("Where did I work immediately prior to Initech?")?.entity == s.ent("Globex"))
        #expect(s.ask("What job came immediately following Acme?")?.entity == plainAfter.entity)
        // A date anchor takes no adverb (the boundary itself isn't established): no intent, while the bare form has one.
        for (adverb, bare) in [("Where did I work immediately before 1 February 2018?", "Where did I work before 1 February 2018?"),
                               ("Where did I work right before 2018?", "Where did I work before 2018?"),
                               ("¿Dónde trabajaba justo antes del 15 de marzo de 2018?", "¿Dónde trabajaba antes del 15 de marzo de 2018?")] {
            #expect(s.intent(adverb) == nil, "\(adverb)")
            #expect(s.intent(bare) != nil, "\(bare)")
        }
    }

    @Test func theOperatorPhraseKeepsItsEpisodeCue() throws {
        // Acme twice: "the first time" picks the first episode, as it does without the adverb.
        let s = stateWith([fact(d, "Acme", "2012", "2013", status: .former).at("2013-12-01"),
                           fact(d, "Globex", "2014", "2015", status: .former).at("2015-12-01"),
                           fact(d, "Acme", "2016", "2017", status: .former, quote: "I rejoined Acme in 2016").at("2017-12-01"),
                           fact(d, "Initech", "2018", status: .current).at("2018-06-01")])
        let plain = try #require(s.intent("Where did I work after I left Acme the first time?"))
        let adverb = try #require(s.intent("Where did I work immediately after I left Acme the first time?"))
        #expect(adverb.phrase?.hasSuffix(plain.phrase ?? "-") == true && adverb.phrase?.hasPrefix("immediately") == true)
        #expect(s.answer(adverb, query: "Where did I work immediately after I left Acme the first time?").entities
                == s.answer(plain, query: "Where did I work after I left Acme the first time?").entities)
    }

    @Test func everythingElseStillFailsClosed() {
        let s = threeJobs()
        for q in ["Where did I work shortly before Initech?",            // not a registry adverb
                  "Where did I work long before Initech?",
                  "Where did I work immediately straight before Initech?", // two adverbs: only the one next to it is read
                  "Where did I work immediately and before Initech?",     // not right next to it
                  "What did Priya do immediately before Initech?",        // someone else's
                  "Where did my wife work right before Initech?",
                  "Where did I work immediately before the promotion at Initech?",
                  "where did sam work, immediately before initech?",        // a comma: the adverb starts its own clause
                  "Did I start work immediately after leaving Acme?",       // a yes/no question about a gap
                  "Was I straight after leaving Acme?",                     // not about a job at all
                  "Was I working immediately before Initech?",
                  "¿Trabajé inmediatamente después de dejar Acme?",
                  "Where did I work immediately straight before Initech?",
                  "Where did I work not immediately before Initech?",
                  "Where did I work almost immediately after Acme?",
                  "Where did I work directly after Acme?",                  // not an operator adverb
                  "Where did I work immediately after Acme's merger?"] {
            #expect(s.intent(q) == nil, "\(q)")
        }
        // An adverb elsewhere in the question changes nothing it didn't before.
        #expect(s.intent("Right now, where do I work?")?.op == .current)
        // An employer named like an adverb is a name, not an adverb.
        let straight = stateWith([fact(d, "Straight", "2014", "2016", status: .former).at("2016-12-01"),
                                  fact(d, "Initech", "2017", status: .current).at("2017-06-01")])
        #expect(straight.intent("What did I do at Straight before Initech?") == nil)
    }

    @Test func aRegistryWithoutAdverbsReadsThemAsBefore() throws {
        let reg = try FX.registry { json in
            var lang = json["language"] as! [String: Any]
            lang.removeValue(forKey: "operator_adverbs")
            json["language"] = lang
        }
        let s = stateWith([fact(d, "Acme", "2015", "June 2018", status: .former), fact(d, "Globex", "July 2018", status: .current)],
                          registry: reg)
        #expect(s.intent("Where did I work immediately before Globex?") == nil)
        #expect(s.intent("Where did I work before Globex?") != nil)
    }

    @Test func adverbsAreReadSideOnlyAndMoveNoExtractionDigest() throws {
        let reg = try FX.registry { json in
            var lang = json["language"] as! [String: Any]
            lang.removeValue(forKey: "operator_adverbs")
            json["language"] = lang
        }
        #expect(reg.extractionDigests == FactsRegistry.bundled.extractionDigests)
        #expect(reg.fingerprint != FactsRegistry.bundled.fingerprint)
    }
}
