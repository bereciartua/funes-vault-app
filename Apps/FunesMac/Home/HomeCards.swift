import Charts
import FunesCore
import FunesProtocol
import SwiftUI

/// Memories, Sensitivity, Rhythm and Who reads your vault, each opening its filtered place: in a
/// row when they fit, else two rows of two (the window's minimum size).
struct HomeCards: View {
    let model: AppModel
    let insights: OverviewInsights

    var body: some View {
        CardGrid {
            memories
            sensitivity
            rhythm
            readers
        }
    }

    private var memories: some View { MemoriesCard(model: model, insights: insights).homeCard() }
    private var sensitivity: some View { SensitivityCard(model: model, insights: insights).homeCard() }
    private var rhythm: some View { RhythmCard(model: model, insights: insights).homeCard() }
    private var readers: some View { ReadersCard(model: model, insights: insights).homeCard() }
}

private extension View {
    /// A card fills its cell, so the cards in a row share its height.
    func homeCard() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The cards in one row while each gets at least `minimumWidth`, else in rows of two; each row
/// as tall as its tallest card. Decided by the width offered, not by the cards' one-line widths.
private struct CardGrid: Layout {
    var spacing: CGFloat = 12
    var minimumWidth: CGFloat = 170

    private func columns(_ width: CGFloat, _ count: Int) -> Int {
        width >= CGFloat(count) * minimumWidth + CGFloat(count - 1) * spacing ? count : min(2, count)
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (columnWidth: CGFloat, heights: [CGFloat], columns: Int) {
        let columns = max(columns(width, subviews.count), 1)
        let columnWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
        }
        return (columnWidth, heights, columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let layout = rows(width, subviews)
        return CGSize(width: width, height: layout.heights.reduce(0, +) + CGFloat(max(layout.heights.count - 1, 0)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in layout.heights.enumerated() {
            for column in 0..<layout.columns {
                let index = row * layout.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (layout.columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: layout.columnWidth, height: height))
            }
            y += height + spacing
        }
    }
}

/// A card's surface, title and caption; the whole card is one button when it opens a place.
private struct HomeCard<Content: View>: View {
    let title: String
    var caption: String?
    var help: String?
    var action: (() -> Void)?
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if action != nil {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            content
            Spacer(minLength: 0)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.card.opacity(1))
        .overlay(Color.primary.opacity(hovering ? 0.03 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Palette.separator.opacity(contrast == .increased ? 1 : 0.6), lineWidth: contrast == .increased ? 1 : 0.5))
        if let action {
            Button(action: action) { card.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(help ?? "")
                .accessibilityElement(children: .combine)
                .accessibilityHint(help ?? "")
        } else {
            card.accessibilityElement(children: .contain)
        }
    }
}

// MARK: Memories

/// The total, counted up, with the vault's growth over 12 weeks and "+9 this week".
private struct MemoriesCard: View {
    let model: AppModel
    let insights: OverviewInsights
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let overview = insights.overview
        let growth = insights.growth
        HomeCard(title: String(localized: "Memories"),
                 caption: overview.thisWeek.saved > 0 ? String(localized: "+\(overview.thisWeek.saved) this week")
                                                      : String(localized: "None new this week"),
                 help: String(localized: "Show the newest in the Vault"),
                 action: { model.showVault(newestFirst: true) }) {
            HStack(alignment: .bottom, spacing: 10) {
                Text(shown, format: .number)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText(value: Double(shown)))
                    .accessibilityLabel(overview.total == 1 ? String(localized: "1 memory") : String(localized: "\(overview.total) memories"))
                if growth.contains(where: { $0 > 0 }) {
                    Chart {
                        ForEach(Array(growth.enumerated()), id: \.offset) { day, size in
                            AreaMark(x: .value("Day", day), y: .value("Memories", size))
                                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0)],
                                                                startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Day", day), y: .value("Memories", size))
                                .foregroundStyle(Color.accentColor)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: Double(growth.min() ?? 0)...Double(max(growth.max() ?? 1, (growth.min() ?? 0) + 1)))
                    .frame(height: 34)
                    .accessibilityLabel(String(localized: "Growth over 12 weeks: from \(growth.first ?? 0) to \(growth.last ?? 0)"))
                }
            }
        }
        .onAppear { count(to: overview.total) }
        .onChange(of: overview.total) { _, total in count(to: total) }
    }

    private func count(to total: Int) {
        if reduceMotion {
            shown = total
        } else {
            withAnimation(.smooth(duration: 0.8)) { shown = total }
        }
    }
}

// MARK: Sensitivity

/// Two bars: the vault's mix, and what was shared in the range.
private struct SensitivityCard: View {
    let model: AppModel
    let insights: OverviewInsights

    private var vault: [(Sensitivity, Int)] { Sensitivity.allCases.map { ($0, insights.overview.count($0)) }.filter { $0.1 > 0 } }
    private var shared: [(Sensitivity, Int)] { Sensitivity.allCases.map { ($0, insights.overview.shared($0)) }.filter { $0.1 > 0 } }

    /// Shared in the overview's range: 7 days shows the last 30's, and says so.
    private var sharedPeriod: String {
        HomeText.rangeTitle(insights.range == .days7 ? .days30 : insights.range)
    }

    var body: some View {
        let vault = self.vault, shared = self.shared
        let filter = (Self.dominant(shared) ?? Self.dominant(vault)).map { $0.0 }
        HomeCard(title: String(localized: "Sensitivity"), caption: caption(vault: vault, shared: shared),
                 help: filter.map { String(localized: "Show \($0.title) memories in the Vault") },
                 action: filter.map { level in { model.showVault(sensitivities: [level]) } }) {
            if vault.isEmpty {
                Text(String(localized: "No memories yet")).font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text(String(localized: "Vault")).font(.caption).foregroundStyle(.secondary)
                        SegmentBar(levels: vault)
                    }
                    GridRow {
                        Text(String(localized: "Shared")).font(.caption).foregroundStyle(.secondary)
                        if shared.isEmpty {
                            Text(String(localized: "Nothing in \(sharedPeriod)")).font(.caption).foregroundStyle(.tertiary)
                        } else {
                            SegmentBar(levels: shared)
                        }
                    }
                }
            }
        }
    }

    /// "Shared: 78% Low" over "Vault: 48% Low".
    private func caption(vault: [(Sensitivity, Int)], shared: [(Sensitivity, Int)]) -> String? {
        var parts: [String] = []
        if let (level, percent) = Self.dominant(shared) { parts.append(String(localized: "Shared: \(percent)% \(level.title)")) }
        if let (level, percent) = Self.dominant(vault) { parts.append(String(localized: "Vault: \(percent)% \(level.title)")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The level with the most, and its share in percent.
    static func dominant(_ levels: [(Sensitivity, Int)]) -> (Sensitivity, Int)? {
        let total = levels.reduce(0) { $0 + $1.1 }
        guard total > 0, let top = levels.max(by: { $0.1 < $1.1 }) else { return nil }
        return (top.0, Int((Double(top.1) / Double(total) * 100).rounded()))
    }
}

/// A stacked bar of sensitivity levels, in their colors, with a gap between them.
private struct SegmentBar: View {
    let levels: [(Sensitivity, Int)]

    var body: some View {
        let total = max(levels.reduce(0) { $0 + $1.1 }, 1)
        GeometryReader { geometry in
            let gaps = CGFloat(max(levels.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(levels, id: \.0) { level, count in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level.tint)
                        .frame(width: max(2, (geometry.size.width - gaps) * CGFloat(count) / CGFloat(total)))
                }
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel(levels.map { level, count in
            String(localized: "\(Int((Double(count) / Double(total) * 100).rounded()))% \(level.title)")
        }.joined(separator: ", "))
    }
}

// MARK: Rhythm

/// Twelve weeks of days, like GitHub's; "Most on Sundays · 3-week streak".
private struct RhythmCard: View {
    let model: AppModel
    let insights: OverviewInsights

    var body: some View {
        let has = insights.hasRhythm
        HomeCard(title: String(localized: "Rhythm"), caption: caption(has),
                 help: String(localized: "Show what came in, in Activity"),
                 action: { model.showActivity(nil, kind: .suggestions) }) {
            RhythmGrid(insights: insights).opacity(has ? 1 : 0.5)
        }
    }

    private func caption(_ has: Bool) -> String {
        guard has else { return String(localized: "Too few memories for a rhythm yet") }
        var parts: [String] = []
        if let weekday = insights.busiestWeekday { parts.append(HomeText.mostOn(weekday)) }
        let streak = insights.streakWeeks
        if streak >= 2 { parts.append(HomeText.streak(streak)) }
        return parts.isEmpty ? String(localized: "12 weeks") : parts.joined(separator: "\n")
    }
}

private struct RhythmGrid: View {
    let insights: OverviewInsights

    var body: some View {
        let grid = insights.grid
        let top = max(grid.joined().compactMap { $0 }.max() ?? 0, 1)
        HStack(alignment: .top, spacing: 2) {
            ForEach(grid.indices, id: \.self) { column in
                VStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { row in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(fill(grid[column][row], top: top))
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private func fill(_ count: Int?, top: Int) -> Color {
        guard let count else { return .clear }
        guard count > 0 else { return Color.secondary.opacity(0.14) }
        let step = Double(count) / Double(top)
        return Color.accentColor.opacity(step > 0.75 ? 1 : step > 0.5 ? 0.75 : step > 0.25 ? 0.5 : 0.3)
    }

    private var label: String {
        let total = insights.overview.rhythm.counts.reduce(0, +)
        let days = insights.overview.rhythm.counts.filter { $0 > 0 }.count
        return String(localized: "12 weeks: \(total) new memories on \(days) days")
    }
}

// MARK: Who reads your vault

/// The top three agents by memories shared in the range, each opening its Activity tab.
private struct ReadersCard: View {
    let model: AppModel
    let insights: OverviewInsights

    var body: some View {
        let readers = Array(insights.readers.prefix(3))
        HomeCard(title: String(localized: "Who reads your vault")) {
            if readers.isEmpty {
                if model.agents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "No agent has read your vault yet.")).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(String(localized: "Add Agent…")) { model.wantsAddAgent = true }.buttonStyle(.link)
                    }
                } else {
                    Text(String(localized: "Nothing shared in the \(HomeText.lastRange(insights.range).lowercased())"))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(readers, id: \.agent.id) { reader in
                        Button { open(reader.agent.id) } label: {
                            HStack(spacing: 6) {
                                AgentIcon(kind: reader.agent.kind, size: 16)
                                Text(name(reader.agent)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(reader.shared, format: .number).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .help(String(localized: "Show \(name(reader.agent))'s Activity"))
                        .accessibilityLabel(reader.shared == 1 ? String(localized: "\(name(reader.agent)), 1 memory shared")
                                                               : String(localized: "\(name(reader.agent)), \(reader.shared) memories shared"))
                    }
                }
            }
        }
    }

    private func name(_ agent: VaultOverview.AgentCount) -> String {
        agent.name.isEmpty ? (UUID(uuidString: agent.id).map(model.agentName) ?? String(localized: "Removed agent")) : agent.name
    }

    /// The agent's Activity tab, or Activity narrowed to it once it's removed.
    private func open(_ id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        if model.agents.contains(where: { $0.id == uuid }) {
            model.agentTab = .activity
            model.showAgent(uuid)
        } else {
            model.showActivity(.agent(uuid))
        }
    }
}
