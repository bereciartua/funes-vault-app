import Foundation
import Testing
@testable import FunesCore

/// The trust rules (memory processing §11.8, Phase 13a.1): untrusted evidence never resolves a trusted memory, never
/// ends an episode that has trusted evidence or triggers succession, never orders anything at full basis, and never
/// changes a trusted fact; an episode with only untrusted evidence gives dates at `inferred` at most and links at
/// `untrusted`; a link's basis is the weakest in its chain.
@Suite struct FactsTrustTests {
    let d = FX.dated

    @Test func untrustedEvidenceNeverResolvesATrustedMemory() {
        var s = stateWith([fact(d, "Acme", "2015", status: .current).untrusted(at: "2016-01-01")])
        #expect(s.resolveText("At my \(FX.word(d)) I use Emacs.", "2017-01-01") == ("Acme", .untrusted))
    }

    @Test func anUntrustedEndNeverEndsATrustedEpisode() {
        let s = stateWith([fact(d, "Acme", "2015", status: .current).at("2016-01-01"),
                           fact(d, "Acme", nil, "2018", status: .former).untrusted(at: "2019-01-01"),
                           fact(d, "Acme", status: .former).untrusted(at: "2020-01-01")])
        let acme = s.episodes(of: "Acme")
        #expect(acme.count == 1 && acme[0].end == nil && acme[0].ongoing)
    }

    @Test func untrustedSuccessionNeverEndsATrustedEpisode() {
        let s = stateWith([fact(d, "Acme", "2018", status: .current, slot: FX.emp).at("2018-06-01"),
                           fact(d, "Initech", "2021", status: .current, slot: FX.emp).untrusted(at: "2021-06-01")])
        #expect(!s.episodes(of: "Acme")[0].inferredEnd)
    }

    @Test func untrustedDatesNeverOrderAtFullBasis() {
        let s = stateWith([fact(d, "Acme", "2015", "2018", status: .former).untrusted,
                           fact(d, "Initech", "2019", status: .current)])
        let got = s.beforeName("Initech")
        #expect(got.0 == nil || got.1 == .inferred)
        #expect(s.inRange(d, FX.rangeOfYear(2016)).basis != .ordered)
    }

    @Test func anUntrustedDenialNeverNegatesATrustedFact() {
        var s = stateWith([fact(d, "Acme", "2015", status: .current)])
        s.apply(FactsMemory(id: "neg", text: "Acme", written: "2026-02-01", source: .agent),
                facts: [fact(d, "Acme", positive: false)])
        #expect(!s.facts[0].negated)
        s.apply(FactsMemory(id: "neg2", text: "Acme", written: "2026-03-01"), facts: [fact(d, "Acme", positive: false)])
        #expect(s.facts[0].negated)        // a trusted denial does
    }

    @Test func anUntrustedMemorysDecisionIsUntrusted() {
        let pp = FX.personSuccession
        var s = peopleState(pp, [("Ana", nil, nil, .current, "2020-01-01"), ("Bo", nil, nil, .current, "2020-01-02")])
        let text = "My \(FX.word(pp)) approved it."
        let ana = s.ent("Ana", pp)
        let mem = FactsMemory(id: "a1", text: text, written: "2021-01-01", source: .agent)
        s.apply(mem, phrases: s.rolePhrases(text), roles: [ExtractedRole(phrase: 0, refersTo: ana)], roster: [ana])
        let got = s.resolve(mem, s.rolePhrases(text)[0])
        #expect(got.entity == ana && got.basis == .untrusted)
    }

    @Test func aPreviousLinkFromAnUntrustedMemoryIsUntrusted() {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Initech", "2019", status: .current)])
        let cue = FX.registry.language.dateCueWords[0]
        let text = "At my \(cue) \(FX.word(d)) I used Emacs."
        let mem = FactsMemory(id: "a2", text: text, written: "2020-06-01", source: .agent)
        let got = s.resolve(mem, s.rolePhrases(text)[0])
        #expect(s.name(got.entity) == "Acme" && got.basis == .untrusted)
    }
}

extension FX {
    static func rangeOfYear(_ y: Int) -> DateRange {
        DateRange(lo: DayNumber.from(year: y, month: 1, day: 1)!, hi: DayNumber.from(year: y, month: 12, day: 31)!,
                  precision: .year)
    }
}
