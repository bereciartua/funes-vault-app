import AppKit
import BridgeUI
import Carbon.HIToolbox
import BridgeKitCore
import FunesCore

/// The menu bar item and its menu (04-ux-mac.md, FR-G-01). The menu is rebuilt each time it
/// opens, so counts and countdowns are current.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item: NSStatusItem
    /// Check for Updates…; nil hides it (a build that can't update itself).
    var checkForUpdates: (() -> Void)?
    var updatesAvailable: () -> Bool = { false }

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.setAccessibilityTitle(String(localized: "Funes Vault"))
        update()
    }

    /// Redraws the icon; the menu itself is built when it opens.
    func update() {
        let state = model.iconState
        let remote = model.remoteAccess.enabled
        item.button?.image = MenuBarIcon.image(state, remote: remote)
        item.button?.setAccessibilityLabel(remote ? state.accessibilityLabel + ", " + String(localized: "Remote Access on")
                                                  : state.accessibilityLabel)
        var tip = statusLine
        if remote { tip += "\n" + model.remoteAccess.menuLine }
        if model.inboxCount > 0 { tip += "\n" + String(localized: "Inbox: \(model.inboxCount)") }
        if !model.pending.isEmpty { tip += "\n" + String(localized: "Pending requests: \(model.pending.count)") }
        item.button?.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.tick()
        menu.removeAllItems()

        // While something waits for the user, the first item answers it (UX review F3).
        if let review = reviewTitle {
            let item = NSMenuItem(title: review, action: #selector(reviewRequest), keyEquivalent: "")
            item.target = self
            if let shortcut = model.preferences.reviewShortcut { Self.setKeyEquivalent(item, shortcut) }
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let status = NSMenuItem(title: statusLine, action: #selector(openAgents), keyEquivalent: "")
        status.target = self
        menu.addItem(status)
        if model.remoteAccess.enabled {
            let remote = NSMenuItem(title: model.remoteAccess.menuLine, action: #selector(openRemoteAccess), keyEquivalent: "")
            remote.target = self
            remote.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            menu.addItem(remote)
            let off = NSMenuItem(title: String(localized: "Turn Off Remote Access"), action: #selector(turnOffRemote),
                                 keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        }
        menu.addItem(.separator())

        let remember = NSMenuItem(title: String(localized: "Remember…"), action: #selector(remember), keyEquivalent: "m")
        remember.keyEquivalentModifierMask = [.option, .command]
        remember.target = self
        menu.addItem(remember)

        let inbox = NSMenuItem(title: String(localized: "Inbox"), action: #selector(openInbox), keyEquivalent: "")
        inbox.target = self
        if model.inboxCount > 0 { inbox.badge = NSMenuItemBadge(count: model.inboxCount) }
        menu.addItem(inbox)

        let pending = NSMenuItem(title: String(localized: "Pending requests"), action: nil, keyEquivalent: "")
        if model.pending.isEmpty {
            pending.isEnabled = false
        } else {
            pending.badge = NSMenuItemBadge(count: model.pending.count)
            let submenu = NSMenu()
            for request in model.pending {
                let minutes = request.minutesLeft(at: model.now)
                let title = request.status == .approved
                    ? String(localized: "\(request.agentName) · approved, waiting for the agent")
                    : String(localized: "\(request.agentName) · \(minutes) min left")
                let row = NSMenuItem(title: title, action: #selector(openPending(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = request.id
                row.isEnabled = request.status == .needsApproval
                submenu.addItem(row)
            }
            submenu.addItem(.separator())
            let all = NSMenuItem(title: String(localized: "Show in Activity"), action: #selector(openActivity), keyEquivalent: "")
            all.target = self
            submenu.addItem(all)
            pending.submenu = submenu
        }
        menu.addItem(pending)
        menu.addItem(.separator())

        if let until = model.pausedUntil {
            let resume = NSMenuItem(title: String(localized: "Resume Funes Vault"), action: #selector(resume), keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
            let note = NSMenuItem(title: Self.pausedText(until, now: model.now), action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        } else {
            let pause = NSMenuItem(title: String(localized: "Pause Funes Vault"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (duration, title) in [(FunesPause.Duration.oneHour, String(localized: "For 1 Hour")),
                                      (.untilTomorrow, String(localized: "Until Tomorrow")),
                                      (.untilResumed, String(localized: "Until I Resume"))] {
                let choice = NSMenuItem(title: title, action: #selector(pause(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = duration.rawValue
                submenu.addItem(choice)
            }
            pause.submenu = submenu
            menu.addItem(pause)
        }
        let open = NSMenuItem(title: String(localized: "Open Funes Vault"), action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        if let checkForUpdates, updatesAvailable() {
            _ = checkForUpdates
            let updates = NSMenuItem(title: String(localized: "Check for Updates…"), action: #selector(checkUpdates),
                                     keyEquivalent: "")
            updates.target = self
            menu.addItem(updates)
        }
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(withTitle: String(localized: "Quit Funes Vault"), action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
    }

    /// "Review Cursor's request · 0:13…" for the panel's current item, or the newest pending request;
    /// nil when nothing waits.
    private var reviewTitle: String? {
        if let current = model.services.approvals.queue.current {
            let agent = current.shortLabel.components(separatedBy: " · ").first ?? current.shortLabel
            if let seconds = model.services.approvals.queue.remaining(current) {
                return String(localized: "Review \(agent)'s Request · \(ApprovalQueue.countdown(seconds))…")
            }
            return String(localized: "Review \(agent)'s Request…")
        }
        guard let newest = model.pending.first(where: { $0.status == .needsApproval }) else { return nil }
        return String(localized: "Review \(newest.agentName)'s Request · \(newest.minutesLeft(at: model.now)) min left…")
    }

    /// Shows the global shortcut next to the item (it works from any app, menu open or not).
    private static func setKeyEquivalent(_ item: NSMenuItem, _ shortcut: Shortcut) {
        item.keyEquivalent = Shortcut.keyName(shortcut.keyCode).lowercased()
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if shortcut.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if shortcut.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        item.keyEquivalentModifierMask = mask
    }

    /// "Funes Vault is on · 3 agents" and its variants.
    var statusLine: String {
        let count = model.agents.count
        if !model.preferences.mcpEnabled { return String(localized: "Funes Vault is off") }
        if model.pausedUntil != nil { return String(localized: "Funes Vault is paused") }
        switch model.mcpStatus {
        case .off: return String(localized: "Funes Vault is off")
        case .starting: return String(localized: "Funes Vault is starting…")
        case .listening:
            return count == 1 ? String(localized: "Funes Vault is on · 1 agent")
                              : String(localized: "Funes Vault is on · \(count) agents")
        case .failed(.portInUse(let port)): return String(localized: "Port \(String(port)) is in use")
        case .failed: return String(localized: "The agent server stopped")
        }
    }

    static func pausedText(_ until: Date, now: Date) -> String {
        if until == .distantFuture { return String(localized: "Paused until you resume") }
        let calendar = Calendar.current
        let time = until.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(until, inSameDayAs: now) { return String(localized: "Paused until \(time)") }
        return String(localized: "Paused until tomorrow at \(time)")
    }

    // MARK: Actions

    @objc private func openAgents() { model.show(.agents) }
    @objc private func reviewRequest() { model.reviewRequest() }
    @objc private func openRemoteAccess() { model.show(.remoteAccess) }
    /// At once, without asking: the port closes and every cloud agent is cut off.
    @objc private func turnOffRemote() { model.remoteAccess.apply(false) }
    @objc private func remember() { model.openCapture() }
    @objc private func openInbox() { model.show(.inbox) }
    @objc private func openActivity() { model.showActivity(nil) }
    @objc private func openWindow() { model.openMainWindow() }
    @objc private func openSettings() { model.openSettings(nil) }
    @objc private func resume() { model.resume() }
    @objc private func checkUpdates() { checkForUpdates?() }

    @objc private func openPending(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.openPendingRequest(id)
    }

    @objc private func pause(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let duration = FunesPause.Duration(rawValue: raw) else { return }
        model.pause(duration)
    }
}
