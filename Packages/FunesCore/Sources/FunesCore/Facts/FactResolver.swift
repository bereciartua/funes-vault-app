import Foundation

/// A first-person role phrase in a memory ("my sister", "my old boss", "at my previous job").
public struct RolePhrase: Sendable, Equatable {
    public var start: Int               // UTF-16 offsets into the memory text
    public var end: Int
    public var surface: String
    public var word: String
    public var predicate: String
    public var cls: String?
    public var generic: Bool
    public var mods: [String]
    public var timeCue: String?         // "in February 2019", next to the phrase
    public var qual: String?
    public var paired: String?          // a name the text ties to the phrase
    public var plural: Bool
    public var exclusiveLabel: Bool
    public var former: Bool             // "my ex", "my old boss": former holders only
    public var current: Bool            // "my new boss"
    public var statusWord: Bool         // the word itself means former ("ex")
}

extension FactsGraph {
    // MARK: Role phrases

    func rolePattern() -> NSRegularExpression {
        let lang = registry.language
        let words = registry.lexicon.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        let owners = lang.owners.map(FactsText.escape)
            + userAliases.sorted { $0.count > $1.count }.map { FactsText.escape($0) + "['’]s" }
        let mods = "(?:" + lang.modifiers.map(FactsText.escape).joined(separator: "|") + ")"
        let prefixes = lang.formerPrefixes.map { FactsText.escape($0).replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        let fw = lang.functionWords.map(FactsText.escape).joined(separator: "|")
        return FactsText.regex(
            "\\b(" + owners.joined(separator: "|") + ")\\s+((?:" + mods + "\\s+)*)"
            + "((?:(?!(?:" + fw + ")\\b)[^\\W\\d_][\\w-]*\\s+){0,2}?)(" + prefixes + ")?("
            + words.map(FactsText.escape).joined(separator: "|") + ")(?![\\w-])", caseInsensitive: true)
    }

    /// Whether a position may be inside quoted speech, failing closed (memory processing §11.3): reading the text up
    /// to there (a quote may run across lines), a quote opens at the line's start or after a space or opening punctuation (“, ‘, «, ‹ and „ always
    /// open), and closes only where it surely does: ”, », › always (“ or ” after „); " before a space, punctuation or the end; ' or ’ the same, but not
    /// after an s ("the kids' teacher" may be a possessive) or between letters ("doesn't"). A quote still open, or
    /// one whose end is uncertain, means the position may be quoted. An inch mark (27") or an apostrophe doesn't open.
    static func mayBeQuoted(_ text: String, at pos: Int) -> Bool {
        let ns = text as NSString
        func ch(_ i: Int) -> unichar? { i >= 0 && i < ns.length ? ns.character(at: i) : nil }
        func isSpace(_ c: unichar?) -> Bool { c.map { $0 == 32 || $0 == 9 || $0 == 10 || $0 == 0xA0 } ?? true }
        func opensAfter(_ c: unichar?) -> Bool { c == nil || isSpace(c) || [40, 91, 58, 44, 0x2014, 0x2013].contains(c!) }
        func closesBefore(_ c: unichar?) -> Bool { c == nil || isSpace(c) || [46, 44, 59, 58, 33, 63, 41, 93].contains(c!) }
        func isLetter(_ c: unichar?) -> Bool { c.map { CharacterSet.alphanumerics.contains(Unicode.Scalar($0) ?? " ") } ?? false }
        // A dialogue dash at the start of the phrase's line ("—Mi jefe llega tarde —dijo Ana") is someone speaking.
        var lineStart = pos
        while lineStart > 0, ns.character(at: lineStart - 1) != 10 { lineStart -= 1 }
        var k = lineStart
        while let c = ch(k), c == 32 || c == 9 { k += 1 }
        if let c = ch(k), c == 0x2014 || c == 0x2013 || c == 0x2015 { return true }
        enum Kind { case double, curlyDouble, single, guillemet, singleGuillemet, low }
        var open: Kind?
        var i = 0                  // a quote may run across lines: read the text from its start
        while i < pos {
            let c = ns.character(at: i), prev = ch(i - 1), next = ch(i + 1)
            switch (open, c) {
            case (nil, 0x00AB): open = .guillemet
            case (nil, 0x2039): open = .singleGuillemet
            case (nil, 0x201E): open = .low
            case (.guillemet?, 0x00BB), (.singleGuillemet?, 0x203A), (.low?, 0x201C), (.low?, 0x201D): open = nil
            case (nil, 0x201C): open = .curlyDouble
            case (nil, 0x2018): open = .single
            case (nil, 34) where opensAfter(prev): open = .double
            case (nil, 39) where opensAfter(prev), (nil, 0x2019) where opensAfter(prev): open = .single
            case (.curlyDouble?, 0x201D): open = nil
            case (.double?, 34) where closesBefore(next): open = nil
            case (.single?, 39), (.single?, 0x2019):
                if closesBefore(next), !(isLetter(prev) && isLetter(next)), prev != 115, prev != 83 { open = nil }
            default: break
            }
            i += 1
        }
        return open != nil
    }

    /// What follows a possessive ("my sister's very kind husband"): up to four words, read up to a function word or
    /// an owner ("my boss's note to my sister" is the boss's note).
    private static let chainRE = FactsText.regex("['’]s((?:\\s+\\w[\\w-]*){1,4})")

    var personNouns: Set<String> {
        Set(registry.lexicon.filter { registry.kindOf($0.value.predicate) == "person" }.map(\.key))
            .union(registry.language.personNouns)
    }

    /// Role phrases in a text, optionally only of some predicates, and only of predicates whose `recorded` is on
    /// (§11.10: one that's off isn't read, asked or resolved). Quoted text and chains ("my sister's husband") are skipped.
    public func rolePhrases(_ text: String, predicates: Set<String>? = nil) -> [RolePhrase] {
        let recorded = Set(uses.predicates(.recorded))
        let predicates = predicates.map { $0.intersection(recorded) } ?? recorded
        let lang = registry.language
        let ns = text as NSString
        let nouns = personNouns
        // A person noun with a former prefix is still one ("my partner's ex-wife").
        let attached = lang.formerPrefixes.filter { !$0.hasSuffix(" ") }.map { $0.lowercased() }
        func unprefixed(_ w: String) -> String {
            for p in attached where w.hasPrefix(p) && w.count > p.count { return String(w.dropFirst(p.count)) }
            return w
        }
        let chainStops = Set((lang.functionWords + lang.owners.map { String($0.split(separator: " ")[0]) }).map { FactsText.fold($0) })
        let lex = registry.lexicon
        let preps = lang.timePrepositions.map(FactsText.escape).joined(separator: "|")
        let joiners = lang.dateJoiners.map(FactsText.escape).joined(separator: "|")
        // A date as the parser reads it: a year, a month and year, or a day ("15 March 2019", "March 15, 2019",
        // "2019-03-15").
        let ords = lang.ordinalSuffixes.map(FactsText.escape).joined(separator: "|")
        let month = "(?:" + parser.monthPattern + ")\\.?"
        let day = "\\d{1,2}(?:" + ords + ")?"
        // Day forms: "15 March 2019", "15th March 2019", "March 15, 2019", "2019-03-15".
        let dayDate = "(?:19|20)\\d{2}-\\d{1,2}-\\d{1,2}|" + day + "\\s+(?:(?:" + joiners + ")\\s+)?" + month + "\\s+(?:(?:" + joiners
            + ")\\s+)?(?:19|20)\\d{2}|" + month + ",?\\s+" + day + ",?\\s+(?:(?:" + joiners + ")\\s+)?(?:19|20)\\d{2}"
        // Any precision after a time preposition ("in 2019", "in March 2019"); only a day after a day preposition
        // ("on 15 March 2019"; "on 2019 numbers" isn't a date).
        let anyDate = dayDate + "|(?:" + month + ",?\\s+(?:(?:" + joiners + ")\\s+)?)?(?:19|20)\\d{2}"
        let dayPreps = lang.dayPrepositions.map(FactsText.escape).joined(separator: "|")
        let dateRE = "(?:(?:" + preps + ")\\s+(" + anyDate + ")" + (dayPreps.isEmpty ? "" : "|(?:" + dayPreps + ")\\s+(" + dayDate + ")") + ")"
        let cueAfter = FactsText.regex("\\s+" + dateRE + "\\b", caseInsensitive: true)
        let cueBefore = FactsText.regex("\\b" + dateRE + ",?\\s*$", caseInsensitive: true)
        let abbrevPeriods = Set(FactsText.matches(FactsText.regex("\\b(?:" + parser.monthPattern + ")(\\.)", caseInsensitive: true), in: text)
            .map { $0.groups[0].location })
        let sentenceBreaks = (0..<ns.length).filter { i in
            let c = ns.character(at: i)
            return (c == 46 && !abbrevPeriods.contains(i)) || c == 33 || c == 63 || c == 10   // . ! ? newline
        }
        var out: [RolePhrase] = []
        for mt in FactsText.matches(rolePattern(), in: text) {
            let s = mt.start, e = mt.end
            if Self.mayBeQuoted(text, at: s) { continue }
            if let chain = FactsText.matchAt(Self.chainRE, in: text, from: e, to: min(e + 60, ns.length)),
               (chain.group(1) ?? "").split(whereSeparator: \.isWhitespace).map({ $0.lowercased() })
                   .prefix(while: { !chainStops.contains(FactsText.fold($0)) }).contains(where: { nouns.contains(unprefixed($0)) }) {
                continue
            }
            let word = mt.group(5)!.lowercased()
            guard let meaning = lex[word] else { continue }
            if !predicates.contains(meaning.predicate) { continue }
            let mods = mt.group(2)!.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let free = mt.group(3)!.trimmingCharacters(in: .whitespaces).lowercased()
            // Sentence bounds, where a month abbreviation's period ("Mar. 2019") doesn't end a sentence.
            let bounds = sentenceBreaks
            let a = (bounds.filter { $0 < s }.max().map { $0 + 1 }) ?? 0
            let b = bounds.filter { $0 >= e }.min() ?? ns.length
            var cue: String?
            if !preps.isEmpty {
                // a time cue only next to the phrase: "my boss in 2019", "In 2019, my boss" (not "…sales dropped in 2019")
                let m = FactsText.matchAt(cueAfter, in: text, from: e, to: max(e, b)) ?? FactsText.first(cueBefore, in: text, from: a, to: s)
                cue = m?.group(1) ?? m?.group(2)
            }
            let paired = registry.kindOf(meaning.predicate) == "person" ? pairedName(text, s, e) : nil
            let former = meaning.status == "former" || !(mt.group(4) ?? "").isEmpty || mods.contains { registry.formerCues.contains($0) }
            let current = mods.contains { registry.currentCues.contains($0) }
            out.append(RolePhrase(start: s, end: e, surface: ns.substring(with: mt.range), word: word,
                                  predicate: meaning.predicate, cls: meaning.cls, generic: meaning.generic, mods: mods,
                                  timeCue: cue, qual: free.isEmpty ? nil : free, paired: paired, plural: meaning.plural,
                                  exclusiveLabel: meaning.exclusiveLabel, former: former, current: current,
                                  statusWord: meaning.status == "former"))
        }
        return out
    }

    private static let namePattern = "[A-ZÁÉÍÓÚÑ][\\w'-]+(?:\\s+[A-ZÁÉÍÓÚÑ][\\w'-]+)?"
    private static let possessive = FactsText.regex("['’]s$")

    /// A name the text ties to the phrase, by the registry's first-person pair templates ("Maria is my sister", "my
    /// sister(,) Maria", "my sister is Maria"). A proposal; code applies it only as §11.6 says.
    func pairedName(_ text: String, _ s: Int, _ e: Int) -> String? {
        let lang = registry.language
        let verbs = lang.pairBefore.map(FactsText.escape).joined(separator: "|")
        let advs = lang.pairAdverbs.map(FactsText.escape).joined(separator: "|")
        let after = lang.pairAfter.map(FactsText.escape).joined(separator: "|")
        let candidates = [
            FactsText.first(FactsText.regex("(" + Self.namePattern + ")\\s+(?:" + verbs + ")(?:\\s+(?:" + advs + "))?\\s+$"),
                            in: text, from: 0, to: s),
            FactsText.matchAt(FactsText.regex(",?\\s+(" + Self.namePattern + ")"), in: text, from: e),
            FactsText.matchAt(FactsText.regex("\\s+(?:" + after + ")\\s+(" + Self.namePattern + ")(?=[\\s.,;:!?]|$)"),
                              in: text, from: e),
        ]
        let users = Set(userAliases.map { FactsText.fold($0) })
        let notNames = Set(lang.notNames.map { FactsText.fold($0) })
        for m in candidates {
            guard let m, let raw = m.group(1) else { continue }
            let name = Self.possessive.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: FactsText.length(raw)),
                                                                withTemplate: "")
            let f = FactsText.fold(name)
            if name.count >= 2, !users.contains(f), !notNames.contains(f) { return name }
        }
        return nil
    }

    /// Whether a name is only a role phrase ("my sister", "my older brother"): never a person's name.
    public func isRoleName(_ name: String) -> Bool {
        let lang = registry.language
        let owners = Set(lang.owners.flatMap { $0.split(separator: " ").map { FactsText.fold(String($0)) } })
            .union(lang.ownerWords.map { FactsText.fold($0) })
        let words = FactsText.fold(name).replacingOccurrences(of: "’", with: "'").split(separator: " ").map(String.init)
        guard let first = words.first, owners.contains(first) else { return false }
        let rest = words.dropFirst().filter { !owners.contains($0) }
        guard let last = rest.last, registry.lexicon[last] != nil else { return false }
        let mods = Set(lang.modifiers)
        return rest.dropLast().allSatisfy { mods.contains($0) }
    }

    // MARK: Holders and resolution (memory processing §11.6)

    /// When a role phrase talks about: a time cue next to it, or the memory's date (none for an imported note).
    /// Also returns the written date, which "former" is judged against.
    func asOf(_ mem: FactsMemory, _ ph: RolePhrase) -> (DateRange?, written: DateRange?) {
        let w = mem.source == .import ? nil : parser.day(mem.written).map { DateRange.day($0) }
        if let cue = ph.timeCue { return (parser.parse(cue), w) }
        return (w, w)
    }

    /// Whether episode e may hold a role phrase's role during d (nil: now). "Current" and plain phrases are evaluated
    /// at d; "former" is relative to when the memory was written, and it held during the time cue, if there is one.
    func holds(_ e: Episode, _ ph: RolePhrase, _ d: DateRange?, deceased: Bool, written: DateRange?) -> Bool {
        if ph.former {
            let w = written ?? (ph.timeCue != nil ? nil : d)
            let ended = (e.former || e.inferredEnd) && (w == nil || e.end == nil || e.end!.lo <= w!.hi)
            return ended && (ph.timeCue == nil || d == nil || e.mayHold(d!))
        }
        guard let d else { return (e.ongoing && !e.inferredEnd) || (deceased && !e.former) }
        if e.handover, let s = e.start, s.lo > d.hi { return false }   // a new holder announced later
        if e.uncertain, let from = e.uncertainFrom, d.lo > from { return false }   // after a memory that may have ended it
        if let end = e.end, end.hi < d.lo { return false }   // a conflicting end's latest day still bounds it
        return true
    }

    struct Holders {
        var holders: [(entity: FactsEntity, fact: LearnedFact)]
        var extra: Int                   // more holders a group count says exist
        var episodes: [String: Episode]  // the episode each holder holds through
    }

    /// Who may hold a role phrase's role at a time, from episodes.
    func holders(_ ph: RolePhrase, asOf d: DateRange?, written: DateRange?, rejected: Set<String> = []) -> Holders {
        let eps = episodes(ph.predicate)
        var out: [(entity: FactsEntity, fact: LearnedFact)] = [], seen = Set<String>(), holdEps: [String: Episode] = [:]
        for r in facts {
            if r.negated || r.predicate != ph.predicate || seen.contains(r.entity) || rejected.contains(r.entity) { continue }
            if !ph.statusWord, !ph.generic, r.cls != nil, r.cls != ph.cls { continue }
            if let qual = ph.qual, let label = r.label, FactsText.fold(label) != FactsText.fold(ph.word),
               !FactsText.fold(label).contains(FactsText.fold(qual)) {
                continue
            }
            guard let ent = entities[r.entity] else { continue }
            let ok = eps.filter { $0.entity == r.entity }.reversed()
                .filter { holds($0, ph, d, deceased: ent.deceased, written: written) }
            guard let e = ok.first(where: { d != nil && $0.mayHold(d!) }) ?? ok.first else { continue }
            seen.insert(r.entity)
            holdEps[r.entity] = e
            out.append((ent, r))
        }
        // Only trusted evidence may say someone certainly held it, and so rule other holders out.
        if let d, out.contains(where: { h in
            let e = holdEps[h.entity.id]!
            return e.certainlyHolds(d) && e.trusted && e.startTrusted && (e.end == nil || e.endTrusted)
        }) {
            // someone certainly held it then: a holder whose stated start comes later isn't a candidate
            out = out.filter { h in
                let e = holdEps[h.entity.id]!
                return !(e.statedStart && e.startTrusted && e.start!.lo > d.hi)   // an untrusted start rules no one out
            }
        }
        var extra = 0
        if !ph.generic, let gid = groups[FactsEntity.RoleGroup(predicate: ph.predicate, cls: ph.cls)],
           let count = entities[gid]?.count {
            extra = max(0, count - out.count)
        }
        return Holders(holders: out, extra: extra, episodes: holdEps)
    }

    /// Who a role phrase in a memory refers to, and why (memory processing §11.6).
    public mutating func resolve(_ mem: FactsMemory, _ ph: RolePhrase) -> (entity: String?, basis: LinkBasis) {
        let key = DecisionKey(memoryID: mem.id, start: ph.start)
        // §11.10, before any stored decision: a predicate that isn't recorded resolves nothing, and a time cue ("my
        // previous job") of a predicate whose timeline is declared but off resolves nothing either.
        if !uses.isOn(ph.predicate, .recorded) { return (nil, .candidates) }
        let dateCue = ph.mods.contains(where: { registry.language.dateCueWords.contains($0) })
        if dateCue, registry.declares(ph.predicate, .timeline), !uses.isOn(ph.predicate, .timeline) { return (nil, .candidates) }
        if let dec = decisions[key], !(dec.basis == .group && entity(dec.entity)?.name != nil),
           !(dec.entity.map { rejections[key]?.contains($0) ?? false } ?? false) {     // a correction beats a decision
            if dec.basis == .someoneElse { return (nil, .someoneElse) }
            // A decision can't lift what it chose above that entity's evidence: untrusted facts give an untrusted link.
            // Judged by the episodes that may hold then, not the fact as a whole: an old trusted stint doesn't vouch for
            // an untrusted new one.
            if dec.basis == .context, let e = dec.entity {
                let (d, written) = asOf(mem, ph)
                let mine = episodes(ph.predicate).filter { $0.entity == e }
                // The episode `holders` would pick: the one that may hold then, latest first.
                let held = mine.reversed().filter { holds($0, ph, d, deceased: entities[e]?.deceased ?? false, written: written) }
                let chosen = held.first(where: { d != nil && $0.mayHold(d!) }) ?? held.first ?? mine.last
                if let chosen, !(chosen.trusted && chosen.startTrusted) { return (e, .untrusted) }
                // As weak as its weakest step: a "former" resting on an inferred end, or a rival ruled out by one.
                if (chosen?.inferredEnd == true && ph.former) || episodes(ph.predicate).contains(where: { o in
                    o.entity != e && o.inferredEnd && (d == nil || (o.tstart.map { $0.lo <= d!.hi } ?? true))
                }) {
                    return (e, .inferred)
                }
            }
            return (dec.entity, dec.basis)
        }
        let rejected = rejections[key] ?? []
        if ph.plural {
            let g = groupFor(ph.predicate, nil)
            return rejected.contains(g) ? (nil, .candidates) : (g, .group)
        }
        if dateCue, uses.isOn(ph.predicate, .timeline) {
            if mem.source == .import { return (nil, .candidates) }   // an imported note's "previous" has no date
            if let got = previousLink(ph.predicate, written: mem.written) {
                if rejected.contains(got.entity) { return (nil, .candidates) }      // "Not <name>" holds on every path
                return (got.entity, mem.trusted && got.trusted ? .inferred : .untrusted)   // as weak as its weakest step
            }
            return (nil, .candidates)
        }
        let (d, written) = asOf(mem, ph)
        let h = holders(ph, asOf: d, written: written, rejected: rejected)
        guard let (p, r) = h.holders.first else {
            let g = groupFor(ph.predicate, ph.generic ? nil : ph.cls)
            return rejected.contains(g) ? (nil, .candidates) : (g, .group)
        }
        if h.holders.count + h.extra > 1 { return (nil, .candidates) }
        let e = h.episodes[p.id]
        if !mem.trusted || !(e?.trusted ?? r.trusted) {
            return (p.id, .untrusted)        // the episode it rests on has only untrusted evidence
        }
        if let e, let d, e.statedStart, e.start!.lo > d.hi {
            return (p.id, .soleKnown)        // a reference before a stated start: probably, not certainly
        }
        // A link resting on succession (the holder ended by inference, or a rival ruled out because its end was inferred)
        // is inferred at best.
        let rivalsInferred = episodes(ph.predicate).contains { o in
            o.entity != p.id && o.inferredEnd && (d == nil || (o.tstart.map { $0.lo <= d!.hi } ?? true))
        }
        if (e?.inferredEnd == true && ph.former) || rivalsInferred { return (p.id, .inferred) }
        let exclusive = registry.predicate(ph.predicate)?.exclusive ?? false
        let group = groups[FactsEntity.RoleGroup(predicate: ph.predicate, cls: ph.cls)].flatMap { entities[$0] }
        var unique = ph.mods.contains { registry.language.onlyWords.contains($0) } || r.only || exclusive
            || ph.exclusiveLabel || group?.count == 1
        if r.cls == nil, !ph.generic { unique = false }
        return (p.id, unique ? .statedUnique : .soleKnown)
    }
}
