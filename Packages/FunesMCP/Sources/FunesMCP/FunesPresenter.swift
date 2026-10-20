import Foundation
import FunesCore
import FunesProtocol

/// What the MCP side needs from the app's UI. The app shows the panels (BridgeUI); the
/// FUNES_MCP_TEST server answers them from its control channel.
public protocol FunesPresenter: Sendable {
    /// A request is waiting for the user: show the Share panel. It counts down 45 s on its own;
    /// after that the request stays in Pending requests for 15 minutes.
    func showApproval(requestID: UUID, agentID: UUID) async
    /// The same, saying whether the call came through Remote Access, so the panel can say "via
    /// Remote Access" under the agent's name. Nothing else about the panel changes.
    func showApproval(requestID: UUID, agentID: UUID, remote: Bool) async
    /// A suggestion went to the Inbox: show the non-blocking Save panel.
    func showSuggestion(suggestionID: UUID, agentID: UUID) async
    /// `open_in_funes`, already checked to be this agent's pending item.
    func open(requestID: UUID) async
    func open(suggestionID: UUID) async
    /// "<Agent> wants more access" (access policy §7, FR-A-10): ask, and return the answer, or
    /// `.unanswered` when `prompt.expiresAt` passes or the panel is withdrawn. FunesCore limits this
    /// to once an hour per agent, category and operation; an unanswered offer doesn't count.
    func askForAccess(_ prompt: AccessPrompt) async -> AccessAnswer
}

extension FunesPresenter {
    public func showApproval(requestID: UUID, agentID: UUID, remote: Bool) async {
        await showApproval(requestID: requestID, agentID: agentID)
    }
}

/// What the access-request panel asks about.
public struct AccessPrompt: Sendable, Hashable {
    public var agentID: UUID
    /// The category it can't read or suggest in; nil when an operation is missing.
    public var categoryKey: String?
    public var operation: AccessOperation
    /// The task it asked with (reads), shown as reported.
    public var task: String?
    public var expiresAt: Date
    /// False when the agent already has its answer (a request shared without asking): Allow Once
    /// can't apply, so the panel offers Not Now and Always Allow only.
    public var allowsOnce: Bool

    public init(agentID: UUID, categoryKey: String?, operation: AccessOperation, task: String?, expiresAt: Date,
                allowsOnce: Bool = true) {
        self.agentID = agentID
        self.categoryKey = categoryKey
        self.operation = operation
        self.task = task
        self.expiresAt = expiresAt
        self.allowsOnce = allowsOnce
    }
}

public enum AccessAnswer: String, Sendable {
    /// Not Now: not asked again for an hour.
    case notNow
    /// No answer in time, or the panel was withdrawn: treated as Not Now, but the next request may
    /// ask again (the user may never have seen it).
    case unanswered
    /// This request only (a grant bound to it and the agent's revision).
    case allowOnce
    /// Adds exactly that category, or that operation, to the agent's access.
    case alwaysAllow
}
