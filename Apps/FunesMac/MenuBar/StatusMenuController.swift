import AppKit
import BridgeUI
import FunesCore

/// The menu bar item (04-ux-mac.md ▸ Menu bar, FR-G-01, ADR-0029): a click opens the panel, or
/// closes it; a right click or Control-click shows a short native menu, so the window, Settings
/// and Quit are always one native menu away.
@MainActor
final class StatusMenuController: NSObject {
    private let model: AppModel
    private let item: NSStatusItem
    let panel: MenuBarPanelController
    /// Check for Updates…; nil hides it (a build that can't update itself).
    var checkForUpdates: (() -> Void)? {
        didSet { panel.checkForUpdates = checkForUpdates }
    }
    var updatesAvailable: () -> Bool = { false } {
        didSet { panel.updatesAvailable = updatesAvailable }
    }

    init(model: AppModel, panel: MenuBarPanelController) {
        self.model = model
        self.panel = panel
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityTitle(String(localized: "Funes Vault"))
        }
        update()
    }

    /// Redraws the icon, its tooltip and VoiceOver's label.
    func update() {
        let state = model.iconState
        let remote = model.remoteAccess.enabled
        item.button?.image = MenuBarIcon.image(state, remote: remote)
        // VoiceOver hears what the tooltip says.
        let tip = tooltip
        item.button?.setAccessibilityLabel(([remote ? state.accessibilityLabel + ", " + String(localized: "Remote Access on")
                                                    : state.accessibilityLabel] + tip.components(separatedBy: "\n"))
            .joined(separator: ", "))
        item.button?.toolTip = tip
        if panel.isShown { panel.model.vaultChanged() }
    }

    /// Opens the panel under the icon (FUNES_DEBUG_OPEN=panel in a Debug build).
    func showPanel() {
        if let button = item.button { panel.show(from: button) }
    }

    /// "Agents: Paused until 14:00", then Remote Access, what waits and the Inbox.
    var tooltip: String {
        var lines = [String(localized: "Agents: \(model.agentsTile.status(now: model.now))")]
        if model.remoteAccess.enabled { lines.append(String(localized: "Remote Access: \(model.remoteTile.status)")) }
        let waiting = model.waiting(now: Date()).cards.count
        if waiting > 0 { lines.append(String(localized: "Waiting for you: \(waiting)")) }
        if model.inboxCount > 0 { lines.append(String(localized: "Inbox: \(model.inboxCount)")) }
        return lines.joined(separator: "\n")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            panel.close()
            showMenu(from: sender)
        } else {
            panel.toggle(from: sender)
        }
    }

    /// Open Funes Vault ⌘O, Settings… ⌘,, Check for Updates… (a copy that can update itself) and
    /// Quit Funes Vault ⌘Q.
    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.appearance = NSApp.appearance
        let open = NSMenuItem(title: String(localized: "Open Funes Vault"), action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        if checkForUpdates != nil, updatesAvailable() {
            let updates = NSMenuItem(title: String(localized: "Check for Updates…"), action: #selector(checkUpdates), keyEquivalent: "")
            updates.target = self
            menu.addItem(updates)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Funes Vault"), action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }

    @objc private func openWindow() { model.showHome() }
    @objc private func openSettings() { model.openSettings(nil) }
    @objc private func checkUpdates() { checkForUpdates?() }
}
