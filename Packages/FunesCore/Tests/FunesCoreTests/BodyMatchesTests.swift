import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Where a body matches and the snippets built from it (FR-V-17, memory processing §10.1–10.2).
@Suite struct BodyMatchesTests {
    /// The body's matches for `query`, through one memory in a fresh vault.
    static func matches(_ body: String, _ query: String, title: String = "Note", prefix: Bool = true) throws -> BodyMatches? {
        let v = try TestVault()
        let m = try v.memory(title, body)
        return try v.store.writer.read { db in try BodyMatches.find(db, ids: [m.id], query: query, prefix: prefix)[m.id] }
    }

    static func marked(_ m: BodyMatches?) -> [String] {
        guard let m else { return [] }
        return BodyMatches.indices(m.spans, in: m.body).map { String(m.body[$0]) }
    }

    /// The snippet's text without its "…" is a slice of the body with lines joined, never over the
    /// length, and every match range lies inside it.
    static func expectWellFormed(_ snippet: Snippet, of body: String, length: Int = 160,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let flat = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        var core = Substring(snippet.text)
        if core.hasPrefix("…") { core = core.dropFirst() }
        if core.hasSuffix("…") { core = core.dropLast() }
        #expect(snippet.text.count <= length, "\(snippet.text.count) characters", sourceLocation: sourceLocation)
        #expect(!core.isEmpty && flat.contains(core), "not a slice: \(snippet.text)", sourceLocation: sourceLocation)
        #expect(snippet.text.hasPrefix("…") == !flat.hasPrefix(core), sourceLocation: sourceLocation)
        #expect(snippet.text.hasSuffix("…") == !flat.hasSuffix(core), sourceLocation: sourceLocation)
        let utf16 = snippet.text.utf16.count
        for pair in snippet.matches {
            #expect(pair.count == 2 && pair[0] >= 0 && pair[1] > 0 && pair[0] + pair[1] <= utf16, "\(pair)", sourceLocation: sourceLocation)
        }
    }

    /// The marked words of a snippet.
    static func words(_ snippet: Snippet) -> [String] {
        let utf16 = Array(snippet.text.utf16)
        return snippet.matches.map { String(decoding: utf16[$0[0]..<($0[0] + $0[1])], as: UTF16.self) }
    }

    @Test func spansFollowKeywordSearchsStemsAccentsAndPrefix() throws {
        // Porter: "titles" finds "title" and "titled".
        #expect(Self.marked(try Self.matches("My title changed; I was titled Analyst.", "titles", prefix: false)) == ["title", "titled"])
        // Diacritics removed both ways.
        #expect(Self.marked(try Self.matches("Prefiero el café de la esquina.", "cafe")) == ["café"])
        #expect(Self.marked(try Self.matches("Cafe con leche.", "café")) == ["Cafe"])
        // The last word as a prefix, as vault search types it; not without the prefix setting.
        #expect(Self.marked(try Self.matches("Senior Analyst at Chatham.", "chath")) == ["Chatham"])
        #expect(try Self.matches("Senior Analyst at Chatham.", "chath", prefix: false) == nil)
        // Stopwords aren't searched, so they aren't marked.
        #expect(Self.marked(try Self.matches("My title at Chatham.", "what's my title at Chatham?")) == ["title", "Chatham"])
    }

    @Test func titleOnlyAndNoMatchGiveNoSpans() throws {
        #expect(try Self.matches("Flat white, no sugar.", "coffee", title: "Coffee order") == nil)
        #expect(try Self.matches("Flat white, no sugar.", "juice") == nil)
        #expect(try Self.matches("Flat white, no sugar.", "") == nil)
        #expect(try Self.matches("Flat white, no sugar.", "the of") == nil)
    }

    @Test func markerCharactersInABodyGiveNoSpans() {
        #expect(BodyMatches.parse("a \u{2}b\u{3} c", body: "a b c")?.spans == [2..<3])
        #expect(BodyMatches.parse("a \u{2}b\u{3} \u{2}c", body: "a b \u{2}c") == nil)
        // UTF-16 offsets: an emoji before the match counts two.
        #expect(BodyMatches.parse("😀 \u{2}tea\u{3}", body: "😀 tea")?.spans == [3..<6])
    }

    @Test func sentencesAreScoredBySpansAndTiesGoEarlier() throws {
        let body = "Coffee in the morning. Tea in the afternoon, tea after dinner. Coffee after lunch.\nTea"
        let m = try #require(try Self.matches(body, "tea", prefix: false))
        #expect(m.sentences().map(\.score) == [0, 2, 0, 1])
        #expect(m.best().map { String(body[$0]) } == "Tea in the afternoon, tea after dinner.")
        #expect(m.best(context: true).map { String(body[$0]) } == "Coffee in the morning. Tea in the afternoon, tea after dinner. Coffee after lunch.")
        let tie = try #require(try Self.matches(body, "coffee", prefix: false))
        #expect(tie.best().map { String(body[$0]) } == "Coffee in the morning.")
        let split = "First line without a stop\nSecond sentence here. Third one!\n\n  Fourth.  "
        #expect(BodyMatches(body: split, spans: []).sentences().map { String(split[$0.range]) }
            == ["First line without a stop", "Second sentence here.", "Third one!", "Fourth."])
    }

    @Test func aLongSingleSentenceIsCutIntoPieces() throws {
        let body = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let m = try #require(try Self.matches(body, "word150", prefix: false))
        let pieces = m.sentences()
        #expect(pieces.count > 1 && pieces.allSatisfy { body.distance(from: $0.range.lowerBound, to: $0.range.upperBound) <= 300 })
        #expect(pieces.map { String(body[$0.range]) }.joined(separator: " ") == body)
        let snippet = m.snippet()
        #expect(Self.words(snippet) == ["word150"])
        Self.expectWellFormed(snippet, of: body)
    }

    @Test func aMatchInTheLastSentenceOfALongBody() throws {
        let body = String(repeating: "Nothing much happened on this ordinary day at the office. ", count: 171)
            + "My title at Chatham is Senior Analyst."
        #expect(body.count > 9_900 && body.count <= 10_000)
        let m = try #require(try Self.matches(body, "What's my title at Chatham?"))
        let snippet = m.snippet()
        #expect(snippet.text.hasPrefix("…") && snippet.text.hasSuffix("My title at Chatham is Senior Analyst."))
        #expect(Self.words(snippet) == ["title", "Chatham"])
        Self.expectWellFormed(snippet, of: body)
        #expect(BodyMatches.plainSnippet(body).text == String(body.prefix(159)) + "…")
    }

    @Test func snippetTrimsAroundTheFirstMatchAtWordBoundaries() throws {
        let body = "Background: " + String(repeating: "the team met several times to talk about plans ", count: 6)
            + "and then decided that the deadline for the Lisbon trip is March 3, with flights booked. More notes, "
            + String(repeating: "and then some more. ", count: 8)
        let snippet = try #require(try Self.matches(body, "Lisbon deadline")).snippet()
        #expect(snippet.text.hasPrefix("…") && snippet.text.hasSuffix("…"))
        #expect(snippet.text.contains("deadline for the Lisbon trip"))
        #expect(Self.words(snippet) == ["deadline", "Lisbon"])
        Self.expectWellFormed(snippet, of: body)
        let core = snippet.text.dropFirst().dropLast()
        let start = body.range(of: core)!.lowerBound
        #expect(body[body.index(before: start)] == " ")
    }

    @Test func aShortSentenceExtendsIntoTheNextOne() throws {
        let body = String(repeating: "Unrelated text about many other things. ", count: 5)
            + "Allergic to nuts. Carries an EpiPen everywhere, including on flights and at restaurants, and tells waiters."
        let snippet = try #require(try Self.matches(body, "nuts allergy")).snippet()
        #expect(snippet.text == "…Allergic to nuts. Carries an EpiPen everywhere, including on flights and at restaurants, and tells waiters.")
        #expect(Self.words(snippet) == ["nuts"])
        Self.expectWellFormed(snippet, of: body)
    }

    @Test func shortBodiesAndNewlinesKeepTheirMatches() throws {
        let short = try #require(try Self.matches("Short body\nwith lines\r\nand more lines", "lines", prefix: false)).snippet()
        #expect(short.text == "Short body with lines and more lines")
        #expect(Self.words(short) == ["lines", "lines"])
        let body = "Line one\n\n" + String(repeating: "x ", count: 100) + "\nTarget sentence is here."
        let snippet = try #require(try Self.matches(body, "target")).snippet()
        #expect(snippet.text.hasSuffix("Target sentence is here.") && snippet.text.hasPrefix("…"))
        #expect(Self.words(snippet) == ["Target"])
        Self.expectWellFormed(snippet, of: body)
    }

    @Test func spanishAndAccentedText() throws {
        let body = String(repeating: "Texto de relleno sin nada importante para la búsqueda. ", count: 4)
            + "Mi cargo en Chatham es Analista Sénior desde enero. Otra frase después."
        let snippet = try #require(try Self.matches(body, "¿Cuál es mi cargo en Chatham?")).snippet()
        #expect(snippet.text.contains("Mi cargo en Chatham es Analista Sénior"))
        #expect(Self.words(snippet).contains("Chatham") && Self.words(snippet).contains("cargo"))
        Self.expectWellFormed(snippet, of: body)
    }

    /// Lines are sentence boundaries in the snippet too (the tokenizer's sentences are cut back to
    /// their line), and dense lines stay cheap.
    @Test func linesBoundSentencesInSnippets() throws {
        let body = "Tea tea\nCoffee coffee coffee\n" + String(repeating: "ordinary filler ", count: 20)
        let snippet = try #require(try Self.matches(body, "tea coffee", prefix: false)).snippet()
        #expect(snippet.text.hasPrefix("…Coffee coffee coffee"))
        #expect(Self.words(snippet) == ["Coffee", "coffee", "coffee"])
        let dense = String(repeating: "tea\n", count: 2_499)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let m = try #require(try Self.matches(dense, "tea", prefix: false))
            #expect(m.sentences().count == 2_499)
            // (The body repeats itself, so expectWellFormed's ends check doesn't apply.)
            let snippet = m.snippet()
            #expect(snippet.text.count <= 160 && snippet.text.hasPrefix("tea tea") && snippet.matches.first == [0, 3])
        }
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test func everyNewlineKindIsFlattened() throws {
        for newline in ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            let body = "First line" + newline + String(repeating: "padding words here ", count: 9) + newline + "the target is here."
            let snippet = try #require(try Self.matches(body, "target", prefix: false), "\(newline.unicodeScalars.map(\.value))").snippet()
            let flattened = !snippet.text.contains(where: \.isNewline)
            #expect(flattened)
            #expect(Self.words(snippet) == ["target"])
            Self.expectWellFormed(snippet, of: body)
        }
    }

    @Test func decomposedAccentsAndEmojiKeepOffsets() throws {
        let decomposed = "Prefiero el cafe\u{301} de la esquina, " + String(repeating: "sin prisa y sin pausa, ", count: 7) + "y el cafe\u{301} con leche."
        let a = try #require(try Self.matches(decomposed, "cafe")).snippet()
        #expect(Self.words(a).allSatisfy { $0.precomposedStringWithCanonicalMapping == "café" } && !a.matches.isEmpty)
        Self.expectWellFormed(a, of: decomposed)
        let emoji = String(repeating: "🎉🎈 party plans and more ", count: 8) + "The venue is the Harbor Hall 🎉."
        let b = try #require(try Self.matches(emoji, "venue harbor")).snippet()
        #expect(Self.words(b) == ["venue", "Harbor"])
        Self.expectWellFormed(b, of: emoji)
    }

    @Test func lengthBoundaries() throws {
        let exact = String(repeating: "a", count: 150) + " the tea."
        #expect(exact.count == 159)
        for body in [exact, exact + "x", exact + "xy"] {
            let snippet = try #require(try Self.matches(body, "tea", prefix: false)).snippet()
            Self.expectWellFormed(snippet, of: body)
            #expect(Self.words(snippet) == ["tea"])
        }
        #expect(BodyMatches.plainSnippet(String(repeating: "b", count: 160)).text.count == 160)
        #expect(BodyMatches.plainSnippet(String(repeating: "b", count: 161)).text == String(repeating: "b", count: 159) + "…")
        #expect(BodyMatches(body: "\n\n", spans: []).snippet().text == "")
        #expect(BodyMatches(body: "", spans: []).sentences().isEmpty)
    }

    /// The text an answer sends (memory processing §10.3).
    @Test func answerTextIsTheBodyOrItsBestPassages() throws {
        let short = "My title at Chatham is Senior Analyst."
        #expect(try #require(try Self.matches(short, "title")).answerText(limit: 1_500) == short)

        let filler = (0..<40).map { "Filler sentence number \($0) about nothing much." }
        var sentences = filler
        sentences[10] = "Joined Chatham in 2023 as a data analyst."
        sentences[30] = "Promoted in March: my title at Chatham is Senior Analyst."
        let body = sentences.joined(separator: " ")
        let m = try #require(try Self.matches(body, "title at Chatham"))
        let text = m.answerText(limit: 1_500)
        // The best sentences with one either side, in body order, joined.
        #expect(text == [sentences[9...11], sentences[29...31]].map { $0.joined(separator: " ") }.joined(separator: " … "))
        // Neighbouring passages merge into one run.
        sentences[12] = "Still at Chatham today."
        let merged = try #require(try Self.matches(sentences.joined(separator: " "), "Chatham", prefix: false)).answerText(limit: 1_500)
        #expect(merged.hasPrefix(sentences[9...13].joined(separator: " ")) && merged.components(separatedBy: " … ").count == 2)
        // Within the limit: a passage that doesn't fit is left out, and the best is cut if it must be.
        #expect(m.answerText(limit: 200).count <= 200 && m.answerText(limit: 200).contains("Senior Analyst"))
        #expect(m.answerText(limit: 30).count <= 30)
        // No spans: the start, cut at a word.
        let start = BodyMatches.answerText(body: body, spans: [], limit: 100)
        #expect(start.count <= 100 && body.hasPrefix(start) && body[body.index(body.startIndex, offsetBy: start.count)] == " ")
    }

    /// Every fixture memory, lengthened, against every benchmark query: well formed at three lengths.
    @Test func snippetsAreAlwaysVerbatimAndShortEnough() async throws {
        let v = try TestVault()
        let memories = try Fixtures.memories()
        var ids: [UUID] = []
        for (i, m) in memories.enumerated() {
            let body = m.body + "\n" + memories[(i + 1) % memories.count].body + " " + memories[(i + 7) % memories.count].body
            ids.append(try v.memory(m.title, body).id)
        }
        let search = SearchService(store: v.store, indexer: nil)
        let bodies = Dictionary(uniqueKeysWithValues: try v.store.memories(ids: ids).map { ($0.id, $0.body) })
        var checked = 0
        for q in try Fixtures.queries(expanded: false).map(\.query) {
            for (id, m) in try await search.bodyMatches(q, ids: ids) {
                for length in [40, 80, 160] {
                    Self.expectWellFormed(m.snippet(length: length), of: bodies[id]!, length: length)
                }
                #expect(!m.snippet().matches.isEmpty)
                checked += 1
            }
        }
        #expect(checked > 500)
    }
}
