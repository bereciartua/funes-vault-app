import Foundation
import GRDB
import Synchronization

/// The facts lane's switches, one per vault (memory processing §11.3), in this process only: the Facts task's settings
/// live in user defaults (storage §5.2) and the app sets them here, at launch and on every change.
///
/// - **Learning** (*Learn from memories*): memory commits queue facts jobs only while it's on, read inside the commit's
///   transaction (`funes_facts_learning()` on every connection, so the static `MemoryStore` helpers see it), and the
///   queue admits a facts job only while it's on. Off by default, so tests and any path the app hasn't wired stay off.
/// - **Closures:** the tidy-up and Remove learned facts close the lane and wait for a running facts job to finish.
/// - **Admission** is atomic with the claim (`tryEnter`, inside `ProcessingQueue.claim`'s write), so a closure that
///   finds nothing running can't be followed by a facts job starting.
/// - **Generation:** bumped by anything that changes what a facts call may send (learning off, a closure, a settings or
///   profile change). A job checks it before every request (`FactsExtractor.permit`), so it stops at its next send
///   and goes back to the queue; a request already in flight finishes.
public final class FactsLane: Sendable {
    public enum Closure: Hashable, Sendable {
        case tidyUp, removing
    }

    private struct State {
        var learning = false
        var closures: [Closure: Int] = [:]
        var running = false
        var generation = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// *Learn from memories*, as the app last set it.
    public var learning: Bool { state.withLock { $0.learning } }

    /// Sets *Learn from memories*. Turning it off bumps the generation, so a running job sends nothing more.
    public func setLearning(_ on: Bool) {
        state.withLock { s in
            if s.learning && !on { s.generation += 1 }
            s.learning = on
        }
    }

    /// Whether a facts job may start now: learning on and nothing closing the lane.
    public var isOpen: Bool { state.withLock { $0.learning && $0.closures.isEmpty } }

    /// The current generation: a job built its configuration under it.
    public var generation: Int { state.withLock { $0.generation } }

    /// Whether a job whose configuration was built under `generation` may still send: the lane is open and nothing
    /// changed since.
    public func permits(_ generation: Int) -> Bool {
        state.withLock { $0.learning && $0.closures.isEmpty && $0.generation == generation }
    }

    /// Something a facts call depends on changed (the cloud limit, an account, the model choice, the profile): a running
    /// job stops at its next send and starts again with the new configuration.
    public func reconfigured() {
        state.withLock { $0.generation += 1 }
    }

    /// Admits one facts job when the lane is open, marking it running. Called inside the claim's write transaction.
    func tryEnter() -> Bool {
        state.withLock { s in
            guard s.learning, s.closures.isEmpty, !s.running else { return false }
            s.running = true
            return true
        }
    }

    /// The admitted facts job ended (its outcome is recorded), or the claim found none.
    func leave() {
        let resumed = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.running = false
            defer { s.waiting = [] }
            return s.waiting
        }
        for c in resumed { c.resume() }
    }

    /// Closes the lane for `reason` (nesting allowed) and returns once no facts job is running.
    public func close(_ reason: Closure) async {
        let mustWait = state.withLock { s -> Bool in
            s.closures[reason, default: 0] += 1
            s.generation += 1
            return s.running
        }
        guard mustWait else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                guard s.running else { return true }
                s.waiting.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    /// Reopens what `close(reason)` closed.
    public func open(_ reason: Closure) {
        state.withLock { s in
            guard let n = s.closures[reason] else { return }
            s.closures[reason] = n > 1 ? n - 1 : nil
        }
    }

    /// Registers `funes_facts_learning()` on a connection: 1 while learning is on.
    func register(_ db: Database) {
        db.add(function: DatabaseFunction("funes_facts_learning", argumentCount: 0, pure: false) { [self] _ in
            self.learning ? 1 : 0
        })
    }

    /// Whether learning is on, read inside the caller's transaction. A connection without the function (not a
    /// `VaultStore`'s) reads it as off.
    static func learning(_ db: Database) -> Bool {
        ((try? Bool.fetchOne(db, sql: "SELECT funes_facts_learning()")) ?? nil) ?? false
    }
}
