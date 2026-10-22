import Foundation
import FunesProtocol

/// The words of approvals on the iPhone (task 5.6), shared by the app and its notification
/// service extension. The Mac sends data, not text (companion protocol §4.1); these say it as
/// the Mac's panels do (`FunesApprovals`, BridgeUI's `PanelItem.share`). They resolve in the
/// running app's or extension's own String Catalog, which `scripts/sync_strings.sh` fills from
/// this file too.
public enum ApprovalWording {
    /// The subscription's fixed alert, set on the phone when it subscribes (ADR-0019 §2). It's
    /// what shows when the extension can't run or says nothing better.
    public static var generic: String { String(localized: "You have a request") }

    /// The panel's and the notification's title: "Claude Code wants 3 memories", "Cursor wants to
    /// read Project context", "Claude suggests a memory".
    public static func title(_ detail: ApprovalDetail) -> String {
        let agent = detail.agentName
        switch detail.kind {
        case .share:
            let count = detail.share?.rows.count ?? 0
            return count == 1 ? String(localized: "\(agent) wants 1 memory") : String(localized: "\(agent) wants \(count) memories")
        case .save:
            switch (detail.save?.action, detail.save?.targetMemoryId) {
            case (.archive?, _): return String(localized: "\(agent) suggests archiving a memory")
            case (_, _?), (.update?, nil): return String(localized: "\(agent) suggests a correction")
            default: return String(localized: "\(agent) suggests a memory")
            }
        case .access:
            return accessTitle(agent: agent, operation: detail.access?.operation ?? .read, category: detail.access?.categoryName)
        }
    }

    /// A list row's title, from the summary alone.
    public static func title(_ summary: ApprovalSummary) -> String {
        let agent = summary.agentName
        switch summary.kind {
        case .share:
            return summary.count == 1 ? String(localized: "\(agent) wants 1 memory")
                                      : String(localized: "\(agent) wants \(summary.count) memories")
        case .save: return String(localized: "\(agent) suggests a memory")
        case .access: return String(localized: "\(agent) wants more access")
        }
    }

    /// As the Mac's access panel words it (`FunesApprovals.accessItem`).
    public static func accessTitle(agent: String, operation: AccessOperation, category: String?) -> String {
        switch (operation, category) {
        case (.read, let name?): String(localized: "\(agent) wants to read \(name)")
        case (_, let name?): String(localized: "\(agent) wants to add to \(name)")
        case (.read, nil): String(localized: "\(agent) wants to read your memories")
        case (_, nil): String(localized: "\(agent) wants to suggest memories")
        }
    }

    /// The Save panel's heading and the line under it, as on the Mac.
    public static func saveHeading(_ save: SavePanel) -> String {
        save.targetMemoryId == nil ? String(localized: "Save this memory?") : String(localized: "Save this correction?")
    }

    public static func saveSubtitle(agent: String) -> String {
        String(localized: "From \(agent). It's in your Inbox either way.")
    }

    /// Always Allow, saying exactly what it adds (UX review F1).
    public static func alwaysAllow(agent: String, operation: AccessOperation, category: String?) -> String {
        switch (operation, category) {
        case (.read, let name?): String(localized: "Always Allow \(agent) to Read \(name)")
        case (_, let name?): String(localized: "Always Allow \(agent) to Add to \(name)")
        case (.read, nil): String(localized: "Always Allow \(agent) to Read")
        case (_, nil): String(localized: "Always Allow \(agent) to Suggest")
        }
    }

    /// The access panel's line under the title, as on the Mac.
    public static func accessSubtitle(_ access: AccessPanel) -> String {
        if !access.allowsOnce {
            return String(localized: "It already got what it may read. Always Allow is for next time.")
        }
        if access.operation == .read, access.categoryName != nil {
            return access.asksBeforeSharing
                ? String(localized: "Allow Once is for this request only. Next, you'll see exactly what would be shared.")
                : String(localized: "Allow Once is for this request only. It shares without asking, so the matching memories go to it at once.")
        }
        return String(localized: "Allow Once is for this request only. The suggestion still waits in your Inbox.")
    }

    /// The notification's line under the title, for a request it could fetch. Never any memory
    /// text: the lock screen shows it.
    public static func alertBody(_ kind: ApprovalKind) -> String {
        switch kind {
        case .share: String(localized: "Open to see exactly what would be shared.")
        case .save: String(localized: "Open to save or discard it.")
        case .access: String(localized: "Open to answer. The agent is waiting.")
        }
    }

    /// The Goes to line, from what the Mac knows (`FunesApprovals.destination`).
    public static func destination(agent: String, _ destination: ApprovalDestination) -> String {
        guard destination.remote else {
            return String(localized: "\(agent) on your Mac. It may send what it reads to its AI service.")
        }
        return switch (destination.tunnel, destination.vendor) {
        case let (tunnel?, vendor?): String(localized: "\(agent), through your \(tunnel), to \(vendor)'s servers")
        case let (nil, vendor?): String(localized: "\(agent), through Remote Access, to \(vendor)'s servers")
        case let (tunnel?, nil): String(localized: "\(agent), a cloud agent, through your \(tunnel)")
        case (nil, nil): String(localized: "\(agent), a cloud agent, through Remote Access")
        }
    }

    /// "Keeps what it gets": `AgentText.retention` on the Mac.
    public static func retention(_ retention: Retention) -> String {
        switch retention {
        case .none: String(localized: "Not at all")
        case .session: String(localized: "For the session")
        case .persistent: String(localized: "Beyond the session")
        case .unknown: String(localized: "Not said")
        }
    }

    /// "2 more matched but can't go to this agent (1 above its sensitivity limit, …)." Nil when
    /// nothing was withheld. Grouped as `FunesApprovals.withheldReasons` groups it.
    public static func withheld(_ withheld: [ReasonCode: Int]) -> String? {
        let held = withheld.values.reduce(0, +)
        guard held > 0 else { return nil }
        let reasons = withheld.sorted { $0.key.rawValue < $1.key.rawValue }.map { reason, count in
            switch reason {
            case .aboveSensitivityCeiling: String(localized: "\(count) above its sensitivity limit")
            case .deniedCategory, .categoryNotAllowed: String(localized: "\(count) in categories it can't read")
            case .expiredMemory: String(localized: "\(count) expired")
            default: String(localized: "\(count) not shareable")
            }
        }.joined(separator: ", ")
        return String(localized: "\(held) more matched but can't go to this agent (\(reasons)).")
    }

    /// A panel that can't be answered any more, or an answer that went through.
    public static func closed(_ reason: ApprovalPanelModel.Closed) -> String {
        switch reason {
        case let .answered(choice, count):
            switch choice {
            case .share: count == 1 ? String(localized: "Shared 1 memory.") : String(localized: "Shared \(count) memories.")
            case .deny: String(localized: "Denied.")
            case .save: String(localized: "Saved.")
            case .discard: String(localized: "Discarded.")
            case .allowOnce: String(localized: "Allowed once.")
            case .alwaysAllow: String(localized: "Always allowed.")
            case .notNow: String(localized: "Not now.")
            }
        case .answeredOnMac: String(localized: "Answered on your Mac")
        case .alreadyAnswered: String(localized: "Already answered")
        case .expired: String(localized: "This request expired")
        case .gone: String(localized: "This request is no longer waiting")
        }
    }
}
