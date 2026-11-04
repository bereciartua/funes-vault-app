import Foundation
import FunesProtocol

/// How the paired Mac can be reached (UX: iPhone, States; FR-iOS-06).
public enum Reachability: Sendable, Equatable {
    case notPaired
    /// Looking for the Mac: the first check, or a check after it went missing.
    case connecting
    case connected(MacConnection)
    case unreachable(localNetworkDenied: Bool)
    /// "This iPhone was removed from Funes on your Mac".
    case revoked
    /// Something answered, but not as a Funes Mac does, or this iPhone's Keychain failed.
    case failed(CompanionClientError)

    /// Search and the Inbox call the Mac only while it's connected (FR-iOS-06).
    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// The state a check, or any call, that failed with `error` leads to.
    public init(_ error: CompanionClientError) {
        switch error {
        case .notPaired: self = .notPaired
        case let .unreachable(denied): self = .unreachable(localNetworkDenied: denied)
        case .refused(.revoked), .refused(.unknownDevice): self = .revoked
        default: self = .failed(error)
        }
    }
}

/// The reachability state machine behind the status bar. `status.get` drives it, and so do
/// the other calls' failures, capture delivery and the network path, so the bar doesn't wait
/// for the next foreground to notice the Mac has gone.
public struct ReachabilityTracker: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// The pairing record was read, or pairing finished or was undone.
        case pairing(paired: Bool)
        /// A `status.get` started.
        case checkStarted
        case checked(Result<MacConnection, CompanionClientError>, at: Date)
        /// A Search, memory or Inbox call failed.
        case callFailed(CompanionClientError)
        case delivered(DeliveryOutcome)
        case path(NetworkPath)
    }

    public private(set) var state = Reachability.notPaired
    public private(set) var lastChecked: Date?
    /// When and how the Mac last answered, for the status sheet.
    public private(set) var lastReached: LastReached?
    private var path: NetworkPath?

    /// "Last reached 5 minutes ago over Wi-Fi".
    public struct LastReached: Sendable, Equatable {
        public var at: Date
        public var route: ConnectionRoute
    }

    public init() {}

    public mutating func handle(_ event: Event) {
        switch event {
        case let .pairing(paired):
            if !paired {
                state = .notPaired
                lastChecked = nil
                lastReached = nil
            } else if state == .notPaired {
                state = .connecting
            }
        case .checkStarted:
            // A connected Mac stays connected while it's checked again, so the bar doesn't
            // flicker on every foreground; a removed iPhone stays removed until it pairs again.
            switch state {
            case .connected, .revoked, .notPaired: break
            case .connecting, .unreachable, .failed: state = .connecting
            }
        case let .checked(.success(connection), at):
            state = .connected(connection)
            lastChecked = at
            lastReached = LastReached(at: at, route: ConnectionRoute(connection.address.connectionKind, path: path))
        case let .checked(.failure(error), at):
            state = Reachability(error)
            lastChecked = at
        case let .callFailed(error):
            fail(error)
        case let .delivered(outcome):
            switch outcome {
            case .revoked: state = .revoked
            case .notPaired: state = .notPaired
            case let .failed(error, _, _): fail(error)
            case .drained, .waiting, .busy, .storage: break
            }
        case let .path(path):
            self.path = path
            switch state {
            case .connected, .connecting:
                if !path.isSatisfied { state = .unreachable(localNetworkDenied: false) }
            case .unreachable, .failed:
                // A check follows a usable path.
                if path.isSatisfied { state = .connecting }
            case .notPaired, .revoked: break
            }
        }
    }

    /// Only "no answer" and "removed" say anything about the Mac. A method's error (`conflict`,
    /// `not_found`…) came from a Mac that answered, and a local failure is this iPhone's.
    private mutating func fail(_ error: CompanionClientError) {
        switch error {
        case .unreachable, .refused(.revoked), .refused(.unknownDevice), .notPaired:
            guard state != .notPaired else { return }
            state = Reachability(error)
        default: break
        }
    }
}

/// How a connected Mac is reached, as the status sheet names it.
public enum ConnectionRoute: String, Sendable, Equatable {
    case wifi, vpn, tailscale, tunnel

    public init(_ kind: ConnectionKind, path: NetworkPath?) {
        switch kind {
        // A LAN address reached off Wi-Fi, such as through a Tailscale subnet router (Spike 1e).
        case .wifi where path.map({ !$0.isLocal }) ?? false: self = .vpn
        case .wifi: self = .wifi
        case .tailscale: self = .tailscale
        case .tunnel: self = .tunnel
        }
    }
}

/// The connection's state, as the status bar shows it (UX: iPhone, Status bar). The app words it.
public enum BannerState: Sendable, Equatable {
    /// "Pair with your Mac to start" [Pair].
    case notPaired(waiting: Int)
    case connecting(macName: String, waiting: Int)
    /// "Connected to Maya's MacBook Pro · Wi-Fi".
    case connected(macName: String, route: ConnectionRoute, waiting: Int)
    /// "Mac not reachable · 3 captures waiting" [Why?].
    case unreachable(waiting: Int)
    case localNetworkOff(waiting: Int)
    /// "This iPhone was removed from Funes on your Mac" [Pair Again].
    case revoked(waiting: Int)
    case failed(CompanionClientError, waiting: Int)

    /// `macName` is the pairing record's; a connected Mac's own answer wins.
    public init(_ reachability: Reachability, macName: String?, waiting: Int, path: NetworkPath?) {
        let name = macName ?? ""
        switch reachability {
        case .notPaired: self = .notPaired(waiting: waiting)
        case .connecting: self = .connecting(macName: name, waiting: waiting)
        case let .connected(connection):
            self = .connected(macName: connection.status.macName, route: ConnectionRoute(connection.address.connectionKind, path: path),
                              waiting: waiting)
        case .unreachable(localNetworkDenied: true): self = .localNetworkOff(waiting: waiting)
        case .unreachable: self = .unreachable(waiting: waiting)
        case .revoked: self = .revoked(waiting: waiting)
        case let .failed(error): self = .failed(error, waiting: waiting)
        }
    }

    /// The bar's button is **Why?** (the status sheet) or **Fix**.
    public var offersWhy: Bool {
        switch self {
        case .unreachable, .localNetworkOff, .failed: true
        case .notPaired, .connecting, .connected, .revoked: false
        }
    }

    /// The bar offers pairing: [Pair] or [Pair Again].
    public var offersPairing: Bool {
        switch self {
        case .notPaired, .revoked: true
        default: false
        }
    }
}

/// The "Why?" sheet's suggestions: why the Mac can't be reached, and what to try, from what the
/// phone knows (its network, the pairing's addresses and the last check's probes).
public struct UnreachableDiagnosis: Sendable, Equatable {
    public enum Hint: Sendable, Equatable {
        /// This iPhone has no network at all.
        case offline
        /// iOS refused the Bonjour browse: Settings ▸ Privacy & Security ▸ Local Network.
        case localNetworkOff
        /// The Mac's address answered but nothing listened: Funes Vault isn't open, or iPhone
        /// access is off.
        case funesNotListening
        /// On Wi-Fi: is it the Mac's?
        case sameWiFi
        /// Off Wi-Fi, with a Tailscale address saved: is Tailscale on at both ends?
        case checkTailscale
        /// Off Wi-Fi, and the pairing has no Tailscale address or tunnel.
        case awayWithoutTailscale
        /// Another service answered at the Mac's address.
        case somethingElseAnswered
        /// The fallback: the Mac is asleep, or Funes Vault isn't running.
        case macAsleep
    }

    public var hints: [Hint]

    public init(_ reachability: Reachability, path: NetworkPath?, addresses: [PairingAddress], probes: [ProbeOutcome]) {
        if let path, !path.isSatisfied {
            hints = [.offline]
            return
        }
        var hints: [Hint] = []
        switch reachability {
        case .unreachable(localNetworkDenied: true): hints.append(.localNetworkOff)
        case .failed(.badResponse): hints.append(.somethingElseAnswered)
        default: break
        }
        if probes.contains(where: { $0.outcome.localizedCaseInsensitiveContains("refused") }) {
            hints.append(.funesNotListening)
        }
        let local = path?.isLocal ?? true
        if local {
            hints.append(.sameWiFi)
        } else if addresses.contains(where: { $0.kind == .tailscale }) {
            hints.append(.checkTailscale)
        } else if !addresses.contains(where: { $0.kind == .tunnel }) {
            hints.append(.awayWithoutTailscale)
        }
        hints.append(.macAsleep)
        self.hints = hints
    }
}
