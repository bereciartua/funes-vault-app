import Foundation
import GRDB
@testable import FunesCore

/// The time model's and the store's tests run with every declared use on (a measurement, as the fixture harness does):
/// the app never has these, since every graph, load, apply and reconciliation in Sources says which uses it reads with.
extension FactsGraph {
    init(registry: FactsRegistry = .bundled, userAliases: [String] = []) {
        self.init(registry: registry, userAliases: userAliases, uses: .everyDeclared(registry))
    }
}

extension FactStore {
    static func load(_ db: Database, registry: FactsRegistry = .bundled, userAliases: [String] = [],
                     excluding: Exclusion? = nil, sendable: CloudLimit? = nil) throws -> Loaded {
        try load(db, registry: registry, userAliases: userAliases, uses: .everyDeclared(registry), excluding: excluding, sendable: sendable)
    }

    @discardableResult
    static func apply(_ db: Database, memoryID: String, version: Int, extraction: FactsExtraction, callGroup: String,
                      runID: String? = nil, registry: FactsRegistry = .bundled, userAliases: [String] = [],
                      now: Date = Date(), readAt: Date? = nil, sendable: CloudLimit? = nil) throws -> ApplyResult {
        try apply(db, memoryID: memoryID, version: version, extraction: extraction, callGroup: callGroup, runID: runID,
                  registry: registry, userAliases: userAliases, uses: .everyDeclared(registry), now: now, readAt: readAt,
                  sendable: sendable)
    }
}

extension FactsReconciler {
    static func reconcile(_ db: Database, only memoryID: String? = nil, registry: FactsRegistry = .bundled,
                          userAliases: [String] = [], sendable: CloudLimit? = nil) throws -> [(key: Key, due: Due)] {
        try reconcile(db, only: memoryID, registry: registry, userAliases: userAliases, uses: .everyDeclared(registry), sendable: sendable)
    }

    @discardableResult
    static func sweep(_ db: Database, registry: FactsRegistry = .bundled, userAliases: [String] = [], sendable: CloudLimit? = nil,
                      now: Date) throws -> Int {
        try sweep(db, registry: registry, userAliases: userAliases, uses: .everyDeclared(registry), sendable: sendable, now: now)
    }
}
