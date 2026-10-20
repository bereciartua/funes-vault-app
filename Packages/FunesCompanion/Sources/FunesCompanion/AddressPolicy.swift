import Foundation
import FunesProtocol
import Network

/// Which networks the iPhone may reach the Mac from (Settings ▸ iPhone). Same Wi-Fi is the default.
public struct CompanionModes: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let sameWiFi = CompanionModes(rawValue: 1 << 0)
    public static let tailscale = CompanionModes(rawValue: 1 << 1)
    /// A tunnel the user runs forwards to `127.0.0.1:47626`.
    public static let tunnel = CompanionModes(rawValue: 1 << 2)

    public static let `default`: CompanionModes = [.sameWiFi]
}

/// Accepts or refuses a connection by its **remote address**, before reading a byte (§5):
///
/// | Mode | Accepted source addresses |
/// |---|---|
/// | Same Wi-Fi | RFC 1918, IPv4 link-local, IPv6 ULA and link-local |
/// | Tailscale | `100.64.0.0/10`, `fd7a:115c:a1e0::/48` |
/// | Public tunnel | loopback only |
///
/// Anything else (a public address, an IPv4-mapped public address, a hostname) is refused.
public enum AddressPolicy {
    public enum AddressClass: Sendable, Equatable {
        case privateLAN, tailscale, loopback, other
    }

    /// The transport a connection from `endpoint` counts as, or nil to refuse it.
    public static func transport(for endpoint: NWEndpoint, modes: CompanionModes) -> DeviceTransport? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        let bytes: [UInt8]
        switch host {
        case let .ipv4(address): bytes = [UInt8](address.rawValue)
        case let .ipv6(address): bytes = [UInt8](address.rawValue)
        default: return nil
        }
        return transport(forAddress: bytes, modes: modes)
    }

    public static func transport(forAddress bytes: [UInt8], modes: CompanionModes) -> DeviceTransport? {
        switch classify(bytes) {
        case .privateLAN: modes.contains(.sameWiFi) ? .lan : nil
        case .tailscale: modes.contains(.tailscale) ? .tailscale : nil
        case .loopback: modes.contains(.tunnel) ? .tunnel : nil
        case .other: nil
        }
    }

    /// 4 bytes for IPv4, 16 for IPv6. IPv4-mapped IPv6 (`::ffff:a.b.c.d`) is read as IPv4.
    public static func classify(_ bytes: [UInt8]) -> AddressClass {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return classify(Array(bytes[12..<16]))
        }
        switch bytes.count {
        case 4:
            let (a, b) = (bytes[0], bytes[1])
            if a == 127 { return .loopback }
            if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) {
                return .privateLAN
            }
            if a == 100 && (64...127).contains(b) { return .tailscale }
            return .other
        case 16:
            if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
            // Tailscale's ULA prefix first: it sits inside fc00::/7.
            if bytes[0] == 0xFD, bytes[1] == 0x7A, bytes[2] == 0x11, bytes[3] == 0x5C, bytes[4] == 0xA1, bytes[5] == 0xE0 {
                return .tailscale
            }
            if bytes[0] & 0xFE == 0xFC { return .privateLAN }
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return .privateLAN }
            return .other
        default:
            return .other
        }
    }
}

/// Public tunnel mode (§5): every request must use the secret path prefix `/r/<secret>/` and the
/// saved public `Host` (or a loopback one), as EK Bridge's Remote Access does. A wrong prefix is
/// `404` before anything else is read; a wrong `Host` is `421`.
public struct TunnelGate: Sendable, Equatable {
    /// 22 base64url characters, 128 bits.
    public var secret: String
    /// The tunnel's public host, e.g. `maya-mbp.tailnet.ts.net`, without a scheme or port.
    public var publicHost: String

    public init(secret: String, publicHost: String) {
        self.secret = secret
        self.publicHost = publicHost
    }

    public static func newSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return Base64URL.encode(Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    public enum Outcome: Equatable, Sendable {
        /// The path below the prefix, e.g. `/c/v1/rpc`.
        case allowed(path: String)
        case notFound
        case misdirected
    }

    public func check(path: String, host: String?) -> Outcome {
        let prefix = "/r/"
        guard path.hasPrefix(prefix) else { return .notFound }
        let rest = path.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/"), Self.constantTimeEqual(String(rest[..<slash]), secret), !secret.isEmpty else {
            return .notFound
        }
        guard let host, hostMatches(host) else { return .misdirected }
        return .allowed(path: String(rest[slash...]))
    }

    private func hostMatches(_ header: String) -> Bool {
        let host = Self.stripPort(header.trimmingCharacters(in: .whitespaces).lowercased())
        if ["127.0.0.1", "localhost", "[::1]"].contains(host) { return true }
        return !publicHost.isEmpty && host == publicHost.lowercased()
    }

    static func stripPort(_ host: String) -> String {
        if host.hasPrefix("[") { return host.firstIndex(of: "]").map { String(host[...$0]) } ?? host }
        return host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
