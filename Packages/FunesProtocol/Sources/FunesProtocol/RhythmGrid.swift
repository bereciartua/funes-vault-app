import Foundation

/// The Rhythm grid (UX: Mac ▸ Home ▸ Rhythm card; iPhone ▸ Home tab, the Pulse sheet and the
/// Rhythm widget), like GitHub's: a square per day, a column per calendar week, a row per weekday,
/// the last column this week with its days still to come. Every surface fits as many weeks as its
/// width holds at a square that fits seven rows in its height (`Fit`), so the grid always fills it.
///
/// It counts the memories you saved (`Rhythm.savedCounts`: not imports or tidy-up). A day is
/// shaded in four steps from the quartiles of the shown days with any, so one busy day doesn't
/// wash out the rest; days before the vault, or before the overview's, show as days with none.
/// With the streak and the busiest weekday, which its words use.
public struct RhythmGrid: Sendable, Equatable {
    public struct Cell: Sendable, Equatable, Identifiable {
        public var date: Date
        /// Column, oldest week first.
        public var week: Int
        /// Row, from the calendar's first weekday.
        public var row: Int
        /// Memories saved that day (0 before the overview's days); nil for the days after today.
        public var count: Int?
        public var isToday: Bool
        public var id: Date { date }
    }

    /// The grid's shape in a box: squares as tall as seven rows allow, as many weeks as fit the
    /// width, and the columns spread so the last one meets the right edge.
    public struct Fit: Sendable, Equatable {
        public var weeks: Int
        public var side: Double
        public var columnSpacing: Double
        public var rowSpacing: Double

        /// - Parameters:
        ///   - spacing: the least space between squares, and the space between rows.
        ///   - maxSide: the largest square, so a tall box doesn't draw tiles.
        ///   - maxWeeks: the most weeks the overview has.
        public init(width: Double, height: Double, spacing: Double, maxSide: Double = .infinity,
                    maxWeeks: Int = VaultOverview.Rhythm.days / 7) {
            let side = max(2, min(maxSide, ((height - 6 * spacing) / 7).rounded(.down)))
            let weeks = min(max(1, maxWeeks), max(1, Int(((width + spacing) / (side + spacing)).rounded(.down))))
            self.side = side
            self.weeks = weeks
            columnSpacing = weeks > 1 ? max(spacing, (width - Double(weeks) * side) / Double(weeks - 1)) : 0
            rowSpacing = spacing
        }

        public var height: Double { 7 * side + 6 * rowSpacing }

        /// Where column `week` and row `row` start.
        public func origin(week: Int, row: Int) -> (x: Double, y: Double) {
            (Double(week) * (side + columnSpacing), Double(row) * (side + rowSpacing))
        }
    }

    /// Fewer memories saved than this in 12 weeks is too few for a rhythm.
    public static let minimum = 5
    /// The days the words look at: the busiest weekday, and whether there's a rhythm yet.
    public static let wordsDays = 84

    public var weeks: Int
    public var cells: [Cell]
    /// The highest count of each of the first three shades; above the third is the fourth.
    public var steps: [Int]
    /// The busiest shown day's count.
    public var peak: Int
    /// Memories saved in the last 12 weeks, whatever `weeks` shows.
    public var total: Int
    /// Calendar weeks in a row with a memory saved, up to this one (or last week, while this one
    /// has none yet), over all the overview's days.
    public var streak: Int
    /// The weekday (`Calendar`'s 1 = Sunday … 7) with the most saved in 12 weeks; nil while
    /// there are too few.
    public var busiestWeekday: Int?

    public var isTooSparse: Bool { total < Self.minimum }

    public init(_ rhythm: VaultOverview.Rhythm, weeks: Int, calendar: Calendar) {
        self.weeks = max(1, weeks)
        let counts = rhythm.savedCounts
        let last = counts.count - 1
        let today = calendar.date(byAdding: .day, value: max(0, last), to: rhythm.start) ?? rhythm.start
        func row(_ date: Date) -> Int { (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7 }
        func index(_ date: Date) -> Int { calendar.dateComponents([.day], from: rhythm.start, to: date).day ?? 0 }
        // The first cell: this week's first day, `weeks - 1` weeks back.
        let thisWeek = calendar.date(byAdding: .day, value: -row(today), to: today) ?? today
        let first = calendar.date(byAdding: .day, value: -7 * (self.weeks - 1), to: thisWeek) ?? thisWeek
        cells = (0..<(self.weeks * 7)).map { n in
            let date = calendar.date(byAdding: .day, value: n, to: first) ?? first
            let i = index(date)
            return Cell(date: date, week: n / 7, row: n % 7, count: i > last ? nil : counts.indices.contains(i) ? counts[i] : 0,
                        isToday: i == last)
        }
        let shown = cells.compactMap(\.count).filter { $0 > 0 }.sorted()
        steps = shown.isEmpty ? [0, 0, 0] : [0.25, 0.5, 0.75].map { shown[Int(Double(shown.count - 1) * $0)] }
        peak = shown.last ?? 0

        // Weeks back from this one, over all of `rhythm`.
        var perWeek: [Int: Int] = [:]
        let thisWeekIndex = index(thisWeek)
        for (i, count) in counts.enumerated() { perWeek[(thisWeekIndex - i + 6) / 7, default: 0] += count }
        var back = (perWeek[0] ?? 0) > 0 ? 0 : 1
        var streak = 0
        while (perWeek[back] ?? 0) > 0 {
            streak += 1
            back += 1
        }
        self.streak = streak

        var byWeekday: [Int: Int] = [:]
        var total = 0
        for i in max(0, counts.count - Self.wordsDays)..<counts.count {
            let date = calendar.date(byAdding: .day, value: i, to: rhythm.start) ?? rhythm.start
            byWeekday[calendar.component(.weekday, from: date), default: 0] += counts[i]
            total += counts[i]
        }
        self.total = total
        // A tie goes to the weekday that comes first (Sunday is 1).
        busiestWeekday = total < Self.minimum ? nil : byWeekday.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// A day's shade: nil for none, else 0 (the faintest) to 3. When most days have the same
    /// count, they take the third shade rather than the faintest.
    public func level(_ count: Int) -> Int? {
        guard count > 0 else { return nil }
        if steps[0] == peak { return 2 }
        return steps.firstIndex { count <= $0 } ?? 3
    }
}
