import Foundation

/// When a search is answered (memory processing §10.6, FR-AI-17): only when asked, or on its own
/// after a pause, for searches that are questions or for every search. The Mac's setting; the
/// phone follows what `status.get` says.
public enum AnswerTrigger: String, Codable, Sendable, CaseIterable {
    /// ⌘⏎, Ask Funes, the Ask pill.
    case ask
    /// A search shaped like a question (`isQuestion`), after `pause`.
    case questions
    /// Any search with results, after `pause`.
    case everySearch

    /// Whether `query` is answered without asking.
    public func fires(for query: String) -> Bool {
        switch self {
        case .ask: false
        case .questions: Self.isQuestion(query)
        case .everySearch: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// How long the results stay unchanged before the answer starts: longer for every search,
    /// since a keyword search is more often still being typed.
    public var pause: Duration {
        switch self {
        case .ask, .questions: .milliseconds(600)
        case .everySearch: .seconds(1)
        }
    }

    /// A question: it ends with "?" (or starts with "¿"), or starts with a question word in English
    /// or Spanish ("what", "how", "dónde", "por qué"; accents optional).
    public static func isQuestion(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("?") || text.hasSuffix("？") || text.hasPrefix("¿") { return true }
        let words = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
        guard let first = words.first.map(String.init) else { return false }
        if first == "por", words.count > 1, words[1] == "que" { return true }
        return questionWords.contains(first) || questionWords.contains(first.split(separator: "'").first.map(String.init) ?? "")
    }

    /// The first words of a question, folded (no accents, lowercase). English auxiliaries ("is",
    /// "do") aren't here: "do not disturb" is a search, and a question that starts with one
    /// usually ends with "?".
    static let questionWords: Set<String> = [
        "what", "when", "where", "who", "whom", "whose", "which", "why", "how",
        "que", "cual", "cuales", "cuando", "cuanto", "cuanta", "cuantos", "cuantas", "donde", "adonde",
        "quien", "quienes", "como",
    ]
}
