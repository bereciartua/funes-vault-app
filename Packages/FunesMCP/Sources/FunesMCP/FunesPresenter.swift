import Foundation

/// What the MCP side needs from the app's UI. The app shows the panels (BridgeUI); the
/// FUNES_MCP_TEST server answers them from its control channel.
public protocol FunesPresenter: Sendable {
    /// A request is waiting for the user: show the Share panel. It counts down 45 s on its own;
    /// after that the request stays in Pending requests for 15 minutes.
    func showApproval(requestID: UUID, agentID: UUID) async
    /// A suggestion went to the Inbox: show the non-blocking Save panel.
    func showSuggestion(suggestionID: UUID, agentID: UUID) async
    /// `open_in_funes`, already checked to be this agent's pending item.
    func open(requestID: UUID) async
    func open(suggestionID: UUID) async
}
