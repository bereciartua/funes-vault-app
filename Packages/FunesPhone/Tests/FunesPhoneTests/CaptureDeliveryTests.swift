import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// A Mac that answers as told, call by call, and keeps what it accepted (deduplicated by
/// `captureId`, as the real one does).
final class ScriptedSender: CaptureSender, @unchecked Sendable {
    enum Answer {
        case acceptAll
        case fail(CompanionClientError)
        /// Rejects these ids with `reason`, accepts the rest.
        case reject([UUID], CompanionErrorCode)
        /// Stores the captures, then the reply is lost.
        case storeAndLose
    }

    private let lock = NSLock()
    private var script: [Answer]
    private(set) var calls: [[CompanionCapture]] = []
    private(set) var stored: [UUID] = []

    init(_ script: [Answer] = []) { self.script = script }

    func then(_ answers: Answer...) { lock.withLock { script += answers } }

    func submit(_ captures: [CompanionCapture]) async throws(CompanionClientError) -> CapturesSubmitResult {
        let answer = lock.withLock {
            calls.append(captures)
            return script.isEmpty ? .acceptAll : script.removeFirst()
        }
        func store(_ ids: [UUID]) { lock.withLock { for id in ids where !stored.contains(id) { stored.append(id) } } }
        let ids = captures.map(\.captureId)
        switch answer {
        case .acceptAll:
            store(ids)
            return CapturesSubmitResult(accepted: ids, rejected: [])
        case let .fail(error):
            throw error
        case let .reject(rejected, reason):
            let accepted = ids.filter { !rejected.contains($0) }
            store(accepted)
            return CapturesSubmitResult(accepted: accepted, rejected: ids.filter(rejected.contains).map { CaptureRejection(captureId: $0, reason: reason) })
        case .storeAndLose:
            store(ids)
            throw .unreachable(localNetworkDenied: false)
        }
    }
}

struct DeliveryRig {
    let clock = TestClock()
    let queue = temporaryQueue()
    let sender: ScriptedSender
    let delivery: CaptureDelivery

    init(_ script: [ScriptedSender.Answer] = [], jitter: Double = 1) {
        sender = ScriptedSender(script)
        let clock = clock
        delivery = CaptureDelivery(queue: queue, sender: sender, clock: { clock.now }, jitter: { jitter })
    }

    @discardableResult
    func queue(_ count: Int) throws -> [UUID] {
        try (0..<count).map { try queue.add("Capture \($0)", source: .typed, now: clock.now.addingTimeInterval(Double($0))).id }
    }
}

@Suite struct BackoffTests {
    @Test func doublesFromFiveSecondsToThirtyMinutes() {
        let delays = (1...12).map { Backoff.delay(failures: $0, jitter: 1) }
        #expect(delays == [5, 10, 20, 40, 80, 160, 320, 640, 1280, 1800, 1800, 1800])
    }

    @Test func jitterTakesTheUpperHalfButNeverUnderFiveSeconds() {
        #expect(Backoff.delay(failures: 1, jitter: 0) == 5)
        #expect(Backoff.delay(failures: 4, jitter: 0) == 20)
        #expect(Backoff.delay(failures: 4, jitter: 0.5) == 30)
        #expect(Backoff.delay(failures: 20, jitter: 0) == 900)
        for _ in 0..<100 {
            let delay = Backoff.delay(failures: 6, jitter: .random(in: 0...1))
            #expect((80...160).contains(delay))
        }
    }

    @Test func failingAndResetting() {
        var backoff = Backoff()
        #expect(backoff.allows(t0))
        backoff.failed(at: t0, jitter: 1)
        backoff.failed(at: t0, jitter: 1)
        #expect(backoff.failures == 2)
        #expect(backoff.notBefore == t0.addingTimeInterval(10))
        #expect(!backoff.allows(t0.addingTimeInterval(9)))
        #expect(backoff.allows(t0.addingTimeInterval(10)))
        backoff.reset()
        #expect(backoff == Backoff())
    }
}

@Suite struct CaptureDeliveryTests {
    @Test func emptyQueueIsDrained() async {
        let rig = DeliveryRig()
        #expect(await rig.delivery.deliver(.launch) == .drained(sent: 0, rejected: 0))
        #expect(rig.sender.calls.isEmpty)
    }

    /// 120 captures go in calls of 50, 50 and 20, oldest first, and leave the phone.
    @Test func splitsIntoBatchesOfFifty() async throws {
        let rig = DeliveryRig()
        let ids = try rig.queue(120)
        #expect(await rig.delivery.deliver(.foreground) == .drained(sent: 120, rejected: 0))
        #expect(rig.sender.calls.map(\.count) == [50, 50, 20])
        #expect(rig.sender.calls.flatMap { $0.map(\.captureId) } == ids)
        #expect(rig.sender.stored == ids)
        #expect(try rig.queue.queuedCount() == 0)
    }

    /// Spike 1 row 1h's queue of 1,000: 20 calls, and the queue is empty.
    @Test func aThousandDrain() async throws {
        let rig = DeliveryRig()
        try rig.queue(CaptureQueue.capacity)
        #expect(await rig.delivery.deliver(.pathChange) == .drained(sent: 1_000, rejected: 0))
        #expect(rig.sender.calls.count == 20)
        #expect(Set(rig.sender.stored).count == 1_000)
        #expect(try rig.queue.all().isEmpty)
    }

    /// A failed call keeps the captures, with the same ids, for the retry.
    @Test func retrySendsTheSameCaptureIds() async throws {
        let rig = DeliveryRig([.fail(.unreachable(localNetworkDenied: false))])
        let ids = try rig.queue(3)
        let outcome = await rig.delivery.deliver(.captured)
        #expect(outcome == .failed(.unreachable(localNetworkDenied: false), retryAt: t0.addingTimeInterval(5), sent: 0))
        #expect(try rig.queue.all().allSatisfy { $0.attempts == 1 && $0.state == .queued })
        rig.clock.advance(5)
        #expect(await rig.delivery.deliver(.retry) == .drained(sent: 3, rejected: 0))
        #expect(rig.sender.calls.map { $0.map(\.captureId) } == [ids, ids])
        #expect(rig.sender.stored == ids)
        #expect(try rig.queue.queuedCount() == 0)
    }

    /// The Mac stored the captures but the phone never heard back: they're resent, the Mac
    /// accepts them as duplicates, and nothing is stored twice (NFR-REL-04).
    @Test func lostReplyIsResentWithoutDuplicates() async throws {
        let rig = DeliveryRig([.storeAndLose])
        let ids = try rig.queue(2)
        guard case .failed = await rig.delivery.deliver(.background) else { Issue.record("expected a failure"); return }
        #expect(rig.sender.stored == ids)
        #expect(try rig.queue.queuedCount() == 2)
        #expect(await rig.delivery.deliver(.foreground) == .drained(sent: 2, rejected: 0))
        #expect(rig.sender.stored == ids)
        #expect(try rig.queue.queuedCount() == 0)
    }

    @Test func backsOffWhileUnreachable() async throws {
        let unreachable = CompanionClientError.unreachable(localNetworkDenied: false)
        let rig = DeliveryRig([.fail(unreachable), .fail(unreachable), .fail(unreachable)])
        try rig.queue(1)
        #expect(await rig.delivery.deliver(.captured) == .failed(unreachable, retryAt: t0.addingTimeInterval(5), sent: 0))
        // A new capture or a background refresh waits out the backoff, without a call.
        try rig.queue(1)
        #expect(await rig.delivery.deliver(.captured) == .waiting(until: t0.addingTimeInterval(5)))
        #expect(await rig.delivery.deliver(.background) == .waiting(until: t0.addingTimeInterval(5)))
        #expect(rig.sender.calls.count == 1)
        #expect(await rig.delivery.nextAttempt == t0.addingTimeInterval(5))
        rig.clock.advance(5)
        #expect(await rig.delivery.deliver(.retry) == .failed(unreachable, retryAt: t0.addingTimeInterval(15), sent: 0))
        rig.clock.advance(10)
        #expect(await rig.delivery.deliver(.retry) == .failed(unreachable, retryAt: t0.addingTimeInterval(35), sent: 0))
        #expect(await rig.delivery.backoff.failures == 3)
        // Coming to the front tries at once, and success resets the backoff.
        #expect(await rig.delivery.deliver(.foreground) == .drained(sent: 2, rejected: 0))
        #expect(await rig.delivery.backoff == Backoff())
        #expect(await rig.delivery.nextAttempt == nil)
    }

    @Test func pathChangeAndSendNowSkipTheBackoff() async throws {
        let unreachable = CompanionClientError.unreachable(localNetworkDenied: false)
        let rig = DeliveryRig([.fail(unreachable), .fail(unreachable)])
        try rig.queue(1)
        _ = await rig.delivery.deliver(.captured)
        guard case .failed = await rig.delivery.deliver(.pathChange) else { Issue.record("expected a try"); return }
        #expect(await rig.delivery.deliver(.manual) == .drained(sent: 1, rejected: 0))
        #expect(rig.sender.calls.count == 3)
    }

    /// A capture the Mac won't ever take stays, marked, and isn't sent again; the rest go.
    @Test func finalRejectionIsKeptAndNotResent() async throws {
        let rig = DeliveryRig()
        let ids = try rig.queue(3)
        rig.sender.then(.reject([ids[1]], .secretLikeContent))
        #expect(await rig.delivery.deliver(.foreground) == .drained(sent: 2, rejected: 1))
        let left = try rig.queue.all()
        #expect(left.map(\.id) == [ids[1]])
        #expect(left[0].state == .rejected(.secretLikeContent))
        #expect(await rig.delivery.deliver(.foreground) == .drained(sent: 0, rejected: 0))
        #expect(rig.sender.calls.count == 1)
    }

    /// Over the Mac's daily limit: the accepted ones go, the rest wait and back off.
    @Test func rateLimitedCapturesWait() async throws {
        let rig = DeliveryRig()
        let ids = try rig.queue(3)
        rig.sender.then(.reject([ids[2]], .rateLimited), .reject([ids[2]], .rateLimited))
        let outcome = await rig.delivery.deliver(.foreground)
        #expect(outcome == .failed(.method(CompanionError(.rateLimited)), retryAt: t0.addingTimeInterval(5), sent: 2))
        #expect(rig.sender.calls.map(\.count) == [3, 1])
        #expect(try rig.queue.all().map(\.state) == [.queued])
        rig.clock.advance(5)
        #expect(await rig.delivery.deliver(.retry) == .drained(sent: 1, rejected: 0))
    }

    @Test func revokedAndNotPairedKeepTheCaptures() async throws {
        let rig = DeliveryRig([.fail(.refused(.revoked)), .fail(.notPaired)])
        try rig.queue(2)
        #expect(await rig.delivery.deliver(.foreground) == .revoked)
        #expect(await rig.delivery.deliver(.foreground) == .notPaired)
        #expect(try rig.queue.queuedCount() == 2)
    }

    /// End to end through `CompanionClient`: the Mac commits, the reply is dropped, the client's
    /// own resend is dropped too; the next delivery is accepted as a duplicate.
    @Test func lostReplyThroughTheClient() async throws {
        let rig = Rig()
        try await rig.pair()
        let queue = temporaryQueue()
        let clock = rig.clock
        let delivery = CaptureDelivery(queue: queue, sender: rig.client, clock: { clock.now }, jitter: { 1 })
        let ids = try (0..<60).map { try queue.add("Capture \($0)", source: .share, now: t0.addingTimeInterval(Double($0))).id }

        rig.transport.dropResponses = true
        guard case .failed(.unreachable, _, sent: 0) = await delivery.deliver(.foreground) else {
            Issue.record("expected unreachable")
            return
        }
        #expect(rig.mac.stored == Array(ids.prefix(50)))
        #expect(try queue.queuedCount() == 60)

        rig.transport.dropResponses = false
        #expect(await delivery.deliver(.foreground) == .drained(sent: 60, rejected: 0))
        #expect(rig.mac.stored == ids)
        #expect(try queue.queuedCount() == 0)
    }
}
