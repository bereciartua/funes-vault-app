import Foundation
import FunesProtocol

/// One doorbell record (ADR-0019 §1): a fresh random name and the device's tag. Nothing else can
/// go in: no text, titles, task, agent name, counts or request id.
public struct DoorbellRing: Sendable, Hashable {
    /// 32 lowercase hex digits, 128 random bits, new for every ring.
    public let recordName: String
    public let tag: String

    init(tag: String) {
        recordName = Self.randomName()
        self.tag = tag
    }

    static func randomName() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String(generator.next() as UInt64, radix: 16) }
            .map { String(repeating: "0", count: 16 - $0.count) + $0 }.joined()
    }
}

/// Where rings go: the private CloudKit database in the app (`CloudKitDoorbell`), a recorder in
/// tests. Kept behind this protocol so FunesCompanion has no CloudKit and tests need no iCloud.
public protocol DoorbellChannel: Sendable {
    func availability() async -> DoorbellAvailability
    /// Saves one record per ring. Throws when CloudKit refuses; nothing retries (the pending list
    /// is the backstop).
    func ring(_ rings: [DoorbellRing]) async throws
    func remove(recordNames: [String]) async throws
    /// At launch: every record left with one of these tags (none outlives its request).
    func removeAll(tags: [String]) async throws
}

/// No doorbell: a build without iCloud, or before the app sets one.
public struct NoDoorbell: DoorbellChannel {
    public init() {}
    public func availability() async -> DoorbellAvailability { .unsupported }
    public func ring(_ rings: [DoorbellRing]) async throws {}
    public func remove(recordNames: [String]) async throws {}
    public func removeAll(tags: [String]) async throws {}
}
