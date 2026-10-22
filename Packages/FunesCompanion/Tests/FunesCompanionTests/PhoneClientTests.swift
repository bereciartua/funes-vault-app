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

    /// Task 5.5's view models through the real client and handlers: an edit on the phone that
    /// the Mac overtook answers `conflict`, Reload shows the Mac's text, and the next save goes
    /// through; a suggestion saved on the Mac first leaves the phone's Inbox without an error.
    @MainActor @Test func conflictAndInboxThroughTheRealMac() async throws {
        let h = try CompanionHarness()
        let phone = client(h)
        let payload = await h.qr()
        async let paired = phone.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        try await h.answerWhenAsked(true)
        _ = try await paired

        let created = try await phone.call(MemoriesCreate.self, MemoryCreateParams(
            title: "Coffee", body: "Oat flat white", kind: .preference, categories: ["personal_preferences"], sensitivity: .low))
        let detail = MemoryDetailModel(id: created.id, caller: phone, clock: { h.clock.now })
        await detail.load()
        detail.startEditing()
        detail.draft?.body = "Oat flat white, extra hot"
        _ = try h.store.updateMemory(id: created.id, MemoryEdit(body: "Oat cortado"), now: h.clock.now)

        #expect(await detail.save() == false)
        #expect(detail.conflict)
        #expect(detail.draft?.body == "Oat flat white, extra hot")
        await detail.reload()
        #expect(detail.memory?.body == "Oat cortado")
        #expect(detail.draft?.body == "Oat cortado")
        detail.draft?.body = "Oat cortado, extra hot"
        #expect(await detail.save())
        #expect(try h.store.memory(id: created.id)?.body == "Oat cortado, extra hot")

        let capture = CompanionCapture(captureId: UUID(), text: "Gym on Tuesdays", createdAt: h.clock.now, source: .typed)
        _ = try await phone.call(CapturesSubmit.self, CapturesSubmitParams(captures: [capture]))
        let inbox = InboxModel(caller: phone)
        await inbox.load()
        let item = try #require(inbox.items.first)
        _ = try await h.services.suggestions.apply(suggestionID: item.id, edits: SuggestionEdit(), now: h.clock.now)
        #expect(await inbox.save(item.id) == false)
        #expect(inbox.failure == nil)
        #expect(inbox.answeredElsewhere == 1)
        #expect(inbox.items.isEmpty)
    }

    /// Task 5.6 from the phone's side: the extension's fetch by the ring, the panel's answer, and
    /// a Mac answer first, through the real client, router and vault.
    @MainActor @Test func approvalsThroughTheRealMac() async throws {
        let h = try CompanionHarness()
        let phone = client(h)
        let payload = await h.qr()
        async let paired = phone.pair(payload, deviceName: "Sam's iPhone", model: "iPhone14,4")
        try await h.answerWhenAsked(true)
        _ = try await paired
        let cloud = RecordingSubscriptions()
        let settings = ApprovalSettingsModel(caller: phone, subscriptions: cloud)
        await settings.load()
        let tag = try #require(settings.settings?.tag)
        #expect(cloud.ids == ["doorbell-" + tag])
        await h.approvals.setRinging(true)

        // The ring, worded on the phone from what the Mac sends over the companion channel.
        let (id, memories) = try await ApprovalsTests().shareRequest(h)
        let ring = try #require(h.doorbell.rung.last)
        #expect(ring.tag == tag)
        let outcome = await ApprovalAlert.fetch(ring: ring.recordName, caller: phone)
        let alert = ApprovalAlert(outcome)
        #expect(alert.title == "Claude Code wants 1 memory" && alert.approvalID == id)
        #expect(!alert.title.contains(ApprovalsTests.title) && !alert.body.contains(ApprovalsTests.title))

        // Tapped: the panel opens by id, and Share answers it.
        let list = ApprovalsModel(caller: phone, clock: { h.clock.now })
        await list.load()
        #expect(list.items.map(\.id) == [id])
        let panel = ApprovalPanelModel(ref: try #require(ApprovalAlert.ref(fromUserInfo: alert.userInfo)), caller: phone)
        await panel.load()
        #expect(panel.selected == Set(memories))
        await panel.answer(.share)
        #expect(panel.phase == .closed(.answered(.share, count: 1)))
        #expect(try await h.disclosures.disclosure(requestID: id)?.status == .approved)

        // The next request is answered on the Mac first.
        let (second, _) = try await ApprovalsTests().shareRequest(h)
        let late = ApprovalPanelModel(ref: ApprovalRef(id: second), caller: phone)
        await late.load()
        try await h.disclosures.deny(requestID: second, now: h.clock.now, waitingOnly: true)
        await late.answer(.share)
        #expect(late.phase == .closed(.answeredOnMac))
        let secondRing = try #require(h.doorbell.rung.last)
        #expect(await ApprovalAlert.fetch(ring: secondRing.recordName, caller: phone) == .answered)

        // Off from the phone: the subscription goes.
        await settings.setEnabled(false)
        #expect(cloud.ids.isEmpty && settings.subscription == .off)
    }
}

/// The phone's CloudKit subscriptions, in memory.
final class RecordingSubscriptions: DoorbellSubscriptions, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: Set<String> = []

    var ids: Set<String> { lock.withLock { saved } }

    func accountAvailable() async -> Bool { true }
    func subscriptionIDs() async throws -> [String] { lock.withLock { Array(saved) } }
    func subscribe(id: String, tag: String, alertBody: String) async throws { _ = lock.withLock { saved.insert(id) } }
    func unsubscribe(ids: [String]) async throws { lock.withLock { saved.subtract(ids) } }
}
