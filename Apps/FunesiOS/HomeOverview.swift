import FunesPhone
import FunesProtocol
import SwiftUI

/// Home's charts (UX: iPhone ▸ Home tab), from the 30-day overview, as widget-like tiles: the
/// week across, then Memories, Rhythm, Sensitivity and Who reads two by two. Live while the Mac
/// answers; the cached snapshot, dimmed, with "As of 10:42" while it's away; the pairing card in
/// their place while the iPhone isn't paired.
struct HomeOverview: View {
    let model: PhoneModel

    var body: some View {
        // With the bar's "Pair with your Mac to start": after its 2 s, so a paired iPhone, whose
        // pairing is read at launch, never flashes it.
        if case .state(.notPaired)? = model.statusBar.item {
            PairingCard(model: model)
        } else if let overview = model.overview.overview(.days30) {
            let stale = model.isStale
            Section {
                VStack(spacing: 12) {
                    WeekTile(overview: overview, stale: stale) { model.pulseSheet = .days7 }
                    HomeTiles(overview: overview, stale: stale, openSearch: model.openSearch(sensitivity:),
                              openRhythm: { model.pulseSheet = .weeks12 }, openReaders: { model.readersSheet = true })
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } else if model.reachability.isConnected {
            Section {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }
}

extension PhoneModel {
    /// The overview is the cache's, not the Mac's answer just now: Home dims it and says when it
    /// was.
    var isStale: Bool { !isDemo && !reachability.isConnected }
}

/// "As of 10:42" (or "As of 21 Oct, 10:42"): when the cached snapshot was made.
struct AsOfLabel: View {
    let date: Date

    var body: some View {
        let time = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        Label("As of \(time)", systemImage: "clock.arrow.circlepath")
            .labelStyle(CompactLabelStyle())
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Icon and title side by side, without a list row's icon column.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: Pulse

/// The week tile: "This week" with its dates, "104 saved · 265 shared" and the last 7 days'
/// in/out chart with a weekday under each day. A finger held on the chart puts that day's numbers
/// in the numbers' place (one line, so the chart never moves), with a light tap per day; the
/// header opens the sheet, with the legend and the longer ranges.
struct WeekTile: View {
    let overview: VaultOverview
    let stale: Bool
    let open: () -> Void
    @State private var selection: Date?

    var body: some View {
        let pulse = Pulse(overview, last: PulseRange.days7.last)
        let bucket = selection.flatMap { pulse.bucket(at: $0) }
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("This week")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let days = OverviewWords.days(pulse, calendar: overview.calendar) {
                        Text(days)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OverviewWords.week(overview.thisWeek))
            .accessibilityHint("Shows the longer ranges")
            .accessibilityAddTraits(.isButton)
            Group {
                if overview.isNewVault {
                    Text("Your pulse starts with your first memories")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    Text(bucket.map { OverviewWords.day($0, calendar: overview.calendar) } ?? OverviewWords.numbers(overview.thisWeek))
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityHidden(true)
                    PulseChart(pulse: pulse, range: .days7, calendar: overview.calendar, selection: $selection,
                               showsAxis: false, showsWeekdays: true)
                        .frame(height: 96)
                        .sensoryFeedback(.impact(weight: .light), trigger: bucket?.date) { _, new in new != nil }
                }
            }
            .dimmed(stale)
            if stale { AsOfLabel(date: overview.generatedAt) }
        }
        .tile()
    }
}

/// The chart with its line above (the bucket under a finger, or the range's totals) and its
/// legend below. The line keeps two lines' room, so scrubbing never moves the chart.
struct PulseDetail: View {
    let pulse: Pulse
    let range: PulseRange
    let calendar: Calendar
    @Binding var selection: Date?
    let height: CGFloat

    var body: some View {
        let bucket = selection.flatMap { pulse.bucket(at: $0) }
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let bucket {
                    Text("\(OverviewWords.bucket(bucket.date, unit: pulse.unit, calendar: calendar)) · \(OverviewWords.breakdown(bucket, agents: pulse.agents))")
                        .foregroundStyle(.primary)
                } else {
                    Text(OverviewWords.summary(pulse, range: range)).foregroundStyle(.secondary)
                }
            }
            .font(.caption.monospacedDigit())
            .lineLimit(2, reservesSpace: true)
            .accessibilityHidden(true)
            PulseChart(pulse: pulse, range: range, calendar: calendar, selection: $selection)
                .frame(height: height)
                .sensoryFeedback(.impact(weight: .light), trigger: bucket?.date) { _, new in new != nil }
            PulseLegend(pulse: pulse)
        }
    }
}

/// The Pulse card's sheet, from the card or the Rhythm tile: the chart full width with all four
/// ranges (12 weeks and 12 months asked for when shown, and cached per range), and the 12-week
/// Rhythm grid.
struct PulseSheet: View {
    let model: PhoneModel
    @State var range: PulseRange
    @State private var selection: Date?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let overview = model.overview.overview(range.overview)
        NavigationStack {
            List {
                Section {
                    Picker("Range", selection: Binding(get: { range }, set: { new in
                        selection = nil
                        withAnimation(reduceMotion ? nil : .default) { range = new }
                    })) {
                        ForEach(PulseRange.allCases) { Text(OverviewWords.rangeShort($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    if let overview {
                        let pulse = Pulse(overview, last: range.last)
                        VStack(alignment: .leading, spacing: 8) {
                            PulseDetail(pulse: pulse, range: range, calendar: overview.calendar, selection: $selection, height: 240)
                                .dimmed(model.isStale)
                            if model.isStale { AsOfLabel(date: overview.generatedAt) }
                        }
                    } else if model.reachability.isConnected || model.isDemo {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ContentUnavailableView("Your Mac isn't reachable", systemImage: "chart.bar.xaxis",
                                               description: Text("This range shows once your Mac can be reached."))
                    }
                }
                if let days = model.overview.overview(.days30) {
                    RhythmSection(overview: days)
                        .dimmed(model.isStale)
                }
            }
            .navigationTitle("Pulse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: range) {
                // Each range once a sheet; the cache shows meanwhile, and while the Mac is away.
                guard model.reachability.isConnected || model.isDemo else { return }
                await model.overview.load(range.overview)
            }
        }
        .presentationDragIndicator(.visible)
    }
}

/// The sheet's Rhythm: all 12 weeks, the busiest weekday and the streak.
struct RhythmSection: View {
    let overview: VaultOverview

    var body: some View {
        let grid = RhythmGrid(overview.rhythm, weeks: 12, calendar: overview.calendar)
        Section {
            VStack(alignment: .leading, spacing: 8) {
                RhythmGridView(grid: grid, spacing: 3)
                    .frame(maxWidth: .infinity, maxHeight: 160)
                Text(RhythmWords.line(grid, calendar: overview.calendar))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RhythmWords.accessibility(grid, calendar: overview.calendar))
        } header: {
            Text("Rhythm · 12 weeks")
        }
    }
}

// MARK: Tiles

/// Memories and Rhythm, then Sensitivity and Who reads, two by two, each row as tall as its
/// tallest tile; one column at the accessibility text sizes. Each reads as one element.
struct HomeTiles: View {
    let overview: VaultOverview
    let stale: Bool
    let openSearch: (Sensitivity?) -> Void
    let openRhythm: () -> Void
    let openReaders: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            if typeSize.isAccessibilitySize {
                GridRow { memories }
                GridRow { rhythm }
                GridRow { sensitivity }
                GridRow { readers }
            } else {
                GridRow {
                    memories
                    rhythm
                }
                GridRow {
                    sensitivity
                    readers
                }
            }
        }
        .dimmed(stale)
    }

    private var memories: some View {
        Button { openSearch(nil) } label: {
            Tile(title: String(localized: "Memories")) {
                Text(overview.total.formatted())
                    .font(.title.bold().monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                GrowthLine(growth: Growth(overview))
                    .frame(height: 40)
                Spacer(minLength: 0)
                Text("+\(overview.thisWeek.saved) this week")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memories: \(overview.total), plus \(overview.thisWeek.saved) this week")
        .accessibilityHint("Opens Search, newest first")
        .accessibilityAddTraits(.isButton)
    }

    private var rhythm: some View {
        let grid = RhythmGrid(overview.rhythm, weeks: 10, calendar: overview.calendar)
        return Button(action: openRhythm) {
            Tile(title: String(localized: "Rhythm")) {
                RhythmGridView(grid: grid, spacing: 3)
                    .frame(maxWidth: .infinity, maxHeight: 96, alignment: .leading)
                Spacer(minLength: 0)
                Text(grid.isTooSparse ? String(localized: "Too few memories for a rhythm yet")
                                      : grid.streak > 0 ? OverviewWords.streak(grid.streak) : String(localized: "No streak yet"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RhythmWords.accessibility(grid, calendar: overview.calendar))
        .accessibilityHint("Shows the longer ranges")
        .accessibilityAddTraits(.isButton)
    }

    private var sensitivity: some View {
        let vault = SensitivityMix(overview.bySensitivity)
        let shared = SensitivityMix(overview.sharedBySensitivity)
        return Menu {
            Section("Search by sensitivity") {
                ForEach(vault.parts) { part in
                    Button("\(part.level.title) · \(part.count)") { openSearch(part.level) }
                }
            }
        } label: {
            Tile(title: String(localized: "Sensitivity")) {
                SensitivityBars(vault: vault, shared: shared)
                    .padding(.top, 2)
                Spacer(minLength: 0)
                if let largest = SensitivityBars.largest(vault) {
                    Text("Vault: \(largest)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(vault.parts.isEmpty)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sensitivity. \(SensitivityBars.describe(vault: vault, shared: shared))")
        .accessibilityHint("Searches your vault by sensitivity")
        .accessibilityAddTraits(.isButton)
    }

    /// The agents shared something in 30 days, most first, each with a bar against the first, in
    /// the chart's colour for it.
    private var readers: some View {
        let readers = overview.readers().filter { $0.shared > 0 }
        let top = Double(max(1, readers.first?.shared ?? 1))
        return Button(action: openReaders) {
            Tile(title: String(localized: "Who reads")) {
                if readers.isEmpty {
                    Text("Nothing shared in 30 days")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(readers.enumerated()), id: \.element.id) { slot, agent in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(agent.name)
                                        .lineLimit(1)
                                        .privacySensitive()
                                    Spacer(minLength: 4)
                                    Text(agent.shared, format: .number)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.quaternary)
                                        Capsule()
                                            .fill(OverviewPalette.agent(slot))
                                            .frame(width: max(4, proxy.size.width * Double(agent.shared) / top))
                                    }
                                }
                                .frame(height: 5)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readers.isEmpty ? String(localized: "Who reads: nothing shared in 30 days")
                                            : String(localized: "Who reads, last 30 days: \(readers.map { "\($0.name) \($0.shared)" }.formatted(.list(type: .and)))"))
        .accessibilityHint("Shows who read your vault, and when")
        .privacySensitive()
        .accessibilityAddTraits(.isButton)
    }
}

/// A tile: its title, then its content, on the list's card colour.
struct Tile<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 132)
        .tile()
    }
}

extension View {
    /// Home's tile look, the widgets': the list's card colour, rounded.
    func tile() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: Who reads

/// The Who reads sheet, from its tile: the top three agents, the memories shared in 30 days, and
/// when each last asked, from the 30-day overview whatever range the Pulse sheet last showed.
struct ReadersSheet: View {
    let model: PhoneModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let overview = model.overview.overview(.days30) {
                    ReadersSection(overview: overview, stale: model.isStale)
                }
            }
            .navigationTitle("Who reads your vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The top three agents: the memories shared in 30 days, and when each last asked.
struct ReadersSection: View {
    let overview: VaultOverview
    let stale: Bool

    var body: some View {
        let readers = overview.readers()
        Section {
            if readers.isEmpty {
                Text("No agent has read your vault yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(readers) { agent in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name).privacySensitive()
                        Text(agent.shared == 1 ? String(localized: "1 memory shared") : String(localized: "\(agent.shared) memories shared"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let last = agent.lastRequestAt {
                        Text(last, format: .relative(presentation: .named))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !readers.isEmpty { Text("In the last 30 days.") }
                if stale { AsOfLabel(date: overview.generatedAt) }
            }
        }
        .dimmed(stale)
    }
}
