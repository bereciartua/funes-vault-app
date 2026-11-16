import Foundation

/// A timeline question: which predicate, which operator, and what it's anchored on (memory processing §11.7).
public struct TimelineIntent: Sendable, Equatable {
    public enum Operator: String, Sendable { case before, after, year, current, previous }

    public var predicate: String
    public var op: Operator
    public var anchor: TimelineAnchor?
    /// The folded operator phrase, operator to the end of its tail: the only text episode cues are read from.
    public var phrase: String?

    public init(predicate: String, op: Operator, anchor: TimelineAnchor?, phrase: String? = nil) {
        self.predicate = predicate
        self.op = op
        self.anchor = anchor
        self.phrase = phrase
    }

    public static func == (a: TimelineIntent, b: TimelineIntent) -> Bool {
        a.predicate == b.predicate && a.op == b.op && a.anchor == b.anchor
    }
}

extension FactsGraph {
    private static let wordRE = FactsText.regex("[\\w'’-]+")
    private static let tokenRE = FactsText.regex("[^\\W\\d_][\\w'’-]*")
    private static let yearRE = FactsText.regex("\\b(19|20)\\d{2}\\b")
    private static let tailStop = FactsText.regex("[,.;:!?¿¡]")
    private static let possessive = FactsText.regex("['’]s$")

    private func word(_ w: String) -> NSRegularExpression {
        FactsText.regex("(?<!\\w)" + FactsText.escape(FactsText.fold(w)) + "(?!\\w)")
    }

    /// Whether a word is one of these registry words, or matches one of their stems ("regres*").
    private func listed(_ w: String, _ words: [String]) -> Bool {
        words.contains { x in
            let f = FactsText.fold(x)
            return f.hasSuffix("*") ? w.hasPrefix(String(f.dropLast())) : f == w
        }
    }

    private var episodeWords: [String] {
        let lang = registry.language
        return lang.episodeFirst + lang.episodeLast + Array(lang.episodeOrdinals.keys)
            + lang.returnCues.flatMap { $0.split(separator: " ").map(String.init) }
    }

    /// Where the operator phrase's tail ends: the next punctuation, or the end.
    private func tailEnd(_ q: String, _ pos: Int) -> Int {
        FactsText.first(Self.tailStop, in: q, from: pos)?.start ?? FactsText.length(q)
    }

    /// The anchor ends the operator phrase: what follows it, up to punctuation, is only words like "the first time".
    private func tailOK(_ q: String, _ pos: Int) -> Bool {
        let allowed = registry.language.anchorTailWords + episodeWords
        return FactsText.matches(Self.wordRE, in: q, from: pos, to: tailEnd(q, pos)).allSatisfy { listed($0.group(0)!, allowed) }
    }

    /// The operator leads to the anchor itself, and the question fails closed (memory processing §11.7): between them
    /// stand only the registry's lead words ("before I joined Acme"), the predicate's own words ("before my job at
    /// Acme"), episode cues ("before I returned to Acme"), first-person words, owners and time nouns ("before my time at Acme"), and one determiner right
    /// before the anchor or its date ("before the BBC", "antes del 15 de marzo"), or before a time noun and the date
    /// ("before the year 2019"). Anything else ("before the promotion at Acme") means no timeline intent.
    private func leadOK(_ q: String, _ from: Int, _ to: Int, predicate: String, op: TimelineIntent.Operator) -> Bool {
        let lang = registry.language
        let determiners = Set(lang.anchorDeterminers.map { FactsText.fold($0) })
        let timeNouns = Set(lang.timeNouns.map { FactsText.fold($0) })
        var words = FactsText.matches(Self.wordRE, in: q, from: from, to: to).map { $0.group(0)! }
        while let last = words.last, timeNouns.contains(last) { words.removeLast() }
        if let last = words.last, determiners.contains(last) { words.removeLast() }
        let p = registry.predicate(predicate)
        let allowed = lang.anchorLeadWords + episodeWords + lang.firstPerson + lang.owners + lang.timeNouns
            + (p?.queryCues ?? []) + registry.lexicon.filter { $0.value.predicate == predicate }.map(\.key)
        // "Before leaving Acme" is before Acme's end, "after joining Acme" after its start: not what the anchor means.
        if words.contains(where: { listed($0, op == .before ? lang.endEvents : lang.startEvents) }) { return false }
        return words.allSatisfy { listed($0, allowed) }
    }

    /// The question is the user's own, failing closed: the words of its clause before the operator (or the date) are
    /// only question words, lead words, first-person words, owners and the predicate's own words ("Where did I work",
    /// "What was my job", "¿Dónde trabajaba"). Anything else ("Where did sam work", "Sam's job") means no intent.
    private func subjectOK(_ q: String, _ pos: Int, predicate: String) -> Bool {
        let lang = registry.language
        let clause = FactsText.matches(Self.tailStop, in: q, from: 0, to: pos).last?.end ?? 0
        let p = registry.predicate(predicate)
        let allowed = lang.questionWords + lang.anchorLeadWords + episodeWords + lang.firstPerson + lang.owners
            + lang.timeNouns + lang.timePrepositions + (p?.queryCues ?? [])
            + registry.lexicon.filter { $0.value.predicate == predicate }.map(\.key)
        return FactsText.matches(Self.wordRE, in: q, from: clause, to: pos).allSatisfy { listed($0.group(0)!, allowed) }
    }

    /// Whether a known person's name appears in folded text.
    private func personNamed(_ q: String) -> Bool {
        let stop = Set(registry.language.stopNames)
        return orderedEntities.contains { e in
            e.kind == "person" && e.name != nil && e.nameForms.contains { a in
                let fa = FactsText.fold(a)
                return fa.count >= 3 && !stop.contains(fa) && FactsText.has(q, fa)
            }
        }
    }

    /// The question is about another person's fact: a known person (other than an anchor) is named, an unknown name
    /// is the subject, a third-person pronoun is, or a role phrase of another person predicate ("my wife") is.
    private func someoneElse(_ query: String, _ q: String, _ predicate: String, _ anchorNames: Set<String>) -> Bool {
        let lang = registry.language
        let stop = Set(lang.stopNames)
        for e in orderedEntities where e.kind == "person" && e.name != nil {
            if facts.contains(where: { $0.entity == e.id && $0.predicate == predicate }) { continue }   // an anchor
            for a in e.nameForms {
                let fa = FactsText.fold(a)
                if fa.count >= 3, !stop.contains(fa), FactsText.has(q, fa), !anchorNames.contains(where: { $0.contains(fa) }) {
                    return true
                }
            }
        }
        // Accent-sensitive: "él" is a pronoun, "el" an article.
        let lower = query.lowercased()
        if lang.thirdPerson.contains(where: { w in
            FactsText.first(FactsText.regex("(?<!\\w)" + FactsText.escape(w.lowercased()) + "(?!\\w)"), in: lower) != nil
        }) { return true }
        let lex = registry.lexicon
        for m in FactsText.matches(rolePattern(), in: query) {
            if let p = lex[m.group(5)!.lowercased()]?.predicate, p != predicate, registry.kindOf(p) == "person" { return true }
        }
        var known = Set(entities.values.flatMap { $0.aliases.flatMap { $0.split(separator: " ").map { FactsText.fold(String($0)) } } })
        for p in registry.predicates {
            for (ph, syn) in p.placeholders ?? [:] {
                for x in [ph] + syn { known.formUnion(x.split(separator: " ").map { FactsText.fold(String($0)) }) }
            }
        }
        known.formUnion(registry.monthWords.keys)
        let ns = query as NSString
        for m in FactsText.matches(Self.tokenRE, in: query) {
            let t = m.group(0)!
            let before = ns.substring(to: m.start).trimmingCharacters(in: .whitespacesAndNewlines)
            if before.isEmpty || ".!?¿¡:".contains(before.last!) || lang.firstPerson.contains(t) || !(t.first?.isUppercase ?? false) {
                continue                 // sentence-initial words are capitalised anyway
            }
            let bare = Self.possessive.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: FactsText.length(t)),
                                                                withTemplate: "")
            if !known.contains(FactsText.fold(bare)) { return true }   // an unknown name: probably someone else
        }
        return false
    }

    /// The timeline intent of a query, or nil. Operators: before / after (the anchor, an entity holding a fact of the
    /// predicate or a date, follows the operator and ends its phrase), year, current, previous.
    public func intent(_ query: String) -> TimelineIntent? {
        let lang = registry.language
        // A contraction that completes an operator is expanded, so "antes del 15 de marzo" has its operator ("antes
        // de") and its determiner ("el"); elsewhere it stays, so names keep it ("Banco del Sur").
        var q = FactsText.fold(query)
        for (w, full) in lang.contractions {
            let parts = FactsText.fold(full).split(separator: " ").map(String.init)
            guard let head = parts.first else { continue }
            for op in lang.operators.before + lang.operators.after {
                var words = FactsText.fold(op).split(separator: " ").map(String.init)
                guard words.count > 1, words.last == head else { continue }
                words.removeLast()
                let lead = words.map(FactsText.escape).joined(separator: "\\s+")
                q = FactsText.regex("(?<!\\w)(" + lead + ")\\s+" + FactsText.escape(FactsText.fold(w)) + "(?!\\w)")
                    .stringByReplacingMatches(in: q, range: NSRange(location: 0, length: FactsText.length(q)),
                                              withTemplate: "$1 " + NSRegularExpression.escapedTemplate(for: parts.joined(separator: " ")))
            }
        }
        let lex = registry.lexicon
        for pred in registry.timelinePredicates {
            guard let p = registry.predicate(pred) else { continue }
            let cues = p.queryCues + lex.filter { $0.value.predicate == pred }.map(\.key)
            if !cues.contains(where: { FactsText.has(q, $0) }) { continue }
            // A question about one of its qualifiers ("my title before being promoted") is about a fact, not the timeline.
            if (p.qualifierCues ?? []).contains(where: { FactsText.has(q, $0) }) { continue }
            var ops: [(start: Int, end: Int, name: TimelineIntent.Operator)] = []
            for (name, words) in [(TimelineIntent.Operator.before, lang.operators.before), (.after, lang.operators.after)] {
                for w in words { ops += FactsText.matches(word(w), in: q).map { ($0.start, $0.end, name) } }
            }
            func later(_ a: (start: Int, end: Int, name: TimelineIntent.Operator), _ b: (start: Int, end: Int, name: TimelineIntent.Operator)) -> Bool {
                a.end != b.end ? a.end < b.end : a.name.rawValue < b.name.rawValue
            }
            ops.sort(by: later)
            let kind = registry.kindOf(pred)
            var nameSet = Set(facts.filter { $0.predicate == pred }.compactMap { entities[$0.entity]?.aliases }.flatMap { $0 })
            for (ph, syn) in p.placeholders ?? [:] {
                nameSet.insert(ph)
                nameSet.formUnion(syn)
            }
            let names = nameSet.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            let anchorNames = Set(names.map { FactsText.normName($0, kind: kind, registry: registry) })
            if someoneElse(query, q, pred, anchorNames) { return nil }
            if !ops.isEmpty {
                for n in names {
                    let nn = FactsText.normName(n, kind: kind, registry: registry)
                    guard !nn.isEmpty else { continue }
                    for m in FactsText.matches(word(nn), in: q) {
                        let raw = FactsText.matchAt(FactsText.regex(FactsText.escape(FactsText.fold(n)) + "(?!\\w)"), in: q, from: m.start)
                        let end = raw?.end ?? m.end      // "Kiteworks Ltd", not just "Kiteworks"
                        let prior = ops.filter { $0.end <= m.start }
                        // Trusted aliases first; an alias only untrusted memories gave anchors only an entity with no
                        // trusted name at all.
                        let trustedHits = entityMatches(pred, n, onlyTrusted: true)
                        let hits = trustedHits.isEmpty
                            ? entityMatches(pred, n).filter { entities[$0]?.trustedAliases.isEmpty ?? true } : trustedHits
                        if let op = prior.max(by: later), let hit = hits.first, tailOK(q, end), leadOK(q, op.end, m.start, predicate: pred, op: op.name) && subjectOK(q, op.start, predicate: pred) {
                            let rest = FactsText.substring(q, 0, m.start) + " " + FactsText.substring(q, end, FactsText.length(q))
                            if personNamed(rest) { return nil }   // "Who was Ada dating before Bea?": someone else
                            // A name two entities share doesn't say which: no anchor, so the answer is told, not guessed.
                            let opStart = ops.filter { $0.end == op.end && $0.name == op.name }.map(\.start).min() ?? op.end
                            return TimelineIntent(predicate: pred, op: op.name, anchor: hits.count == 1 ? .entity(hit) : nil,
                                                  phrase: FactsText.substring(q, opStart, tailEnd(q, end)))
                        }
                    }
                }
                for m in FactsText.matches(Self.yearRE, in: q) {
                    let prior = ops.filter { $0.end <= m.start }
                    if let op = prior.max(by: later), tailOK(q, m.end), leadOK(q, op.end, parser.dateStart(at: m.end, in: q), predicate: pred, op: op.name) && subjectOK(q, op.start, predicate: pred),
                       let d = parser.dateEnding(at: m.end, in: q) {
                        let opStart = ops.filter { $0.end == op.end && $0.name == op.name }.map(\.start).min() ?? op.end
                        return TimelineIntent(predicate: pred, op: op.name, anchor: .date(d),
                                              phrase: FactsText.substring(q, opStart, tailEnd(q, m.end)))
                    }
                }
                continue
            }
            if anchorNames.contains(where: { !$0.isEmpty && FactsText.first(word($0), in: q) != nil }) {
                return nil                   // "my current role at Acme": a question about one fact, not the timeline
            }
            let years = FactsText.matches(Self.yearRE, in: q)
            // Fails closed: the date follows a year preposition ("in 2016", "en marzo de 2016"), or a span opens with a
            // range one ("between 2014 and 2016"), and ends its phrase; "since 2016" and "until 2016" get no intent.
            if let y = years.first {
                let opening = lang.yearPrepositions + (years.count > 1 ? lang.rangePrepositions : [])
                let preps = opening.map { FactsText.escape(FactsText.fold($0)).replacingOccurrences(of: " ", with: "\\s+") }
                let lead = FactsText.substring(q, 0, parser.dateStart(at: y.end, in: q))
                let prepRE = FactsText.regex("(?<!\\w)(?:" + preps.joined(separator: "|") + ")\\s+$")
                guard let prep = FactsText.first(prepRE, in: lead), tailOK(q, years[years.count - 1].end),
                      subjectOK(q, prep.start, predicate: pred) else { continue }
            }
            if years.count > 1, let a = parser.dateEnding(at: years[0].end, in: q),
               let b = parser.dateEnding(at: years[years.count - 1].end, in: q) {
                return TimelineIntent(predicate: pred, op: .year, anchor: .date(DateRange(lo: a.lo, hi: b.hi, precision: .year)))
            }
            if let y = years.first, let d = parser.dateEnding(at: y.end, in: q) {
                return TimelineIntent(predicate: pred, op: .year, anchor: .date(d))
            }
            let timeNouns = Set(lang.timeNouns.map { FactsText.fold($0) })
            for (name, words) in [(TimelineIntent.Operator.previous, lang.operators.previous), (.current, lang.operators.current)] {
                for w in words {
                    let re = FactsText.regex("(?<!\\w)" + FactsText.escape(FactsText.fold(w)) + "(?!\\w)\\s*(\\w+)?")
                    if let m = FactsText.first(re, in: q), !timeNouns.contains(FactsText.fold(m.group(1) ?? "")),
                       subjectOK(q, m.start, predicate: pred) {
                        return TimelineIntent(predicate: pred, op: name, anchor: nil)   // "my last job", not "last year"
                    }
                }
            }
        }
        return nil
    }
}
