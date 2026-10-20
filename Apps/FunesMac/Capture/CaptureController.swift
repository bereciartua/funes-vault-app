import AppKit
import FunesCore
import FunesProtocol
import os
import SwiftUI

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "capture")

/// Quick capture (FR-C-01..04): the box from the hotkey, the menu's Remember… and Services ▸
/// Remember in Funes. A capture always goes to the Inbox; classification fills in the proposal
/// afterwards and never holds up saving.
@MainActor
final class CaptureController: NSObject {
    private let model: AppModel
    private let hud: HUD
    private var panel: CapturePanel?
    private let box = CaptureBoxModel()

    init(model: AppModel, hud: HUD) {
        self.model = model
        self.hud = hud
        super.init()
        box.save = { [weak self] text in self?.save(text) ?? false }
        box.cancel = { [weak self] in self?.close() }
    }

    func show(text: String = "", error: String? = nil) {
        let panel = self.panel ?? make()
        self.panel = panel
        box.text = text
        box.error = error
        box.focusRequest += 1
        box.cloudProvider = nil
        if model.preferences.classifyCaptures {
            let settings = model.modelSettings
            Task { [box] in box.cloudProvider = await settings.cloudClassifierName() }
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - frame.height * 0.18))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Stores the capture, or shows why not; true when the box may close.
    private func save(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let classify = model.preferences.classifyCaptures
        let settings = model.modelSettings
        Task {
            do {
                let result = try await services.captures.capture(body, sensitivityHint: hint, now: Date())
                hud.show(String(localized: "Saved to Inbox"))
                guard classify else { return }
                let router = settings.makeRouter()
                let categories = (try? services.store.categories()) ?? []
                let record = await router.classify(body, categories: categories, hint: hint)
                settings.collectUsage(from: router)
                if record.engine != RulesClassifier.engine || record.keptOnDevice {
                    // "At least <level>" holds whatever the model proposed (PR #3 review 4304236141).
                    try? await services.captures.reclassify(suggestionID: result.suggestionID, record: record, floor: hint)
                }
            } catch let error as VaultError {
                show(text: body, error: ErrorText.message(error))
            } catch {
                logger.error("Capture failed")
                show(text: body, error: String(localized: "It couldn't be saved. Try again."))
            }
        }
        box.text = ""
        box.error = nil
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
        if !save(text) { show(text: text, error: box.error) }
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

@MainActor @Observable
final class CaptureBoxModel {
    var text = ""
    var error: String?
    var focusRequest = 0
    /// The cloud provider that proposes the fields for new captures ("Anthropic"); nil when that
    /// happens on this Mac.
    var cloudProvider: String?
    @ObservationIgnored var save: (String) -> Bool = { _ in false }
    @ObservationIgnored var cancel: () -> Void = {}
}

/// "What should Funes remember?" with ⏎ Save · ⇧⏎ New line · Esc Cancel (04-ux-mac.md).
struct CaptureBox: View {
    @Bindable var box: CaptureBoxModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if box.text.isEmpty {
                    Text(String(localized: "What should Funes remember?"))
                        .font(.title3).foregroundStyle(.tertiary).padding(.top, 1).accessibilityHidden(true)
                }
                TextField("", text: $box.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...8)
                    .focused($focused)
                    .accessibilityLabel(String(localized: "What should Funes remember?"))
                    .onKeyPress(keys: [.return]) { press in
                        if press.modifiers.contains(.shift) {
                            box.text += "\n"
                            return .handled
                        }
                        _ = box.save(box.text)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        box.cancel()
                        return .handled
                    }
            }
            if let error = box.error {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red).font(.callout)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack {
                Text(String(localized: "⏎ Save · ⇧⏎ New line · Esc Cancel")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let provider = box.cloudProvider {
                    Text(String(localized: "Goes to your Inbox · fields suggested by \(provider)"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(localized: "Cloud"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .accessibilityLabel(String(localized: "Leaves this Mac"))
                } else {
                    Text(String(localized: "Goes to your Inbox")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5))
        .onChange(of: box.error) { _, error in
            if let error {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
        .onChange(of: box.focusRequest, initial: true) { _, _ in focused = true }
    }
}
