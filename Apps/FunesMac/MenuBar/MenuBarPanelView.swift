import AppKit
import BridgeUI
import FunesCore
import FunesProtocol
import SwiftUI

/// The menu bar panel (04-ux-mac.md ▸ Menu bar, ADR-0029), top to bottom: Waiting for you (only
/// while something waits), the Agents and Remote Access tiles, the field, then the last 24 hours
/// (or the results and the answer), and the footer. The cards, the tiles and the footer keep their
/// size; the area under the field takes what's left of the screen and scrolls.
struct MenuBarPanelView: View {
    let model: MenuBarPanelModel
    let heightChanged: (CGFloat) -> Void
    let moreMenu: () -> Void

    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @FocusState private var focus: PanelFocus?

    private var app: AppModel { model.app }
    private var field: PanelField<PanelSearchRow, PanelSearchAnswer> { model.field }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                WaitingSection(model: model)
                TilesSection(model: model)
                FieldSection(model: model, focus: $focus)
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { headerHeight = $0 }

            ScrollView {
                Group {
                    if field.showsResults {
                        ResultsSection(model: model, focus: $focus)
                    } else {
                        RecentPulseSection(model: model, focus: $focus)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: max(90, model.maxHeight - headerHeight - footerHeight))

            PanelFooter(model: model, moreMenu: moreMenu)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { footerHeight = $0 }
        }
        .frame(width: MenuBarPanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { heightChanged($0) }
        .onChange(of: model.focusRequest, initial: true) { _, _ in focus = .field }
        .onChange(of: model.waiting.cards.map(\.route)) { old, new in
            // Arrivals never move focus; VoiceOver hears the new card.
            for card in model.waiting.cards where new.contains(card.route) && !old.contains(card.route) {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: card.title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
        .onChange(of: field.showsResults) { _, showing in if !showing, focus == nil { focus = .field } }
    }
}

enum PanelFocus: Hashable {
    case field
    case chart
}

// MARK: Waiting for you

private struct WaitingSection: View {
    let model: MenuBarPanelModel

    var body: some View {
        let waiting = model.waiting
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(waiting.shown.enumerated()), id: \.element.id) { index, card in
                    WaitingCard(card: card, first: index == 0, now: model.now,
                                shortcut: waiting.reviewTarget == card.route ? model.app.preferences.reviewShortcut?.display : nil,
                                review: { model.review(card.route) })
                }
                if waiting.hiddenCount > 0 {
                    HStack(spacing: 6) {
                        Text(String(localized: "\(waiting.hiddenCount) more waiting")).foregroundStyle(.secondary)
                        Spacer()
                        if waiting.hidesPending {
                            Button(String(localized: "Show All Pending Requests")) { model.showPendingRequests() }
                                .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }
}

/// One item to answer: its panel's title, its time, and **Review**, the only button. Review
/// opens the item's own panel; nothing is answered here.
private struct WaitingCard: View {
    let card: WaitingItems.Card
    let first: Bool
    let now: Date
    let shortcut: String?
    let review: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let time = WaitingItems.timeText(card.time, now: now)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).fontWeight(.medium).lineLimit(2).truncationMode(.tail)
                let line = [time, shortcut].compactMap { $0 }.joined(separator: " · ")
                if !line.isEmpty {
                    Text(line).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([card.title, WaitingItems.spokenTime(card.time, now: now)].compactMap { $0 }.joined(separator: ", "))
            Spacer(minLength: 4)
            if first {
                Button(String(localized: "Review"), action: review).buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityLabel(String(localized: "Review: \(card.title)"))
            } else {
                Button(String(localized: "Review"), action: review).controlSize(.small)
                    .accessibilityLabel(String(localized: "Review: \(card.title)"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(first ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(first ? Color.accentColor.opacity(contrast == .increased ? 0.9 : 0.35) : Color.primary.opacity(contrast == .increased ? 0.5 : 0),
                          lineWidth: 1))
    }
}

// MARK: The switches

private struct TilesSection: View {
    let model: MenuBarPanelModel

    var body: some View {
        let agents = model.agentsTile
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                AgentsTileView(model: model, tile: agents)
                RemoteTileView(model: model, tile: model.remoteTile)
            }
            .fixedSize(horizontal: false, vertical: true)
            if case .paused = agents {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(localized: "Agents' requests are refused. Capture and the Inbox keep working."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(String(localized: "Resume")) { model.app.resume() }.controlSize(.small)
                }
                .font(.caption)
            }
        }
    }
}

/// A tile: its icon, name and status open its section; a switch at its top right, or a button
/// under the status, acts. The tile comes first for Tab and VoiceOver, then its control.
private struct Tile<Accessory: View, Action: View>: View {
    let symbol: String
    let name: String
    let status: String
    var tint: Color?
    var spinner = false
    let open: () -> Void
    let openHint: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var action: Action
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint ?? Color.accentColor)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill((tint ?? Color.accentColor).opacity(0.16)))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).fontWeight(.semibold).lineLimit(1)
                            HStack(spacing: 4) {
                                if spinner { ProgressView().controlSize(.mini) }
                                Text(status).font(.caption).foregroundStyle(tint == nil ? .secondary : .primary)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name): \(status)")
                .accessibilityHint(openHint)
                accessory
            }
            action
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill((tint ?? Color.primary).opacity(tint == nil ? 0.05 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0), lineWidth: 1))
    }
}

private struct AgentsTileView: View {
    let model: MenuBarPanelModel
    let tile: AgentsTile

    var body: some View {
        Tile(symbol: "person.2.fill", name: String(localized: "Agents"), status: tile.status(now: model.now),
             tint: tint, spinner: tile == .starting, open: { model.show(.agents) },
             openHint: String(localized: "Opens Agents")) {
            switch tile {
            case .on, .paused:
                Toggle(String(localized: "Agents"), isOn: Binding(get: { tile.isOn }, set: { on in
                    if on {
                        model.app.resume()
                    } else {
                        // The lengths' menu; Esc or a click elsewhere leaves agents on.
                        DispatchQueue.main.async { model.showPauseMenu() }
                    }
                }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.pauseMenuAnchor = $0 }
                .accessibilityHint(tile.isOn ? String(localized: "Pauses all agents") : String(localized: "Resumes all agents"))
            case .starting:
                Toggle(String(localized: "Agents"), isOn: .constant(false)).toggleStyle(.switch).labelsHidden()
                    .controlSize(.mini).disabled(true)
            default:
                EmptyView()
            }
        } action: {
            switch tile {
            case .noAgents:
                Button(String(localized: "Add Agent…")) { model.addAgent() }.controlSize(.small)
            case .cantConnect:
                Button(String(localized: "Fix…")) { model.openSettings(SettingsDestination(.agentServer)) }.controlSize(.small)
            case .offInSettings:
                Button(String(localized: "Turn On…")) { model.openSettings(SettingsDestination(.agentServer)) }.controlSize(.small)
            default:
                EmptyView()
            }
        }
    }

    private var tint: Color? {
        switch tile {
        case .paused: .orange
        case .cantConnect: Palette.warning
        default: nil
        }
    }
}

private struct RemoteTileView: View {
    let model: MenuBarPanelModel
    let tile: RemoteTile

    var body: some View {
        Tile(symbol: "globe", name: String(localized: "Remote Access"), status: tile.status,
             tint: tile.isWarning ? Palette.warning : nil, open: { model.show(.remoteAccess) },
             openHint: String(localized: "Opens Remote Access")) {
            if tile.hasSwitch {
                // While it's on the switch is always here, so it can always be turned off.
                Toggle(String(localized: "Remote Access"), isOn: Binding(get: { tile.isOn }, set: { on in
                    if on {
                        // Asks first (FR-AI-04); Cancel leaves it off.
                        DispatchQueue.main.async { model.confirmRemoteOn() }
                    } else {
                        // At once: the public address stops answering.
                        model.app.remoteAccess.apply(false)
                    }
                }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                .accessibilityHint(tile.isOn ? String(localized: "Turns Remote Access off now")
                                             : String(localized: "Asks before turning Remote Access on"))
            }
        } action: {
            if !tile.hasSwitch {
                Button(String(localized: "Set Up…")) { model.show(.remoteAccess) }.controlSize(.small)
            } else if tile == .notListening {
                Button(String(localized: "Fix…")) { fix() }.controlSize(.small)
            }
        }
    }

    /// Not listening: the agent server is off or failed (Settings ▸ Agent Server), or the listener is (Remote Access).
    private func fix() {
        if case .on = model.agentsTile { model.show(.remoteAccess) } else if case .paused = model.agentsTile {
            model.show(.remoteAccess)
        } else {
            model.openSettings(SettingsDestination(.agentServer))
        }
    }
}

// MARK: The field

private struct FieldSection: View {
    let model: MenuBarPanelModel
    var focus: FocusState<PanelFocus?>.Binding

    private var field: PanelField<PanelSearchRow, PanelSearchAnswer> { model.field }

    var body: some View {
        @Bindable var field = model.field
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if field.text.isEmpty {
                        Text(String(localized: "Remember something, or search…"))
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    TextField("", text: $field.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused(focus, equals: .field)
                        .accessibilityLabel(String(localized: "Remember something, or search"))
                        .accessibilityHint(String(localized: "Return remembers it in your Inbox. Command-Return searches your vault."))
                        .onKeyPress(keys: [.return]) { press in
                            if press.modifiers.contains(.shift) {
                                // A new line at the caret, replacing any selection.
                                NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                            } else if press.modifiers.contains(.command) {
                                field.commandReturn()
                            } else if case .open(let row) = field.returnKey() {
                                model.open(row)
                            }
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            if field.escape() == .close { model.closePanel() }
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            guard field.page != nil else { return .ignored }
                            field.moveSelection(by: -1)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            guard field.page != nil else { return .ignored }
                            field.moveSelection(by: 1)
                            return .handled
                        }
                }
                .font(.body)
                if #available(macOS 26, *) { DictationButton(box: model).controlSize(.small) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focus.wrappedValue == .field ? Color.accentColor.opacity(0.6) : Palette.separator.opacity(0.6),
                              lineWidth: focus.wrappedValue == .field ? 1.5 : 0.5))
            if let error = field.error {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            hint
        }
        .onChange(of: field.error) { _, error in
            if let error {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
        .onChange(of: field.hint) { _, hint in
            if hint == .saved {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: String(localized: "Saved to Inbox"),
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
    }

    @ViewBuilder
    private var hint: some View {
        switch field.hint {
        case .saving:
            Text(String(localized: "Saving…")).font(.caption).foregroundStyle(.secondary)
        case .saved:
            Label(String(localized: "Saved to Inbox"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
        case .notSaved:
            HStack(spacing: 6) {
                Text(String(localized: "Your last note wasn't saved")).font(.caption)
                Button(String(localized: "Restore")) { field.restore() }.buttonStyle(.link).font(.caption)
            }
        case .keys:
            if field.showsResults {
                Text(field.page.map { !$0.rows.isEmpty } == true && model.app.searchAnswers.isOn
                     ? String(localized: "⏎ Open · ⌘⏎ Ask · Esc Back") : String(localized: "⏎ Open · Esc Back"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                CaptureFooter(cloudProvider: model.chip.cloudProvider, keys: String(localized: "⏎ Remember · ⌘⏎ Search"),
                              centered: true, compact: true)
            }
        }
    }
}

// MARK: Results

private struct ResultsSection: View {
    let model: MenuBarPanelModel
    var focus: FocusState<PanelFocus?>.Binding
    /// The result row with keyboard focus (Tab from the field): it is the selection, and ↑ ↓ move it.
    @FocusState private var rowFocus: Int?

    private var field: PanelField<PanelSearchRow, PanelSearchAnswer> { model.field }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let page = field.page {
                if !page.rows.isEmpty, model.app.searchAnswers.isOn {
                    AnswerCard(vault: model)
                }
                if page.rows.isEmpty {
                    Text(String(localized: "Nothing matches.")).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(field.shownRows.enumerated()), id: \.element.id) { index, row in
                            ResultRow(row: row, selected: index == field.selection, number: model.answerSources.firstIndex(of: row.id).map { $0 + 1 }) {
                                model.open(row)
                            }
                            .focused($rowFocus, equals: index)
                            .onHover { if $0 { field.select(row) } }
                        }
                    }
                    Button(String(localized: "Show All \(page.total) in Vault")) { model.showAllInVault() }
                        .buttonStyle(.link).font(.callout)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Searching…")).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .onChange(of: rowFocus) { _, index in
            if let index, field.shownRows.indices.contains(index) { field.select(field.shownRows[index]) }
        }
        .onKeyPress(.upArrow) {
            guard let index = rowFocus else { return .ignored }
            rowFocus = max(0, index - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard let index = rowFocus else { return .ignored }
            rowFocus = min(field.shownRows.count - 1, index + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            // A result row: back to the field.
            rowFocus = nil
            focus.wrappedValue = .field
            return .handled
        }
    }
}

/// A result: the title, the first category and the sensitivity badge; never the body.
private struct ResultRow: View {
    let row: PanelSearchRow
    let selected: Bool
    let number: Int?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(row.title).lineLimit(1).truncationMode(.tail)
                        if let number { SourceChip(number: number) }
                    }
                    if let category = row.category {
                        Text(category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                SensitivityBadge(sensitivity: row.sensitivity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: Footer

private struct PanelFooter: View {
    let model: MenuBarPanelModel
    let moreMenu: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Button { model.show(.inbox) } label: {
                    HStack(spacing: 5) {
                        Text(String(localized: "Inbox"))
                        if model.app.inboxCount > 0 {
                            Text("\(model.app.inboxCount)")
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                }
                .accessibilityLabel(model.app.inboxCount > 0 ? String(localized: "Inbox, \(model.app.inboxCount) waiting")
                                                             : String(localized: "Inbox"))
                Button(String(localized: "Open Funes Vault")) { model.show(.home) }
                Spacer()
                Button { model.openSettings(nil) } label: { Image(systemName: "gearshape") }
                    .help(String(localized: "Settings"))
                    .accessibilityLabel(String(localized: "Settings"))
                Button(action: moreMenu) { Image(systemName: "ellipsis") }
                    .help(String(localized: "More"))
                    .accessibilityLabel(String(localized: "More"))
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.moreMenuAnchor = $0 }
            }
            .buttonStyle(.accessoryBar)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}
