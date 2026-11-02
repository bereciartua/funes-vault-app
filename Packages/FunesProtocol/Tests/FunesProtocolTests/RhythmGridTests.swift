import Foundation
import Testing
@testable import FunesProtocol

// The Rhythm grid (UX: Mac ▸ Home ▸ Rhythm card; iPhone ▸ Home tab, Pulse sheet, Rhythm widget):
// its weeks, the days still to come, the shades, the streak and the busiest weekday, and how it
// fits a box.
@Suite struct RhythmGridTests {
    /// Monday-first weeks in UTC; today is Friday 15 January 2027.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    static let today = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15))!

    func day(_ offset: Int) -> Date { Self.calendar.date(byAdding: .day, value: offset, to: Self.today)! }

    /// 84 days ending today, with `counts` as the last days.
    func rhythm(_ last: [Int], saved: [Int]? = nil) -> VaultOverview.Rhythm {
        let pad = { (xs: [Int]) in Array(repeating: 0, count: 84 - xs.count) + xs }
        return VaultOverview.Rhythm(start: day(-83), counts: pad(last), saved: saved.map(pad))
    }

    @Test func endsWithThisWeekAndItsDaysToCome() {
        // Today is a Friday: the last column is Monday 11 to Sunday 17 January.
        let grid = RhythmGrid(rhythm([1, 0, 2]), weeks: 8, calendar: Self.calendar)
        #expect(grid.cells.count == 56)
        let last = grid.cells.suffix(7)
        #expect(last.first?.date == day(-4))
        #expect(last.map(\.count) == [0, 0, 1, 0, 2, nil, nil])
        #expect(last.map(\.isToday) == [false, false, false, false, true, false, false])
        #expect(grid.cells.first?.row == 0 && grid.cells.first?.week == 0)
        #expect(grid.cells.last?.week == 7 && grid.cells.last?.row == 6)
        #expect(grid.peak == 2 && grid.total == 3)
        #expect(grid.isTooSparse && grid.busiestWeekday == nil)

        // Weeks before the overview's first day are days with none, not gaps.
        let wide = RhythmGrid(rhythm([1]), weeks: 20, calendar: Self.calendar)
        #expect(wide.cells.first?.count == 0)
    }

    @Test func countsWhatYouSaved() {
        // A tidy-up run of 40 isn't yours; without `saved` (a Mac before v0.6) everything counts.
        let tidy = rhythm([2, 40, 1], saved: [2, 0, 1])
        #expect(tidy.savedCounts.suffix(3) == [2, 0, 1])
        let grid = RhythmGrid(tidy, weeks: 2, calendar: Self.calendar)
        #expect(grid.peak == 2 && grid.total == 3)
        #expect(RhythmGrid(rhythm([2, 40, 1]), weeks: 2, calendar: Self.calendar).peak == 40)
    }

    @Test func shadesFollowTheQuartiles() {
        // One busy day doesn't wash out the rest.
        let grid = RhythmGrid(rhythm([1, 2, 3, 4, 5, 6, 7, 8, 60]), weeks: 3, calendar: Self.calendar)
        #expect(grid.level(0) == nil)
        #expect(grid.level(1) == 0)
        #expect(grid.level(4) == 1)
        #expect(grid.level(6) == 2)
        #expect(grid.level(8) == 3 && grid.level(60) == 3)
        // Days all alike take the third shade, not the faintest.
        let even = RhythmGrid(rhythm([1, 1, 1, 0, 1]), weeks: 2, calendar: Self.calendar)
        #expect(even.level(1) == 2)
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

        // Thursday and Friday tied: the first of them.
        let tie = RhythmGrid(rhythm([3, 3]), weeks: 2, calendar: Self.calendar)
        #expect(!tie.isTooSparse && tie.busiestWeekday == 5)
    }

    @Test func wordsLookAtTwelveWeeks() {
        // 53 weeks, with 10 saved a year ago and 2 lately: too few for a rhythm, but a long streak.
        var counts = Array(repeating: 1, count: VaultOverview.Rhythm.days)
        for i in counts.indices.dropLast(84) { counts[i] = i == 0 ? 10 : 1 }
        for i in counts.indices.suffix(84) { counts[i] = 0 }
        counts[counts.count - 1] = 2
        let start = day(1 - VaultOverview.Rhythm.days)
        let grid = RhythmGrid(VaultOverview.Rhythm(start: start, counts: counts), weeks: 4, calendar: Self.calendar)
        #expect(grid.total == 2 && grid.isTooSparse)
        #expect(grid.streak == 1)
    }

    @Test func sundayFirstAcrossADaylightSavingChange() {
        // New York, Sunday-first; today is Monday 2 November 2026, the day after clocks went back.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let start = calendar.date(byAdding: .day, value: -83, to: today)!
        var counts = Array(repeating: 0, count: 84)
        counts[83] = 2
        counts[82] = 1
        let grid = RhythmGrid(VaultOverview.Rhythm(start: start, counts: counts), weeks: 3, calendar: calendar)
        let last = grid.cells.suffix(7)
        // The last column is Sunday 1 to Saturday 7 November: Sunday and Monday, then five to come.
        #expect(last.first?.date == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(last.map(\.count) == [1, 2, nil, nil, nil, nil, nil])
        #expect(last.map(\.row) == Array(0..<7) && last.dropFirst().first?.isToday == true)
        // The first column starts on a Sunday too, before the change.
        #expect(calendar.component(.weekday, from: grid.cells[0].date) == 1)
    }

    @Test func fitFillsTheWidth() {
        // A small widget's grid: 138 × 86 with 3 between squares.
        let small = RhythmGrid.Fit(width: 138, height: 86, spacing: 3, maxSide: 16)
        #expect(small.side == 9 && small.weeks == 11)
        #expect(abs(small.origin(week: small.weeks - 1, row: 0).x + small.side - 138) < 0.001)
        #expect(small.height <= 86)
        #expect(small.columnSpacing >= 3)

        // The same height in a medium widget: the same squares, more weeks.
        let medium = RhythmGrid.Fit(width: 332, height: 86, spacing: 3, maxSide: 16)
        #expect(medium.side == 9 && medium.weeks == 27)

        // A tall box keeps its squares to `maxSide`; a very wide one to the overview's weeks.
        #expect(RhythmGrid.Fit(width: 300, height: 400, spacing: 3, maxSide: 14).side == 14)
        let wide = RhythmGrid.Fit(width: 4_000, height: 86, spacing: 3)
        #expect(wide.weeks == VaultOverview.Rhythm.days / 7)
        // Too narrow for two: one column.
        #expect(RhythmGrid.Fit(width: 5, height: 86, spacing: 3).weeks == 1)
    }

    @Test func lastDays() {
        let all = VaultOverview.Rhythm(start: day(-9), counts: Array(0..<10), saved: Array(10..<20))
        let last = all.last(4, calendar: Self.calendar)
        #expect(last.start == day(-3) && last.counts == [6, 7, 8, 9] && last.saved == [16, 17, 18, 19])
        #expect(all.last(30, calendar: Self.calendar) == all)
    }

    @Test func savedSkipsImportsAndTidyUp() {
        #expect(MemorySource.allCases.filter { !$0.countsAsSaved }
            == [.importChatGPT, .importClaude, .importMarkdown, .importFunes, .tidyUp])
    }
}
