import Foundation

/// Text helpers for learned facts: folding, regular expressions over NSString ranges, and name normalisation.
enum FactsText {
    /// Case and accents folded, trimmed ("María" → "maria").
    static func fold(_ s: String?) -> String {
        guard let s else { return "" }
        return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    /// A compiled pattern (ICU syntax, so lookbehind works), cached. Patterns come from code and the registry only.
    static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        let key = (caseInsensitive ? "i:" : "c:") + pattern
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let re = cache[key] { return re }
        // swiftlint:disable:next force_try
        let re = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        if cache.count > 4096 { cache.removeAll() }
        cache[key] = re
        return re
    }

    struct Match {
        let range: NSRange
        let groups: [NSRange]
        let source: NSString
        func group(_ i: Int) -> String? {
            let r = i == 0 ? range : groups[i - 1]
            return r.location == NSNotFound ? nil : source.substring(with: r)
        }
        var start: Int { range.location }
        var end: Int { range.location + range.length }
    }

    static func matches(_ re: NSRegularExpression, in s: String, from: Int = 0, to: Int? = nil) -> [Match] {
        let ns = s as NSString
        let end = min(to ?? ns.length, ns.length)
        guard from <= end else { return [] }
        return re.matches(in: s, range: NSRange(location: from, length: end - from)).map { m in
            Match(range: m.range, groups: (1..<max(m.numberOfRanges, 1)).map { m.range(at: $0) }, source: ns)
        }
    }

    static func first(_ re: NSRegularExpression, in s: String, from: Int = 0, to: Int? = nil) -> Match? {
        matches(re, in: s, from: from, to: to).first
    }

    /// A match anchored at `from` (the spike's `re.match` on a suffix).
    static func matchAt(_ re: NSRegularExpression, in s: String, from: Int, to: Int? = nil) -> Match? {
        let ns = s as NSString
        let end = min(to ?? ns.length, ns.length)
        guard from <= end else { return nil }
        guard let m = re.firstMatch(in: s, options: [.anchored], range: NSRange(location: from, length: end - from)) else { return nil }
        return Match(range: m.range, groups: (1..<max(m.numberOfRanges, 1)).map { m.range(at: $0) }, source: ns)
    }

    static func substring(_ s: String, _ from: Int, _ to: Int) -> String {
        let ns = s as NSString
        let a = max(0, min(from, ns.length)), b = max(a, min(to, ns.length))
        return ns.substring(with: NSRange(location: a, length: b - a))
    }

    static func length(_ s: String) -> Int { (s as NSString).length }

    /// Whether a whole word or phrase occurs in already-folded text.
    /// A registry cue: a whole word, or a stem when written with a trailing `*` ("regres*" matches "regresé").
    static func cue(_ folded: String, _ word: String) -> Bool {
        let stem = word.hasSuffix("*")
        let w = fold(stem ? String(word.dropLast()) : word)
        guard !w.isEmpty else { return false }
        return first(regex("(?<!\\w)" + escape(w) + (stem ? "" : "(?!\\w)")), in: folded) != nil
    }

    static func has(_ folded: String, _ word: String) -> Bool {
        let w = fold(word)
        guard !w.isEmpty else { return false }
        return first(regex("(?<!\\w)" + escape(w) + "(?!\\w)"), in: folded) != nil
    }

    private static let trailingPunct = regex("[,.]+$")

    /// A name normalised for matching by its entity kind: folded, and for organizations without a legal suffix.
    static func normName(_ name: String, kind: String, registry: FactsRegistry) -> String {
        var s = fold(name)
        if registry.kinds[kind]?.normalise.contains("legal_suffix") == true {
            let suffixes = registry.language.legalSuffixes.sorted { $0.count > $1.count }.map(escape).joined(separator: "|")
            let legalSuffix = regex("\\b(?:" + suffixes + ")\\.?$", caseInsensitive: true)
            s = trailingPunct.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: length(s)), withTemplate: "")
            s = legalSuffix.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: length(s)), withTemplate: "")
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        }
        return s
    }

    /// The user's own names replaced by the registry's placeholder (memory processing §11.3, §10.3), longest first,
    /// whole words.
    static func userText(_ text: String, aliases: [String], registry: FactsRegistry) -> String {
        var out = text
        let placeholder = NSRegularExpression.escapedTemplate(for: registry.language.userPlaceholder)
        for a in aliases.sorted(by: { $0.count > $1.count }) where !a.isEmpty {
            let re = regex("\\b" + escape(a) + "\\b")
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: length(out)), withTemplate: placeholder)
        }
        return out
    }

    /// UTF-16 starts of a name's whole-word occurrences in a text, case and accents folded.
    static func wholeWordStarts(_ name: String, in text: String) -> [Int] { wholeWordRanges(name, in: text).map(\.location) }

    /// The same occurrences as ranges of the original text (UTF-16).
    static func wholeWordRanges(_ name: String, in text: String) -> [NSRange] {
        let folded = foldedWithMap(text)
        let n = fold(name)
        guard !n.isEmpty else { return [] }
        return matches(regex("(?<![\\w])" + escape(n) + "(?![\\w])"), in: folded.text).map { m in
            // Folded per character, so the next folded offset's original is where the next character starts: the
            // match keeps its last character whole (an accent written apart, a surrogate pair).
            let a = folded.original(m.start)
            return NSRange(location: a, length: folded.original(m.end) - a)
        }
    }
}
