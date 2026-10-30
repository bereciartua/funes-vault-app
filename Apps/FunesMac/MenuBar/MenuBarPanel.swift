import AppKit
import FunesCore
import FunesProtocol
import os
import SwiftUI

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "menubar")

/// The menu bar panel's window (ADR-0029, Phase 10): borderless, non-activating, able to become
/// key for its own field and controls while another app stays frontmost, 350 pt wide and
/// anchored under the status item. It closes on Esc, a click outside, another click on the icon,
/// another app activating (⌘⇥ included), a Space or full-screen change, the screen locking and the
/// Mac sleeping; closing keeps only the field's draft. The signals are those Phase 10.0's spike
/// proved (spec/plans/phase-10-menu-bar-panel.md).
@MainActor
final class MenuBarPanelController {
    static let width: CGFloat = 350

    let model: MenuBarPanelModel
    private let panel: MenuBarPanelWindow
    private let host: NSHostingView<AnyView>
    /// The status item's button: the panel's anchor, and the click that toggles it.
    private weak var anchor: NSStatusBarButton?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timers: [Timer] = []
    /// While above zero, nothing closes the panel: its own menus, Remote Access's question,
    /// dictation's permission prompt.
    private var holds = 0
    private var dictationHeld = false
    /// The app Remote Access's question took the focus from: its coming back doesn't close the panel.
    private var returning: NSRunningApplication?
    private var lastHeight: CGFloat = 0
    /// The menu bar's other app actions (⌘O, ⌘, and ⌘Q work while the panel is key).
    var checkForUpdates: (() -> Void)?
    var updatesAvailable: () -> Bool = { false }

    var isShown: Bool { panel.isVisible }

    init(model: MenuBarPanelModel) {
        self.model = model
        panel = MenuBarPanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        host = NSHostingView(rootView: AnyView(EmptyView()))
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.title = String(localized: "Funes Vault")
        panel.setAccessibilityLabel(String(localized: "Funes Vault"))
        panel.animationBehavior = .utilityWindow

        // The menu bar's material behind the SwiftUI content, rounded like macOS's menu bar extras.
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        panel.onCancel = { [weak self] in self?.close("esc") }
        panel.keyEquivalent = { [weak self] event in self?.performKeyEquivalent(event) ?? false }
        model.closePanel = { [weak self] in self?.close() }
        model.holdOpen = { [weak self] on in self?.holdForDictation(on) }
        model.confirmRemoteOn = { [weak self] in self?.confirmRemoteOn() }
        model.showPauseMenu = { [weak self] in self?.showPauseMenu() }
        host.rootView = AnyView(MenuBarPanelView(model: model, heightChanged: { [weak self] in self?.heightChanged($0) },
                                                 moreMenu: { [weak self] in self?.showMoreMenu() }))
    }

    // MARK: Showing

    /// A click on the icon: opens the panel, or closes it if it's open.
    func toggle(from button: NSStatusBarButton) {
        if panel.isVisible {
            close("icon")
        } else {
            show(from: button)
        }
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        // Follows Settings ▸ General ▸ Appearance like the rest of the app (FR-G-06).
        panel.appearance = NSApp.appearance
        model.maxHeight = availableHeight()
        model.opened()
        host.layoutSubtreeIfNeeded()
        let height = max(lastHeight, host.fittingSize.height, 120)
        place(height: height)
        panel.makeKeyAndOrderFront(nil)
        startWatching()
        announce()
        logger.debug("Panel opened")
    }

    /// `reason` is for the log: which closing rule fired. `incidental` closes (a click outside,
    /// another app activating) wait while a hold is on: the panel's own menu, Remote Access's
    /// question or dictation's permission prompt cause them. Every other close happens at once.
    func close(_ reason: String = "action", incidental: Bool = false) {
        guard panel.isVisible else { return }
        guard holds == 0 || !incidental else {
            logger.debug("Panel held open: \(reason, privacy: .public)") // log-safe: a fixed word
            return
        }
        logger.debug("Panel closed: \(reason, privacy: .public)") // log-safe: a fixed word
        // Closing stops dictation, so its hold goes with it.
        if dictationHeld {
            dictationHeld = false
            holds -= 1
        }
        stopWatching()
        panel.orderOut(nil)
        model.closed()
    }

    /// The screen's visible area under the icon.
    private func availableHeight() -> CGFloat {
        guard let frame = anchorFrame(), let screen = anchor?.window?.screen ?? NSScreen.main else { return 720 }
        return max(240, frame.minY - 6 - screen.visibleFrame.minY - 8)
    }

    private func anchorFrame() -> NSRect? {
        guard let anchor, let window = anchor.window else { return nil }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    /// Under the icon, its top 6 pt below the menu bar, kept on the icon's screen.
    private func place(height: CGFloat) {
        let screen = anchor?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let icon = anchorFrame() ?? NSRect(x: visible.maxX - 200, y: visible.maxY, width: 24, height: 0)
        let height = min(height, model.maxHeight)
        let x = min(max(icon.midX - Self.width / 2, visible.minX + 8), visible.maxX - Self.width - 8)
        let top = min(icon.minY, visible.maxY) - 6
        panel.setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: true)
        fitContentView()
        panel.invalidateShadow()
    }

    /// The content view always fills the panel. A resize that AppKit applies late leaves it at its
    /// old height, which shows as an empty strip at the top and the footer cut off.
    private func fitContentView() {
        guard let content = panel.contentView else { return }
        let bounds = NSRect(origin: .zero, size: panel.frame.size)
        if content.frame != bounds { content.frame = bounds }
    }

    /// The content's height changed (a card arrived, the field grew, results showed): the panel
    /// keeps its top under the icon. SwiftUI reports it during its own layout, and resizing the
    /// window from there is applied unreliably, so the resize waits a turn.
    private func heightChanged(_ height: CGFloat) {
        lastHeight = ceil(height)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.fitHeight() } }
    }

    private func fitHeight() {
        guard panel.isVisible, abs(panel.frame.height - min(lastHeight, model.maxHeight)) > 0.5 else { return }
        #if FUNES_UI_REVIEW
        if reviewAnchored {
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - min(lastHeight, model.maxHeight), width: Self.width,
                                  height: min(lastHeight, model.maxHeight)), display: true)
            fitContentView()
            return
        }
        #endif
        place(height: lastHeight)
    }

    /// "Funes Vault, 2 requests waiting for you".
    private func announce() {
        let count = model.waiting.cards.count
        var text = String(localized: "Funes Vault")
        if count == 1 { text += ", " + String(localized: "1 request waiting for you") }
        if count > 1 { text += ", " + String(localized: "\(count) requests waiting for you") }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    #if FUNES_UI_REVIEW
    /// The UI review: the panel as it opens, centred near the top of the screen, without a status item.
    func reviewShow() -> NSWindow {
        panel.appearance = NSApp.appearance
        model.maxHeight = 760
        model.opened()
        host.layoutSubtreeIfNeeded()
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let height = min(max(lastHeight, host.fittingSize.height, 120), model.maxHeight)
        panel.setFrame(NSRect(x: visible.midX - Self.width / 2, y: visible.maxY - 20 - height, width: Self.width, height: height),
                       display: true)
        panel.orderFrontRegardless()
        reviewAnchored = true
        return panel
    }

    private var reviewAnchored = false

    func reviewHide() {
        reviewAnchored = false
        panel.orderOut(nil)
        model.closed()
    }
    #endif

    // MARK: Closing rules

    private func startWatching() {
        stopWatching()
        // A click in another app, on the desktop or on the menu bar. On macOS 26 and later the
        // click on our own status item reaches this monitor too: the icon's own action toggles.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                           handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let icon = self.anchorFrame(), icon.contains(NSEvent.mouseLocation) { return }
                self.close("click outside", incidental: true)
            }
        }) { monitors.append(monitor) }
        // A click in one of Funes's own windows (the main window, an approval panel).
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                          handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let window = event.window, window !== self.panel, window !== self.anchor?.window { self.close("click in a window", incidental: true) }
            }
            return event
        }) { monitors.append(monitor) }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] pid in
            // ⌘⇥ or a click in the Dock: another app came forward.
            guard let self, pid != ProcessInfo.processInfo.processIdentifier else { return }
            if let returning = self.returning, pid == returning.processIdentifier {
                self.returning = nil
                return
            }
            self.close("app activated", incidental: true)
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observe(workspace, name) { [weak self] _ in self?.close(name.rawValue) }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in
            self?.close("screen locked")
        }
        // While open: the counts follow the vault, the chart moves on at each hour, after the Mac
        // wakes and when the time zone changes.
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in self?.model.refreshPulse() }
        observe(NotificationCenter.default, .NSSystemTimeZoneDidChange) { [weak self] _ in self?.model.refreshPulse() }

        let second = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.model.tick() } }
        RunLoop.main.add(second, forMode: .common)
        timers.append(second)
        let next = Calendar.current.dateInterval(of: .hour, for: Date())?.end ?? Date().addingTimeInterval(3_600)
        let hourly = Timer(fireAt: next.addingTimeInterval(1), interval: 3_600, target: BlockTarget { [weak self] in
            self?.model.refreshPulse()
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(hourly, forMode: .common)
        timers.append(hourly)
    }

    /// `handler` gets the activated app's process id, for an app activation.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (pid_t?) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { handler(pid) }
        }
        observers.append((center, token))
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        timers.forEach { $0.invalidate() }
        timers = []
    }

    private func hold(_ body: () -> Void) {
        holds += 1
        body()
        holds -= 1
    }

    private func holdForDictation(_ on: Bool) {
        guard on != dictationHeld else { return }
        dictationHeld = on
        holds += on ? 1 : -1
        if !on, panel.isVisible { panel.makeKey() }
    }

    // MARK: Menus and the question

    /// Turning the Agents switch off: For 1 Hour, Until Tomorrow, Until I Resume (FR-A-11). Esc
    /// or a click elsewhere closes the menu and leaves agents on.
    private func showPauseMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSApp.appearance
        var targets: [BlockTarget] = []
        for (duration, title) in [(FunesPause.Duration.oneHour, String(localized: "For 1 Hour")),
                                  (.untilTomorrow, String(localized: "Until Tomorrow")),
                                  (.untilResumed, String(localized: "Until I Resume"))] {
            let target = BlockTarget { [weak self] in self?.model.app.pause(duration) }
            targets.append(target)
            let item = NSMenuItem(title: title, action: #selector(BlockTarget.fire), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        popUp(menu, at: model.pauseMenuAnchor)
        withExtendedLifetime(targets) {}
    }

    /// The footer's ⋯: Check for Updates… (in a copy that can update itself) and Quit Funes Vault.
    private func showMoreMenu() {
        let menu = NSMenu()
        menu.appearance = NSApp.appearance
        var targets: [BlockTarget] = []
        if let checkForUpdates, updatesAvailable() {
            let target = BlockTarget { [weak self] in
                self?.close()
                checkForUpdates()
            }
            targets.append(target)
            let item = NSMenuItem(title: String(localized: "Check for Updates…"), action: #selector(BlockTarget.fire), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        menu.addItem(withTitle: String(localized: "Quit Funes Vault"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        popUp(menu, at: model.moreMenuAnchor)
        withExtendedLifetime(targets) {}
    }

    /// A menu from a control in the panel (its frame in the panel's content, from SwiftUI), held
    /// open: the panel doesn't close while it's up.
    private func popUp(_ menu: NSMenu, at anchor: CGRect) {
        guard let content = panel.contentView else { return }
        // SwiftUI's frames are top-down; the content view's are bottom-up.
        let point = NSPoint(x: anchor.minX, y: content.bounds.height - anchor.maxY - 2)
        hold { _ = menu.popUp(positioning: nil, at: point, in: content) }
    }

    /// Turning Remote Access on asks first, with the Remote Access section's own question
    /// (FR-AI-04). The question is an app-modal alert, which brings Funes forward; the app that
    /// was frontmost comes back after it, and the panel stays open.
    private func confirmRemoteOn() {
        let previous = NSWorkspace.shared.frontmostApplication
        hold { model.app.remoteAccess.setEnabled(true) }
        if let previous, previous != NSRunningApplication.current {
            returning = previous
            previous.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.returning = nil }
        }
        if panel.isVisible { panel.makeKeyAndOrderFront(nil) }
    }

    // MARK: Keys

    /// ⌘O, ⌘, and ⌘Q while the panel is key: Funes isn't the active app, so its main menu may not see them.
    private func performKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "o":
            close()
            model.app.showHome()
        case ",":
            close()
            model.app.openSettings(nil)
        case "q":
            NSApp.terminate(nil)
        default:
            return false
        }
        return true
    }
}

/// The panel: key without activating Funes; Esc that nothing in it handled closes it.
final class MenuBarPanelWindow: NSPanel {
    var onCancel: () -> Void = {}
    var keyEquivalent: (NSEvent) -> Bool = { _ in false }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyEquivalent(event) || super.performKeyEquivalent(with: event)
    }
}

/// A closure as an Objective-C target, for menu items and timers.
@MainActor
final class BlockTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
