import Foundation
import FunesCore
import FunesProtocol

/// One Activity row as the screen shows it (FR-L-02): what happened and its result, from the
/// stored ids, codes and counts only. Titles are looked up live when shown.
struct ActivityEntry: Identifiable, Equatable {
    let id: String
    let event: ActivityEvent

    enum Kind: String, CaseIterable, Identifiable {
        case all, shared, suggestions, problems, remote
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .shared: String(localized: "Shared")
            case .suggestions: String(localized: "Suggestions")
            case .problems: String(localized: "Problems")
            case .remote: String(localized: "Remote Access")
            }
        }
    }

    var time: Date { event.time }
    var agentID: UUID? { Self.id(in: event.actor, prefix: "agent:") }
    var deviceID: UUID? { Self.id(in: event.actor, prefix: "device:") }

    static func id(in actor: String, prefix: String) -> UUID? {
        actor.hasPrefix(prefix) ? UUID(uuidString: String(actor.dropFirst(prefix.count))) : nil
    }

    /// Memories released by this row.
    var sharedCount: Int {
        switch (event.event, event.outcome) {
        case ("request_memory", "fulfilled"), ("get_memory_request", "delivered"): event.ids.count
        default: 0
        }
    }

    var isShared: Bool {
        sharedCount > 0 || (event.event == "approval" && event.approval == .approved)
    }

    var isSuggestion: Bool {
        ["suggest_memory", "capture", "suggestion_applied", "suggestion_rejected", "seed_question", "import"].contains(event.event)
    }

    /// Refusals by policy, rate limits, expired requests; a user's own No isn't a problem.
    var isProblem: Bool {
        guard let reason = event.reason else { return event.outcome == "denied" && event.event != "approval" }
        return ![.deniedByUser, .allowed, .allowedByWindow, .confirmationRequired].contains(reason)
    }

    func matches(_ kind: Kind) -> Bool {
        switch kind {
        case .all: true
        case .shared: isShared
        case .suggestions: isSuggestion
        case .problems: isProblem
        case .remote: isRemote
        }
    }

    /// A call through Remote Access, from a cloud agent (ADR-0018).
    var isRemote: Bool { event.via == .remote }

    // MARK: Words

    /// "Shared 3 memories", "Refused", "Suggested a memory".
    var label: String {
        let e = event
        switch e.event {
        case "request_memory":
            switch e.outcome {
            case "fulfilled": return Self.shared(e.ids.count)
            case "needs_approval": return String(localized: "Asked for memories")
            default: return String(localized: "Refused a request")
            }
        case "get_memory_request":
            return e.outcome == "delivered" ? Self.shared(e.ids.count) : String(localized: "Checked a request")
        case "approval":
            switch e.approval {
            case .approved: return String(localized: "You approved sharing \(e.counts["approved"] ?? 0)")
            case .denied: return String(localized: "You denied a request")
            case .timeout: return String(localized: "Request expired")
            default: return String(localized: "Request answered")
            }
        case "suggest_memory":
            switch e.outcome {
            case "saved": return String(localized: "Saved a memory")
            case "queued": return String(localized: "Suggested a memory")
            default: return String(localized: "Suggestion refused")
            }
        case "list_memory_categories": return String(localized: "Listed categories")
        case "open_in_funes": return String(localized: "Opened a request in Funes")
        case "capture": return String(localized: "Captured a note")
        case "seed_question": return String(localized: "Answered a question")
        case "suggestion_applied": return String(localized: "You applied a suggestion")
        case "suggestion_rejected": return String(localized: "You rejected a suggestion")
        case "memory_created": return String(localized: "Created a memory")
        case "memory_edited": return String(localized: "Edited a memory")
        case "agent_added": return String(localized: "Agent added")
        case "agent_removed": return String(localized: "Agent removed")
        case "agent_paused": return String(localized: "Agent paused")
        case "agent_resumed": return String(localized: "Agent resumed")
        case "access_changed": return String(localized: "Access changed")
        case "key_rotated": return String(localized: "Key rotated")
        case "cloud_access_on": return String(localized: "Cloud access turned on")
        case "cloud_access_off": return String(localized: "Cloud access turned off")
        case "remote_key_issued": return String(localized: "Remote token issued")
        case "cloud_apps_changed": return String(localized: "Connected cloud apps changed")
        case "funes_paused": return String(localized: "Funes Vault paused")
        case "funes_resumed": return String(localized: "Funes Vault resumed")
        case "import": return String(localized: "Imported \((e.counts["suggestions"] ?? 0) + (e.counts["memories"] ?? 0)) items")
        case "export": return String(localized: "Exported the vault")
        case "access_request": return String(localized: "Asked for more access")
        default: return e.event.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func shared(_ count: Int) -> String {
        count == 1 ? String(localized: "Shared 1 memory") : String(localized: "Shared \(count) memories")
    }

    /// The Result column: "Approved by you", "Category not allowed", "Waiting in Inbox".
    var result: (text: String, tone: Pill.Tone) {
        let e = event
        if let reason = e.reason, isProblem || e.outcome == "denied" {
            return (Self.reasonText(reason), reason == .deniedByUser ? .neutral : .bad)
        }
        switch (e.event, e.outcome) {
        case ("request_memory", "fulfilled"):
            return e.approval == .notRequired ? (String(localized: "Shared without asking"), .good) : (String(localized: "Shared"), .good)
        case ("request_memory", "needs_approval"): return (String(localized: "Waiting for you"), .accent)
        case ("get_memory_request", "delivered"): return (String(localized: "Approved by you"), .good)
        case ("approval", _):
            switch e.approval {
            case .approved: return (String(localized: "Approved"), .good)
            case .denied: return (String(localized: "Denied by you"), .neutral)
            default: return (String(localized: "Expired"), .warning)
            }
        case ("suggest_memory", "queued"), ("capture", _), ("seed_question", _): return (String(localized: "Waiting in Inbox"), .accent)
        case ("suggest_memory", "saved"): return (String(localized: "Saved"), .good)
        case ("suggestion_applied", _): return (String(localized: "Applied"), .good)
        case ("suggestion_rejected", _): return (String(localized: "Rejected"), .neutral)
        default: return (e.outcome.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? String(localized: "Done"), .neutral)
        }
    }

    /// The reason codes in the user's words (access-policy.md §8).
    static func reasonText(_ reason: ReasonCode) -> String {
        switch reason {
        case .funesPaused: String(localized: "Funes was paused")
        case .agentPaused: String(localized: "Agent paused")
        case .accessExpired: String(localized: "Access expired")
        case .operationNotAllowed: String(localized: "Not allowed to do this")
        case .noMatchingMemories: String(localized: "Nothing relevant")
        case .inactiveMemory: String(localized: "Archived")
        case .expiredMemory: String(localized: "Expired memory")
        case .aboveSensitivityCeiling: String(localized: "Above its sensitivity limit")
        case .deniedCategory: String(localized: "Category denied")
        case .categoryNotAllowed: String(localized: "Category not allowed")
        case .noAllowedMemories: String(localized: "Matches, none allowed")
        case .confirmationRequired: String(localized: "Waiting for you")
        case .allowed: String(localized: "Shared without asking")
        case .allowedByWindow: String(localized: "Shared without asking")
        case .deniedByUser: String(localized: "Denied by you")
        case .approvalExpired: String(localized: "No answer in 15 minutes")
        case .policyChanged: String(localized: "Changed since approval")
        case .alreadyDelivered: String(localized: "Already delivered")
        case .notFound: String(localized: "Not found")
        case .invalidInput: String(localized: "Invalid input")
        case .unknownCategory: String(localized: "Unknown category")
        case .secretLikeContent: String(localized: "Looked like a secret")
        case .rateLimited: String(localized: "Too many requests")
        case .funesQuit: String(localized: "Funes was quitting")
        }
    }
}
