import AppKit
import Charts
import FunesCore
import FunesProtocol
import SwiftUI

/// The words of the last 24 hours (04-ux-mac.md ▸ Menu bar ▸ Last 24 hours): the header's counts,
/// each hour's breakdown and label. Counts and agents' names only (FR-H-07).
enum PulseText {
    /// "13 in · 27 shared · 1 refused", parts with nothing dropped; "Quiet: nothing in or out".
    static func counts(_ pulse: RecentPulse) -> String {
        guard !pulse.isQuiet else { return String(localized: "Quiet: nothing in or out") }
        var parts: [String] = []
        if pulse.inbound.total > 0 { parts.append(String(localized: "\(pulse.inbound.total) in")) }
        if pulse.shared > 0 { parts.append(String(localized: "\(pulse.shared) shared")) }
        if pulse.refused > 0 { parts.append(String(localized: "\(pulse.refused) refused")) }
        return parts.joined(separator: " · ")
    }

    /// "Last 24 hours: 13 memories in, 27 shared, 1 request refused".
    static func summary(_ pulse: RecentPulse) -> String {
        guard !pulse.isQuiet else { return String(localized: "Last 24 hours: nothing in or out") }
        let n = pulse.inbound.total
        let inText = n == 1 ? String(localized: "1 memory in") : String(localized: "\(n) memories in")
        let refused = pulse.refused == 1 ? String(localized: "1 request refused") : String(localized: "\(pulse.refused) requests refused")
        return String(localized: "Last 24 hours: \(inText), \(pulse.shared) shared, \(refused)")
    }

    /// "09:00–10:00", with the zone on an hour that happens twice ("01:00–02:00 EST").
    static func hourTitle(_ bucket: VaultOverview.Bucket, in pulse: RecentPulse, calendar: Calendar = .current) -> String {
        let interval = RecentPulse.interval(of: bucket)
        let text = (interval.start..<interval.end).formatted(.interval.hour().minute())
        let hour = calendar.component(.hour, from: bucket.date)
        let repeated = pulse.hours.filter { calendar.component(.hour, from: $0.date) == hour }.count > 1
        guard repeated, let zone = calendar.timeZone.abbreviation(for: bucket.date) else { return text }
        return "\(text) \(zone)"
    }

    /// "1 in (iPhone)", "4 shared (Claude Code 3, Codex 1)", "1 refused"; nothing for a quiet hour.
    static func breakdown(_ bucket: VaultOverview.Bucket, in pulse: RecentPulse) -> [String] {
        var lines: [String] = []
        let total = bucket.inbound.total
        if total > 0 {
            let sources = HomeText.Source.allCases.compactMap { source -> String? in
                let n = source.count(bucket.inbound)
                guard n > 0 else { return nil }
                return n == total ? source.title : "\(n) \(source.title)"
            }
            lines.append(String(localized: "\(total) in (\(sources.joined(separator: ", ")))"))
        }
        if bucket.shared > 0 {
            let agents = bucket.out.sorted { ($0.value, pulse.agentNames[$1.key] ?? "") > ($1.value, pulse.agentNames[$0.key] ?? "") }
                .map { "\(pulse.agentNames[$0.key] ?? String(localized: "Removed agent")) \($0.value)" }
            lines.append(String(localized: "\(bucket.shared) shared (\(agents.joined(separator: ", ")))"))
        }
        if bucket.refused > 0 { lines.append(String(localized: "\(bucket.refused) refused")) }
        return lines
    }

    /// "09:00–10:00 · 1 in (iPhone) · 4 shared (Claude Code 3, Codex 1) · 1 refused".
    static func hourLabel(_ bucket: VaultOverview.Bucket, in pulse: RecentPulse) -> String {
        let lines = breakdown(bucket, in: pulse)
        return ([hourTitle(bucket, in: pulse)] + (lines.isEmpty ? [String(localized: "nothing in or out")] : lines))
            .joined(separator: " · ")
    }
}

/// Last 24 hours: the header and its counts, then the chart; the new-vault line in a vault with nothing yet.
struct RecentPulseSection: View {
    let model: MenuBarPanelModel
    var focus: FocusState<PanelFocus?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Last 24 hours")).font(.subheadline.weight(.semibold))
                Spacer()
                if let pulse = model.pulse, !model.isNewVault {
                    Text(PulseText.counts(pulse)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if model.isNewVault {
                Text(String(localized: "Your pulse starts with your first memories"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if let pulse = model.pulse {
                RecentPulseChart(pulse: pulse, focus: focus, open: model.openHour)
            } else {
                Color.clear.frame(height: RecentPulseChart.height + 16)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 24 hourly bars, the current hour last: In above the line (new memories, one color), Shared
/// below it (memories delivered), a red dot under an hour with refusals. Each half has its own
/// scale, as in Home's pulse (`PulseScale`, `PulsePalette`). Hover says the hour's breakdown; a
/// click, or ⏎ on the focused hour, opens Activity for that hour (a dot, its Problems).
struct RecentPulseChart: View {
    static let height: CGFloat = 96

    let pulse: RecentPulse
    var focus: FocusState<PanelFocus?>.Binding
    let open: (VaultOverview.Bucket, _ problems: Bool) -> Void

    @State private var hovered: Date?
    @State private var focused = 23
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var hours: [VaultOverview.Bucket] { pulse.hours }
    private var scale: PulseScale {
        PulseScale(peakIn: hours.map(\.inbound.total).max() ?? 0, peakOut: hours.map(\.shared).max() ?? 0,
                   refused: hours.contains { $0.refused > 0 })
    }
    /// In and Shared: Home's Mac blue and its second Out step; with Increase Contrast, the
    /// strongest Out step and the blue at full strength against a primary-tinted line.
    private var inColor: Color { PulsePalette.source(.mac) }
    private var outColor: Color { contrast == .increased ? PulsePalette.out(rank: 0) : PulsePalette.out(rank: 1) }
    private var chartFocused: Bool { focus.wrappedValue == .chart }
    /// The hour hover or the keyboard points at.
    private var marked: Date? { hovered ?? (chartFocused ? hours[safe: focused]?.date : nil) }

    var body: some View {
        let scale = self.scale
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                if let marked {
                    RectangleMark(x: .value("Hour", marked, unit: .hour), yStart: .value("Bottom", PulseScale.domain.lowerBound),
                                  yEnd: .value("Top", PulseScale.domain.upperBound))
                        .foregroundStyle(Color.primary.opacity(0.08))
                }
                ForEach(hours, id: \.date) { bucket in
                    if bucket.inbound.total > 0 {
                        BarMark(x: .value("Hour", bucket.date, unit: .hour), y: .value("In", drawn ? scale.plot(in: bucket.inbound.total) : 0))
                            .foregroundStyle(inColor)
                            .cornerRadius(1.5)
                    }
                    if bucket.shared > 0 {
                        BarMark(x: .value("Hour", bucket.date, unit: .hour), y: .value("Shared", drawn ? scale.plot(out: bucket.shared) : 0))
                            .foregroundStyle(outColor)
                            .cornerRadius(1.5)
                    }
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(hours.filter { $0.refused > 0 }, id: \.date) { bucket in
                    PointMark(x: .value("Hour", bucket.date, unit: .hour), y: .value("Refused", PulseScale.refusedY))
                        .symbolSize(CGFloat(18 + 12 * min(bucket.refused, 5)) * (drawn ? 1 : 0.01))
                        .foregroundStyle(PulsePalette.refused)
                }
            }
            .chartYScale(domain: PulseScale.domain)
            .chartXScale(domain: hours.first!.date...hours.last!.date.addingTimeInterval(3_600))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: axisHours) { value in
                    AxisValueLabel(anchor: value.index == axisHours.count - 1 ? .topTrailing : .top) {
                        if let date = value.as(Date.self) { Text(axisLabel(date)) }
                    }
                }
            }
            .chartOverlay { proxy in overlay(proxy) }
            .frame(height: Self.height)
            .focusable()
            .focused(focus, equals: .chart)
            .focusEffectDisabled()
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(chartFocused ? 0.6 : 0), lineWidth: 1.5))
            .onKeyPress(.leftArrow) { focused = max(0, focused - 1); return .handled }
            .onKeyPress(.rightArrow) { focused = min(hours.count - 1, focused + 1); return .handled }
            .onKeyPress(.return) {
                if let bucket = hours[safe: focused] { open(bucket, false) }
                return .handled
            }
            .onKeyPress(.escape) {
                focus.wrappedValue = .field
                return .handled
            }
            .accessibilityChartDescriptor(RecentPulseDescriptor(pulse: pulse))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(PulseText.summary(pulse))
            .accessibilityChildren {
                HStack(spacing: 0) {
                    ForEach(hours, id: \.date) { bucket in
                        Rectangle()
                            .accessibilityLabel(PulseText.hourLabel(bucket, in: pulse))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { open(bucket, false) }
                            .accessibilityActions {
                                if bucket.refused > 0 {
                                    Button(String(localized: "Show Problems")) { open(bucket, true) }
                                }
                            }
                    }
                }
            }
            if let marked, let bucket = hours.first(where: { $0.date == marked }) {
                Text(PulseText.hourLabel(bucket, in: pulse))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            if reduceMotion { drawn = true } else { withAnimation(.easeOut(duration: 0.4)) { drawn = true } }
        }
    }

    /// Every 6 hours by the clock (12:00, 18:00, 00:00, 06:00), plus "now" under the last bar.
    private var axisHours: [Date] {
        let calendar = Calendar.current
        // Not within 5 hours of "now" or at the left edge, where the labels would collide or clip
        // ("12:00 PM" 4 hours before "now" touches it).
        let sixes = hours.dropFirst().dropLast(5).filter { calendar.component(.hour, from: $0.date) % 6 == 0 }
            .map { $0.date.addingTimeInterval(1_800) }
        return sixes + [hours.last!.date.addingTimeInterval(1_800)]
    }

    private func axisLabel(_ date: Date) -> String {
        if date > hours.last!.date { return String(localized: "now") }
        return date.addingTimeInterval(-1_800).formatted(.dateTime.hour().minute())
    }

    private func bucket(at date: Date) -> VaultOverview.Bucket? {
        hours.last { $0.date <= date && $0.date.addingTimeInterval(3_600) > date }
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
                        let dot = proxy.position(forY: PulseScale.refusedY).map { $0 + plot.minY }
                        open(bucket, bucket.refused > 0 && dot.map { abs(point.y - $0) < 10 } == true)
                    }
                    .pointerStyle(hovered == nil ? .default : .link)
            }
        }
    }
}

/// VoiceOver's audio graph of the last 24 hours: In, Shared and Refused per hour.
struct RecentPulseDescriptor: AXChartDescriptorRepresentable {
    let pulse: RecentPulse

    func makeChartDescriptor() -> AXChartDescriptor {
        let hours = pulse.hours
        let titles = hours.map { PulseText.hourTitle($0, in: pulse) }
        let top = Double(max(hours.map(\.inbound.total).max() ?? 0, hours.map(\.shared).max() ?? 0,
                             hours.map(\.refused).max() ?? 0, 1))
        let x = AXCategoricalDataAxisDescriptor(title: String(localized: "Hour"), categoryOrder: titles)
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Memories"), range: 0...top, gridlinePositions: []) { "\(Int($0))" }
        func series(_ title: String, _ value: (VaultOverview.Bucket) -> Int) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: title, isContinuous: false, dataPoints: zip(titles, hours).map { title, bucket in
                AXDataPoint(x: title, y: Double(value(bucket)), label: PulseText.hourLabel(bucket, in: pulse))
            })
        }
        return AXChartDescriptor(title: PulseText.summary(pulse), summary: nil, xAxis: x, yAxis: y, additionalAxes: [],
                                 series: [series(String(localized: "In"), { $0.inbound.total }),
                                          series(String(localized: "Shared"), { $0.shared }),
                                          series(String(localized: "Refused"), { $0.refused })])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
