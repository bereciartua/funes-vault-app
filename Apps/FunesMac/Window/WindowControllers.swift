import AppKit
import SwiftUI

/// A window hosting a SwiftUI view, created on first use and kept for the app's lifetime.
@MainActor
class HostedWindowController<Content: View>: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let make: () -> Content
    private let configure: (NSWindow) -> Void
    /// Called when the window opens or closes (the Dock icon follows it).
    var visibilityChanged: () -> Void = {}

    init(content: @escaping () -> Content, configure: @escaping (NSWindow) -> Void) {
        make = content
        self.configure = configure
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? build()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        visibilityChanged()
    }

    func close() { window?.close() }

    private func build() -> NSWindow {
        let host = NSHostingController(rootView: make())
        // The window keeps the size the user gives it; SwiftUI only sets the minimum.
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.delegate = self
        configure(window)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
    }
}

/// The main window (04-ux-mac.md): a sidebar and a content area, at least 860×560.
@MainActor
final class MainWindowController: HostedWindowController<MainView> {
    static let minimumSize = NSSize(width: 860, height: 560)

    init(model: AppModel) {
        super.init(content: { MainView(model: model) }, configure: { window in
            window.title = String(localized: "Funes Vault")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.contentMinSize = Self.minimumSize
            window.setContentSize(NSSize(width: 1_040, height: 680))
            window.center()
            if !Preferences.isDevelopmentVault { window.setFrameAutosaveName("FunesMainWindow") }
            if window.frame.width < Self.minimumSize.width || window.frame.height < Self.minimumSize.height {
                window.setContentSize(NSSize(width: 1_040, height: 680))
                window.center()
            }
            window.tabbingMode = .disallowed
        })
    }
}

/// Settings (ADR-0030 §1): a sidebar window, 820×600 by default and at least 760×520.
@MainActor
final class SettingsWindowController: HostedWindowController<SettingsView> {
    static let minimumSize = NSSize(width: 760, height: 520)
    static let defaultSize = NSSize(width: 820, height: 600)

    init(model: AppModel) {
        super.init(content: { SettingsView(model: model) }, configure: { window in
            window.title = String(localized: "Funes Vault Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.toolbarStyle = .unified
            window.contentMinSize = Self.minimumSize
            window.setContentSize(Self.defaultSize)
            window.center()
            if !Preferences.isDevelopmentVault { window.setFrameAutosaveName("FunesSettingsWindow") }
            if window.frame.width < Self.minimumSize.width || window.frame.height < Self.minimumSize.height {
                window.setContentSize(Self.defaultSize)
                window.center()
            }
            window.tabbingMode = .disallowed
        })
    }

}
