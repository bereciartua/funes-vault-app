import AppKit
import BridgeKitRemote
import FunesCore
import SwiftUI

// "<app> wants to connect" (04-ux-mac.md, Panels; T24): shown only while pairing is open for one
// agent. The browser and the panel show the same six-digit code; the panel names the agent, the
// app as reported, its metadata URL and where the browser returns. Allow arms after one second;
// a second sign-in waits until this one is answered. Adapted from EK Bridge's PairingSheet.

@MainActor
final class SignInPanelController {
    static let width: CGFloat = 420
    private let model: AppModel
    private var panel: NSPanel?
    private var shownID: UUID?

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the oldest waiting sign-in, keeps showing the one on screen until it's answered or
    /// expires, and hides when none is left.
    func update() {
        guard let first = model.signIns.first else {
            panel?.orderOut(nil)
            shownID = nil
            return
        }
        if let shownID, model.signIns.contains(where: { $0.id == shownID }) { return }
        shownID = first.id
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentViewController = NSHostingController(rootView: SignInPanelView(model: model, request: first))
        panel.layoutIfNeeded()
        position(panel)
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: String(localized: "\(first.appName) wants to connect. Code \(first.code)."),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
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
        panel.title = String(localized: "Cloud sign-in")
        return panel
    }

    /// Top right, below an approval panel that's showing.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        var top = frame.maxY - 12
        if let other = NSApp.windows.first(where: { $0 !== panel && $0.isVisible && $0.title == String(localized: "Approval") }) {
            top = other.frame.minY - 12
        }
        panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 12, y: top))
    }
}

struct SignInPanelView: View {
    let model: AppModel
    let request: PairingRequest
    /// Allow is enabled a moment after the panel appears, so a click meant for something else
    /// can't approve it.
    @State private var armed = false

    var body: some View {
        let agent = UUID(uuidString: request.clientID).map { model.agentName($0) } ?? String(localized: "an agent")
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text(String(localized: "\(request.appName) wants to connect as \(agent)")).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let url = request.appURL {
                    Text(url).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                Text(String(localized: "Returns to \(request.redirectHost)")).font(.callout).foregroundStyle(.secondary)
                Text(String(localized: "The app's name is as it reported it.")).font(.caption).foregroundStyle(.tertiary)
            }
            Text(request.code)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityLabel(String(localized: "Code \(request.code)"))
            Text(String(localized: "Allow only if this code matches the one in your browser. It will use \(agent)'s access."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.signIns.count > 1 {
                    Text(String(localized: "\(model.signIns.count - 1) more waiting")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Deny")) { model.answerSignIn(request.id, allow: false) }
                Button(String(localized: "Allow")) { model.answerSignIn(request.id, allow: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!armed)
            }
        }
        .padding(18)
        .frame(width: SignInPanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: request.id) {
            armed = false
            try? await Task.sleep(for: .seconds(1))
            armed = true
        }
    }
}
