import Foundation
import FunesProtocol

/// What the Mac's Home draws from a `VaultOverview` (FR-H-02, 04-ux-mac.md ▸ Home): the pulse's
/// buckets for each range, the agents the chart names, the vault's growth line and the Rhythm
/// card's grid, most active weekday and streak. Numbers only; the app words them.
public struct OverviewInsights: Sendable {
    /// The chart's ranges. 7 days is the last week of the 30-day overview.
    public enum Range: String, CaseIterable, Sendable, Identifiable {
        case days7 = "7d"
        case days30 = "30d"
        case weeks12 = "12w"
        case months12 = "12m"

        public var id: String { rawValue }

        /// The overview read that holds this range.
        public var overviewRange: OverviewRange {
            switch self {
            case .days7, .days30: .days30
            case .weeks12: .weeks12
            case .months12: .months12
            }
        }

        public var bucketCount: Int { self == .days7 ? 7 : overviewRange.bucketCount }
    }

    /// The chart's Out series: the top agents by memories shared in the range, then everyone else.
    public enum OutSeries: Hashable, Sendable {
        case agent(String)
        case other
    }

    public static let outLimit = 4

    public let overview: VaultOverview
    public let range: Range
    public let calendar: Calendar

    /// `overview` must be `range.overviewRange`'s.
    public init(_ overview: VaultOverview, range: Range, calendar: Calendar) {
        self.overview = overview
        self.range = range
        self.calendar = calendar
    }

    /// The range's buckets, oldest first.
    public var buckets: [VaultOverview.Bucket] { Array(overview.days.suffix(range.bucketCount)) }

    /// Memories shared in the range, per agent id.
    public var sharedByAgent: [String: Int] {
        buckets.reduce(into: [:]) { totals, bucket in
            for (agent, n) in bucket.out { totals[agent, default: 0] += n }
        }
    }

    /// Agents that were shared something in the range, most first (ties by name), with their count.
    public var readers: [(agent: VaultOverview.AgentCount, shared: Int)] {
        let shared = sharedByAgent
        let names = Dictionary(overview.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return shared.compactMap { id, n -> (VaultOverview.AgentCount, Int)? in
            guard n > 0 else { return nil }
            // An agent the overview didn't list (removed before the range) still counts, unnamed.
            return (names[id] ?? VaultOverview.AgentCount(id: id, name: "", kind: .other, shared: n, requests: 0), n)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
        .map { (agent: $0.0, shared: $0.1) }
    }

    /// The Out series in stacking order: up to four agents, then Other when anyone else shared.
    public var outSeries: [OutSeries] {
        let readers = readers
        var series = readers.prefix(Self.outLimit).map { OutSeries.agent($0.agent.id) }
        if readers.count > Self.outLimit { series.append(.other) }
        return series
    }

    /// A bucket's Out counts by series, in `outSeries`' order, leaving out zeros.
    public func out(_ bucket: VaultOverview.Bucket) -> [(series: OutSeries, count: Int)] {
        let series = outSeries
        let named = Set(series.compactMap { if case .agent(let id) = $0 { id } else { nil } })
        var result: [(OutSeries, Int)] = series.compactMap { s in
            guard case .agent(let id) = s, let n = bucket.out[id], n > 0 else { return nil }
            return (s, n)
        }
        let other = bucket.out.filter { !named.contains($0.key) }.values.reduce(0, +)
        if other > 0 { result.append((.other, other)) }
        return result.map { (series: $0.0, count: $0.1) }
    }

    /// The range's totals: memories in, memories shared, requests refused.
    public var totals: (inbound: Int, shared: Int, refused: Int) {
        buckets.reduce(into: (0, 0, 0)) { totals, bucket in
            totals.0 += bucket.inbound.total
            totals.1 += bucket.shared
            totals.2 += bucket.refused
        }
    }

    /// A bucket's span: its day, week or month.
    public func interval(of bucket: VaultOverview.Bucket) -> DateInterval {
        let unit: Calendar.Component = switch range.overviewRange {
        case .days30: .day
        case .weeks12: .weekOfYear
        case .months12: .month
        }
        let end = calendar.date(byAdding: unit, value: 1, to: bucket.date) ?? bucket.date.addingTimeInterval(86_400)
        return DateInterval(start: bucket.date, end: end)
    }

    // MARK: The vault's shape

    /// Active memories at the end of each of the rhythm's 84 days, the last being now: the
    /// Memories card's line. Worked back from the total, so memories archived or deleted since
    /// count as if they'd never come in; never below zero.
    public var growth: [Int] {
        var size = overview.total
        var points = Array(repeating: 0, count: overview.rhythm.counts.count)
        for i in points.indices.reversed() {
            points[i] = max(0, size)
            size -= overview.rhythm.counts[i]
        }
        return points
    }

    /// Whether the rhythm has enough to say: at least 5 new memories in its 12 weeks.
    public var hasRhythm: Bool { overview.rhythm.counts.reduce(0, +) >= 5 }

    /// The weekday (1 is Sunday, as `Calendar` numbers them) with the most new memories in the
    /// rhythm's 12 weeks; nil when there are none, or when two weekdays tie for the most.
    public var busiestWeekday: Int? {
        var totals = [Int: Int]()
        for (i, n) in overview.rhythm.counts.enumerated() { totals[weekday(ofDay: i), default: 0] += n }
        guard let best = totals.values.max(), best > 0, totals.values.filter({ $0 == best }).count == 1 else { return nil }
        return totals.first { $0.value == best }?.key
    }

    /// Weeks in a row, up to this one, with a new memory. A week with nothing yet doesn't break
    /// the streak until it's over.
    public var streakWeeks: Int {
        let columns = grid
        var weeks = columns.map { $0.contains { ($0 ?? 0) > 0 } }
        if weeks.last == false { weeks.removeLast() }
        return weeks.reversed().prefix { $0 }.count
    }

    /// The Rhythm grid: one column per calendar week (oldest first), seven rows from the
    /// calendar's first weekday. Days outside the rhythm's 84 (before its start, after today)
    /// are nil.
    public var grid: [[Int?]] {
        let counts = overview.rhythm.counts
        guard !counts.isEmpty else { return [] }
        let lead = (weekday(ofDay: 0) - calendar.firstWeekday + 7) % 7
        let cells: [Int?] = Array(repeating: nil, count: lead) + counts.map(Optional.some)
        let padded = cells + Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        return stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0..<$0 + 7]) }
    }

    /// The date of the grid's cell, or nil outside the rhythm.
    public func date(column: Int, row: Int) -> Date? {
        let lead = (weekday(ofDay: 0) - calendar.firstWeekday + 7) % 7
        let day = column * 7 + row - lead
        guard overview.rhythm.counts.indices.contains(day) else { return nil }
        return calendar.date(byAdding: .day, value: day, to: overview.rhythm.start)
    }

    private func weekday(ofDay index: Int) -> Int {
        let date = calendar.date(byAdding: .day, value: index, to: overview.rhythm.start) ?? overview.rhythm.start
        return calendar.component(.weekday, from: date)
    }
}
