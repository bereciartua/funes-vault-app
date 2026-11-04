import AppKit
import Charts
import FunesCore
import FunesProtocol
import SwiftUI

/// The pulse's colors. In is five fixed hues, one per source (a validated categorical set, light
/// and dark); Out is one warm family stepped by rank, the top agent strongest, Other grey; refused
/// is the status red. The legend and the hover text name every series, so color is never the
/// only cue.
enum PulsePalette {
    static func source(_ source: HomeText.Source) -> Color {
        switch source {
        case .mac: adaptive(0x2a78d6, 0x3987e5)
        case .iphone: adaptive(0x1baf7a, 0x199e70)
        case .agent: adaptive(0x6250d6, 0x9085e9)
        case .import: adaptive(0xeda100, 0xc98500)
        case .tidy: adaptive(0xe87ba4, 0xd55181)
        }
    }

    static func out(rank: Int) -> Color {
        let light = [0xa8401a, 0xd4572a, 0xeb7a4c, 0xf3a582]
        let dark = [0xf29a70, 0xe0703f, 0xc25423, 0x9a4019]
        return adaptive(light[min(rank, 3)], dark[min(rank, 3)])
    }

    static let other = adaptive(0x9a9890, 0x6f6e68)
    static let refused = adaptive(0xd03b3b, 0xe66767)

    private static func adaptive(_ light: Int, _ dark: Int) -> Color {
        func color(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
}

/// The pulse card (04-ux-mac.md ▸ Home): the week's sentence, the range, and the chart of what
/// came in and what went out.
struct PulseCard: View {
    let model: AppModel
    let insights: OverviewInsights

    private var home: HomeModel { model.home }

    var body: some View {
        Card {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    sentence
                    Spacer(minLength: 12)
                    rangePicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    sentence
                    rangePicker
                }
            }
            if isNewVault {
                Text(String(localized: "Your pulse starts with your first memories"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: PulseChart.height + 22)
            } else {
                PulseChart(insights: insights, showsOut: !model.agents.isEmpty || insights.totals.shared > 0,
                           name: name, open: open)
                legend
                if model.agents.isEmpty && insights.totals.shared == 0 {
                    HStack(spacing: 4) {
                        Text(String(localized: "No agent has read your vault yet."))
                        Button(String(localized: "Add Agent…")) { model.wantsAddAgent = true }.buttonStyle(.link)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A vault with nothing yet: no memories now and nothing in the range.
    private var isNewVault: Bool {
        let totals = insights.totals
        return insights.overview.total == 0 && totals.inbound == 0 && totals.shared == 0 && totals.refused == 0
    }

    private var sentence: some View {
        Text(HomeText.week(insights.overview.thisWeek)).font(.headline).fixedSize(horizontal: false, vertical: true)
    }

    private var rangePicker: some View {
        Picker(String(localized: "Range"), selection: Binding(get: { home.range }, set: { home.range = $0 })) {
            ForEach(OverviewInsights.Range.allCases) { Text(HomeText.rangeTitle($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .accessibilityLabel(String(localized: "Range"))
    }

    /// In's sources and Out's agents that appear in the range, then Refused.
    private var legend: some View {
        let sources = HomeText.Source.allCases.filter { source in insights.buckets.contains { source.count($0.inbound) > 0 } }
        let out = insights.outSeries
        let inItems = sources.map { LegendItem(title: $0.title, color: PulsePalette.source($0)) }
        let outItems = out.enumerated().map { LegendItem(title: name($0.element), color: color($0.element, rank: $0.offset)) }
        let one = HStack(spacing: 14) {
            legendGroup(String(localized: "In"), inItems)
            legendGroup(String(localized: "Out"), outItems)
            refusedItem
        }
        let two = VStack(alignment: .leading, spacing: 4) {
            legendGroup(String(localized: "In"), inItems)
            HStack(spacing: 14) {
                legendGroup(String(localized: "Out"), outItems)
                refusedItem
            }
        }
        return ViewThatFits(in: .horizontal) { one; two }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }

    struct LegendItem: Hashable {
        let title: String
        let color: Color
    }

    @ViewBuilder
    private func legendGroup(_ title: String, _ items: [LegendItem]) -> some View {
        if !items.isEmpty {
            HStack(spacing: 8) {
                Text(title).fontWeight(.semibold)
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 9, height: 9).accessibilityHidden(true)
                        Text(item.title).lineLimit(1)
                    }
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var refusedItem: some View {
        if insights.totals.refused > 0 {
            HStack(spacing: 4) {
                Circle().fill(PulsePalette.refused).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(String(localized: "Refused"))
            }
            .fixedSize()
        }
    }

    private func color(_ series: OverviewInsights.OutSeries, rank: Int) -> Color {
        series == .other ? PulsePalette.other : PulsePalette.out(rank: rank)
    }

    /// An Out series' name: the agent's, "Removed agent" when the vault no longer knows it, or Other.
    private func name(_ series: OverviewInsights.OutSeries) -> String {
        switch series {
        case .other: return String(localized: "Other")
        case .agent(let id):
            if let agent = insights.overview.agents.first(where: { $0.id == id }), !agent.name.isEmpty { return agent.name }
            return UUID(uuidString: id).map(model.agentName) ?? String(localized: "Removed agent")
        }
    }

    /// A day's click: Activity for that day, or its Problems for a refused dot.
    private func open(_ bucket: VaultOverview.Bucket, refused: Bool) {
        model.showActivity(.period(insights.interval(of: bucket)), kind: refused ? .problems : .all)
    }
}

/// In above the line, stacked by source; Out below, stacked by agent; a red dot under each day
/// with refusals, sized by count. Each half has its own scale (`PulseScale`), the line in the
/// middle, and the y axis labels each half's peak. Hover shows the day's breakdown; a click opens it.
struct PulseChart: View {
    static let height: CGFloat = 132

    let insights: OverviewInsights
    /// False with no agents and nothing shared: the chart is In only.
    let showsOut: Bool
    let name: (OverviewInsights.OutSeries) -> String
    let open: (VaultOverview.Bucket, _ refused: Bool) -> Void

    @State private var hovered: Date?
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Segment: Identifiable {
        let id: String
        let date: Date
        let series: String
        /// The plot value: In and Out each on their own scale.
        let value: Double
    }

    private var unit: Calendar.Component {
        switch insights.range {
        case .days7, .days30: .day
        case .weeks12: .weekOfYear
        case .months12: .month
        }
    }

    private var buckets: [VaultOverview.Bucket] { insights.buckets }
    private var maxIn: Int { buckets.map(\.inbound.total).max() ?? 0 }
    private var maxOut: Int { showsOut ? buckets.map(\.shared).max() ?? 0 : 0 }
    private var yScale: PulseScale {
        PulseScale(peakIn: maxIn, peakOut: maxOut, refused: showsOut && buckets.contains { $0.refused > 0 })
    }
    /// Where the refused dots sit, under the deepest Out bar.
    private var dotY: Double { PulseScale.refusedY }
    /// The line in the middle; In only (the line at the bottom) without agents.
    private var yDomain: ClosedRange<Double> { showsOut ? PulseScale.domain : 0...PulseScale.top }

    private var segments: [Segment] {
        let yScale = self.yScale
        return buckets.flatMap { bucket -> [Segment] in
            let key = bucket.date.timeIntervalSinceReferenceDate
            let inbound = HomeText.Source.allCases.compactMap { source -> Segment? in
                let n = source.count(bucket.inbound)
                return n > 0 ? Segment(id: "\(key)-in-\(source)", date: bucket.date, series: "in.\(source)", value: yScale.plot(in: n)) : nil
            }
            let out = showsOut ? insights.out(bucket).map { entry in
                Segment(id: "\(key)-\(seriesKey(entry.series))", date: bucket.date, series: seriesKey(entry.series), value: yScale.plot(out: entry.count))
            } : []
            return inbound + out
        }
    }

    private func seriesKey(_ series: OverviewInsights.OutSeries) -> String {
        switch series {
        case .agent(let id): "out.\(id)"
        case .other: "out.other"
        }
    }

    private var scale: (domain: [String], range: [Color]) {
        var domain = HomeText.Source.allCases.map { "in.\($0)" }
        var range = HomeText.Source.allCases.map(PulsePalette.source)
        for (rank, series) in insights.outSeries.enumerated() {
            domain.append(seriesKey(series))
            range.append(series == .other ? PulsePalette.other : PulsePalette.out(rank: rank))
        }
        return (domain, range)
    }

    var body: some View {
        let scale = self.scale
        Chart {
            if let hovered {
                RectangleMark(x: .value("Day", hovered, unit: unit), yStart: .value("Bottom", yDomain.lowerBound),
                              yEnd: .value("Top", yDomain.upperBound))
                    .foregroundStyle(Color.primary.opacity(0.07))
            }
            ForEach(segments) { segment in
                BarMark(x: .value("Day", segment.date, unit: unit), y: .value("Memories", drawn ? segment.value : 0))
                    .foregroundStyle(by: .value("Series", segment.series))
                    .cornerRadius(2)
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1))
            if showsOut {
                ForEach(buckets.filter { $0.refused > 0 }, id: \.date) { bucket in
                    PointMark(x: .value("Day", bucket.date, unit: unit), y: .value("Memories", dotY))
                        .symbolSize(CGFloat(24 + 18 * min(bucket.refused, 6)) * (drawn ? 1 : 0.01))
                        .foregroundStyle(PulsePalette.refused)
                }
            }
        }
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
        .chartXScale(domain: (buckets.first?.date ?? Date())...(insights.buckets.last.map { insights.interval(of: $0).end } ?? Date()))
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                // The newest label ends under its bar, so it isn't dropped at the plot's edge.
                AxisValueLabel(anchor: value.index == 0 ? .topTrailing : .top) {
                    if let date = value.as(Date.self) { Text(axisLabel(date)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yScale.ticks) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let y = value.as(Double.self) {
                        let n = yScale.count(at: y)
                        Text(y > 0 ? String(localized: "\(n) in") : String(localized: "\(n) out"))
                    }
                }
            }
        }
        .chartOverlay { proxy in overlay(proxy) }
        .frame(height: Self.height)
        .accessibilityChartDescriptor(PulseDescriptor(insights: insights, name: name))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HomeText.summary(insights))
        .accessibilityChildren {
            HStack(spacing: 0) {
                ForEach(buckets, id: \.date) { bucket in
                    Rectangle()
                        .accessibilityLabel(HomeText.dayLabel(bucket, in: insights, name: name))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { open(bucket, false) }
                }
            }
        }
        .onChange(of: insights.range) { _, _ in hovered = nil }
        .onAppear {
            if reduceMotion {
                drawn = true
            } else {
                withAnimation(.easeOut(duration: 0.5)) { drawn = true }
            }
        }
    }

    /// About five labels, under the middle of their bars: each day for 7 days, weekly for 30,
    /// every third week, every other month, counting back from now.
    private var axisDates: [Date] {
        let step = switch insights.range {
        case .days7: 1
        case .days30: 7
        case .weeks12: 3
        case .months12: 2
        }
        return stride(from: buckets.count - 1, through: 0, by: -step).map { middle(of: buckets[$0]) }
    }

    private func middle(of bucket: VaultOverview.Bucket) -> Date {
        let interval = insights.interval(of: bucket)
        return interval.start.addingTimeInterval(interval.duration / 2)
    }

    private func axisLabel(_ date: Date) -> String {
        switch insights.range {
        case .days7: date.formatted(.dateTime.weekday(.abbreviated))
        case .days30, .weeks12: date.formatted(.dateTime.day().month(.abbreviated))
        case .months12: date.formatted(.dateTime.month(.abbreviated))
        }
    }

    private func bucket(at date: Date) -> VaultOverview.Bucket? {
        buckets.last { $0.date <= date && insights.interval(of: $0).end > date }
    }

    private func overlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                let hit = { (point: CGPoint) -> VaultOverview.Bucket? in
                    guard plot.contains(point), let date = proxy.value(atX: point.x - plot.minX, as: Date.self) else { return nil }
                    return bucket(at: date)
                }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hovered = hit(point)?.date
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { point in
                        guard let bucket = hit(point) else { return }
                        let dot = proxy.position(forY: dotY).map { $0 + plot.minY }
                        open(bucket, bucket.refused > 0 && dot.map { abs(point.y - $0) < 12 } == true)
                    }
                    .pointerStyle(hovered == nil ? .default : .link)
                if let hovered, let bucket = buckets.first(where: { $0.date == hovered }), let x = proxy.position(forX: middle(of: bucket)) {
                    let width: CGFloat = 230
                    tooltip(bucket)
                        .frame(width: width, alignment: .leading)
                        .position(x: min(max(plot.minX + x, plot.minX + width / 2), plot.maxX - width / 2), y: plot.minY + 34)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func tooltip(_ bucket: VaultOverview.Bucket) -> some View {
        let lines = HomeText.breakdown(bucket, in: insights, name: name)
        return VStack(alignment: .leading, spacing: 2) {
            Text(HomeText.bucketTitle(bucket, in: insights)).fontWeight(.semibold)
            if lines.isEmpty { Text(String(localized: "Nothing came in or went out")).foregroundStyle(.secondary) }
            ForEach(lines, id: \.self) { Text($0).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        // Solid, so the bars behind never show through the words.
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .fixedSize()
    }
}

/// VoiceOver's audio graph of the pulse: In, Shared and Refused per day.
struct PulseDescriptor: AXChartDescriptorRepresentable {
    let insights: OverviewInsights
    let name: (OverviewInsights.OutSeries) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let buckets = insights.buckets
        let titles = buckets.map { HomeText.bucketTitle($0, in: insights) }
        let top = Double(max(buckets.map(\.inbound.total).max() ?? 0, buckets.map(\.shared).max() ?? 0, 1))
        let x = AXCategoricalDataAxisDescriptor(title: String(localized: "Day"), categoryOrder: titles)
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Memories"), range: 0...top, gridlinePositions: []) { "\(Int($0))" }
        func series(_ title: String, _ value: (VaultOverview.Bucket) -> Int) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: title, isContinuous: false, dataPoints: zip(titles, buckets).map { title, bucket in
                AXDataPoint(x: title, y: Double(value(bucket)), label: HomeText.dayLabel(bucket, in: insights, name: name))
            })
        }
        return AXChartDescriptor(title: HomeText.summary(insights), summary: nil, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [series(String(localized: "In"), { $0.inbound.total }),
                                          series(String(localized: "Shared"), { $0.shared }),
                                          series(String(localized: "Refused"), { $0.refused })])
    }
}
