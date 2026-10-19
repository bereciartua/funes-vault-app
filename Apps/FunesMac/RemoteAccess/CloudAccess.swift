import AppKit
import BridgeKitRemote
import BridgeUI
import FunesCore
import FunesMCP
import FunesProtocol

// An agent's cloud access (04-ux-mac.md, the agent's Cloud section; ADR-0018): Allow cloud access,
// its remote token, its OAuth-connected cloud apps, pairing, and the sign-in panel's queue.
// Adapted from the cloud parts of EK Bridge's BridgeAppModel (e753b22).

/// Gemini Enterprise's OAuth client: the values to enter in its console. In memory only, while
/// its sheet is open; the store keeps only the secret's digest.
struct OAuthClientDetails: Identifiable, Equatable {
    let id = UUID()
    let agentID: UUID
    let clientID: String
    let secret: String
    let authorizationURL: String
    let tokenURL: String
    let redirectURI: String
}

extension AppModel {
    /// The agents with cloud access, for the Remote Access page and Switch Tunnel….
    func remoteCloudAgents() -> [RemoteCloudAgent] {
        agents.filter(\.cloudAccess).map { agent in
            RemoteCloudAgent(id: agent.id.db, name: agent.name, hasRemoteToken: agent.hasRemoteKey,
                             apps: connectedApps(agent.id).map(\.appName))
        }
    }

    func connectedApps(_ agentID: UUID) -> [OAuthConnectionView] {
        _ = cloudGeneration
        return remoteServer?.connectedApps(agentID: agentID) ?? []
    }

    /// "Token · claude.ai", for the Remote Access page's list.
    func cloudCredentialsLine(_ agent: Agent) -> String {
        var parts = [String]()
        if agent.hasRemoteKey { parts.append(String(localized: "Remote token")) }
        parts += connectedApps(agent.id).map(\.appName)
        return parts.isEmpty ? String(localized: "No credentials yet") : parts.joined(separator: " · ")
    }

    /// The Allow cloud access caption: what the agent can do from the internet. Its access is the
    /// same as on this Mac; nothing here changes it.
    func cloudSummary(_ agent: Agent) -> String {
        let access = agent.access
        guard !access.operations.isEmpty else {
            return String(localized: "This agent has no access yet, so cloud agents can't use anything.")
        }
        return String(localized: "Cloud agents can use this from the internet: \(AgentText.accessSummary(access, categories: categories)). It's the same access as on this Mac.")
    }

    // MARK: Allow cloud access

    /// Turning it off asks first when the agent has a remote token or connected apps: they stop
    /// working at once. Either way its revision goes up, so pending approvals end.
    func setCloudAccess(_ agent: Agent, _ on: Bool) {
        guard agent.cloudAccess != on, let remoteServer else { return }
        if !on, agent.hasRemoteKey || !connectedApps(agent.id).isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Turn off cloud access for “\(agent.name)”?")
            alert.informativeText = String(localized: "Its remote token and every connected cloud app stop working now. Its access on this Mac isn't affected.")
            let off = alert.addButton(withTitle: String(localized: "Turn Off"))
            off.hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "Cancel"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            do {
                try await remoteServer.setCloudAccess(agentID: agent.id, on)
            } catch {
                cloudMessage = ErrorText.message(error)
            }
            cloudGeneration += 1
            remoteAccess.agentsChanged()
            await refresh()
        }
    }

    /// Removing an agent ends its keys, remote token and connected apps.
    func removeAgent(_ agent: Agent) async throws {
        if let remoteServer {
            try await remoteServer.removeAgent(agentID: agent.id)
        } else {
            try await services.agents.remove(agentID: agent.id, now: Date())
        }
        cloudGeneration += 1
        remoteAccess.agentsChanged()
    }

    // MARK: Remote token

    /// Copy Remote Token…: asks first, creates the token the first time, and clears the clipboard
    /// after 90 s. Header-sending cloud agents need it pasted into their settings.
    func copyRemoteToken(_ agent: Agent) {
        guard agent.cloudAccess else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Copy the remote token for “\(agent.name)”?")
        alert.informativeText = String(localized: "Anyone with this token and the URL can use \(agent.name)'s access from the internet while Remote Access and Funes Vault are on. Paste it only into the cloud agent's settings. The clipboard is cleared in 90 seconds.")
        alert.addButton(withTitle: String(localized: "Copy Remote Token"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let token: String
                if agent.hasRemoteKey, let url = services.keys.remoteURL(agentID: agent.id),
                   let saved = try? String(contentsOf: url, encoding: .utf8),
                   saved.hasPrefix(Identifiers.remoteKeyPrefix) {
                    token = saved.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    guard let remoteServer else { return }
                    token = try await remoteServer.issueRemoteKey(agentID: agent.id).plaintext
                }
                SecretClipboard.copy(token)
                cloudMessage = String(localized: "Remote token copied. The clipboard is cleared in 90 seconds.")
            } catch {
                cloudMessage = ErrorText.message(error)
            }
            remoteAccess.agentsChanged()
            await refresh()
        }
    }

    /// Reset Remote Token…: the old token stops working at once.
    func resetRemoteToken(_ agent: Agent) {
        guard agent.cloudAccess, agent.hasRemoteKey else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Reset the remote token for “\(agent.name)”?")
        alert.informativeText = String(localized: "Cloud agents using the current token stop working until you copy the new one into their settings. Connected cloud apps aren't affected.")
        alert.addButton(withTitle: String(localized: "Reset Token"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                guard let remoteServer else { return }
                _ = try await remoteServer.issueRemoteKey(agentID: agent.id)
                cloudMessage = String(localized: "Remote token reset. The old token no longer works; copy the new one.")
            } catch {
                cloudMessage = ErrorText.message(error)
            }
            await refresh()
        }
    }

    // MARK: Connected cloud apps and pairing

    /// Connect a Cloud App…: a 10-minute pairing window for this agent. The cloud app's sign-in
    /// then shows the panel with a code to compare.
    func connectCloudApp(_ agent: Agent) {
        guard let remoteServer, remoteServer.openPairing(agentID: agent.id) else { return }
        cloudGeneration += 1
        cloudMessage = String(localized: "Pairing is open for 10 minutes. Add the connector in the cloud app now; when it asks to connect, check the code and allow it here.")
    }

    /// The agent pairing is open for, while it is.
    var pairingAgentID: UUID? {
        _ = cloudGeneration
        guard let oauth = remoteServer?.oauth, let expires = oauth.pairingExpiresAt, expires > Date() else { return nil }
        return oauth.pairingClientID.flatMap(UUID.init(uuidString:))
    }

    func revokeApp(_ connection: OAuthConnectionView) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Revoke “\(connection.appName)”?")
        alert.informativeText = String(localized: "It stops working now. To use it again, connect it again.")
        let revoke = alert.addButton(withTitle: String(localized: "Revoke"))
        revoke.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        remoteServer?.oauth.revoke(connectionID: connection.id)
        cloudGeneration += 1
    }

    /// Set Up OAuth Client… (Gemini Enterprise): a confidential client for this agent, pairing
    /// opened, and the values to enter. Each use replaces the agent's unused ones.
    func setUpOAuthClient(_ agent: Agent, appName: String, redirectURI: String) -> OAuthClientDetails? {
        guard let remoteServer, agent.cloudAccess, let context = remoteAccess.configuration.oauthContext,
              remoteAccess.mcpURL != nil else { return nil }
        guard let issued = remoteServer.oauth.registerConfidentialClient(for: agent.id.db, name: appName,
                                                                          redirectURI: redirectURI) else {
            cloudMessage = String(localized: "The app couldn't be set up: the list of connected apps can't be saved right now.")
            return nil
        }
        remoteServer.openPairing(agentID: agent.id)
        cloudGeneration += 1
        return OAuthClientDetails(agentID: agent.id, clientID: issued.clientID, secret: issued.secret,
                                  authorizationURL: context.issuer + "/oauth/authorize", tokenURL: context.issuer + "/oauth/token",
                                  redirectURI: redirectURI)
    }

    // MARK: The sign-in panel

    /// Pairing changed: the panel shows the oldest waiting sign-in, never replacing one it shows.
    func signInsChanged() {
        cloudGeneration += 1
        signIns = remoteServer?.oauth.pendingPairings ?? []
        signInsUpdated()
    }

    func answerSignIn(_ id: UUID, allow: Bool) {
        remoteServer?.oauth.answerPairing(id, allow: allow)
        signInsChanged()
    }
}
