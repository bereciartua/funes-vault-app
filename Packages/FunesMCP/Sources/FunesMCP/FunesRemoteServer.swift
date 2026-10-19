import BridgeKitCore
import BridgeKitRemote
import Foundation
import FunesCore
import FunesProtocol

/// Funes's values for BridgeKitRemote (mcp-server.md §12, ADR-0018).
public enum FunesRemoteConfiguration {
    /// The first free port after Funes's own 47625 and 47626, and after EK Bridge's 47615 and 47616.
    public static let defaultPort = 47627
    /// The User-Agent product of the client-metadata fetch: `FunesVault/<version>`.
    public static let userAgentProduct = "FunesVault"

    public static func make(dataFolder: URL, version: String) -> RemoteBridgeConfiguration {
        let app = "Funes Vault"
        var texts = RemoteTexts.standard(displayName: app, agent: "agent")
        texts.unauthorized = "\(app) doesn't recognize this credential. Use the agent's remote token, or connect the "
            + "app again from the agent's Cloud section in \(app)."
        return RemoteBridgeConfiguration(
            identity: BridgeIdentity(displayName: app, bundleID: Identifiers.macBundleID, dataFolder: dataFolder,
                                     version: version),
            defaultPort: defaultPort, remoteTokenPrefix: Identifiers.remoteKeyPrefix,
            accessTokenPrefix: Identifiers.oauthAccessPrefix, refreshTokenPrefix: Identifiers.oauthRefreshPrefix,
            clientSecretPrefix: Identifiers.oauthClientSecretPrefix, scope: Identifiers.oauthScope,
            userAgentProduct: userAgentProduct, storeDirectory: dataFolder, texts: texts)
    }
}

/// Remote tokens and OAuth-connected cloud apps, looked up in the vault. Only agents with
/// Allow cloud access on (and not removed) authenticate. Paused and expired agents still do, so
/// their calls get the same reason codes as locally (mcp-server.md §12).
@MainActor
public final class FunesRemoteAuthenticator: RemoteAuthenticator {
    private let agents: AgentService
    /// Refused remote credentials since launch, for the Remote Access page. No Activity row: a
    /// flood from the internet mustn't fill the log (the per-address lockout handles it).
    public private(set) var failures = 0

    public init(agents: AgentService) {
        self.agents = agents
    }

    public func authenticate(remoteToken: PresentedKey) async -> AuthenticationOutcome {
        do {
            guard let agent = try await agents.authenticate(remoteKeyDigest: remoteToken.digest) else {
                failures += 1
                return .rejected
            }
            return .authenticated(AuthenticatedAgent(id: agent.id.uuidString.lowercased(), name: agent.name))
        } catch {
            return .unavailable
        }
    }

    public func authenticate(agentID: String) async -> AuthenticationOutcome {
        guard let id = UUID(uuidString: agentID) else { return .rejected }
        do {
            guard let agent = try await agents.agent(id: id), !agent.isRemoved, agent.cloudAccess else { return .rejected }
            return .authenticated(AuthenticatedAgent(id: agentID, name: agent.name))
        } catch {
            return .unavailable
        }
    }

    /// A quick synchronous read, for OAuth's decisions on the main actor. Any doubt is no.
    public func cloudAccessAllowed(agentID: String) -> Bool {
        guard let id = UUID(uuidString: agentID), let agent = try? agents.store.agent(id: id) else { return false }
        return agent.cloudAccess && !agent.isRemoved
    }

    public func agentName(agentID: String) -> String? {
        guard let id = UUID(uuidString: agentID), let agent = try? agents.store.agent(id: id), !agent.isRemoved else {
            return nil
        }
        return agent.name
    }

    public func recordFailedRemoteAuth() { failures += 1 }
}

/// Remote Access (mcp-server.md §12): BridgeKitRemote's listener on `127.0.0.1:47627` and its
/// OAuth server, over the **same** MCP dispatch, tool contract, `RequestPipeline` and rate
/// limiter as the local server. Only the gate and the credentials differ; calls carry
/// `ToolCall.remote`, which changes Activity's `via` and adds the stricter remote buckets.
@MainActor
public final class FunesRemoteServer {
    public let service: RemoteMCPService
    public let oauth: OAuthServer
    public let authenticator: FunesRemoteAuthenticator
    public let configuration: RemoteBridgeConfiguration
    /// The last remote request from each agent, by agent id.
    public private(set) var connections = [String: MCPServer.Connection]()
    /// The tunnel and forwarded address of the last 50 remote requests. Memory only (§12).
    public private(set) var notes = [RemoteRequestNote]()
    public static let maxNotes = 50
    /// An agent's connected cloud apps changed (its revision was bumped first).
    public var cloudAppsChanged: (UUID) -> Void = { _ in }
    private let agents: AgentService
    private let epochs: RemoteCredentialEpochs
    private let now: @Sendable () -> Date

    /// `cimdTesting` only from the FUNES_MCP_TEST harness.
    public init(local: FunesMCPServer, dataFolder: URL, version: String, cimdTesting: CIMDFetcher.Testing? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        let configuration = FunesRemoteConfiguration.make(dataFolder: dataFolder, version: version)
        self.configuration = configuration
        agents = local.services.agents
        epochs = local.pipeline.remoteEpochs
        self.now = now
        let authenticator = FunesRemoteAuthenticator(agents: local.services.agents)
        self.authenticator = authenticator
        oauth = OAuthServer(configuration: configuration,
                            fetcher: CIMDFetcher(userAgent: configuration.userAgent, testing: cimdTesting),
                            authenticator: authenticator)
        var record: (String, MCPServer.Connection) -> Void = { _, _ in }
        // A second protocol layer on the same pipeline, limiter and counters.
        let server = MCPServer(configuration: local.configuration, authenticator: local.authenticator,
                               tools: local.tools, handler: local.pipeline, limiter: local.limiter,
                               counters: local.counters, didConnect: { record($0, $1) })
        service = RemoteMCPService(server: server, configuration: configuration, authenticator: authenticator,
                                   limiter: local.limiter, counters: local.counters, oauth: oauth)
        record = { [weak self] id, connection in self?.connections[id] = connection }
        service.didServe = { [weak self] note in
            guard let self else { return }
            self.notes.append(note)
            if self.notes.count > Self.maxNotes { self.notes.removeFirst(self.notes.count - Self.maxNotes) }
        }
        oauth.connectionsChanged = { [weak self] id in
            guard let self, let agentID = UUID(uuidString: id) else { return }
            // A new or revoked app: the agent's in-flight remote calls release nothing more.
            self.epochs.bump(id)
            let agents = self.agents, now = self.now
            Task { @MainActor [weak self] in
                // Pending approvals bind to the revision; a new or revoked app ends them (domain model).
                _ = try? await agents.cloudAppsChanged(agentID: agentID, now: now())
                self?.cloudAppsChanged(agentID)
            }
        }
    }

    public var status: RemoteMCPService.Status { service.status }

    /// Starts the listener (or restarts it on a new port). Pairing stays closed until the user opens it.
    public func start(_ settings: RemoteConfiguration) { service.start(settings) }

    /// New address or secret path without a restart. Connections issued for another MCP URL are
    /// revoked; returns how many.
    @discardableResult
    public func update(_ settings: RemoteConfiguration) -> Int {
        service.update(settings)
        return settings.oauthContext.map { oauth.revokeConnections(notFor: $0.resource) } ?? 0
    }

    /// Turning Remote Access off: the port closes at once and pairing ends. Cloud access, remote
    /// tokens and connected apps are kept for next time.
    public func stop() {
        service.stop()
        oauth.closePairing()
    }

    /// Allow cloud access. Off deletes the remote token and the agent's connected apps at once;
    /// either way the revision goes up.
    /// Remote calls already in flight release nothing once it's off.
    public func setCloudAccess(agentID: UUID, _ on: Bool) async throws {
        if !on { epochs.bump(agentID.uuidString.lowercased()) }
        try await agents.setCloudAccess(agentID: agentID, on, now: now())
        if !on { revokeApps(agentID: agentID) }
    }

    /// Removing an agent also removes its connected apps (and confidential clients set up for it).
    public func removeAgent(agentID: UUID) async throws {
        epochs.bump(agentID.uuidString.lowercased())
        try await agents.remove(agentID: agentID, now: now())
        revokeApps(agentID: agentID)
    }

    /// Copy Remote Token… the first time, Reset Remote Token… after: the old token stops at once,
    /// in-flight calls included.
    public func issueRemoteKey(agentID: UUID) async throws -> IssuedKey {
        epochs.bump(agentID.uuidString.lowercased())
        return try await agents.issueRemoteKey(agentID: agentID, now: now())
    }

    public func revokeApps(agentID: UUID) {
        epochs.bump(agentID.uuidString.lowercased())
        oauth.revokeAll(clientID: agentID.uuidString.lowercased())
        if oauth.pairingClientID == agentID.uuidString.lowercased() { oauth.closePairing() }
    }

    /// Connect a Cloud App…: a 10-minute pairing window for this agent only. Refused unless it has
    /// cloud access.
    @discardableResult
    public func openPairing(agentID: UUID) -> Bool {
        let id = agentID.uuidString.lowercased()
        guard authenticator.cloudAccessAllowed(agentID: id) else { return false }
        oauth.openPairing(clientID: id)
        return true
    }

    public func connectedApps(agentID: UUID) -> [OAuthConnectionView] {
        oauth.connections(clientID: agentID.uuidString.lowercased())
    }

    /// The note for an Activity row: the same agent within 5 seconds.
    public func note(agentID: UUID, near time: Date) -> RemoteRequestNote? {
        let id = agentID.uuidString.lowercased()
        return notes.last { $0.clientID == id && abs($0.at.timeIntervalSince(time)) < 5 }
    }
}
