import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// Home's charts from an overview (FR-H-04): the pulse's stacks, the growth line, the Rhythm grid
/// and its streak, the sensitivity mixes, who reads, and a new vault.
@Suite struct OverviewDigestTests {
    /// Monday-first weeks in UTC; `t0` is Friday 15 January 2027, 08:00.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    var today: Date { Self.calendar.startOfDay(for: t0) }

    func day(_ offset: Int) -> Date { Self.calendar.date(byAdding: .day, value: offset, to: today)! }

    /// 84 days ending today, with `counts` as the last days.
    func rhythm(_ last: [Int]) -> VaultOverview.Rhythm {
        VaultOverview.Rhythm(start: day(-83), counts: Array(repeating: 0, count: 84 - last.count) + last)
    }

    func overview(days: [VaultOverview.Bucket], agents: [VaultOverview.AgentCount] = [], total: Int = 0,
                  rhythm: VaultOverview.Rhythm? = nil) -> VaultOverview {
        VaultOverview(range: .days30, generatedAt: t0, timeZone: "UTC", total: total, thisWeek: .init(), days: days,
                      rhythm: rhythm ?? self.rhythm([]), agents: agents)
    }

    func agent(_ id: String, shared: Int, requests: Int = 1) -> VaultOverview.AgentCount {
        VaultOverview.AgentCount(id: id, name: id.uppercased(), kind: .claudeCode, shared: shared, requests: requests)
    }

    @Test func pulseNamesTheTopAgentsAndFoldsTheRest() {
        let days = (0..<30).map { i in
            VaultOverview.Bucket(date: day(i - 29), inbound: .init(mac: 1, iphone: i == 29 ? 2 : 0),
                                 out: i.isMultiple(of: 2) ? ["a": 3, "b": 2, "c": 1, "d": 1, "e": 1] : [:], refused: i == 28 ? 1 : 0)
        }
        let o = overview(days: days, agents: [agent("a", shared: 45), agent("b", shared: 30), agent("c", shared: 15),
                                              agent("d", shared: 15), agent("e", shared: 15), agent("idle", shared: 0)])
        let pulse = Pulse(o)
        #expect(pulse.unit == .day)
        #expect(pulse.agents.map(\.name) == ["A", "B", "C", nil])
        #expect(pulse.agents.map(\.slot) == [0, 1, 2, 3])
        #expect(pulse.buckets.count == 30)
        #expect(pulse.buckets[0].out == [3, 2, 1, 2])
        #expect(pulse.inbound == 32 && pulse.shared == 15 * 8 && pulse.refused == 1)
        #expect(pulse.peakIn == 3 && pulse.peakOut == 8)

        // The last week keeps the 30 days' agents, so their colours stay.
        let week = Pulse(o, last: 7)
        #expect(week.buckets.count == 7 && week.buckets.last?.date == today)
        #expect(week.agents == pulse.agents)
        #expect(week.inbound == 9 && week.refused == 1)

        #expect(pulse.bucket(at: day(-3).addingTimeInterval(3_600))?.date == day(-3))
        #expect(pulse.bucket(at: t0)?.date == today)
        #expect(pulse.bucket(at: day(-40)) == nil)
    }

    @Test func pulseWithoutAgentsHasNoOther() {
        let o = overview(days: [VaultOverview.Bucket(date: today, inbound: .init(tidy: 2))])
        let pulse = Pulse(o)
        #expect(pulse.agents.isEmpty)
        #expect(pulse.buckets.map(\.out) == [[]])
        #expect(!pulse.isEmpty)
        #expect(Pulse(overview(days: [VaultOverview.Bucket(date: today)])).isEmpty)
    }

    @Test func pulseRanges() {
        #expect(PulseRange.days7.overview == .days30 && PulseRange.days7.last == 7)
        #expect(PulseRange.days30.last == nil)
        #expect(PulseRange.weeks12.overview == .weeks12 && PulseRange.months12.overview == .months12)
    }

    /// Today's total, less what came in since each week ended.
    @Test func growthCountsBackFromTodaysTotal() {
        let counts = Array(repeating: 1, count: 84)
        let growth = Growth(total: 100, rhythm: rhythm(counts), calendar: Self.calendar)
        #expect(growth.points.count == 13)
        #expect(growth.points.first?.total == 16)
        #expect(growth.points.last?.total == 100)
        #expect(growth.points.map(\.total) == stride(from: 16, through: 100, by: 7).map { $0 })
        #expect(growth.points.first?.date == day(-83))

        // Never below zero, as when memories were deleted.
        #expect(Growth(total: 3, rhythm: rhythm([5]), calendar: Self.calendar).points.first?.total == 0)
    }

    @Test func rhythmGridEndsWithThisWeek() {
        // Today is a Friday: the last column is Monday 11 to Sunday 17 January.
        let grid = RhythmGrid(rhythm([1, 0, 2]), weeks: 8, calendar: Self.calendar)
        #expect(grid.cells.count == 56)
        let last = grid.cells.suffix(7)
        #expect(last.first?.date == day(-4))
        #expect(last.map(\.count) == [0, 0, 1, 0, 2, nil, nil])
        #expect(grid.cells.first?.row == 0 && grid.cells.first?.week == 0)
        #expect(grid.cells.last?.week == 7 && grid.cells.last?.row == 6)
        #expect(grid.peak == 2 && grid.total == 3)
        #expect(grid.isTooSparse && grid.busiestWeekday == nil)

        // 12 weeks reach back before the overview's first day.
        let all = RhythmGrid(rhythm([1]), weeks: 13, calendar: Self.calendar)
        #expect(all.cells.first?.count == nil)
    }

    @Test func streakCountsWeeksUpToThisOne() {
        // This week (Mon–Fri) and the two before it.
        let three = RhythmGrid(rhythm([1] + Array(repeating: 0, count: 6) + [1] + Array(repeating: 0, count: 6) + [1, 0, 0, 0, 0]),
                               weeks: 8, calendar: Self.calendar)
        #expect(three.streak == 3)
        // Nothing yet this week: the streak still stands on last week's.
        let waiting = RhythmGrid(rhythm([2] + Array(repeating: 0, count: 6) + [1] + Array(repeating: 0, count: 6) + [0, 0, 0, 0, 0]),
                                 weeks: 8, calendar: Self.calendar)
        #expect(waiting.streak == 2)
        // A week without a memory breaks it.
        let broken = RhythmGrid(rhythm([1] + Array(repeating: 0, count: 13) + [0, 0, 0, 0, 1]), weeks: 8, calendar: Self.calendar)
        #expect(broken.streak == 1)
        #expect(RhythmGrid(rhythm([]), weeks: 8, calendar: Self.calendar).streak == 0)
    }

    @Test func busiestWeekday() {
        // Fridays (today, a week ago…) have 3, other days 0 or 1.
        var counts = Array(repeating: 0, count: 84)
        for i in stride(from: 83, through: 0, by: -7) { counts[i] = 3 }
        counts[80] = 1
        let grid = RhythmGrid(VaultOverview.Rhythm(start: day(-83), counts: counts), weeks: 8, calendar: Self.calendar)
        #expect(grid.busiestWeekday == 6)
        #expect(!grid.isTooSparse)
    }

    @Test func sensitivityMix() {
        let mix = SensitivityMix(["low": 6, "internal": 2, "secret": 0, "unknown": 9])
        #expect(mix.parts.map(\.level) == [.low, .internal])
        #expect(mix.total == 8)
        #expect(mix.fraction(.low) == 0.75 && mix.fraction(.secret) == 0)
        #expect(mix.largest?.level == .low)
        #expect(SensitivityMix(["public": 2, "sensitive": 2]).largest?.level == .public)
        #expect(SensitivityMix([:]).fraction(.low) == 0)
    }

    @Test func readersAndANewVault() {
        let o = overview(days: [VaultOverview.Bucket(date: today)],
                         agents: [agent("a", shared: 5), agent("asked", shared: 0, requests: 2), agent("idle", shared: 0, requests: 0),
                                  agent("b", shared: 1), agent("c", shared: 1)])
        #expect(o.readers().map(\.id) == ["a", "asked", "b"])
        #expect(o.isNewVault)
        #expect(!overview(days: [], total: 1).isNewVault)
        #expect(!overview(days: [], rhythm: rhythm([1])).isNewVault)
        #expect(o.calendar.timeZone.secondsFromGMT() == 0)
    }

    /// The demo's overview draws a full Home.
    @Test func theDemoFillsEveryChart() async throws {
        let vault = DemoVault(calendar: Self.calendar, clock: { t0 })
        let o = try await vault.overview(.days30)
        let pulse = Pulse(o)
        #expect(pulse.agents.map(\.name) == ["Claude Code", "Cursor", "Codex"])
        #expect(!pulse.isEmpty && pulse.refused > 0)
        #expect(Growth(o).points.last?.total == o.total)
        let grid = RhythmGrid(o.rhythm, weeks: 8, calendar: o.calendar)
        #expect(!grid.isTooSparse && grid.streak > 0 && grid.busiestWeekday != nil)
        #expect(SensitivityMix(o.bySensitivity).total == o.total)
        #expect(!o.isNewVault && o.readers().count == 3)
    }
}
