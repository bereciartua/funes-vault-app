import AppKit
import FunesProtocol
import SwiftUI

/// Settings ▸ Capture (04-ux-mac.md): the hotkey, the default sensitivity for captures, and
/// classification on or off.
struct CaptureSettings: View {
    let model: AppModel
    @State private var sensitivity: Sensitivity?
    @State private var classify = true
    @State private var cloudProvider: String?

    var body: some View {
        Form {
            Section(String(localized: "Quick capture")) {
                ShortcutRecorder(title: String(localized: "Shortcut"), accessibilityName: String(localized: "Capture shortcut"),
                                 current: model.preferences.captureShortcut, defaultShortcut: .defaultCapture,
                                 apply: model.setCaptureShortcut)
                Text(String(localized: "Opens the capture box from any app. Funes doesn't need Accessibility access for it."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(String(localized: "Try It")) { model.openCapture() }
            }
            Section(String(localized: "New captures")) {
                Picker(String(localized: "Sensitivity"), selection: $sensitivity) {
                    Text(String(localized: "Let Funes propose it")).tag(Sensitivity?.none)
                    ForEach(Sensitivity.allCases, id: \.self) { Text(String(localized: "At least \($0.title)")).tag(Optional($0)) }
                }
                .onChange(of: sensitivity) { _, value in model.preferences.captureSensitivity = value }
                Toggle(String(localized: "Propose a title, kind and categories"), isOn: $classify)
                    .onChange(of: classify) { _, on in model.preferences.classifyCaptures = on }
                Text(classify ? String(localized: "Uses the Classification model in AI Models; you review every proposal in the Inbox.")
                              : String(localized: "Captures get simple proposals from rules on this Mac."))
                    .font(.callout).foregroundStyle(.secondary)
                if classify, let cloudProvider {
                    Label(String(localized: "New captures are sent to \(cloudProvider) to suggest their fields, within the cloud limit in AI Models."),
                          systemImage: "arrow.up.forward.app")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Button(String(localized: "AI Models…")) { model.settingsTab = .models }
                    .buttonStyle(.link)
            }
            Section(String(localized: "From other apps")) {
                Text(String(localized: "Select text in any app, then choose Services ▸ Remember in Funes. It goes to your Inbox."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            sensitivity = model.preferences.captureSensitivity
            classify = model.preferences.classifyCaptures
        }
        .task { cloudProvider = await model.modelSettings.cloudClassifierName() }
    }
}

/// A global shortcut's row: the shortcut (click, then press keys to change it), Turn Off, and
/// back to the default. Used for capture (⌥⌘M) and Review Request (⌃⌥⌘R).
struct ShortcutRecorder: View {
    let title: String
    let accessibilityName: String
    let defaultShortcut: Shortcut
    /// Registers the new shortcut; false when another app has it.
    let apply: (Shortcut?) -> Bool
    @State private var shortcut: Shortcut?
    @State private var recording = false
    @State private var problem: String?
    @State private var monitor: Any?

    init(title: String, accessibilityName: String, current: Shortcut?, defaultShortcut: Shortcut,
         apply: @escaping (Shortcut?) -> Bool) {
        self.title = title
        self.accessibilityName = accessibilityName
        self.defaultShortcut = defaultShortcut
        self.apply = apply
        _shortcut = State(initialValue: current)
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Button(recording ? String(localized: "Press the new shortcut…") : (shortcut?.display ?? String(localized: "None"))) {
                    recording ? stopRecording() : startRecording()
                }
                .accessibilityLabel(String(localized: "\(accessibilityName): \(shortcut?.display ?? String(localized: "none"))"))
                if shortcut != nil {
                    Button(String(localized: "Turn Off")) { set(nil) }
                }
                if shortcut != defaultShortcut {
                    Button(String(localized: "Use \(defaultShortcut.display)")) { set(defaultShortcut) }
                }
            }
        }
        if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
    }

    private func startRecording() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                return nil
            }
            guard let new = Shortcut(event: event) else {
                problem = String(localized: "Use ⌘, ⌥ or ⌃ with a key.")
                return nil
            }
            stopRecording()
            set(new)
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func set(_ new: Shortcut?) {
        if apply(new) {
            shortcut = new
            problem = nil
        } else {
            problem = String(localized: "Another app already uses \(new?.display ?? ""). Try another shortcut.")
        }
    }
}
