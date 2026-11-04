import Foundation
import FunesProtocol

/// The menu bar panel's chart (FR-H-07, ADR-0029): the last 24 hours hour by hour, the current
/// hour last. The same aggregates as `VaultOverview`'s days, from the same tables: counts and the
/// agents' names, never memory text or titles. Mac only; the companion protocol doesn't carry it.
public struct RecentPulse: Codable, Sendable, Equatable {
    public static let hourCount = 24

    public var generatedAt: Date
    /// The calendar's time zone identifier; each hour's `date` is an instant, so an hour that
    /// happens twice when clocks go back is two buckets, labelled with their zone.
    public var timeZone: String
    /// 24 buckets of one hour each, oldest first: `date` is the hour's start.
    public var hours: [VaultOverview.Bucket]
    /// The display names of the agents in `hours`' `out`, by agent id (removed agents too).
    public var agentNames: [String: String]

    public init(generatedAt: Date, timeZone: String, hours: [VaultOverview.Bucket], agentNames: [String: String]) {
        self.generatedAt = generatedAt
        self.timeZone = timeZone
        self.hours = hours
        self.agentNames = agentNames
    }

    /// New memories in the 24 hours, by source.
    public var inbound: VaultOverview.Sources {
        hours.reduce(into: VaultOverview.Sources()) { $0.add($1.inbound) }
    }

    /// Memories delivered to agents in the 24 hours.
    public var shared: Int { hours.map(\.shared).reduce(0, +) }

    /// Requests refused in the 24 hours.
    public var refused: Int { hours.map(\.refused).reduce(0, +) }

    /// Nothing came in or went out.
    public var isQuiet: Bool { inbound.total == 0 && shared == 0 && refused == 0 }

    /// The hour a bucket covers.
    public static func interval(of bucket: VaultOverview.Bucket) -> DateInterval {
        DateInterval(start: bucket.date, duration: 3_600)
    }
}
