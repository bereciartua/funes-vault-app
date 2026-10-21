import Foundation
import FunesProtocol

/// One way to reach the paired Mac (§5): a Bonjour hit or a saved LAN address (same Wi-Fi), the
/// saved Tailscale IP, or the tunnel URL with its secret path prefix.
public struct MacAddress: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        case bonjour, lan, tailscale, tunnel

        /// Address selection's preference: same Wi-Fi, then Tailscale, then the tunnel. A Bonjour
        /// hit and a saved LAN address are the same network, so whichever answers first wins.
        var rank: Int {
            switch self {
            case .bonjour, .lan: 0
            case .tailscale: 1
            case .tunnel: 2
            }
        }
    }

    public var kind: Kind
    /// `http://host:port`, or the tunnel's `https://host/r/<secret>`.
    public var base: URL

    public init(kind: Kind, base: URL) {
        self.kind = kind
        self.base = base
    }

    /// A host and port over plain HTTP; the envelope gives confidentiality (§5). Nil for a host
    /// that can't be put in a URL.
    public init?(kind: Kind, host: String, port: UInt16) {
        guard !host.isEmpty, !host.contains("/"), !host.contains("@"), !host.contains("?"), !host.contains("#") else { return nil }
        // An IPv6 literal goes in brackets, with a zone's "%" escaped.
        let authority = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        guard let url = URL(string: "http://\(authority):\(port)"), url.host() != nil else { return nil }
        self.init(kind: kind, base: url)
    }

    /// An address from the QR code. The tunnel must be HTTPS; LAN and Tailscale default to 47626.
    public init?(_ address: PairingAddress) {
        switch address.kind {
        case .lan, .tailscale:
            guard let host = address.host else { return nil }
            self.init(kind: address.kind == .lan ? .lan : .tailscale, host: host, port: address.port ?? CompanionProtocol.port)
        case .tunnel:
            guard let string = address.url, var components = URLComponents(string: string), components.scheme == "https",
                  components.host?.isEmpty == false, components.query == nil, components.fragment == nil
            else { return nil }
            while components.path.hasSuffix("/") { components.path.removeLast() }
            guard let url = components.url else { return nil }
            self.init(kind: .tunnel, base: url)
        }
    }

    /// The endpoint's URL: the base plus `/c/v1/rpc` or `/c/v1/pair`.
    public func url(_ path: String) -> URL {
        URL(string: base.absoluteString + path) ?? base
    }

    /// How the banner names the connection.
    public var connectionKind: ConnectionKind {
        switch kind {
        case .bonjour, .lan: .wifi
        case .tailscale: .tailscale
        case .tunnel: .tunnel
        }
    }

    public var description: String { "\(kind.rawValue) \(base.absoluteString)" }
}

/// "Connected to Maya's MacBook Pro · Wi-Fi" (UX: iPhone, States).
public enum ConnectionKind: String, Sendable {
    case wifi, tailscale, tunnel
}

extension Array where Element == PairingAddress {
    /// The saved addresses to try, in the QR code's order. Duplicates dropped.
    var macAddresses: [MacAddress] {
        var seen = Set<MacAddress>()
        return compactMap(MacAddress.init).filter { seen.insert($0).inserted }
    }
}
