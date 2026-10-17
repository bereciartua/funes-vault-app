import Foundation
import FunesProtocol
import GRDB
@testable import FunesCore

/// A fixed point in time for tests: whole seconds, so GRDB's millisecond storage round-trips.
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

extension Date {
    func plus(minutes: Double) -> Date { addingTimeInterval(minutes * 60) }
    func plus(days: Double) -> Date { addingTimeInterval(days * 86_400) }
}

/// A vault in a fresh temporary folder, removed when the value is released.
final class TestVault: @unchecked Sendable {
    let directory: URL
    let store: VaultStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "funes-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        store = try VaultStore.open(directory: directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func memory(_ title: String, _ body: String? = nil, categories: [String] = ["personal_preferences"],
                sensitivity: Sensitivity? = .low, kind: MemoryKind = .fact, expiresAt: Date? = nil,
                now: Date = t0) throws -> Memory {
        try store.createMemory(MemoryDraft(title: title, body: body ?? "\(title) body", kind: kind, categoryKeys: categories,
                                           sensitivity: sensitivity, expiresAt: expiresAt), now: now)
    }

    func count(_ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try store.writer.read { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }
}
