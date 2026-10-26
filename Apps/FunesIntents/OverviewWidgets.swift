import FunesPhone
import FunesProtocol
import SwiftUI
import WidgetKit

// Home's cards on the Home Screen (FR-H-06, UX: iPhone ▸ Widgets): Pulse, Remember and Rhythm.
// Counts and agent names only, never memory text or titles; agent names are privacy-sensitive,
// so iOS redacts them while the phone is locked.

// MARK: Pulse

/// The week's numbers and the 14-day in/out chart, with the refused dots. Tapping opens Home.
struct PulseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FunesWidgets.pulse, provider: OverviewProvider()) { entry in
            PulseWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Pulse")
        .description("This week's numbers, and what came in and went out to agents over 14 days.")
        .supportedFamilies([.systemMedium])
    }
}

struct PulseWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: String(localized: "Funes · this week"), snapshot: snapshot)
            switch snapshot.content {
            case .notPaired:
                WidgetMessage(String(localized: "Pair with your Mac"), detail: String(localized: "Open Funes to pair."),
                              systemImage: "iphone.slash")
            case .waiting:
                WidgetMessage(String(localized: "Your pulse shows here"), detail: String(localized: "Open Funes once your Mac is near."),
                              systemImage: "chart.bar.xaxis")
            case let .overview(overview):
                pulse(overview)
            }
        }
        .accessibilityElement(children: .combine)
        .widgetURL(FunesWidgets.homeURL)
        .funesWidgetBackground()
    }

    @ViewBuilder private func pulse(_ overview: VaultOverview) -> some View {
        let pulse = Pulse(overview, last: 14)
        let stale = snapshot.freshness == .stale
        Text(OverviewWords.numbers(overview.thisWeek))
            .font(.headline.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .dimmed(stale)
            .accessibilityLabel(OverviewWords.week(overview.thisWeek))
        if overview.isNewVault {
            WidgetMessage(String(localized: "Your pulse starts with your first memories"), detail: nil, systemImage: nil)
        } else {
            PulseChart(pulse: pulse, range: .days30, calendar: overview.calendar, showsAxis: false)
                .widgetAccentable()
                .frame(maxHeight: .infinity)
                .dimmed(stale)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(OverviewWords.lastDays(pulse))
            let named = pulse.agents.filter { !$0.isOther }
            if !named.isEmpty {
                Text("Shared with \(named.map(OverviewWords.agentName).formatted(.list(type: .and, width: .narrow)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacySensitive()
                    .dimmed(stale)
            }
        }
    }
}

// MARK: Remember

/// "What should Funes remember?", with **Remember** and 🎙, which open Home's composer ready to
/// type or dictate (the Control's path, `CaptureLaunch`). Works unpaired too: captures queue.
struct RememberWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FunesWidgets.remember, provider: OverviewProvider()) { entry in
            RememberWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Remember")
        .description("Opens Funes ready to type or dictate something to remember.")
        .supportedFamilies([.systemSmall])
    }
}

struct RememberWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: String(localized: "Funes"), snapshot: snapshot, showsFreshness: false)
            Text("What should Funes remember?")
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if snapshot.content == .notPaired {
                Text("Pair with your Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(spacing: 6) {
                Button(intent: OpenCaptureIntent()) {
                    Text("Remember")
                        .font(.footnote.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .widgetAccentable()
                Button(intent: OpenDictationIntent()) {
                    Image(systemName: "mic.fill")
                        .font(.footnote.bold())
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(.blue)
                .accessibilityLabel("Dictate")
            }
        }
        .funesWidgetBackground()
    }
}

// MARK: Rhythm

/// The grid of days: 6 weeks in small, 12 weeks with the streak and the busiest weekday in
/// medium. Tapping opens Home.
struct RhythmWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FunesWidgets.rhythm, provider: OverviewProvider()) { entry in
            RhythmWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Rhythm")
        .description("The days you added memories, week by week.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RhythmWidgetView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch snapshot.content {
            case .notPaired:
                VStack(alignment: .leading, spacing: 4) {
                    WidgetHeader(title: String(localized: "Rhythm"), snapshot: snapshot)
                    WidgetMessage(String(localized: "Pair with your Mac"), detail: String(localized: "Open Funes to pair."),
                                  systemImage: "iphone.slash")
                }
            case .waiting:
                VStack(alignment: .leading, spacing: 4) {
                    WidgetHeader(title: String(localized: "Rhythm"), snapshot: snapshot)
                    WidgetMessage(String(localized: "Your rhythm shows here"), detail: String(localized: "Open Funes once your Mac is near."),
                                  systemImage: "square.grid.3x3")
                }
            case let .overview(overview):
                if family == .systemMedium { medium(overview) } else { small(overview) }
            }
        }
        .widgetURL(FunesWidgets.homeURL)
        .funesWidgetBackground()
    }

    private func small(_ overview: VaultOverview) -> some View {
        let grid = RhythmGrid(overview.rhythm, weeks: 6, calendar: overview.calendar)
        let stale = snapshot.freshness == .stale
        return VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: String(localized: "Rhythm"), snapshot: snapshot)
            RhythmGridView(grid: grid, spacing: 3)
                .widgetAccentable()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .dimmed(stale)
            Text(grid.isTooSparse ? String(localized: "Too few memories yet")
                                  : grid.streak > 0 ? OverviewWords.streak(grid.streak) : String(localized: "No streak yet"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RhythmWords.accessibility(grid, calendar: overview.calendar))
    }

    private func medium(_ overview: VaultOverview) -> some View {
        let grid = RhythmGrid(overview.rhythm, weeks: 12, calendar: overview.calendar)
        let stale = snapshot.freshness == .stale
        let count = grid.cells.compactMap(\.count).reduce(0, +)
        return HStack(alignment: .top, spacing: 14) {
            RhythmGridView(grid: grid, spacing: 3)
                .widgetAccentable()
                .frame(maxHeight: .infinity)
                .dimmed(stale)
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(title: String(localized: "Rhythm"), snapshot: snapshot)
                Spacer(minLength: 0)
                if grid.isTooSparse {
                    Text("Too few memories for a rhythm yet")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text(grid.streak > 0 ? OverviewWords.streak(grid.streak) : String(localized: "No streak yet"))
                        .font(.headline)
                    if let weekday = grid.busiestWeekday {
                        Text(OverviewWords.busiest(weekday, calendar: overview.calendar))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(count == 1 ? String(localized: "1 new in 12 weeks") : String(localized: "\(count) new in 12 weeks"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RhythmWords.accessibility(grid, calendar: overview.calendar))
    }
}

// MARK: Parts

/// The widget's title, and on its right **DEMO** for the demo's counts, or "as of 10:42" once
/// they're over an hour old.
struct WidgetHeader: View {
    let title: String
    let snapshot: WidgetSnapshot
    var showsFreshness = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if snapshot.isDemo {
                Text("DEMO")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange, in: Capsule())
                    .foregroundStyle(.white)
                    .widgetAccentable()
                    .accessibilityLabel("Demo vault: not your data")
            } else if showsFreshness, snapshot.freshness != .fresh, let overview = snapshot.overview {
                Text("as of \(Self.time(overview.generatedAt, now: snapshot.date))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// "10:42" today, "21 Oct" before.
    static func time(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        calendar.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
                                                : date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// What a widget says in place of its numbers: Not paired, or no counts yet.
struct WidgetMessage: View {
    let title: String
    let detail: String?
    let systemImage: String?

    init(_ title: String, detail: String?, systemImage: String?) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The system's widget background, and text no larger than the widgets have room for.
    func funesWidgetBackground() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .containerBackground(.background, for: .widget)
    }
}

// MARK: Previews

private extension WidgetSnapshot {
    static func preview(_ content: Content, age: TimeInterval = 0, demo: Bool = false) -> WidgetSnapshot {
        guard case var .overview(overview) = content else { return WidgetSnapshot(date: Date(), content: content, isDemo: demo) }
        overview.generatedAt = Date() - age
        return WidgetSnapshot(date: Date(), content: .overview(overview), isDemo: demo)
    }

    static var sample: Content { .overview(OverviewEntry.sampleOverview) }
}

#Preview("Pulse", as: .systemMedium) {
    PulseWidget()
} timeline: {
    OverviewEntry(snapshot: .preview(WidgetSnapshot.sample, demo: true))
    OverviewEntry(snapshot: .preview(WidgetSnapshot.sample, age: 2 * 3_600))
    OverviewEntry(snapshot: .preview(WidgetSnapshot.sample, age: 2 * 86_400))
    OverviewEntry(snapshot: .preview(.notPaired))
    OverviewEntry(snapshot: .preview(.waiting))
}

#Preview("Remember", as: .systemSmall) {
    RememberWidget()
} timeline: {
    OverviewEntry(snapshot: .preview(WidgetSnapshot.sample))
    OverviewEntry(snapshot: .preview(WidgetSnapshot.sample, demo: true))
    OverviewEntry(snapshot: .preview(.notPaired))
}

#Preview("Rhythm small", as: .systemSmall) {
    RhythmWidget()
} timeline: {
    OverviewEntry(snapshot: .preview(WidgetSnapshot.sample, demo: true))
    OverviewEntry(snapshot: .preview(WidgetSnapshot.sample, age: 3 * 3_600))
    OverviewEntry(snapshot: .preview(.notPaired))
}

#Preview("Rhythm medium", as: .systemMedium) {
    RhythmWidget()
} timeline: {
    OverviewEntry(snapshot: .preview(WidgetSnapshot.sample, demo: true))
    OverviewEntry(snapshot: .preview(WidgetSnapshot.sample, age: 2 * 86_400))
    OverviewEntry(snapshot: .preview(.waiting))
}
