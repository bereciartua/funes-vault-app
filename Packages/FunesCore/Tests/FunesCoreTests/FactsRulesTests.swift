import Foundation
import Testing
@testable import FunesCore

/// Spike H3's generic rules (`spikes/people/test_facts.py`), ported. Canned extractions go through `apply`, then
/// resolution and the timeline run as they would on a model's output.
@Suite struct FactsRulesTests {
    let d = FX.dated

    @Test func sideBusinessDoesNotEndDayJob() {
        let s = stateWith([fact(d, "Acme", "2018", status: .current, slot: FX.emp).at("2018-06-01"),
                           fact(d, "MyShop", "2020", status: .current, slot: FX.own).at("2020-06-01"),
                           fact(d, "Initech", "2021", status: .current, slot: FX.emp).at("2021-06-01")])
        let eps = s.episodesByName()
        #expect(eps["Acme"]!.inferredEnd)
        #expect(eps["Acme"]!.endedBy?.entity == s.ent("Initech"))     // ended by the next job in its slot
        #expect(eps["MyShop"]!.end == nil)                             // nothing in its slot followed it
        #expect(s.beforeName("Initech") == ("Acme", .inferred))
    }

    @Test func successiveJobsChainButConcurrentOnesEndNothing() {
        var s = stateWith([fact(d, "Acme", "2018", status: .current, slot: FX.emp).at("2018-06-01"),
                           fact(d, "Globex", "2019", status: .current, slot: FX.emp).at("2019-06-01"),
                           fact(d, "Initech", "2021", status: .current, slot: FX.emp).at("2021-06-01")])
        var eps = s.episodesByName()
        #expect(eps["Acme"]!.endedBy?.entity == s.ent("Globex"))
        #expect(eps["Globex"]!.endedBy?.entity == s.ent("Initech"))
        s = stateWith([fact(d, "Acme", "2018", status: .current, slot: FX.emp),     // said current in 2026: still held
                       fact(d, "Globex", "2019", status: .current, slot: FX.emp).at("2019-06-01"),
                       fact(d, "Initech", "2021", status: .current, slot: FX.emp).at("2021-06-01")])
        eps = s.episodesByName()
        #expect(eps["Globex"]!.end == nil)       // Acme was still open when Initech started: which one ended is unknown
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
    }

    @Test func successionNeverEndsAFactStatedAsFormer() {
        let s = stateWith([fact(d, "Acme", "2015", "2018", status: .former, slot: FX.emp),
                           fact(d, "Globex", "2016", status: .former, slot: FX.emp),
                           fact(d, "Initech", "2019", slot: FX.emp)])
        #expect(!s.episodesByName()["Globex"]!.inferredEnd)                 // ended, but when isn't known
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)       // it could have ended after Acme
    }

    @Test func untrustedNeverTriggersSuccession() {
        let s = stateWith([fact(d, "Acme", "2018", slot: FX.emp), fact(d, "Initech", "2021", slot: FX.emp).untrusted])
        #expect(s.episodesByName()["Acme"]!.end == nil)
    }

    @Test func gapIsTold() {
        let s = stateWith([fact(d, "Acme", "2015", "January 2016", status: .former), fact(d, "Initech", "June 2016")])
        #expect(s.beforeName("Initech") == ("Acme", .gap))
    }

    @Test func tieAtWrittenPrecisionIsAmbiguous() {
        let s = stateWith([fact(d, "Acme", "2015", "2019", status: .former), fact(d, "Globex", "2016", "March 2019", status: .former),
                           fact(d, "Initech", "2020")])
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)       // "2019" may be before or after March 2019
    }

    @Test func monthPrecisionDecides() {
        let s = stateWith([fact(d, "Acme", "2015", "February 2019", status: .former),
                           fact(d, "Globex", "2016", "December 2019", status: .former), fact(d, "Initech", "January 2020")])
        #expect(s.beforeName("Initech") == ("Globex", .ordered))
    }

    @Test func currentOrOverlappingNeverBefore() {
        let s = stateWith([fact(d, "Acme", "2015", status: .current), fact(d, "Initech", "2020")])
        #expect(s.beforeName("Initech").0 == nil)
    }

    @Test func statedEdgeWinsAndContradictionsFallBackToDates() {
        var s = stateWith([fact(d, "Acme", "2015", "2017", status: .former), fact(d, "Globex", "2016", "2017", status: .former),
                           fact(d, "Initech", "2018", precededBy: "Globex")])        // the dates tie; the edge decides
        #expect(s.beforeName("Initech") == ("Globex", .stated))
        s = stateWith([fact(d, "Acme", "2015", "June 2017", status: .former, followedBy: "Initech"),
                       fact(d, "Initech", "July 2017", precededBy: "Acme"), fact(d, "Acme", precededBy: "Initech")])
        let got = s.beforeName("Initech")
        #expect(got.0 == "Acme" && [.ordered, .stated].contains(got.1))         // the dates rule out the contradiction
    }

    @Test func conflictingEndIsAmbiguous() {
        let s = stateWith([fact(d, "Acme", "2015", "March 2019", status: .former), fact(d, "Acme", nil, "May 2019", status: .former),
                           fact(d, "Initech", "June 2019")])
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
    }

    @Test func sameDateAtTwoPrecisionsIsNotAConflict() {
        let s = stateWith([fact(d, "Acme", "2015", "2019", status: .former), fact(d, "Acme", nil, "June 2019", status: .former),
                           fact(d, "Initech", "July 2019")])
        #expect(s.beforeName("Initech") == ("Acme", .ordered))
    }

    @Test func rejoinIsASecondEpisode() {
        let s = stateWith([fact(d, "Acme", "2014", "2016", status: .former), fact(d, "Globex", "2017", "2019", status: .former),
                           fact(d, "Acme", "2020", "2021", status: .former)])
        #expect(s.episodes(of: "Acme").count == 2)
        #expect(s.beforeName("Acme", "before I returned to Acme").0 == "Globex")
        #expect(s.beforeName("Acme", "before Acme").0 == nil)                    // which Acme? told, not guessed
    }

    private func roleState(_ pred: String, _ word: String) -> (FactsGraph, FactsMemory, RolePhrase) {
        var s = FactsGraph(registry: FX.registry)
        let text = "My \(word) Robin called."
        let mem = FactsMemory(id: "m1", text: text, written: "2026-01-01")
        s.apply(mem, phrases: s.rolePhrases(text), people: [ExtractedPerson(name: "Robin")],
                facts: [fact(pred, "Robin", label: word, quote: "My \(word) Robin")])
        let text2 = "My \(word) likes tea."
        let m2 = FactsMemory(id: "m2", text: text2, written: "2026-02-01")
        return (s, m2, s.rolePhrases(text2)[0])
    }

    @Test func exclusivePredicateResolvesStatedUniqueOthersSoleKnown() {
        let reg = FX.registry
        let ex = FX.personPredicate { $0.exclusive && $0.lexicon.contains { $0.plural != true } }
        let word = reg.predicate(ex)!.lexicon.first { $0.plural != true && $0.cls == nil }!.words[0]
        var (s, m, ph) = roleState(ex, word)
        #expect(s.resolve(m, ph).basis == .statedUnique)
        let other = FX.personPredicate { p in
            !p.exclusive && p.lexicon.contains { $0.cls != nil && $0.exclusive != true && $0.plural != true }
        }
        let word2 = reg.predicate(other)!.lexicon.first { $0.cls != nil && $0.exclusive != true && $0.plural != true }!.words[0]
        (s, m, ph) = roleState(other, word2)
        #expect(s.resolve(m, ph).basis == .soleKnown)
    }

    @Test func dateCueNeedsTheTimelineUse() throws {
        let words = FX.registry.lexicon.filter { $0.value.predicate == d }.map(\.key).sorted()
        let cue = FX.registry.language.dateCueWords[0]
        let rows: [FactRowConvertible] = [fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Initech", "2019", status: .current)]
        var s = stateWith(rows)
        let text = "At my \(cue) \(words[0]) I used Emacs."
        let mem = FactsMemory(id: "mx", text: text, written: "2020-06-01")
        let got = s.resolve(mem, s.rolePhrases(text)[0])
        #expect(s.name(got.entity) == "Acme" && got.basis == .inferred)
        let reg = try FX.registry { json in
            FX.editPredicate(&json, d) { p in p["uses"] = (p["uses"] as! [String]).filter { $0 != "timeline" } }
        }
        var s2 = stateWith(rows, registry: reg)
        #expect(s2.resolve(mem, s2.rolePhrases(text)[0]).basis != .inferred)   // without the use, only a status cue
    }

    @Test func intentNegativesAndPositives() {
        let s = stateWith([fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Initech", "2019", status: .current)])
        for q in ["What was my job before Initech?", "What was I doing right before joining Initech?"] {
            #expect(s.intent(q).map { [$0.predicate, $0.op.rawValue] } == [d, "before"], "\(q)")
        }
        for q in ["What was my title at Initech before the promotion?", "What did we use before Initech moved to Slack?",
                  "What do I need to do before the Initech demo?"] {
            #expect(s.intent(q) == nil, "\(q)")
        }
    }
}
