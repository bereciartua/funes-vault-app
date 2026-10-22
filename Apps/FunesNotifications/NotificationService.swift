@preconcurrency import CloudKit
import FunesPhone
import FunesProtocol
import os
@preconcurrency import UserNotifications

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "notifications")

/// The notification service extension (`com.funesvault.ios.notifications`, ADR-0019 §2). Every
/// doorbell ring comes through here, also with the phone locked: the push holds only the ring's
/// record name, so the extension fetches the request with `approvals.get {ring}` over the
/// companion channel and words the alert on the phone ("Claude Code wants 3 memories"). If the
/// Mac doesn't answer in time, the alert says "Mac not reachable". It never answers: that needs
/// the phone unlocked, in the app (FR-iOS-12).
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        // A Focus shouldn't hide a request an agent waits about 45 s for.
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "approvals"
        let ring = CKQueryNotification(fromRemoteNotificationDictionary: request.content.userInfo)?.recordID?.recordName
        // A tap opens the request even when the fetch never finishes.
        if let ring { content.userInfo[ApprovalAlert.Key.ring] = ring }
        Self.apply(.fallback, to: content)
        lock.withLock {
            self.contentHandler = contentHandler
            self.content = content
        }

        Task {
            let client = CompanionClient(store: KeychainSecretStore())
            let outcome = await ApprovalAlert.fetch(ring: ring, caller: client)
            if case .unreachable = outcome { logger.info("Couldn't reach the Mac for a ring") }
            self.finish(with: ApprovalAlert(outcome))
        }
    }

    /// iOS is about to end the extension: the alert goes as it stands, "Mac not reachable".
    override func serviceExtensionTimeWillExpire() {
        finish(with: nil)
    }

    private static func apply(_ alert: ApprovalAlert, to content: UNMutableNotificationContent) {
        content.title = alert.title
        content.body = alert.body
        for (key, value) in alert.userInfo { content.userInfo[key] = value }
    }

    private func finish(with alert: ApprovalAlert?) {
        let (handler, content) = lock.withLock { () -> (((UNNotificationContent) -> Void)?, UNMutableNotificationContent?) in
            defer { contentHandler = nil }
            return (contentHandler, self.content)
        }
        guard let handler, let content else { return }
        if let alert { Self.apply(alert, to: content) }
        handler(content)
    }
}
