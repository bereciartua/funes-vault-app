import Foundation
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "delivery")

/// Sends one `captures.submit` call. `CompanionClient` on the phone; a fake in tests.
public protocol CaptureSender: Sendable {
    func submit(_ captures: [CompanionCapture]) async throws(CompanionClientError) -> CapturesSubmitResult
}

extension CompanionClient: CaptureSender {
    public func submit(_ captures: [CompanionCapture]) async throws(CompanionClientError) -> CapturesSubmitResult {
        try await call(CapturesSubmit.self, CapturesSubmitParams(captures: captures))
    }
}

/// What started a delivery (companion protocol §6, FR-iOS-05).
public enum DeliveryTrigger: String, Sendable, CaseIterable {
    case launch, foreground
    /// `NWPathMonitor` found a usable path.
    case pathChange
    /// A new capture, while the app is open.
    case captured
    /// `BGAppRefreshTask`.
    case background
    /// The backoff's wait is over.
    case retry
    /// "Send now".
    case manual

    /// Launch, foreground, a new path and "Send now" try at once; the others wait out the backoff.
    public var resetsBackoff: Bool {
        switch self {
        case .launch, .foreground, .pathChange, .manual: true
        case .captured, .background, .retry: false
        }
    }
}

/// How a delivery went.
public enum DeliveryOutcome: Sendable, Equatable {
    /// Nothing is left to send. `sent` were accepted (duplicates included); `rejected` the Mac
    /// won't ever take.
    case drained(sent: Int, rejected: Int)
    /// Still backing off; nothing was tried.
    case waiting(until: Date)
    /// The Mac didn't take the rest. `sent` went before that; the next try is after `retryAt`.
    case failed(CompanionClientError, retryAt: Date, sent: Int)
    case notPaired
    /// The Mac removed this iPhone: the captures stay until the user re-pairs or deletes them (§8).
    case revoked
    /// Another delivery is running; it goes on to what was just queued.
    case busy
    /// The queue couldn't be read.
    case storage
}

/// Exponential backoff with jitter while the Mac is unreachable: 5 s doubling to 30 min (§6),
/// each wait drawn from its upper half so that retries don't line up.
public struct Backoff: Sendable, Equatable {
    public static let base: TimeInterval = 5
    public static let cap: TimeInterval = 30 * 60

    public private(set) var failures = 0
    /// No automatic try before this.
    public private(set) var notBefore: Date?

    public init() {}

    /// The wait after the `failures`th failure in a row, for `jitter` in 0...1.
    public static func delay(failures: Int, jitter: Double) -> TimeInterval {
        let full = min(cap, base * pow(2, Double(max(0, failures - 1))))
        return max(base, full * (0.5 + 0.5 * min(1, max(0, jitter))))
    }

    public func allows(_ now: Date) -> Bool { notBefore.map { now >= $0 } ?? true }

    public mutating func failed(at now: Date, jitter: Double) {
        failures += 1
        notBefore = now.addingTimeInterval(Self.delay(failures: failures, jitter: jitter))
    }

    public mutating func reset() {
        failures = 0
        notBefore = nil
    }
}

/// Drains the capture queue to the Mac (companion protocol §6), oldest first, in calls of at
/// most 50. A capture leaves the queue only once the Mac has accepted it, so a reply lost after
/// the Mac stored it means a resend, which the Mac accepts as a duplicate without storing it
/// again: exactly once. Runs in the app only; extensions just add to the queue.
public actor CaptureDelivery {
    private let queue: CaptureQueue
    private let sender: any CaptureSender
    private let clock: @Sendable () -> Date
    private let jitter: @Sendable () -> Double

    public private(set) var backoff = Backoff()
    private var running = false
    private var again = false

    public init(queue: CaptureQueue, sender: any CaptureSender, clock: @escaping @Sendable () -> Date = Date.init,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.queue = queue
        self.sender = sender
        self.clock = clock
        self.jitter = jitter
    }

    /// When the backoff allows the next automatic try, or nil when it's now.
    public var nextAttempt: Date? { backoff.allows(clock()) ? nil : backoff.notBefore }

    public func deliver(_ trigger: DeliveryTrigger) async -> DeliveryOutcome {
        if trigger.resetsBackoff { backoff.reset() }
        guard !running else {
            again = true
            return .busy
        }
        running = true
        defer { running = false }
        var outcome = await drain()
        // Something was queued while this ran: go on, unless the Mac just failed.
        while again, case .drained = outcome {
            again = false
            let more = await drain()
            outcome = Self.adding(outcome, to: more)
        }
        again = false
        logger.info("Delivery after \(trigger.rawValue, privacy: .public): \(Self.describe(outcome), privacy: .public)") // log-safe: counts and codes
        return outcome
    }

    private func drain() async -> DeliveryOutcome {
        guard backoff.allows(clock()) else { return .waiting(until: backoff.notBefore ?? clock()) }
        var sent = 0, rejected = 0
        while true {
            let batch: [QueuedCapture]
            do {
                batch = try queue.nextBatch()
                guard !batch.isEmpty else {
                    backoff.reset()
                    return .drained(sent: sent, rejected: rejected)
                }
                try queue.recordAttempt(batch.map(\.id), at: clock())
            } catch {
                return .storage
            }
            let ids = Set(batch.map(\.id))
            let result: CapturesSubmitResult
            do {
                result = try await sender.submit(batch.map(\.wire))
            } catch {
                switch error {
                case .notPaired: return .notPaired
                case .refused(.revoked), .refused(.unknownDevice): return .revoked
                default:
                    backoff.failed(at: clock(), jitter: jitter())
                    return .failed(error, retryAt: backoff.notBefore ?? clock(), sent: sent)
                }
            }
            let accepted = result.accepted.filter(ids.contains)
            let refusals = result.rejected.filter { ids.contains($0.captureId) }
            let final = refusals.filter { !CaptureQueue.transientRejections.contains($0.reason) }
            do {
                try queue.remove(accepted)
                try queue.reject(final)
            } catch {
                return .storage
            }
            sent += accepted.count
            rejected += final.count
            // Nothing in this batch moved (all rate limited, say): back off rather than loop.
            if accepted.isEmpty && final.isEmpty {
                let reason = refusals.first?.reason ?? .unavailable
                backoff.failed(at: clock(), jitter: jitter())
                return .failed(.method(CompanionError(reason)), retryAt: backoff.notBefore ?? clock(), sent: sent)
            }
        }
    }

    private static func adding(_ first: DeliveryOutcome, to second: DeliveryOutcome) -> DeliveryOutcome {
        guard case let .drained(sent, rejected) = first else { return second }
        switch second {
        case let .drained(more, moreRejected): return .drained(sent: sent + more, rejected: rejected + moreRejected)
        case let .failed(error, retryAt, more): return .failed(error, retryAt: retryAt, sent: sent + more)
        default: return second
        }
    }

    static func describe(_ outcome: DeliveryOutcome) -> String {
        switch outcome {
        case let .drained(sent, rejected): "drained, \(sent) sent, \(rejected) rejected"
        case .waiting: "backing off"
        case let .failed(error, _, sent): "failed (\(CompanionClient.code(error))) after \(sent) sent"
        case .notPaired: "not paired"
        case .revoked: "revoked"
        case .busy: "already running"
        case .storage: "queue unreadable"
        }
    }
}

extension CompanionClient {
    /// A short code for logs: no text, no addresses.
    static func code(_ error: CompanionClientError) -> String {
        switch error {
        case .notPaired: "not_paired"
        case .unreachable: "unreachable"
        case let .refused(refusal): refusal.code
        case .pairing: "pairing"
        case .qrExpired: "qr_expired"
        case let .method(error): error.code.rawValue
        case let .badResponse(status): "http_\(status)"
        case .local: "local"
        }
    }
}
