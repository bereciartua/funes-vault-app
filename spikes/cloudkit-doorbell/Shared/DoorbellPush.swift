@preconcurrency import CloudKit
import Foundation

#if os(iOS)
/// The fields a CloudKit query notification carries: the record's name, plus the spike's two
/// timing fields (the subscription's desired keys).
struct DoorbellPush {
    var recordName: String?
    var seq: Int?
    var sentAt: Date?

    init(userInfo: [AnyHashable: Any]) {
        guard let notification = CKQueryNotification(fromRemoteNotificationDictionary: userInfo) else { return }
        recordName = notification.recordID?.recordName
        seq = (notification.recordFields?[Doorbell.seqField] as? NSNumber)?.intValue
        if let sent = notification.recordFields?[Doorbell.sentAtField] {
            sentAt = (sent as? Date) ?? (sent as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
    }

    func delay(at now: Date) -> Double? { sentAt.map { now.timeIntervalSince($0) } }
}
#endif
