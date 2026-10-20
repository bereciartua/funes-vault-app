@preconcurrency import CloudKit
import SwiftUI
import UIKit
@preconcurrency import UserNotifications

@main
struct DoorbellPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { PhoneView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // CloudKit subscriptions need the app registered for remote notifications.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        DoorbellLog.append(DoorbellLogEntry(at: Date(), phase: "registered", note: "APNs token \(deviceToken.count) bytes"))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        DoorbellLog.append(DoorbellLogEntry(at: Date(), phase: "register-failed", note: error.localizedDescription))
    }

    /// While the app is open, the extension still runs first; this logs that the alert reached the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let parsed = DoorbellPush(userInfo: userInfo)
        DoorbellLog.append(DoorbellLogEntry(at: Date(), phase: "foreground", recordName: parsed.recordName, seq: parsed.seq,
                                            delaySeconds: parsed.delay(at: Date())))
        return [.banner, .sound, .list]
    }
}

struct PhoneView: View {
    @AppStorage(Doorbell.macAddressKey, store: UserDefaults(suiteName: Doorbell.appGroup)) private var macAddress = ""
    @AppStorage("DoorbellTag") private var tag = Doorbell.defaultTag
    @State private var status = ""
    @State private var log: [DoorbellLogEntry] = []

    private let container = CKContainer(identifier: Doorbell.container)

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    TextField("Mac address (from the Mac app)", text: $macAddress)
                        .keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Test Mac") { Task { await testMac() } }
                }
                Section("Doorbell") {
                    TextField("Tag", text: $tag).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Allow Notifications") { Task { await allowNotifications() } }
                    Button("Subscribe") { Task { await subscribe() } }
                    Button("Unsubscribe", role: .destructive) { Task { await unsubscribe() } }
                    if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
                }
                Section("Log (\(log.count))") {
                    ForEach(log.reversed()) { entry in
                        VStack(alignment: .leading) {
                            Text("\(entry.at.formatted(date: .omitted, time: .standard)) · \(entry.phase)\(entry.seq.map { " · #\($0)" } ?? "")")
                            if let delay = entry.delaySeconds { Text(String(format: "%.2f s after the Mac saved it", delay)) }
                            if let reached = entry.macReached { Text(reached ? "Reached the Mac" : "Mac not reachable") }
                            if let note = entry.note { Text(note).foregroundStyle(.secondary) }
                        }
                        .font(.caption)
                    }
                    Button("Copy Log") { UIPasteboard.general.string = logText }
                    Button("Clear Log", role: .destructive) { DoorbellLog.clear(); reload() }
                }
            }
            .navigationTitle("Doorbell spike")
            .refreshable { reload() }
            .onAppear(perform: reload)
        }
    }

    private var logText: String {
        log.map { e in
            [e.at.ISO8601Format(), e.phase, e.seq.map { "#\($0)" }, e.delaySeconds.map { String(format: "%.2fs", $0) },
             e.macReached.map { $0 ? "mac-ok" : "mac-unreachable" }, e.note].compactMap { $0 }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func reload() { log = DoorbellLog.read() }

    private func allowNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            status = granted ? "Notifications allowed" : "Notifications not allowed: turn them on in Settings"
        } catch {
            status = "Notifications: \(error.localizedDescription)"
        }
    }

    private func subscribe() async {
        do {
            guard try await container.accountStatus() == .available else {
                status = "iCloud isn't available: sign in with the Mac's Apple ID"
                return
            }
            let subscription = CKQuerySubscription(recordType: Doorbell.recordType,
                                                   predicate: NSPredicate(format: "%K == %@", Doorbell.tagField, tag),
                                                   subscriptionID: Doorbell.subscriptionPrefix + tag,
                                                   options: [.firesOnRecordCreation])
            let info = CKSubscription.NotificationInfo()
            info.alertBody = Doorbell.alertBody
            info.soundName = "default"
            // Lets the extension word the alert on the phone. The product sends no desired keys;
            // the spike asks for its two timing fields.
            info.shouldSendMutableContent = true
            info.desiredKeys = [Doorbell.seqField, Doorbell.sentAtField]
            subscription.notificationInfo = info
            _ = try await container.privateCloudDatabase.save(subscription)
            status = "Subscribed to tag \"\(tag)\""
        } catch {
            status = "Subscribe failed: \(error.localizedDescription)"
        }
    }

    private func unsubscribe() async {
        do {
            _ = try await container.privateCloudDatabase.deleteSubscription(withID: Doorbell.subscriptionPrefix + tag)
            status = "Unsubscribed"
        } catch {
            status = "Unsubscribe failed: \(error.localizedDescription)"
        }
    }

    private func testMac() async {
        let ack = DoorbellAck(recordName: "test", phase: .test, phoneReceivedAt: Date().milliseconds)
        let reached = await AckClient.send(ack, to: macAddress)
        status = reached ? "Reached the Mac" : "Mac not reachable at \(macAddress):\(Doorbell.ackPort)"
        DoorbellLog.append(DoorbellLogEntry(at: Date(), phase: "test", macReached: reached))
        reload()
    }
}
