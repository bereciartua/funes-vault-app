import Foundation

/// A timeline question: which predicate, which operator, and what it's anchored on (memory processing §11.7).
public struct TimelineIntent: Sendable, Equatable {
    public enum Operator: String, Sendable { case before, after, year, current, previous }

    public var predicate: String
    public var op: Operator
    public var anchor: TimelineAnchor?
    /// The folded operator phrase, operator to the end of its tail: the only text episode cues are read from.
    public var phrase: String?
    /// The slot value the user's own words ask within ("my day job" → employee), or nil (13e.1).
    public var slot: String?
    /// A date after the anchor ("before rejoining Acme in January 2021"): it picks the anchor's episode whose boundary
    /// (`anchorBoundary`: "start", "end", or nil for the stint) it overlaps.
    public var anchorDate: DateRange?
    public var anchorBoundary: String?
    /// The anchor's episode by number (1 the first, as the trusted episodes are ordered), for a comparison that names it
    /// (13e.2's check); nil reads the phrase's episode cues as before.
    public var stint: Int?

    public init(predicate: String, op: Operator, anchor: TimelineAnchor?, phrase: String? = nil, slot: String? = nil,
                anchorDate: DateRange? = nil, anchorBoundary: String? = nil, stint: Int? = nil) {
        self.predicate = predicate
        self.op = op
        self.anchor = anchor
        self.phrase = phrase
        self.slot = slot
        self.anchorDate = anchorDate
        self.anchorBoundary = anchorBoundary
        self.stint = stint
    }

    public static func == (a: TimelineIntent, b: TimelineIntent) -> Bool {
        a.predicate == b.predicate && a.op == b.op && a.anchor == b.anchor && a.slot == b.slot && a.anchorDate == b.anchorDate
            && a.stint == b.stint
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

    /// An adverb right before an operator ("immediately before", "justo antes de") belongs to the operator: where it
    /// starts, or nil. Only one of the registry's adverbs, right next to the operator, after a word of its own clause
    /// that isn't another adverb, in a clause with a question word ("where", "qué"; a yes/no question about a gap isn't
    /// one), and not a known name of the predicate's ("Straight", an employer). Anything else stays in the clause, which
    /// then fails closed as before.
    private func adverbStart(_ q: String, _ opStart: Int, names: Set<String>, unmasked: String? = nil) -> Int? {
        let lang = registry.language
        let adverbs = Set((lang.operatorAdverbs ?? []).map { FactsText.fold($0) })
        guard !adverbs.isEmpty else { return nil }
        let clause = FactsText.matches(Self.tailStop, in: q, from: 0, to: opStart).last?.end ?? 0
        let words = FactsText.matches(Self.wordRE, in: q, from: clause, to: opStart)
        // A word of its own clause before it: a masked slot word ("Employer immediately before…") counts too.
        let before = FactsText.matches(Self.wordRE, in: unmasked ?? q, from: clause, to: words.last?.start ?? clause)
        guard let m = words.last, adverbs.contains(m.group(0)!), !names.contains(m.group(0)!),
              FactsText.substring(q, m.end, opStart).allSatisfy({ $0 == " " }), !before.isEmpty,
              !adverbs.contains(before.last!.group(0)!) else { return nil }
        let wh = Set((lang.whWords ?? []).map { FactsText.fold($0) })
        // Or a clause of nouns only ("Employer immediately before Acme?", "My last day job right before Acme?"): no verb,
        // so not a yes/no question about a gap.
        let nouns = Set((lang.owners + lang.anchorDeterminers + nounWords).map { FactsText.fold($0) })
        // A clause opening with a noun ("Company I worked for immediately before Acme", "Mi empresa justo antes de…") is
        // a noun phrase too; one opening with a verb ("Did I start…", "¿Trabajé…") isn't.
        let firstWord = before.first.map { $0.group(0)! }
        guard words.dropLast().contains(where: { wh.contains($0.group(0)!) })
                || words.dropLast().allSatisfy({ nouns.contains($0.group(0)!) })
                || firstWord.map({ nouns.contains($0) || slotFirstWords.contains($0) }) == true else { return nil }
        return m.start
    }

    /// First words of slot phrases ("day job", "payroll"): a clause may open with one.
    private var slotFirstWords: Set<String> {
        Set(registry.predicates.flatMap { ($0.slotCues ?? [:]).values.flatMap { $0 } }.compactMap { FactsText.fold($0).split(separator: " ").first.map(String.init) })
    }

    /// The predicates' cue words and the operator modifiers: what a clause of nouns only may hold.
    private var nounWords: [String] {
        registry.predicates.filter { $0.uses.contains(FactsUse.timeline.rawValue) }.flatMap { p in
            (p.queryNouns ?? []) + registry.lexicon.filter { $0.value.predicate == p.id }.map(\.key)
        } + (registry.language.operatorModifiers ?? []).flatMap { $0.split(separator: " ").map(String.init) }
    }

    /// Folded text with these phrases blanked, keeping every offset: the words a check reads skip them.
    private func masked(_ q: String, _ phrases: [String]) -> String {
        var out = q
        for ph in Set(phrases.map { FactsText.fold($0) }).sorted(by: { $0.count > $1.count }) where !ph.isEmpty {
            let re = FactsText.regex("(?<!\\w)" + FactsText.escape(ph).replacingOccurrences(of: " ", with: "\\s+") + "(?!\\w)")
            let ns = out as NSString
            var parts: [String] = [], last = 0
            for m in FactsText.matches(re, in: out) {
                parts.append(ns.substring(with: NSRange(location: last, length: m.start - last)))
                parts.append(String(repeating: " ", count: m.end - m.start))
                last = m.end
            }
            parts.append(ns.substring(from: last))
            out = parts.joined()
        }
        return out
    }

    /// The slot value a stretch of the question asks within: words of exactly one value ("day job"), else nil.
    private func slotValue(_ q: String, _ p: FactsRegistry.Predicate, from: Int, to: Int) -> String? {
        let span = FactsText.substring(q, from, to)
        var found = Set<String>()
        for (value, words) in p.slotCues ?? [:] where words.contains(where: { FactsText.has(span, FactsText.fold($0)) }) {
            found.insert(value)
        }
        return found.count == 1 ? found.first : nil
    }

    /// Words of the user's own clause (memory processing §11.7).
    private func subjectVocabulary(_ predicate: String, cue: Bool) -> [String] {
        let lang = registry.language
        let p = registry.predicate(predicate)
        // No time nouns: "my summer job before Acme" asks about one kind of job, which the timeline can't tell.
        // Not the lead words (verbs like "got", "went", "with"): those belong between an operator and its anchor.
        // Episode words, but not the return cues' words ("back with", "de vuelta con").
        return lang.questionWords + lang.episodeFirst + lang.episodeLast + Array(lang.episodeOrdinals.keys) + lang.firstPerson + lang.owners
            + (p?.queryCues ?? [])
            + registry.lexicon.filter { $0.value.predicate == predicate }.map(\.key)
            + (lang.subjectWords ?? []) + (lang.operatorModifiers ?? []).flatMap { $0.split(separator: " ").map(String.init) }
            + (cue ? (lang.cueBoundWords ?? []) : [])
    }

    /// The question asks for the organization (13e.1): a "which" word with a noun of the predicate or a slot word after
    /// it ("Which company…", "¿Qué empresa…"); a "where" word with a work verb ("Where did I work…", "Where was I…"); a
    /// "who" frame ("Who employed me…", "Who do I work for…"); a name frame ("What do I call…"); or a noun phrase, its
    /// first word an owner, a determiner, a noun of the predicate, a slot word or an operator modifier, with a noun of
    /// the predicate ("Employer immediately before Acme?", "Mi empleador actual"). Words in `keep` (the operator phrase)
    /// don't count. "Who worked for my employer in 2020?", "Where is my company now?", "Am I still employed?" and
    /// "Did I work in 2017?" don't ask it.
    private func asksWhich(_ q: String, outside keep: [(Int, Int)], predicate: String) -> Bool {
        let lang = registry.language
        guard let frames = lang.askFrames else { return true }
        let p = registry.predicate(predicate)
        let slotPhrases = (p?.slotCues ?? [:]).values.flatMap { $0 }
        let nounList = (p?.queryNouns ?? []) + registry.lexicon.filter { $0.value.predicate == predicate }.map(\.key)
        let outside = FactsText.matches(Self.wordRE, in: q).filter { m in !keep.contains { m.start >= $0.0 && m.end <= $0.1 } }
        let text = outside.map { $0.group(0)! }.joined(separator: " ")
        let hasNoun = nounList.contains { FactsText.has(text, FactsText.fold($0)) } || slotPhrases.contains { FactsText.has(text, FactsText.fold($0)) }
        func any(_ k: String) -> Bool { (frames[k] ?? []).contains { FactsText.has(text, FactsText.fold($0)) } }
        if any("name_frames") { return true }
        // A who frame with no other noun of the predicate ("Who did I work for at my last job?" asks for a person).
        if any("who_frames") {
            var rest = text
            for f in frames["who_frames"] ?? [] { rest = rest.replacingOccurrences(of: FactsText.fold(f), with: " ") }
            return !nounList.contains { FactsText.has(rest, FactsText.fold($0)) }
        }
        // A person predicate's question asks who ("Who was I dating before Bea?").
        if registry.kindOf(predicate) == FactsValidator.personKind, outside.contains(where: { listed($0.group(0)!, lang.whWords ?? []) }) { return true }
        // "where" with a work verb, or one of the predicate's own verb cues (its cues that aren't nouns: "study").
        let verbCues = Set(p?.queryCues ?? []).subtracting(nounList)
        if any("where") && (any("where_verbs") || verbCues.contains { FactsText.has(text, FactsText.fold($0)) }) { return true }
        let words = outside.map { $0.group(0)! }
        // "Which company…", "What was my previous job…": the noun right after the which-word, with only `ask_between`
        // words in between ("What do I do at my job?" asks something else).
        if let i = words.firstIndex(where: { listed($0, frames["which"] ?? []) }) {
            var j = i + 1
            while j < words.count, listed(words[j], lang.askBetween ?? []) { j += 1 }
            let from = words[j...].joined(separator: " ")
            let verbNoun = j < words.count && listed(words[j], lang.verbNouns ?? []) && !(j > i + 1 && listed(words[j - 1], lang.owners + lang.anchorDeterminers))
            if j < words.count, !verbNoun, listed(words[j], nounList) || slotPhrases.contains(where: { from.hasPrefix(FactsText.fold($0)) }) { return true }
        }
        // A noun phrase: an owner, a determiner, a noun of the predicate or a modifier first, or a slot phrase opening it.
        let nouns = Set((lang.owners + lang.anchorDeterminers + nounWords).map { FactsText.fold($0) })
        return hasNoun && ((words.first.map { listed($0, Array(nouns)) } ?? false) || slotPhrases.contains { text.hasPrefix(FactsText.fold($0)) })
    }

    /// Every word outside these stretches is one of these.
    private func onlyWords(_ q: String, outside keep: [(Int, Int)], _ allowed: [String]) -> Bool {
        FactsText.matches(Self.wordRE, in: q).allSatisfy { m in keep.contains { m.start >= $0.0 && m.end <= $0.1 } || listed(m.group(0)!, allowed) }
    }

    /// Every word of these stretches is the user's own clause's (a question about something else fails closed).
    private func onlySubjectWords(_ q: String, outside keep: [(Int, Int)], predicate: String, cue: Bool) -> Bool {
        let allowed = subjectVocabulary(predicate, cue: cue)
        return FactsText.matches(Self.wordRE, in: q).allSatisfy { m in
            keep.contains { m.start >= $0.0 && m.end <= $0.1 } || listed(m.group(0)!, allowed)
        }
    }

    /// Where the operator phrase's tail ends: the next punctuation, or the end.
    private func tailEnd(_ q: String, _ pos: Int) -> Int {
        FactsText.first(Self.tailStop, in: q, from: pos)?.start ?? FactsText.length(q)
    }

    /// The anchor ends the operator phrase: what follows it, up to punctuation, is only words like "the first time".
    private func tailOK(_ q: String, _ pos: Int, op: TimelineIntent.Operator? = nil) -> Bool {
        let lang = registry.language
        // "After my job at Acme ended": an end word after the anchor is "after leaving Acme"; a start word, for before.
        // …and only when the lead says whose ("my job at Acme ended"), never the company's own ("before Acme moved").
        let lead = FactsText.matches(Self.wordRE, in: FactsText.substring(q, 0, pos)).suffix(4).map { $0.group(0)! }
        let mine = lead.contains { listed($0, lang.owners) }
        let event = !mine ? [] : op == .after ? lang.endEvents : op == .before ? lang.startEvents : []
        let allowed = lang.anchorTailWords + episodeWords
        let words = FactsText.matches(Self.wordRE, in: q, from: pos, to: tailEnd(q, pos)).map { $0.group(0)! }
        return words.allSatisfy { listed($0, allowed) || listed($0, event) } && words.filter { listed($0, event) && !listed($0, allowed) }.count <= 1
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
        // "after work at Acme" is after the working day, not after Acme.
        if let first = words.first, listed(first, lang.leadRefusedFirst ?? []) { return false }
        while let last = words.last, timeNouns.contains(last) { words.removeLast() }
        if let last = words.last, determiners.contains(last) { words.removeLast() }
        let p = registry.predicate(predicate)
        let allowed = lang.anchorLeadWords + episodeWords + lang.firstPerson + lang.owners + lang.timeNouns + lang.anchorTailWords
            + (p?.queryCues ?? []) + registry.lexicon.filter { $0.value.predicate == predicate }.map(\.key)
        // "Before leaving Acme" is before Acme's end, "after joining Acme" after its start: not what the anchor means.
        if words.contains(where: { listed($0, op == .before ? lang.endEvents : lang.startEvents) }) { return false }
        // "before I launched Acme", "once I'd finished at Acme": the event the operator means.
        return words.allSatisfy { listed($0, allowed) || listed($0, op == .before ? lang.startEvents : lang.endEvents) }
    }

    /// The question is the user's own, failing closed: the words of its clause before the operator (or the date) are
    /// only question words, lead words, first-person words, owners and the predicate's own words ("Where did I work",
    /// "What was my job", "¿Dónde trabajaba"). Anything else ("Where did sam work", "Sam's job") means no intent.
    private func subjectOK(_ q: String, _ pos: Int, predicate: String, cue: Bool = true) -> Bool {
        let clause = FactsText.matches(Self.tailStop, in: q, from: 0, to: pos).last?.end ?? 0
        let allowed = subjectVocabulary(predicate, cue: cue)
        return FactsText.matches(Self.wordRE, in: q, from: clause, to: pos).allSatisfy { listed($0.group(0)!, allowed) }
    }

    private func clauseStart(_ q: String, _ pos: Int) -> Int {
        FactsText.matches(Self.tailStop, in: q, from: 0, to: pos).last?.end ?? 0
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

    /// A date right after an anchor: one time preposition, then a date ending the phrase ("in January 2021", "en
    /// diciembre de 2021"). Its range and where the phrase ends, or nil.
    private func anchorDateTail(_ q: String, _ pos: Int, op: TimelineIntent.Operator) -> (range: DateRange, end: Int, dateStart: Int)? {
        let stop = tailEnd(q, pos)
        guard let y = FactsText.matches(Self.yearRE, in: q, from: pos, to: stop).last,
              FactsText.matches(Self.wordRE, in: q, from: y.end, to: stop).isEmpty,
              let d = parser.dateEnding(at: y.end, in: q) else { return nil }
        let start = parser.dateStart(at: y.end, in: q)
        var lead = FactsText.matches(Self.wordRE, in: q, from: pos, to: start).map { $0.group(0)! }
        let lang = registry.language
        let preps = lang.timePrepositions + lang.dayPrepositions
        // "my Acme job ended in December 2021": tail words and one event word may come first, the event the operator
        // means (an end after "after", a start after "before").
        let event = op == .after ? lang.endEvents : lang.startEvents
        var events = 0
        while let w = lead.first, !listed(w, preps), listed(w, lang.anchorTailWords) || (events == 0 && listed(w, event)) {
            if !listed(w, lang.anchorTailWords) { events += 1 }
            lead.removeFirst()
        }
        // "in January 2021", or with words of the date's own ("at the end of 2021", "a finales de 2021").
        guard let first = lead.first, listed(first, preps) || listed(first, lang.dateLeadWords ?? []),
              lead.dropFirst().allSatisfy({ listed($0, (lang.dateLeadWords ?? []) + preps) }),
              lead.count == 1 || !(lang.dateLeadWords ?? []).isEmpty else { return nil }
        return (d, stop, start)
    }

    /// "Acme was preceded by which job?": the anchor ends right before a passive operator, the words before it in its
    /// clause are lead words, and the rest is the user's own clause (memory processing §11.7, 13e.1).
    private func passiveIntent(_ q: String, _ qm: String, _ pred: String, _ p: FactsRegistry.Predicate, names: [String], kind: String,
                               hasCue: Bool, hasNoun: Bool, years: [FactsText.Match]) -> TimelineIntent? {
        for (dir, words) in registry.language.passiveOperators ?? [:] {
            guard let op: TimelineIntent.Operator = dir == "before" ? .before : dir == "after" ? .after : nil else { continue }
            for w in words {
                for o in FactsText.matches(word(w), in: q) {
                    for n in names {
                        let nn = FactsText.normName(n, kind: kind, registry: registry)
                        guard !nn.isEmpty else { continue }
                        guard let m = FactsText.matches(word(nn), in: q, from: 0, to: o.start).last else { continue }
                        let end = FactsText.matchAt(FactsText.regex(FactsText.escape(FactsText.fold(n)) + "(?!\\w)"), in: q, from: m.start)?.end ?? m.end
                        guard FactsText.substring(q, end, o.start).allSatisfy({ $0 == " " }) else { continue }
                        let start = clauseStart(q, m.start), stop = tailEnd(q, o.end)
                        guard leadOK(qm, start, m.start, predicate: pred, op: op), !years.contains(where: { $0.start >= start && $0.start < stop }),
                              onlySubjectWords(qm, outside: [(start, o.end)], predicate: pred, cue: hasNoun),
                              hasCue || onlyWords(qm, outside: [(start, o.end)], registry.language.anchorCueWords ?? []),
                              asksWhich(q, outside: [(start, o.end)], predicate: pred) else { continue }
                        var hits: [String] = []
                        let trusted = entityMatches(pred, n, onlyTrusted: true)
                        let found = trusted.isEmpty ? entityMatches(pred, n).filter { entities[$0]?.trustedAliases.isEmpty ?? true } : trusted
                        for h in found.map({ timelineEntity(pred, $0) }) where !hits.contains(h) { hits.append(h) }
                        guard let hit = hits.first else { continue }
                        return TimelineIntent(predicate: pred, op: op, anchor: hits.count == 1 ? .entity(hit) : nil,
                                              phrase: FactsText.substring(q, m.start, o.end), slot: slotValue(q, p, from: o.end, to: stop))
                    }
                }
            }
        }
        return nil
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
        // Only predicates whose timeline use is on (§11.10).
        for pred in uses.predicates(.timeline) {
            guard let p = registry.predicate(pred) else { continue }
            let cues = p.queryCues + lex.filter { $0.value.predicate == pred }.map(\.key)
            let slotPhrases = (p.slotCues ?? [:]).values.flatMap { $0 }
            // A cue word, or a slot word ("my day job"); without either, only an operator leading to an anchor of the
            // predicate makes a timeline question, and then every word outside its phrase must be the user's own clause's.
            let hasCue = cues.contains(where: { FactsText.has(q, $0) }) || slotPhrases.contains(where: { FactsText.has(q, FactsText.fold($0)) })
            // A noun of the predicate ("company", "empresa", "my business"): only beside one do the registry's cue-bound
            // words count ("Which company was I with…", never "Who did I work with…").
            let hasNoun = ((p.queryNouns ?? []) + lex.filter { $0.value.predicate == pred }.map(\.key)).contains(where: { FactsText.has(q, FactsText.fold($0)) })
                || slotPhrases.contains(where: { FactsText.has(q, FactsText.fold($0)) })
            // A question about one of its qualifiers ("my title before being promoted") is about a fact, not the timeline.
            if (p.qualifierCues ?? []).contains(where: { FactsText.has(q, $0) }) { continue }
            // Slot words and verb frames ("employed me", "me contrató") are read as units: the word checks skip them.
            let qm = masked(q, slotPhrases + (lang.subjectFrames ?? []))
            var nameSet = Set(facts.filter { $0.predicate == pred }.compactMap { entities[$0.entity]?.aliases }.flatMap { $0 })
            for (ph, syn) in p.placeholders ?? [:] {
                nameSet.insert(ph)
                nameSet.formUnion(syn)
            }
            let nameWords = Set(nameSet.flatMap { FactsText.fold($0).split(separator: " ").map(String.init) })
            var ops: [(start: Int, end: Int, name: TimelineIntent.Operator)] = []
            for (name, words) in [(TimelineIntent.Operator.before, lang.operators.before), (.after, lang.operators.after)] {
                for w in words {
                    ops += FactsText.matches(word(w), in: q).map { (adverbStart(qm, $0.start, names: nameWords, unmasked: q) ?? $0.start, $0.end, name) }
                }
            }
            // "once I'd left Acme", "having left Acme", "al salir de Acme": an "after" only with an end word (below).
            var eventEnds = Set<Int>()
            for w in lang.eventOperators ?? [] {
                for m in FactsText.matches(word(w), in: q) {
                    ops.append((m.start, m.end, .after))
                    eventEnds.insert(m.end)
                }
            }
            func later(_ a: (start: Int, end: Int, name: TimelineIntent.Operator), _ b: (start: Int, end: Int, name: TimelineIntent.Operator)) -> Bool {
                a.end != b.end ? a.end < b.end : a.name.rawValue < b.name.rawValue
            }
            ops.sort(by: later)
            let kind = registry.kindOf(pred)
            let names = nameSet.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            let anchorNames = Set(names.map { FactsText.normName($0, kind: kind, registry: registry) })
            if someoneElse(query, q, pred, anchorNames) { return nil }
            let years = FactsText.matches(Self.yearRE, in: q)
            // A stated rename's stand-in, computed once per question.
            let groups = statedGroups(pred)
            func stand(_ id: String) -> String {
                guard let g = groups.first(where: { $0.contains(id) }) else { return id }
                return g.min(by: { (entities[$0]?.seq ?? 0, $0) < (entities[$1]?.seq ?? 0, $1) }) ?? id
            }
            if let it = passiveIntent(q, qm, pred, p, names: names, kind: kind, hasCue: hasCue, hasNoun: hasNoun, years: years) { return it }
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
                        let found = trustedHits.isEmpty
                            ? entityMatches(pred, n).filter { entities[$0]?.trustedAliases.isEmpty ?? true } : trustedHits
                        // A stated rename is one entity: two names of it aren't two anchors.
                        var hits: [String] = []
                        for h in found.map({ stand($0) }) where !hits.contains(h) { hits.append(h) }
                        guard let op = prior.max(by: later), let hit = hits.first,
                              leadOK(qm, op.end, m.start, predicate: pred, op: op.name),
                              subjectOK(qm, op.start, predicate: pred, cue: hasNoun) else { continue }
                        if eventEnds.contains(op.end) {
                            let around = FactsText.matches(Self.wordRE, in: q, from: op.end, to: tailEnd(q, end)).map { $0.group(0)! }
                            guard around.contains(where: { listed($0, lang.endEvents) }) else { continue }
                        }
                        // After the anchor: tail words only, or a date picking its episode ("before rejoining Acme in
                        // January 2021"), at a boundary its lead words name.
                        var anchorDate: DateRange?, boundary: String?
                        var phraseEnd = tailEnd(q, end)
                        if !tailOK(q, end, op: op.name) {
                            guard let d = anchorDateTail(q, end, op: op.name) else { continue }
                            anchorDate = d.range
                            phraseEnd = d.end
                            // The boundary from the event words around the anchor (an end word in an after's tail: its end).
                            let leadWords = FactsText.matches(Self.wordRE, in: q, from: op.end, to: d.dateStart).map { $0.group(0)! }
                            if leadWords.contains(where: { listed($0, lang.startEvents) || listed($0, lang.episodeLast) }) { boundary = "start" }
                            if leadWords.contains(where: { listed($0, lang.endEvents) }) { boundary = boundary == nil ? "end" : "both" }
                            if boundary == "both" { continue }
                        }
                        let opStart = ops.filter { $0.end == op.end && $0.name == op.name }.map(\.start).min() ?? op.end
                        // A date elsewhere in the question ("In 2021, where did I work before Acme?") says something the
                        // anchor doesn't: no intent.
                        if years.contains(where: { $0.start < opStart || $0.start >= phraseEnd }) { return nil }
                        // Without a cue word, every other word must be the user's own clause's ("Before Acme, who fixed
                        // my laptop?" isn't a job question). So must it when the operator phrase leads its sentence
                        // ("Before I joined Acme, where did I work?"): the question is the clause after it.
                        let leading = FactsText.matches(Self.wordRE, in: q, from: clauseStart(q, opStart), to: opStart).isEmpty
                        // Every other word of the question is the user's own clause's, and it asks which (13e.1); with no
                        // cue word, only the few words of "Where did I go / work / was I" ("Where did I move after Acme?"
                        // isn't a job question).
                        // An event in the question itself must be the one the operator means ("Which company did I join
                        // after leaving X?"); "Which company did I leave after X?", "…join after 2018?" fail closed.
                        let own = FactsText.matches(Self.wordRE, in: qm).filter { $0.start < opStart || $0.start >= phraseEnd }.map { $0.group(0)! }
                        // ("came", "went": a job coming after another is what before / after ask.)
                        if own.contains(where: { listed($0, lang.eventWords ?? []) && !listed($0, (lang.cueBoundWords ?? []) + ["go", "went", "fui"]) }) { continue }
                        if own.contains(where: { listed($0, op.name == .after ? lang.endEvents : lang.startEvents) }) { continue }
                        // "my first job before Acme" asks for the earliest, not the one just before: no intent.
                        if own.contains(where: { listed($0, lang.episodeFirst + Array(lang.episodeOrdinals.keys)) }) { continue }
                        guard onlySubjectWords(qm, outside: [(opStart, phraseEnd)], predicate: pred, cue: hasNoun),
                              hasCue || onlyWords(qm, outside: [(opStart, phraseEnd)], lang.anchorCueWords ?? []),
                              asksWhich(q, outside: [(opStart, phraseEnd)], predicate: pred) else { continue }
                        let slotSpan = leading ? (phraseEnd, FactsText.length(q)) : (clauseStart(q, opStart), opStart)
                        let rest = FactsText.substring(q, 0, m.start) + " " + FactsText.substring(q, end, FactsText.length(q))
                        if personNamed(rest) { return nil }   // "Who was Ada dating before Bea?": someone else
                        // A name two entities share doesn't say which: no anchor, so the answer is told, not guessed.
                        return TimelineIntent(predicate: pred, op: op.name, anchor: hits.count == 1 ? .entity(hit) : nil,
                                              phrase: FactsText.substring(q, opStart, phraseEnd),
                                              slot: slotValue(q, p, from: slotSpan.0, to: slotSpan.1),
                                              anchorDate: anchorDate, anchorBoundary: boundary)
                    }
                }
                guard hasCue else { continue }
                // A date anchor takes no adverb: "immediately before 1 February 2019" would need the boundary itself held,
                // which the nearest-episode rule doesn't establish.
                let adverbs = Set((lang.operatorAdverbs ?? []).map { FactsText.fold($0) })
                func modified(_ op: (start: Int, end: Int, name: TimelineIntent.Operator)) -> Bool {
                    FactsText.matches(Self.wordRE, in: q, from: op.start, to: op.end).first.map { adverbs.contains($0.group(0)!) } ?? false
                }
                for m in years {
                    let prior = ops.filter { $0.end <= m.start }
                    if let op = prior.max(by: later), !modified(op), tailOK(q, m.end), leadOK(qm, op.end, parser.dateStart(at: m.end, in: q), predicate: pred, op: op.name) && subjectOK(qm, op.start, predicate: pred, cue: hasNoun),
                       let d = parser.dateEnding(at: m.end, in: q) {
                        let opStart = ops.filter { $0.end == op.end && $0.name == op.name }.map(\.start).min() ?? op.end
                        let span = [(opStart, tailEnd(q, m.end))]
                        let own = FactsText.matches(Self.wordRE, in: q).filter { $0.start < opStart || $0.start >= span[0].1 }.map { $0.group(0)! }
                        if own.contains(where: { listed($0, lang.startEvents + lang.endEvents + (lang.eventWords ?? [])) }) { continue }   // "…join after 2018?"
                        guard onlySubjectWords(qm, outside: span, predicate: pred, cue: hasNoun), asksWhich(q, outside: span, predicate: pred) else { continue }
                        return TimelineIntent(predicate: pred, op: op.name, anchor: .date(d),
                                              phrase: FactsText.substring(q, opStart, tailEnd(q, m.end)),
                                              slot: slotValue(q, p, from: clauseStart(q, opStart), to: opStart))
                    }
                }
                continue
            }
            guard hasCue else { continue }
            // "my current role at Acme": a question about one fact, not the timeline. A placeholder's words aren't a
            // name here ("my current freelance business" asks the timeline).
            let placeholderNames = Set((p.placeholders ?? [:]).flatMap { [$0.key] + $0.value }.map { FactsText.normName($0, kind: kind, registry: registry) })
            if anchorNames.subtracting(placeholderNames).contains(where: { !$0.isEmpty && FactsText.first(word($0), in: q) != nil }) {
                return nil
            }
            // The slot the question asks within: its words anywhere but the dates.
            let slot = slotValue(q, p, from: 0, to: FactsText.length(q))
            // An event ("Which company did I join in 2019?", "¿Qué empresa dejé en 2019?") isn't what held then.
            let allWords = FactsText.matches(Self.wordRE, in: q).map { $0.group(0)! }
            // Accents tell "entré" (an event) from "entre" (a range): the raw words, lowercased.
            let rawWords = FactsText.matches(Self.wordRE, in: query.lowercased()).map { $0.group(0)! }
            // (Folded, "entré" is "entre": a range preposition isn't an event.)
            let events = lang.startEvents + lang.endEvents + lang.episodeLast + (lang.eventWords ?? []) + lang.episodeFirst + Array(lang.episodeOrdinals.keys)
            let rawEvents = Set(events.map { $0.lowercased() })
            let preps = Set((lang.rangePrepositions + lang.yearPrepositions).map { $0.lowercased() })
            if rawWords.contains(where: { !preps.contains($0) && (rawEvents.contains($0) || listed(FactsText.fold($0), events)) }) { continue }
            let previousWords = lang.operators.previous + (lang.operatorModifiers ?? []).flatMap { $0.split(separator: " ").map(String.init) }
            // Fails closed: the date follows a year preposition ("in 2016", "en marzo de 2016"), or a span opens with a
            // range one ("between 2014 and 2016"), and ends its phrase; "since 2016" and "until 2016" get no intent. A
            // date clause may lead ("In 2021, ¿qué empresa me tenía en plantilla?"): the rest is then the user's clause.
            if let y = years.first {
                let opening = lang.yearPrepositions + (years.count > 1 ? lang.rangePrepositions : [])
                let alt = { (xs: [String]) in xs.map { FactsText.escape(FactsText.fold($0)).replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|") }
                let start = parser.dateStart(at: y.end, in: q)
                let lead = FactsText.substring(q, 0, start)
                // "in 2016", "en el año 2019", "in the year 2019"
                let prepRE = FactsText.regex("(?<!\\w)(?:" + alt(opening) + ")\\s+(?:(?:" + alt(lang.anchorDeterminers) + ")\\s+)?(?:(?:"
                                             + alt(lang.timeNouns) + ")\\s+)?$")
                let last = years[years.count - 1].end
                if let prep = FactsText.first(prepRE, in: lead) {
                    let span = [(prep.start, last)]
                    guard tailOK(q, last), onlySubjectWords(qm, outside: span, predicate: pred, cue: hasNoun), asksWhich(q, outside: span, predicate: pred) else { continue }
                } else {
                    // A date opening the question ("October 2020: which company employed me?", "August 2020 workplace"):
                    // every other word is the user's own clause's.
                    // Or a date alone in its clause ("employee job, July 2020").
                    let own = FactsText.substring(q, clauseStart(q, start), start)
                    let opening = lead.allSatisfy { !$0.isLetter && !$0.isNumber }
                    let alone = FactsText.matches(Self.wordRE, in: q, from: last, to: tailEnd(q, last)).isEmpty
                    let span = [(clauseStart(q, start), alone ? tailEnd(q, last) : last)]
                    guard own.allSatisfy({ !$0.isLetter && !$0.isNumber }), years.count == 1, opening || alone,
                          onlySubjectWords(qm, outside: span, predicate: pred, cue: hasNoun), asksWhich(q, outside: span, predicate: pred) else { continue }
                }
            }
            // A year with "previous", "next" or "current" in it ("my previous employer in 2020") isn't the year's.
            if !years.isEmpty, allWords.contains(where: { listed($0, previousWords + lang.operators.current) }) { continue }
            if years.count > 1, let a = parser.dateEnding(at: years[0].end, in: q),
               let b = parser.dateEnding(at: years[years.count - 1].end, in: q) {
                return TimelineIntent(predicate: pred, op: .year, anchor: .date(DateRange(lo: a.lo, hi: b.hi, precision: .year)), slot: slot)
            }
            if let y = years.first, let d = parser.dateEnding(at: y.end, in: q) {
                return TimelineIntent(predicate: pred, op: .year, anchor: .date(d), slot: slot)
            }
            let timeNouns = Set(lang.timeNouns.map { FactsText.fold($0) })
            for (name, words) in [(TimelineIntent.Operator.previous, lang.operators.previous), (.current, lang.operators.current)] {
                for w in words {
                    let re = FactsText.regex("(?<!\\w)" + FactsText.escape(FactsText.fold(w)) + "(?!\\w)\\s*(\\w+)?")
                    let span = { (m: FactsText.Match) in [(m.start, m.start + FactsText.length(FactsText.fold(w)))] }
                    if let m = FactsText.first(re, in: q), !timeNouns.contains(FactsText.fold(m.group(1) ?? "")),
                       onlySubjectWords(qm, outside: span(m), predicate: pred, cue: hasNoun), asksWhich(q, outside: span(m), predicate: pred) {
                        return TimelineIntent(predicate: pred, op: name, anchor: nil, slot: slot)   // "my last job", not "last year"
                    }
                }
            }
        }
        return nil
    }
}
