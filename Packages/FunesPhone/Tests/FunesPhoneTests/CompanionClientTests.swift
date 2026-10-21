import CryptoKit
import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// A phone and a fake Mac reachable at the hosts the routes name.
struct Rig {
    let clock = TestClock()
    let store = MemorySecretStore()
    let mac: FakeMac
    let transport: RoutedTransport
    let client: CompanionClient

    init(routes: (FakeMac) -> [String: RoutedTransport.Route] = { ["192.168.1.20": .mac($0)] },
         discovery: DiscoveryResult = DiscoveryResult(), discoveryDelay: Duration = .zero) {
        mac = FakeMac(clock: clock)
        transport = RoutedTransport(routes(mac))
        let clock = clock
        client = CompanionClient(store: store, transport: transport, discovery: FakeDiscovery(result: discovery, delay: discoveryDelay),
                                 secureEnclave: false, clock: { clock.now })
    }

    @discardableResult
    func pair(_ addresses: [PairingAddress] = Addresses.all) async throws -> PairingRecord {
        try await client.pair(mac.payload(addresses), deviceName: "Sam's iPhone", model: "iPhone14,4")
    }
}

@Suite struct PairingTests {
    @Test func pairsAndSavesKeysAndRecord() async throws {
        let rig = Rig()
        let record = try await rig.pair()
        #expect(record.macID == rig.mac.macID)
        #expect(record.macName == "Maya's MacBook Pro")
        #expect(record.deviceName == "Sam's iPhone")
        #expect(record.addresses == Addresses.all)
        #expect(rig.store.accounts == ["device-signing", "device-hpke", "pairing"])
        #expect(try await rig.client.record() == record)
        #expect(await rig.client.usesSecureEnclave() == false)

        // A new client on the same Keychain picks the pairing up and can call.
        let clock = rig.clock
        let again = CompanionClient(store: rig.store, transport: rig.transport, discovery: FakeDiscovery(result: DiscoveryResult()),
                                    secureEnclave: false, clock: { clock.now })
        let connection = try await again.status()
        #expect(connection.status.macName == "Maya's MacBook Pro")
        #expect(connection.address.kind == .lan)
    }

    @Test func deniedOnTheMacSavesNothing() async throws {
        let rig = Rig()
        rig.mac.allow = false
        await #expect(throws: CompanionClientError.pairing(.denied)) { try await rig.pair() }
        #expect(rig.store.accounts.isEmpty)
        #expect(try await rig.client.record() == nil)
        await #expect(throws: CompanionClientError.notPaired) { try await rig.client.status() }
    }

    @Test func expiredCodeNeverTouchesTheNetwork() async throws {
        let rig = Rig()
        let payload = rig.mac.payload(Addresses.all, expiresIn: -1)
        await #expect(throws: CompanionClientError.qrExpired) {
            try await rig.client.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        }
        #expect(rig.transport.hosts.isEmpty)
    }

    @Test func probesBeforeSpendingAnAttempt() async throws {
        // LAN refuses, something else answers on the Tailscale address, the tunnel is the Mac.
        let rig = Rig(routes: { ["100.101.102.103": .status(404), "maya.example.ts.net": .mac($0)] })
        _ = try await rig.pair()
        #expect(rig.mac.pairAttempts == 1)
        #expect(await rig.client.currentAddress?.kind == .tunnel)
    }

    @Test func unreachableMac() async throws {
        let rig = Rig(routes: { _ in [:] })
        await #expect(throws: CompanionClientError.unreachable(localNetworkDenied: false)) { try await rig.pair() }
        #expect(rig.mac.pairAttempts == 0)
    }

    @Test func localNetworkDenied() async throws {
        let rig = Rig(routes: { _ in [:] }, discovery: DiscoveryResult(localNetworkDenied: true))
        await #expect(throws: CompanionClientError.unreachable(localNetworkDenied: true)) { try await rig.pair([Addresses.lan]) }
    }

    @Test func unpairTellsTheMacAndForgets() async throws {
        let rig = Rig()
        let record = try await rig.pair()
        try await rig.client.unpair()
        #expect(rig.mac.unpaired == [record.deviceID])
        #expect(rig.store.accounts.isEmpty)
        #expect(try await rig.client.record() == nil)
    }

    @Test func rePairingReplacesTheKeys() async throws {
        let rig = Rig()
        let first = try await rig.pair()
        let firstKey = try #require(try rig.store.read("device-signing"))
        let second = try await rig.pair()
        #expect(first.deviceID != second.deviceID)
        #expect(try rig.store.read("device-signing") != firstKey)
        #expect(try await rig.client.status().status.vaultActive)
    }
}

@Suite struct AddressSelectionTests {
    @Test func sameWiFiWinsOverTailscaleAndTunnel() async throws {
        let rig = Rig(routes: { ["192.168.1.20": .mac($0), "100.101.102.103": .mac($0), "maya.example.ts.net": .mac($0)] })
        try await rig.pair()
        let connection = try await rig.client.status(fresh: true)
        #expect(connection.address.kind == .lan)
    }

    @Test func bonjourHitWhenTheSavedAddressIsStale() async throws {
        let bonjour = try #require(MacAddress(kind: .bonjour, host: "192.168.1.44", port: 47626))
        let rig = Rig(routes: { ["192.168.1.20": .mac($0), "192.168.1.44": .mac($0)] }, discovery: DiscoveryResult(addresses: [bonjour]))
        try await rig.pair()
        rig.transport.set("192.168.1.20", .refused)
        let connection = try await rig.client.status(fresh: true)
        #expect(connection.address == bonjour)
    }

    @Test func tailscaleThenTunnel() async throws {
        let rig = Rig(routes: { ["192.168.1.20": .mac($0), "100.101.102.103": .mac($0), "maya.example.ts.net": .mac($0)] })
        try await rig.pair()
        rig.transport.set("192.168.1.20", .refused)
        #expect(try await rig.client.status(fresh: true).address.kind == .tailscale)
        rig.transport.set("100.101.102.103", .refused)
        #expect(try await rig.client.status(fresh: true).address.kind == .tunnel)
        rig.transport.set("maya.example.ts.net", .refused)
        await #expect(throws: CompanionClientError.unreachable(localNetworkDenied: false)) { try await rig.client.status(fresh: true) }
    }

    @Test func waitsForABetterAddressOnlyUntilItsProbeTimesOut() async throws {
        let rig = Rig(routes: { ["192.168.1.20": .mac($0), "100.101.102.103": .mac($0)] })
        try await rig.pair([Addresses.lan, Addresses.tailscale])
        rig.transport.set("192.168.1.20", .silent)
        let start = ContinuousClock.now
        let connection = try await rig.client.status(fresh: true)
        let elapsed = ContinuousClock.now - start
        #expect(connection.address.kind == .tailscale)
        #expect(elapsed >= .seconds(CompanionClient.probeTimeout) && elapsed < .seconds(CompanionClient.probeTimeout + 2))
    }

    @Test func doesNotWaitForWorseAddresses() async throws {
        let rig = Rig(routes: { ["192.168.1.20": .mac($0), "100.101.102.103": .silent] })
        try await rig.pair([Addresses.lan, Addresses.tailscale])
        let start = ContinuousClock.now
        #expect(try await rig.client.status(fresh: true).address.kind == .lan)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func cachesTheAddressForTenMinutes() async throws {
        let rig = Rig(routes: { ["192.168.1.20": .mac($0), "100.101.102.103": .mac($0)] })
        try await rig.pair([Addresses.lan, Addresses.tailscale])
        _ = try await rig.client.status(fresh: true)
        let probes = rig.transport.count("100.101.102.103")

        _ = try await rig.client.status()
        _ = try await rig.client.status()
        #expect(rig.transport.count("100.101.102.103") == probes)

        rig.clock.advance(CompanionClient.addressLifetime + 1)
        #expect(await rig.client.currentAddress == nil)
        _ = try await rig.client.status()
        #expect(rig.transport.count("100.101.102.103") == probes + 1)

        await rig.client.networkChanged()
        #expect(await rig.client.currentAddress == nil)
    }

    @Test func aRevokedDeviceIsToldSo() async throws {
        let rig = Rig()
        let record = try await rig.pair()
        rig.mac.revoke(record.deviceID)
        await #expect(throws: CompanionClientError.refused(.revoked)) { try await rig.client.status() }
        await #expect(throws: CompanionClientError.refused(.revoked)) { try await rig.client.status(fresh: true) }
    }
}

@Suite struct CallTests {
    @Test func clockSkewIsRetriedWithTheMacsTime() async throws {
        let rig = Rig()
        try await rig.pair()
        // The Mac's clock is ten minutes ahead: the first try is `clock_skew`, the retry works,
        // and later calls use the learnt offset straight away.
        rig.mac.skew = 600
        let connection = try await rig.client.status()
        #expect(connection.status.serverTime == t0.addingTimeInterval(600))
        let calls = rig.transport.count("192.168.1.20")
        _ = try await rig.client.status()
        #expect(rig.transport.count("192.168.1.20") == calls + 1)
    }

    @Test func aRepeatableCallIsResentAfterNoAnswer() async throws {
        let rig = Rig(routes: { ["192.168.1.20": .mac($0), "100.101.102.103": .mac($0)] })
        try await rig.pair([Addresses.lan, Addresses.tailscale])
        _ = try await rig.client.status()
        // The answer is lost after the Mac stored the capture; the resend is a duplicate.
        rig.transport.dropResponses = true
        let capture = CompanionCapture(captureId: UUID(), text: "Prefers aisle seats", createdAt: t0, source: .typed)
        await #expect(throws: CompanionClientError.unreachable(localNetworkDenied: false)) {
            try await rig.client.call(CapturesSubmit.self, CapturesSubmitParams(captures: [capture]))
        }
        rig.transport.dropResponses = false
        let result = try await rig.client.call(CapturesSubmit.self, CapturesSubmitParams(captures: [capture]))
        #expect(result.accepted == [capture.captureId])
        #expect(rig.mac.receiptCount == 1)

        // The cached address goes away mid-session: the call moves to Tailscale by itself.
        rig.transport.set("192.168.1.20", .refused)
        let moved = try await rig.client.call(CapturesSubmit.self, CapturesSubmitParams(captures: [capture]))
        #expect(moved.accepted == [capture.captureId])
        #expect(await rig.client.currentAddress?.kind == .tailscale)
    }

    @Test func anUnsafeCallIsNotResent() async throws {
        let rig = Rig(routes: { ["192.168.1.20": .mac($0), "100.101.102.103": .mac($0)] })
        try await rig.pair([Addresses.lan, Addresses.tailscale])
        _ = try await rig.client.status()
        rig.transport.set("192.168.1.20", .refused)
        let before = rig.transport.count("100.101.102.103")
        await #expect(throws: CompanionClientError.unreachable(localNetworkDenied: false)) {
            try await rig.client.call(DeviceUnpair.self, EmptyParams())
        }
        #expect(rig.transport.count("100.101.102.103") == before)
        #expect(await rig.client.currentAddress == nil)
    }

    @Test func methodErrorsComeThrough() async throws {
        let rig = Rig()
        try await rig.pair()
        await #expect(throws: CompanionClientError.method(CompanionError(.unknownMethod))) {
            try await rig.client.call(CategoriesList.self, EmptyParams())
        }
    }

    @Test func protocolChecksAllPass() async throws {
        let rig = Rig()
        try await rig.pair()
        let checks = try await rig.client.protocolChecks()
        #expect(checks.map(\.got) == ["ok", "replay", "invalid_signature", "clock_skew"])
        #expect(checks.allSatisfy { $0.passed })
    }
}

@Suite struct AddressTests {
    @Test func urls() throws {
        #expect(MacAddress(Addresses.lan)?.url(CompanionProtocol.rpcPath).absoluteString == "http://192.168.1.20:47626/c/v1/rpc")
        #expect(MacAddress(PairingAddress(kind: .lan, host: "maya-mbp.local"))?.base.absoluteString == "http://maya-mbp.local:47626")
        #expect(MacAddress(kind: .lan, host: "fe80::1%en0", port: 47626)?.base.absoluteString == "http://[fe80::1%25en0]:47626")
        #expect(MacAddress(PairingAddress(kind: .tunnel, url: "https://maya.example.ts.net/r/abc/"))?.url(CompanionProtocol.pairPath)
            .absoluteString == "https://maya.example.ts.net/r/abc/c/v1/pair")
        #expect(MacAddress(Addresses.tailscale)?.connectionKind == .tailscale)
    }

    @Test func refusesWhatIsNotAnAddress() {
        #expect(MacAddress(PairingAddress(kind: .tunnel, url: "http://maya.example.ts.net/r/abc")) == nil)
        #expect(MacAddress(PairingAddress(kind: .tunnel, url: "https://maya.example.ts.net/r/abc?x=1")) == nil)
        #expect(MacAddress(PairingAddress(kind: .lan)) == nil)
        #expect(MacAddress(PairingAddress(kind: .lan, host: "evil.com/x")) == nil)
        #expect(MacAddress(PairingAddress(kind: .lan, host: "a@b")) == nil)
    }

    @Test func savedAddressesDropDuplicates() {
        #expect([Addresses.lan, Addresses.lan, Addresses.tunnel].macAddresses.map(\.kind) == [.lan, .tunnel])
    }
}

@Suite struct KeyStoreTests {
    @Test func softwareKeysRoundTrip() throws {
        let store = MemorySecretStore()
        let keys = DeviceKeyStore(store: store)
        #expect(try keys.load() == nil)
        let made = DeviceKeys.fresh(secureEnclave: false)
        try keys.save(made)
        let loaded = try #require(try keys.load())
        #expect(loaded.signer.publicKey.rawRepresentation == made.signer.publicKey.rawRepresentation)
        #expect(loaded.hpke.publicKey.rawRepresentation == made.hpke.publicKey.rawRepresentation)
        let message = Data("funes".utf8)
        #expect(made.signer.publicKey.isValidSignature(try loaded.signer.signature(for: message), for: message))
        try keys.delete()
        #expect(try keys.load() == nil)
    }

    @Test func aBrokenItemIsUnreadable() throws {
        let store = MemorySecretStore()
        try DeviceKeyStore(store: store).save(DeviceKeys.fresh(secureEnclave: false))
        try store.write(Data("nope".utf8), account: "device-signing")
        #expect(throws: DeviceKeyError.unreadable) { try DeviceKeyStore(store: store).load() }
    }

    @Test(.enabled(if: SecureEnclave.isAvailable)) func secureEnclaveKeyRoundTrips() throws {
        let made = DeviceKeys.fresh(secureEnclave: true)
        // Some test hosts can't create Secure Enclave keys; the fallback is then a software key.
        guard made.signer.isSecureEnclave else { return }
        let store = MemorySecretStore()
        try DeviceKeyStore(store: store).save(made)
        let loaded = try #require(try DeviceKeyStore(store: store).load())
        #expect(loaded.signer.isSecureEnclave)
        let message = Data("funes".utf8)
        #expect(made.signer.publicKey.isValidSignature(try loaded.signer.signature(for: message), for: message))
    }

    @Test func pairingRecordRoundTrips() throws {
        let store = MemorySecretStore()
        let mac = FakeMac(clock: TestClock())
        let payload = mac.payload(Addresses.all)
        let record = PairingRecord(payload: payload, confirmation: PairConfirmation(deviceID: UUID(), macID: mac.macID, confirm: Data()),
                                   deviceName: "Sam's iPhone", pairedAt: t0)
        try PairingRecordStore(store: store).save(record)
        #expect(try PairingRecordStore(store: store).load() == record)
        #expect(record.bonjourTag == CompanionBonjour.macTag(mac.macID))
    }
}
