import Foundation
import FunesProtocol

/// People & history's words on the iPhone (05-ux-iphone.md, companion protocol §4.3): the Mac sends data, and these say
/// it as the Mac's section does (its `PeopleText`): kinds, dates at the precision written, bases in words (never a code),
/// and what VoiceOver reads. They resolve in the app's String Catalog, which `scripts/sync_strings.sh` fills from this
/// file too.
public enum PeopleWording {
    // MARK: Kinds

    public static func kind(_ k: String) -> String {
        switch k {
        case "person": String(localized: "Person")
        case "organization": String(localized: "Organization")
        case "place": String(localized: "Place")
        case "thing": String(localized: "Thing")
        default: k
        }
    }

    public static func kindPlural(_ k: String) -> String {
        switch k {
        case "person": String(localized: "People")
        case "organization": String(localized: "Organizations")
        case "place": String(localized: "Places")
        case "thing": String(localized: "Things")
        default: k
        }
    }

    public static func symbol(_ k: String) -> String {
        switch k {
        case "person": "person.fill"
        case "organization": "building.2.fill"
        case "place": "mappin.circle.fill"
        default: "shippingbox.fill"
        }
    }

    // MARK: Names

    /// "Maria", "Your sisters (2)", or "Unnamed (Person)" for an entry no memory names any more.
    public static func name(_ e: PeopleEntry) -> String {
        if let n = e.name { return n }
        guard let g = e.group else {
            return String(localized: "Unnamed (\(kind(e.kind)))", comment: "An entry no memory names any more, kept for your corrections")
        }
        let a = capitalized(g.attribute)
        return g.count.map { String(localized: "\(a) (\($0))", comment: "A role group and how many: Your sisters (2)") } ?? a
    }

    public static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    // MARK: Dates

    /// A date at the precision written: "2019", "March 2019", "15 March 2019".
    public static func date(_ r: PeopleDateRange, end: Bool = false) -> String {
        let c = PeopleDay.civil(end ? r.hi : r.lo)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var dc = DateComponents()
        dc.year = c.year; dc.month = c.month; dc.day = c.day
        guard let d = cal.date(from: dc) else { return String(c.year ?? 0) }
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = cal.timeZone
        switch r.precision {
        case .day: f.setLocalizedDateFormatFromTemplate("d MMMM y")
        case .month: f.setLocalizedDateFormatFromTemplate("MMMM y")
        case .year: f.setLocalizedDateFormatFromTemplate("y")
        default:
            // A derived bound: the year it falls in, unless it's a single month or day.
            if r.hi - r.lo < 1 { f.setLocalizedDateFormatFromTemplate("d MMMM y") }
            else if r.hi - r.lo < 32 { f.setLocalizedDateFormatFromTemplate("MMMM y") }
            else { f.setLocalizedDateFormatFromTemplate("y") }
        }
        return f.string(from: d)
    }

    /// "2019 – March 2021", "since 2021", "until 2017", or nil when undated.
    public static func range(start: PeopleDateRange?, end: PeopleDateRange?, ongoing: Bool) -> String? {
        switch (start, end) {
        case let (s?, e?): String(localized: "\(date(s)) – \(date(e, end: true))", comment: "An episode's dates")
        case let (s?, nil): ongoing ? String(localized: "since \(date(s))", comment: "An episode that still holds")
                                    : String(localized: "from \(date(s))", comment: "An episode with no known end")
        case let (nil, e?): String(localized: "until \(date(e, end: true))", comment: "An episode with no known start")
        default: nil
        }
    }

    /// A list row's fact: "your sister", "where you worked until 2021", "your client".
    public static func line(_ f: PeopleEntry.Fact) -> String {
        if f.recordedOnly { return f.attribute }
        if let s = f.since { return String(localized: "\(f.attribute) since \(date(s))", comment: "List row: e.g. where you worked since 2021") }
        if let u = f.until { return String(localized: "\(f.attribute) until \(date(u, end: true))", comment: "List row: e.g. where you worked until 2021") }
        if f.status == .former { return String(localized: "\(f.attribute), former", comment: "List row: a former relation") }
        return f.attribute
    }

    // MARK: Bases

    public static func basis(_ b: PeopleBasis) -> String? {
        switch b {
        case .confirmed: String(localized: "You said so")
        case .named: String(localized: "Named in the memory")
        case .context: String(localized: "From the memory's context")
        case .untrusted: String(localized: "From an agent's or an import's text")
        case .other: nil
        }
    }

    /// A fact's basis line: "Named in the memory", or with "· recorded only, not used in search".
    public static func basisLine(_ f: PeopleFact) -> String {
        let b = basis(f.basis)
        guard f.recordedOnly else { return b ?? "" }
        return b.map { String(localized: "\($0) · recorded only, not used in search") }
            ?? String(localized: "Recorded only, not used in search")
    }

    /// An episode's basis on the timeline: Stated · Probably former · You said so.
    public static func basis(_ e: PeopleEpisode) -> String {
        if e.yours { return String(localized: "You said so") }
        if e.untrusted { return String(localized: "From an agent's or an import's text") }
        if e.inferredEnd { return String(localized: "Probably former", comment: "Timeline basis: ended by a later job") }
        if e.former { return String(localized: "Stated as former", comment: "Timeline basis") }
        return String(localized: "Stated", comment: "Timeline basis")
    }

    /// "Engineer, then Senior engineer from 2020".
    public static func titles(_ ts: [PeopleEpisode.Title]) -> String? {
        guard let first = ts.first else { return nil }
        return ts.dropFirst().reduce(first.title) { out, t in
            t.from.map { String(localized: "\(out), then \(t.title) from \(date($0))", comment: "Title history") }
                ?? String(localized: "\(out), then \(t.title)", comment: "Title history")
        }
    }

    /// "Started 2019 or 2020: two memories disagree".
    public static func conflict(_ e: PeopleEpisode) -> String? {
        func years(_ r: PeopleDateRange) -> String? {
            let a = PeopleDay.civil(r.lo).year ?? 0, b = PeopleDay.civil(min(r.hi, PeopleDateRange.maxDay - 1)).year ?? 0
            return a == b ? nil : String(localized: "\(String(a)) or \(String(b))", comment: "Two years memories disagree on")
        }
        if e.conflictStart, let s = e.start {
            return years(s).map { String(localized: "Started \($0): two memories disagree", comment: "Timeline: conflicting dates") }
                ?? String(localized: "Its start: two memories disagree", comment: "Timeline: conflicting dates")
        }
        if e.conflictEnd, let x = e.end {
            return years(x).map { String(localized: "Ended \($0): two memories disagree", comment: "Timeline: conflicting dates") }
                ?? String(localized: "Its end: two memories disagree", comment: "Timeline: conflicting dates")
        }
        return nil
    }

    public static func previous(_ p: PeopleEpisode.Previous) -> String? {
        if p.cantTell == true { return String(localized: "Funes can't tell which came first", comment: "Timeline: an undecidable order") }
        if let m = p.gapMonths { return String(localized: "Gap of \(m) months before this", comment: "Timeline: a gap") }
        return nil
    }

    /// "employee", "self employed": the slot qualifier as the Mac shows it.
    public static func slot(_ k: String) -> String { k.replacingOccurrences(of: "_", with: " ") }

    /// "1 memory says so", "3 memories say so".
    public static func stating(_ n: Int) -> String? {
        switch n {
        case 0: nil
        case 1: String(localized: "1 memory says so")
        default: String(localized: "\(n) memories say so")
        }
    }

    /// A status of yours with no dates: "current" or "former".
    public static func yourStatus(_ e: PeopleEpisode) -> String {
        e.former ? String(localized: "former", comment: "Timeline: a job of yours marked former, no dates")
                 : String(localized: "current", comment: "Timeline: a job of yours marked current, no dates")
    }

    // MARK: To check

    public static func question(_ item: PeopleToCheckItem) -> String? {
        if let l = item.link {
            return String(localized: "Who is “\(l.surface)” in \(l.memoryTitle)?", comment: "To check: an unsettled role phrase")
        }
        if let m = item.merge {
            return String(localized: "Are \(m.names.first ?? "") and \(m.names.last ?? "") the same?", comment: "To check: a suggested merge")
        }
        if let e = item.episode {
            return e.choices.isEmpty
                ? String(localized: "Something you set on \(e.name) (\(e.noun)) no longer matches one of its dates.")
                : String(localized: "Which \(e.name) \(e.noun) did you mean?", comment: "To check: e.g. Which Acme job did you mean?")
        }
        return nil
    }

    /// The choices under a question: the candidates' names, or the episodes' years ("2015 – 2017", "since 2021").
    public static func choices(_ item: PeopleToCheckItem) -> [String] {
        if let l = item.link { return l.candidates }
        if let e = item.episode {
            return e.choices.map { r in
                range(start: r.lo > PeopleDateRange.minDay ? PeopleDateRange(lo: r.lo, hi: r.lo, precision: .year) : nil,
                      end: r.hi < PeopleDateRange.maxDay ? PeopleDateRange(lo: r.hi, hi: r.hi, precision: .year) : nil,
                      ongoing: r.hi >= PeopleDateRange.maxDay) ?? String(localized: "undated")
            }
        }
        return []
    }

    // MARK: VoiceOver

    /// "Maria, person, your sister, 14 memories".
    public static func accessibility(_ e: PeopleEntry) -> String {
        var parts = [name(e), kind(e.kind)]
        if let f = e.fact { parts.append(line(f)) }
        if e.deceased { parts.append(String(localized: "deceased")) }
        if e.hidden { parts.append(String(localized: "hidden")) }
        parts.append(String(localized: "\(e.mentions) memories", comment: "VoiceOver: how many memories mention it"))
        return parts.joined(separator: ", ")
    }

    // MARK: States

    /// Facts off on the Mac (`facts_off`, `shown: false`).
    public static let factsOff = String(localized: "Funes can learn the people in your life and where you've worked from your memories, for your own search. Turn on Facts on your Mac in Settings ▸ AI ▸ Features.")
    /// Your names unreadable (`names_unavailable`).
    public static let namesUnavailable = String(localized: "Your Mac can't read your names in About You right now, so it shows nothing here.")
    public static let nothingYet = String(localized: "Funes hasn't learned anyone from your memories yet. It reads new and changed ones as you save them.")
    public static let notLearning = String(localized: "Funes isn't learning from your memories. Your own entries and corrections are kept.")
    public static func reading(_ r: PeopleDirectoryResult.Reading) -> String {
        String(localized: "Reading your memories: \(r.done) of \(r.total)")
    }
    public static let timelineOff = String(localized: "Funes isn't ordering this now. Only what you enter shows here.")
    public static let toCheckFooter = String(localized: "Answer these on your Mac. Nothing waits on them.")
    public static let toCheckEmpty = String(localized: "Nothing to check. Funes asks here only what it couldn't settle; nothing waits on it.")
    public static let macOnly = String(localized: "Rename, merge, hide, dates and undo are on your Mac.")

    /// Not this's question: "Maria isn't your sister?".
    public static func notThisQuestion(_ entry: PeopleEntry, _ f: PeopleFact) -> String {
        String(localized: "\(name(entry)) isn't \(f.attribute)?")
    }
}
