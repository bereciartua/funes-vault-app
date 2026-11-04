import Foundation
import FunesCore
import FunesProtocol

/// Home's words (04-ux-mac.md ▸ Home): numbers over adjectives, parts with nothing to say left out.
enum HomeText {
    /// "Good afternoon, Martin." with the name Funes calls you from About You; "Good afternoon."
    /// without one. Never the macOS account's name, which is often a username (ADR-0026).
    static func greeting(now: Date, calledName: String?) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        let first = calledName ?? ""
        switch (hour, first.isEmpty) {
        case (5..<12, false): return String(localized: "Good morning, \(first).")
        case (12..<18, false): return String(localized: "Good afternoon, \(first).")
        case (_, false): return String(localized: "Good evening, \(first).")
        case (5..<12, true): return String(localized: "Good morning.")
        case (12..<18, true): return String(localized: "Good afternoon.")
        default: return String(localized: "Good evening.")
        }
    }

    /// "This week: 9 saved, 23 shared with 3 agents, 2 refused." or "Nothing new this week".
    static func week(_ week: VaultOverview.Week) -> String {
        var parts: [String] = []
        if week.saved > 0 { parts.append(String(localized: "\(week.saved) saved")) }
        if week.shared > 0 {
            parts.append(week.agents == 1 ? String(localized: "\(week.shared) shared with 1 agent")
                                          : String(localized: "\(week.shared) shared with \(week.agents) agents"))
        }
        if week.refused > 0 { parts.append(String(localized: "\(week.refused) refused")) }
        guard !parts.isEmpty else { return String(localized: "Nothing new this week") }
        return String(localized: "This week: \(parts.joined(separator: ", ")).")
    }

    static func rangeTitle(_ range: OverviewInsights.Range) -> String {
        switch range {
        case .days7: String(localized: "7 days")
        case .days30: String(localized: "30 days")
        case .weeks12: String(localized: "12 weeks")
        case .months12: String(localized: "12 months")
        }
    }

    /// "Last 30 days".
    static func lastRange(_ range: OverviewInsights.Range) -> String {
        switch range {
        case .days7: String(localized: "Last 7 days")
        case .days30: String(localized: "Last 30 days")
        case .weeks12: String(localized: "Last 12 weeks")
        case .months12: String(localized: "Last 12 months")
        }
    }

    /// The chart for VoiceOver: "Last 30 days: 41 memories in, 96 shared, 3 requests refused".
    static func summary(_ insights: OverviewInsights) -> String {
        let totals = insights.totals
        let memories = totals.inbound == 1 ? String(localized: "1 memory in") : String(localized: "\(totals.inbound) memories in")
        let refused = totals.refused == 1 ? String(localized: "1 request refused")
                                          : String(localized: "\(totals.refused) requests refused")
        return String(localized: "\(lastRange(insights.range)): \(memories), \(totals.shared) shared, \(refused)")
    }

    /// "Tue 21 Oct", "13–19 Oct" or "Oct 2026": a bucket of the range.
    static func bucketTitle(_ bucket: VaultOverview.Bucket, in insights: OverviewInsights) -> String {
        switch insights.range {
        case .days7, .days30: return bucket.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .weeks12:
            let interval = insights.interval(of: bucket)
            return (interval.start..<interval.end.addingTimeInterval(-1)).formatted(.interval.day().month(.abbreviated))
        case .months12: return bucket.date.formatted(.dateTime.month(.abbreviated).year())
        }
    }

    enum Source: CaseIterable {
        case mac, iphone, agent, `import`, tidy

        var title: String {
            switch self {
            case .mac: String(localized: "You (Mac)")
            case .iphone: String(localized: "iPhone")
            case .agent: String(localized: "Agents")
            case .import: String(localized: "Imports")
            case .tidy: String(localized: "Tidy-up")
            }
        }

        func count(_ sources: VaultOverview.Sources) -> Int {
            switch self {
            case .mac: sources.mac
            case .iphone: sources.iphone
            case .agent: sources.agent
            case .import: sources.import
            case .tidy: sources.tidy
            }
        }
    }

    /// The day's breakdown for hover and VoiceOver: "4 in (2 iPhone, 2 Agents)", "11 shared
    /// (Claude Code 8, Cursor 3)", "1 refused"; nothing for a quiet day.
    static func breakdown(_ bucket: VaultOverview.Bucket, in insights: OverviewInsights,
                          name: (OverviewInsights.OutSeries) -> String) -> [String] {
        var lines: [String] = []
        let total = bucket.inbound.total
        if total > 0 {
            let parts = Source.allCases.compactMap { source -> String? in
                let n = source.count(bucket.inbound)
                return n > 0 ? "\(n) \(source.title)" : nil
            }
            lines.append(String(localized: "\(total) in (\(parts.joined(separator: ", ")))"))
        }
        if bucket.shared > 0 {
            let parts = insights.out(bucket).map { "\(name($0.series)) \($0.count)" }
            lines.append(String(localized: "\(bucket.shared) shared (\(parts.joined(separator: ", ")))"))
        }
        if bucket.refused > 0 { lines.append(String(localized: "\(bucket.refused) refused")) }
        return lines
    }

    /// One line for VoiceOver: "Tue 21 Oct · 4 in (2 iPhone, 2 Agents) · 1 refused".
    static func dayLabel(_ bucket: VaultOverview.Bucket, in insights: OverviewInsights,
                         name: (OverviewInsights.OutSeries) -> String) -> String {
        let lines = breakdown(bucket, in: insights, name: name)
        let title = bucketTitle(bucket, in: insights)
        return ([title] + (lines.isEmpty ? [String(localized: "nothing")] : lines)).joined(separator: " · ")
    }

    /// "Most on Sundays".
    static func mostOn(_ weekday: Int) -> String {
        let names = Calendar.current.standaloneWeekdaySymbols
        let name = names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
        return String(localized: "Most on \(name)s")
    }

    static func streak(_ weeks: Int) -> String {
        weeks == 1 ? String(localized: "1-week streak") : String(localized: "\(weeks)-week streak")
    }

    /// "today 03:04", "yesterday 03:04", "Mon 03:04" this week, else "21 Oct".
    static func when(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "yesterday \(time)") }
        if now.timeIntervalSince(date) < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
