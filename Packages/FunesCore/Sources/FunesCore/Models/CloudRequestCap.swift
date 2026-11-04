import Foundation
import FunesProtocol
import GRDB

/// The daily cap on cloud generation requests (ADR-0022, model providers §4–§6): 300 by default,
/// counted per local day in the vault (so it holds across restarts), shared by New memories and
/// the tidy-up. Agents' input may use at most 40% of it, so the user's own captures aren't
/// starved. Embeddings don't count. The first refusal of a day is an Activity row
/// (`cap_reached`, counts only), which the Mac turns into its once-a-day notice.
public final class CloudRequestCap: Sendable {
    public static let defaultLimit = 300
    public static let agentShare = 0.4
    static let metaKey = "cloud_requests"

    /// Whose work a request is for.
    public enum Requester: String, Sendable, Hashable {
        /// The user's captures and imports, and the tidy-up.
        case user
        /// Agents' suggestions and direct writes.
        case agent
    }

    /// Today's counts.
    public struct Day: Sendable, Hashable, Codable {
        /// `yyyy-MM-dd` in the Mac's time zone.
        public var day: String
        public var total = 0
        public var agents = 0
        /// The day's first refusal was recorded.
        public var reached = false
    }

    public let store: VaultStore
    public let limit: Int
    public let activity: (any ActivityRecorder)?
    public let timeZone: TimeZone

    public init(store: VaultStore, limit: Int = CloudRequestCap.defaultLimit, activity: (any ActivityRecorder)? = nil,
                timeZone: TimeZone = .current) {
        self.store = store
        self.limit = max(0, limit)
        self.activity = activity
        self.timeZone = timeZone
    }

    /// The agents' share of the cap.
    public var agentLimit: Int { Int((Double(limit) * Self.agentShare).rounded(.down)) }

    /// Counts one request, or refuses it with `ProviderError.capReached` when the cap, or the
    /// agents' share for an agent's input, is used up. Atomic across callers.
    public func consume(_ requester: Requester, now: Date) async throws {
        enum Result { case counted, refused(first: Bool, total: Int) }
        let result = try await store.writer.write { db -> Result in
            var day = try Self.read(db, key: self.key(now))
            if day.total >= self.limit || (requester == .agent && day.agents >= self.agentLimit) {
                let first = !day.reached
                day.reached = true
                try Self.write(db, day)
                return .refused(first: first, total: day.total)
            }
            day.total += 1
            if requester == .agent { day.agents += 1 }
            try Self.write(db, day)
            return .counted
        }
        if case let .refused(first, total) = result {
            if first {
                activity?.record(ActivityEvent(time: now, phase: .event, actor: .system, via: .app, event: "cap_reached",
                                               outcome: requester.rawValue, counts: ["requests": total, "limit": limit]))
            }
            throw ProviderError.capReached
        }
    }

    public func today(now: Date) async throws -> Day {
        try await store.writer.read { db in try Self.read(db, key: self.key(now)) }
    }

    /// The start of the next local day, when the cap resets.
    public func nextDay(after now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? now + 86_400
    }

    func key(_ now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// The stored counts if they're today's; a new day starts at zero.
    static func read(_ db: Database, key: String) throws -> Day {
        let stored = JSON.decode(Day.self, try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [metaKey]))
        return stored?.day == key ? stored! : Day(day: key)
    }

    static func write(_ db: Database, _ day: Day) throws {
        try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [metaKey, JSON.encode(day)])
    }
}
