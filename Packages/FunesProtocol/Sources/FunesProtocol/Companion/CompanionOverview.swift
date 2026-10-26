import Foundation

// MARK: - overview.get (v0.4)

/// `overview.get` (§4, ADR-0025): the vault's counts for a range, for Home and the widgets.
public enum OverviewGet: CompanionCall {
    public static let method = CompanionMethod.overviewGet
    public typealias Params = OverviewParams
    public typealias Result = VaultOverview
}

/// How far back an overview looks, and how it groups: 30 days by day, 12 weeks by week, 12
/// months by month. Each ends with the bucket holding now.
public enum OverviewRange: String, Codable, Sendable, CaseIterable {
    case days30 = "30d"
    case weeks12 = "12w"
    case months12 = "12m"

    /// How many buckets the range has.
    public var bucketCount: Int {
        switch self {
        case .days30: 30
        case .weeks12, .months12: 12
        }
    }
}

public struct OverviewParams: Codable, Sendable, Equatable {
    public var range: OverviewRange

    public init(range: OverviewRange) { self.range = range }
}

/// The vault's counts (FR-H-01): numbers, dates and agent names only, never memory text or
/// titles. What the Mac's Home shows, what `overview.get` returns and what the iPhone caches.
///
/// Dictionaries are keyed by their wire spellings (a sensitivity's name, a category key, a kind,
/// a reason code, an agent's lowercase id), so they encode as JSON objects.
public struct VaultOverview: Codable, Sendable, Equatable {
    /// New memories in one bucket, by where they came from (the chart's five sources).
    public struct Sources: Codable, Sendable, Equatable {
        /// Typed or captured on the Mac, and the setup's questions.
        public var mac: Int
        /// Captured, or typed, on a paired iPhone.
        public var iphone: Int
        /// An agent's suggestion applied, or its direct write.
        public var agent: Int
        public var `import`: Int
        /// A merge's or split's result (Phase 6).
        public var tidy: Int

        public init(mac: Int = 0, iphone: Int = 0, agent: Int = 0, import: Int = 0, tidy: Int = 0) {
            self.mac = mac
            self.iphone = iphone
            self.agent = agent
            self.import = `import`
            self.tidy = tidy
        }

        public var total: Int { mac + iphone + agent + `import` + tidy }

        public mutating func add(_ other: Sources) {
            mac += other.mac
            iphone += other.iphone
            agent += other.agent
            self.import += other.import
            tidy += other.tidy
        }
    }

    /// One day, week or month.
    public struct Bucket: Codable, Sendable, Equatable {
        /// Its start: midnight, in `timeZone`, of the day, of the week's first day or of the month's.
        public var date: Date
        public var inbound: Sources
        /// Memories delivered, by agent id. A request that shares 3 counts 3.
        public var out: [String: Int]
        /// Requests refused.
        public var refused: Int

        public init(date: Date, inbound: Sources = Sources(), out: [String: Int] = [:], refused: Int = 0) {
            self.date = date
            self.inbound = inbound
            self.out = out
            self.refused = refused
        }

        public var shared: Int { out.values.reduce(0, +) }

        enum CodingKeys: String, CodingKey {
            case date, inbound = "in", out, refused
        }
    }

    /// The last 7 days, today included: the sentence's numbers ("This week: 9 saved, 23 shared
    /// with 3 agents, 2 refused").
    public struct Week: Codable, Sendable, Equatable {
        public var saved: Int
        public var shared: Int
        /// Agents that were delivered at least one memory.
        public var agents: Int
        public var refused: Int

        public init(saved: Int = 0, shared: Int = 0, agents: Int = 0, refused: Int = 0) {
            self.saved = saved
            self.shared = shared
            self.agents = agents
            self.refused = refused
        }
    }

    /// New memories per day over the last 12 weeks, whatever the range: the Rhythm grid.
    public struct Rhythm: Codable, Sendable, Equatable {
        public static let days = 84
        /// Midnight, in `timeZone`, of the first day.
        public var start: Date
        /// One count per day, oldest first; the last is today.
        public var counts: [Int]

        public init(start: Date, counts: [Int]) {
            self.start = start
            self.counts = counts
        }
    }

    /// An agent, with its counts in the range.
    public struct AgentCount: Codable, Sendable, Equatable, Identifiable {
        /// The agent's lowercase id, the key of `Bucket.out`.
        public var id: String
        public var name: String
        public var kind: AgentKind
        /// Memories delivered in the range.
        public var shared: Int
        /// Requests made in the range.
        public var requests: Int
        public var lastRequestAt: Date?

        public init(id: String, name: String, kind: AgentKind, shared: Int, requests: Int, lastRequestAt: Date? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.shared = shared
            self.requests = requests
            self.lastRequestAt = lastRequestAt
        }
    }

    public var range: OverviewRange
    public var generatedAt: Date
    /// The Mac's time zone identifier, in which the buckets' days begin.
    public var timeZone: String
    /// Active memories.
    public var total: Int
    public var thisWeek: Week
    /// `range.bucketCount` buckets, oldest first; the last holds now. Days for 30d, weeks for
    /// 12w, months for 12m.
    public var days: [Bucket]
    public var rhythm: Rhythm
    /// Active memories by sensitivity name.
    public var bySensitivity: [String: Int]
    /// Active memories by category key (a memory in two categories counts in both).
    public var byCategory: [String: Int]
    /// Active memories by kind.
    public var byKind: [String: Int]
    /// Memories delivered in the range, by the sensitivity they had then.
    public var sharedBySensitivity: [String: Int]
    /// Memories delivered in the range, by the category they were shared under.
    public var sharedByCategory: [String: Int]
    /// Requests refused in the range, by reason code.
    public var refusedByReason: [String: Int]
    /// Memories withheld from the requests refused in the range, by reason code.
    public var withheld: [String: Int]
    /// Agents with a request in the range or not removed, most memories shared first.
    public var agents: [AgentCount]
    public var inboxPending: Int
    public var oldestPendingAt: Date?
    /// When the last tidy-up run finished.
    public var lastTidyUpAt: Date?

    public init(range: OverviewRange, generatedAt: Date, timeZone: String, total: Int, thisWeek: Week, days: [Bucket],
                rhythm: Rhythm, bySensitivity: [String: Int] = [:], byCategory: [String: Int] = [:], byKind: [String: Int] = [:],
                sharedBySensitivity: [String: Int] = [:], sharedByCategory: [String: Int] = [:],
                refusedByReason: [String: Int] = [:], withheld: [String: Int] = [:], agents: [AgentCount] = [],
                inboxPending: Int = 0, oldestPendingAt: Date? = nil, lastTidyUpAt: Date? = nil) {
        self.range = range
        self.generatedAt = generatedAt
        self.timeZone = timeZone
        self.total = total
        self.thisWeek = thisWeek
        self.days = days
        self.rhythm = rhythm
        self.bySensitivity = bySensitivity
        self.byCategory = byCategory
        self.byKind = byKind
        self.sharedBySensitivity = sharedBySensitivity
        self.sharedByCategory = sharedByCategory
        self.refusedByReason = refusedByReason
        self.withheld = withheld
        self.agents = agents
        self.inboxPending = inboxPending
        self.oldestPendingAt = oldestPendingAt
        self.lastTidyUpAt = lastTidyUpAt
    }

    /// Active memories at `level`.
    public func count(_ level: Sensitivity) -> Int { bySensitivity[level.name] ?? 0 }

    /// Memories delivered in the range at `level`.
    public func shared(_ level: Sensitivity) -> Int { sharedBySensitivity[level.name] ?? 0 }
}

/// The buckets of an overview range (FR-H-01): calendar days, weeks and months in a time zone,
/// so a day is the user's day across daylight saving changes. The Mac's `VaultOverview` query
/// and the demo vault both use it.
public struct OverviewCalendar: Sendable {
    public var calendar: Calendar

    /// `calendar` with its time zone and first weekday; the Mac passes `Calendar.current`.
    public init(calendar: Calendar) { self.calendar = calendar }

    /// The `count + 1` boundaries of `range` ending with the bucket holding `now`: bucket `i`
    /// is `[b[i], b[i+1])`.
    public func boundaries(_ range: OverviewRange, now: Date) -> [Date] {
        let unit: Calendar.Component = switch range {
        case .days30: .day
        case .weeks12: .weekOfYear
        case .months12: .month
        }
        let current = start(of: unit, containing: now)
        return (0...range.bucketCount).map { i in
            calendar.date(byAdding: unit, value: i - range.bucketCount + 1, to: current)!
        }
    }

    /// The `days + 1` day boundaries ending with tomorrow's midnight.
    public func dayBoundaries(_ days: Int, now: Date) -> [Date] {
        let today = start(of: .day, containing: now)
        return (0...days).map { calendar.date(byAdding: .day, value: $0 - days + 1, to: today)! }
    }

    private func start(of unit: Calendar.Component, containing date: Date) -> Date {
        calendar.dateInterval(of: unit, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
