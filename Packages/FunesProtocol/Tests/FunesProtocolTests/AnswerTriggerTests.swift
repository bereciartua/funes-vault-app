import Foundation
import Testing
@testable import FunesProtocol

/// Automatic search answers (memory processing §10.6): which searches are questions, and how
/// `status.get` carries the trigger between app versions.
@Suite struct AnswerTriggerTests {
    @Test(arguments: [
        "What's my title at Chatham?", "what is my title at chatham", "When does the lease end", "who is Lucía",
        "how do I reset the router", "my title at Chatham?", "  title?  ", "¿Dónde vive mi hermana", "donde vive mi hermana",
        "Cuándo vence el contrato", "cuanto pagué de alquiler", "Por qué cambié de banco", "por que cambie de banco",
        "Quién es Lucía", "Cómo hago el pan", "Which bank", "Why did I leave", "en qué banco tengo la cuenta",
        "a quién llamo si se corta la luz", "para qué sirve el router", "De dónde es Lucía", "desde cuándo pago el gimnasio",
    ])
    func questions(_ query: String) {
        #expect(AnswerTrigger.isQuestion(query))
        #expect(AnswerTrigger.questions.fires(for: query))
    }

    @Test(arguments: [
        "Chatham title", "lease", "do not disturb", "is it", "whatever", "Howard's birthday", "porque sí", "quemado",
        "the question of what", "", "   ", "en casa", "a la playa", "para Lucía", "de",
    ])
    func notQuestions(_ query: String) {
        #expect(!AnswerTrigger.isQuestion(query))
        #expect(!AnswerTrigger.questions.fires(for: query))
    }

    @Test func everySearchFiresOnAnyTextAndAskNever() {
        #expect(AnswerTrigger.everySearch.fires(for: "Chatham title"))
        #expect(!AnswerTrigger.everySearch.fires(for: "  "))
        #expect(!AnswerTrigger.ask.fires(for: "What's my title?"))
        #expect(AnswerTrigger.questions.pause == .milliseconds(600) && AnswerTrigger.everySearch.pause == .seconds(1))
    }

    @Test func statusDecodesTheTriggerAndToleratesOlderAndNewerMacs() throws {
        let decoder = JSONDecoder()
        let older = try decoder.decode(SearchAnswersStatus.self, from: Data(#"{"engine":"Claude","locality":"cloud"}"#.utf8))
        #expect(older == SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .ask, maxIDs: 8))
        let newer = try decoder.decode(SearchAnswersStatus.self, from: Data(#"{"engine":"Claude","locality":"cloud","trigger":"whenever"}"#.utf8))
        #expect(newer.trigger == .ask)
        let status = SearchAnswersStatus(engine: "GPT-6-Luna (Codex)", locality: .cloud, trigger: .everySearch)
        #expect(try decoder.decode(SearchAnswersStatus.self, from: JSONEncoder().encode(status)) == status)
        let json = try #require(String(data: JSONEncoder().encode(status), encoding: .utf8))
        #expect(json.contains(#""trigger":"everySearch""#) && json.contains(#""maxIds":10"#))
    }
}
