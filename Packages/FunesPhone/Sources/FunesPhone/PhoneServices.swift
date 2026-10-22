import Foundation
import FunesProtocol

/// What the app's models talk to: the paired Mac through `CompanionClient`, or the demo vault
/// (FR-iOS-10). Search, the Inbox, approvals and capture delivery see only `caller`, `sender`,
/// `subscriptions` and `queue`, so the demo runs the same models and screens as the real thing.
public struct PhoneServices: Sendable {
    /// The real pieces: the Keychain (the pairing and its keys), the network, CloudKit and the
    /// App Group's capture queue.
    public struct Live: Sendable {
        public var store: any SecretStore
        public var transport: any CompanionTransport
        public var discovery: any MacDiscovery
        public var subscriptions: any DoorbellSubscriptions
        public var queue: @Sendable () throws(CaptureQueueError) -> CaptureQueue

        public init(store: any SecretStore, transport: any CompanionTransport, discovery: any MacDiscovery,
                    subscriptions: any DoorbellSubscriptions,
                    queue: @escaping @Sendable () throws(CaptureQueueError) -> CaptureQueue = { () throws(CaptureQueueError) in try CaptureQueue.appGroup() }) {
            self.store = store
            self.transport = transport
            self.discovery = discovery
            self.subscriptions = subscriptions
            self.queue = queue
        }
    }

    /// The demo's capture queue, in its own file: demo captures never reach the App Group's queue,
    /// and so never a Mac.
    public static let demoQueueName = "demo-capture-queue.sqlite"

    /// Nil in demo mode.
    public let client: CompanionClient?
    /// Nil unless in demo mode.
    public let demo: DemoVault?
    public let caller: any CompanionCalling
    public let sender: any CaptureSender
    public let subscriptions: any DoorbellSubscriptions
    /// Nil when the queue's file can't be had (no App Group container).
    public let queue: CaptureQueue?

    public var isDemo: Bool { demo != nil }

    /// The paired Mac's services, or, with `demo`, the demo vault's. In demo mode `live` is never
    /// evaluated: no client, Keychain read, connection, CloudKit call or App Group queue. The
    /// demo's queue is a fresh file in `demoDirectory`.
    public init(demo: Bool, live: @autoclosure () -> Live, demoDirectory: URL, clock: @escaping @Sendable () -> Date = Date.init) {
        if demo {
            let vault = DemoVault(clock: clock)
            self.demo = vault
            client = nil
            caller = vault
            sender = vault
            subscriptions = NoSubscriptions()
            Self.discardDemo(in: demoDirectory)
            queue = CaptureQueue(url: demoDirectory.appending(path: Self.demoQueueName))
        } else {
            let live = live()
            let client = CompanionClient(store: live.store, transport: live.transport, discovery: live.discovery, clock: clock)
            self.demo = nil
            self.client = client
            caller = client
            sender = client
            subscriptions = live.subscriptions
            queue = try? live.queue()
        }
    }

    /// Leaving the demo: its captures go with it (UX: iPhone, Demo mode). Its vault was only ever
    /// in memory.
    public static func discardDemo(in directory: URL) {
        let file = directory.appending(path: demoQueueName)
        for url in [file] + ["-wal", "-shm", "-journal"].map({ URL(filePath: file.path + $0) }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// The demo's doorbell: there's no iCloud account to subscribe with, and so nothing to ring.
struct NoSubscriptions: DoorbellSubscriptions {
    func accountAvailable() async -> Bool { false }
    func subscriptionIDs() async throws -> [String] { [] }
    func subscribe(id: String, tag: String, alertBody: String) async throws {}
    func unsubscribe(ids: [String]) async throws {}
}
