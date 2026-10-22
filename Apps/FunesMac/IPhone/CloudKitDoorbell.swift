@preconcurrency import CloudKit
import Foundation
import FunesCompanion
import FunesProtocol
import os
import Security

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "doorbell")

/// The doorbell in the user's private CloudKit database (ADR-0019): `Doorbell` records with only
/// `tag`, in the default zone of `iCloud.com.funesvault`. The Mac only saves and deletes; it never
/// subscribes or receives pushes. A build without the iCloud entitlement (CloudKit would crash
/// it) never touches CloudKit and reports `unsupported`.
final class CloudKitDoorbell: DoorbellChannel {
    private let container: CKContainer?

    init() {
        container = Self.isEntitled ? CKContainer(identifier: Doorbell.container) : nil
    }

    /// Whether this process is signed with the container (`com.apple.developer.icloud-container-identifiers`).
    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(Doorbell.container) == true
    }

    func availability() async -> DoorbellAvailability {
        guard let container else { return .unsupported }
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted, .temporarilyUnavailable, .couldNotDetermine: return .restricted
            @unknown default: return .restricted
            }
        } catch {
            return .restricted
        }
    }

    func ring(_ rings: [DoorbellRing]) async throws {
        guard let database = container?.privateCloudDatabase, !rings.isEmpty else { return }
        let records = rings.map { ring in
            let record = CKRecord(recordType: Doorbell.recordType, recordID: CKRecord.ID(recordName: ring.recordName))
            record[Doorbell.tagField] = ring.tag as CKRecordValue
            return record
        }
        let (saved, _) = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
        let failed = saved.values.filter { if case .failure = $0 { true } else { false } }.count
        if failed > 0 { logger.error("\(failed, privacy: .public) doorbell records weren't saved") } // log-safe: a count
    }

    func remove(recordNames: [String]) async throws {
        guard let database = container?.privateCloudDatabase, !recordNames.isEmpty else { return }
        _ = try await database.modifyRecords(saving: [], deleting: recordNames.map { CKRecord.ID(recordName: $0) },
                                             atomically: false)
    }

    func removeAll(tags: [String]) async throws {
        guard let database = container?.privateCloudDatabase, !tags.isEmpty,
              await availability() == .available else { return }
        let query = CKQuery(recordType: Doorbell.recordType, predicate: NSPredicate(format: "%K IN %@", Doorbell.tagField, tags))
        let (matches, _) = try await database.records(matching: query, desiredKeys: [], resultsLimit: 200)
        try await remove(recordNames: matches.map(\.0.recordName))
    }
}
