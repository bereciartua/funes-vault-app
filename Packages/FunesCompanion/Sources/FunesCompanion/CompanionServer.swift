import Darwin
import Foundation
import FunesCore
import FunesProtocol
import SystemConfiguration

/// iPhone access on the Mac (Settings ▸ iPhone): the listener, pairing and the device list. Off
/// by default; the listener runs only while it's on.
@MainActor
public final class CompanionServer {
    public struct Configuration: Equatable, Sendable {
        public var enabled: Bool
        public var modes: CompanionModes
        public var port: Int
        /// Public tunnel mode's secret path and host. Nil leaves tunnel mode unusable.
        public var tunnel: TunnelGate?

        public init(enabled: Bool = false, modes: CompanionModes = .default, port: Int = Int(CompanionProtocol.port),
                    tunnel: TunnelGate? = nil) {
            self.enabled = enabled
            self.modes = modes
            self.port = port
            self.tunnel = tunnel
        }

        /// Tunnel mode counts only with a host and secret saved.
        var effectiveModes: CompanionModes {
            var modes = modes
            if tunnel == nil || tunnel?.publicHost.isEmpty == true { modes.remove(.tunnel) }
            return modes
        }
    }

    public enum Status: Equatable, Sendable {
        case off
        case starting
        case listening(port: Int)
        case failed(CompanionListener.Failure)
    }

    public let identity: MacIdentity
    public let pairing: PairingService
    public let services: CompanionServices
    public private(set) var configuration = Configuration()
    public private(set) var status = Status.off
    public var statusChanged: ((Status) -> Void)?
    private let handlers: CompanionHandlers
    private var router: CompanionRouter?
    private var listener: CompanionListener?

    public let approvals: CompanionApprovals?

    public init(identity: MacIdentity, services: CompanionServices, macName: @escaping @Sendable () -> String, appVersion: String,
                approvals: CompanionApprovals? = nil) {
        self.identity = identity
        self.services = services
        self.approvals = approvals
        pairing = PairingService(identity: identity, devices: services.devices, activity: services.activity)
        handlers = CompanionHandlers(services: services, macName: macName, appVersion: appVersion, approvals: approvals)
    }

    /// Starts, restarts or stops the listener to match `configuration`.
    public func apply(_ configuration: Configuration) {
        let changed = configuration != self.configuration || listener == nil
        self.configuration = configuration
        guard changed else { return }
        listener?.stop()
        listener = nil
        router = nil
        let modes = configuration.effectiveModes
        guard configuration.enabled, !modes.isEmpty else {
            setStatus(.off)
            Task { await pairing.cancel() }
            return
        }
        let router = CompanionRouter(identity: identity, devices: services.devices, pairing: pairing, handlers: handlers,
                                     gate: modes.contains(.tunnel) ? configuration.tunnel : nil)
        let listener = CompanionListener(port: configuration.port, modes: modes,
                                         bonjour: CompanionBonjour.txtRecord(macID: identity.macID)) { request, transport in
            await router.handle(request, transport: transport)
        }
        self.router = router
        self.listener = listener
        listener.start { [weak self] state in
            Task { @MainActor in
                switch state {
                case .stopped: self?.setStatus(.off)
                case .starting: self?.setStatus(.starting)
                case let .ready(port): self?.setStatus(.listening(port: port))
                case let .failed(failure): self?.setStatus(.failed(failure))
                }
            }
        }
    }

    public func stop() {
        listener?.stop()
        listener = nil
        router = nil
        setStatus(.off)
    }

    /// Revoke on the Mac (§8): the device's next request gets `401 revoked`.
    public func revoke(deviceID: UUID) async throws {
        try await services.devices.revoke(deviceID: deviceID, now: Date(), actor: .user)
        await router?.forget(deviceID: deviceID)
        await approvals?.forget(deviceID: deviceID)
    }

    /// The addresses a QR code lists, in the order the phone tries them (§5): the Mac's `.local`
    /// name and LAN address, its Tailscale address, then the tunnel URL.
    public func addresses() -> [PairingAddress] {
        let modes = configuration.effectiveModes
        let port = UInt16(clamping: configuration.port)
        var result: [PairingAddress] = []
        let interfaces = NetworkAddresses.ipv4()
        if modes.contains(.sameWiFi) {
            if let name = NetworkAddresses.localHostName() { result.append(PairingAddress(kind: .lan, host: name, port: port)) }
            if let ip = interfaces.first(where: { AddressPolicy.classify($0.bytes) == .privateLAN }) {
                result.append(PairingAddress(kind: .lan, host: ip.text, port: port))
            }
        }
        if modes.contains(.tailscale), let ip = interfaces.first(where: { AddressPolicy.classify($0.bytes) == .tailscale }) {
            result.append(PairingAddress(kind: .tailscale, host: ip.text, port: port))
        }
        if modes.contains(.tunnel), let gate = configuration.tunnel {
            result.append(PairingAddress(kind: .tunnel, url: "https://\(gate.publicHost)/r/\(gate.secret)"))
        }
        return result
    }

    private func setStatus(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        statusChanged?(status)
    }
}

/// The Mac's own addresses, read from its interfaces.
public enum NetworkAddresses {
    /// This Mac's Tailscale address (`100.x.y.z`), when Tailscale is running.
    public static func tailscale() -> String? {
        ipv4().first { AddressPolicy.classify($0.bytes) == .tailscale }?.text
    }

    struct IPv4: Equatable {
        var bytes: [UInt8]
        var text: String
    }

    static func ipv4() -> [IPv4] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [IPv4] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let value = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let bytes = withUnsafeBytes(of: value) { [UInt8]($0) }
            result.append(IPv4(bytes: bytes, text: bytes.map(String.init).joined(separator: ".")))
        }
        return result
    }

    /// `maya-mbp.local`, from System Settings ▸ General ▸ Sharing.
    static func localHostName() -> String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" }
    }
}
