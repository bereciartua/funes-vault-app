import AppKit
import SwiftUI

/// What the capture box and Home's composer type into (FR-C-01, FR-H-02): the text, the reason it
/// can't be saved, and where it goes.
@MainActor @Observable
final class CaptureBoxModel {
    var text = ""
    var error: String?
    var focusRequest = 0
    /// Bumped when the text is saved or the box closes, so dictation stops.
    var stopDictation = 0
    /// The cloud provider that proposes the fields for new captures ("Anthropic"); nil when that
    /// happens on this Mac.
    var cloudProvider: String?
    @ObservationIgnored var save: (String) -> Bool = { _ in false }
    @ObservationIgnored var cancel: () -> Void = {}
    /// ⌘⏎ in Home's composer: the Vault, searching for the text.
    @ObservationIgnored var search: ((String) -> Void)?
    /// Shows the text again after a save that failed once the box had let it go.
    @ObservationIgnored var restore: () -> Void = {}
}

/// The text field, its error and its footer, shared by the capture box and Home's composer: the
/// same words, keys, secret-scanner error and Cloud chip (04-ux-mac.md ▸ Capture box, Home).
struct CaptureField: View {
    enum Style { case box, home }

    @Bindable var box: CaptureBoxModel
    let style: Style
    @FocusState private var focused: Bool

    private var placeholder: String {
        style == .box ? String(localized: "What should Funes remember?") : String(localized: "Tell me something, or search what I know…")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if box.text.isEmpty {
                    Text(placeholder)
                        .font(.title3).foregroundStyle(.tertiary).padding(.top, 1).accessibilityHidden(true)
                }
                TextField("", text: $box.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(style == .box ? 1...8 : 1...5)
                    .focused($focused)
                    .accessibilityLabel(String(localized: "What should Funes remember?"))
                    .accessibilityHint(style == .home ? String(localized: "Return remembers it. Command-Return searches your vault.") : "")
                    .onKeyPress(keys: [.return]) { press in
                        if press.modifiers.contains(.shift) {
                            box.text += "\n"
                            return .handled
                        }
                        // ⌘⏎ searches from Home; in the capture box it saves, as ⏎ does.
                        if press.modifiers.contains(.command), let search = box.search {
                            search(box.text)
                            return .handled
                        }
                        _ = box.save(box.text)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard style == .box else { return .ignored }
                        box.cancel()
                        return .handled
                    }
            }
            if style == .home {
                HStack(spacing: 10) {
                    Spacer()
                    if #available(macOS 26, *) { DictationButton(box: box) }
                    Button(String(localized: "Remember")) { _ = box.save(box.text) }
                        .buttonStyle(.borderedProminent)
                        .disabled(box.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let error = box.error {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red).font(.callout)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if style == .box { footer }
        }
        .onChange(of: box.error) { _, error in
            if let error {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
        .onChange(of: box.focusRequest, initial: true) { _, _ in focused = true }
    }

    /// "⏎ Save · ⇧⏎ New line · Esc Cancel" and where it goes, with the Cloud chip.
    var footer: some View {
        CaptureFooter(cloudProvider: box.cloudProvider, keys: style == .box ? String(localized: "⏎ Save · ⇧⏎ New line · Esc Cancel")
                                                     : String(localized: "⏎ Remember · ⌘⏎ Search vault"))
    }
}

/// The keys, then "Goes to your Inbox", or "… · fields suggested by Anthropic" with a Cloud chip
/// while a cloud model proposes the fields (principle 7).
struct CaptureFooter: View {
    let cloudProvider: String?
    let keys: String
    var centered = false
    /// The menu bar panel's narrow field: "Goes to your Inbox" and the Cloud chip, the provider in its tooltip.
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Text(keys).foregroundStyle(.secondary)
            if centered {
                Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true)
            } else {
                Spacer()
            }
            if let provider = cloudProvider {
                Text(compact ? String(localized: "Goes to your Inbox") : String(localized: "Goes to your Inbox · fields suggested by \(provider)"))
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Fields suggested by \(provider)"))
                Text(String(localized: "Cloud"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .accessibilityLabel(String(localized: "Leaves this Mac"))
            } else {
                Text(String(localized: "Goes to your Inbox")).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}

/// "What should Funes remember?" with ⏎ Save · ⇧⏎ New line · Esc Cancel (04-ux-mac.md).
struct CaptureBox: View {
    @Bindable var box: CaptureBoxModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CaptureField(box: box, style: .box)
            if #available(macOS 26, *) { DictationButton(box: box) }
        }
        .padding(18)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5))
    }
}
