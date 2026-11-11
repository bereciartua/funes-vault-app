import Foundation
import FunesProtocol
@testable import FunesPhone

/// Holds whoever passes through until it's opened, and tells a test when someone is waiting, so a
/// test can act while a call is on its way instead of guessing with a sleep.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Waits here until `open()`.
    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (through, ready) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                arrivals += 1
                let ready = watchers.filter { $0.count <= arrivals }.map(\.continuation)
                watchers.removeAll { $0.count <= arrivals }
                if isOpen { return (true, ready) }
                held.append(continuation)
                return (false, ready)
            }
            ready.forEach { $0.resume() }
            if through { continuation.resume() }
        }
    }

    /// Returns once `count` callers have reached the gate.
    func arrived(_ count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if arrivals >= count { return true }
                watchers.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { held = [] }
            return held
        }.forEach { $0.resume() }
    }

    /// Holds the next callers again, counting arrivals from zero.
    func close() {
        lock.withLock {
            isOpen = false
            arrivals = 0
        }
    }
}

/// Passes calls to `inner`; the replies of `method` are held at `gate` on their way back, as an
/// answer the Mac gave before something changed and that arrives after.
struct GatedCaller: CompanionCalling {
    let inner: any CompanionCalling
    let method: CompanionMethod
    let gate: Gate

    func perform<Call: CompanionCall>(_ request: PendingCall<Call>) async throws(CompanionClientError) -> Call.Result {
        let result = await Result { () async throws(CompanionClientError) in try await inner.perform(request) }
        if Call.method == method { await gate.pass() }
        return try result.get()
    }
}
