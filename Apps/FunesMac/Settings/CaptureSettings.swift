import AppKit
import FunesProtocol
import SwiftUI

/// Settings ▸ Capture (04-ux-mac.md): the hotkey, the default sensitivity for captures, and
/// classification on or off.
struct CaptureSettings: View {
    let model: AppModel
    @State private var shortcut: Shortcut?
    @State private var recording = false
    @State private var problem: String?
    @State private var sensitivity: Sensitivity?
    @State private var classify = true
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section(String(localized: "Quick capture")) {
                LabeledContent(String(localized: "Shortcut")) {
                    HStack {
                        Button(recording ? String(localized: "Press the new shortcut…") : (shortcut?.display ?? String(localized: "None"))) {
                            recording ? stopRecording() : startRecording()
                        }
                        .accessibilityLabel(String(localized: "Capture shortcut: \(shortcut?.display ?? String(localized: "none"))"))
                        if shortcut != nil {
                            Button(String(localized: "Turn Off")) { apply(nil) }
                        }
                        if shortcut != .defaultCapture {
                            Button(String(localized: "Use ⌥⌘M")) { apply(.defaultCapture) }
                        }
                    }
                }
                if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
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
            shortcut = model.preferences.captureShortcut
            sensitivity = model.preferences.captureSensitivity
            classify = model.preferences.classifyCaptures
        }
        .onDisappear(perform: stopRecording)
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
            apply(new)
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func apply(_ new: Shortcut?) {
        if model.setCaptureShortcut(new) {
            shortcut = new
            problem = nil
        } else {
            problem = String(localized: "Another app already uses \(new?.display ?? ""). Try another shortcut.")
        }
    }
}
