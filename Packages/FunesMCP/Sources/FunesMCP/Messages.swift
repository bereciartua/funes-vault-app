import Foundation
import FunesProtocol

/// The `message` an agent gets with each outcome: short, user-safe guidance. Wording from
/// Spike 3: an explicit sentence to relay, then what to call and when.
enum Messages {
    static func needsApproval(_ requestID: String) -> String {
        "Tell the user: \"Waiting for your approval in Funes.\" Then call get_memory_request with request_id "
            + "\"\(requestID)\" in about a minute; it expires in 15 minutes."
    }

    static func delivered(_ count: Int) -> String {
        count == 1 ? "Here is 1 memory, shared once for this task." : "Here are \(count) memories, shared once for this task."
    }

    static func quit(_ requestID: String) -> String {
        "Funes Vault was quit before the user answered. Tell the user. If Funes is open again within 15 minutes, "
            + "call get_memory_request with request_id \"\(requestID)\"; otherwise make a new request."
    }

    static func rateLimited(_ seconds: Int) -> String {
        "Too many requests from this agent. Wait \(seconds) s before trying again."
    }

    static func text(for reason: ReasonCode) -> String {
        switch reason {
        case .funesPaused: "Funes Vault is paused. Tell the user; they can resume it from the menu bar."
        case .agentPaused: "The user paused this agent in Funes. Tell the user instead of retrying."
        case .accessExpired: "This agent's access in Funes has expired. Tell the user; they can renew it in Funes."
        case .operationNotAllowed: "This agent isn't allowed to do that in Funes. Tell the user if it's needed."
        case .noMatchingMemories: "No memories matched this task. Continue without personal context."
        case .noAllowedMemories: "Memories matched, but none may be shared with this agent. Continue without them."
        case .confirmationRequired: "Waiting for the user to approve in Funes."
        case .deniedByUser:
            "The user declined to share these memories. Don't ask again for this task unless the user asks you to."
        case .approvalExpired: "The request expired before it was delivered. Make a new request if you still need it."
        case .policyChanged: "Something changed in Funes since the user approved. Make a new request if you still need it."
        case .alreadyDelivered: "These memories were already delivered once; use the copy you received."
        case .notFound: "No such request or suggestion for this agent."
        case .invalidInput: "The input isn't valid."
        case .unknownCategory: "A category key doesn't exist. Call list_memory_categories for the keys."
        case .secretLikeContent: "This looks like it contains a secret, so it wasn't saved. Never send keys or passwords."
        case .aboveSensitivityCeiling: "That's above the sensitivity this agent may save. Use a lower sensitivity or skip it."
        case .deniedCategory, .categoryNotAllowed:
            "This agent may not save memories in that category. Tell the user if it's needed."
        case .rateLimited: "Too many requests from this agent. Wait before trying again."
        case .funesQuit: "Funes Vault is quitting. Tell the user; try again once it's open."
        case .inactiveMemory, .expiredMemory, .allowed, .allowedByWindow:
            "Not shared."
        }
    }
}
