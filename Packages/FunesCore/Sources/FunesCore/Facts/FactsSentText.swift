import Foundation

/// A memory's text as the Facts call sends it (memory processing §11.3, §11.9): the user's own names replaced by the
/// registry's placeholder, with a map of offsets, so quotes are validated against the text sent and mapped back to the
/// original. Offsets are UTF-16, as `NSString` and the graph use. (A namesake in the same memory keeping its name is the
/// privacy step's profile matcher; until then every whole-word match is replaced, as the spike did.)
public struct FactsSentText: Sendable, Equatable {
    public let original: String
    public let sent: String
    /// Replaced spans, in order: (sent range, original range).
    let replaced: [(sent: NSRange, original: NSRange)]

    public static func == (a: FactsSentText, b: FactsSentText) -> Bool { a.original == b.original && a.sent == b.sent }

    public init(_ text: String, userAliases: [String], registry: FactsRegistry) {
        original = text
        let ns = text as NSString
        var spans: [NSRange] = []
        // As written, or in capitals ("DANI"): not in any case, so a user called Will keeps "I will call".
        let forms = userAliases.flatMap { [$0, $0.uppercased()] }
        for a in Array(Set(forms)).sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }) where !a.isEmpty {
            let re = FactsText.regex("\\b" + FactsText.escape(a) + "\\b")
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where !spans.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                spans.append(m.range)
            }
        }
        spans.sort { $0.location < $1.location }
        let placeholder = registry.language.userPlaceholder
        let pl = FactsText.length(placeholder)
        var out = "", map: [(NSRange, NSRange)] = [], cursor = 0, delta = 0
        for r in spans {
            out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            map.append((NSRange(location: r.location + delta, length: pl), r))
            out += placeholder
            delta += pl - r.length
            cursor = r.location + r.length
        }
        out += ns.substring(from: cursor)
        sent = FactsPrompt.disarm(out)      // one UTF-16 unit for another: the offsets hold
        replaced = map
    }

    /// An offset in the sent text, in the original: inside a placeholder, the start (or end) of the name it replaced.
    func toOriginal(_ k: Int, end: Bool = false) -> Int {
        var delta = 0
        for (s, o) in replaced {
            let sEnd = s.location + s.length
            if end ? k <= s.location : k < s.location { break }
            if end ? k <= sEnd : k < sEnd { return end ? o.location + o.length : o.location }   // the whole name
            delta = (o.location + o.length) - sEnd
        }
        return k + delta
    }

    /// An offset in the original text, in the sent one.
    func toSent(_ k: Int) -> Int {
        var delta = 0
        for (s, o) in replaced {
            if k < o.location { break }
            if k < o.location + o.length { return s.location }
            delta = (s.location + s.length) - (o.location + o.length)
        }
        return k + delta
    }

    /// A range of the sent text as a range of the original.
    func toOriginal(_ r: NSRange) -> NSRange {
        let a = toOriginal(r.location), b = toOriginal(r.location + r.length, end: true)
        return NSRange(location: a, length: max(0, b - a))
    }

    /// Where a quote is in the sent text, by the spike's normalisation (`_norm`: curly quotes straightened, whitespace
    /// collapsed, case folded), as a range of the original text. Nil when it isn't there or normalises to nothing.
    func locate(_ quote: String) -> NSRange? {
        guard let r = FactsSentText.find(quote, in: sent) else { return nil }
        return toOriginal(r)
    }

    /// The original text a range covers.
    func slice(_ r: NSRange) -> String { (original as NSString).substring(with: r) }

    /// Whether `needle` occurs in `hay`, both normalised (the spike's `_norm(a) in _norm(b)`); an empty needle doesn't.
    static func contains(_ hay: String, _ needle: String) -> Bool {
        let n = Normalized(needle).text
        return !n.isEmpty && Normalized(hay).text.contains(n)
    }

    static func norm(_ s: String?) -> String { Normalized(s ?? "").text }

    /// Like `find`, but only an occurrence that is a whole word in `text` (no letter or digit on either side, judged in
    /// the whole text, not at the edge of `within`): "Ana" in "Susana and Ana" is the second; in "Susana called" there's
    /// none. (A script written without spaces would need its own rule before the registry gains one.)
    static func findWord(_ needle: String, in text: String, within: NSRange? = nil) -> NSRange? {
        let ns = text as NSString
        let window = within ?? NSRange(location: 0, length: ns.length)
        let t = Normalized(ns.substring(with: window)), n = Normalized(needle).text
        guard !n.isEmpty else { return nil }
        let tn = t.text as NSString
        func letter(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let u = Unicode.Scalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(u)
        }
        var from = 0
        while from < tn.length {
            let r = tn.range(of: n, range: NSRange(location: from, length: tn.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            let start = window.location + t.starts[r.location], end = window.location + t.ends[r.location + r.length - 1]
            if !letter(start - 1), !letter(end) { return NSRange(location: start, length: end - start) }
            from = r.location + 1
        }
        return nil
    }

    /// Where a quote that holds `name` as a whole word is, as a range of the original text: the first occurrence of
    /// the quote in the text sent whose name sits on word boundaries of the whole text.
    func locate(_ quote: String, holding name: String) -> NSRange? {
        let t = Normalized(sent), q = Normalized(quote).text
        guard !q.isEmpty else { return nil }
        let tn = t.text as NSString
        var from = 0
        while from < tn.length {
            let r = tn.range(of: q, range: NSRange(location: from, length: tn.length - from))
            guard r.location != NSNotFound, r.length > 0 else { return nil }
            let start = t.starts[r.location], end = t.ends[r.location + r.length - 1]
            let hit = NSRange(location: start, length: end - start)
            if FactsSentText.findWord(name, in: sent, within: hit) != nil { return toOriginal(hit) }
            from = r.location + 1
        }
        return nil
    }

    /// The range of a normalised needle in a text, in the text's own offsets.
    static func find(_ needle: String, in text: String) -> NSRange? {
        let n = Normalized(needle).text, t = Normalized(text)
        guard !n.isEmpty else { return nil }
        let r = (t.text as NSString).range(of: n)
        guard r.location != NSNotFound, r.length > 0 else { return nil }
        let start = t.starts[r.location], end = t.ends[r.location + r.length - 1]
        return NSRange(location: start, length: end - start)
    }

    /// A normalised text and, for each of its UTF-16 units, the source range it came from.
    struct Normalized {
        var text = ""
        var starts: [Int] = []
        var ends: [Int] = []

        init(_ s: String) {
            var offset = 0
            var pending: (Int, Int)?
            for ch in s {
                let len = String(ch).utf16.count
                defer { offset += len }
                if ch.isWhitespace {
                    if !text.isEmpty { pending = (pending?.0 ?? offset, offset + len) }
                    continue
                }
                if let p = pending {
                    append(" ", p.0, p.1)
                    pending = nil
                }
                let mapped: String
                switch ch {
                case "’": mapped = "'"
                case "“", "”": mapped = "\""
                case "‹": mapped = "<"            // the prompt's disarmed tag character
                default: mapped = String(ch).lowercased()
                }
                append(mapped, offset, offset + len)
            }
        }

        private mutating func append(_ s: String, _ a: Int, _ b: Int) {
            text += s
            for _ in 0..<s.utf16.count {
                starts.append(a)
                ends.append(b)
            }
        }
    }
}
