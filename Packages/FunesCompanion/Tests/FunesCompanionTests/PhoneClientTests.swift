import BridgeKitCore
import Foundation
import FunesCore
import FunesPhone
import FunesProtocol
import Testing
@testable import FunesCompanion

/// The iPhone's `CompanionClient` (task 5.3) against the real router, pairing service and
/// handlers: the two halves of the protocol written separately, meeting in one process.
@Suite struct PhoneClientTests {
    /// Posts straight to `CompanionRouter.handle`, as if from a phone on the same Wi-Fi.
    struct RouterTransport: CompanionTransport {
        let harness: CompanionHarness

        func post(_ url: URL, body: Data, timeout: TimeInterval) async throws(TransportError) -> TransportResponse {
            let response = await harness.router.handle(CompanionHarness.request(url.path(), body: body), transport: .lan)
            return TransportResponse(status: response.status, body: response.body)
        }
    }

    struct NoBonjour: MacDiscovery {
        func find(tag: String, timeout: TimeInterval) async -> DiscoveryResult { DiscoveryResult() }
    }

    func client(_ h: CompanionHarness, store: MemorySecretStore = MemorySecretStore()) -> CompanionClient {
        let clock = h.clock
        return CompanionClient(store: store, transport: RouterTransport(harness: h), discovery: NoBonjour(), secureEnclave: false,
                               clock: { clock.now })
    }

    @Test func pairsThenCallsAsTheOwner() async throws {
        let h = try CompanionHarness()
        let phone = client(h)
        let payload = await h.qr()
        async let paired = phone.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        try await h.answerWhenAsked(true)
        let record = try await paired
        #expect(record.macID == h.identity.macID)

        let devices = try await h.services.devices.devices()
        #expect(devices.map(\.id) == [record.deviceID])
        #expect(devices.first?.name == "Sam's iPhone")

        let connection = try await phone.status()
        #expect(connection.status.macName == "Maya's MacBook Pro")
        #expect(connection.address.kind == .lan)

        let capture = CompanionCapture(captureId: UUID(), text: "Prefers aisle seats", createdAt: h.clock.now, source: .typed)
        let first = try await phone.call(CapturesSubmit.self, CapturesSubmitParams(captures: [capture]))
        let again = try await phone.call(CapturesSubmit.self, CapturesSubmitParams(captures: [capture]))
        #expect(first.accepted == [capture.captureId] && again.accepted == [capture.captureId])

        let checks = try await phone.protocolChecks()
        #expect(checks.allSatisfy { $0.passed }, "\(checks)")
    }

    @Test func deniedOnTheMac() async throws {
        let h = try CompanionHarness()
        let phone = client(h)
        let payload = await h.qr()
        let paired = Task { try await phone.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4") }
        try await h.answerWhenAsked(false)
        await #expect(throws: CompanionClientError.pairing(.denied)) { try await paired.value }
        #expect(try await h.services.devices.devices().isEmpty)
    }

    @Test func revokedOnTheMac() async throws {
        let h = try CompanionHarness()
        let phone = client(h)
        let payload = await h.qr()
        async let paired = phone.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        try await h.answerWhenAsked(true)
        let record = try await paired
        try await h.services.devices.revoke(deviceID: record.deviceID, now: h.clock.now)
        await #expect(throws: CompanionClientError.refused(.revoked)) { try await phone.status() }
    }
}
