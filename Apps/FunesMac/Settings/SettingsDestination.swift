import Foundation

/// A Settings pane (ADR-0030 §2, 04-ux-mac.md ▸ Settings): the profile row, then eleven panes in
/// four groups. The raw value is the destination's first part.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case aboutYou = "about-you"
    case general, notifications, capture
    case features = "ai.features"
    case accounts = "ai.accounts"
    case privacy = "ai.privacy"
    case agentServer = "agent-server"
    case iphone, data, advanced
    var id: String { rawValue }

    /// The sidebar's groups, in order; the first has no header.
    enum Group: CaseIterable {
        case app, ai, connections, vault

        var title: String? {
            switch self {
            case .app: nil
            case .ai: String(localized: "AI")
            case .connections: String(localized: "Connections")
            case .vault: String(localized: "Vault")
            }
        }

        var panes: [SettingsPane] {
            switch self {
            case .app: [.general, .notifications, .capture]
            case .ai: [.features, .accounts, .privacy]
            case .connections: [.agentServer, .iphone]
            case .vault: [.data, .advanced]
            }
        }
    }

    var title: String {
        switch self {
        case .aboutYou: String(localized: "About You")
        case .general: String(localized: "General")
        case .notifications: String(localized: "Notifications")
        case .capture: String(localized: "Capture & Shortcuts")
        case .features: String(localized: "Features")
        case .accounts: String(localized: "Models & Accounts")
        case .privacy: String(localized: "Privacy & Limits")
        case .agentServer: String(localized: "Agent Server")
        case .iphone: String(localized: "iPhone")
        case .data: String(localized: "Data & Backups")
        case .advanced: String(localized: "Advanced")
        }
    }

    var symbol: String {
        switch self {
        case .aboutYou: "person.crop.circle"
        case .general: "gearshape"
        case .notifications: "bell.badge"
        case .capture: "square.and.pencil"
        case .features: "sparkles"
        case .accounts: "key"
        case .privacy: "hand.raised"
        case .agentServer: "point.3.connected.trianglepath.dotted"
        case .iphone: "iphone"
        case .data: "externaldrive"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// A page inside a pane (ADR-0030 §1): a job's page in Features, or an account's in Models &
/// Accounts (an API or local-server account's id, or a plan's: `claude-code`, `codex`).
enum SettingsPage: Hashable {
    case newMemories, tidyUp, searchAnswers, searchIndex
    case account(String)

    var pane: SettingsPane {
        switch self {
        case .newMemories, .tidyUp, .searchAnswers, .searchIndex: .features
        case .account: .accounts
        }
    }

    /// The part after the slash: `tidy-up`, `anthropic`.
    var rawValue: String {
        switch self {
        case .newMemories: "new-memories"
        case .tidyUp: "tidy-up"
        case .searchAnswers: "search-answers"
        case .searchIndex: "search-index"
        case let .account(id): id
        }
    }
}

/// Where Settings opens (ADR-0030 §9): a pane, or a page inside one. Written `ai.features/tidy-up`,
/// `ai.accounts/<account id>`; `FUNES_DEBUG_OPEN=settings:<destination>` and the deep links use the
/// same form.
struct SettingsDestination: Hashable {
    var pane: SettingsPane
    var page: SettingsPage?

    init(_ pane: SettingsPane) {
        self.pane = pane
        page = nil
    }

    init(_ page: SettingsPage) {
        pane = page.pane
        self.page = page
    }

    static let newMemories = SettingsDestination(.newMemories)
    static let tidyUp = SettingsDestination(.tidyUp)
    static let searchAnswers = SettingsDestination(.searchAnswers)
    static let searchIndex = SettingsDestination(.searchIndex)
    static func account(_ id: String) -> SettingsDestination { SettingsDestination(.account(id)) }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first, let pane = SettingsPane(rawValue: first) else { return nil }
        self.pane = pane
        guard parts.count > 1 else { page = nil; return }
        switch (pane, parts[1]) {
        case (.features, "new-memories"): page = .newMemories
        case (.features, "tidy-up"): page = .tidyUp
        case (.features, "search-answers"): page = .searchAnswers
        case (.features, "search-index"): page = .searchIndex
        case (.accounts, let id) where !id.isEmpty: page = .account(id)
        default: return nil
        }
    }

    var rawValue: String { page.map { "\(pane.rawValue)/\($0.rawValue)" } ?? pane.rawValue }

    /// For a snapshot's file name: `ai-features-tidy-up`.
    var safeName: String {
        String(rawValue.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }
}
