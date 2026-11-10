import BridgeKitCore
import Foundation
import FunesCore
import FunesProtocol
import Synchronization
import Testing
@testable import FunesCompanion

/// §7's per-call deadline, and the pairing prompt under two requests at once.
@Suite struct DeadlineTests {
    /// Waits `seconds` without noticing cancellation, as slow work that doesn't check does.
    static func busy(_ seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    /// Past 10 s the phone hears `unavailable` on time, and the work goes on to its end, not
    /// cancelled (the spec's "the work still finishes on the Mac").
    @Test func aSlowCallAnswersOnTimeAndItsWorkFinishes() async throws {
        let h = try CompanionHarness()
        let finished = Mutex<Bool?>(nil)
        let start = ContinuousClock.now
        let reply = await h.router.handlers.withTimeout(id: "1", limit: .milliseconds(100)) {
            await Self.busy(0.6)
            finished.withLock { $0 = Task.isCancelled }
            return Data("done".utf8)
        }
        #expect(ContinuousClock.now - start < .milliseconds(450))
        #expect(throws: CompanionError(.unavailable, message: "Timed out")) { _ = try CompanionResponse<EmptyResult>.decode(reply).get() }
        try await Task.sleep(for: .milliseconds(900))
        #expect(finished.withLock { $0 } == false)
    }

    /// `memories.answer`'s deadline cancels its work, and the reply doesn't wait for the work to
    /// notice.
    @Test func anAnswerPastItsDeadlineIsCancelledWithoutWaiting() async throws {
        let h = try CompanionHarness()
        let cancelled = Mutex<Bool?>(nil)
        let start = ContinuousClock.now
        let reply = await h.router.handlers.withTimeout(id: "1", limit: .milliseconds(100),
                                                        error: CompanionError(.modelTimeout, message: "Deadline"), cancelsWork: true) {
            await Self.busy(0.6)
            cancelled.withLock { $0 = Task.isCancelled }
            return Data()
        }
        #expect(ContinuousClock.now - start < .milliseconds(450))
        #expect(throws: CompanionError(.modelTimeout, message: "Deadline")) { _ = try CompanionResponse<EmptyResult>.decode(reply).get() }
        try await Task.sleep(for: .milliseconds(900))
        #expect(cancelled.withLock { $0 } == true)
    }

    @Test func aQuickCallIsItsOwnReply() async throws {
        let h = try CompanionHarness()
        let reply = await h.router.handlers.withTimeout(id: "1", limit: .seconds(5)) { Data("quick".utf8) }
        #expect(reply == Data("quick".utf8))
    }

    /// Two pairing requests on one session at once: one prompt, the other refused, nothing left
    /// hanging.
    @Test func twoPairingRequestsAtOnceGetOnePrompt() async throws {
        let h = try CompanionHarness()
        let payload = await h.qr()
        let first = CompanionHarness.Phone(), second = CompanionHarness.Phone()
        let (_, a) = try PairingClient.start(payload: payload, deviceName: "Sam's iPhone", model: "iPhone17,1", signer: first.signer,
                                             deviceHPKEKey: first.hpke, now: h.clock.now)
        let (_, b) = try PairingClient.start(payload: payload, deviceName: "Ana's iPhone", model: "iPhone17,1", signer: second.signer,
                                             deviceHPKEKey: second.hpke, now: h.clock.now)
        async let one = h.router.handle(CompanionHarness.request(CompanionProtocol.pairPath, body: a), transport: .lan)
        async let two = h.router.handle(CompanionHarness.request(CompanionProtocol.pairPath, body: b), transport: .lan)
        try await h.answerWhenAsked(true)
        let statuses = await [one.status, two.status].sorted()
        #expect(statuses == [200, PairingError.httpStatus])
        #expect(try await h.services.devices.devices().count == 1)
    }
}
