import FunesPhone
import FunesProtocol
import Observation
import os
import SwiftUI

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "app")

/// The app's state: the pairing, how the Mac is reachable (UX: iPhone, States), and the
/// capture queue.
@MainActor @Observable
final class PhoneModel {
    enum Reachability: Equatable {
        case notPaired
        case checking
        case connected(MacConnection)
        case unreachable(localNetworkDenied: Bool)
        /// "This iPhone was removed from Funes on your Mac".
        case revoked
        case failed(String)
    }

    private(set) var record: PairingRecord?
    private(set) var reachability = Reachability.notPaired
    private(set) var lastChecked: Date?
    /// The phone's network, for the banner: a LAN address reached off Wi-Fi goes through a VPN.
    private(set) var path: NetworkPath?
    private(set) var usesSecureEnclave: Bool?
    private(set) var protocolChecks: [ProtocolCheck] = []
    /// Each address's probe in the last check (Debug's Spike 1 section).
    private(set) var probes: [ProbeOutcome] = []
    private(set) var spikeMessage: String?
    private var testCaptureID: UUID?

    let client: CompanionClient
    let capture: CaptureModel
    /// The Control asked for Capture, ready to type or dictate.
    private(set) var captureRequests = 0
    private var started = false
    private var refreshing = false

    init(client: CompanionClient = CompanionClient(store: KeychainSecretStore())) {
        self.client = client
        capture = CaptureModel(client: client)
        capture.onOutcome = { [weak self] outcome in self?.delivered(outcome) }
    }

    func start() async {
        guard !started else { return }
        started = true
        await reload()
        Task { [weak self] in
            for await path in NetworkPathWatcher.updates() {
                guard let self else { return }
                self.path = path
                await client.networkChanged()
                // Start over on a usable path; the first update is the current path, which the
                // foreground refresh already covers.
                if path.isSatisfied, self.record != nil, self.lastChecked != nil {
                    await self.refresh()
                    await self.capture.deliver(.pathChange)
                }
            }
        }
        // The share extension and the App Intents queued something, or the Control asked for
        // Capture.
        Task { [weak self] in
            for await _ in AppSignal.queueChanged.updates() {
                guard let self else { return }
                self.capture.reload()
                await self.capture.deliver(.captured)
            }
        }
        Task { [weak self] in
            for await _ in AppSignal.openCapture.updates() { self?.takeCaptureRequest() }
        }
        takeCaptureRequest()
        await refresh()
        await capture.deliver(.launch)
    }

    /// Coming to the front: `status.get`, then the queue (companion protocol §4, §6).
    func foreground() async {
        takeCaptureRequest()
        capture.reload()
        guard started else { return }
        await refresh()
        await capture.deliver(.foreground)
    }

    /// `BGAppRefreshTask`: send what's waiting, then ask for the next refresh, since the share
    /// extension and the Control can queue more while the app stays closed.
    func backgroundDelivery() async {
        capture.reload()
        if capture.queuedCount > 0 { await capture.deliver(.background) }
        await capture.scheduleBackgroundDelivery()
    }

    private func takeCaptureRequest() {
        if CaptureLaunch().take() { captureRequests += 1 }
    }

    private func delivered(_ outcome: DeliveryOutcome) {
        switch outcome {
        case .revoked: reachability = .revoked
        case .notPaired: reachability = .notPaired
        default: break
        }
    }

    private func reload() async {
        do {
            record = try await client.record()
        } catch {
            logger.error("Couldn't read the pairing")
            record = nil
        }
        usesSecureEnclave = await client.usesSecureEnclave()
        if record == nil { reachability = .notPaired }
    }

    /// `status.get`, on the cached address or by selecting one.
    func refresh(fresh: Bool = false) async {
        guard record != nil else {
            reachability = .notPaired
            return
        }
        // Launch and coming to the front both ask; one check at a time is enough.
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if case .connected = reachability {} else { reachability = .checking }
        do {
            reachability = .connected(try await client.status(fresh: fresh))
        } catch {
            reachability = Self.reachability(for: error)
        }
        probes = await client.lastProbes
        lastChecked = Date()
    }

    private static func reachability(for error: CompanionClientError) -> Reachability {
        switch error {
        case .notPaired: .notPaired
        case let .unreachable(denied): .unreachable(localNetworkDenied: denied)
        case .refused(.revoked), .refused(.unknownDevice): .revoked
        default: .failed(Self.message(for: error))
        }
    }

    /// Pairs with the scanned Mac. Returns how long it took, Allow click included (Spike 1a).
    func pair(_ payload: PairingQRPayload, deviceName: String) async throws(CompanionClientError) -> Duration {
        let start = ContinuousClock.now
        record = try await client.pair(payload, deviceName: deviceName, model: DeviceInfo.model)
        let elapsed = ContinuousClock.now - start
        usesSecureEnclave = await client.usesSecureEnclave()
        protocolChecks = []
        spikeMessage = nil
        testCaptureID = nil
        await refresh()
        // Captures made before pairing, or kept from a revoked pairing, go now.
        await capture.deliver(.manual)
        return elapsed
    }

    /// Unpair on the phone (§8): tells the Mac if it can, then forgets the keys and the pairing,
    /// and the queued captures if the user said so.
    func unpair(deletingQueue: Bool) async {
        do { try await client.unpair() } catch { logger.error("Couldn't delete the pairing") }
        if deletingQueue { capture.deleteAll() }
        await reload()
        protocolChecks = []
        spikeMessage = nil
    }

    // MARK: Spike 1 (Debug builds)

    func runProtocolChecks() async {
        do { protocolChecks = try await client.protocolChecks() } catch {
            protocolChecks = []
            spikeMessage = Self.message(for: error)
        }
    }

    /// Sends a capture to the Mac (rows 1b and 1c); `again` resends the last one with the same id,
    /// which the Mac accepts as a duplicate without storing it twice.
    func sendTestCapture(again: Bool) async {
        let id = again ? (testCaptureID ?? UUID()) : UUID()
        testCaptureID = id
        let capture = CompanionCapture(captureId: id, text: "Spike 1 test capture \(id.uuidString.prefix(8))", createdAt: Date(),
                                       source: .typed)
        let start = ContinuousClock.now
        do {
            let result = try await client.call(CapturesSubmit.self, CapturesSubmitParams(captures: [capture]))
            let ms = (ContinuousClock.now - start).milliseconds
            spikeMessage = result.accepted.contains(id)
                ? String(localized: "Accepted \(String(id.uuidString.prefix(8))) in \(ms) ms")
                : String(localized: "Rejected: \(result.rejected.first?.reason.rawValue ?? "?")")
        } catch {
            spikeMessage = Self.message(for: error)
        }
    }

    // MARK: Messages

    static func message(for error: CompanionClientError) -> String {
        switch error {
        case .notPaired:
            String(localized: "This iPhone isn't paired with a Mac.")
        case .unreachable(localNetworkDenied: true):
            String(localized: "Funes isn't allowed on your local network. Turn it on in Settings ▸ Privacy & Security ▸ Local Network, then try again.")
        case .unreachable:
            String(localized: "Couldn't reach your Mac. Make sure both are on the same Wi-Fi, or set up Tailscale on both.")
        case .qrExpired, .pairing(.expired):
            String(localized: "This code has expired. Show a new one on your Mac.")
        case .pairing(.denied):
            String(localized: "Pairing was declined on your Mac.")
        case .pairing(.tooManyAttempts):
            String(localized: "Too many tries with this code. Show a new one on your Mac.")
        case .pairing(.tooManyDevices):
            String(localized: "Five iPhones are already paired with this Mac. Remove one in Funes Settings ▸ iPhone.")
        case .pairing:
            String(localized: "This code didn't match your Mac. Show a new one and scan again.")
        case .refused(.revoked), .refused(.unknownDevice):
            String(localized: "This iPhone was removed from Funes on your Mac.")
        case let .refused(refusal):
            String(localized: "Your Mac refused the request (\(refusal.code)).")
        case let .method(error):
            String(localized: "Your Mac couldn't do that (\(error.code.rawValue)).")
        case let .badResponse(status):
            String(localized: "Something else answered at your Mac's address (HTTP \(status)).")
        case .local:
            String(localized: "Something went wrong on this iPhone. Try again.")
        }
    }
}

extension Duration {
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}
