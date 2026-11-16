import Foundation

/// The predicate registry (ADR-0032 decision 2, memory processing §11.2): what each kind of fact about you means and
/// how it's used, as data. Every part of `Facts/` reads it; no code names a predicate or carries its words.
public struct FactsRegistry: Sendable, Decodable {
    public let version: String
    public let language: Language
    public let kinds: [String: Kind]
    public let callGroups: [String: CallGroup]
    public let predicates: [Predicate]

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
        public let pairBefore: [String]
        public let pairAfter: [String]
        public let pairAdverbs: [String]
        public let notNames: [String]
        public let stopNames: [String]
        public let personNouns: [String]
        public let formerPrefixes: [String]
        public let formerWords: [String]
        public let anchorTailWords: [String]
        public let timePrepositions: [String]
        public let dayPrepositions: [String]
        public let returnCues: [String]
        public let timeNouns: [String]
        public let thirdPerson: [String]
        public let firstPerson: [String]
        public let months: [String: [String]]
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

    public func uses(_ id: String, _ use: String) -> Bool { predicate(id)?.uses.contains(use) ?? false }

    public func kindOf(_ id: String) -> String { predicate(id)?.objectKind ?? "thing" }

    public var timelinePredicates: [String] { predicates.filter { $0.uses.contains("timeline") }.map(\.id) }

    public func groupPredicates(_ group: String) -> [String] {
        predicates.filter { $0.uses.contains("recorded") && $0.callGroup == group }.map(\.id)
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
        let registry = try d.decode(FactsRegistry.self, from: data)
        try registry.validate()
        return registry
    }

    public enum ValidationError: Error, Equatable {
        case unknownKind(String)
        case unknownCallGroup(String)
        case useWithoutPrerequisite(predicate: String, use: String)
        case slotNotAQualifier(String)
        case duplicatePredicate(String)
    }

    /// Structural checks: kinds and call groups exist, a use has the ones before it, a slot names a qualifier.
    public func validate() throws {
        var seen = Set<String>()
        let order = ["recorded", "linked", "timeline"]
        for p in predicates {
            guard seen.insert(p.id).inserted else { throw ValidationError.duplicatePredicate(p.id) }
            guard kinds[p.objectKind] != nil else { throw ValidationError.unknownKind(p.objectKind) }
            guard callGroups[p.callGroup] != nil else { throw ValidationError.unknownCallGroup(p.callGroup) }
            for (i, use) in order.enumerated() where p.uses.contains(use) {
                for prior in order.prefix(i) where !p.uses.contains(prior) {
                    throw ValidationError.useWithoutPrerequisite(predicate: p.id, use: use)
                }
            }
            if let slot = p.slot, p.qualifiers[slot] == nil { throw ValidationError.slotNotAQualifier(p.id) }
        }
    }
}
