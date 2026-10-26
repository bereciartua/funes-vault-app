import Foundation
import FunesProtocol

// What the Home Screen widgets show (FR-H-06, UX: iPhone ▸ Widgets): the cached 30-day overview
// (ADR-0025) moved along to the moment shown, how fresh it is, and when to look again. The
// widgets never call the Mac; the views are the Intents extension's.

/// One entry of the widgets' timeline.
public struct WidgetSnapshot: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// Not paired and not in the demo: "Pair with your Mac" (Remember still works, captures
        /// queue).
        case notPaired
        /// Paired, but the app hasn't cached the counts yet.
        case waiting
        /// The 30-day overview, moved along to the entry's day.
        case overview(VaultOverview)
    }

    /// How old the counts are: nothing said under an hour, "as of 10:42" after that, and dimmed
    /// after a day.
    public enum Freshness: Sendable, Equatable {
        case fresh, asOf, stale

        public static let asOfAfter: TimeInterval = 3_600
        public static let staleAfter: TimeInterval = 86_400

        public init(generatedAt: Date, now: Date) {
            let age = now.timeIntervalSince(generatedAt)
            self = age >= Self.staleAfter ? .stale : age >= Self.asOfAfter ? .asOf : .fresh
        }
    }

    public var date: Date
    public var content: Content
    /// The demo vault's counts: labelled **DEMO**, never "as of".
    public var isDemo: Bool

    public init(date: Date, content: Content, isDemo: Bool = false) {
        self.date = date
        self.content = content
        self.isDemo = isDemo
    }

    /// What to show at `date`: the cached counts, which the app deletes on unpair and revocation;
    /// without them, whether this iPhone holds a pairing says Not paired from not yet (`paired`
    /// is only asked then; nil when the Keychain couldn't say, before the first unlock).
    public init(date: Date, cache: OverviewCache.Contents, paired: @autoclosure () -> Bool?) {
        self.date = date
        isDemo = cache.isDemo
        if let overview = cache.overviews[.days30] {
            content = .overview(overview.moved(to: date))
        } else if !cache.isDemo, paired() == false {
            content = .notPaired
        } else {
            content = .waiting
        }
    }

    public var overview: VaultOverview? {
        if case let .overview(overview) = content { overview } else { nil }
    }

    /// Fresh for the demo and while there are no counts.
    public var freshness: Freshness {
        guard !isDemo, let overview else { return .fresh }
        return Freshness(generatedAt: overview.generatedAt, now: date)
    }

    /// The same snapshot at a later `date`: the days moved along, the freshness worked out again.
    public func at(_ date: Date) -> WidgetSnapshot {
        var later = self
        later.date = date
        if case let .overview(overview) = content { later.content = .overview(overview.moved(to: date)) }
        return later
    }

    /// The timeline's dates: `now`, when "as of" and the dimming begin (if still ahead), and the
    /// next `midnights` midnights in `calendar` (the Mac's, whose days the overview counts),
    /// which move the days along.
    public static func dates(from now: Date, generatedAt: Date?, calendar: Calendar, midnights: Int = 2) -> [Date] {
        var dates: Set<Date> = [now]
        if let generatedAt {
            for later in [generatedAt + Freshness.asOfAfter, generatedAt + Freshness.staleAfter] where later > now {
                dates.insert(later)
            }
        }
        var day = calendar.startOfDay(for: now)
        for _ in 0..<midnights {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            dates.insert(next)
            day = next
        }
        return dates.sorted()
    }
}

extension VaultOverview {
    /// The 30-day overview as it reads on `date`'s day, when that's after its last: the days
    /// since are empty, the oldest drop out, and this week's numbers and the agents' shared
    /// counts are worked out again from the days. Unchanged on its own day, or for the longer
    /// ranges. The sensitivity and category totals stay as they were (no widget shows them).
    public func moved(to date: Date) -> VaultOverview {
        guard range == .days30, let last = days.last else { return self }
        let calendar = self.calendar
        let today = calendar.startOfDay(for: date)
        guard let shift = calendar.dateComponents([.day], from: last.date, to: today).day, shift > 0 else { return self }

        var moved = self
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        moved.days = (0..<days.count).map { i in
            let day = calendar.date(byAdding: .day, value: i - days.count + 1, to: today) ?? today
            return byDate[day] ?? Bucket(date: day)
        }

        let n = rhythm.counts.count
        let start = calendar.date(byAdding: .day, value: 1 - n, to: today) ?? today
        let offset = calendar.dateComponents([.day], from: rhythm.start, to: start).day ?? 0
        moved.rhythm = Rhythm(start: start, counts: (0..<n).map { i in
            rhythm.counts.indices.contains(i + offset) ? rhythm.counts[i + offset] : 0
        })

        let week = moved.days.suffix(7)
        let weekAgents = Set(week.flatMap { $0.out.filter { $0.value > 0 }.keys })
        moved.thisWeek = Week(saved: moved.rhythm.counts.suffix(7).reduce(0, +), shared: week.map(\.shared).reduce(0, +),
                              agents: weekAgents.count, refused: week.map(\.refused).reduce(0, +))

        var shared: [String: Int] = [:]
        for bucket in moved.days { shared.merge(bucket.out, uniquingKeysWith: +) }
        moved.agents = agents
            .map { agent in
                var agent = agent
                agent.shared = shared[agent.id] ?? 0
                return agent
            }
            .sorted { ($0.shared, $0.requests, $1.name) > ($1.shared, $1.requests, $0.name) }
        return moved
    }
}
