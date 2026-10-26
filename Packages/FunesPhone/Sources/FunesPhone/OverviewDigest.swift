import Foundation
import FunesProtocol

// What Home's charts and the widgets draw (FR-H-04, UX: iPhone ▸ Home tab), worked out from a
// `VaultOverview`: numbers and dates only. The words and the views are `Apps/FunesShared`'s.

/// The Pulse card's ranges: 7 and 30 days on Home, and the longer ones in its sheet. 7 days is
/// the last week of the 30-day overview.
public enum PulseRange: String, CaseIterable, Sendable, Identifiable {
    case days7 = "7d"
    case days30 = "30d"
    case weeks12 = "12w"
    case months12 = "12m"

    /// The overview it's drawn from.
    public var overview: OverviewRange {
        switch self {
        case .days7, .days30: .days30
        case .weeks12: .weeks12
        case .months12: .months12
        }
    }

    /// How many of the overview's buckets it shows; nil for all of them.
    public var last: Int? { self == .days7 ? 7 : nil }

    public var id: String { rawValue }
}

/// The in/out chart (UX: Mac ▸ Home, Pulse card): new memories per bucket by source above the
/// line, memories shared by agent below it, and the requests refused.
public struct Pulse: Sendable, Equatable {
    public enum Unit: Sendable, Equatable {
        case day, week, month

        public var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            }
        }
    }

    /// One agent of the Out stack, or the rest of them ("Other").
    public struct Agent: Sendable, Hashable, Identifiable {
        /// The agent's id; empty for Other.
        public var id: String
        /// Nil for Other.
        public var name: String?
        /// Its colour: the agent's rank in the overview, so 7 and 30 days paint it alike.
        public var slot: Int

        public var isOther: Bool { name == nil }
    }

    public struct Bucket: Sendable, Equatable, Identifiable {
        public var date: Date
        public var inbound: VaultOverview.Sources
        /// Memories shared, in `Pulse.agents`' order.
        public var out: [Int]
        public var refused: Int

        public var id: Date { date }
        public var shared: Int { out.reduce(0, +) }
    }

    /// Agents named in the Out stack; the rest are Other.
    public static let namedAgents = 3

    public var unit: Unit
    /// The named agents, most shared first, then Other when anyone else shared.
    public var agents: [Agent]
    /// Oldest first; the last holds now.
    public var buckets: [Bucket]

    /// `overview`'s buckets, or its `last` few. Agents are named by their rank in the overview,
    /// the others folded into Other.
    public init(_ overview: VaultOverview, last: Int? = nil, namedAgents: Int = Pulse.namedAgents) {
        unit = switch overview.range {
        case .days30: .day
        case .weeks12: .week
        case .months12: .month
        }
        let named = overview.agents.filter { $0.shared > 0 }.prefix(namedAgents)
        var agents = named.enumerated().map { Agent(id: $1.id, name: $1.name, slot: $0) }
        let namedIDs = Set(agents.map(\.id))
        let others = overview.days.contains { $0.out.contains { !namedIDs.contains($0.key) && $0.value > 0 } }
        if others { agents.append(Agent(id: "", name: nil, slot: namedAgents)) }
        self.agents = agents
        let days = last.map { Array(overview.days.suffix($0)) } ?? overview.days
        buckets = days.map { day in
            var out = agents.map { $0.isOther ? 0 : day.out[$0.id] ?? 0 }
            if others {
                out[out.count - 1] = day.out.filter { !namedIDs.contains($0.key) }.values.reduce(0, +)
            }
            return Bucket(date: day.date, inbound: day.inbound, out: out, refused: day.refused)
        }
    }

    public var inbound: Int { buckets.map(\.inbound.total).reduce(0, +) }
    public var shared: Int { buckets.map(\.shared).reduce(0, +) }
    public var refused: Int { buckets.map(\.refused).reduce(0, +) }
    public var isEmpty: Bool { inbound == 0 && shared == 0 && refused == 0 }
    /// The tallest In and Out stacks, for a scale that keeps the line where it is.
    public var peakIn: Int { buckets.map(\.inbound.total).max() ?? 0 }
    public var peakOut: Int { buckets.map(\.shared).max() ?? 0 }

    /// The bucket holding `date`: a finger on the chart.
    public func bucket(at date: Date) -> Bucket? {
        guard let first = buckets.first, date >= first.date else { return nil }
        return buckets.last { $0.date <= date }
    }
}

/// The Memories tile's line: active memories at the end of each of the last 12 weeks, from the
/// day-by-day new memories in `rhythm` and today's total. Deletions aren't counted, so earlier
/// totals may read a little high.
public struct Growth: Sendable, Equatable {
    public struct Point: Sendable, Equatable, Identifiable {
        public var date: Date
        public var total: Int
        public var id: Date { date }
    }

    /// Oldest first; the last is today's total.
    public var points: [Point]

    public init(total: Int, rhythm: VaultOverview.Rhythm, calendar: Calendar) {
        let counts = rhythm.counts
        let weeks = max(1, counts.count / 7)
        var points: [Point] = []
        // The total at the start, then after each 7 days ending with today.
        for week in 0...weeks {
            let end = counts.count - (weeks - week) * 7
            let after = counts[max(0, end)...].reduce(0, +)
            let date = calendar.date(byAdding: .day, value: end, to: rhythm.start) ?? rhythm.start
            points.append(Point(date: date, total: max(0, total - after)))
        }
        self.points = points
    }

    public init(_ overview: VaultOverview) {
        self.init(total: overview.total, rhythm: overview.rhythm, calendar: overview.calendar)
    }
}

/// The Rhythm grid (like GitHub's): a column per calendar week, a row per weekday, the last
/// column this week; with the streak and the busiest weekday.
public struct RhythmGrid: Sendable, Equatable {
    public struct Cell: Sendable, Equatable, Identifiable {
        public var date: Date
        /// Column, oldest week first.
        public var week: Int
        /// Row, from the calendar's first weekday.
        public var row: Int
        /// New memories that day; nil before the overview's days and after today.
        public var count: Int?
        public var id: Date { date }
    }

    /// Fewer memories than this in 12 weeks is too few for a rhythm.
    public static let minimum = 5

    public var weeks: Int
    public var cells: [Cell]
    /// The busiest cell's count.
    public var peak: Int
    /// New memories in the 12 weeks of `rhythm`, whatever `weeks` shows.
    public var total: Int
    /// Calendar weeks in a row with a new memory, up to this one (or last week, while this one
    /// has none yet).
    public var streak: Int
    /// The weekday (`Calendar`'s 1 = Sunday … 7) with the most new memories; nil while there are
    /// too few.
    public var busiestWeekday: Int?

    public var isTooSparse: Bool { total < Self.minimum }

    public init(_ rhythm: VaultOverview.Rhythm, weeks: Int, calendar: Calendar) {
        self.weeks = weeks
        let counts = rhythm.counts
        total = counts.reduce(0, +)
        let today = calendar.date(byAdding: .day, value: max(0, counts.count - 1), to: rhythm.start) ?? rhythm.start
        func row(_ date: Date) -> Int { (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7 }
        func index(_ date: Date) -> Int { calendar.dateComponents([.day], from: rhythm.start, to: date).day ?? 0 }
        // The first cell: this week's first day, `weeks - 1` weeks back.
        let thisWeek = calendar.date(byAdding: .day, value: -row(today), to: today) ?? today
        let first = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeek) ?? thisWeek
        cells = (0..<(weeks * 7)).map { n in
            let date = calendar.date(byAdding: .day, value: n, to: first) ?? first
            let i = index(date)
            return Cell(date: date, week: n / 7, row: n % 7, count: counts.indices.contains(i) ? counts[i] : nil)
        }
        peak = cells.compactMap(\.count).max() ?? 0

        // Weeks back from this one, over all of `rhythm`.
        var perWeek: [Int: Int] = [:]
        for (i, count) in counts.enumerated() {
            let date = calendar.date(byAdding: .day, value: i, to: rhythm.start) ?? rhythm.start
            let back = (index(thisWeek) - index(date) + 6) / 7
            perWeek[back, default: 0] += count
        }
        var back = (perWeek[0] ?? 0) > 0 ? 0 : 1
        var streak = 0
        while (perWeek[back] ?? 0) > 0 {
            streak += 1
            back += 1
        }
        self.streak = streak

        var byWeekday: [Int: Int] = [:]
        for (i, count) in counts.enumerated() {
            let date = calendar.date(byAdding: .day, value: i, to: rhythm.start) ?? rhythm.start
            byWeekday[calendar.component(.weekday, from: date), default: 0] += count
        }
        busiestWeekday = total < Self.minimum ? nil : byWeekday.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }
}

/// One of the Sensitivity tile's bars: the share of each level, lowest first.
public struct SensitivityMix: Sendable, Equatable {
    public struct Part: Sendable, Equatable, Identifiable {
        public var level: Sensitivity
        public var count: Int
        public var id: Sensitivity { level }
    }

    /// The levels with any memories, lowest first.
    public var parts: [Part]
    public var total: Int { parts.map(\.count).reduce(0, +) }

    /// From counts keyed by a sensitivity's name (`bySensitivity`, `sharedBySensitivity`).
    public init(_ counts: [String: Int]) {
        parts = Sensitivity.allCases.compactMap { level in
            let count = counts[level.name] ?? 0
            return count > 0 ? Part(level: level, count: count) : nil
        }
    }

    public func fraction(_ level: Sensitivity) -> Double {
        guard total > 0 else { return 0 }
        return Double(parts.first { $0.level == level }?.count ?? 0) / Double(total)
    }

    /// The level with the most memories; the lower one on a tie.
    public var largest: Part? { parts.max { ($0.count, $1.level) < ($1.count, $0.level) } }
}

extension VaultOverview {
    /// The calendar its days were counted in: the Mac's time zone.
    public var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        if let zone = TimeZone(identifier: timeZone) { calendar.timeZone = zone }
        return calendar
    }

    /// Who reads your vault: the agents that were shared something or asked in the range, most
    /// shared first.
    public func readers(_ limit: Int = 3) -> [AgentCount] {
        Array(agents.filter { $0.shared > 0 || $0.requests > 0 }.prefix(limit))
    }

    /// Nothing in the vault and nothing in its 12 weeks: Home's "Your pulse starts with your
    /// first memories".
    public var isNewVault: Bool {
        total == 0 && rhythm.counts.allSatisfy { $0 == 0 } && days.allSatisfy { $0.inbound.total == 0 && $0.shared == 0 && $0.refused == 0 }
    }
}
