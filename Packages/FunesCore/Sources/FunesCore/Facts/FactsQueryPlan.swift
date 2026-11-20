import Foundation

/// What a search names of learned facts (memory processing §4, §11.4, §11.7), all code, no model call: the entities
/// its names, aliases and role phrases match, a timeline question's answer, and the rest of the query.
public struct FactsQueryPlan: Sendable, Equatable {
    /// How the query matched an entity.
    public struct Match: Sendable, Equatable {
        public enum Via: String, Sendable { case name, role }
        public var entity: String
        public var via: Via
        /// The query's words that matched (UTF-16 range in the query).
        public var start: Int
        public var end: Int
        /// For a role phrase: how sure the query's phrase is of this holder (`candidates` when several hold the role,
        /// `group` for the role group), its predicate and its word.
        public var basis: LinkBasis
        public var predicate: String?
        public var word: String?
    }

    /// A timeline question's answer (§11.6): the answer's entities when it's decided, and the anchor's entity.
    public struct Timeline: Sendable, Equatable {
        public var predicate: String
        public var op: TimelineIntent.Operator
        public var anchor: String?
        public var answer: [String]
        public var basis: TimelineBasis
        /// The operator as the query wrote it ("before"), for the why line.
        public var opWords: String

        /// Decided: one or more entities, not told.
        public var decided: Bool { !answer.isEmpty && ![.ambiguous, .unknown].contains(basis) }
    }

    public var matches: [Match] = []
    public var timeline: Timeline?
    /// The query without the matched names and role phrases ("" when no searchable word is left).
    public var rest = ""

    /// The entities matched, by name or role (a timeline anchor isn't: its memories drop instead).
    public var matched: Set<String> { Set(matches.map(\.entity)).subtracting(timeline?.anchor.map { [$0] } ?? []) }

    /// Nothing named and no timeline question: search is unchanged.
    public var isEmpty: Bool { matches.isEmpty && timeline == nil }
}

extension FactsSearchIndex {
    /// The plan for a query, as of `today` (an ISO day): what "my sister" means now.
    func plan(_ query: String, today: String) -> FactsQueryPlan {
        var plan = FactsQueryPlan()
        guard !isEmpty else { return plan }
        let g = graph
        var taken: [NSRange] = []
        func overlaps(_ r: NSRange) -> Bool { taken.contains { NSIntersectionRange($0, r).length > 0 } }

        // Names: longest first, no overlaps; a shared name matches everyone who has it.
        for m in nameMatches(query) where !overlaps(NSRange(location: m.start, length: m.end - m.start)) {
            taken.append(NSRange(location: m.start, length: m.end - m.start))
            for e in m.entities {
                plan.matches.append(.init(entity: e, via: .name, start: m.start, end: m.end, basis: .named, predicate: nil, word: nil))
            }
        }

        // Role phrases, read as in memories (chains and quoted speech skipped), resolved as of today or the phrase's own
        // time cue. One holder: it; several: all of them, as candidates; none: the role group.
        let phrasePredicates = linked.intersection(g.uses.predicates(.recorded))
        if !phrasePredicates.isEmpty {
            let asked = FactsMemory(id: Self.queryID, text: query, written: today, source: .capture, trusted: true)
            for ph in g.rolePhrases(query, predicates: phrasePredicates) {
                let r = NSRange(location: ph.start, length: ph.end - ph.start)
                guard !overlaps(r) else { continue }
                var copy = g            // `resolution` may make a role group; the index's graph stays as built
                let res = copy.resolution(asked, ph)
                var found: [(String, LinkBasis)] = []
                if let entity = res.entity, eligible.contains(entity) {
                    found = [(entity, res.basis)]
                } else if res.entity == nil, res.basis == .candidates {
                    found = res.candidates.filter(eligible.contains).map { ($0, LinkBasis.candidates) }
                }
                guard !found.isEmpty else { continue }
                taken.append(r)
                for (e, b) in found {
                    plan.matches.append(.init(entity: e, via: .role, start: ph.start, end: ph.end, basis: b,
                                              predicate: ph.predicate, word: ph.word))
                }
            }
        }

        // A timeline question (only predicates whose timeline is on, §11.10).
        if let it = g.intent(query) {
            let answer = g.answer(it, query: query)
            var anchor: String?
            if case let .entity(e)? = it.anchor { anchor = e }
            plan.timeline = .init(predicate: it.predicate, op: it.op, anchor: anchor, answer: answer.entities,
                                  basis: answer.basis, opWords: Self.operatorWords(it, graph: g))
        }

        plan.rest = Self.rest(query, removing: taken, functionWords: Set(g.registry.language.functionWords.map { FactsText.fold($0) }))
        return plan
    }

    /// The operator as the registry lists it that the question used ("before", "antes de"), for the why line.
    static func operatorWords(_ it: TimelineIntent, graph g: FactsGraph) -> String {
        let ops = it.op == .before ? g.registry.language.operators.before : it.op == .after ? g.registry.language.operators.after : []
        let phrase = it.phrase ?? ""
        return ops.sorted { $0.count > $1.count }.first { FactsText.has(phrase, $0) } ?? it.op.rawValue
    }

    /// The id the query stands under when its role phrases are resolved: never a memory's.
    static let queryID = "\u{1F}query"

    /// The query without the matched spans, a possessive left behind, and punctuation; "" when no word search indexes is
    /// left ("my sister?" has nothing more to say).
    static func rest(_ query: String, removing spans: [NSRange], functionWords: Set<String> = []) -> String {
        var s = query as NSString
        for r in spans.sorted(by: { $0.location > $1.location }) {
            s = s.replacingCharacters(in: r, with: " ") as NSString
        }
        var out = s as String
        out = FactsText.regex("(^|\\s)['’]s\\b").stringByReplacingMatches(in: out, range: NSRange(location: 0, length: FactsText.length(out)),
                                                                        withTemplate: "$1")
        out = FactsText.regex("[¿?¡!,.;:]").stringByReplacingMatches(in: out, range: NSRange(location: 0, length: FactsText.length(out)),
                                                                   withTemplate: " ")
        // The registry's function words go too (search.py's ES_STOP): "de mi hermana" leaves nothing to search.
        out = out.split(whereSeparator: \.isWhitespace).filter { !functionWords.contains(FactsText.fold(String($0))) }
            .joined(separator: " ")
        return KeywordSearch.terms(out).isEmpty ? "" : out
    }

    /// Names and aliases of usable named entities in a query (memory processing §11.4's matching cases):
    /// - whole words, case and accents ignored, longest first, at least 3 letters, a possessive allowed ("Lucía's");
    /// - a person's first name alone matches everyone who has it as a first name (the kind's `first_name` rule);
    /// - a stop name ("Will", "May") only written with a capital, and not as a sentence's first word unless it's the
    ///   whole query or a possessive ("May's"): "in may", "Will you…" match nobody;
    /// - your own names never match, and a function word or search stop word is never a name;
    /// - a trusted alias, or any alias of an entity no trusted memory named (the query is yours, §11.4's alias trust).
    func nameMatches(_ query: String) -> [(start: Int, end: Int, entities: [String])] {
        let g = graph, reg = g.registry
        let users = Set(g.userAliases.map { FactsText.fold($0) })
        let stopNames = Set(reg.language.stopNames.map { FactsText.fold($0) })
        // A stop name ("Will") reaches its own rule below rather than being dropped as a function word.
        let stop = Set(reg.language.functionWords.map { FactsText.fold($0) }).union(KeywordSearch.stopwords).subtracting(stopNames)
        var byAlias: [String: Set<String>] = [:]
        for id in eligible.sorted() {
            guard let e = g.entities[id], e.name != nil else { continue }
            let aliases = e.trustedAliases.isEmpty ? e.aliases : e.trustedAliases
            let forms = aliases.map { FactsText.normName($0, kind: e.kind, registry: reg) }
            var keys = Set(forms)
            if reg.kinds[e.kind]?.match == "first_name" {
                for f in forms where f.split(separator: " ").count > 1 { keys.insert(String(f.split(separator: " ")[0])) }
            }
            for k in keys where k.count >= 3 && !users.contains(k) && !stop.contains(k) {
                byAlias[k, default: []].insert(id)
            }
        }
        let folded = FactsText.foldedWithMap(query)
        let ns = query as NSString
        var takenFolded: [NSRange] = []
        var out: [(Int, Int, [String])] = []
        for alias in byAlias.keys.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }) {
            let re = FactsText.regex("(?<![\\w])" + FactsText.escape(alias) + "(?:['’]s)?(?![\\w])")
            for m in FactsText.matches(re, in: folded.text) {
                guard !takenFolded.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { continue }
                let o = folded.original(m.start)
                let e = folded.original(m.end)
                if stopNames.contains(alias) {
                    let first = ns.character(at: o)
                    let capital = CharacterSet.uppercaseLetters.contains(Unicode.Scalar(first) ?? " ")
                    let before = ns.substring(to: o).trimmingCharacters(in: .whitespaces)
                    let atStart = before.isEmpty || "\n.!?¿¡".contains(before.last ?? " ")
                    let written = ns.substring(with: NSRange(location: o, length: e - o))
                    let owned = written.hasSuffix("'s") || written.hasSuffix("’s")
                    let after = ns.substring(from: e).trimmingCharacters(in: CharacterSet(charactersIn: "?!. \n"))
                    if !capital || (atStart && !owned && !after.isEmpty) { continue }
                }
                takenFolded.append(m.range)
                // The match without a possessive: what the query names.
                var end = e
                let tail = ns.substring(with: NSRange(location: o, length: e - o))
                if tail.hasSuffix("'s") || tail.hasSuffix("’s") { end -= 2 }
                out.append((o, end, byAlias[alias]!.sorted()))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
