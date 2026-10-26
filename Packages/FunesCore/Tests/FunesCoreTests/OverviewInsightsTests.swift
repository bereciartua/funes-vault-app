import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// Home's numbers from an overview (FR-H-02): the 7-day slice, the agents the chart names, the
/// growth line and the Rhythm card.
@Suite struct OverviewInsightsTests {
    /// Madrid, weeks from Monday (as OverviewTests).
    static var calendar: Calendar { OverviewTests.calendar }

    /// Friday 15 January 2027, as OverviewTests' t0.
    static var today: Date { calendar.startOfDay(for: t0) }

    static func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

    static func overview(days: [VaultOverview.Bucket], rhythm: [Int] = Array(repeating: 0, count: 84), total: Int = 0,
                         agents: [VaultOverview.AgentCount] = []) -> VaultOverview {
        VaultOverview(range: .days30, generatedAt: t0, timeZone: "Europe/Madrid", total: total, thisWeek: .init(), days: days,
                      rhythm: .init(start: day(-83), counts: rhythm), agents: agents)
    }

    static func agent(_ id: String, _ name: String) -> VaultOverview.AgentCount {
        VaultOverview.AgentCount(id: id, name: name, kind: .other, shared: 0, requests: 0)
    }

    /// 30 days where day `i` (0 the oldest) shares `i` with "a", one with "b".."f" on the last day,
    /// takes in `i` from the Mac and refuses one on even days.
    static var thirtyDays: [VaultOverview.Bucket] {
        (0..<30).map { i in
            var out = ["a": i]
            if i == 29 { for id in ["b", "c", "d", "e", "f"] { out[id] = 1 } }
            if i == 28 { out["e"] = 3 }
            return VaultOverview.Bucket(date: day(i - 29), inbound: .init(mac: i), out: out, refused: i % 2 == 0 ? 1 : 0)
        }
    }

    @Test func sevenDaysAreTheLastWeekOfThirty() {
        let insights = OverviewInsights(Self.overview(days: Self.thirtyDays), range: .days7, calendar: Self.calendar)
        #expect(insights.buckets.count == 7)
        #expect(insights.buckets.first?.date == Self.day(-6))
        #expect(insights.buckets.last?.date == Self.today)
        // In 23...29, refused on 24, 26, 28.
        let totals = insights.totals
        #expect(totals.inbound == (23...29).reduce(0, +))
        #expect(totals.refused == 3)
        #expect(totals.shared == (23...29).reduce(0, +) + 5 + 3)
        #expect(OverviewInsights.Range.days7.overviewRange == .days30)
        #expect(insights.interval(of: insights.buckets[0]) == DateInterval(start: Self.day(-6), end: Self.day(-5)))
    }

    @Test func topFourAgentsThenOther() {
        let agents = [Self.agent("a", "Claude Code"), Self.agent("b", "Cursor"), Self.agent("c", "Codex"),
                      Self.agent("d", "Zed"), Self.agent("e", "Windsurf"), Self.agent("f", "Goose")]
        let insights = OverviewInsights(Self.overview(days: Self.thirtyDays, agents: agents), range: .days30, calendar: Self.calendar)
        // a shares most, then e (4), then b, c, d, f tie at 1: by name, Codex, Cursor, Goose.
        #expect(insights.readers.map(\.agent.name) == ["Claude Code", "Windsurf", "Codex", "Cursor", "Goose", "Zed"])
        #expect(insights.outSeries == [.agent("a"), .agent("e"), .agent("c"), .agent("b"), .other])
        let last = insights.out(insights.buckets.last!)
        #expect(last.map(\.series) == [.agent("a"), .agent("e"), .agent("c"), .agent("b"), .other])
        #expect(last.map(\.count) == [29, 1, 1, 1, 2])
        // A day with only "a": no zero entries.
        #expect(insights.out(insights.buckets[5]).map(\.series) == [.agent("a")])
        #expect(insights.out(insights.buckets[0]).isEmpty)
    }

    @Test func fewAgentsHaveNoOther() {
        let days = [VaultOverview.Bucket(date: Self.today, out: ["a": 2, "gone": 1])]
        let insights = OverviewInsights(Self.overview(days: days, agents: [Self.agent("a", "Claude Code")]), range: .days7,
                                        calendar: Self.calendar)
        #expect(insights.outSeries == [.agent("a"), .agent("gone")])
        // An agent the overview no longer lists still counts, without a name.
        #expect(insights.readers.last?.agent.name == "")
    }

    @Test func growthWorksBackFromTheTotal() {
        var rhythm = Array(repeating: 0, count: 84)
        rhythm[83] = 2
        rhythm[80] = 3
        rhythm[0] = 50
        let insights = OverviewInsights(Self.overview(days: [], rhythm: rhythm, total: 40), range: .days30, calendar: Self.calendar)
        let growth = insights.growth
        #expect(growth.count == 84)
        #expect(growth[83] == 40)
        #expect(growth[82] == 38)
        #expect(growth[80] == 38)
        #expect(growth[79] == 35)
        // More came in than is active now (some archived since): never below zero.
        #expect(growth[0] == 35)
        #expect(OverviewInsights(Self.overview(days: [], rhythm: rhythm, total: 10), range: .days30, calendar: Self.calendar).growth[0] == 5)
    }

    @Test func rhythmGridStartsOnTheFirstWeekday() {
        // Day 0 is 83 days before Friday 15 January 2027: Saturday 24 October 2026.
        var rhythm = Array(repeating: 0, count: 84)
        rhythm[83] = 1
        rhythm[0] = 4
        let insights = OverviewInsights(Self.overview(days: [], rhythm: rhythm), range: .days30, calendar: Self.calendar)
        let grid = insights.grid
        // Monday-first: Saturday is row 5, so 5 empty cells lead; today is a Friday, so 2 trail.
        #expect(grid.count == 13)
        #expect(grid.allSatisfy { $0.count == 7 })
        #expect(grid[0][0...4].allSatisfy { $0 == nil })
        #expect(grid[0][5] == 4)
        #expect(grid[12][4] == 1)
        #expect(grid[12][5] == nil && grid[12][6] == nil)
        #expect(insights.date(column: 0, row: 5) == Self.day(-83))
        #expect(insights.date(column: 12, row: 4) == Self.today)
        #expect(insights.date(column: 0, row: 0) == nil)
    }

    @Test func busiestWeekdayAndStreak() {
        var rhythm = Array(repeating: 0, count: 84)
        // Fridays (day 83 is a Friday) in the last three weeks, twice on today's.
        for back in [0, 7, 14] { rhythm[83 - back] = 1 }
        rhythm[83] = 2
        // A Tuesday five weeks back, after a gap.
        rhythm[83 - 38] = 1
        let insights = OverviewInsights(Self.overview(days: [], rhythm: rhythm), range: .days30, calendar: Self.calendar)
        #expect(insights.busiestWeekday == 6)
        #expect(insights.streakWeeks == 3)
        #expect(insights.hasRhythm)

        // Nothing yet this week: last week's streak still stands.
        rhythm[83] = 0
        let quiet = OverviewInsights(Self.overview(days: [], rhythm: rhythm), range: .days30, calendar: Self.calendar)
        #expect(quiet.streakWeeks == 2)
        #expect(!quiet.hasRhythm)
    }

    @Test func noWeekdayStandsOut() {
        var rhythm = Array(repeating: 0, count: 84)
        rhythm[83] = 1
        rhythm[82] = 1
        let tie = OverviewInsights(Self.overview(days: [], rhythm: rhythm), range: .days30, calendar: Self.calendar)
        #expect(tie.busiestWeekday == nil)
        let empty = OverviewInsights(Self.overview(days: []), range: .days30, calendar: Self.calendar)
        #expect(empty.busiestWeekday == nil)
        #expect(empty.streakWeeks == 0)
    }
}
