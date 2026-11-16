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

    private static let quoteRE = FactsText.regex("(?:^|(?<=[\\s:,]))['\"“‘]([^'\"”’]+)['\"”’](?=[\\s.,;:!?]|$)")
    private static let chainRE = FactsText.regex("['’]s\\s+(\\w[\\w-]*)(?:\\s+(\\w[\\w-]*))?")

    var personNouns: Set<String> {
        Set(registry.lexicon.filter { registry.kindOf($0.value.predicate) == "person" }.map(\.key))
            .union(registry.language.personNouns)
    }

    /// Role phrases in a text, optionally only of some predicates. Quoted text and chains ("my sister's husband") are
    /// skipped.
    public func rolePhrases(_ text: String, predicates: Set<String>? = nil) -> [RolePhrase] {
        let lang = registry.language
        let ns = text as NSString
        let quoted = FactsText.matches(Self.quoteRE, in: text).map { $0.groups[0] }
        let nouns = personNouns
        let lex = registry.lexicon
        let preps = lang.timePrepositions.map(FactsText.escape).joined(separator: "|")
        let joiners = lang.dateJoiners.map(FactsText.escape).joined(separator: "|")
        let dateRE = "(?:" + preps + ")\\s+((?:(?:" + parser.monthPattern + ")\\.?\\s+(?:(?:" + joiners
            + ")\\s+)?)?(?:19|20)\\d{2})"
        let cueAfter = FactsText.regex("\\s+" + dateRE + "\\b", caseInsensitive: true)
        let cueBefore = FactsText.regex("\\b" + dateRE + ",?\\s*$", caseInsensitive: true)
        var out: [RolePhrase] = []
        for mt in FactsText.matches(rolePattern(), in: text) {
            let s = mt.start, e = mt.end
            if quoted.contains(where: { $0.location != NSNotFound && $0.location <= s && s < $0.location + $0.length }) {
                continue
            }
            if let chain = FactsText.matchAt(Self.chainRE, in: text, from: e, to: min(e + 40, ns.length)),
               [chain.group(1), chain.group(2)].contains(where: { $0.map { nouns.contains($0.lowercased()) } ?? false }) {
                continue
            }
            let word = mt.group(5)!.lowercased()
            guard let meaning = lex[word] else { continue }
            if let predicates, !predicates.contains(meaning.predicate) { continue }
            let mods = mt.group(2)!.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let free = mt.group(3)!.trimmingCharacters(in: .whitespaces).lowercased()
            let a = [".", "!", "?", "\n"].map { ns.range(of: $0, options: .backwards, range: NSRange(location: 0, length: s)).location }
                .filter { $0 != NSNotFound }.max().map { $0 + 1 } ?? 0
            let b = [".", "!", "?", "\n"].map { ns.range(of: $0, range: NSRange(location: e, length: ns.length - e)).location }
                .filter { $0 != NSNotFound }.min() ?? ns.length
            var cue: String?
            if !preps.isEmpty {
                // a time cue only next to the phrase: "my boss in 2019", "In 2019, my boss" (not "…sales dropped in 2019")
                cue = (FactsText.matchAt(cueAfter, in: text, from: e, to: max(e, b))
                       ?? FactsText.first(cueBefore, in: text, from: a, to: s))?.group(1)
            }
            let paired = registry.kindOf(meaning.predicate) == "person" ? pairedName(text, s, e) : nil
            let former = meaning.status == "former" || mt.group(4) != nil || mods.contains { registry.formerCues.contains($0) }
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
        if let end = e.end, end.hi < d.lo { return false }
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
        if let d, out.contains(where: { holdEps[$0.entity.id]!.certainlyHolds(d) }) {
            // someone certainly held it then: a holder whose stated start comes later isn't a candidate
            out = out.filter { h in
                let e = holdEps[h.entity.id]!
                return !(e.statedStart && e.start!.lo > d.hi)
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
        if let dec = decisions[key], !(dec.basis == .group && entity(dec.entity)?.name != nil),
           !(dec.entity.map { rejections[key]?.contains($0) ?? false } ?? false) {     // a correction beats a decision
            return dec.basis == .someoneElse ? (nil, .someoneElse) : (dec.entity, dec.basis)
        }
        if ph.plural { return (groupFor(ph.predicate, nil), .group) }
        if ph.mods.contains(where: { registry.language.dateCueWords.contains($0) }), registry.uses(ph.predicate, "timeline") {
            if mem.source == .import { return (nil, .candidates) }   // an imported note's "previous" has no date
            if let got = previousAsOf(ph.predicate, written: mem.written) {
                return (got, mem.trusted ? .inferred : .untrusted)   // a link is as weak as the weakest step in it
            }
            return (nil, .candidates)
        }
        let (d, written) = asOf(mem, ph)
        let h = holders(ph, asOf: d, written: written, rejected: rejections[key] ?? [])
        guard let (p, r) = h.holders.first else {
            return (groupFor(ph.predicate, ph.generic ? nil : ph.cls), .group)
        }
        if h.holders.count + h.extra > 1 { return (nil, .candidates) }
        let e = h.episodes[p.id]
        if !mem.trusted || !(e?.trusted ?? r.trusted) {
            return (p.id, .untrusted)        // the episode it rests on has only untrusted evidence
        }
        if let e, let d, e.statedStart, e.start!.lo > d.hi {
            return (p.id, .soleKnown)        // a reference before a stated start: probably, not certainly
        }
        let exclusive = registry.predicate(ph.predicate)?.exclusive ?? false
        let group = groups[FactsEntity.RoleGroup(predicate: ph.predicate, cls: ph.cls)].flatMap { entities[$0] }
        var unique = ph.mods.contains { registry.language.onlyWords.contains($0) } || r.only || exclusive
            || ph.exclusiveLabel || group?.count == 1
        if r.cls == nil, !ph.generic { unique = false }
        return (p.id, unique ? .statedUnique : .soleKnown)
    }
}
