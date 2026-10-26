import Foundation

/// A part of the profile an agent may be given with its `request_memory` answers
/// (spec/domain/domain-model.md#enumerations, access policy §3.10). Raw values are the wire and
/// database spellings.
public enum ProfileField: String, Codable, Sendable, CaseIterable, Comparable {
    /// The given, family and called name together.
    case name
    case pronouns, languages, location
    case timeZone = "time_zone"
    case occupation

    /// `allCases` order: the order fields are listed in, everywhere.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// What the user tells Funes about themself, "About you" (spec/domain/domain-model.md#profile,
/// ADR-0026). One per vault, every field optional. It isn't a memory.
public struct Profile: Sendable, Hashable, Codable {
    public var givenName: String?
    public var familyName: String?
    /// "What should Funes call you?". Empty means the given name.
    public var preferredName: String?
    public var pronouns: String?
    /// BCP 47 tags, ordered: the first is the one the user writes in most.
    public var languages: [String]
    public var location: String?
    /// An IANA id, or `automatic` (the Mac's time zone, read when it's needed).
    public var timeZone: String
    public var occupation: String?
    public var updatedAt: Date?

    public static let automaticTimeZone = "automatic"

    public init(givenName: String? = nil, familyName: String? = nil, preferredName: String? = nil,
                pronouns: String? = nil, languages: [String] = [], location: String? = nil,
                timeZone: String = Profile.automaticTimeZone, occupation: String? = nil, updatedAt: Date? = nil) {
        self.givenName = givenName
        self.familyName = familyName
        self.preferredName = preferredName
        self.pronouns = pronouns
        self.languages = languages
        self.location = location
        self.timeZone = timeZone
        self.occupation = occupation
        self.updatedAt = updatedAt
    }

    /// The name Funes calls the user by: the preferred name, else the given name, else none.
    public var calledName: String? { preferredName ?? givenName }

    /// Nothing set. `automatic` is the time zone's starting value, so it doesn't count.
    public var isEmpty: Bool {
        timeZone == Self.automaticTimeZone && ProfileField.allCases.allSatisfy { $0 == .timeZone || !hasValue($0) }
    }

    /// Whether the field has something to send. The time zone always has: `automatic` is the
    /// Mac's.
    public func hasValue(_ field: ProfileField) -> Bool {
        switch field {
        case .name: givenName != nil || familyName != nil || preferredName != nil
        case .pronouns: pronouns != nil
        case .languages: !languages.isEmpty
        case .location: location != nil
        case .timeZone: true
        case .occupation: occupation != nil
        }
    }

    // MARK: - Limits

    /// The free-text fields, for per-field errors.
    public enum TextField: String, Sendable, CaseIterable {
        case givenName = "given_name", familyName = "family_name", preferredName = "preferred_name"
        case pronouns, location, occupation

        /// The most Unicode scalars it may hold.
        public var limit: Int {
            switch self {
            case .givenName, .familyName, .preferredName: 80
            case .pronouns: 40
            case .location, .occupation: 120
            }
        }

        /// The group it's shared with.
        public var field: ProfileField {
            switch self {
            case .givenName, .familyName, .preferredName: .name
            case .pronouns: .pronouns
            case .location: .location
            case .occupation: .occupation
            }
        }
    }

    public static let maxLanguages = 8
    static let maxLanguageTagLength = 35

    public subscript(text field: TextField) -> String? {
        get {
            switch field {
            case .givenName: givenName
            case .familyName: familyName
            case .preferredName: preferredName
            case .pronouns: pronouns
            case .location: location
            case .occupation: occupation
            }
        }
        set {
            switch field {
            case .givenName: givenName = newValue
            case .familyName: familyName = newValue
            case .preferredName: preferredName = newValue
            case .pronouns: pronouns = newValue
            case .location: location = newValue
            case .occupation: occupation = newValue
            }
        }
    }

    /// Trimmed, with empty text as none and the languages without blanks or repeats.
    public func normalized() -> Profile {
        var p = self
        for field in TextField.allCases {
            let trimmed = p[text: field]?.trimmingCharacters(in: .whitespacesAndNewlines)
            p[text: field] = trimmed?.isEmpty == false ? trimmed : nil
        }
        var seen = Set<String>()
        p.languages = languages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let zone = timeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        p.timeZone = zone.isEmpty ? Self.automaticTimeZone : zone
        return p
    }

    /// What's wrong with a field, shown under it.
    public enum Problem: Sendable, Hashable {
        case tooLong(limit: Int)
        /// The secret scanner matched; the pattern types, never the text.
        case secret([SecretPattern])
    }

    /// The free-text fields that can't be saved, and why. Run on a normalized profile.
    public func problems() -> [TextField: Problem] {
        var out: [TextField: Problem] = [:]
        for field in TextField.allCases {
            guard let text = self[text: field] else { continue }
            let found = SecretScanner.scan(text)
            if !found.isEmpty {
                out[field] = .secret(found)
            } else if InputLimits.length(of: text) > field.limit {
                out[field] = .tooLong(limit: field.limit)
            }
        }
        return out
    }

    /// The languages are at most eight well-formed tags.
    public var languagesAreValid: Bool {
        languages.count <= Self.maxLanguages && languages.allSatisfy(Self.isLanguageTag)
    }

    /// `automatic`, or a time zone this system knows.
    public var timeZoneIsValid: Bool {
        timeZone == Self.automaticTimeZone || TimeZone.knownTimeZoneIdentifiers.contains(timeZone)
    }

    /// A BCP 47 tag's shape: a 2–8 letter language subtag, then subtags of 1–8 letters or digits.
    public static func isLanguageTag(_ tag: String) -> Bool {
        guard (2...maxLanguageTagLength).contains(tag.count) else { return false }
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...8).contains(first.count),
              first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// The name a suggestion from the macOS account's full name would fill in, when it looks like
    /// a person's: two or more words, or one capitalized word. Never for a username like "mib",
    /// and only ever offered, never saved by itself (ADR-0026).
    public static func suggested(fromAccountName fullName: String) -> Profile? {
        let words = fullName.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, first.first?.isLetter == true else { return nil }
        if words.count == 1 {
            guard first.first?.isUppercase == true else { return nil }
            return Profile(givenName: first)
        }
        return Profile(givenName: first, familyName: words.dropFirst().joined(separator: " "))
    }

    /// The time zone an agent is told: the IANA id, or the Mac's for `automatic`.
    public func resolvedTimeZone(current: TimeZone = .current) -> String {
        timeZone == Self.automaticTimeZone ? current.identifier : timeZone
    }
}
