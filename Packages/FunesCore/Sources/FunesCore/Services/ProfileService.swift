import Foundation
import FunesProtocol
import GRDB

/// The profile row (storage §2, `v6_profile`). ProfileService is the public API.
enum ProfileStore {
    /// The profile, or an empty one before the first save.
    static func fetch(_ db: Database) throws -> Profile {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM profile WHERE id = 1") else { return Profile() }
        return Profile(givenName: row["given_name"], familyName: row["family_name"], preferredName: row["preferred_name"],
                       pronouns: row["pronouns"], languages: JSON.decode([String].self, row["languages"]) ?? [],
                       location: row["location"], timeZone: row["time_zone"] ?? Profile.automaticTimeZone,
                       occupation: row["occupation"], updatedAt: row["updated_at"])
    }

    /// Checks a normalized profile: lengths, languages, time zone, then the secret scanner over
    /// every field (domain model ▸ Profile). Nothing is saved on a failure.
    static func validate(_ p: Profile) throws {
        let problems = p.problems()
        let secrets = Profile.TextField.allCases.flatMap { field -> [SecretPattern] in
            if case let .secret(found) = problems[field] { found } else { [] }
        }
        let languageSecrets = SecretScanner.scan(p.languages)
        if !secrets.isEmpty || !languageSecrets.isEmpty {
            throw VaultError.secretLikeContent(SecretPattern.allCases.filter { secrets.contains($0) || languageSecrets.contains($0) })
        }
        if let field = Profile.TextField.allCases.first(where: { problems[$0] != nil }) {
            throw VaultError.invalidInput(field: field.rawValue)
        }
        guard p.languagesAreValid else { throw VaultError.invalidInput(field: "languages") }
        guard p.timeZoneIsValid else { throw VaultError.invalidInput(field: "time_zone") }
    }

    static func write(_ db: Database, _ p: Profile) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO profile (id, given_name, family_name, preferred_name, pronouns, languages, location,
              time_zone, occupation, updated_at) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [p.givenName, p.familyName, p.preferredName, p.pronouns, JSON.encode(p.languages), p.location,
                             p.timeZone, p.occupation, p.updatedAt])
    }

    /// The groups whose values differ, in `ProfileField` order.
    static func changedFields(from old: Profile, to new: Profile) -> [ProfileField] {
        ProfileField.allCases.filter { field in
            switch field {
            case .name:
                old.givenName != new.givenName || old.familyName != new.familyName || old.preferredName != new.preferredName
            case .pronouns: old.pronouns != new.pronouns
            case .languages: old.languages != new.languages
            case .location: old.location != new.location
            case .timeZone: old.timeZone != new.timeZone
            case .occupation: old.occupation != new.occupation
            }
        }
    }
}

/// About you (FR-U-01, ADR-0026): reading and saving the profile, and who sees each field.
public final class ProfileService: Sendable {
    public let store: VaultStore
    public let activity: any ActivityRecorder

    public init(store: VaultStore, activity: any ActivityRecorder) {
        self.store = store
        self.activity = activity
    }

    public func profile() async throws -> Profile {
        try await store.writer.read { db in try ProfileStore.fetch(db) }
    }

    /// Saves `profile`, trimmed and with empty text as none, in one transaction. Refused whole
    /// with `secretLikeContent` when the scanner matches any field (T46), or `invalidInput` naming
    /// the field over its limit. Records `profile_edited` with the changed fields' names, never
    /// their values; saving the same values changes nothing. Returns the profile as saved.
    @discardableResult
    public func save(_ profile: Profile, now: Date) async throws -> Profile {
        let candidate = profile.normalized()
        try ProfileStore.validate(candidate)
        let (saved, changed) = try await store.writer.write { db -> (Profile, [ProfileField]) in
            let old = try ProfileStore.fetch(db)
            let changed = ProfileStore.changedFields(from: old, to: candidate)
            guard !changed.isEmpty else { return (old, []) }
            var new = candidate
            new.updatedAt = now
            try ProfileStore.write(db, new)
            return (new, changed)
        }
        if !changed.isEmpty {
            activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "profile_edited",
                                          profileFields: changed))
        }
        return saved
    }

    /// The agents (not removed) each field goes to, for "Shared with" in About You. Agents
    /// without Read get nothing, whatever their fields say (§3.10 rule 1), so they aren't counted.
    public func sharing() async throws -> [ProfileField: [Agent]] {
        let agents = try await store.writer.read { db in try AgentStore.all(db) }
        var out: [ProfileField: [Agent]] = [:]
        for agent in agents where agent.access.operations.contains(.read) {
            for field in agent.access.profileFields { out[field, default: []].append(agent) }
        }
        return out
    }
}

extension VaultStore {
    /// The profile, or an empty one before the first save; a quick synchronous read for Home's
    /// greeting and the companion's `status.get`.
    public func profile() throws -> Profile {
        try writer.read { db in try ProfileStore.fetch(db) }
    }
}
