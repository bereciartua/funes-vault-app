import Charts
import FunesPhone
import FunesProtocol
import SwiftUI

// Home's charts (UX: iPhone ▸ Home tab), in the app and the Intents extension both, so the widgets
// (task 7.5) draw the same thing. SwiftUI and Swift Charts only: nothing app-only. The numbers
// are FunesPhone's (`Pulse`, `Growth`, `RhythmGrid`, `SensitivityMix`); the words are here.

// MARK: Colours

/// The charts' colours: a hue per source above the line, per agent below it, never the same
/// one on both sides, and the refused dots red. Each stack's neighbours stay apart for colour
/// blindness (checked with the dataviz palette validator, light and dark); the legend names every
/// series, so colour is never the only cue.
enum OverviewPalette {
    /// iPhone, Mac, Agents, Imports, Tidy-up, in the stack's order.
    static func source(_ source: PulseSource) -> Color {
        switch source {
        case .iphone: Color(light: 0x1BAF7A, dark: 0x199E70)
        case .mac: Color(light: 0x2A78D6, dark: 0x3987E5)
        case .agent: Color(light: 0xE87BA4, dark: 0xD55181)
        case .import: Color(light: 0x008300, dark: 0x008300)
        case .tidy: other
        }
    }

    /// The first, second and third agents, then Other.
    static func agent(_ slot: Int) -> Color {
        switch slot {
        case 0: Color(light: 0xEB6834, dark: 0xD95926)
        case 1: Color(light: 0x6250D6, dark: 0x9085E9)
        case 2: Color(light: 0xEDA100, dark: 0xC98500)
        default: other
        }
    }

    static let other = Color(light: 0x8A8F98, dark: 0x8A8F98)
    static let refused = Color(light: 0xE34948, dark: 0xE66767)
}

extension Color {
    /// A colour with a light and a dark value.
    init(light: UInt32, dark: UInt32) {
        func components(_ hex: UInt32) -> (Double, Double, Double) {
            (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        let l = components(light), d = components(dark)
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

extension Sensitivity {
    /// "Low", "Internal"… for badges, pickers and the Sensitivity tile.
    var title: String {
        switch self {
        case .public: String(localized: "Public")
        case .low: String(localized: "Low")
        case .internal: String(localized: "Internal")
        case .sensitive: String(localized: "Sensitive")
        case .restricted: String(localized: "Restricted")
        case .secret: String(localized: "Secret")
        }
    }

    var tint: Color {
        switch self {
        case .public: .gray
        case .low: .green
        case .internal: .blue
        case .sensitive: .orange
        case .restricted: .red
        case .secret: .purple
        }
    }
}

// MARK: Words

/// Where new memories came from: the In stack's series.
enum PulseSource: CaseIterable {
    case iphone, mac, agent, `import`, tidy

    var title: String {
        switch self {
        case .iphone: String(localized: "iPhone")
        case .mac: String(localized: "Mac")
        case .agent: String(localized: "Agents")
        case .import: String(localized: "Imports")
        case .tidy: String(localized: "Tidy-up")
        }
    }

    func count(_ sources: VaultOverview.Sources) -> Int {
        switch self {
        case .iphone: sources.iphone
        case .mac: sources.mac
        case .agent: sources.agent
        case .import: sources.import
        case .tidy: sources.tidy
        }
    }
}

/// Home's and the widgets' sentences, numbers over adjectives.
enum OverviewWords {
    /// "This week: 7 saved, 7 shared with 2 agents, 1 refused." Parts with nothing to say drop
    /// out; "Nothing new this week." when none has anything.
    static func week(_ week: VaultOverview.Week) -> String {
        var parts: [String] = []
        if week.saved > 0 { parts.append(String(localized: "\(week.saved) saved")) }
        if week.shared > 0 {
            parts.append(week.agents == 1 ? String(localized: "\(week.shared) shared with 1 agent")
                                          : String(localized: "\(week.shared) shared with \(week.agents) agents"))
        }
        if week.refused > 0 { parts.append(String(localized: "\(week.refused) refused")) }
        guard !parts.isEmpty else { return String(localized: "Nothing new this week.") }
        return String(localized: "This week: \(parts.joined(separator: ", ")).")
    }

    /// "7 saved · 7 shared · 1 refused": the Pulse widget's line, refused only when there were
    /// any.
    static func numbers(_ week: VaultOverview.Week) -> String {
        var parts = [String(localized: "\(week.saved) saved"), String(localized: "\(week.shared) shared")]
        if week.refused > 0 { parts.append(String(localized: "\(week.refused) refused")) }
        return parts.joined(separator: " · ")
    }

    /// "Last 14 days: 20 in · 41 shared · 1 refused": the Pulse widget's chart, as VoiceOver
    /// reads it.
    static func lastDays(_ pulse: Pulse) -> String {
        String(localized: "Last \(pulse.buckets.count) days: \(pulse.inbound) in · \(pulse.shared) shared · \(pulse.refused) refused")
    }

    /// "Last 30 days: 41 in · 96 shared · 3 refused": the chart's totals, above it and as
    /// VoiceOver reads it.
    static func summary(_ pulse: Pulse, range: PulseRange) -> String {
        String(localized: "\(rangeTitle(range)): \(pulse.inbound) in · \(pulse.shared) shared · \(pulse.refused) refused")
    }

    static func rangeTitle(_ range: PulseRange) -> String {
        switch range {
        case .days7: String(localized: "Last 7 days")
        case .days30: String(localized: "Last 30 days")
        case .weeks12: String(localized: "Last 12 weeks")
        case .months12: String(localized: "Last 12 months")
        }
    }

    /// The switch's words.
    static func rangeShort(_ range: PulseRange) -> String {
        switch range {
        case .days7: String(localized: "7 days")
        case .days30: String(localized: "30 days")
        case .weeks12: String(localized: "12 weeks")
        case .months12: String(localized: "12 months")
        }
    }

    /// "Tue 21 Oct", "Week of 13 Oct", "October 2026".
    static func bucket(_ date: Date, unit: Pulse.Unit, calendar: Calendar) -> String {
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        switch unit {
        case .day: return date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
        case .week: return String(localized: "Week of \(date.formatted(style.day().month(.abbreviated)))")
        case .month:
            style = style.month(.wide).year()
            return date.formatted(style)
        }
    }

    /// "4 in (2 iPhone, 2 Agents) · 11 shared (Claude Code 8, Cursor 3) · 1 refused": a day under
    /// a finger, or read by VoiceOver.
    static func breakdown(_ bucket: Pulse.Bucket, agents: [Pulse.Agent]) -> String {
        let total = bucket.inbound.total
        let sources = PulseSource.allCases.compactMap { source -> String? in
            let n = source.count(bucket.inbound)
            return n > 0 ? "\(n) \(source.title)" : nil
        }
        var parts = [total > 0 ? String(localized: "\(total) in (\(sources.joined(separator: ", ")))") : String(localized: "0 in")]
        if bucket.shared > 0 {
            let names = zip(agents, bucket.out).filter { $0.1 > 0 }.map { "\(agentName($0.0)) \($0.1)" }
            parts.append(String(localized: "\(bucket.shared) shared (\(names.joined(separator: ", ")))"))
        }
        if bucket.refused > 0 { parts.append(String(localized: "\(bucket.refused) refused")) }
        return parts.joined(separator: " · ")
    }

    static func agentName(_ agent: Pulse.Agent) -> String { agent.name ?? String(localized: "Other") }

    /// "Most on Sundays".
    static func busiest(_ weekday: Int, calendar: Calendar) -> String {
        let names = calendar.standaloneWeekdaySymbols
        let name = names.indices.contains(weekday - 1) ? names[weekday - 1] : ""
        return String(localized: "Most on \(name)s")
    }

    /// "3-week streak".
    static func streak(_ weeks: Int) -> String {
        weeks == 1 ? String(localized: "1-week streak") : String(localized: "\(weeks)-week streak")
    }
}

/// The Rhythm grid's words, on Home and in the Rhythm widget.
enum RhythmWords {
    /// "Most on Sundays · 3-week streak", or "Too few memories for a rhythm yet".
    static func line(_ grid: RhythmGrid, calendar: Calendar) -> String {
        guard !grid.isTooSparse else { return String(localized: "Too few memories for a rhythm yet") }
        let parts = [grid.busiestWeekday.map { OverviewWords.busiest($0, calendar: calendar) },
                     grid.streak > 0 ? OverviewWords.streak(grid.streak) : nil]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// "Rhythm, last 8 weeks: 23 new memories. Most on Sundays · 3-week streak".
    static func accessibility(_ grid: RhythmGrid, calendar: Calendar) -> String {
        let count = grid.cells.compactMap(\.count).reduce(0, +)
        return count == 1 ? String(localized: "Rhythm, last \(grid.weeks) weeks: 1 new memory. \(line(grid, calendar: calendar))")
                          : String(localized: "Rhythm, last \(grid.weeks) weeks: \(count) new memories. \(line(grid, calendar: calendar))")
    }
}

extension View {
    /// The cached snapshot while the Mac is away (Home), or over a day old (the widgets): faded
    /// and greyed, never colour alone ("As of 10:42" goes beside it).
    func dimmed(_ stale: Bool) -> some View {
        opacity(stale ? 0.55 : 1).saturation(stale ? 0.2 : 1)
    }
}

// MARK: Pulse

/// The in/out chart: new memories by source above the line, memories shared by agent below it,
/// and a red dot under each bucket with refused requests. With `selection`, a finger (or
/// VoiceOver's swipe up and down) picks a bucket; the widgets pass none.
struct PulseChart: View {
    let pulse: Pulse
    let range: PulseRange
    var calendar: Calendar = .autoupdatingCurrent
    var selection: Binding<Date?>?
    /// The x axis's dates; the widgets leave them out.
    var showsAxis = true

    var body: some View {
        chart
            .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                if showsAxis {
                    AxisMarks(values: axisDates) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) { Text(Self.axisLabel(date, unit: pulse.unit, calendar: calendar)) }
                        }
                    }
                } else {
                    AxisMarks(values: [Date]()) { _ in }
                }
            }
            .environment(\.calendar, calendar)
            .chartOverlay { proxy in
                if let selection { Scrubbing(proxy: proxy, selection: selection) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OverviewWords.summary(pulse, range: range))
            .accessibilityValue(selectedValue)
            .accessibilityChartDescriptor(PulseDescriptor(pulse: pulse, range: range, calendar: calendar))
            .modifier(StepThrough(pulse: pulse, selection: selection))
    }

    private var chart: some View {
        Chart {
            ForEach(pulse.buckets) { bucket in
                ForEach(PulseSource.allCases, id: \.self) { source in
                    let n = source.count(bucket.inbound)
                    if n > 0 {
                        BarMark(x: .value("Date", bucket.date, unit: pulse.unit.component), y: .value("Memories", n))
                            .foregroundStyle(OverviewPalette.source(source))
                            .opacity(opacity(bucket))
                    }
                }
                ForEach(Array(zip(pulse.agents, bucket.out)), id: \.0.id) { agent, n in
                    if n > 0 {
                        BarMark(x: .value("Date", bucket.date, unit: pulse.unit.component), y: .value("Memories", -n))
                            .foregroundStyle(OverviewPalette.agent(agent.slot))
                            .opacity(opacity(bucket))
                    }
                }
                if bucket.refused > 0 {
                    PointMark(x: .value("Date", bucket.date, unit: pulse.unit.component), y: .value("Memories", refusedY))
                        .symbolSize(bucket.refused > 2 ? 60 : bucket.refused > 1 ? 40 : 24)
                        .foregroundStyle(OverviewPalette.refused)
                        .opacity(opacity(bucket))
                }
            }
            RuleMark(y: .value("Memories", 0))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(Color.primary.opacity(0.35))
        }
    }

    /// The bucket VoiceOver stepped to: "Thu, Oct 22: 2 in (2 iPhone) · 2 shared (Claude Code 2)".
    private var selectedValue: String {
        guard let bucket = selectedBucket else { return "" }
        return OverviewWords.bucket(bucket.date, unit: pulse.unit, calendar: calendar) + ": " + OverviewWords.breakdown(bucket, agents: pulse.agents)
    }

    private var selectedBucket: Pulse.Bucket? { selection?.wrappedValue.flatMap { pulse.bucket(at: $0) } }

    private func opacity(_ bucket: Pulse.Bucket) -> Double {
        guard let selected = selectedBucket else { return 1 }
        return selected.date == bucket.date ? 1 : 0.35
    }

    /// Room under the Out bars for the refused dots.
    private var gap: Double { max(1, Double(pulse.peakIn + pulse.peakOut) * 0.14) }
    private var refusedY: Double { -Double(pulse.peakOut) - gap * 0.6 }

    private var yDomain: ClosedRange<Double> {
        guard !pulse.isEmpty else { return -1...1 }
        let bottom = pulse.refused > 0 ? -Double(pulse.peakOut) - gap : -Double(max(pulse.peakOut, 0))
        return min(bottom, -0.5)...max(Double(pulse.peakIn), 0.5)
    }

    /// The first bucket, the last, and one or two between.
    private var axisDates: [Date] {
        let dates = pulse.buckets.map(\.date)
        guard dates.count > 2 else { return dates }
        let n = dates.count
        return [dates[0], dates[n / 2], dates[n - 1]]
    }

    static func axisLabel(_ date: Date, unit: Pulse.Unit, calendar: Calendar) -> String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        return switch unit {
        case .day, .week: date.formatted(style.day().month(.abbreviated))
        case .month: date.formatted(style.month(.abbreviated))
        }
    }

    /// A finger held on the chart, then moved, picks the bucket under it; lifted, nothing is
    /// picked. Holding first leaves a quick swipe to the list, which scrolls as usual.
    private struct Scrubbing: View {
        let proxy: ChartProxy
        let selection: Binding<Date?>

        var body: some View {
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.15)
                            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                            .onChanged { value in
                                guard case let .second(true, drag?) = value, let plot = proxy.plotFrame else { return }
                                let x = drag.location.x - geometry[plot].origin.x
                                selection.wrappedValue = proxy.value(atX: x, as: Date.self)
                            }
                            .onEnded { _ in selection.wrappedValue = nil }
                    )
            }
        }
    }

    /// VoiceOver: swipe up and down to step through the buckets, each read as its breakdown.
    private struct StepThrough: ViewModifier {
        let pulse: Pulse
        let selection: Binding<Date?>?

        func body(content: Content) -> some View {
            if let selection {
                content.accessibilityAdjustableAction { direction in
                    let dates = pulse.buckets.map(\.date)
                    guard !dates.isEmpty else { return }
                    let current = selection.wrappedValue.flatMap { pulse.bucket(at: $0)?.date }.flatMap { dates.firstIndex(of: $0) }
                    switch direction {
                    case .increment: selection.wrappedValue = dates[min((current ?? -1) + 1, dates.count - 1)]
                    case .decrement: selection.wrappedValue = dates[max((current ?? dates.count) - 1, 0)]
                    @unknown default: break
                    }
                }
            } else {
                content
            }
        }
    }
}

/// The pulse as an audio graph: In and Shared per bucket.
struct PulseDescriptor: AXChartDescriptorRepresentable {
    let pulse: Pulse
    let range: PulseRange
    let calendar: Calendar

    func makeChartDescriptor() -> AXChartDescriptor {
        let labels = pulse.buckets.map { OverviewWords.bucket($0.date, unit: pulse.unit, calendar: calendar) }
        let x = AXCategoricalDataAxisDescriptor(title: String(localized: "Date"), categoryOrder: labels)
        let peak = Double(max(pulse.peakIn, pulse.peakOut, 1))
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Memories"), range: 0...peak, gridlinePositions: []) {
            String(localized: "\(Int($0)) memories")
        }
        let inbound = AXDataSeriesDescriptor(name: String(localized: "In"), isContinuous: false, dataPoints: zip(labels, pulse.buckets).map {
            AXDataPoint(x: $0, y: Double($1.inbound.total))
        })
        let shared = AXDataSeriesDescriptor(name: String(localized: "Shared"), isContinuous: false, dataPoints: zip(labels, pulse.buckets).map {
            AXDataPoint(x: $0, y: Double($1.shared))
        })
        return AXChartDescriptor(title: OverviewWords.rangeTitle(range), summary: OverviewWords.summary(pulse, range: range),
                                 xAxis: x, yAxis: y, additionalAxes: [], series: [inbound, shared])
    }
}

/// The pulse's legend: every series that has a count, so colour is never the only cue.
struct PulseLegend: View {
    let pulse: Pulse

    var body: some View {
        let sources = PulseSource.allCases.filter { source in pulse.buckets.contains { source.count($0.inbound) > 0 } }
        let agents = pulse.agents.enumerated().filter { i, _ in pulse.buckets.contains { $0.out[i] > 0 } }.map(\.element)
        VStack(alignment: .leading, spacing: 4) {
            if !sources.isEmpty {
                row(String(localized: "In"), sources.map { ($0.title, OverviewPalette.source($0)) })
            }
            if !agents.isEmpty {
                row(String(localized: "Out"), agents.map { (OverviewWords.agentName($0), OverviewPalette.agent($0.slot)) })
            }
            if pulse.refused > 0 {
                row("", [(String(localized: "Refused"), OverviewPalette.refused)], dot: true)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func row(_ title: String, _ items: [(String, Color)], dot: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).fontWeight(.semibold).frame(minWidth: 24, alignment: .leading)
            FlowRow(spacing: 8) {
                ForEach(items, id: \.0) { name, color in
                    HStack(spacing: 3) {
                        if dot {
                            Circle().fill(color).frame(width: 7, height: 7)
                        } else {
                            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                        }
                        Text(name).lineLimit(1)
                    }
                }
            }
        }
    }
}

/// Items left to right, wrapping to a new line when the next doesn't fit.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing / 2 * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing / 2
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: Tiles' charts

/// The Memories tile's line: the vault's total over 12 weeks.
struct GrowthLine: View {
    let growth: Growth

    var body: some View {
        let totals = growth.points.map(\.total)
        let low = Double(totals.min() ?? 0), high = Double(max(totals.max() ?? 1, 1))
        Chart(growth.points) { point in
            AreaMark(x: .value("Date", point.date), yStart: .value("Memories", low), yEnd: .value("Memories", Double(point.total)))
                .foregroundStyle(.tint.opacity(0.15))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Date", point.date), y: .value("Memories", Double(point.total)))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(.tint)
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: low...(high > low ? high : low + 1))
        .accessibilityHidden(true)
    }
}

/// The Sensitivity tile's bars: the vault's mix, and what was shared in the range.
struct SensitivityBars: View {
    let vault: SensitivityMix
    let shared: SensitivityMix

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar(String(localized: "Vault"), vault)
            bar(String(localized: "Shared"), shared)
        }
        .accessibilityHidden(true)
    }

    private func bar(_ title: String, _ mix: SensitivityMix) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { proxy in
                HStack(spacing: mix.parts.count > 1 ? 2 : 0) {
                    if mix.parts.isEmpty {
                        Capsule().fill(.quaternary)
                    }
                    ForEach(mix.parts) { part in
                        Rectangle()
                            .fill(part.level.tint)
                            .frame(width: max(2, (proxy.size.width - CGFloat(mix.parts.count - 1) * 2) * mix.fraction(part.level)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
        }
    }

    /// "Vault: 48% Low · Shared: 78% Low", for VoiceOver and the tile's line.
    static func describe(vault: SensitivityMix, shared: SensitivityMix) -> String {
        func part(_ mix: SensitivityMix) -> String? {
            guard let largest = mix.largest else { return nil }
            return "\(mix.fraction(largest.level).formatted(.percent.precision(.fractionLength(0)))) \(largest.level.title)"
        }
        let parts = [part(vault).map { String(localized: "Vault: \($0)") }, part(shared).map { String(localized: "Shared: \($0)") }]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// The Rhythm grid: a column per week, a row per weekday, darker for more new memories.
struct RhythmGridView: View {
    let grid: RhythmGrid
    var spacing: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let side = max(2, min((proxy.size.width - spacing * CGFloat(grid.weeks - 1)) / CGFloat(grid.weeks),
                                  (proxy.size.height - spacing * 6) / 7))
            HStack(alignment: .top, spacing: spacing) {
                ForEach(0..<grid.weeks, id: \.self) { week in
                    VStack(spacing: spacing) {
                        ForEach(grid.cells.filter { $0.week == week }) { cell in
                            RoundedRectangle(cornerRadius: side / 4)
                                .fill(fill(cell.count))
                                .frame(width: side, height: side)
                        }
                    }
                }
            }
        }
        .aspectRatio(CGFloat(grid.weeks) / 7, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func fill(_ count: Int?) -> AnyShapeStyle {
        guard let count else { return AnyShapeStyle(.clear) }
        guard count > 0, grid.peak > 0 else { return AnyShapeStyle(.quaternary) }
        // Four steps of one hue, light to dark.
        let step = min(4, 1 + (count - 1) * 4 / max(1, grid.peak))
        return AnyShapeStyle(Color.accentColor.opacity([0.3, 0.5, 0.75, 1][step - 1]))
    }
}
