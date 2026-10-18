import BridgeKitCore
import Foundation
import FunesCore

/// Funes's MCP server: BridgeKitCore's listener and protocol with Funes's contract, key
/// lookup and pipeline. The listener writes `mcp-endpoint.json` (0600) while it listens and
/// removes it when it stops, so `funes-mcp` finds the port (mcp-server.md §1).
@MainActor
public final class FunesMCPServer {
    public let service: MCPService
    public let limiter: RateLimiter
    public let counters: MCPTrafficCounters
    public let configuration: BridgeConfiguration
    /// The port `start()` listens on (Settings ▸ MCP). Changing it takes effect at the next start.
    public var port: Int
    let pipeline: RequestPipeline
    let services: FunesServices
    let tools: FunesTools
    let authenticator: FunesAuthenticator
    /// The last request from each agent ("Connected · Claude Code 2.1 · 2 min ago"), by agent id.
    public private(set) var connections = [String: MCPServer.Connection]()
    public var statusChanged: (MCPService.Status) -> Void = { _ in } {
        didSet { service.statusChanged = statusChanged }
    }

    public init(services: FunesServices, presenter: any FunesPresenter, dataFolder: URL, version: String,
                port: Int = FunesMCPConfiguration.defaultPort, allowedOrigins: Set<String> = [],
                inCallWait: Duration = FunesMCPConfiguration.inCallWait,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.port = port
        configuration = FunesMCPConfiguration.server(dataFolder: dataFolder, version: version, port: port,
                                                     allowedOrigins: allowedOrigins)
        limiter = RateLimiter(policy: configuration.limits)
        counters = MCPTrafficCounters()
        let pipeline = RequestPipeline(services: services, presenter: presenter, limiter: limiter,
                                       inCallWait: inCallWait, now: now)
        self.pipeline = pipeline
        self.services = services
        tools = FunesTools(store: services.store)
        authenticator = FunesAuthenticator(agents: services.agents)
        var record: (String, MCPServer.Connection) -> Void = { _, _ in }
        let server = MCPServer(configuration: configuration, authenticator: authenticator,
                               tools: tools, handler: pipeline, limiter: limiter,
                               counters: counters, didConnect: { record($0, $1) })
        service = MCPService(server: server, limiter: limiter, counters: counters,
                             endpointFile: MCPEndpointFile(directory: dataFolder))
        record = { [weak self] id, connection in self?.connections[id] = connection }
    }

    /// Starts listening on `port`, or on the one given, which becomes `port` (0 picks a free one,
    /// for tests). A port in use is reported, never moved: agents' configs embed the URL.
    public func start(port: Int? = nil) {
        if let port { self.port = port }
        service.start(port: self.port)
    }

    public func stop() {
        service.stop()
    }

    /// Before quitting: calls waiting for the user answer `funes_quit` now (mcp-server.md §7).
    /// Keep listening until `callsInProgress` is 0, so the answers reach the agents.
    public func quit() {
        pipeline.quit()
    }

    public var callsInProgress: Int { pipeline.callsInProgress }
}
