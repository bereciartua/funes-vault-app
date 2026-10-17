import Foundation
import FunesProtocol
import Synchronization

/// One Activity row (spec/domain/domain-model.md#activity-record). Never holds memory text,
/// task text, keys or bodies: only ids, reason codes, counts and labels.
public struct ActivityEvent: Sendable, Hashable, Codable {
    public enum Phase: String, Sendable, Codable { case start, result, event }
    public enum Via: String, Sendable, Codable { case mcp, companion, app }
    public enum Approval: String, Sendable, Codable {
        case approved, denied, timeout
        case notRequired = "not_required"
    }

    public var time: Date
    public var requestID: UUID?
    public var phase: Phase
    /// `user`, `agent:<id>`, `device:<id>` or `system`.
    public var actor: String
    public var via: Via
    /// What happened: `request_memory`, `get_memory_request`, `approval`, `disclosure`, `suggest_memory`, `capture`, …
    public var event: String
    /// The result status, e.g. `needs_approval`, `delivered`, `queued`.
    public var outcome: String?
    /// Ids of memories released or created, or of the suggestion. Never ids of withheld memories.
    public var ids: [UUID]
    public var reason: ReasonCode?
    /// Withheld counts by reason code, or other counts.
    public var counts: [String: Int]
    public var approval: Approval?

    public init(time: Date, requestID: UUID? = nil, phase: Phase = .result, actor: Actor, via: Via, event: String,
                outcome: String? = nil, ids: [UUID] = [], reason: ReasonCode? = nil, counts: [String: Int] = [:],
                approval: Approval? = nil) {
        self.time = time
        self.requestID = requestID
        self.phase = phase
        self.actor = actor.description
        self.via = via
        self.event = event
        self.outcome = outcome
        self.ids = ids
        self.reason = reason
        self.counts = counts
        self.approval = approval
    }
}

/// Where Activity rows go. The app's append-only JSONL store (EK Bridge's `ActivityStore`, from
/// Phase 2) implements it; tests use `InMemoryActivityLog`.
public protocol ActivityRecorder: Sendable {
    func record(_ event: ActivityEvent)
}

public final class InMemoryActivityLog: ActivityRecorder {
    private let rows = Mutex<[ActivityEvent]>([])
    public init() {}
    public func record(_ event: ActivityEvent) { rows.withLock { $0.append(event) } }
    public var events: [ActivityEvent] { rows.withLock { $0 } }
}

/// "Pause Funes Vault" (FR-A-11): refuses all agent requests with `funes_paused` until resumed.
/// Held in memory; the app persists the choice.
public final class FunesPause: Sendable {
    private let until = Mutex<Date?>(nil)
    public init() {}

    /// Pauses until `date`, or indefinitely with `.distantFuture`.
    public func pause(until date: Date) { until.withLock { $0 = date } }
    public func resume() { until.withLock { $0 = nil } }
    public func isPaused(at now: Date) -> Bool { until.withLock { $0.map { now < $0 } ?? false } }
}

extension Dictionary where Key == ReasonCode, Value == Int {
    var counts: [String: Int] { Dictionary<String, Int>(uniqueKeysWithValues: map { ($0.key.rawValue, $0.value) }) }
}
