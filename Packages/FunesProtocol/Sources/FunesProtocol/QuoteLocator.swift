import Foundation

/// Finds a model's quote in a memory's text (memory processing §10.4–10.5): both sides compared
/// after normalizing (Unicode NFC, whitespace runs to one space, curly quotes and apostrophes to
/// straight ones, case kept), and a match mapped back to a range of the original text. Shared by
/// the Mac's validation and both apps' highlighting of a quoted sentence, so no offsets travel.
public enum QuoteLocator {
    /// The normalized form of `text`, without leading or trailing whitespace.
    public static func normalize(_ text: String) -> String {
        String(Normalized(text).characters).trimmingCharacters(in: .whitespaces)
    }

    /// The range of the first occurrence of `quote` in `text`, after normalizing both; nil when it
    /// isn't there or the quote is empty.
    public static func range(of quote: String, in text: String) -> Range<String.Index>? {
        let needle = normalize(quote)
        guard !needle.isEmpty else { return nil }
        let haystack = Normalized(text)
        let joined = String(haystack.characters)
        guard let found = joined.range(of: needle, options: [.literal]) else { return nil }
        let start = joined.distance(from: joined.startIndex, to: found.lowerBound)
        let count = joined.distance(from: found.lowerBound, to: found.upperBound)
        return haystack.origins[start].lowerBound..<haystack.origins[start + count - 1].upperBound
    }

    /// Whether `quote` appears in `text`.
    public static func contains(_ quote: String, in text: String) -> Bool { range(of: quote, in: text) != nil }

    /// The text normalized character by character, with each normalized character's range in
    /// the original (a whitespace run's single space covers the whole run).
    struct Normalized {
        var characters: [Character] = []
        var origins: [Range<String.Index>] = []

        init(_ text: String) {
            var i = text.startIndex
            while i < text.endIndex {
                let c = text[i]
                let next = text.index(after: i)
                if c.isWhitespace {
                    if characters.last == " ", let last = origins.last {
                        origins[origins.count - 1] = last.lowerBound..<next
                    } else {
                        characters.append(" ")
                        origins.append(i..<next)
                    }
                } else {
                    characters.append(Self.straight(c))
                    origins.append(i..<next)
                }
                i = next
            }
        }

        static func straight(_ c: Character) -> Character {
            switch c {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}": return "'"
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}": return "\""
            default: return Character(String(c).precomposedStringWithCanonicalMapping)
            }
        }
    }
}
