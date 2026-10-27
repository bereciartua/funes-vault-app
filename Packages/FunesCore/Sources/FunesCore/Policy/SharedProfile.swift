import Foundation
import FunesProtocol

/// The parts of the profile one `request_memory` answer carries (access policy §3.10): the
/// agent's profile fields that have a value. Encodes as the response's `profile` object.
public struct SharedProfile: Sendable, Hashable, Codable {
    public struct Name: Sendable, Hashable, Codable {
        public var given: String?
        public var family: String?
        /// The called name: the preferred name, else the given name.
        public var called: String?
    }

    public var name: Name?
    public var pronouns: String?
    public var languages: [String]?
    public var location: String?
    /// An IANA id; the Mac's for `automatic`.
    public var timeZone: String?
    public var occupation: String?

    enum CodingKeys: String, CodingKey {
        case name, pronouns, languages, location, occupation
        case timeZone = "time_zone"
    }

    /// The fields this carries, in `ProfileField` order: the disclosure's `profileFieldsSent`.
    public var fields: [ProfileField] {
        ProfileField.allCases.filter { field in
            switch field {
            case .name: name != nil
            case .pronouns: pronouns != nil
            case .languages: languages != nil
            case .location: location != nil
            case .timeZone: timeZone != nil
            case .occupation: occupation != nil
            }
        }
    }

    /// What `profile` adds to an agent's result, in the bundle's wire bytes (§3.10 rule 9): its
    /// JSON, counted like an item's text, so both copies of the result are covered.
    public var wireBytes: Int { BundleCompiler.wireBytes("\"profile\":" + JSON.encode(self)) }
}

extension Profile {
    /// What an agent sharing `fields` is given, or nil when none of them has a value (rule 3:
    /// then the response has no `profile` key at all).
    public func shared(_ fields: Set<ProfileField>, timeZone current: TimeZone = .current) -> SharedProfile? {
        let p = normalized()
        var out = SharedProfile()
        if fields.contains(.name), p.hasValue(.name) {
            out.name = SharedProfile.Name(given: p.givenName, family: p.familyName, called: p.calledName)
        }
        if fields.contains(.pronouns) { out.pronouns = p.pronouns }
        if fields.contains(.languages), !p.languages.isEmpty { out.languages = p.languages }
        if fields.contains(.location) { out.location = p.location }
        if fields.contains(.timeZone) { out.timeZone = p.resolvedTimeZone(current: current) }
        if fields.contains(.occupation) { out.occupation = p.occupation }
        return out.fields.isEmpty ? nil : out
    }
}
