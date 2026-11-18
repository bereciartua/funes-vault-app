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
    public var lexicon: [String: Word] {
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
