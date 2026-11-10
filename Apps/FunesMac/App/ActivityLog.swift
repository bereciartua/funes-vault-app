import BridgeUI
import Foundation
import FunesCore
import Synchronization

/// One line of `activity/activity.jsonl`: FunesCore's `ActivityEvent` (ids, codes and counts,
/// never memory text, task text or keys) with the row bookkeeping BridgeUI's store needs.
struct ActivityLine: ActivityRow {
    var rowID: String
    let event: ActivityEvent
    /// A refusal that repeats one kept as important within the hour (BridgeUI `RepeatedRows`):
    /// kept as a routine row. Absent on every other row.
    var repeated: Bool?

    var at: Date { event.time }
    var phase: String { event.phase.rawValue }
    var requestID: String? { event.requestID?.uuidString.lowercased() }
    /// Refusals, approvals, changes and suggestions are kept 400 days (BridgeUI `.funes`); an
    /// agent's repeated identical refusals only once an hour, so a loop can't evict the rest.
    var isImportant: Bool {
        guard repeated != true else { return false }
        return event.approval != nil || event.reason != nil || event.outcome == "denied"
            || ["suggest_memory", "agent_added", "agent_removed", "key_rotated", "access_changed", "agent_paused",
                "agent_resumed", "funes_paused", "funes_resumed", "import", "export", "profile_edited"].contains(event.event)
    }

    /// What makes two refusals the same: who, through what, which tool and why, and the counts.
    /// Nil for anything that isn't an agent's or a device's refusal; approvals (the user's or an
    /// expiry's) never repeat.
    static func refusalKey(_ event: ActivityEvent) -> String? {
        guard event.outcome == "denied", event.approval == nil,
              event.actor.hasPrefix("agent:") || event.actor.hasPrefix("device:") else { return nil }
        let counts = event.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return [event.actor, event.via.rawValue, event.event, event.reason?.rawValue ?? "", counts].joined(separator: "|")
    }
}

/// FunesCore's `ActivityRecorder` on BridgeUI's append-only store (storage §1).
final class ActivityLog: ActivityRecorder, Sendable {
    let store: ActivityStore<ActivityLine>
    private let listener = Mutex<(@Sendable (ActivityEvent) -> Void)?>(nil)
    private let repeats = Mutex(RepeatedRows<String>())

    init(dataFolder: URL, retention: ActivityRetention = .funes) {
        store = ActivityStore(dataFolder: dataFolder, retention: retention, autoCompact: true)
    }

    /// Called after each row is written (on the writer's thread).
    var onAppend: (@Sendable (ActivityEvent) -> Void)? {
        get { listener.withLock { $0 } }
        set { listener.withLock { $0 = newValue } }
    }

    func record(_ event: ActivityEvent) {
        let base = (event.requestID?.uuidString.lowercased() ?? UUID().uuidString.lowercased()) + "|" + event.phase.rawValue
        let repeated = ActivityLine.refusalKey(event).map { key in repeats.withLock { $0.isRepeat(key, at: event.time) } }
        store.append(ActivityLine(rowID: base, event: event, repeated: repeated == true ? true : nil))
        onAppend?(event)
    }
}
