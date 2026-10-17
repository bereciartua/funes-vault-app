import AppKit
import SwiftUI

/// A short notice near the top of the screen ("Saved to Inbox", "No answer: … was told to wait").
/// Non-activating, never takes focus, announced to VoiceOver, and gone after a few seconds.
@MainActor
final class HUD {
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    func show(_ text: String, symbol: String = "checkmark.circle.fill", seconds: TimeInterval = 2.5) {
        let panel = self.panel ?? make()
        self.panel = panel
        let host = NSHostingController(rootView: HUDView(text: text, symbol: symbol))
        let size = host.sizeThatFits(in: NSSize(width: 440, height: 400))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: ceil(size.width), height: ceil(size.height)))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 120))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let panel = self?.panel else { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    panel.orderOut(nil)
                } else {
                    NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                         completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
                }
            }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

struct HUDView: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
