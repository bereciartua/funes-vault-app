import AppKit
import UserNotifications

/// The optional notifications (FR-L-04): a request expired unanswered, a suggestion is waiting, an
/// agent was refused repeatedly, Remote Access's tunnel stopped. Each is off until turned on in Settings ▸ General; permission is
/// asked then, never at launch. A daily tidy-up with results says so (memory processing §9.5);
/// permission is asked when it's turned on. Notifications name agents and counts, never memory or task text.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String { case expired, suggestion, refused, tunnelDown, tidyUp }

    /// A click: which kind, and the agent it's about.
    var onOpen: (Kind, UUID?) -> Void = { _, _ in }
    private var center: UNUserNotificationCenter? {
        // A bundle is needed; the UI-review build and tests never post.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }
    /// Refusals per agent in the last 10 minutes, and when each agent was last notified.
    private var refusals: [UUID: [Date]] = [:]
    private var lastRefusedNotice: [UUID: Date] = [:]

    override init() {
        super.init()
        center?.delegate = self
    }

    func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else { return done(false) }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(granted) } }
        }
    }

    func post(_ kind: Kind, title: String, body: String, agentID: UUID? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["kind": kind.rawValue, "agent": agentID?.uuidString ?? ""]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Counts a refusal; true when the agent passed 5 in 10 minutes (and wasn't noticed in the last hour).
    func noteRefusal(agentID: UUID, at now: Date) -> Bool {
        var recent = (refusals[agentID] ?? []).filter { now.timeIntervalSince($0) < 600 }
        recent.append(now)
        refusals[agentID] = recent
        guard recent.count > 5, lastRefusedNotice[agentID].map({ now.timeIntervalSince($0) >= 3_600 }) ?? true else { return false }
        lastRefusedNotice[agentID] = now
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = (info["kind"] as? String).flatMap(Kind.init(rawValue:))
        let agent = (info["agent"] as? String).flatMap(UUID.init(uuidString:))
        completionHandler()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { if let kind { self.onOpen(kind, agent) } }
        }
    }
}
