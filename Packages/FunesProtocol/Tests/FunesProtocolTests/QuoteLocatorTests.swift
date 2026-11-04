import Foundation
import Testing
@testable import FunesProtocol

/// Finding a quote in a memory's text (memory processing §10.4–10.5).
@Suite struct QuoteLocatorTests {
    static func found(_ quote: String, in text: String) -> String? {
        QuoteLocator.range(of: quote, in: text).map { String(text[$0]) }
    }

    @Test func exactAndNormalizedMatchesMapBackToTheOriginal() {
        let text = "My title at Chatham is Senior Analyst.\nI joined in 2023."
        #expect(Self.found("title at Chatham", in: text) == "title at Chatham")
        // Whitespace runs and line breaks are one space; the range covers the original run.
        #expect(Self.found("Analyst. I joined", in: text) == "Analyst.\nI joined")
        #expect(Self.found("  Senior   Analyst  ", in: "a Senior \t Analyst b") == "Senior \t Analyst")
        // Case is kept.
        #expect(Self.found("senior analyst", in: text) == nil)
    }

    @Test func curlyQuotesAndApostrophes() {
        let text = "She said \u{201C}don\u{2019}t book Friday\u{201D}."
        #expect(Self.found("said \"don't book Friday\"", in: text) == "said \u{201C}don\u{2019}t book Friday\u{201D}")
        #expect(Self.found("We\u{2019}ll go", in: "We'll go soon") == "We'll go")
    }

    @Test func composedAndDecomposedAccents() {
        let decomposed = "Prefiero el cafe\u{301} de la esquina."
        #expect(Self.found("el café de", in: decomposed) == "el cafe\u{301} de")
        #expect(Self.found("el cafe\u{301} de", in: "Prefiero el café de la esquina.") == "el café de")
    }

    @Test func emojiAndRepeatedQuotes() {
        let text = "Party 🎉 at 18:00. Then again: party 🎉 at 18:00."
        let range = QuoteLocator.range(of: "🎉 at 18:00", in: text)
        // The first occurrence.
        #expect(range.map { text.distance(from: text.startIndex, to: $0.lowerBound) } == 6)
        #expect(Self.found("Party 🎉 at", in: text) == "Party 🎉 at")
    }

    @Test func emptyAndMissingQuotes() {
        #expect(QuoteLocator.range(of: "", in: "anything") == nil)
        #expect(QuoteLocator.range(of: "   ", in: "anything") == nil)
        #expect(QuoteLocator.range(of: "nothing like it", in: "anything") == nil)
        #expect(QuoteLocator.normalize("  a \u{2019}b\u{2019}\n\nc  ") == "a 'b' c")
    }
}
