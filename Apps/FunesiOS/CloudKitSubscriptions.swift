@preconcurrency import CloudKit
import FunesPhone
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "doorbell")

/// The doorbell subscription in this iPhone's private CloudKit database (ADR-0019 §2): a
/// `CKQuerySubscription` on `Doorbell` with `tag == <its tag>`, firing on creation, with a fixed
/// alert, `shouldSendMutableContent` so the notification service extension words it, and no
/// desired keys, so the push holds nothing but the record name.
struct CloudKitSubscriptions: DoorbellSubscriptions {
    private var database: CKDatabase { CKContainer(identifier: Doorbell.container).privateCloudDatabase }

    func accountAvailable() async -> Bool {
        do {
            let status = try await CKContainer(identifier: Doorbell.container).accountStatus()
            if status != .available { logger.error("iCloud account status \(status.rawValue, privacy: .public)") } // log-safe: a status code
            return status == .available
        } catch {
            Self.log("account status", error)
            return false
        }
    }

    func subscriptionIDs() async throws -> [String] {
        do { return try await database.allSubscriptions().map(\.subscriptionID) } catch {
            Self.log("listing subscriptions", error)
            throw StepError(step: "listing subscriptions", error: error)
        }
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
        do { _ = try await database.save(subscription) } catch {
            Self.log("saving the subscription", error)
            throw StepError(step: "saving the subscription", error: error)
        }
        logger.info("Subscribed to the doorbell")
    }

    func unsubscribe(ids: [String]) async throws {
        do { _ = try await database.modifySubscriptions(saving: [], deleting: ids) } catch {
            Self.log("deleting subscriptions", error)
            throw StepError(step: "deleting subscriptions", error: error)
        }
    }

    /// Which call failed, for the Debug readout in Settings.
    struct StepError: Error, CustomStringConvertible {
        let step: String
        let error: any Error
        var description: String { "\(step): \(error)" }
    }

    /// The CloudKit error's code and domain only: nothing of the user's.
    private static func log(_ step: StaticString, _ error: any Error) {
        let error = error as NSError
        logger.error("CloudKit failed \(step, privacy: .public): \(error.domain, privacy: .public) \(error.code, privacy: .public)") // log-safe: a step name and an error code
    }
}
