import Foundation

/// A snippet with its search matches in bold, for a SwiftUI `Text` on the Mac and the iPhone
/// (FR-V-17). The matches are UTF-16 `[start, length]` pairs into the snippet, as the Mac marks them
/// (`snippetMatches`); a pair that doesn't fit is ignored. The characters are unchanged, so
/// VoiceOver reads it as plain text.
public enum SnippetHighlight {
    public static func attributed(_ snippet: String, matches: [[Int]]?) -> AttributedString {
        var attributed = AttributedString(snippet)
        let utf16 = snippet.utf16
        for pair in matches ?? [] {
            guard pair.count == 2, pair[0] >= 0, pair[1] > 0, pair[0] <= utf16.count, pair[1] <= utf16.count - pair[0] else { continue }
            let lower = utf16.index(utf16.startIndex, offsetBy: pair[0])
            let upper = utf16.index(lower, offsetBy: pair[1])
            guard let from = AttributedString.Index(lower, within: attributed),
                  let to = AttributedString.Index(upper, within: attributed), from < to else { continue }
            attributed[from..<to].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
