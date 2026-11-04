import Foundation
import Testing
@testable import FunesProtocol

/// The apps' bold for `snippetMatches` (FR-V-17).
@Suite struct SnippetHighlightTests {
    static func strong(_ attributed: AttributedString) -> [String] {
        attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(attributed[$0.range].characters) }
    }

    @Test func boldsTheMatchesAndKeepsTheText() {
        let text = "…my title at Chatham is Senior Analyst…"
        let attributed = SnippetHighlight.attributed(text, matches: [[4, 5], [13, 7]])
        #expect(String(attributed.characters) == text)
        #expect(Self.strong(attributed) == ["title", "Chatham"])
    }

    @Test func utf16OffsetsAndBadPairs() {
        let text = "😀 café and tea"
        #expect(Self.strong(SnippetHighlight.attributed(text, matches: [[3, 4], [12, 3]])) == ["café", "tea"])
        #expect(Self.strong(SnippetHighlight.attributed(text, matches: [[-1, 2], [12, 9], [1], [3, 0]])).isEmpty)
        #expect(Self.strong(SnippetHighlight.attributed(text, matches: nil)).isEmpty)
        // A pair splitting the emoji's surrogates, or at the integer limits, is ignored.
        #expect(Self.strong(SnippetHighlight.attributed(text, matches: [[1, 1]])).isEmpty)
        #expect(Self.strong(SnippetHighlight.attributed(text, matches: [[Int.max, 1], [1, Int.max], [Int.max, Int.max]])).isEmpty)
    }

    @Test func snippetMatchesIsOptionalOnTheWire() throws {
        let summary = MemorySummary(id: UUID(), title: "T", snippet: "s", kind: .fact, categories: [], sensitivity: .low, updatedAt: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        #expect(!json.contains("snippetMatches"))
        var marked = summary
        marked.snippetMatches = [[0, 1]]
        let decoded = try JSONDecoder().decode(MemorySummary.self, from: JSONEncoder().encode(marked))
        #expect(decoded.snippetMatches == [[0, 1]])
        // An older Mac's result, without the field.
        let older = try JSONDecoder().decode(MemorySummary.self, from: Data(json.utf8))
        #expect(older.snippetMatches == nil && older.snippet == "s")
    }
}
