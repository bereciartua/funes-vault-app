import Foundation
import FunesProtocol
import notify

/// Darwin notifications between the app and its extensions. They carry no data: a signal only
/// says "look again".
public enum AppSignal: String, Sendable {
    /// A capture was queued, by the app, the share extension or an App Intent.
    case queueChanged = "com.funesvault.ios.queue-changed"
    /// The Control or the Remember widget asked for Home's composer (`CaptureLaunch`).
    case openCapture = "com.funesvault.ios.open-capture"

    public func post() { notify_post(rawValue) }

    /// Each time the signal is posted, from any process of this app, until the stream ends.
    public func updates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(rawValue, &token, DispatchQueue.global(qos: .utility)) { _ in
                continuation.yield()
            }
            guard status == NOTIFY_STATUS_OK else {
                continuation.finish()
                return
            }
            let registered = token
            continuation.onTermination = { _ in notify_cancel(registered) }
        }
    }
}

/// The Control's, or the Remember widget's, request to open Home's composer, ready to type or
/// dictate. The intent may run in the extension or in the app, so it leaves the request in the
/// App Group's defaults and signals; the app takes it when it comes to the front.
public struct CaptureLaunch: Sendable {
    /// What the composer opens ready for: the keyboard, or dictation (the widget's 🎙).
    public enum Mode: String, Sendable {
        case type, dictate
    }

    /// A request older than this is stale: the user went elsewhere.
    public static let lifetime: TimeInterval = 60
    static let key = "captureLaunchRequestedAt"
    static let modeKey = "captureLaunchMode"

    private let suiteName: String?

    public init(suiteName: String? = Identifiers.appGroup) { self.suiteName = suiteName }

    private var defaults: UserDefaults? { suiteName.map { UserDefaults(suiteName: $0) } ?? .standard }

    public func request(_ mode: Mode = .type, now: Date = Date()) {
        defaults?.set(now.timeIntervalSince1970, forKey: Self.key)
        defaults?.set(mode.rawValue, forKey: Self.modeKey)
        AppSignal.openCapture.post()
    }

    /// The fresh request waiting, if any; it's used up either way.
    public func take(now: Date = Date()) -> Mode? {
        guard let defaults, let at = defaults.object(forKey: Self.key) as? Double else { return nil }
        let mode = defaults.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .type
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.modeKey)
        let age = now.timeIntervalSince1970 - at
        return age >= -5 && age <= Self.lifetime ? mode : nil
    }
}
