import Foundation
import FunesProtocol
import Network
import Testing
@testable import FunesCompanion

@Suite struct AddressPolicyTests {
    func v4(_ text: String) -> [UInt8] { [UInt8](IPv4Address(text)!.rawValue) }
    func v6(_ text: String) -> [UInt8] { [UInt8](IPv6Address(text)!.rawValue) }

    @Test(arguments: ["10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.1.20", "169.254.3.4"])
    func privateIPv4IsLAN(_ address: String) {
        #expect(AddressPolicy.classify(v4(address)) == .privateLAN)
    }

    @Test(arguments: ["fd00::1", "fc12:3456::9", "fe80::1", "febf::1"])
    func privateIPv6IsLAN(_ address: String) {
        #expect(AddressPolicy.classify(v6(address)) == .privateLAN)
    }

    @Test(arguments: ["100.64.0.1", "100.101.102.103", "100.127.255.255"])
    func tailscaleIPv4(_ address: String) {
        #expect(AddressPolicy.classify(v4(address)) == .tailscale)
    }

    @Test func tailscaleIPv6IsNotPlainULA() {
        #expect(AddressPolicy.classify(v6("fd7a:115c:a1e0::1")) == .tailscale)
        #expect(AddressPolicy.classify(v6("fd7a:115c:a1e1::1")) == .privateLAN)
    }

    @Test(arguments: ["8.8.8.8", "172.32.0.1", "172.15.255.255", "100.63.255.255", "100.128.0.1", "192.169.0.1", "0.0.0.0"])
    func publicIPv4IsOther(_ address: String) {
        #expect(AddressPolicy.classify(v4(address)) == .other)
    }

    @Test(arguments: ["2001:db8::1", "2606:4700::1111", "fec0::1", "::"])
    func publicIPv6IsOther(_ address: String) {
        #expect(AddressPolicy.classify(v6(address)) == .other)
    }

    @Test func loopbackAndMapped() {
        #expect(AddressPolicy.classify(v4("127.0.0.1")) == .loopback)
        #expect(AddressPolicy.classify(v4("127.8.9.10")) == .loopback)
        #expect(AddressPolicy.classify(v6("::1")) == .loopback)
        #expect(AddressPolicy.classify(v6("::ffff:192.168.1.2")) == .privateLAN)
        #expect(AddressPolicy.classify(v6("::ffff:8.8.8.8")) == .other)
        #expect(AddressPolicy.classify(v6("::ffff:127.0.0.1")) == .loopback)
    }

    /// The table in companion-protocol §5.
    @Test func modesDecideAcceptance() {
        let lan = v4("192.168.1.20"), ts = v4("100.101.102.103"), loop = v4("127.0.0.1"), pub = v4("8.8.8.8")
        #expect(AddressPolicy.transport(forAddress: lan, modes: .default) == .lan)
        #expect(AddressPolicy.transport(forAddress: ts, modes: .default) == nil)
        #expect(AddressPolicy.transport(forAddress: loop, modes: .default) == nil)
        #expect(AddressPolicy.transport(forAddress: ts, modes: [.tailscale]) == .tailscale)
        #expect(AddressPolicy.transport(forAddress: lan, modes: [.tailscale]) == nil)
        #expect(AddressPolicy.transport(forAddress: loop, modes: [.tunnel]) == .tunnel)
        #expect(AddressPolicy.transport(forAddress: lan, modes: [.tunnel]) == nil)
        #expect(AddressPolicy.transport(forAddress: pub, modes: [.sameWiFi, .tailscale, .tunnel]) == nil)
    }

    @Test func endpoints() {
        let lan = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 50_000)
        #expect(AddressPolicy.transport(for: lan, modes: .default) == .lan)
        let named = NWEndpoint.hostPort(host: .name("evil.example", nil), port: 50_000)
        #expect(AddressPolicy.transport(for: named, modes: [.sameWiFi, .tailscale, .tunnel]) == nil)
        #expect(AddressPolicy.transport(for: .service(name: "x", type: "_funes._tcp", domain: "local", interface: nil),
                                        modes: .default) == nil)
    }
}

@Suite struct TunnelGateTests {
    let gate = TunnelGate(secret: "AAAAAAAAAAAAAAAAAAAAAA", publicHost: "maya-mbp.tailnet.ts.net")

    @Test func rightPrefixAndHost() {
        #expect(gate.check(path: "/r/AAAAAAAAAAAAAAAAAAAAAA/c/v1/rpc", host: "maya-mbp.tailnet.ts.net") == .allowed(path: "/c/v1/rpc"))
        #expect(gate.check(path: "/r/AAAAAAAAAAAAAAAAAAAAAA/c/v1/pair", host: "MAYA-MBP.tailnet.ts.net:443") == .allowed(path: "/c/v1/pair"))
        #expect(gate.check(path: "/r/AAAAAAAAAAAAAAAAAAAAAA/c/v1/rpc", host: "127.0.0.1:47626") == .allowed(path: "/c/v1/rpc"))
        #expect(gate.check(path: "/r/AAAAAAAAAAAAAAAAAAAAAA/c/v1/rpc", host: "[::1]:47626") == .allowed(path: "/c/v1/rpc"))
    }

    @Test func wrongPathIsNotFoundBeforeHost() {
        #expect(gate.check(path: "/c/v1/rpc", host: "maya-mbp.tailnet.ts.net") == .notFound)
        #expect(gate.check(path: "/r/AAAAAAAAAAAAAAAAAAAAAB/c/v1/rpc", host: "evil.example") == .notFound)
        #expect(gate.check(path: "/r/AAAAAAAAAAAAAAAAAAAAAA", host: "maya-mbp.tailnet.ts.net") == .notFound)
        #expect(gate.check(path: "/r//c/v1/rpc", host: "maya-mbp.tailnet.ts.net") == .notFound)
        #expect(TunnelGate(secret: "", publicHost: "h").check(path: "/r//c/v1/rpc", host: "h") == .notFound)
    }

    @Test func wrongHostIsMisdirected() {
        #expect(gate.check(path: "/r/AAAAAAAAAAAAAAAAAAAAAA/c/v1/rpc", host: "evil.example") == .misdirected)
        #expect(gate.check(path: "/r/AAAAAAAAAAAAAAAAAAAAAA/c/v1/rpc", host: nil) == .misdirected)
        #expect(gate.check(path: "/r/AAAAAAAAAAAAAAAAAAAAAA/c/v1/rpc", host: "maya-mbp.tailnet.ts.net.evil.example") == .misdirected)
    }

    @Test func newSecretsAre128Bits() {
        let secret = TunnelGate.newSecret()
        #expect(secret.count == 22)
        #expect(Base64URL.decode(secret)?.count == 16)
        #expect(TunnelGate.newSecret() != secret)
    }
}
