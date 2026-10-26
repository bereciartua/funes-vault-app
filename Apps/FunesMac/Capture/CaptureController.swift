import AppKit
import FunesCore
import FunesProtocol
import os
import SwiftUI

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "capture")

/// Quick capture (FR-C-01..04): the box from the hotkey, the menu's Remember… and Services ▸
/// Remember in Funes. A capture always goes to the Inbox; its processing job, queued with it,
/// fills in the proposal afterwards (ProcessingRunner) and never holds up saving.
@MainActor
final class CaptureController: NSObject {
    private let model: AppModel
    private let saver: CaptureSaver
    private var panel: CapturePanel?
    private let box = CaptureBoxModel()

    init(model: AppModel, saver: CaptureSaver) {
        self.model = model
        self.saver = saver
        super.init()
        box.save = { [weak self] _ in self?.save() ?? false }
        box.cancel = { [weak self] in self?.close() }
        // A save that fails after the box closed brings it back with the text and the reason.
        box.restore = { [weak self] in self?.reopen() }
    }

    func show(text: String = "", error: String? = nil) {
        box.text = text
        box.error = error
        reopen()
    }

    private func reopen() {
        let panel = self.panel ?? make()
        self.panel = panel
        box.focusRequest += 1
        model.updateCloudChip(box)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - frame.height * 0.18))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        box.stopDictation += 1
        panel?.orderOut(nil)
    }

    /// Stores the box's text, or shows why not; true when the box may close.
    private func save() -> Bool {
        guard saver.save(box) else { return false }
        close()
        return true
    }

    private func make() -> CapturePanel {
        let panel = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                                 styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = String(localized: "Remember")
        let host = NSHostingController(rootView: CaptureBox(box: box))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.onResign = { [weak self] in
            // Clicking elsewhere puts the box away, keeping what was typed.
            if self?.box.text.isEmpty == true { self?.close() }
        }
        return panel
    }

    // MARK: Services ▸ Remember in Funes (FR-C-03)

    /// NSServices `rememberInFunes`: the selected text goes straight to the Inbox, or into the box
    /// with the reason when it can't be saved as it is.
    @objc func rememberInFunes(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            error.pointee = String(localized: "There's no text to remember.") as NSString
            return
        }
        box.text = text
        box.error = nil
        if !saver.save(box) { reopen() }
    }
}

/// Saving a capture, the same from the capture box and Home's composer (FR-C-01, FR-H-02): the
/// length limit, the secret scanner, the HUD, and the text back with the reason when storing it
/// fails.
@MainActor
final class CaptureSaver {
    private let model: AppModel
    private let hud: HUD

    init(model: AppModel, hud: HUD) {
        self.model = model
        self.hud = hud
    }

    /// Stores `box.text` and empties the box, or shows why not in it; true when it was taken.
    func save(_ box: CaptureBoxModel) -> Bool {
        let body = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        guard InputLimits.length(of: body) <= InputLimits.body.upperBound else {
            box.error = String(localized: "That's longer than 10,000 characters.")
            return false
        }
        let findings = SecretScanner.scan(body)
        guard findings.isEmpty else {
            box.error = SecretText.message(findings)
            return false
        }
        let hint = model.preferences.captureSensitivity
        let services = model.services
        let hud = self.hud
        Task {
            do {
                try await services.captures.capture(body, sensitivityHint: hint, now: Date())
                hud.show(String(localized: "Saved to Inbox"))
            } catch let error as VaultError {
                box.text = body
                box.error = ErrorText.message(error)
                box.restore()
            } catch {
                logger.error("Capture failed")
                box.text = body
                box.error = String(localized: "It couldn't be saved. Try again.")
                box.restore()
            }
        }
        box.stopDictation += 1
        box.text = ""
        box.error = nil
        return true
    }
}

/// A panel that takes typing without activating Funes, like Spotlight.
final class CapturePanel: NSPanel {
    var onResign: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign()
    }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
