import BridgeKitCore
import Foundation
import FunesCore
import FunesPhone
import FunesProtocol
import Testing
@testable import FunesCompanion

/// The rows of the companion protocol's test plan (§9) that the other suites cover from one side
/// only, run here with the iPhone's `CompanionClient` against the real router and vault (task
/// 5.8): the three ways to reach the Mac, a tunnel with the wrong path or Host, the Mac asleep
/// with 1,000 captures queued and then woken, pairing's refusals and an unknown device as the
/// phone sees them, and fuzzed method params through the real handlers.
@Suite struct TestPlanTests {
    static let lanHost = "192.168.1.20"
    static let tailscaleHost = "100.89.20.22"
    static let tunnelHost = "maya.tailnet.ts.net"

    /// The phone's networks: posts go to the router as the listener would hand them over, by the
    /// URL's kind (`https` is the tunnel, 100.x is Tailscale, anything else the LAN), unless that
    /// network is down, which looks like a Mac that doesn't answer.
    final class Networks: CompanionTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var mac: CompanionHarness
        private var down: Set<DeviceTransport> = []
        private var posted: [DeviceTransport] = []

        init(harness: CompanionHarness) { mac = harness }

        func setDown(_ transports: Set<DeviceTransport>) { lock.withLock { down = transports } }
        /// Another Mac answers at the same addresses.
        func replaceMac(_ harness: CompanionHarness) { lock.withLock { mac = harness } }
        /// The posts that reached the Mac, by transport.
        var reached: [DeviceTransport] { lock.withLock { posted } }

        static func transport(_ url: URL) -> DeviceTransport {
            if url.scheme == "https" { return .tunnel }
            return url.host()?.hasPrefix("100.") == true ? .tailscale : .lan
        }

        func post(_ url: URL, body: Data, timeout: TimeInterval) async throws(TransportError) -> TransportResponse {
            let transport = Self.transport(url)
            let harness: CompanionHarness? = lock.withLock {
                guard !down.contains(transport) else { return nil }
                posted.append(transport)
                return mac
            }
            guard let harness else { throw .timedOut }
            let host = url.host().map { name in url.port.map { "\(name):\($0)" } ?? name } ?? ""
            let response = await harness.router.handle(CompanionHarness.request(url.path(), body: body, host: host), transport: transport)
            return TransportResponse(status: response.status, body: response.body)
        }
    }

    /// A QR code naming the Mac's LAN address, its Tailscale IP and a tunnel URL.
    func qr(_ h: CompanionHarness, tunnel: String) async -> PairingQRPayload {
        await h.pairing.start(macName: "Maya's MacBook Pro", addresses: [
            PairingAddress(kind: .lan, host: Self.lanHost, port: 47626),
            PairingAddress(kind: .tailscale, host: Self.tailscaleHost, port: 47626),
            PairingAddress(kind: .tunnel, url: tunnel),
        ], now: h.clock.now)
    }

    func phone(_ h: CompanionHarness, networks: Networks, clock: (@Sendable () -> Date)? = nil) -> CompanionClient {
        let macClock = h.clock
        return CompanionClient(store: MemorySecretStore(), transport: networks, discovery: PhoneClientTests.NoBonjour(),
                               secureEnclave: false, clock: clock ?? { macClock.now })
    }

    func paired(_ h: CompanionHarness, gate: TunnelGate) async throws -> (CompanionClient, Networks, UUID) {
        let networks = Networks(harness: h)
        let client = phone(h, networks: networks)
        let payload = await qr(h, tunnel: "https://\(gate.publicHost)/r/\(gate.secret)")
        async let paired = client.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        try await h.answerWhenAsked(true)
        return (client, networks, try await paired.deviceID)
    }

    // MARK: Reachability

    /// Same Wi-Fi, then Tailscale, then the tunnel (§5): each network that goes away hands over
    /// to the next, and the Mac records how the phone's calls came in. (Address selection probes
    /// every saved address at once, so the probes that lose also reach the Mac; the transport is
    /// checked after a call, which goes only to the chosen address.)
    @Test func sameWiFiThenTailscaleThenTunnel() async throws {
        let gate = TunnelGate(secret: TunnelGate.newSecret(), publicHost: Self.tunnelHost)
        let h = try CompanionHarness(gate: gate)
        let (client, networks, deviceID) = try await paired(h, gate: gate)
        func capture(_ text: String) async throws -> DeviceTransport? {
            let capture = CompanionCapture(captureId: UUID(), text: text, createdAt: h.clock.now, source: .typed)
            #expect(try await client.call(CapturesSubmit.self, CapturesSubmitParams(captures: [capture])).accepted == [capture.captureId])
            return try await h.services.devices.device(id: deviceID)?.lastTransport
        }

        #expect(try await client.status(fresh: true).address.kind == .lan)
        #expect(try await capture("Sent on the same Wi-Fi") == .lan)

        networks.setDown([.lan])
        await client.networkChanged()
        let tailscale = try await client.status()
        #expect(tailscale.address.kind == .tailscale && tailscale.address.connectionKind == .tailscale)
        #expect(try await capture("Sent over Tailscale") == .tailscale)

        networks.setDown([.lan, .tailscale])
        await client.networkChanged()
        #expect(try await client.status().address.connectionKind == .tunnel)
        #expect(try await capture("Sent through the tunnel") == .tunnel)
        #expect(try await h.services.suggestions.pending().count == 3)

        // Back on the same Wi-Fi, it's preferred again.
        networks.setDown([])
        await client.networkChanged()
        #expect(try await client.status().address.kind == .lan)
    }

    /// A tunnel URL the Mac no longer serves (a new secret path, or another host name) is
    /// refused before the envelope is read: the phone says the Mac isn't reachable, and the
    /// probe says why.
    @Test(arguments: [("wrong path", 404), ("wrong host", 421)])
    func aTunnelWithTheWrongPathOrHost(_ change: String, status: Int) async throws {
        let gate = TunnelGate(secret: TunnelGate.newSecret(), publicHost: Self.tunnelHost)
        let h = try CompanionHarness(gate: gate)
        let networks = Networks(harness: h)
        let client = phone(h, networks: networks)
        let tunnel = change == "wrong path" ? "https://\(Self.tunnelHost)/r/\(TunnelGate.newSecret())"
                                            : "https://maya-old.tailnet.ts.net/r/\(gate.secret)"
        let payload = await qr(h, tunnel: tunnel)
        async let paired = client.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        try await h.answerWhenAsked(true)
        let deviceID = try await paired.deviceID
        let seen = try await h.services.devices.device(id: deviceID)?.lastSeenAt

        networks.setDown([.lan, .tailscale])
        await client.networkChanged()
        h.clock.advance(60)
        await #expect(throws: CompanionClientError.unreachable(localNetworkDenied: false)) { try await client.status() }
        let probe = try #require(await client.lastProbes.first { $0.address.kind == .tunnel })
        #expect(probe.outcome == "HTTP \(status)")
        #expect(networks.reached.last == .tunnel)
        // Nothing got as far as the device: it wasn't seen again.
        #expect(try await h.services.devices.device(id: deviceID)?.lastSeenAt == seen)
    }

    /// Mac asleep, then woken, with a full queue (§6, §9): 1,000 captures wait while nothing
    /// answers, the banner says so, and after the wake they arrive once each, 50 to a call.
    @Test func macAsleepWithAThousandQueuedThenWoken() async throws {
        let gate = TunnelGate(secret: TunnelGate.newSecret(), publicHost: Self.tunnelHost)
        let h = try CompanionHarness(gate: gate)
        let (client, networks, _) = try await paired(h, gate: gate)
        let clock = h.clock
        var tracker = ReachabilityTracker()
        tracker.handle(.pairing(paired: true))
        tracker.handle(.checked(.success(try await client.status(fresh: true)), at: clock.now))

        // Asleep: no address answers.
        networks.setDown([.lan, .tailscale, .tunnel])
        await client.networkChanged()
        let folder = FileManager.default.temporaryDirectory.appending(path: "funes-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = CaptureQueue(url: folder.appending(path: CaptureQueue.fileName))
        var ids: Set<UUID> = []
        for i in 0..<CaptureQueue.capacity {
            ids.insert(try queue.add("Asleep capture \(i)", source: .share, now: clock.now.addingTimeInterval(Double(i) / 10)).id)
        }
        #expect(throws: CaptureQueueError.full) { try queue.add("One too many", source: .typed, now: clock.now) }
        let delivery = CaptureDelivery(queue: queue, sender: client, clock: { clock.now }, jitter: { 1 })
        let asleep = await delivery.deliver(.captured)
        guard case .failed(.unreachable, _, sent: 0) = asleep else {
            Issue.record("expected the Mac to look unreachable, got \(asleep)")
            return
        }
        tracker.handle(.delivered(asleep))
        #expect(tracker.state == .unreachable(localNetworkDenied: false))
        #expect(BannerState(tracker.state, macName: "Maya's MacBook Pro", waiting: try queue.queuedCount(), path: nil)
            == .unreachable(waiting: 1_000))
        #expect(try await h.services.suggestions.pending().isEmpty)

        // Woken: the network path changes, which skips the backoff.
        networks.setDown([])
        await client.networkChanged()
        let before = networks.reached.filter { $0 == .lan }.count
        #expect(await delivery.deliver(.pathChange) == .drained(sent: 1_000, rejected: 0))
        tracker.handle(.checked(.success(try await client.status()), at: clock.now))
        #expect(tracker.state.isConnected)
        // Over the same Wi-Fi: the probe that chose it, 20 calls of 50, then the status check.
        #expect(networks.reached.filter { $0 == .lan }.count - before == 1 + 20 + 1)
        #expect(try queue.queuedCount() == 0)
        let pending = try await h.services.suggestions.pending()
        #expect(pending.count == 1_000)
        #expect(Set(pending.compactMap(\.captureID)) == ids)
        #expect(await delivery.deliver(.foreground) == .drained(sent: 0, rejected: 0))
    }

    // MARK: Pairing and the envelope, from the phone

    /// A wrong secret (a QR code read wrong, or made up) is refused, and so is a 4th attempt on
    /// the same code even with the right secret (§2.3).
    @Test func aWrongSecretThenAFourthAttemptFromThePhone() async throws {
        let h = try CompanionHarness()
        let networks = Networks(harness: h)
        let payload = await qr(h, tunnel: "https://\(Self.tunnelHost)/r/\(TunnelGate.newSecret())")
        var wrong = payload
        wrong.secret = Data(repeating: 7, count: payload.secret.count)
        for _ in 0..<CompanionProtocol.maxPairingAttempts {
            await #expect(throws: CompanionClientError.pairing(.invalidProof)) {
                try await phone(h, networks: networks).pair(wrong, deviceName: "Sam's iPhone", model: "iPhone14,4")
            }
        }
        let fourth = phone(h, networks: networks)
        await #expect(throws: CompanionClientError.pairing(.tooManyAttempts)) {
            try await fourth.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        }
        #expect(try await fourth.record() == nil)
        #expect(try await h.services.devices.devices().isEmpty)
    }

    /// The QR code's 5 minutes ran out on the Mac while the phone, its clock a minute behind,
    /// still thought it valid: the Mac refuses it as expired.
    @Test func aCodeThatExpiredOnTheMac() async throws {
        let h = try CompanionHarness()
        let networks = Networks(harness: h)
        let macClock = h.clock
        let client = phone(h, networks: networks, clock: { macClock.now.addingTimeInterval(-61) })
        let payload = await qr(h, tunnel: "https://\(Self.tunnelHost)/r/\(TunnelGate.newSecret())")
        h.clock.advance(CompanionProtocol.pairingLifetime + 1)
        await #expect(throws: CompanionClientError.pairing(.expired)) {
            try await client.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        }
    }

    /// A phone whose clock is 5 minutes off is told the Mac's time and retries once (§3); a phone
    /// the Mac doesn't know (its vault was replaced, same Mac keys) is told so, and the banner
    /// asks to pair again.
    @Test func aSkewedClockThenAnUnknownDevice() async throws {
        let gate = TunnelGate(secret: TunnelGate.newSecret(), publicHost: Self.tunnelHost)
        let h = try CompanionHarness(gate: gate)
        let networks = Networks(harness: h)
        let macClock = h.clock
        let phoneBehind = Locked(0.0)
        let client = phone(h, networks: networks, clock: { macClock.now.addingTimeInterval(-phoneBehind.value) })
        let payload = await qr(h, tunnel: "https://\(Self.tunnelHost)/r/\(gate.secret)")
        async let pairing = client.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        try await h.answerWhenAsked(true)
        _ = try await pairing
        phoneBehind.value = 300
        networks.setDown([.tailscale, .tunnel])
        let reached = networks.reached.count
        #expect(try await client.status(fresh: true).status.macName == "Maya's MacBook Pro")
        // The probe that met `clock_skew` and its retry; the next call goes straight through.
        #expect(networks.reached.count - reached == 2)
        _ = try await client.call(CategoriesList.self, EmptyParams())
        #expect(networks.reached.count - reached == 3)

        // The Mac's vault is replaced; its keys and addresses stay.
        networks.setDown([])
        networks.replaceMac(try CompanionHarness(gate: gate, identity: h.identity))
        await #expect(throws: CompanionClientError.refused(.unknownDevice)) { try await client.status(fresh: true) }
        var tracker = ReachabilityTracker()
        tracker.handle(.pairing(paired: true))
        tracker.handle(.checked(.failure(.refused(.unknownDevice)), at: macClock.now))
        #expect(tracker.state == .revoked)
    }

    final class Locked<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    // MARK: Fuzzing the method params

    /// SplitMix64, seeded so a failure can be reproduced.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let keys = ["id", "version", "query", "captures", "captureId", "text", "note", "createdAt", "source", "changes", "title",
                       "body", "kind", "categories", "sensitivity", "expiresAt", "filters", "status", "limit", "cursor", "suggestionId",
                       "edits", "reason", "memoryIds", "revision", "choice", "ring", "enabled", "keywords", "sensitivities", "kinds"]

    static func value(depth: Int, using rng: inout Seeded) -> Any {
        switch Int.random(in: 0..<(depth > 2 ? 9 : 11), using: &rng) {
        case 0: return Int.random(in: -3...3, using: &rng)
        case 1: return [Int.min, Int.max, Int(Int32.max) + 1, -1].randomElement(using: &rng)!
        case 2: return Double.random(in: -1e12...1e12, using: &rng)
        case 3: return Bool.random(using: &rng)
        case 4: return NSNull()
        case 5: return UUID().uuidString
        case 6: return ["", " ", "2026-10-22T10:00:00Z", "not a date", "share", "typed", "low", "high", "active", "archived", "deleted",
                        "allow_once", "always_allow", "deny", "share", "save", "health", String(repeating: "x", count: 20_001)]
                       .randomElement(using: &rng)!
        case 7: return String(decoding: (0..<Int.random(in: 0...40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) },
                              as: UTF8.self)
        case 8: return Base64URL.encode(Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        case 9: return (0..<Int.random(in: 0...4, using: &rng)).map { _ in value(depth: depth + 1, using: &rng) }
        default: return object(depth: depth + 1, using: &rng)
        }
    }

    static func object(depth: Int, using rng: inout Seeded) -> [String: Any] {
        var object: [String: Any] = [:]
        for _ in 0..<Int.random(in: 0...5, using: &rng) {
            object[keys.randomElement(using: &rng)!] = value(depth: depth, using: &rng)
        }
        return object
    }

    /// Every method but `device.unpair` (which would end the run) with random params: the Mac
    /// answers each with a sealed reply carrying the call's id and either a result or an error
    /// other than `internal_error`, and still works afterwards.
    @Test func fuzzedParamsThroughTheRealHandlers() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        _ = try await h.result(MemoriesCreate.self, MemoryCreateParams(
            title: "Coffee", body: "Oat flat white", kind: .preference, categories: ["personal_preferences"], sensitivity: .low), phone: phone)
        var rng = Seeded(state: 0x5E_ED)
        let methods = CompanionMethod.allCases.filter { $0 != .deviceUnpair }
        var answered: [CompanionErrorCode?: Int] = [:]
        for i in 0..<(methods.count * 60) {
            let method = methods[i % methods.count]
            let params: Any = Int.random(in: 0..<8, using: &rng) == 0 ? Self.value(depth: 2, using: &rng) : Self.object(depth: 0, using: &rng)
            let plaintext = try JSONSerialization.data(withJSONObject: ["id": "f\(i)", "method": method.rawValue, "params": params],
                                                       options: [.fragmentsAllowed])
            h.clock.advance(1) // under the per-minute call limit
            let sealed = try CompanionRequestEnvelope.seal(plaintext, deviceID: phone.deviceID!, macHPKEKey: h.identity.hpkeKey.publicKey,
                                                           signer: phone.signer, now: h.clock.now)
            let response = await h.router.handle(CompanionHarness.request(CompanionProtocol.rpcPath, body: sealed.envelope.body),
                                                 transport: .lan)
            try #require(response.status == 200, "\(method.rawValue), iteration \(i)")
            let reply = try #require(try JSONSerialization.jsonObject(with: try sealed.responseKey.open(response.body)) as? [String: Any])
            #expect(reply["id"] as? String == "f\(i)")
            if let error = reply["error"] as? [String: Any] {
                let code = CompanionErrorCode(rawValue: error["code"] as? String ?? "")
                #expect(code != nil && code != .internalError, "\(method.rawValue), iteration \(i): \(error)")
                answered[code, default: 0] += 1
            } else {
                #expect(reply["result"] != nil, "\(method.rawValue), iteration \(i)")
                answered[nil, default: 0] += 1
            }
        }
        #expect(answered[.invalidInput, default: 0] > 0)
        #expect(try await h.result(StatusGet.self, EmptyParams(), phone: phone).macName == "Maya's MacBook Pro")
    }
}
