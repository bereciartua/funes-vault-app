import Foundation

/// A timeline question: which predicate, which operator, and what it's anchored on (memory processing §11.7).
public struct TimelineIntent: Sendable, Equatable {
    public enum Operator: String, Sendable { case before, after, year, current, previous }

    public var predicate: String
    public var op: Operator
    public var anchor: TimelineAnchor?
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

    /// The anchor ends the operator phrase: what follows it, up to punctuation, is only words like "the first time".
    private func tailOK(_ q: String, _ pos: Int) -> Bool {
        let end = FactsText.first(Self.tailStop, in: q, from: pos)?.start ?? FactsText.length(q)
        let lang = registry.language
        let allowed = Set((lang.anchorTailWords + lang.episodeFirst + lang.episodeLast).map { FactsText.fold($0.replacingOccurrences(of: "*", with: "")) })
        return FactsText.matches(Self.wordRE, in: q, from: pos, to: end).allSatisfy { allowed.contains($0.group(0)!) }
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
        if lang.thirdPerson.contains(where: { FactsText.has(q, $0) }) { return true }
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
        let q = FactsText.fold(query)
        let lang = registry.language
        let lex = registry.lexicon
        for pred in registry.timelinePredicates {
            guard let p = registry.predicate(pred) else { continue }
            let cues = p.queryCues + lex.filter { $0.value.predicate == pred }.map(\.key)
            if !cues.contains(where: { FactsText.has(q, $0) }) { continue }
            var ops: [(end: Int, name: TimelineIntent.Operator)] = []
            for (name, words) in [(TimelineIntent.Operator.before, lang.operators.before), (.after, lang.operators.after)] {
                for w in words { ops += FactsText.matches(word(w), in: q).map { ($0.end, name) } }
            }
            func later(_ a: (end: Int, name: TimelineIntent.Operator), _ b: (end: Int, name: TimelineIntent.Operator)) -> Bool {
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
                        if let op = prior.max(by: later), let hit = hits.first, tailOK(q, end) {
                            let rest = FactsText.substring(q, 0, m.start) + " " + FactsText.substring(q, end, FactsText.length(q))
                            if personNamed(rest) { return nil }   // "Who was Ada dating before Bea?": someone else
                            return TimelineIntent(predicate: pred, op: op.name, anchor: .entity(hit))
                        }
                    }
                }
                for m in FactsText.matches(Self.yearRE, in: q) {
                    let prior = ops.filter { $0.end <= m.start }
                    if let op = prior.max(by: later), tailOK(q, m.end), let d = parser.dateEnding(at: m.end, in: q) {
                        return TimelineIntent(predicate: pred, op: op.name, anchor: .date(d))
                    }
                }
                continue
            }
            if anchorNames.contains(where: { !$0.isEmpty && FactsText.first(word($0), in: q) != nil }) {
                return nil                   // "my current role at Acme": a question about one fact, not the timeline
            }
            let years = FactsText.matches(Self.yearRE, in: q)
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
                    if let m = FactsText.first(re, in: q), !timeNouns.contains(FactsText.fold(m.group(1) ?? "")) {
                        return TimelineIntent(predicate: pred, op: name, anchor: nil)   // "my last job", not "last year"
                    }
                }
            }
        }
        return nil
    }
}
