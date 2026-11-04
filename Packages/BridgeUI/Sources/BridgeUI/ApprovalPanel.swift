import AppKit
import SwiftUI

// Adapted from EK Bridge's ApprovalPanel (Upstream/ApprovalPanel.swift): the same
// non-activating floating panel at the top right, the same arming delay and the same
// VoiceOver announcement, drawing a generic `PanelItem` (checkbox rows with badges,
// facts, a countdown) instead of EK Bridge's change summaries.

/// The floating panel. Non-activating, so typing in the agent's terminal can never answer
/// it by accident; Return and Escape work only after the user clicks into it.
@MainActor
public final class ApprovalPanelController {
    public static let width: CGFloat = 420

    private let queue: ApprovalQueue
    private var panel: NSPanel?
    private var host: NSHostingController<ApprovalPanelView>?
    private var announced = Set<UUID>()

    public init(queue: ApprovalQueue) {
        self.queue = queue
    }

    /// Shows, updates or hides the panel to match the queue.
    public func update() {
        guard let current = queue.current else {
            panel?.orderOut(nil)
            announced.removeAll()
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        fit(panel)
        // Once more after SwiftUI has drawn the change, which the first measurement can miss.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, self.queue.current != nil else { return }
                self.fit(panel)
            }
        }
        if !panel.isVisible {
            position(panel)
            panel.orderFrontRegardless()
        }
        // One announcement for everything new, so a second one never cuts the first off.
        let fresh = queue.shown.filter { !announced.contains($0.id) }
        if !fresh.isEmpty {
            announced.formUnion(fresh.map(\.id))
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: Self.announcement(fresh, current: current, queue: queue,
                                                                             reviewHint: reviewHint),
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    /// Appended to announcements: how to reach the panel from the keyboard ("Option-Command-R to
    /// review"). Set by the app, which owns the shortcut.
    public var reviewHint: String?

    /// "Cursor asks for more access in Funes. 38 seconds to answer. Option-Command-R to review.", or
    /// "3 requests waiting in Funes. …" when several arrive together.
    static func announcement(_ fresh: [PanelItem], current: PanelItem, queue: ApprovalQueue, reviewHint: String?) -> String {
        var parts = [fresh.count == 1 ? fresh[0].announcement
                                      : String(localized: "\(queue.items.count) requests waiting in Funes")]
        if let seconds = queue.remaining(current) {
            parts.append(seconds < 60 ? String(localized: "\(seconds) seconds to answer")
                                      : String(localized: "\(seconds / 60) minutes to answer"))
        }
        if let reviewHint { parts.append(reviewHint) }
        return parts.joined(separator: ". ") + "."
    }

    /// Brings the panel forward and makes it key, so Return and Escape answer it (Open in Funes,
    /// the Review Request shortcut, the menu's Review item).
    public func bringForward() {
        guard let panel, queue.current != nil else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    public var window: NSWindow? { panel }

    /// The panel's height: everything at its natural size, but never taller than the screen's
    /// visible area. Beyond that the rows scroll and the title and buttons stay put.
    private func fit(_ panel: NSPanel) {
        guard host != nil else { return }
        let available = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)
            .map { $0.visibleFrame.height - 2 * Self.margin } ?? 800
        let height = Self.height(for: queue, available: available)
        let size = NSSize(width: Self.width, height: height)
        if height > 1, size != panel.contentLayoutRect.size {
            let top = panel.frame.maxY
            panel.setContentSize(size)
            if panel.isVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
        }
    }

    static let margin: CGFloat = 12

    /// The natural height of the current item, measured without scrolling.
    public static func idealHeight(for queue: ApprovalQueue) -> CGFloat {
        let measure = NSHostingController(rootView: ApprovalPanelView(queue: queue, scrolls: false))
        return measure.sizeThatFits(in: NSSize(width: width, height: 100_000)).height
    }

    /// The height the panel takes: its natural height, capped at `available`.
    public static func height(for queue: ApprovalQueue, available: CGFloat) -> CGFloat {
        min(idealHeight(for: queue), available)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
                            styleMask: [.nonactivatingPanel, .titled, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = String(localized: "Approval")
        let host = NSHostingController(rootView: ApprovalPanelView(queue: queue, scrolls: true))
        host.sizingOptions = []
        panel.contentViewController = host
        self.host = host
        return panel
    }

    /// Top right of the screen with the menu bar.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first else { return }
        panel.layoutIfNeeded()
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - Self.margin, y: frame.maxY - size.height - Self.margin))
    }
}

public struct ApprovalPanelView: View {
    let queue: ApprovalQueue
    /// True in the panel: the middle scrolls inside whatever height the panel has. False only to
    /// measure the natural height.
    let scrolls: Bool
    /// The content the buttons may act on: the item and its content generation. When either
    /// changes (one expired, the user picked another, or a refresh changed what would be shared),
    /// they wait a moment so a click meant for the old content can't approve the new one.
    @State private var armed: ArmKey?
    public static let armingDelay: TimeInterval = 0.6

    struct ArmKey: Equatable {
        let id: UUID
        let generation: Int
    }

    public init(queue: ApprovalQueue, scrolls: Bool = true) {
        self.queue = queue
        self.scrolls = scrolls
    }

    public var body: some View {
        content.ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        if let item = queue.current {
            let key = ArmKey(id: item.id, generation: queue.generation(of: item.id))
            VStack(alignment: .leading, spacing: 0) {
                if queue.shown.count > 1 {
                    chips(current: item)
                        .padding([.horizontal, .top], 12)
                }
                header(item)
                    .padding([.horizontal], 16)
                    .padding(.top, queue.shown.count > 1 ? 10 : 16)
                    .padding(.bottom, 12)
                if scrolls {
                    ScrollView(.vertical) { middle(item) }
                        .scrollBounceBehavior(.basedOnSize)
                } else {
                    middle(item)
                }
                Divider()
                footer(item, armed: armed == key)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .frame(width: ApprovalPanelController.width)
            .frame(maxHeight: scrolls ? .infinity : nil, alignment: .top)
            .fixedSize(horizontal: false, vertical: !scrolls)
            .onChange(of: key, initial: true) { _, key in
                armed = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.armingDelay) {
                    MainActor.assumeIsolated {
                        if let current = queue.current,
                           ArmKey(id: current.id, generation: queue.generation(of: current.id)) == key {
                            armed = key
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.title)
        } else {
            Color.clear.frame(width: ApprovalPanelController.width, height: 1)
        }
    }

    /// One chip per waiting item, most urgent first, each with its own countdown: "Cursor · access
    /// · 0:13". The shown one is filled; clicking another shows it.
    private func chips(current: PanelItem) -> some View {
        HStack(spacing: 6) {
            ForEach(queue.shown) { item in
                let isCurrent = item.id == current.id
                Button { queue.select(item.id) } label: {
                    HStack(spacing: 4) {
                        Text(item.shortLabel).lineLimit(1)
                        if let seconds = queue.remaining(item) {
                            Text(ApprovalQueue.countdown(seconds)).monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    .background(Capsule().fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(queue.remaining(item).map { "\(item.shortLabel), \(ApprovalQueue.spokenCountdown($0))" }
                                    ?? item.shortLabel)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
            if queue.hiddenCount > 0 {
                Text(String(localized: "+\(queue.hiddenCount) more")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Everything between the title and the buttons; it scrolls when the panel is capped. A Save
    /// panel shows the memory first; the others show where the text goes and what the agent said
    /// before the memories.
    private func middle(_ item: PanelItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let subtitle = item.subtitle {
                Text(subtitle).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let destination = item.destination { destinationBox(destination) }
            if !item.agentSays.isEmpty { agentSays(item) }
            if item.kind == .save {
                rows(item)
                facts(item.facts, in: item)
            } else {
                facts(item.facts, in: item)
                rows(item)
            }
            if let note = item.note {
                Text(note).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let aside = item.aside { asideLine(aside, item) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// "Claude Code also has your name, as set in [its Access]." The link opens it elsewhere.
    private func asideLine(_ aside: PanelItem.Aside, _ item: PanelItem) -> some View {
        var text = AttributedString(aside.text)
        var link = AttributedString(aside.link)
        link.link = URL(string: "bridgeui-aside:link")
        text += link
        text += AttributedString(aside.after)
        return Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { _ in
                queue.asideLinkClicked(item)
                return .handled
            })
    }

    private func header(_ item: PanelItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text(item.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// "Goes to": Funes's own words about where the text ends up.
    private func destinationBox(_ destination: PanelItem.Destination) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(String(localized: "Goes to")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if destination.isCloud {
                    Text(String(localized: "Cloud"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .accessibilityLabel(String(localized: "Leaves this Mac"))
                }
            }
            Text(destination.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }

    /// What the agent said, in a quoted block of its own: not checked by Funes, never a reason to share.
    private func agentSays(_ item: PanelItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "The agent says · not checked by Funes"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            facts(item.agentSays, in: item)
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.35)).frame(width: 3)
        }
        .accessibilityElement(children: .contain)
    }

    private func rows(_ item: PanelItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(item.rows.enumerated()), id: \.element.id) { index, row in
                if row.weak, index == 0 || !item.rows[index - 1].weak {
                    Text(String(localized: "Also matched, less closely"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, index == 0 ? 0 : 4)
                        .accessibilityAddTraits(.isHeader)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if row.selectable {
                        Toggle(isOn: Binding(get: { row.selected },
                                             set: { _ in queue.toggle(row: row.id, in: item.id) })) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel(row.title)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.title).fontWeight(.medium)
                            if let badge = row.badge {
                                Text(badge)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(row.badgeIsWarning ? Color.orange.opacity(0.25)
                                                                                  : Color.secondary.opacity(0.15)))
                                    .accessibilityLabel(String(localized: "Sensitivity: \(badge)"))
                            }
                        }
                        if let detail = queue.displayedDetail(row, in: item.id) {
                            // The exact text that would be sent: a preview cut by PanelText, never
                            // clipped silently, and all of it after Show all.
                            Text(detail).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if row.isClipped {
                            let open = queue.isExpanded(row: row.id, in: item.id)
                            Button(open ? String(localized: "Show Less") : String(localized: "Show All")) {
                                queue.toggleExpanded(row: row.id, in: item.id)
                            }
                            .buttonStyle(.link)
                            .font(.callout)
                            .accessibilityLabel(open ? String(localized: "Show less of \(row.title)")
                                                     : String(localized: "Show all of \(row.title)"))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func facts(_ facts: [PanelItem.Fact], in item: PanelItem) -> some View {
        if !facts.isEmpty {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.label).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(queue.displayedValue(fact, in: item.id))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if fact.isClipped {
                                let open = queue.isExpanded(row: "fact:" + fact.label, in: item.id)
                                Button(open ? String(localized: "Show Less") : String(localized: "Show All")) {
                                    queue.toggleExpanded(row: "fact:" + fact.label, in: item.id)
                                }
                                .buttonStyle(.link)
                                .accessibilityLabel(open ? String(localized: "Show less of \(fact.label)")
                                                         : String(localized: "Show all of \(fact.label)"))
                            }
                        }
                    }
                }
            }
            .font(.callout)
        }
    }

    /// The buttons. The default (Return, once the panel is key) is drawn prominent and is never a
    /// choice with lasting effect: Share N, Save, or Allow Once. Always Allow is a link on its own
    /// line, so it can't be truncated and is never hit by habit (UX review F1).
    private func footer(_ item: PanelItem, armed: Bool) -> some View {
        let count = item.selectedIDs.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let seconds = queue.remaining(item) {
                    Text(ApprovalQueue.countdown(seconds)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel(ApprovalQueue.spokenCountdown(seconds))
                }
                if let moreTime = item.moreTime {
                    Button(moreTime) { queue.answer(item.id, .deferred) }
                        .buttonStyle(.link)
                        .disabled(!armed)
                        .help(String(localized: "Moves it to Pending requests, where it waits up to 15 minutes"))
                }
                if let edit = item.edit {
                    Button(edit) { queue.answer(item.id, .edit) }
                        .buttonStyle(.link)
                        .disabled(!armed)
                }
                Spacer(minLength: 4)
                switch item.kind {
                case .access:
                    Button(item.secondary) { queue.answer(item.id, .secondary) }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!armed)
                    if let tertiary = item.tertiary {
                        Button(tertiary) { queue.answer(item.id, .tertiary) }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            // The panel is rarely key; draw the default as primary anyway.
                            .environment(\.controlActiveState, .key)
                            .disabled(!armed)
                    }
                case .share, .save:
                    if let tertiary = item.tertiary {
                        Button(tertiary) { queue.answer(item.id, .tertiary) }
                            .disabled(!armed)
                    }
                    Button(item.secondary) { queue.answer(item.id, .secondary) }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!armed)
                    Button(item.kind == .share ? "\(item.primary) \(count)" : item.primary) {
                        queue.answer(item.id, .primary(selected: item.selectedIDs))
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                            // The panel is rarely key; draw the default as primary anyway.
                            .environment(\.controlActiveState, .key)
                    .disabled(!armed || (item.kind == .share && count == 0))
                }
            }
            if item.kind == .access {
                Button(item.primary) { queue.answer(item.id, .primary(selected: [])) }
                    .buttonStyle(.link)
                    .disabled(!armed)
            }
            // A burst of suggestions: put them all off at once; they wait in the Inbox.
            if item.kind == .save, queue.saveCount > 1 {
                Button(String(localized: "Later for all \(queue.saveCount) suggestions")) { queue.laterForAllSaves() }
                    .buttonStyle(.link)
                    .disabled(!armed)
                    .help(String(localized: "Closes every Save panel. The suggestions stay in the Inbox."))
            }
        }
    }
}
