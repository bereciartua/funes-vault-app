import Foundation

/// A date as written: every day it could be (memory processing §11.5). "2019" is 1 January to 31 December; "March
/// 2019" is that month; "15 March 2019" is that day. Days are counted in the proleptic Gregorian calendar.
public struct DateRange: Sendable, Equatable, Hashable {
    public enum Precision: String, Sendable {
        case year, month, day
        case bound        // an "ended by" limit: the memory that says it's over
        case inferred     // ended by succession
        case handover     // a new holder's assumed start (role resolution only)
        case conflict     // memories disagree
    }

    public let lo: Int
    public let hi: Int
    public let precision: Precision

    public init(lo: Int, hi: Int, precision: Precision = .day) {
        self.lo = lo
        self.hi = hi
        self.precision = precision
    }

    public static func day(_ d: Int) -> DateRange { DateRange(lo: d, hi: d, precision: .day) }

    public func certainlyBefore(_ other: DateRange) -> Bool { hi <= other.lo }
    public func overlaps(_ other: DateRange) -> Bool { lo <= other.hi && other.lo <= hi }

    public static let minDay = 1
    public static let maxDay = DayNumber.from(year: 9999, month: 12, day: 31)!
}

/// Day numbers (days since 1 January of year 1 is day 1, as Python's `date.toordinal`).
public enum DayNumber {
    public static func from(year y: Int, month m: Int, day d: Int) -> Int? {
        guard (1...12).contains(m), d >= 1, d <= daysIn(year: y, month: m) else { return nil }
        // Howard Hinnant's days_from_civil, shifted so 0001-01-01 is 1.
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468 + 719_163
    }

    public static func daysIn(year y: Int, month m: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}

/// Parsing dates as written, with month words from the registry.
struct DateParser: Sendable {
    let months: [String: Int]
    let joiners: [String]
    private let monthAlternation: String
    private let ordinals: String

    init(registry: FactsRegistry) {
        months = registry.monthWords
        joiners = registry.language.dateJoiners
        monthAlternation = months.keys.sorted { $0.count > $1.count }.map(FactsText.escape).joined(separator: "|")
        ordinals = registry.language.ordinalSuffixes.map(FactsText.escape).joined(separator: "|")
    }

    var monthPattern: String { monthAlternation }

    private func monthRange(_ y: Int, _ m: Int) -> DateRange? {
        guard let first = DayNumber.from(year: y, month: m, day: 1) else { return nil }
        return DateRange(lo: first, hi: first + DayNumber.daysIn(year: y, month: m) - 1, precision: .month)
    }

    /// A date as written → a range, or nil. A month counts only as a month word or number next to a year ("March 2019",
    /// "marzo de 2019", "2019-03"); "married in 2015" is the year 2015.
    func parse(_ s: String?) -> DateRange? {
        guard let s, !s.isEmpty else { return nil }
        let t = FactsText.fold(s)
        let j = joiners.map(FactsText.escape).joined(separator: "|")
        if let m = FactsText.first(FactsText.regex("\\b((?:19|20)\\d{2})-(\\d{1,2})-(\\d{1,2})\\b"), in: t),
           let y = Int(m.group(1)!), let mo = Int(m.group(2)!), let d = Int(m.group(3)!),
           let n = DayNumber.from(year: y, month: mo, day: d) {
            return .day(n)
        }
        if let m = FactsText.first(FactsText.regex("\\b((?:19|20)\\d{2})-(\\d{1,2})\\b(?!-)"), in: t),
           let y = Int(m.group(1)!), let mo = Int(m.group(2)!), (1...12).contains(mo) {
            return monthRange(y, mo)
        }
        var mon: String?, dd: String?, yy: String?
        if let m = FactsText.first(FactsText.regex("\\b(\\d{1,2})\\s+(?:(?:" + j + ")\\s+)?(" + monthAlternation
                                                   + ")\\.?\\s+(?:(?:" + j + ")\\s+)?((?:19|20)\\d{2})\\b"), in: t) {
            dd = m.group(1); mon = m.group(2); yy = m.group(3)
        } else if let m = FactsText.first(FactsText.regex("\\b(" + monthAlternation
                                                          + ")\\.?,?\\s+(?:(\\d{1,2})(?:" + ordinals + ")?,?\\s+)?(?:(?:" + j
                                                          + ")\\s+)?((?:19|20)\\d{2})\\b"), in: t) {
            mon = m.group(1); dd = m.group(2); yy = m.group(3)
        }
        if let mon, let yy, let y = Int(yy), let mo = months[mon] {
            if let dd, let d = Int(dd), let n = DayNumber.from(year: y, month: mo, day: d) { return .day(n) }
            return monthRange(y, mo)
        }
        if let m = FactsText.first(FactsText.regex("\\b((?:19|20)\\d{2})\\b"), in: t), let y = Int(m.group(1)!),
           let lo = DayNumber.from(year: y, month: 1, day: 1), let hi = DayNumber.from(year: y, month: 12, day: 31) {
            return DateRange(lo: lo, hi: hi, precision: .year)
        }
        return nil
    }

    /// A memory's written date (ISO) → a day.
    func day(_ s: String?) -> Int? { parse(s)?.lo }

    /// The whole date expression that ends at a year in folded text: "march 2019", "15 de marzo de 2019", or the year.
    func dateEnding(at end: Int, in q: String) -> DateRange? {
        let j = joiners.map(FactsText.escape).joined(separator: "|")
        let prefix = FactsText.substring(q, 0, end)
        let re = FactsText.regex("(?:(?:\\d{1,2}\\s+(?:(?:" + j + ")\\s+)?)?(?:" + monthAlternation
                                 + ")\\.?,?\\s+(?:\\d{1,2}(?:" + ordinals + ")?,?\\s+)?(?:(?:" + j + ")\\s+)?)?(?:19|20)\\d{2}$")
        if let m = FactsText.first(re, in: prefix) { return parse(m.group(0)) }
        return parse(FactsText.substring(q, end - 4, end))
    }
}
