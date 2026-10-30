import Foundation
import FunesProtocol
import GRDB
import NaturalLanguage

/// A result's snippet: the text, and the matches inside it as UTF-16 `[start, length]` pairs
/// (memory processing §10.2, `snippetMatches` in `memories.search`).
public struct Snippet: Sendable, Hashable {
    public let text: String
    public let matches: [[Int]]

    public init(text: String, matches: [[Int]] = []) {
        self.text = text
        self.matches = matches
    }
}

/// Where a body matches a search (memory processing §10.1, FR-V-17): the spans FTS5's
/// `highlight()` marks with search's own MATCH query, so they agree with keyword search (porter
/// stems, diacritics removed, the last word as a prefix). The body's sentences scored by spans,
/// and the snippet built from the best one (§10.2). No model.
public struct BodyMatches: Sendable, Hashable {
    public let body: String
    /// The marked spans as UTF-16 offset ranges into `body`, in order.
    public let spans: [Range<Int>]

    public init(body: String, spans: [Range<Int>]) {
        self.body = body
        self.spans = spans
    }

    /// A sentence longer than this is cut into pieces at word boundaries.
    public static let pieceLength = 300
    /// `memories.search`'s snippet length.
    public static let snippetLength = 160

    // MARK: Finding

    static let open: Character = "\u{2}"
    static let close: Character = "\u{3}"

    /// One `highlight()` query for the given memories with the MATCH query search built for
    /// `query` (`KeywordSearch.ftsQuery`, with its prefix setting). Memories the query doesn't
    /// match, or matches only in the title, get no spans; an empty search finds nothing.
    static func find(_ db: Database, ids: [UUID], query: String, prefix: Bool) throws -> [UUID: BodyMatches] {
        guard !ids.isEmpty, let match = KeywordSearch.ftsQuery(query, prefix: prefix) else { return [:] }
        var result: [UUID: BodyMatches] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT memory.id AS id, memory.body AS body, highlight(memory_fts, 1, char(2), char(3)) AS marked
            FROM memory_fts JOIN memory ON memory.seq = memory_fts.rowid
            WHERE memory_fts MATCH ? AND memory.id IN (\(databaseQuestionMarks(count: ids.count)))
            """, arguments: StatementArguments([match] + ids.map(\.db))) {
            guard let id = row.uuid("id"), let marked: String = row["marked"], let body: String = row["body"],
                  let found = parse(marked, body: body), !found.spans.isEmpty else { continue }
            result[id] = found
        }
        return result
    }

    /// The body and its spans from `highlight()`'s output; nil when the markers don't give back
    /// the body exactly (a body that holds the marker characters itself).
    static func parse(_ marked: String, body: String) -> BodyMatches? {
        var plain = ""
        plain.reserveCapacity(marked.utf8.count)
        var spans: [Range<Int>] = []
        var offset = 0, start: Int?
        for scalar in marked.unicodeScalars {
            switch scalar {
            case "\u{2}":
                start = offset
            case "\u{3}":
                if let s = start, s < offset { spans.append(s..<offset) }
                start = nil
            default:
                plain.unicodeScalars.append(scalar)
                offset += UTF16.width(scalar)
            }
        }
        guard plain == body else { return nil }
        return BodyMatches(body: body, spans: spans)
    }

    // MARK: Sentences

    /// One sentence (or piece) of a text, with the number of match spans that start in it.
    public struct Sentence: Sendable, Hashable {
        public let range: Range<String.Index>
        public let score: Int
        public let firstMatch: Range<String.Index>?
    }

    /// The body's sentences, in order: split at line breaks, then by `NLTokenizer`, without
    /// surrounding whitespace.
    public func sentences() -> [Sentence] {
        Self.sentences(in: body, lines: body.split(whereSeparator: \.isNewline).map { $0.startIndex..<$0.endIndex },
                       spans: Self.indices(spans, in: body))
    }

    /// The best sentence (most spans, the earlier on a tie), with one sentence either side when
    /// `context` is set; nil without spans.
    public func best(context: Bool = false) -> Range<String.Index>? {
        let all = sentences()
        guard let i = Self.bestIndex(all) else { return nil }
        guard context else { return all[i].range }
        return all[max(i - 1, 0)].range.lowerBound..<all[min(i + 1, all.count - 1)].range.upperBound
    }

    // MARK: Snippets

    /// The snippet (§10.2): the best sentence trimmed to `length` around its first match, with "…"
    /// where text was cut, and the spans inside it. Without spans, or for a short body, the
    /// body's start. Newlines become spaces, so the text (without its "…") is always a verbatim
    /// slice of the body with its lines joined by spaces, at most `length` characters.
    public func snippet(length: Int = snippetLength) -> Snippet {
        let (flat, lines, map) = Self.flatten(body)
        guard Self.longer(flat[...], than: length) else {
            return Snippet(text: flat, matches: spans.map { map($0) }.map { [$0.lowerBound, $0.count] })
        }
        let flatSpans = Self.indices(spans.map(map), in: flat)
        let all = Self.sentences(in: flat, lines: lines, spans: flatSpans, matchingLinesOnly: true)
        guard let i = Self.bestIndex(all), let first = all[i].firstMatch else { return Self.start(of: flat, length: length) }
        let (start, end) = Self.trim(flat, sentence: all[i].range, match: first, length: length)
        let lead = start > flat.startIndex, tail = end < flat.endIndex
        let text = (lead ? "…" : "") + flat[start..<end] + (tail ? "…" : "")
        let base = flat.utf16.distance(from: flat.startIndex, to: start) - (lead ? 1 : 0)
        let matches = flatSpans.filter { $0.lowerBound >= start && $0.upperBound <= end }.map { span in
            [flat.utf16.distance(from: flat.startIndex, to: span.lowerBound) - base, flat.utf16.distance(from: span.lowerBound, to: span.upperBound)]
        }
        return Snippet(text: text, matches: matches)
    }

    /// The body's start, newlines flattened: the snippet without a search or a match.
    public static func plainSnippet(_ body: String, length: Int = snippetLength) -> Snippet {
        start(of: flatten(body).0, length: length)
    }

    // MARK: Answer passages

    /// The text an answer sends for a memory (§10.3): the whole body when it's at most `limit`
    /// characters; otherwise the 3 best sentences, each with a sentence either side, merged where
    /// they touch, in body order, joined with " … ", within `limit`. A body without spans gives its
    /// start, cut at a word.
    public func answerText(limit: Int) -> String {
        Self.answerText(body: body, spans: spans, limit: limit)
    }

    /// The separator between passages; a quote that spans it fails validation (§10.4).
    public static let passageJoin = " … "

    public static func answerText(body: String, spans: [Range<Int>], limit: Int) -> String {
        guard longer(body[...], than: limit) else { return body }
        let all = sentences(in: body, lines: body.split(whereSeparator: \.isNewline).map { $0.startIndex..<$0.endIndex },
                            spans: indices(spans, in: body))
        let ranked = all.indices.filter { all[$0].score > 0 }.sorted { (all[$0].score, $1) > (all[$1].score, $0) }
        guard let first = ranked.first else { return cut(body[...], to: limit) }
        var chosen = Set<Int>()
        var text = ""
        for i in ranked.prefix(3) {
            let window = chosen.union(max(i - 1, 0)...min(i + 1, all.count - 1))
            let joined = join(window, all, in: body)
            guard joined.count <= limit else { continue }
            chosen = window
            text = joined
        }
        return text.isEmpty ? cut(body[all[first].range], to: limit) : text
    }

    /// The chosen sentences in body order; runs of neighbours keep the body's text between them.
    static func join(_ chosen: Set<Int>, _ all: [Sentence], in body: String) -> String {
        var runs: [Range<String.Index>] = []
        for i in chosen.sorted() {
            if let last = runs.last, chosen.contains(i - 1) {
                runs[runs.count - 1] = last.lowerBound..<all[i].range.upperBound
            } else {
                runs.append(all[i].range)
            }
        }
        return runs.map { String(body[$0]) }.joined(separator: passageJoin)
    }

    /// The text's start, at most `limit` characters, cut after a word.
    static func cut(_ text: Substring, to limit: Int) -> String {
        guard longer(text, than: limit) else { return String(text) }
        var end = text.index(text.startIndex, offsetBy: limit)
        while end > text.startIndex, !text[end].isWhitespace { end = text.index(before: end) }
        if end == text.startIndex { end = text.index(text.startIndex, offsetBy: limit) }
        return String(text[text.startIndex..<end]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Internals

    static func start(of flat: String, length: Int) -> Snippet {
        Snippet(text: longer(flat[...], than: length) ? String(flat.prefix(length - 1)) + "…" : flat)
    }

    static func bestIndex(_ sentences: [Sentence]) -> Int? {
        var best: Int?
        for (i, s) in sentences.enumerated() where s.score > (best.map { sentences[$0].score } ?? 0) { best = i }
        return best
    }

    static func indices(_ spans: [Range<Int>], in text: String) -> [Range<String.Index>] {
        let utf16 = text.utf16
        return spans.compactMap { span in
            guard span.upperBound <= utf16.count else { return nil }
            let lower = utf16.index(utf16.startIndex, offsetBy: span.lowerBound)
            return lower..<utf16.index(lower, offsetBy: span.count)
        }
    }

    /// The body's lines joined by single spaces, each line's range in the result, and the map
    /// from a UTF-16 range in the body to the same text's range in the result.
    static func flatten(_ body: String) -> (String, [Range<String.Index>], (Range<Int>) -> Range<Int>) {
        let newlines: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]  // Character.isNewline's
        if !body.isEmpty, !body.unicodeScalars.contains(where: { newlines.contains($0.value) }) {
            return (body, [body.startIndex..<body.endIndex], { $0 })
        }
        var flat = ""
        var offsets: [(utf8: Range<Int>, body16: Int, flat16: Int)] = []
        var flat16 = 0, body16 = 0
        var previous = body.startIndex
        for line in body.split(whereSeparator: \.isNewline) {
            if !flat.isEmpty {
                flat += " "
                flat16 += 1
            }
            body16 += body.utf16.distance(from: previous, to: line.startIndex)
            previous = line.startIndex
            let start = flat.utf8.count
            flat += line
            offsets.append((start..<flat.utf8.count, body16, flat16))
            flat16 += line.utf16.count
        }
        let utf8 = flat.utf8
        let lines = offsets.map { utf8.index(utf8.startIndex, offsetBy: $0.utf8.lowerBound)..<utf8.index(utf8.startIndex, offsetBy: $0.utf8.upperBound) }
        let map: (Range<Int>) -> Range<Int> = { span in
            let line = offsets.last { $0.body16 <= span.lowerBound } ?? offsets[0]
            let shift = line.flat16 - line.body16
            return (span.lowerBound + shift)..<(span.upperBound + shift)
        }
        return (flat, lines, map)
    }

    /// With `matchingLinesOnly`, lines without a span are skipped (a snippet needs only the best
    /// sentence, and splitting sentences is most of the cost).
    static func sentences(in text: String, lines: [Range<String.Index>], spans: [Range<String.Index>],
                          matchingLinesOnly: Bool = false) -> [Sentence] {
        var result: [Sentence] = []
        var next = 0, s = 0
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        for line in lines {
            if matchingLinesOnly {
                while next < spans.count, spans[next].lowerBound < line.lowerBound { next += 1 }
                guard next < spans.count, spans[next].lowerBound < line.upperBound else { continue }
            }
            var pieces: [Range<String.Index>] = []
            // The tokenizer returns whole sentences that touch the line; on flattened text one can
            // run across the line's end, so each is cut back to the line.
            tokenizer.enumerateTokens(in: line) { range, _ in
                pieces.append(contentsOf: Self.pieces(of: trimmed(range.clamped(to: line), in: text), in: text))
                return true
            }
            for sentence in pieces where !sentence.isEmpty {
                while s < spans.count, spans[s].lowerBound < sentence.lowerBound { s += 1 }
                var k = s
                while k < spans.count, spans[k].lowerBound < sentence.upperBound { k += 1 }
                result.append(Sentence(range: sentence, score: k - s, firstMatch: k > s ? spans[s] : nil))
                s = k
            }
        }
        return result
    }

    static func trimmed(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var lower = range.lowerBound, upper = range.upperBound
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        while upper > lower, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
        return lower..<upper
    }

    /// A sentence longer than `pieceLength` cut into pieces at its last space before each limit.
    static func pieces(of range: Range<String.Index>, in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var lower = range.lowerBound
        while let limit = text.index(lower, offsetBy: pieceLength, limitedBy: range.upperBound), limit < range.upperBound {
            var cut = limit
            while cut > lower, !text[cut].isWhitespace { cut = text.index(before: cut) }
            if cut == lower { cut = limit }
            result.append(trimmed(lower..<cut, in: text))
            lower = cut
            while lower < range.upperBound, text[lower].isWhitespace { lower = text.index(after: lower) }
        }
        if lower < range.upperBound { result.append(lower..<range.upperBound) }
        return result
    }

    /// Characters of context kept before a match that's too far into its sentence.
    static let lead = 30

    /// The slice of `text` to show: from the sentence's start, or shortly before a match too far
    /// into it, to at most `length` characters with room for the "…".
    static func trim(_ text: String, sentence: Range<String.Index>, match: Range<String.Index>,
                     length: Int) -> (String.Index, String.Index) {
        var start = sentence.lowerBound
        if longer(text[start..<match.upperBound], than: length - 2) {
            start = text.index(match.lowerBound, offsetBy: -lead, limitedBy: sentence.lowerBound) ?? sentence.lowerBound
            start = wordStart(text, from: start, notPast: match.lowerBound)
        }
        // Near the end of the body: start earlier, back to the sentence's start at most, so the
        // snippet uses its length.
        if start > sentence.lowerBound, !longer(text[start...], than: length - 2) {
            start = max(text.index(text.endIndex, offsetBy: -(length - 1)), sentence.lowerBound)
            start = wordStart(text, from: start, notPast: match.lowerBound)
        }
        let room = length - (start > text.startIndex ? 1 : 0)
        guard longer(text[start...], than: room) else { return (start, text.endIndex) }
        var end = text.index(start, offsetBy: room - 1)
        var cut = end
        while cut > match.upperBound, !text[cut].isWhitespace { cut = text.index(before: cut) }
        if cut > match.upperBound { end = cut }
        while end > start, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return (start, end)
    }

    /// Whether `text` has more than `count` characters, counting at most `count + 1`.
    static func longer(_ text: Substring, than count: Int) -> Bool {
        text.index(text.startIndex, offsetBy: count, limitedBy: text.endIndex).map { $0 < text.endIndex } ?? false
    }

    /// `index` when a word starts there, else the start of the next word, never past `limit`.
    static func wordStart(_ text: String, from index: String.Index, notPast limit: String.Index) -> String.Index {
        guard index > text.startIndex, index < limit else { return min(index, limit) }
        var i = index
        if !text[text.index(before: i)].isWhitespace {
            while i < limit, !text[i].isWhitespace { i = text.index(after: i) }
        }
        while i < limit, text[i].isWhitespace { i = text.index(after: i) }
        return i
    }
}
