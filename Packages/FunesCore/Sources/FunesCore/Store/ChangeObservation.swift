import Foundation
import GRDB

extension VaultStore {
    /// Tables a change to which the app's screens show: memories, categories, suggestions, agents
    /// and their access, and disclosures (Pending requests).
    static let observedTables = ["memory", "memory_category", "category", "suggestion", "agent", "access",
                                 "access_category", "disclosure"]

    /// Calls `onChange` after every committed transaction that touched what the app shows,
    /// whoever wrote it (the app, an agent's request, an import). Keep the returned object to keep
    /// observing; release it to stop. `onChange` runs on a background queue.
    public func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyObject {
        let observation = DatabaseRegionObservation(tracking: Self.observedTables.map { Table($0) })
        return observation.start(in: writer, onError: { _ in }, onChange: { _ in onChange() })
    }
}
