import BridgeKitCore
import Foundation
import FunesCore
import FunesProtocol
import Testing
@testable import FunesCompanion

/// §7's per-call deadline, and the pairing prompt under two requests at once.
@Suite struct DeadlineTests {
    /// Holds slow work until the test lets it go, without noticing cancellation, as slow work
    /// that doesn't check does. The reply coming back while the work is held shows the deadline
    /// didn't wait for it, with no clock involved.
    final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var waiting: CheckedContinuation<Void, Never>?
        private var finished: CheckedContinuation<Void, Never>?
        private(set) var sawCancel: Bool?

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if released { return true }
                    waiting = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func release() {
            lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { waiting = nil }
                return waiting
            }?.resume()
        }

        /// The work's last step: whether it had been cancelled by then.
        func done(cancelled: Bool) {
            lock.withLock { () -> CheckedContinuation<Void, Never>? in
                sawCancel = cancelled
                defer { finished = nil }
                return finished
            }?.resume()
        }

        func untilDone() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if sawCancel != nil { return true }
                    finished = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        }
    }

    /// Past 10 s the phone hears `unavailable` while the work is still going, and the work goes
    /// on to its end, not cancelled (the spec's "the work still finishes on the Mac").
    @Test func aSlowCallAnswersOnTimeAndItsWorkFinishes() async throws {
        let h = try CompanionHarness()
        let hold = Hold()
        let reply = await h.router.handlers.withTimeout(id: "1", limit: .milliseconds(50)) {
            await hold.wait()
            hold.done(cancelled: Task.isCancelled)
            return Data("done".utf8)
        }
        #expect(hold.sawCancel == nil)
        #expect(throws: CompanionError(.unavailable, message: "Timed out")) { _ = try CompanionResponse<EmptyResult>.decode(reply).get() }
        hold.release()
        await hold.untilDone()
        #expect(hold.sawCancel == false)
    }

    /// `memories.answer`'s deadline cancels its work, and the reply doesn't wait for the work to
    /// notice.
    @Test func anAnswerPastItsDeadlineIsCancelledWithoutWaiting() async throws {
        let h = try CompanionHarness()
        let hold = Hold()
        let reply = await h.router.handlers.withTimeout(id: "1", limit: .milliseconds(50),
                                                        error: CompanionError(.modelTimeout, message: "Deadline"), cancelsWork: true) {
            await hold.wait()
            hold.done(cancelled: Task.isCancelled)
            return Data()
        }
        #expect(hold.sawCancel == nil)
        #expect(throws: CompanionError(.modelTimeout, message: "Deadline")) { _ = try CompanionResponse<EmptyResult>.decode(reply).get() }
        hold.release()
        await hold.untilDone()
        #expect(hold.sawCancel == true)
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

    /// A new code shown while the Mac asks about the old one denies the old prompt but leaves
    /// the new session waiting, and the new code pairs.
    @Test func aNewSessionDuringThePromptSurvives() async throws {
        let h = try CompanionHarness()
        let first = CompanionHarness.Phone()
        let (_, body) = try PairingClient.start(payload: await h.qr(), deviceName: "Sam's iPhone", model: "iPhone17,1",
                                                signer: first.signer, deviceHPKEKey: first.hpke, now: h.clock.now)
        async let old = h.router.handle(CompanionHarness.request(CompanionProtocol.pairPath, body: body), transport: .lan)
        for _ in 0..<200 where !(await h.pairing.isAsking) { try await Task.sleep(for: .milliseconds(10)) }
        let fresh = await h.qr()
        let response = await old
        #expect(response.status == PairingError.httpStatus && PairingError(body: response.body) == .denied)
        guard case .waiting = await h.pairing.state else { Issue.record("\(await h.pairing.state)"); return }
        var second = CompanionHarness.Phone()
        let (paired, _) = try await h.pair(&second, payload: fresh)
        #expect(paired.status == 200)
        #expect(try await h.services.devices.devices().count == 1)
    }
}
