@preconcurrency import CloudKit
import FunesPhone
import FunesProtocol

/// The doorbell subscription in this iPhone's private CloudKit database (ADR-0019 §2): a
/// `CKQuerySubscription` on `Doorbell` with `tag == <its tag>`, firing on creation, with a fixed
/// alert, `shouldSendMutableContent` so the notification service extension words it, and no
/// desired keys, so the push holds nothing but the record name.
struct CloudKitSubscriptions: DoorbellSubscriptions {
    private var database: CKDatabase { CKContainer(identifier: Doorbell.container).privateCloudDatabase }

    func accountAvailable() async -> Bool {
        (try? await CKContainer(identifier: Doorbell.container).accountStatus()) == .available
    }

    func subscriptionIDs() async throws -> [String] {
        try await database.allSubscriptions().map(\.subscriptionID)
    }

    func subscribe(id: String, tag: String, alertBody: String) async throws {
        let subscription = CKQuerySubscription(recordType: Doorbell.recordType,
                                               predicate: NSPredicate(format: "%K == %@", Doorbell.tagField, tag),
                                               subscriptionID: id, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.alertBody = alertBody
        info.soundName = "default"
        info.shouldSendMutableContent = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    func unsubscribe(ids: [String]) async throws {
        _ = try await database.modifySubscriptions(saving: [], deleting: ids)
    }
}
