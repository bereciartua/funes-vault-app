@preconcurrency import CloudKit
import FunesPhone
import FunesProtocol
import os
import UIKit
@preconcurrency import UserNotifications

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "notifications")

/// Push registration, which CloudKit subscriptions need, and the approval notifications: shown
/// while the app is open, and a tap opens the request (task 5.6).
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Opens a request (or the list, for nil). Set once the model exists; a tap that launched
    /// the app waits for it.
    var open: ((ApprovalRef?) -> Void)? {
        didSet {
            guard let open else { return }
            pending.forEach(open)
            pending = []
        }
    }
    /// A ring arrived while the app is open: the list reads the Mac again.
    var rang: () -> Void = {}
    private var pending: [ApprovalRef?] = []

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        logger.info("Registered for remote notifications")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        logger.error("Couldn't register for remote notifications")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
        Task { @MainActor in self.rang() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let ref = Self.ref(response.notification.request.content.userInfo)
        completionHandler()
        Task { @MainActor in
            if let open = self.open { open(ref) } else { self.pending.append(ref) }
        }
    }

    /// What the extension put in the notification; if it never ran, the ring's own record name.
    nonisolated static func ref(_ userInfo: [AnyHashable: Any]) -> ApprovalRef? {
        if let ref = ApprovalAlert.ref(fromUserInfo: userInfo) { return ref }
        guard let ring = CKQueryNotification(fromRemoteNotificationDictionary: userInfo)?.recordID?.recordName else { return nil }
        return ApprovalAlert.ref(fromUserInfo: [ApprovalAlert.Key.ring: ring])
    }
}

/// Notification permission, asked once approvals are on with a tag (so there's something to
/// notify about), and read again on every foreground for Settings.
enum NotificationPermission {
    static func current() async -> Bool? {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: nil
        case .denied: false
        default: true
        }
    }

    /// Asks when iOS hasn't yet; otherwise just says.
    static func ask() async -> Bool {
        if let decided = await current() { return decided }
        do { return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) } catch {
            logger.error("Couldn't ask for notification permission")
            return false
        }
    }
}
