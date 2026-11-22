import Foundation
import Testing
@testable import FunesCore

/// The language layer fails closed (memory processing §11.3, §11.7): a question outside the grammar gets no timeline
/// intent (plain search), and a role phrase that may be quoted speech is skipped. A misread costs an answer, never
/// gives a wrong one.
@Suite struct FactsFailClosedTests {
    let d = FX.dated
    let w = FX.word(FX.personSuccession)

    func jobs() -> FactsGraph {
        stateWith([fact(d, "EarlierCo", "2008", "2009", status: .former), fact(d, "Acme", "2010", "2012", status: .former),
                   fact(d, "Globex", "2013", "2014", status: .former), fact(d, "Acme", "2015", "2018", status: .former),
                   fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
    }

    @Test func aQuestionOutsideTheGrammarHasNoIntent() {
        let s = jobs()
        for q in ["Where did I work before the big reorg at Initech?", "Where did I work before Initech bought Globex?",
                  "Where did I work before moving cities to join Initech?", "Where did I work 2016?",
                  "My 2016 job was where?", "Where did I work in 2016 and who was my boss?"] {
            #expect(s.intent(q)?.anchor == nil, "\(q)")
        }
        for q in ["Where did I work before Initech?", "Where did I work before I joined Initech?",
                  "Where did I work in 2016?", "Where did I work back in 2016?", "¿Dónde trabajaba en marzo de 2016?",
                  "Where did I work between 2013 and 2014?"] {
            #expect(s.intent(q)?.anchor != nil, "\(q)")
        }
    }

    @Test func episodeCuesComeFromTheOperatorPhraseOnly() {
        let s = jobs()
        let stray = "First question: where did I work before Acme?"
        let it = s.intent(stray)
        // Told, or since 13e.1 no intent at all (every word of the question counts): never the first stint's answer.
        #expect(it.map { s.answer($0, query: stray).basis } ?? .ambiguous == .ambiguous)
        let q = "Where did I work before Acme the first time?"
        #expect(s.intent(q).map { s.name(s.answer($0, query: q).entity) } == "EarlierCo")
    }

    /// 13e.2: a paired name never spans a line break, so a title line can't join the name that opens the body.
    @Test func aPairedNameStaysOnItsLine() {
        let s = FactsGraph(registry: FX.registry)
        for (text, name) in [("Dinner\nMax is my \(w).", "Max"), ("Note\nJoana is my \(w); we met in 2019.", "Joana"),
                             ("Max Ruiz is my \(w).", "Max Ruiz"), ("Plans\nMy \(w) Max\nRuiz called.", "Max")] {
            #expect(s.rolePhrases(text).first?.paired == name, "\(text)")
        }
        // Nor does a pair: the role ending one line isn't paired with the name opening the next.
        for text in ["My \(w)\nAlice is my manager.", "Dinner with my \(w)\nMax came too."] {
            #expect(s.rolePhrases(text).first?.paired == nil, "\(text)")
        }
        // Nor does the phrase itself: an owner ending one line and the role word opening the next.
        #expect(s.rolePhrases("Dinner with my\n\(w.capitalized) Alice called.").isEmpty)
        #expect(!s.rolePhrases("Dinner with my \(w)\nAlice called.").isEmpty)
    }

    @Test func aPhraseThatMayBeQuotedIsSkipped() {
        let s = FactsGraph(registry: FX.registry)
        for text in ["She wrote: 'my \(w) is late and", "She said: 'I'm tired. My \(w) is mean.'",
                     "‘my \(w) is late’ she said.", "He said, \"my \(w) is late\".", "'Yes' and my \(w) agreed."] {
            #expect(s.rolePhrases(text).isEmpty, "\(text)")
        }
        for text in ["He said \"I don't know\" and then my \(w) arrived.", "I bought a 27\" monitor and my \(w) approved it.",
                     "The kids' teacher and my \(w) had coffee.", "I'm sure my \(w) called.",
                     "She said: 'I'm tired.'\nMy \(w) called."] {
            #expect(!s.rolePhrases(text).isEmpty, "\(text)")
        }
    }
}
