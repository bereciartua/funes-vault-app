import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// The Home Screen widgets' entries (FR-H-06): their states, the days moved along at midnight,
/// "as of" after an hour and dimmed after a day, and the timeline's dates.
@Suite struct WidgetSnapshotTests {
    /// Monday-first weeks in UTC; `t0` is Friday 15 January 2027, 08:00.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    var today: Date { Self.calendar.startOfDay(for: t0) }

    func day(_ offset: Int) -> Date { Self.calendar.date(byAdding: .day, value: offset, to: today)! }

    /// 30 days ending today: one new memory a day, 2 shared with "a" every other day (yesterday,
    /// the day before's day before…) and 1 with "b" today, 1 refused yesterday; the rhythm's 84
    /// days one a day.
    var overview: VaultOverview {
        let days = (0..<30).map { i in
            VaultOverview.Bucket(date: day(i - 29), inbound: .init(iphone: 1),
                                 out: (i.isMultiple(of: 2) ? ["a": 2] : [:]).merging(i == 29 ? ["b": 1] : [:]) { $0 + $1 },
                                 refused: i == 28 ? 1 : 0)
        }
        return VaultOverview(range: .days30, generatedAt: t0, timeZone: "UTC", total: 120,
                             thisWeek: .init(saved: 7, shared: 9, agents: 2, refused: 1), days: days,
                             rhythm: .init(start: day(-83), counts: Array(repeating: 1, count: 84)),
                             agents: [.init(id: "a", name: "A", kind: .claudeCode, shared: 30, requests: 15),
                                      .init(id: "b", name: "B", kind: .cursor, shared: 1, requests: 1)])
    }

    func notAsked() -> Bool? {
        Issue.record("The Keychain was asked")
        return false
    }

    @Test func statesFromTheCacheAndThePairing() {
        let cached = OverviewCache.Contents(overviews: [.days30: overview])
        #expect(WidgetSnapshot(date: t0, cache: cached, paired: true).content == .overview(overview))
        // Before the first unlock the Keychain can't say: the cache decides.
        #expect(WidgetSnapshot(date: t0, cache: cached, paired: nil).content == .overview(overview))
        // The app deletes the counts on unpair: with them, the Keychain isn't asked.
        #expect(WidgetSnapshot(date: t0, cache: cached, paired: notAsked()).content == .overview(overview))
        #expect(WidgetSnapshot(date: t0, cache: .init(), paired: false).content == .notPaired)
        #expect(WidgetSnapshot(date: t0, cache: .init(), paired: nil).content == .waiting)
        #expect(WidgetSnapshot(date: t0, cache: .init(), paired: true).content == .waiting)
        // Only the longer ranges cached: nothing for the widgets yet.
        var weeks = overview
        weeks.range = .weeks12
        #expect(WidgetSnapshot(date: t0, cache: .init(overviews: [.weeks12: weeks]), paired: true).content == .waiting)

        // The demo is never paired, and labelled.
        let demo = WidgetSnapshot(date: t0, cache: .init(overviews: [.days30: overview], isDemo: true), paired: false)
        #expect(demo.isDemo && demo.overview == overview)
        #expect(demo.at(t0 + 3 * 86_400).freshness == .fresh)
    }

    @Test func asOfAfterAnHourDimmedAfterADay() {
        let snapshot = WidgetSnapshot(date: t0, cache: .init(overviews: [.days30: overview]), paired: true)
        #expect(snapshot.freshness == .fresh)
        #expect(snapshot.at(t0 + 3_599).freshness == .fresh)
        #expect(snapshot.at(t0 + 3_600).freshness == .asOf)
        #expect(snapshot.at(t0 + 86_399).freshness == .asOf)
        #expect(snapshot.at(t0 + 86_400).freshness == .stale)
        #expect(WidgetSnapshot(date: t0, content: .waiting).freshness == .fresh)
    }

    @Test func theSameDayIsUnchanged() {
        #expect(overview.moved(to: t0) == overview)
        #expect(overview.moved(to: day(1) - 1) == overview)
        #expect(overview.moved(to: day(-3)) == overview)
        var weeks = overview
        weeks.range = .weeks12
        #expect(weeks.moved(to: day(5)) == weeks)
    }

    /// Two days later: the two oldest days drop out, two empty ones end the chart, and this
    /// week's numbers come from the days that are left in it.
    @Test func midnightMovesTheDaysAlong() {
        let moved = overview.moved(to: day(2) + 60)
        #expect(moved.days.count == 30)
        #expect(moved.days.first?.date == day(-27))
        #expect(moved.days.last?.date == day(2))
        #expect(moved.days.suffix(2).allSatisfy { $0.inbound.total == 0 && $0.shared == 0 && $0.refused == 0 })
        #expect(Array(moved.days.prefix(28)) == Array(overview.days.suffix(28)))

        #expect(moved.rhythm.counts.count == 84)
        #expect(moved.rhythm.start == day(-81))
        #expect(moved.rhythm.counts.suffix(2) == [0, 0])
        #expect(moved.rhythm.counts.prefix(82).allSatisfy { $0 == 1 })

        // Days -4…2: five of them had a memory; "a" shared on days -3 and -1, "b" on day 0.
        #expect(moved.thisWeek == VaultOverview.Week(saved: 5, shared: 5, agents: 2, refused: 1))
        #expect(moved.agents.map(\.shared) == [28, 1])
        #expect(moved.total == overview.total)

        // A month away: nothing left in 30 days, but the rhythm still has its oldest weeks.
        let later = overview.moved(to: day(40))
        #expect(later.days.allSatisfy { $0.inbound.total == 0 && $0.shared == 0 })
        #expect(later.thisWeek == VaultOverview.Week())
        #expect(later.agents.map(\.shared) == [0, 0])
        #expect(later.rhythm.counts.prefix(44).allSatisfy { $0 == 1 } && later.rhythm.counts.suffix(40).allSatisfy { $0 == 0 })
        // Pulse names no agent once none has shared.
        #expect(Pulse(later, last: 14).agents.isEmpty)
    }

    /// The days are the Mac's: midnight in its time zone, across a daylight saving change.
    @Test func movesInTheMacsTimeZone() throws {
        var madrid = Calendar(identifier: .gregorian)
        madrid.timeZone = try #require(TimeZone(identifier: "Europe/Madrid"))
        // Saturday 27 March 2027, the day before summer time.
        let start = try #require(madrid.date(from: DateComponents(year: 2027, month: 3, day: 27)))
        let days = (0..<30).map { VaultOverview.Bucket(date: madrid.date(byAdding: .day, value: $0 - 29, to: start)!, inbound: .init(mac: 1)) }
        let o = VaultOverview(range: .days30, generatedAt: start, timeZone: "Europe/Madrid", total: 30, thisWeek: .init(saved: 7),
                              days: days, rhythm: .init(start: madrid.date(byAdding: .day, value: -83, to: start)!,
                                                        counts: Array(repeating: 1, count: 84)))
        let monday = try #require(madrid.date(from: DateComponents(year: 2027, month: 3, day: 29, hour: 0, minute: 30)))
        let moved = o.moved(to: monday)
        #expect(moved.days.last?.date == madrid.startOfDay(for: monday))
        #expect(moved.days.map(\.inbound.total).suffix(3) == [1, 0, 0])
        #expect(moved.thisWeek.saved == 5)
    }

    @Test func theTimelineLooksAgainWhenSomethingChanges() {
        let dates = WidgetSnapshot.dates(from: t0 + 600, generatedAt: t0, calendar: Self.calendar)
        #expect(dates == [t0 + 600, t0 + 3_600, day(1), t0 + 86_400, day(2)])
        // Already over a day old: now and the midnights.
        #expect(WidgetSnapshot.dates(from: t0 + 90_000, generatedAt: t0, calendar: Self.calendar) == [t0 + 90_000, day(2), day(3)])
        #expect(WidgetSnapshot.dates(from: t0, generatedAt: nil, calendar: Self.calendar, midnights: 1) == [t0, day(1)])
    }
}
