import Foundation

/// What this Mac knows about other people who share the user's names (memory processing §11.3, §11.9): known people's
/// names of two or more words, from the graph the call's roster comes from, so the profile matcher keeps such a name.
public struct FactsNamesakes: Sendable, Equatable {
    /// Names of known people (never *you*) of two or more words, as their aliases write them ("Dani Ortiz").
    public var fullNames: [String] = []
    /// Folded words of known things' names ("amazon"): never the start of a surname.
    public var thingWords: Set<String> = []

    public init(fullNames: [String] = [], thingWords: Set<String> = []) {
        self.fullNames = fullNames
        self.thingWords = thingWords
    }

    public static let none = FactsNamesakes()
}

/// A memory's text as the Facts call sends it (memory processing §11.3, §11.9): the user's own names replaced by the
/// registry's placeholder, with a map of offsets, so quotes are validated against the text sent and mapped back to the
/// original. Offsets are UTF-16, as `NSString` and the graph use.
///
/// The profile matcher: a profile name is matched as written or in capitals (a one-word name: so a user called Will
/// keeps "I will call"), or in any case (a name of two or more words), as a whole word, longest first. Each occurrence
/// is the user unless it's a namesake's, which keeps its name:
/// - it's inside a known person's full name written here ("Dani Ortiz" for a user whose profile has "Dani");
/// - or, written as the profile writes it, it's followed by a word written in title case (two letters or more, not all
///   capitals) that isn't a stop name, a not-name, a month, a weekday or a word of a known thing's name, on an ordinary
///   line (some other word not capitalised, and most of them not, as a title can have): the start of someone else's
///   full name.
/// Anything else is the user: a bare name that could be either is replaced (privacy fails closed), so a namesake known
/// by one word alone can't be learned through a cloud model.
public struct FactsSentText: Sendable, Equatable {
    public let original: String
    public let sent: String
    /// Replaced spans, in order: (sent range, original range).
    let replaced: [(sent: NSRange, original: NSRange)]

    public static func == (a: FactsSentText, b: FactsSentText) -> Bool { a.original == b.original && a.sent == b.sent }

    public init(_ text: String, userAliases: [String], registry: FactsRegistry, namesakes: FactsNamesakes = .none) {
        original = text
        let ns = text as NSString
        var spans: [NSRange] = [], kept: [NSRange] = []
        // As written, or in capitals ("DANI"): not in any case, so a user called Will keeps "I will call".
        let forms = userAliases.flatMap { [$0, $0.uppercased()] }
        let longest = Array(Set(forms)).sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0 < $1 })
        let matcher = Matcher(text: text, userAliases: userAliases, registry: registry, namesakes: namesakes)
        for a in longest where !a.isEmpty {
            let multiWord = a.split(separator: " ").count >= 2
            let re = FactsText.regex("\\b" + FactsText.escape(a) + "\\b", caseInsensitive: multiWord)
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where !(spans + kept).contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                let asWritten = ns.substring(with: m.range) == a && userAliases.contains(a)
                if matcher.isNamesake(m.range, asWritten: asWritten) { kept.append(m.range) } else { spans.append(m.range) }
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

    /// The profile matcher's rules for one text.
    struct Matcher {
        let ns: NSString
        let stop: Set<String>
        let userForms: Set<String>
        let thingWords: Set<String>
        /// Ranges of known people's full names written in the text.
        let fullNameRanges: [NSRange]

        init(text: String, userAliases: [String], registry: FactsRegistry, namesakes: FactsNamesakes) {
            ns = text as NSString
            let lang = registry.language
            stop = Set((lang.stopNames + lang.notNames + lang.months.values.flatMap { $0 } + (lang.weekdays ?? []))
                .map { FactsText.fold($0) })
            userForms = Set(userAliases.map { FactsText.fold($0) })
            thingWords = namesakes.thingWords
            var ranges: [NSRange] = []
            for full in namesakes.fullNames where full.split(separator: " ").count >= 2 && !userForms.contains(FactsText.fold(full)) {
                var from = 0
                while let r = FactsText.wholeWord(full, in: text, from: from) {
                    ranges.append(r)
                    from = r.location + max(r.length, 1)
                }
            }
            fullNameRanges = ranges
        }

        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0xA0 }

        /// The word right after `end` on the same line (spaces between), if any.
        func word(after end: Int) -> String? {
            var i = end, spaces = 0
            while i < ns.length, isSpace(ns.character(at: i)) { i += 1; spaces += 1 }
            guard spaces > 0 else { return nil }
            let start = i
            while i < ns.length, let u = Unicode.Scalar(ns.character(at: i)), CharacterSet.letters.contains(u) { i += 1 }
            return i > start ? ns.substring(with: NSRange(location: start, length: i - start)) : nil
        }

        /// Whether the line holding `at` reads as prose: of its words that don't open a sentence, aren't the user's names
        /// and aren't `skip` (the word that would be a surname), at least one isn't capitalised, and most aren't (as a
        /// title or a heading can have).
        func ordinaryLine(_ at: Int, skip: NSRange) -> Bool {
            var a = at, b = at
            while a > 0, ns.character(at: a - 1) != 0x0A, ns.character(at: a - 1) != 0x0D { a -= 1 }
            while b < ns.length, ns.character(at: b) != 0x0A, ns.character(at: b) != 0x0D { b += 1 }
            var words: [String] = [], opens = true, i = a
            while i < b {
                guard let u = Unicode.Scalar(ns.character(at: i)), CharacterSet.letters.contains(u) else {
                    if let u = Unicode.Scalar(ns.character(at: i)), ".!?:…¿¡•-–—*#".unicodeScalars.contains(u) { opens = true }
                    i += 1
                    continue
                }
                let start = i
                while i < b, let u = Unicode.Scalar(ns.character(at: i)), CharacterSet.letters.contains(u) { i += 1 }
                let word = ns.substring(with: NSRange(location: start, length: i - start))
                if !opens, start != skip.location, !userForms.contains(FactsText.fold(word)) { words.append(word) }
                opens = false
            }
            let capitalised = words.filter { $0.first?.isUppercase == true }.count
            return capitalised < words.count && capitalised * 2 < words.count
        }

        func isNamesake(_ r: NSRange, asWritten: Bool) -> Bool {
            if fullNameRanges.contains(where: { NSIntersectionRange($0, r).length == r.length }) { return true }
            guard asWritten, let w = word(after: r.location + r.length), w.count >= 2, w.first?.isUppercase == true,
                  w.dropFirst().contains(where: { $0.isLowercase }), !w.dropFirst().contains(where: { $0.isUppercase }) else { return false }
            let f = FactsText.fold(w)
            guard !stop.contains(f), !userForms.contains(f), !thingWords.contains(f) else { return false }
            let start = (ns.range(of: w, range: NSRange(location: r.location + r.length, length: ns.length - r.location - r.length))).location
            return ordinaryLine(r.location, skip: NSRange(location: start, length: (w as NSString).length))
        }
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

    /// The sent text for a range of the original (a name the range only partly covers becomes the whole placeholder).
    func sentSlice(_ r: NSRange) -> String {
        let a = toSent(r.location), b = max(a, toSentEnd(r.location + r.length))
        return (sent as NSString).substring(with: NSRange(location: a, length: b - a))
    }

    /// An end offset in the original text, in the sent one: inside a replaced name, the end of its placeholder.
    func toSentEnd(_ k: Int) -> Int {
        var delta = 0
        for (s, o) in replaced {
            if k <= o.location { break }
            if k <= o.location + o.length { return s.location + s.length }
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
