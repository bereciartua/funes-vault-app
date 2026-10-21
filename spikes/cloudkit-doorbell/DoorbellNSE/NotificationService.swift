@preconcurrency import CloudKit
@preconcurrency import UserNotifications

/// Runs for every doorbell push, also with the phone locked: logs when it ran, tells the Mac, and
/// words the alert. In the product it would fetch the request's panel over the companion channel
/// here instead.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let received = Date()
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.interruptionLevel = .timeSensitive
        self.content = content

        let push = DoorbellPush(userInfo: request.content.userInfo)
        let address = UserDefaults(suiteName: Doorbell.appGroup)?.string(forKey: Doorbell.macAddressKey) ?? ""
        let ack = DoorbellAck(recordName: push.recordName ?? "unknown", phase: .extensionRan,
                              phoneReceivedAt: received.milliseconds, macSentAt: push.sentAt?.milliseconds, seq: push.seq)
        Task {
            let reached = await AckClient.send(ack, to: address, timeout: 10)
            let delay = push.delay(at: received)
            DoorbellLog.append(DoorbellLogEntry(at: received, phase: "nse", recordName: push.recordName, seq: push.seq,
                                                delaySeconds: delay, macReached: reached))
            content.body = [delay.map { String(format: "Arrived %.1f s after the Mac rang", $0) },
                            reached ? "Reached your Mac" : "Mac not reachable"].compactMap { $0 }.joined(separator: ". ")
            self.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        DoorbellLog.append(DoorbellLogEntry(at: Date(), phase: "nse-timeout"))
        finish()
    }

    private func finish() {
        guard let handler = contentHandler, let content else { return }
        contentHandler = nil
        handler(content)
    }
}
