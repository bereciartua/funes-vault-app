import CryptoKit
import Foundation

/// The predicate registry (ADR-0032 decision 2, memory processing §11.2): what each kind of fact about you means and
/// how it's used, as data. Every part of `Facts/` reads it; no code names a predicate or carries its words.
public struct FactsRegistry: Sendable, Decodable {
    public let version: String
    public let language: Language
    public let kinds: [String: Kind]
    public let callGroups: [String: CallGroup]
    public let predicates: [Predicate]
    /// The uses a predicate can have and what each needs on first (memory processing §11.10): turning a use off turns
    /// off everything that needs it, with no code change.
    public let useRules: [String: UseRule]
    /// Each predicate's qualifier keys in the order the JSON gives them (the prompt and schema list them in it).
    public internal(set) var qualifierOrder: [String: [String]] = [:]
    /// The registry version a qualification record names (§11.10): the version label and a digest of the whole
    /// registry except each predicate's `uses` list. Every group's validation and parsing read the shared language and
    /// the whole lexicon, so any other change re-runs every gate; a `uses` list is in the record's key already.
    public internal(set) var fingerprint: String = ""
    /// Each call group's extraction digest (memory processing §11.3's registry rule): the registry as that group's
    /// readings depend on it, without what only questions read. With the group's prompt version it makes the key a
    /// model reading records (`FactsExtractor.readKey`), so a language-only change re-reads nothing.
    public internal(set) var extractionDigests: [String: String] = [:]
    /// `lexicon`, built once when the registry is decoded (search reads it for every memory).
    var lexiconTable: [String: Word]?

    enum CodingKeys: String, CodingKey { case version, language, kinds, callGroups, predicates, useRules = "uses" }

    public struct UseRule: Sendable, Decodable {
        public let requires: [String]
    }

    /// Language data shared by every predicate.
    public struct Language: Sendable, Decodable {
        public let owners: [String]
        public let ownerWords: [String]
        public let statusCues: StatusCues
        public let modifiers: [String]
        public let onlyWords: [String]
        public let dateCueWords: [String]
        public let operators: Operators
        public let episodeFirst: [String]
        public let episodeLast: [String]
        public let episodeOrdinals: [String: Int]
        public let pairBefore: [String]
        public let pairAfter: [String]
        public let pairAdverbs: [String]
        public let notNames: [String]
        public let stopNames: [String]
        public let personNouns: [String]
        public let formerPrefixes: [String]
        public let formerWords: [String]
        public let anchorTailWords: [String]
        public let anchorDeterminers: [String]
        /// Words that may stand between an operator and its anchor ("before I joined Acme"); anything else means no
        /// timeline intent (memory processing §11.7: a question outside the grammar fails closed).
        public let anchorLeadWords: [String]
        /// Words naming a fact's start or end ("joined", "left"): "before leaving Acme" and "after joining Acme" name an
        /// event the anchor can't stand for (it means the stint), so they get no intent.
        public let startEvents: [String]
        public let endEvents: [String]
        /// Words a user's own question may open with, before its operator ("Where did I work…", "¿Dónde trabajaba…").
        public let questionWords: [String]
        /// What may open a question's year with no operator: "in 2016" (`yearPrepositions`), or a span of two dates,
        /// "between 2014 and 2016" (`rangePrepositions` too). "Since 2016" and "until 2016" aren't the year itself.
        public let yearPrepositions: [String]
        public let rangePrepositions: [String]
        /// Contracted function words, expanded before a question is read ("del" is "de el").
        public let contractions: [String: String]
        public let timePrepositions: [String]
        public let dayPrepositions: [String]
        public let returnCues: [String]
        public let timeNouns: [String]
        public let thirdPerson: [String]
        public let firstPerson: [String]
        public let months: [String: [String]]
        /// Day names: never the start of a surname after a profile name (the profile matcher, memory processing §11.3).
        public let weekdays: [String]?
        /// Adverbs a timeline question may put right before its operator ("immediately before", "justo antes de"); they
        /// leave its meaning as it is. Optional: a registry without them reads such a question as no intent.
        public let operatorAdverbs: [String]?
        /// The question words an operator adverb needs in its clause ("Where did I work immediately before Acme?"): without
        /// one, "Did I start work immediately after Acme?" asks about a gap, not for the next job.
        public let whWords: [String]?
        /// Nouns that make a role word part of a compound, not a role ("my parent company", "my sister company", "my
        /// friend group"): a lexicon word right before one isn't a role phrase. Optional (13a.2's fix round).
        public let compoundHeads: [String]?
        /// Words that make a denial a "never" ("I never worked at Orlin Labs", "Nunca trabajé en Nácar"), not an end
        /// ("I no longer work there"): a trusted never-denial also reaches an agent's claim under the same name (13e.1).
        /// Optional: without them no denial reaches another entity.
        public let neverWords: [String]?
        /// Words that tie a placeholder to a named business in one clause ("por cuenta propia con Nudo Estudio",
        /// "freelancing through Copper Finch"): the placeholder is that business (13e.1). Optional.
        public let placeholderLinks: [String]?
        /// Timeline grammar (13e.1, memory processing §11.7), all optional: words next to before / after that keep their
        /// meaning ("my next job after…", "last employer before…"); closed-class words a user's own clause may hold
        /// ("Where did I go…", "¿Qué empleo vino…"); words allowed only beside a cue word ("What do I call my business…",
        /// never "Who did I call after Acme?"); and verbs only in their frame ("employed me", "me contrató").
        public let operatorModifiers: [String]?
        public let subjectWords: [String]?
        public let cueBoundWords: [String]?
        public let subjectFrames: [String]?
        /// Operators after their anchor ("Acme was preceded by which job?"), per direction. Optional.
        public let passiveOperators: [String: [String]]?
        /// Words that are an "after" operator only with an end word in their phrase ("once I'd left Acme", "having left
        /// Acme", "al salir de Acme"); anything else ("once at Acme") isn't one. Optional.
        public let eventOperators: [String]?
        /// Words a date after an anchor may open with besides its preposition ("at the end of 2021", "a finales de
        /// 2021"). Optional.
        public let dateLeadWords: [String]?
        /// What a timeline question must ask, the organization (13e.1): "which" words with a noun of the predicate after
        /// them; "where" words with one of `where_verbs`; `who_frames` ("who employed me"); `name_frames` ("what do I call…");
        /// or a noun phrase. Optional: without them every question asks.
        public let askFrames: [String: [String]]?
        /// Words that can't open the stretch between an operator and its anchor ("after work at Acme"). Optional.
        public let leadRefusedFirst: [String]?
        /// The only words around a never-word in a never-denial: before it ("I", "yo"), and between it and the name
        /// ("have", "been", "at"); the predicate's own cues may stand between too. Optional.
        /// Verbs that name an event like the start and end words ("took", "set up", "came from"): a year, "current" or
        /// "previous" question with one isn't about what held. Optional.
        public let eventWords: [String]?
        /// What may stand between a "which" word and the noun it asks for ("What was my previous job"). Optional.
        public let askBetween: [String]?
        /// Nouns that are also verbs ("trabajo"): a noun only after an owner or a determiner ("mi trabajo"). Optional.
        public let verbNouns: [String]?
        /// The only words around a placeholder phrase and its business for the fold ("I'm still freelancing with…"). Optional.
        public let foldLeadWords: [String]?
        public let neverLeadWords: [String]?
        public let neverBetweenWords: [String]?
        /// The only words a question may hold besides its operator phrase when no cue word names the predicate ("Where did
        /// I go after Acme?", never "Where did I move after Acme?"). Optional: without them, a cue word is needed.
        public let anchorCueWords: [String]?
        /// Words that negate or contrast in a clause ("pero ya no con…"): a placeholder isn't folded across them. Optional.
        public let negationWords: [String]?
        public let functionWords: [String]
        public let dateJoiners: [String]
        public let ordinalSuffixes: [String]
        public let legalSuffixes: [String]
        public let userPlaceholder: String
        public let promptExamples: [String: String]

        public struct StatusCues: Sendable, Decodable {
            public let former: [String]
            public let current: [String]
        }

        public struct Operators: Sendable, Decodable {
            public let before: [String]
            public let after: [String]
            public let previous: [String]
            public let current: [String]
        }
    }

    /// Per entity kind: how names match and normalise.
    public struct Kind: Sendable, Decodable {
        public let match: String           // first_name · contains · exact
        public let normalise: [String]     // legal_suffix
    }

    public struct CallGroup: Sendable, Decodable {
        public let intro: String
        public let examples: [String: [String]]?
    }

    public struct Predicate: Sendable, Decodable {
        public let id: String
        public let objectKind: String
        public let callGroup: String
        public let uses: [String]
        public let definition: String
        public let placeholders: [String: [String]]?
        public let exclusive: Bool
        public let succession: Bool
        public let slot: String?
        public let gapMonths: Double?
        public let qualifiers: [String: Qualifier]
        public let lexicon: [LexiconEntry]
        public let queryCues: [String]
        public let phrases: [String: String]
        /// Words that make a question about one of its qualifiers ("my title before…"), not the timeline.
        public let qualifierCues: [String]?
        /// Per value of the slot qualifier, words that ask about that value only ("day job" → employee, "mi negocio" →
        /// self-employed): the timeline answers within it (13e.1). Optional.
        public let slotCues: [String: [String]]?
        /// The nouns among its cues ("company", "empresa"): a clause opening with one is a noun phrase, never a
        /// yes/no question ("Company I worked for right before Acme", not "¿Trabajé justo después de…?"). Optional.
        public let queryNouns: [String]?
    }

    public struct Qualifier: Sendable, Decodable {
        public let multi: Bool
        public let describe: String?
        public let values: [String]?
    }

    public struct LexiconEntry: Sendable, Decodable {
        public let cls: String?
        public let words: [String]
        public let generic: Bool?
        public let plural: Bool?
        public let exclusive: Bool?
        public let status: String?
    }

    /// One lexicon word, with what it means.
    public struct Word: Sendable {
        public let predicate: String
        public let cls: String?
        public let generic: Bool
        public let plural: Bool
        public let exclusiveLabel: Bool
        public let status: String?
    }

    // MARK: - Derived lookups

    public func predicate(_ id: String) -> Predicate? { predicates.first { $0.id == id } }

    /// Whether the registry declares a use for a predicate. Declared isn't on: a use is on only with a qualification
    /// record (`FactsUses`).
    public func declares(_ id: String, _ use: FactsUse) -> Bool { predicate(id)?.uses.contains(use.rawValue) ?? false }

    public func kindOf(_ id: String) -> String { predicate(id)?.objectKind ?? "thing" }

    /// The predicates that declare the timeline use (on or not).
    public var timelinePredicates: [String] { predicates.filter { $0.uses.contains(FactsUse.timeline.rawValue) }.map(\.id) }

    /// A group's declared predicates: what its prompt and schema ask for, whatever is on (so the prompt version, part
    /// of a qualification record's key, never depends on the gate).
    public func groupPredicates(_ group: String) -> [String] {
        predicates.filter { $0.uses.contains(FactsUse.recorded.rawValue) && $0.callGroup == group }.map(\.id)
    }

    /// Every use a use needs on first, directly or through another (from `uses`).
    public func prerequisites(_ use: String) -> [String] {
        var out: [String] = [], stack = useRules[use]?.requires ?? []
        while let u = stack.popLast() {
            if out.contains(u) { continue }
            out.append(u)
            stack += useRules[u]?.requires ?? []
        }
        return out
    }

    /// Every lexicon word, lowercased, with its meaning (a word listed twice keeps its last meaning, as the spike did).
    public var lexicon: [String: Word] { lexiconTable ?? buildLexicon() }

    func buildLexicon() -> [String: Word] {
        var out: [String: Word] = [:]
        for p in predicates {
            for e in p.lexicon {
                for w in e.words {
                    out[w.lowercased()] = Word(predicate: p.id, cls: e.cls, generic: e.generic ?? false,
                                               plural: e.plural ?? false, exclusiveLabel: e.exclusive ?? false,
                                               status: e.status)
                }
            }
        }
        return out
    }

    /// Month words → month number.
    public var monthWords: [String: Int] {
        var out: [String: Int] = [:]
        for (k, ws) in language.months { for w in ws { out[w] = Int(k) } }
        return out
    }

    public var formerCues: Set<String> { Set(language.statusCues.former) }
    public var currentCues: Set<String> { Set(language.statusCues.current) }

    // MARK: - Loading

    /// The registry shipped with the app.
    public static let bundled: FactsRegistry = {
        guard let registry = try? FactsRegistry.decode(bundledData) else { fatalError("facts-registry.json is invalid") }
        return registry
    }()

    /// The bundled registry's JSON (tests derive variants from it).
    public static let bundledData: Data = {
        guard let url = Bundle.module.url(forResource: "facts-registry", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            fatalError("facts-registry.json is missing")
        }
        return data
    }()

    public static func decode(_ data: Data) throws -> FactsRegistry {
        let d = JSONDecoder()
        // Snake-case keys throughout; note the strategy also applies to dictionary keys ("note_noun" → "noteNoun").
        d.keyDecodingStrategy = .convertFromSnakeCase
        var registry = try d.decode(FactsRegistry.self, from: data)
        registry.qualifierOrder = OrderedJSON.qualifierOrder(data)
        registry.fingerprint = try fingerprint(data, version: registry.version)
        registry.extractionDigests = try extractionDigests(data)
        registry.lexiconTable = registry.buildLexicon()
        try registry.validate()
        return registry
    }

    /// `version-<12 hex>`: SHA-256 of the registry as canonical JSON (sorted keys), with each predicate's `uses` and
    /// every `note` (comments for people) removed.
    static func fingerprint(_ data: Data, version: String) throws -> String {
        func strip(_ v: Any) -> Any {
            if let o = v as? [String: Any] { return o.filter { $0.key != "note" }.mapValues(strip) }
            if let a = v as? [Any] { return a.map(strip) }
            return v
        }
        guard var top = strip(try JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return version }
        if let preds = top["predicates"] as? [[String: Any]] {
            top["predicates"] = preds.map { var p = $0; p.removeValue(forKey: "uses"); return p }
        }
        let canonical = try JSONSerialization.data(withJSONObject: top, options: [.sortedKeys, .withoutEscapingSlashes])
        return version + "-" + SHA256.hash(data: canonical).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// What only questions read (`TimelineIntent`; a predicate's attribute phrases are for answers, 13d): a change to
    /// them is language-only and re-reads nothing. Anything not listed counts as extraction, so a doubt costs a re-read.
    static let readSideLanguage: Set<String> = ["operators", "operator_adverbs", "wh_words", "time_nouns", "anchor_tail_words",
                                                "anchor_lead_words", "question_words", "year_prepositions"]
    static let readSidePredicate: Set<String> = ["query_cues", "qualifier_cues", "phrases", "uses", "note"]

    /// Per call group: SHA-256 of the canonical JSON of the shared language and kinds (without the read-side fields),
    /// the group's own entry and its predicates (without theirs). Another group's predicate isn't in it: a new
    /// predicate re-reads only its own group (ADR-0032 decision 3).
    static func extractionDigests(_ data: Data) throws -> [String: String] {
        func strip(_ v: Any) -> Any {
            if let o = v as? [String: Any] { return o.filter { $0.key != "note" }.mapValues(strip) }
            if let a = v as? [Any] { return a.map(strip) }
            return v
        }
        guard let top = strip(try JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        let language = (top["language"] as? [String: Any] ?? [:]).filter { !readSideLanguage.contains($0.key) }
        let predicates = top["predicates"] as? [[String: Any]] ?? []
        var out: [String: String] = [:]
        for (group, entry) in top["call_groups"] as? [String: Any] ?? [:] {
            let own = predicates.filter { $0["call_group"] as? String == group }
                .map { $0.filter { !readSidePredicate.contains($0.key) } }
            let projection: [String: Any] = ["language": language, "kinds": top["kinds"] ?? [:], "group": entry, "predicates": own]
            let canonical = try JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys, .withoutEscapingSlashes])
            out[group] = SHA256.hash(data: canonical).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    /// A predicate's qualifiers in their JSON order (unknown ones last, sorted).
    public func qualifierKeys(_ id: String) -> [String] {
        guard let p = predicate(id) else { return [] }
        let known = (qualifierOrder[id] ?? []).filter { p.qualifiers[$0] != nil }
        return known + p.qualifiers.keys.filter { !known.contains($0) }.sorted()
    }

    public enum ValidationError: Error, Equatable {
        case unknownKind(String)
        case unknownCallGroup(String)
        case useWithoutPrerequisite(predicate: String, use: String)
        case slotNotAQualifier(String)
        case duplicatePredicate(String)
        case unknownUse(String)
        case useCycle(String)
    }

    /// Structural checks: kinds and call groups exist, the uses are known and acyclic, a predicate declares what each of
    /// its uses needs, a slot names a qualifier.
    public func validate() throws {
        for (use, rule) in useRules {
            guard FactsUse(rawValue: use) != nil else { throw ValidationError.unknownUse(use) }
            for r in rule.requires where useRules[r] == nil { throw ValidationError.unknownUse(r) }
            if prerequisites(use).contains(use) { throw ValidationError.useCycle(use) }
        }
        var seen = Set<String>()
        for p in predicates {
            guard seen.insert(p.id).inserted else { throw ValidationError.duplicatePredicate(p.id) }
            guard kinds[p.objectKind] != nil else { throw ValidationError.unknownKind(p.objectKind) }
            guard callGroups[p.callGroup] != nil else { throw ValidationError.unknownCallGroup(p.callGroup) }
            for use in p.uses {
                guard useRules[use] != nil else { throw ValidationError.unknownUse(use) }
                for prior in prerequisites(use) where !p.uses.contains(prior) {
                    throw ValidationError.useWithoutPrerequisite(predicate: p.id, use: use)
                }
            }
            if let slot = p.slot, p.qualifiers[slot] == nil { throw ValidationError.slotNotAQualifier(p.id) }
            if let cues = p.slotCues {
                guard let slot = p.slot, let values = p.qualifiers[slot]?.values, Set(cues.keys).isSubset(of: values) else {
                    throw ValidationError.slotNotAQualifier(p.id)
                }
            }
        }
    }
}

/// Just enough of a JSON reader to keep object key order, which `JSONDecoder` doesn't.
enum OrderedJSON {
    indirect enum Value {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        case other
    }

    /// `predicates[i].id` → the keys of `predicates[i].qualifiers`, in order.
    static func qualifierOrder(_ data: Data) -> [String: [String]] {
        var r = Reader(bytes: Array(data))
        guard case let .object(top)? = r.value(),
              case let .array(preds)? = top.first(where: { $0.0 == "predicates" })?.1 else { return [:] }
        var out: [String: [String]] = [:]
        for case let .object(fields) in preds {
            guard case let .string(id)? = fields.first(where: { $0.0 == "id" })?.1,
                  case let .object(q)? = fields.first(where: { $0.0 == "qualifiers" })?.1 else { continue }
            out[id] = q.map { camel($0.0) }      // as `convertFromSnakeCase` decodes the dictionary's keys
        }
        return out
    }

    /// The keys of the top-level object `key`, in order.
    static func objectKeys(_ data: Data, at key: String) -> [String] {
        var r = Reader(bytes: Array(data))
        guard case let .object(top)? = r.value(), case let .object(fields)? = top.first(where: { $0.0 == key })?.1 else { return [] }
        return fields.map(\.0)
    }

    static func camel(_ key: String) -> String {
        let parts = key.split(separator: "_", omittingEmptySubsequences: true)
        guard let first = parts.first, parts.count > 1 else { return key }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    struct Reader {
        let bytes: [UInt8]
        var i = 0

        mutating func skipSpace() { while i < bytes.count, [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }

        mutating func value() -> Value? {
            skipSpace()
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var fields: [(String, Value)] = []
                while true {
                    skipSpace()
                    if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(fields) }
                    guard case let .string(key)? = value() else { return nil }
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                    i += 1
                    guard let v = value() else { return nil }
                    fields.append((key, v))
                    skipSpace()
                    if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i += 1 }
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [Value] = []
                while true {
                    skipSpace()
                    if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    guard let v = value() else { return nil }
                    items.append(v)
                    skipSpace()
                    if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i += 1 }
                }
            case UInt8(ascii: "\""):
                let start = i
                i += 1
                while i < bytes.count, bytes[i] != UInt8(ascii: "\"") { i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1 }
                i += 1
                guard i <= bytes.count,
                      let s = try? JSONSerialization.jsonObject(with: Data(bytes[start..<i]), options: [.fragmentsAllowed]) as? String
                else { return nil }
                return .string(s)
            default:
                while i < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[i]) { i += 1 }
                return .other
            }
        }
    }
}
