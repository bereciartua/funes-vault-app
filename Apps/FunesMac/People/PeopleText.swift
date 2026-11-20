import Foundation
import FunesCore

/// People & history's words (04-ux-mac.md): kinds, dates at the precision written, bases in words (never a code), and
/// what VoiceOver reads.
enum PeopleText {
    // MARK: Kinds

    static func kind(_ k: String) -> String {
        switch k {
        case "person": String(localized: "Person")
        case "organization": String(localized: "Organization")
        case "place": String(localized: "Place")
        case "thing": String(localized: "Thing")
        default: k
        }
    }

    static func kindPlural(_ k: String) -> String {
        switch k {
        case "person": String(localized: "People")
        case "organization": String(localized: "Organizations")
        case "place": String(localized: "Places")
        case "thing": String(localized: "Things")
        default: k
        }
    }

    static func symbol(_ k: String) -> String {
        switch k {
        case "person": "person.fill"
        case "organization": "building.2.fill"
        case "place": "mappin.circle.fill"
        default: "shippingbox.fill"
        }
    }

    // MARK: Names

    static func name(_ e: PeopleDirectory.Entry) -> String {
        if let n = e.name { return n }
        guard let g = e.group else {
            return String(localized: "Unnamed (\(kind(e.kind)))", comment: "An entry no memory names any more, kept for your corrections")
        }
        let a = g.attribute.prefix(1).uppercased() + g.attribute.dropFirst()
        return g.count.map { String(localized: "\(a) (\($0))", comment: "A role group and how many: Your sisters (2)") } ?? a
    }

    // MARK: Dates

    /// A day number (`DayNumber`: proleptic Gregorian, day 1 is 1 January of year 1) as a civil date, by Howard
    /// Hinnant's civil_from_days (Foundation's calendar turns Julian before 1582, so it can't count from year 1).
    static func civil(_ day: Int) -> DateComponents {
        let z = day - 719_163 + 719_468                  // days since 0000-03-01
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        var c = DateComponents()
        c.day = doy - (153 * mp + 2) / 5 + 1
        c.month = mp < 10 ? mp + 3 : mp - 9
        c.year = yoe + era * 400 + (c.month! <= 2 ? 1 : 0)
        return c
    }

    /// A date at the precision written: "2019", "March 2019", "15 March 2019".
    static func date(_ r: DateRange, end: Bool = false) -> String {
        let day = end ? r.hi : r.lo
        let c = civil(day)
        var dc = DateComponents()
        dc.year = c.year; dc.month = c.month; dc.day = c.day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let d = cal.date(from: dc) else { return String(c.year ?? 0) }
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = cal.timeZone
        switch r.precision {
        case .day: f.setLocalizedDateFormatFromTemplate("d MMMM y")
        case .month: f.setLocalizedDateFormatFromTemplate("MMMM y")
        case .year: f.setLocalizedDateFormatFromTemplate("y")
        default:
            // A year, or a derived bound: the year it falls in, unless it's a single month or day.
            if r.hi - r.lo < 1 { f.setLocalizedDateFormatFromTemplate("d MMMM y") }
            else if r.hi - r.lo < 32 { f.setLocalizedDateFormatFromTemplate("MMMM y") }
            else { f.setLocalizedDateFormatFromTemplate("y") }
        }
        return f.string(from: d)
    }

    /// "2019 – March 2021", "since 2021", "until 2017", or nil when undated.
    static func range(start: DateRange?, end: DateRange?, ongoing: Bool) -> String? {
        switch (start, end) {
        case let (s?, e?): return String(localized: "\(date(s)) – \(date(e, end: true))", comment: "An episode's dates")
        case let (s?, nil): return ongoing ? String(localized: "since \(date(s))", comment: "An episode that still holds")
                                           : String(localized: "from \(date(s))", comment: "An episode with no known end")
        case let (nil, e?): return String(localized: "until \(date(e, end: true))", comment: "An episode with no known start")
        default: return nil
        }
    }

    static func line(_ f: PeopleDirectory.FactLine) -> String {
        if f.recordedOnly { return f.attribute }
        if let s = f.since { return String(localized: "\(f.attribute) since \(date(s))", comment: "List row: e.g. where you worked since 2021") }
        if let u = f.until { return String(localized: "\(f.attribute) until \(date(u, end: true))", comment: "List row: e.g. where you worked until 2021") }
        if f.status == .former { return String(localized: "\(f.attribute), former", comment: "List row: a former relation") }
        return f.attribute
    }

    // MARK: Bases

    static func basis(_ b: PeopleEntityPage.Fact.Basis) -> String {
        switch b {
        case .confirmed: String(localized: "You said so")
        case .named: String(localized: "Named in the memory")
        case .context: String(localized: "From the memory's context")
        case .untrusted: String(localized: "From an agent's or an import's text")
        }
    }

    /// An episode's basis on the timeline: Stated · Probably · From text you didn't write.
    static func basis(_ e: PeopleDirectory.TimelineEpisode) -> String? {
        if e.yours { return String(localized: "You said so") }
        if e.untrusted { return String(localized: "From an agent's or an import's text") }
        if e.inferredEnd { return String(localized: "Probably former", comment: "Timeline basis: ended by a later job") }
        if e.former { return String(localized: "Stated as former", comment: "Timeline basis") }
        return String(localized: "Stated", comment: "Timeline basis")
    }

    static func titles(_ ts: [PeopleDirectory.TimelineEpisode.Title]) -> String? {
        guard let first = ts.first else { return nil }
        return ts.dropFirst().reduce(first.title) { out, t in
            t.from.map { String(localized: "\(out), then \(t.title) from \(date($0))", comment: "Title history") }
                ?? String(localized: "\(out), then \(t.title)", comment: "Title history")
        }
    }

    /// "2019 or 2020: two memories disagree".
    static func conflict(_ e: PeopleDirectory.TimelineEpisode) -> String? {
        func years(_ r: DateRange) -> String? {
            let a = civil(r.lo).year ?? 0, b = civil(min(r.hi, DateRange.maxDay - 1)).year ?? 0
            return a == b ? nil : String(localized: "\(String(a)) or \(String(b))", comment: "Two years memories disagree on")
        }
        if e.conflictStart, let s = e.start {
            // (The years a conflict spans.)
            return years(s).map { String(localized: "Started \($0): two memories disagree", comment: "Timeline: conflicting dates") }
                ?? String(localized: "Its start: two memories disagree", comment: "Timeline: conflicting dates")
        }
        if e.conflictEnd, let x = e.end {
            return years(x).map { String(localized: "Ended \($0): two memories disagree", comment: "Timeline: conflicting dates") }
                ?? String(localized: "Its end: two memories disagree", comment: "Timeline: conflicting dates")
        }
        return nil
    }

    static func previous(_ p: PeopleDirectory.TimelineEpisode.Previous) -> String {
        switch p {
        case .cantTell: String(localized: "Funes can't tell which came first", comment: "Timeline: an undecidable order")
        case let .gap(months): String(localized: "Gap of \(months) months before this", comment: "Timeline: a gap")
        }
    }

    // MARK: Corrections

    static func correction(_ c: PeopleEntityPage.Correction) -> String {
        let base: String
        switch c.what {
        case let .renamed(n): base = String(localized: "Renamed to \(n)")
        case let .kind(k): base = String(localized: "Kind set to \(kind(k))")
        case let .deceased(on): base = on ? String(localized: "Marked as deceased") : String(localized: "Marked as not deceased")
        case let .mergedFrom(n): base = n.map { String(localized: "Merged with \($0)") } ?? String(localized: "Merged")
        case let .mergedInto(n): base = n.map { String(localized: "Merged into \($0)") } ?? String(localized: "Merged")
        case let .notSame(n): base = n.map { String(localized: "Not the same as \($0)") } ?? String(localized: "Not the same")
        case let .label(attribute, label): base = String(localized: "Called “\(label)” (\(attribute))", comment: "Correction: your word")
        case let .factRejected(attribute): base = String(localized: "Not \(attribute)", comment: "Correction: Not this on a fact")
        case .linkRejected: base = String(localized: "Not about them", comment: "Correction: Not <name> on a memory")
        case .linkConfirmed: base = String(localized: "Confirmed as the one meant", comment: "Correction: a To check answer")
        case .someoneElse: base = String(localized: "Someone else")
        case .skipped: base = String(localized: "Skipped")
        case let .dates(attribute, start, end):
            base = String(localized: "Dates set (\(attribute)): \(start ?? "…") – \(end ?? "…")", comment: "Correction: your dates")
        case let .status(attribute, status):
            base = status == .former ? String(localized: "Marked as former (\(attribute))") : String(localized: "Marked as current (\(attribute))")
        case let .order(attribute): base = String(localized: "Order added (\(attribute))")
        case .orderRejected: base = String(localized: "Order rejected")
        case let .factAdded(attribute): base = String(localized: "Added by you: \(attribute)")
        case let .hidden(on): base = on ? String(localized: "Hidden") : String(localized: "Shown again")
        case .retired: base = String(localized: "Removed in To Check")
        case let .alias(a): base = String(localized: "Also called \(a)")
        case .other: base = String(localized: "Changed by you")
        }
        return c.memoryTitle.map { String(localized: "\(base), in “\($0)”", comment: "A correction made from a memory") } ?? base
    }

    // MARK: VoiceOver

    /// "Maria, person, your sister, 14 memories".
    static func accessibility(_ e: PeopleDirectory.Entry) -> String {
        var parts = [name(e), kind(e.kind)]
        if let f = e.fact { parts.append(line(f)) }
        if e.deceased { parts.append(String(localized: "deceased")) }
        if e.hidden { parts.append(String(localized: "hidden")) }
        parts.append(String(localized: "\(e.mentions) memories", comment: "VoiceOver: how many memories mention it"))
        return parts.joined(separator: ", ")
    }

    // MARK: The summary

    /// "Funes found 23 people, 9 employers and 41 other names." (the employers left out while there are none).
    static func summary(_ s: PeopleDirectory.Summary) -> String {
        s.employers > 0
            ? String(localized: "Funes found \(s.people) people, \(s.employers) employers and \(s.others) other names.")
            : String(localized: "Funes found \(s.people) people and \(s.others) other names.")
    }
}
