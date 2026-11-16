import Foundation
import Testing
@testable import FunesCore

/// Adversarial review, round 17 (GPT-6-Astra and Fable 5.2): each finding is a test.
@Suite struct FactsReviewRound17Tests {
    let d = FX.dated
    let q2 = "Where did I work before Acme the second time?"

    private var history: [FactRow] { [
        fact(d, "EarlierCo", "2012-01-01", "2014-12-31", status: .former).row,
        fact(d, "Acme", "2015-01-01", "2016-12-31", status: .former).row,
        fact(d, "Globex", "2017-01-01", "2019-12-31", status: .former).row,
        fact(d, "Acme", "2020-01-01", status: .current).row,
    ] }

    // Astra 1: an untrusted episode can't renumber the trusted ones.
    @Test func untrustedEpisodesDontRenumberTrustedOnes() throws {
        let base = stateWith(history)
        #expect(base.beforeName("Acme", q2) == ("Globex", .ordered))
        let s = stateWith(history + [fact(d, "Acme", "2010-01-01", "2011-12-31", status: .former).untrusted])
        #expect(s.beforeName("Acme", q2) == ("Globex", .ordered))
    }

    // Astra 2: one known episode still has its ordinal checked.
    @Test func aMissingSecondEpisodeIsAmbiguous() {
        let s = stateWith([fact(d, "EarlierCo", "2012-01-01", "2014-12-31", status: .former),
                           fact(d, "Acme", "2015-01-01", status: .current)])
        #expect(s.beforeName("Acme", q2).1 == .ambiguous)
        #expect(s.beforeName("Acme", "Where did I work before Acme?") == ("EarlierCo", .ordered))
    }

    // Astra 3: words of the anchor's own name aren't episode cues.
    @Test func anAnchorsNameIsNotAnEpisodeCue() {
        let s = stateWith([fact(d, "EarlierCo", "2012-01-01", "2014-12-31", status: .former),
                           fact(d, "First National Bank", "2015-01-01", "2016-12-31", status: .former),
                           fact(d, "Globex", "2017-01-01", "2019-12-31", status: .former),
                           fact(d, "First National Bank", "2020-01-01", status: .current)])
        #expect(s.beforeName("First National Bank", "Where did I work before First National Bank?").1 == .ambiguous)
        #expect(s.beforeName("First National Bank", "Where did I work before First National Bank the first time?")
                == ("EarlierCo", .ordered))
    }

    // Astra 4 and 5: a plural possessive inside single quotes doesn't close them; "ex-wife" is a chain's person noun.
    @Test func quotedPluralPossessivesAndPrefixedChains() {
        let s = FactsGraph(registry: FX.registry)
        let w = FX.word(FX.personExclusive)
        for text in ["The witness said, 'The kids' teacher and my \(w) drink coffee'.",
                     "The witness said, ‘The kids’ teacher and my \(w) drink coffee’.",
                     "My \(w)'s ex-wife drinks coffee.", "My \(w)'s ex wife drinks coffee."] {
            #expect(s.rolePhrases(text).isEmpty, "\(text)")
        }
        #expect(!s.rolePhrases("The kids' teacher and my \(w) drink coffee.").isEmpty)
    }

    // Fable M1: a contraction is expanded only where it completes an operator, so names keep it.
    @Test func aNameWithAContractionStillAnchors() {
        let s = stateWith([fact(d, "Globex", "2010", "2014", status: .former), fact(d, "Banco del Sur", "2015", "2016", status: .former),
                           fact(d, "Al Jazeera", "2017", "2018", status: .former), fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
        for (q, want) in [("¿Dónde trabajé antes de Banco del Sur?", "Banco del Sur"), ("Where did I work before Banco del Sur?", "Banco del Sur"),
                          ("Where did I work after Al Jazeera?", "Al Jazeera"), ("¿Dónde trabajé después de Al Jazeera?", "Al Jazeera"),
                          ("¿Dónde trabajé antes del Banco del Sur?", "Banco del Sur")] {
            var got: String?
            if case .entity(let id)? = s.intent(q)?.anchor { got = s.name(id) }
            #expect(got == want, "\(q)")
        }
        #expect(s.intent("¿Dónde trabajaba antes del 15 de marzo de 2019?")?.op == .before)
        #expect(s.intent("¿Dónde trabajaba antes del despido en 2016?") == nil)
    }
}
