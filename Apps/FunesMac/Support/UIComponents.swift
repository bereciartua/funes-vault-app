import AppKit
import FunesCore
import FunesProtocol
import SwiftUI

// Shared pieces, after EK Bridge's UIComponents (BridgeUI/Upstream/UIComponents.swift): cards,
// pills and the palette, with Funes's sensitivity badges.

enum Palette {
    /// Card surface: white in light mode, raised grey in dark mode; stronger with Increase Contrast.
    static let card = Color(nsColor: adaptive(light: .white, dark: NSColor(white: 0.17, alpha: 1),
                                              lightContrast: .white, darkContrast: NSColor(white: 0.12, alpha: 1)))
    /// Behind the cards.
    static let pane = Color(nsColor: adaptive(light: NSColor(white: 0.962, alpha: 1), dark: NSColor(white: 0.115, alpha: 1),
                                              lightContrast: NSColor(white: 0.93, alpha: 1), darkContrast: .black))
    static let separator = Color(nsColor: .separatorColor)
    /// A warning icon's orange: darker than system orange in light mode, so the icon keeps 3:1 on
    /// white, and darker again with Increase Contrast. Warning text stays primary.
    static let warning = Color(nsColor: adaptive(light: NSColor(srgbRed: 0.80, green: 0.40, blue: 0, alpha: 1),
                                                 dark: .systemOrange,
                                                 lightContrast: NSColor(srgbRed: 0.64, green: 0.32, blue: 0, alpha: 1),
                                                 darkContrast: NSColor(srgbRed: 1, green: 0.70, blue: 0.25, alpha: 1)))

    private static func adaptive(light: NSColor, dark: NSColor, lightContrast: NSColor, darkContrast: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: dark
            case .accessibilityHighContrastDarkAqua: darkContrast
            case .accessibilityHighContrastAqua: lightContrast
            default: light
            }
        }
    }
}

/// A rounded group like System Settings.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.separator.opacity(contrast == .increased ? 1 : 0.6),
                              lineWidth: contrast == .increased ? 1 : 0.5))
    }
}

/// A warning: an orange icon and primary text (orange text on white is under 3:1).
struct WarningLabel: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Palette.warning)
        }
        .font(.callout)
    }
}

/// A small capsule with text: a result, a status, a category.
struct Pill: View {
    enum Tone { case neutral, good, warning, bad, accent }
    let label: String
    var tone: Tone = .neutral
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(Capsule().fill(color.opacity(contrast == .increased ? 0.32 : 0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(contrast == .increased ? 0.9 : 0), lineWidth: 1))
    }

    private var color: Color {
        switch tone {
        case .neutral: .secondary
        case .good: .green
        case .warning: .orange
        case .bad: .red
        case .accent: .accentColor
        }
    }

    private var foreground: Color { tone == .neutral ? .secondary : .primary }
}

extension Sensitivity {
    /// "Low", "Internal"… for badges and pickers.
    var title: String {
        switch self {
        case .public: String(localized: "Public")
        case .low: String(localized: "Low")
        case .internal: String(localized: "Internal")
        case .sensitive: String(localized: "Sensitive")
        case .restricted: String(localized: "Restricted")
        case .secret: String(localized: "Secret")
        }
    }

    /// The one-line explanations (04-ux-mac.md, FR-V-07).
    var explanation: String {
        switch self {
        case .public: String(localized: "Fine for anyone to know.")
        case .low: String(localized: "Everyday preferences. Fine for most of your agents.")
        case .internal: String(localized: "Work or project context. Share with agents you use for that work.")
        case .sensitive: String(localized: "Personal: health, money, family. Share rarely, and always ask.")
        case .restricted: String(localized: "Very personal. Only for agents you fully trust, and always ask.")
        case .secret: String(localized: "Never shared with agents unless you raise an agent's ceiling to Secret.")
        }
    }

    var tint: Color {
        switch self {
        case .public: .gray
        case .low: .green
        case .internal: .blue
        case .sensitive: .orange
        case .restricted: .red
        case .secret: .purple
        }
    }
}

/// The sensitivity badge: the level's color in the fill and primary text, so the name reads at
/// 4.5:1 or better (color is never the only cue).
struct SensitivityBadge: View {
    let sensitivity: Sensitivity
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(sensitivity.title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.3)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.primary)
            .background(Capsule().fill(sensitivity.tint.opacity(contrast == .increased ? 0.30 : 0.18)))
            .overlay(Capsule().strokeBorder(sensitivity.tint.opacity(contrast == .increased ? 0.9 : 0), lineWidth: 1))
            .accessibilityLabel(String(localized: "Sensitivity: \(sensitivity.title)"))
    }
}

extension MemoryKind {
    var title: String {
        switch self {
        case .fact: String(localized: "Fact")
        case .preference: String(localized: "Preference")
        case .instruction: String(localized: "Instruction")
        case .goal: String(localized: "Goal")
        case .projectContext: String(localized: "Project Context")
        case .relationship: String(localized: "Relationship")
        case .constraint: String(localized: "Constraint")
        case .event: String(localized: "Event")
        case .summary: String(localized: "Summary")
        }
    }

    var symbol: String {
        switch self {
        case .fact: "info.circle"
        case .preference: "heart"
        case .instruction: "list.bullet.clipboard"
        case .goal: "flag"
        case .projectContext: "folder"
        case .relationship: "person.2"
        case .constraint: "exclamationmark.triangle"
        case .event: "calendar"
        case .summary: "text.alignleft"
        }
    }
}

extension MemorySource {
    var title: String {
        switch self {
        case .manual: String(localized: "Added by you")
        case .captureMac: String(localized: "Captured on this Mac")
        case .captureIPhone: String(localized: "Captured on iPhone")
        case .agentSuggestion: String(localized: "Suggested by an agent")
        case .agentWrite: String(localized: "Saved by an agent")
        case .importChatGPT: String(localized: "Imported from ChatGPT")
        case .importClaude: String(localized: "Imported from Claude")
        case .importMarkdown: String(localized: "Imported from Markdown")
        case .importFunes: String(localized: "Imported from a Funes export")
        case .seedQuestion: String(localized: "Answered a question")
        }
    }
}

enum RelativeTime {
    /// "2 min ago", "yesterday".
    static func short(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func full(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}

/// The title row of a section, with room for controls on the right.
struct PaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

/// A user-facing message for a vault error. Never includes memory text: only field names and
/// pattern types.
enum ErrorText {
    static func message(_ error: Error) -> String {
        guard let error = error as? VaultError else { return String(localized: "Something went wrong. Try again.") }
        switch error {
        case .invalidInput(let field):
            switch field {
            case "title": return String(localized: "The title needs 1 to 180 characters.")
            case "body": return String(localized: "The text needs 1 to 10,000 characters.")
            case "name": return String(localized: "The name needs 1 to 60 characters.")
            case "key": return String(localized: "That name can't be used for a category.")
            case "categories": return String(localized: "A memory can have at most 12 categories.")
            default: return String(localized: "Something in this form isn't valid.")
            }
        case .secretLikeContent(let patterns): return SecretText.message(patterns)
        case .unknownCategory: return String(localized: "That category no longer exists.")
        case .noCategories: return String(localized: "Choose at least one category.")
        case .builtinCategory: return String(localized: "Built-in categories can be renamed but not deleted.")
        case .categoryExists: return String(localized: "A category with that name already exists.")
        case .categoryInUse: return String(localized: "Some memories are only in this category. Choose a replacement.")
        case .onlyAllowedCategory: return String(localized: "It's the only category some agents may read. Choose a replacement, or change those agents first.")
        case .nameTaken: return String(localized: "Another agent already has that name.")
        case .notFound: return String(localized: "It was deleted or changed elsewhere.")
        case .invalidState: return String(localized: "It changed in the meantime. Look again and retry.")
        case .snapshotChanged: return String(localized: "This request changed; review again.")
        case .newerSchema: return String(localized: "This vault was written by a newer Funes Vault. Update the app.")
        case .unsafeFile: return String(localized: "A vault file has unsafe permissions.")
        case .unauthenticated: return String(localized: "Not allowed.")
        case .revisionChanged: return String(localized: "It changed in the meantime. Review it again.")
        case .versionConflict: return String(localized: "It changed in the meantime. Look again and retry.")
        }
    }
}

enum SecretText {
    /// "This looks like an API key. Funes never stores secrets."
    static func message(_ patterns: [SecretPattern]) -> String {
        let kind = patterns.first.map(name) ?? String(localized: "a secret")
        return String(localized: "This looks like \(kind). Funes never stores secrets.")
    }

    static func name(_ pattern: SecretPattern) -> String {
        switch pattern {
        case .creditCard: String(localized: "a card number")
        case .privateKey: String(localized: "a private key")
        case .jwt: String(localized: "a sign-in token")
        case .assignedSecret: String(localized: "a password or secret")
        case .funesOrEKBKey: String(localized: "an agent key")
        default: String(localized: "an API key")
        }
    }
}
