import AppKit
import SwiftUI

// Small pieces the Remote Access screens share, after EK Bridge's UIComponents
// (BridgeUI/Upstream/UIComponents.swift): rows inside a card, Copy and info buttons.

/// A hairline between rows inside a `Card(padding: 0)`.
struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
}

/// "Label    value …    actions", as in the Remote Access page's rows.
struct ValueRow<Value: View, Actions: View>: View {
    let label: String
    @ViewBuilder var value: Value
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Copies plain text (never a secret: those go through `SecretClipboard`).
struct CopyButton: View {
    let text: String
    var title: String?
    var help: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            if let title {
                Text(copied ? String(localized: "Copied") : title)
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An ⓘ that shows longer text in a popover.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "More information"))
            .popover(isPresented: $shown) {
                Text(text).padding(14).frame(width: 340, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
    }
}

/// A full-width row that highlights when pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

/// The prominent button of a row, when `on`.
struct Prominent: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent) } else { content }
    }
}

/// A key, token or secret on the clipboard: confirmed first by the caller, cleared after 90 s
/// unless something else was copied since (T25).
enum SecretClipboard {
    static let seconds = 90

    @MainActor
    static func copy(_ secret: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(secret, forType: .string)
        let count = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}

/// A guide's numbered steps: done ones checked, the current one highlighted.
struct GuideStepsHeader: View {
    let titles: [String]
    /// Index into `titles`; `titles.count` means all done.
    let current: Int
    /// The highlighted step, when it isn't `current` (a finished guide highlights its last step).
    var highlighted: Int? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                let done = index < current
                let isCurrent = index == (highlighted ?? current)
                HStack(spacing: 8) {
                    ZStack {
                        Circle().strokeBorder(done ? Color.green : isCurrent ? Color.primary : Color.secondary, lineWidth: 1.5)
                        if done {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                        } else {
                            Text("\(index + 1)").font(.caption.weight(.semibold))
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(title)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(done ? Color.green : isCurrent ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Step \(index + 1), \(title), \(done ? String(localized: "done") : isCurrent ? String(localized: "current") : String(localized: "not done"))"))
                if index < titles.count - 1 { Divider() }
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
}
