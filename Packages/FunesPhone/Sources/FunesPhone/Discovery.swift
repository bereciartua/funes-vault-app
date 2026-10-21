import Foundation
import FunesProtocol
import Network

/// What a Bonjour search found.
public struct DiscoveryResult: Sendable, Equatable {
    public var addresses: [MacAddress]
    /// iOS refused the browse: the user said no to Local Network access for Funes.
    public var localNetworkDenied: Bool

    public init(addresses: [MacAddress] = [], localNetworkDenied: Bool = false) {
        self.addresses = addresses
        self.localNetworkDenied = localNetworkDenied
    }
}

/// Finds the paired Mac on the local network.
public protocol MacDiscovery: Sendable {
    /// Macs advertising `_funes._tcp` whose TXT `mac` is `tag`, resolved to an address, within
    /// `timeout` seconds. Returns as soon as one is found.
    func find(tag: String, timeout: TimeInterval) async -> DiscoveryResult
}

/// `NWBrowser` for `_funes._tcp` (§5). A match is resolved to its IPv4 address and port by
/// opening (and at once closing) a TCP connection, since `URLSession` can't use a Bonjour
/// service endpoint directly. Browsing is also what triggers iOS's Local Network prompt.
public struct BonjourDiscovery: MacDiscovery {
    public init() {}

    public func find(tag: String, timeout: TimeInterval) async -> DiscoveryResult {
        let search = BonjourSearch(tag: tag)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in search.start(timeout: timeout, continuation) }
        } onCancel: {
            search.stop()
        }
    }
}

/// One search. All state lives on `queue`.
private final class BonjourSearch: @unchecked Sendable {
    /// `kDNSServiceErr_PolicyDenied`: Local Network access is off for this app.
    static let policyDenied: Int32 = -65570

    let tag: String
    let queue = DispatchQueue(label: "com.funesvault.ios.bonjour")
    private var browser: NWBrowser?
    private var connections: [NWEndpoint: NWConnection] = [:]
    private var continuation: CheckedContinuation<DiscoveryResult, Never>?
    private var denied = false
    private var finished = false

    init(tag: String) { self.tag = tag }

    func start(timeout: TimeInterval, _ continuation: CheckedContinuation<DiscoveryResult, Never>) {
        queue.async { [self] in
            guard !finished else { return continuation.resume(returning: DiscoveryResult()) }
            self.continuation = continuation
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Identifiers.bonjourServiceType, domain: nil), using: NWParameters())
            browser.stateUpdateHandler = { [weak self] state in self?.browserState(state) }
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.found(results) }
            self.browser = browser
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        }
    }

    func stop() { queue.async { [self] in finish(nil) } }

    private func browserState(_ state: NWBrowser.State) {
        switch state {
        case let .waiting(error), let .failed(error):
            if case let .dns(code) = error, code == Self.policyDenied {
                denied = true
                finish(nil)
            } else if case .failed = state {
                finish(nil)
            }
        default: break
        }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .bonjour(txt) = result.metadata, txt["mac"] == tag, connections[result.endpoint] == nil else { continue }
            resolve(result.endpoint)
        }
    }

    private func resolve(_ endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, case .ready = state, case let .hostPort(host, port)? = connection?.currentPath?.remoteEndpoint else { return }
            if let address = MacAddress(kind: .bonjour, host: Self.string(host), port: port.rawValue) { finish(address) }
        }
        connections[endpoint] = connection
        connection.start(queue: queue)
    }

    private static func string(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address): "\(address)".split(separator: "%").first.map(String.init) ?? ""
        case let .ipv6(address): "\(address)"
        case let .name(name, _): name
        @unknown default: ""
        }
    }

    private func finish(_ address: MacAddress?) {
        guard !finished else { return }
        finished = true
        browser?.cancel()
        connections.values.forEach { $0.cancel() }
        connections = [:]
        continuation?.resume(returning: DiscoveryResult(addresses: address.map { [$0] } ?? [], localNetworkDenied: denied))
        continuation = nil
    }
}

/// The phone's network, from `NWPathMonitor`.
public struct NetworkPath: Sendable, Equatable {
    public var isSatisfied: Bool
    public var usesWiFi: Bool
    public var usesCellular: Bool
    public var usesWired: Bool

    public init(isSatisfied: Bool, usesWiFi: Bool = false, usesCellular: Bool = false, usesWired: Bool = false) {
        self.isSatisfied = isSatisfied
        self.usesWiFi = usesWiFi
        self.usesCellular = usesCellular
        self.usesWired = usesWired
    }

    /// On a local network itself, rather than reaching one through a VPN.
    public var isLocal: Bool { usesWiFi || usesWired }
}

public enum NetworkPathWatcher {
    /// Every change of the phone's network path, starting with the current one. Address
    /// selection starts over on each change, and delivery retries on a satisfied path (§6).
    public static func updates() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(NetworkPath(isSatisfied: path.status == .satisfied, usesWiFi: path.usesInterfaceType(.wifi),
                                               usesCellular: path.usesInterfaceType(.cellular),
                                               usesWired: path.usesInterfaceType(.wiredEthernet)))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.funesvault.ios.path"))
        }
    }
}
