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
        for item in queue.shown where !announced.contains(item.id) {
            announced.insert(item.id)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: item.announcement,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        _ = current
    }

    /// Brings the panel forward (Open in Funes).
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
    /// changes (one expired, the user stepped, or a refresh changed what would be shared), they
    /// wait a moment so a click meant for the old content can't approve the new one.
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
                header(item)
                    .padding([.horizontal, .top], 16)
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

    /// Everything between the title and the buttons; it scrolls when the panel is capped.
    private func middle(_ item: PanelItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let subtitle = item.subtitle {
                Text(subtitle).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            facts(item)
            rows(item)
            if let note = item.note {
                Text(note).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func header(_ item: PanelItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rows(_ item: PanelItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(item.rows) { row in
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
                                    .font(.caption2.weight(.semibold))
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
                            Button(open ? String(localized: "Show less") : String(localized: "Show all")) {
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
    private func facts(_ item: PanelItem) -> some View {
        if !item.facts.isEmpty {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(item.facts.enumerated()), id: \.offset) { _, fact in
                    GridRow {
                        Text(fact.label).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(queue.displayedValue(fact, in: item.id))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if fact.isClipped {
                                let open = queue.isExpanded(row: "fact:" + fact.label, in: item.id)
                                Button(open ? String(localized: "Show less") : String(localized: "Show all")) {
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

    private func footer(_ item: PanelItem, armed: Bool) -> some View {
        let shown = queue.shown
        let index = shown.firstIndex(where: { $0.id == item.id }) ?? 0
        let count = item.selectedIDs.count
        return HStack(spacing: 8) {
            if shown.count > 1 {
                Button { queue.selection = max(0, index - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .accessibilityLabel(String(localized: "Previous request"))
                Text(String(localized: "\(index + 1) of \(shown.count)")).foregroundStyle(.secondary)
                Button { queue.selection = min(shown.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(index == shown.count - 1)
                    .accessibilityLabel(String(localized: "Next request"))
            }
            if let seconds = queue.remaining(item) {
                Text(ApprovalQueue.countdown(seconds)).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "\(seconds) seconds left"))
            }
            Spacer()
            if item.kind == .access {
                // Not Now · Allow Once · Always Allow (04-ux-mac.md).
                Button(item.secondary) { queue.answer(item.id, .secondary) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!armed)
                if let tertiary = item.tertiary {
                    Button(tertiary) { queue.answer(item.id, .tertiary) }
                        .disabled(!armed)
                }
            } else {
                if let tertiary = item.tertiary {
                    Button(tertiary) { queue.answer(item.id, .tertiary) }
                        .disabled(!armed)
                }
                Button(item.secondary) { queue.answer(item.id, .secondary) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!armed)
                if let edit = item.edit {
                    Button(edit) { queue.answer(item.id, .edit) }
                        .disabled(!armed)
                }
            }
            Button(item.kind == .share ? "\(item.primary) \(count)" : item.primary) {
                queue.answer(item.id, .primary(selected: item.selectedIDs))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!armed || (item.kind == .share && count == 0))
        }
    }
}
