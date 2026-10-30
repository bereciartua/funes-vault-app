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

/// Saving a capture, the same from the capture box, Home's composer and the menu bar panel's field
/// (FR-C-01, FR-H-02, FR-G-01): the length limit, the secret scanner, then storing it. The box and
/// the composer show the HUD and get the text back with the reason when storing fails; the panel
/// handles the result itself.
@MainActor
final class CaptureSaver {
    private let model: AppModel
    private let hud: HUD

    init(model: AppModel, hud: HUD) {
        self.model = model
        self.hud = hud
    }

    /// Why `body` can't be saved as it is (too long, or it looks like it holds a secret); nil
    /// when it can. Checked before a field lets go of the text.
    func validate(_ body: String) -> String? {
        guard InputLimits.length(of: body) <= InputLimits.body.upperBound else {
            return String(localized: "That's longer than 10,000 characters.")
        }
        let findings = SecretScanner.scan(body)
        return findings.isEmpty ? nil : SecretText.message(findings)
    }

    /// Stores a capture that passed `validate`: nil once it's in the Inbox, else why it isn't.
    /// The caller decides what to do with the text (the menu bar panel stays open).
    func store(_ body: String) async -> String? {
        do {
            try await model.services.captures.capture(body, sensitivityHint: model.preferences.captureSensitivity, now: Date())
            return nil
        } catch let error as VaultError {
            return ErrorText.message(error)
        } catch {
            logger.error("Capture failed")
            return String(localized: "It couldn't be saved. Try again.")
        }
    }

    /// Stores `box.text` and empties the box, or shows why not in it; true when it was taken.
    /// A store that fails later puts the text back with the reason (`box.restore`).
    func save(_ box: CaptureBoxModel) -> Bool {
        let body = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        if let reason = validate(body) {
            box.error = reason
            return false
        }
        let hud = self.hud
        Task {
            if let failure = await store(body) {
                box.text = body
                box.error = failure
                box.restore()
            } else {
                hud.show(String(localized: "Saved to Inbox"))
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
