import Foundation

/// What the Mac, the iPhone app and the notification service extension agree on.
enum Doorbell {
    /// Permanent once created in the portal: containers can't be deleted or renamed.
    static let container = "iCloud.com.funesvault"
    static let recordType = "Doorbell"
    /// Which phone the ring is for. The product gives each device a random tag; the spike uses one.
    static let tagField = "tag"
    /// Spike only, for measuring: the product's record carries nothing but the tag.
    static let seqField = "seq"
    static let sentAtField = "sentAt"
    static let defaultTag = "spike"
    static let subscriptionPrefix = "doorbell-"

    /// The alert text, set on the phone when it subscribes. Nothing from the Mac is in it.
    static let alertBody = "You have a request"

    /// Where the Mac's spike app listens for acknowledgements. Funes uses 47625–47627, a debug
    /// build 47635; EK Bridge 47615–47616.
    static let ackPort: UInt16 = 47639

    static let appGroup = "group.com.funesvault"
    static let macAddressKey = "DoorbellMacAddress"
    static let logFile = "doorbell-log.jsonl"
}

/// What the phone tells the Mac when a ring arrives.
struct DoorbellAck: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// The notification service extension ran (the phone was locked or the app in the background).
        case extensionRan = "nse"
        /// The app was in the foreground.
        case foreground
        /// "Test Mac" in the phone app.
        case test
    }

    var recordName: String
    var phase: Phase
    /// The phone's clock, milliseconds since 1970.
    var phoneReceivedAt: Int64
    /// The Mac's clock when it saved the record, from the push payload (desired keys).
    var macSentAt: Int64?
    var seq: Int?
}

/// One line of the phone's log, shared by the app and the extension through the App Group.
struct DoorbellLogEntry: Codable, Sendable, Identifiable {
    var id = UUID()
    var at: Date
    var phase: String
    var recordName: String?
    var seq: Int?
    /// Phone clock minus the Mac's `sentAt`, in seconds.
    var delaySeconds: Double?
    var macReached: Bool?
    var note: String?
}

#if os(iOS)
enum DoorbellLog {
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Doorbell.appGroup)?
            .appendingPathComponent(Doorbell.logFile)
    }

    static func append(_ entry: DoorbellLogEntry) {
        guard let url, var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            // Readable while the phone is locked (after the first unlock), so the extension can write.
            try? line.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func read() -> [DoorbellLogEntry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(DoorbellLogEntry.self, from: Data($0)) }
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif

extension Date {
    var milliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
