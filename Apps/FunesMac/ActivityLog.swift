import BridgeUI
import Foundation
import FunesCore

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
            || ["suggest_memory", "agent_added", "agent_removed", "key_rotated", "access_changed"].contains(event.event)
    }
}

/// FunesCore's `ActivityRecorder` on BridgeUI's append-only store (storage §1).
final class ActivityLog: ActivityRecorder, Sendable {
    let store: ActivityStore<ActivityLine>

    init(dataFolder: URL) {
        store = ActivityStore(dataFolder: dataFolder, retention: .funes, autoCompact: true)
    }

    func record(_ event: ActivityEvent) {
        let base = (event.requestID?.uuidString.lowercased() ?? UUID().uuidString.lowercased()) + "|" + event.phase.rawValue
        store.append(ActivityLine(rowID: base, event: event))
    }
}
