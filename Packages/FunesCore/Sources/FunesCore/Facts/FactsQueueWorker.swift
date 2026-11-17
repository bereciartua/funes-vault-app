import Foundation
import GRDB

/// Runs the facts lane's jobs (memory processing §11.3). A memory's job reads it in its call group: in full when the
/// model hasn't read that version in that group yet, otherwise only what reconciliation finds due now (a partial
/// re-read), or nothing, with no call. The sweep revalidates in code what it can and queues the memories with something
/// due. Every applied change queues the sweep again (`FactStore.bumpRevision`), in the same transaction.
///
/// Nothing in the app queues facts jobs yet: memory commits will, while *Learn from memories* is on (the Settings step).
public struct FactsQueueWorker: Sendable {
    public let extractor: FactsExtractor
    public var clock: @Sendable () -> Date

    public init(extractor: FactsExtractor) {
        self.extractor = extractor
        self.clock = extractor.clock
    }

    /// What a memory's job will do.
    enum Plan: Equatable {
        case gone
        case full
        case partial(FactsReconciler.Due)
        case nothing
    }

    func plan(_ memoryID: String, group: String) async throws -> Plan {
        let registry = extractor.registry, users = extractor.userAliases
        return try await extractor.store.writer.write { db in
            guard let m = try Row.fetchOne(db, sql: "SELECT version, status FROM memory WHERE id = ?", arguments: [memoryID]),
                  ["active", "archived"].contains(m["status"] as String) else { return .gone }
            let read = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM facts_asked WHERE memory_id = ? AND memory_version = ? AND call_group = ? AND mention_kind = 'read')
                """, arguments: [memoryID, m["version"] as Int, group]) ?? false
            guard read else { return .full }
            let due = try FactsReconciler.reconcile(db, only: memoryID, registry: registry, userAliases: users)
                .first { $0.key.group == group }?.due
            return due.map { .partial($0) } ?? .nothing
        }
    }

    /// Runs one `facts` job and says how it went. `report` hears each learn's report (the harness records its calls).
    public func process(_ job: ProcessingJob, report: @Sendable (FactsLearnReport, String) async -> Void = { _, _ in })
        async throws -> ProcessingQueue.Outcome {
        guard job.kind == .facts else { return .done(engine: nil) }
        let engine = extractor.router.factsModel.map(ModelRouter.engine) ?? extractor.codeEngine
        guard let group = job.callGroup else {
            let registry = extractor.registry, users = extractor.userAliases, now = clock()
            try await extractor.store.writer.write { db in
                try FactsReconciler.sweep(db, registry: registry, userAliases: users, now: now)
            }
            return .done(engine: nil)
        }
        let memoryID = job.subject.db
        let scope: FactsScope, kind: String
        switch try await plan(memoryID, group: group) {
        case .gone, .nothing: return .done(engine: nil)
        case .full: (scope, kind) = (.full, "incremental")
        case let .partial(due): (scope, kind) = (.partial(roles: due.roles, names: due.names), "reconciliation")
        }
        let r = try await extractor.learn([memoryID], groups: [group], kind: kind, scope: scope)
        await report(r, scope == .full ? "full" : "reconcile")
        if let c = r.calls.first, c.outcome == .codeOnly, c.dropped.contains(FactsExtractor.transient) {
            // Read by the model later: an hour on, not counted as an attempt (the cap lasts the day).
            return .later(until: clock().addingTimeInterval(3_600), code: "unavailable")
        }
        switch r.calls.first?.outcome {
        case nil, .applied?, .codeOnly?: return .done(engine: engine)
        case .changed?: return .later(until: clock(), code: "changed")       // read again at once (§11.3)
        case .failed?: return .retry(code: "failed")
        }
    }
}
