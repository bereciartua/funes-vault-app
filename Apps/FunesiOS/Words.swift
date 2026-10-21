import FunesPhone
import FunesProtocol
import SwiftUI

// The vault's words on the iPhone, the same as the Mac's (Apps/FunesMac/Support/UIComponents.swift).

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

    var explanation: String {
        switch self {
        case .public: String(localized: "Fine for anyone to know.")
        case .low: String(localized: "Everyday preferences. Fine for most of your agents.")
        case .internal: String(localized: "Work or project context. Share with agents you use for that work.")
        case .sensitive: String(localized: "Personal: health, money, family. Share rarely, and always ask.")
        case .restricted: String(localized: "Very personal. Only for agents you fully trust, and always ask.")
        case .secret: String(localized: "Never shared with agents unless you raise an agent's sensitivity limit to Secret.")
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

extension MemoryStatus {
    /// Search's scopes.
    var scopeTitle: String {
        switch self {
        case .active: String(localized: "Active")
        case .archived: String(localized: "Archived")
        case .deleted: String(localized: "Recently Deleted")
        }
    }
}

extension ConnectionRoute {
    var title: String {
        switch self {
        case .wifi: String(localized: "Wi-Fi")
        case .vpn: String(localized: "VPN")
        case .tailscale: String(localized: "Tailscale")
        case .tunnel: String(localized: "Tunnel")
        }
    }
}

/// "Internal", tinted, read as "Sensitivity: Internal" (UX: iPhone, Accessibility).
struct SensitivityBadge: View {
    let sensitivity: Sensitivity

    var body: some View {
        Text(sensitivity.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(sensitivity.tint)
            .background(sensitivity.tint.opacity(0.15), in: Capsule())
            .accessibilityLabel("Sensitivity: \(sensitivity.title)")
    }
}

/// A memory's categories, as names.
struct CategoryChips: View {
    let keys: [String]
    let categories: CategoryList

    var body: some View {
        ForEach(keys, id: \.self) { key in
            Text(categories.name(key))
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }
}
