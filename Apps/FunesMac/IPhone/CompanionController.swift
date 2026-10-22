import Foundation
import FunesCompanion
import FunesCore
import FunesProtocol
import Observation
import os
import SystemConfiguration

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "companion")

/// Settings ▸ iPhone (companion protocol §5, task 5.2): iPhone access on or off, the networks it
/// listens on, pairing and the paired devices. Off by default; nothing listens on 47626 until the
/// user turns it on. The Mac's companion keys are created then, in the Keychain.
@MainActor @Observable
final class CompanionController {
    enum Key {
        static let enabled = "CompanionEnabled"
        static let modes = "CompanionModes"
        static let port = "CompanionPort"
        static let tunnelHost = "CompanionTunnelHost"
        static let tunnelSecret = "CompanionTunnelSecret"
    }

    private(set) var enabled = false
    private(set) var modes = CompanionModes.default
    private(set) var tunnelHost = ""
    private(set) var tunnelSecret = ""
    private(set) var status = CompanionServer.Status.off
    private(set) var devices: [Device] = []
    /// The QR code while the pairing sheet is open.
    private(set) var qr: PairingQRPayload?
    private(set) var pairingState = PairingService.State.idle
    /// The Keychain refused the companion keys.
    private(set) var keysUnavailable = false
    /// Whether this Mac can ring a phone's doorbell for approvals (ADR-0019).
    private(set) var doorbell = DoorbellAvailability.unsupported

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let services: CompanionServices
    @ObservationIgnored private let approvals: CompanionApprovals
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var server: CompanionServer?

    init(defaults: UserDefaults, services: CompanionServices, approvals: CompanionApprovals, appVersion: String) {
        self.defaults = defaults
        self.services = services
        self.approvals = approvals
        self.appVersion = appVersion
        defaults.register(defaults: [Key.enabled: false, Key.modes: CompanionModes.default.rawValue,
                                     Key.port: Int(CompanionProtocol.port)])
        enabled = defaults.bool(forKey: Key.enabled)
        modes = CompanionModes(rawValue: defaults.integer(forKey: Key.modes))
        tunnelHost = defaults.string(forKey: Key.tunnelHost) ?? ""
        tunnelSecret = defaults.string(forKey: Key.tunnelSecret) ?? ""
    }

    var port: Int { defaults.integer(forKey: Key.port) }
    var canPair: Bool { enabled && status == .listening(port: port) && activeDevices.count < CompanionProtocol.maxPairedDevices }
    var activeDevices: [Device] { devices.filter { !$0.isRevoked } }

    /// At launch: starts the listener if iPhone access was on, and deletes doorbell records a
    /// previous run left.
    func launch() {
        Task {
            await reloadDevices()
            await approvals.launch()
            await refreshDoorbell()
        }
        apply()
    }

    /// iCloud on this Mac, for Settings ▸ iPhone's approvals line.
    func refreshDoorbell() async {
        doorbell = await approvals.doorbellAvailability()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Key.enabled)
        apply()
    }

    func setMode(_ mode: CompanionModes, _ on: Bool) {
        if on { modes.insert(mode) } else { modes.remove(mode) }
        if mode == .tunnel, on, tunnelSecret.isEmpty { resetTunnelPath() }
        defaults.set(modes.rawValue, forKey: Key.modes)
        apply()
    }

    func setTunnelHost(_ host: String) {
        tunnelHost = Self.normalizedHost(host)
        defaults.set(tunnelHost, forKey: Key.tunnelHost)
        apply()
    }

    /// A new secret path: the old tunnel URL stops working, and phones need to pair again to learn it.
    func resetTunnelPath() {
        tunnelSecret = TunnelGate.newSecret()
        defaults.set(tunnelSecret, forKey: Key.tunnelSecret)
        apply()
    }

    /// `https://<host>/r/<secret>`, what the tunnel must forward to `http://127.0.0.1:47626`.
    var tunnelURL: String? {
        guard !tunnelHost.isEmpty, !tunnelSecret.isEmpty else { return nil }
        return "https://\(tunnelHost)/r/\(tunnelSecret)"
    }

    // MARK: Pairing

    func startPairing() async {
        guard let server else { return }
        qr = await server.pairing.start(macName: Self.macName(), addresses: server.addresses())
    }

    func answerPairing(allow: Bool) {
        guard let server else { return }
        Task { await server.pairing.answer(allow: allow) }
    }

    func endPairing() {
        qr = nil
        pairingState = .idle
        guard let server else { return }
        Task { await server.pairing.cancel() }
    }

    // MARK: Devices

    func reloadDevices() async {
        devices = (try? await services.devices.devices(includingRevoked: false)) ?? []
    }

    /// Approvals from this iPhone on or off (FR-iOS-12). Off takes back its doorbell records.
    func setApprovals(_ device: Device, _ on: Bool) async {
        do {
            try await approvals.setApprovals(deviceID: device.id, enabled: on)
        } catch {
            logger.error("Couldn't change an iPhone's approvals")
        }
        await reloadDevices()
    }

    func remove(_ device: Device) async {
        do {
            if let server { try await server.revoke(deviceID: device.id) } else {
                try await services.devices.revoke(deviceID: device.id, now: Date(), actor: .user)
                await approvals.forget(deviceID: device.id)
            }
        } catch {
            logger.error("Couldn't remove a paired iPhone")
        }
        await reloadDevices()
    }

    // MARK: Listener

    private func apply() {
        let approvals = self.approvals, ringing = enabled
        Task { await approvals.setRinging(ringing) }
        guard enabled else {
            server?.apply(CompanionServer.Configuration())
            qr = nil
            return
        }
        guard let server = server ?? makeServer() else { return }
        let tunnel = tunnelSecret.isEmpty ? nil : TunnelGate(secret: tunnelSecret, publicHost: tunnelHost)
        server.apply(CompanionServer.Configuration(enabled: true, modes: modes, port: port, tunnel: tunnel))
    }

    private func makeServer() -> CompanionServer? {
        let service = Identifiers.companionKeychainService + (Preferences.isDevelopmentVault ? ".dev" : "")
        let identity: MacIdentity
        do {
            identity = try KeychainMacIdentityStore(service: service).loadOrCreate()
        } catch {
            logger.error("The companion keys aren't available")
            keysUnavailable = true
            return nil
        }
        let server = CompanionServer(identity: identity, services: services, macName: { Self.macNameNonisolated() },
                                     appVersion: appVersion, approvals: approvals)
        server.statusChanged = { [weak self] status in self?.status = status }
        Task { [weak self] in
            await server.pairing.observe { state in
                Task { @MainActor in
                    self?.pairingState = state
                    if case .paired = state { await self?.reloadDevices() }
                }
            }
        }
        self.server = server
        return server
    }

    static func macName() -> String { macNameNonisolated() }

    /// The computer name from System Settings ▸ General ▸ Sharing ("Maya's MacBook Pro").
    nonisolated static func macNameNonisolated() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? String(localized: "Mac")
    }

    /// `maya.tailnet.ts.net` from whatever was pasted: a URL, a host with a port, spaces.
    static func normalizedHost(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: host), let parsed = url.host, url.scheme != nil { host = parsed }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        return host
    }
}
