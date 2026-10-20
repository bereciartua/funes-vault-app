import FunesCore
import FunesProtocol
import SwiftUI

// Activity (04-ux-mac.md, FR-L-02), after EK Bridge's ActivityView (BridgeUI/Upstream/ActivityView.swift):
// a filterable table under day headers with a detail pane below that explains each row and links to
// the fix. Rows hold ids, codes and counts; titles are looked up live.

struct ActivityScreen: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    private var activity: ActivityModel { model.activity }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                PaneHeader(title: String(localized: "Activity")) { EmptyView() }
                filters
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            if !model.pending.isEmpty {
                PendingRequestsCard(model: model)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            if let focus = model.activityFocus {
                HStack {
                    Text(focusText(focus)).font(.callout)
                    Button(String(localized: "Show everything")) { model.activityFocus = nil }.buttonStyle(.link)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            ActivityList(model: model, scope: scope)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .background(Palette.pane)
        .onChange(of: model.searchFocusRequest) { _, _ in if model.section == .activity { searchFocused = true } }
    }

    private var scope: ActivityScope {
        switch model.activityFocus {
        case .memory(let id): .memory(id)
        case .agent(let id): .agent(id)
        case .request(let id): .request(id)
        case nil: .all
        }
    }

    private func focusText(_ focus: ActivityFocus) -> String {
        switch focus {
        case .memory(let id): String(localized: "Showing “\(activity.title(id))” only")
        case .agent(let id): String(localized: "Showing \(model.agentName(id)) only")
        case .request: String(localized: "Showing one request")
        }
    }

    /// One row when the pane is wide enough; otherwise the Show segments on their own line and
    /// the agent, period and search below, so the page never gets wider than the window.
    private var filters: some View {
        FilterRow {
            kindPicker
            HStack(spacing: 10) {
                pickers
                Spacer(minLength: 8)
                search
            }
        }
        .controlSize(.small)
    }

    private var kindPicker: some View {
        Picker(String(localized: "Show"), selection: Binding(get: { activity.kind }, set: { activity.kind = $0 })) {
            ForEach(ActivityEntry.Kind.allCases) { kind in
                if kind == .problems {
                    let count = activity.entries.filter(\.isProblem).count
                    Text(count > 0 ? String(localized: "Problems \(count)") : kind.title).tag(kind)
                } else {
                    Text(kind.title).tag(kind)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(String(localized: "Show"))
    }

    @ViewBuilder
    private var pickers: some View {
        Picker(String(localized: "Agent"), selection: Binding(get: { activity.agentFilter }, set: { activity.agentFilter = $0 })) {
            Text(String(localized: "All agents")).tag(UUID?.none)
            ForEach(model.allAgents) { agent in Text(model.agentName(agent.id)).tag(Optional(agent.id)) }
        }
        .fixedSize()
        Picker(String(localized: "Period"), selection: Binding(get: { activity.period }, set: { activity.period = $0 })) {
            ForEach(ActivityModel.Period.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(String(localized: "Period"))
    }

    private var search: some View {
        SearchField(text: Binding(get: { activity.search }, set: { activity.search = $0 }),
                    prompt: String(localized: "Search activity"), focused: $searchFocused)
            .frame(minWidth: 140, idealWidth: 220, maxWidth: 220)
    }
}

/// Two views side by side when they fit at their ideal widths, else the second below the first.
/// The second gets the rest of the width, so its spacer and search field can stretch.
private struct FilterRow: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let first = subviews[0].sizeThatFits(.unspecified)
        let ideal = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? first.width + spacing + ideal.width
        if fitsOnOneLine(width, first: first, second: ideal) {
            let second = subviews[1].sizeThatFits(ProposedViewSize(width: width - first.width - spacing, height: nil))
            return CGSize(width: width, height: max(first.height, second.height))
        }
        let second = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: first.height + lineSpacing + second.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let first = subviews[0].sizeThatFits(.unspecified)
        let ideal = subviews[1].sizeThatFits(.unspecified)
        if fitsOnOneLine(bounds.width, first: first, second: ideal) {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: bounds.minX + first.width + spacing, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width - first.width - spacing, height: nil))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + first.height + lineSpacing),
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    private func fitsOnOneLine(_ width: CGFloat, first: CGSize, second: CGSize) -> Bool {
        first.width + spacing + second.width <= width
    }
}

/// The Activity table and its detail pane, for the Activity screen and an agent's Activity tab.
struct ActivityList: View {
    @Bindable var model: AppModel
    let scope: ActivityScope

    private var activity: ActivityModel { model.activity }

    var body: some View {
        let rows = activity.rows(scope, now: model.now, labels: labels)
        let selected = rows.first { $0.id == activity.selection }
        GeometryReader { proxy in
            list(rows: rows, selected: selected, height: proxy.size.height)
        }
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5))
        .task(id: model.activityGeneration) { await activity.load() }
        .onChange(of: model.dataGeneration) { _, _ in Task { await activity.load() } }
    }

    /// The table, and the selected row's details below it: never more than 45% of the height, so
    /// the rows stay in view.
    private func list(rows: [ActivityEntry], selected: ActivityEntry?, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                empty
            } else {
                List(selection: Binding(get: { activity.selection }, set: { activity.selection = $0 })) {
                    ForEach(ActivityDays.group(rows, now: model.now), id: \.title) { day in
                        SwiftUI.Section {
                            ForEach(day.entries) { entry in
                                ActivityRowView(model: model, entry: entry, showsAgent: !isAgentScope).tag(entry.id)
                            }
                        } header: {
                            Text(day.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(String(localized: "Activity"))
            }
            if let selected {
                Divider()
                ActivityInspector(model: model, entry: selected)
                    .frame(height: min(230, height * 0.45))
            }
        }
    }

    private var isAgentScope: Bool { if case .agent = scope { true } else { false } }

    private var header: some View {
        HStack(spacing: 12) {
            Text(String(localized: "Time")).frame(width: 70, alignment: .leading)
            if !isAgentScope { Text(String(localized: "Agent or device")).frame(width: 130, alignment: .leading) }
            Text(String(localized: "Event")).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "Detail")).frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "Result")).frame(width: 170, alignment: .leading)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var empty: some View {
        if activity.entries.isEmpty {
            ContentUnavailableView(String(localized: "No activity yet"), systemImage: "list.bullet",
                                   description: Text(String(localized: "Requests from your agents appear here, with what was shared and why.")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !activity.search.isEmpty {
            ContentUnavailableView.search(text: activity.search).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(activity.kind == .problems ? String(localized: "No problems") : String(localized: "Nothing here"),
                                   systemImage: activity.kind == .problems ? "checkmark.circle" : "list.bullet",
                                   description: Text(String(localized: "Nothing matches these filters.")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func labels(_ entry: ActivityEntry) -> String {
        ActivityText.who(entry, model: model) + " " + ActivityText.detail(entry, model: model)
    }
}

@MainActor
enum ActivityText {
    /// The agent or device: "Claude Code", "iPhone", "You", "Funes Vault".
    static func who(_ entry: ActivityEntry, model: AppModel) -> String {
        if let id = entry.agentID { return model.agentName(id) }
        if entry.deviceID != nil { return String(localized: "iPhone") }
        if entry.event.actor == "user" { return String(localized: "You") }
        if entry.event.actor.hasPrefix("import:") { return String(localized: "Import") }
        return String(localized: "Funes Vault")
    }

    /// The Detail column: memory titles, looked up live, or the agent an event is about.
    static func detail(_ entry: ActivityEntry, model: AppModel) -> String {
        let e = entry.event
        switch e.event {
        case "agent_added", "agent_removed", "agent_paused", "agent_resumed", "access_changed", "key_rotated",
             "cloud_access_on", "cloud_access_off", "remote_key_issued", "cloud_apps_changed":
            return e.ids.first.map(model.agentName) ?? ""
        case "request_memory" where e.outcome != "fulfilled":
            let withheld = e.counts.values.reduce(0, +)
            return withheld > 0 ? String(localized: "\(withheld) withheld") : ""
        case "import", "export", "funes_paused", "funes_resumed", "approval", "list_memory_categories", "open_in_funes":
            return ""
        default:
            let titles = e.ids.prefix(3).map(model.activity.title)
            let more = e.ids.count > 3 ? String(localized: " and \(e.ids.count - 3) more") : ""
            return titles.joined(separator: ", ") + more
        }
    }
}

struct ActivityRowView: View {
    let model: AppModel
    let entry: ActivityEntry
    let showsAgent: Bool

    var body: some View {
        let result = entry.result
        HStack(spacing: 12) {
            Text(entry.time.formatted(date: .omitted, time: .shortened))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
                .help(RelativeTime.full(entry.time))
            if showsAgent {
                HStack(spacing: 4) {
                    if entry.isRemote {
                        Image(systemName: "cloud").foregroundStyle(.secondary)
                            .help(String(localized: "via Remote Access"))
                            .accessibilityLabel(String(localized: "via Remote Access"))
                    }
                    Text(ActivityText.who(entry, model: model)).lineLimit(1)
                }
                .frame(width: 130, alignment: .leading)
            } else if entry.isRemote {
                Image(systemName: "cloud").foregroundStyle(.secondary)
                    .help(String(localized: "via Remote Access"))
                    .accessibilityLabel(String(localized: "via Remote Access"))
            }
            Text(entry.label).lineLimit(1).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            Text(ActivityText.detail(entry, model: model)).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
            Pill(label: result.text, tone: result.tone).frame(width: 170, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Rows under "Today", "Yesterday" and dated headers.
enum ActivityDays {
    struct Day { let title: String; let entries: [ActivityEntry] }

    static func group(_ entries: [ActivityEntry], now: Date) -> [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        var current: (Date, [ActivityEntry])?
        for entry in entries {
            let day = calendar.startOfDay(for: entry.time)
            if let open = current, open.0 == day {
                current = (day, open.1 + [entry])
            } else {
                if let open = current { days.append(Day(title: title(open.0, now: now), entries: open.1)) }
                current = (day, [entry])
            }
        }
        if let open = current { days.append(Day(title: title(open.0, now: now), entries: open.1)) }
        return days
    }

    static func title(_ day: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        return day.formatted(date: .complete, time: .omitted)
    }
}

/// A row's details: the request id, the task (only while this session saw it), withheld counts by
/// reason, the memories involved (live titles) and links to fix a refusal.
struct ActivityInspector: View {
    let model: AppModel
    let entry: ActivityEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(entry.label).font(.headline)
                    Pill(label: entry.result.text, tone: entry.result.tone)
                    Spacer()
                    Text(RelativeTime.full(entry.time)).font(.callout).foregroundStyle(.secondary)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text(String(localized: "From")).foregroundStyle(.secondary)
                        Text(entry.isRemote ? String(localized: "\(ActivityText.who(entry, model: model)) via Remote Access")
                                            : ActivityText.who(entry, model: model))
                    }
                    if entry.isRemote, let agentID = entry.agentID,
                       let note = model.remoteServer?.note(agentID: agentID, near: entry.time) {
                        // In memory only, for the last 50 remote requests (mcp-server.md §12).
                        GridRow {
                            Text(String(localized: "Tunnel")).foregroundStyle(.secondary)
                            Text(note.tunnel?.name ?? String(localized: "Unknown"))
                        }
                        GridRow {
                            Text(String(localized: "Address")).foregroundStyle(.secondary)
                            Text(String(localized: "\(note.address) (as the tunnel reported)"))
                                .font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let request = entry.event.requestID {
                        GridRow {
                            Text(String(localized: "Request")).foregroundStyle(.secondary)
                            Text(request.uuidString.lowercased()).font(.callout.monospaced()).textSelection(.enabled)
                        }
                        GridRow {
                            Text(String(localized: "Task")).foregroundStyle(.secondary)
                            if let task = model.services.approvals.sessionTask(request) {
                                Text("“\(task)” (as reported)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(String(localized: "Task text not stored")).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !withheld.isEmpty {
                        GridRow {
                            Text(String(localized: "Withheld")).foregroundStyle(.secondary)
                            Text(withheld).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                if !memoryIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(memoryIDs, id: \.self) { id in
                            if model.activity.titles[id] != nil {
                                Button(model.activity.title(id)) { model.showMemory(id) }.buttonStyle(.link)
                            } else {
                                Text(model.activity.title(id)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.callout)
                }
                fixes
            }
            .padding(14)
        }
    }

    /// Memories this row is about (not agents).
    private var memoryIDs: [UUID] {
        switch entry.event.event {
        case "request_memory", "get_memory_request", "suggest_memory", "capture", "suggestion_applied", "suggestion_rejected",
             "seed_question", "memory_created", "memory_edited":
            entry.event.ids
        default: []
        }
    }

    /// "2 above its sensitivity limit, 1 in a category it can't read".
    private var withheld: String {
        guard entry.event.event == "request_memory" else { return "" }
        return entry.event.counts.sorted { $0.key < $1.key }.compactMap { key, count in
            ReasonCode(rawValue: key).map { "\(count) · \(ActivityEntry.reasonText($0))" }
        }.joined(separator: ", ")
    }

    @ViewBuilder
    private var fixes: some View {
        let reasons = Set(entry.event.counts.keys.compactMap(ReasonCode.init(rawValue:)) + [entry.event.reason].compactMap { $0 })
        if let agentID = entry.agentID, let agent = model.agent(agentID) {
            HStack(spacing: 12) {
                if reasons.contains(.categoryNotAllowed) || reasons.contains(.deniedCategory) {
                    Button(String(localized: "Change \(agent.name)'s categories…")) { openAccess(agentID) }
                }
                if reasons.contains(.aboveSensitivityCeiling) {
                    Button(String(localized: "Raise \(agent.name)'s limit…")) { openAccess(agentID) }
                }
                if reasons.contains(.operationNotAllowed) || reasons.contains(.accessExpired) {
                    Button(String(localized: "Edit \(agent.name)'s access…")) { openAccess(agentID) }
                }
                if reasons.contains(.agentPaused), agent.paused {
                    Button(String(localized: "Resume \(agent.name)")) {
                        Task { try? await model.services.agents.resume(agentID: agentID, now: Date()) }
                    }
                }
                if reasons.contains(.funesPaused), model.pausedUntil != nil {
                    Button(String(localized: "Resume Funes Vault")) { model.resume() }
                }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private func openAccess(_ id: UUID) {
        model.agentTab = .access
        model.showAgent(id)
    }
}
