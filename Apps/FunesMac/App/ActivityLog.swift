import BridgeUI
import Foundation
import FunesCore
import Synchronization

/// One line of `activity/activity.jsonl`: FunesCore's `ActivityEvent` (ids, codes and counts,
/// never memory text, task text or keys) with the row bookkeeping BridgeUI's store needs.
struct ActivityLine: ActivityRow {
    var rowID: String
    let event: ActivityEvent

    var at: Date { event.time }
    var phase: String { event.phase.rawValue }
    var requestID: String? { event.requestID?.uuidString.lowercased() }
    /// Refusals, approvals, changes and suggestions are kept 400 days (BridgeUI `.funes`).
    var isImportant: Bool {
        event.approval != nil || event.reason != nil || event.outcome == "denied"
            || ["suggest_memory", "agent_added", "agent_removed", "key_rotated", "access_changed", "agent_paused",
                "agent_resumed", "funes_paused", "funes_resumed", "import", "export"].contains(event.event)
    }
}

/// FunesCore's `ActivityRecorder` on BridgeUI's append-only store (storage §1).
final class ActivityLog: ActivityRecorder, Sendable {
    let store: ActivityStore<ActivityLine>
    private let listener = Mutex<(@Sendable () -> Void)?>(nil)

    init(dataFolder: URL, retention: ActivityRetention = .funes) {
        store = ActivityStore(dataFolder: dataFolder, retention: retention, autoCompact: true)
    }

    /// Called after each row is written (on the writer's thread).
    var onAppend: (@Sendable () -> Void)? {
        get { listener.withLock { $0 } }
        set { listener.withLock { $0 = newValue } }
    }

    func record(_ event: ActivityEvent) {
        let base = (event.requestID?.uuidString.lowercased() ?? UUID().uuidString.lowercased()) + "|" + event.phase.rawValue
        store.append(ActivityLine(rowID: base, event: event))
        onAppend?()
    }
}
