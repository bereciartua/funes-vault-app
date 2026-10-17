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

    private func fit(_ panel: NSPanel) {
        guard let host else { return }
        let size = host.sizeThatFits(in: NSSize(width: Self.width, height: 2_000))
        if size.height > 1, size != panel.contentLayoutRect.size {
            let top = panel.frame.maxY
            panel.setContentSize(size)
            if panel.isVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
        }
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
        let host = NSHostingController(rootView: ApprovalPanelView(queue: queue))
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
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 12))
    }
}

public struct ApprovalPanelView: View {
    let queue: ApprovalQueue
    /// The item the buttons may act on. When the shown item switches (one expired, or the user
    /// stepped), they wait a moment so a click meant for the old one can't answer the new one.
    @State private var armedID: UUID?
    public static let armingDelay: TimeInterval = 0.6

    public init(queue: ApprovalQueue) {
        self.queue = queue
    }

    public var body: some View {
        content.ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        if let item = queue.current {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    header(item)
                    rows(item)
                    facts(item)
                    if let note = item.note {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                Divider()
                footer(item)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .frame(width: ApprovalPanelController.width)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: item.id, initial: true) { _, id in
                armedID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.armingDelay) {
                    MainActor.assumeIsolated {
                        if queue.current?.id == id { armedID = id }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.title)
        } else {
            Color.clear.frame(width: ApprovalPanelController.width, height: 1)
        }
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
                if let subtitle = item.subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                        if let detail = row.detail {
                            Text(detail).font(.callout).foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
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
                        Text(fact.value).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func footer(_ item: PanelItem) -> some View {
        let shown = queue.shown
        let index = shown.firstIndex(where: { $0.id == item.id }) ?? 0
        let armed = armedID == item.id
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
                Text(String(localized: "\(seconds) s")).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "\(seconds) seconds left"))
            }
            Spacer()
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
            .disabled(!armed || (item.kind == .share && count == 0))
        }
    }
}
