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

    /// Posts to the router like `RouterTransport`, but can lose every answer after the Mac has
    /// handled the request.
    final class LossyTransport: CompanionTransport, @unchecked Sendable {
        let harness: CompanionHarness
        private let lock = NSLock()
        private var losing = false

        init(harness: CompanionHarness) { self.harness = harness }

        func lose(_ on: Bool) { lock.withLock { losing = on } }

        func post(_ url: URL, body: Data, timeout: TimeInterval) async throws(TransportError) -> TransportResponse {
            let response = await harness.router.handle(CompanionHarness.request(url.path(), body: body), transport: .lan)
            if lock.withLock({ losing }) { throw TransportError("connection lost") }
            return TransportResponse(status: response.status, body: response.body)
        }
    }

    /// The phone's queue and delivery (task 5.4) against the real Mac: the Mac commits a batch,
    /// the answer is lost (and so is the client's resend), and the next delivery is accepted as
    /// duplicates. Every capture reaches the Inbox exactly once (NFR-REL-04).
    @Test func queuedCapturesArriveExactlyOnceDespiteLostReplies() async throws {
        let h = try CompanionHarness()
        let transport = LossyTransport(harness: h)
        let clock = h.clock
        let phone = CompanionClient(store: MemorySecretStore(), transport: transport, discovery: NoBonjour(), secureEnclave: false,
                                    clock: { clock.now })
        let payload = await h.qr()
        async let paired = phone.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        try await h.answerWhenAsked(true)
        _ = try await paired

        let folder = FileManager.default.temporaryDirectory.appending(path: "funes-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
        let queue = CaptureQueue(url: folder.appending(path: CaptureQueue.fileName))
        var ids: [UUID] = []
        for i in 0..<120 { ids.append(try queue.add("Capture number \(i)", source: .share, now: clock.now.addingTimeInterval(Double(i))).id) }
        let delivery = CaptureDelivery(queue: queue, sender: phone, clock: { clock.now }, jitter: { 1 })

        transport.lose(true)
        guard case .failed(.unreachable, _, sent: 0) = await delivery.deliver(.foreground) else {
            Issue.record("expected the Mac to look unreachable")
            return
        }
        #expect(try await h.services.suggestions.pending().count == 50)
        #expect(try queue.queuedCount() == 120)

        transport.lose(false)
        #expect(await delivery.deliver(.foreground) == .drained(sent: 120, rejected: 0))
        let pending = try await h.services.suggestions.pending()
        #expect(pending.count == 120)
        #expect(Set(pending.compactMap(\.captureID)) == Set(ids))
        #expect(try queue.queuedCount() == 0)
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
