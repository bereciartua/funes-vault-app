import Foundation
import FunesProtocol
import Observation

/// What waits for the user on the Mac (`approvals.list`), soonest deadline first: shown when the
/// app opens, for a notification that never came or was dismissed.
@MainActor @Observable
public final class ApprovalsModel {
    public enum Phase: Sendable, Equatable {
        case idle, loading, loaded
        case failed(CompanionClientError)
    }

    public private(set) var items: [ApprovalSummary] = []
    public private(set) var phase = Phase.idle
    /// One `approvals.list` at a time: a foreground, a network change and a ring can come together.
    private var loading = false
    /// When the list last came back. Each call is a row in the Mac's Activity, so a read this
    /// recent is enough unless something says the list changed (a ring, an answer).
    private var loadedAt: Date?
    public static let freshFor: TimeInterval = 5

    private let caller: any CompanionCalling
    private let clock: @Sendable () -> Date
    @ObservationIgnored public var onFailure: @MainActor (CompanionClientError) -> Void = { _ in }

    public init(caller: any CompanionCalling, clock: @escaping @Sendable () -> Date = Date.init) {
        self.caller = caller
        self.clock = clock
    }

    /// The ones still answerable by the phone's clock.
    public var waiting: [ApprovalSummary] {
        let now = clock()
        return items.filter { $0.expiresAt > now }
    }

    /// `approvals.list`, unless it came back less than `freshFor` ago; `force` after a ring.
    public func load(force: Bool = false) async {
        guard !loading else { return }
        if !force, phase == .loaded, let loadedAt, clock().timeIntervalSince(loadedAt) < Self.freshFor { return }
        loading = true
        defer { loading = false }
        if items.isEmpty { phase = .loading }
        do {
            items = try await caller.call(ApprovalsList.self, EmptyParams()).items.sorted { $0.expiresAt < $1.expiresAt }
            loadedAt = clock()
            phase = .loaded
        } catch {
            if items.isEmpty { phase = .failed(error) }
            onFailure(error)
        }
    }

    /// Answered or closed in its panel.
    public func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    /// Leaving the Mac (unpaired, removed): nothing stays on the phone.
    public func clear() {
        items = []
        phase = .idle
        loadedAt = nil
    }
}

// MARK: - The doorbell subscription

/// This iPhone's CloudKit subscriptions to the doorbell (ADR-0019 §2): the app's `CloudKit`
/// adapter, and a fake in tests.
public protocol DoorbellSubscriptions: Sendable {
    /// Whether this iPhone is signed in to iCloud, so the subscription can exist.
    func accountAvailable() async -> Bool
    /// The ids of this app's subscriptions in the private database.
    func subscriptionIDs() async throws -> [String]
    /// A `CKQuerySubscription` on `Doorbell` with `tag == <tag>`, firing on creation, with the
    /// fixed alert, `shouldSendMutableContent` and no desired keys.
    func subscribe(id: String, tag: String, alertBody: String) async throws
    func unsubscribe(ids: [String]) async throws
}

/// What to change so the phone is subscribed to exactly its current tag: one `doorbell-<tag>`
/// while approvals are on and the Mac has handed out a tag, none otherwise. A tag changes after
/// approvals go off and on, so an old one's subscription goes.
public struct DoorbellSubscriptionPlan: Sendable, Equatable {
    public static let prefix = "doorbell-"

    public var subscribeTag: String?
    public var unsubscribe: [String]

    public static func id(_ tag: String) -> String { prefix + tag }

    public init(settings: ApprovalSettings, existing: [String]) {
        let wanted = settings.enabled ? settings.tag.map(Self.id) : nil
        subscribeTag = wanted.flatMap { existing.contains($0) ? nil : settings.tag }
        unsubscribe = existing.filter { $0.hasPrefix(Self.prefix) && $0 != wanted }.sorted()
    }

    public var isEmpty: Bool { subscribeTag == nil && unsubscribe.isEmpty }
}

/// Settings ▸ Approvals on the phone: the device's switch (`approvals.settings.get`/`.set`, the
/// same flag as Settings ▸ iPhone on the Mac), and the CloudKit subscription that follows it.
/// The phone subscribes only once the Mac has given it a tag.
@MainActor @Observable
public final class ApprovalSettingsModel {
    public enum Subscription: Sendable, Equatable {
        /// Not checked yet (no settings from the Mac yet).
        case unknown
        /// Approvals off: nothing to ring.
        case off
        case subscribed
        /// This iPhone isn't signed in to iCloud.
        case noICloud
        /// CloudKit refused; tried again on the next foreground.
        case failed
    }

    public private(set) var settings: ApprovalSettings?
    public private(set) var subscription = Subscription.unknown
    /// Why CloudKit refused the subscription, as it said it (`.failed`), for Debug builds and logs.
    public private(set) var subscriptionError: String?
    public private(set) var saving = false
    /// The switch's last change didn't reach the Mac.
    public var failure: CompanionClientError?

    private let caller: any CompanionCalling
    private let subscriptions: any DoorbellSubscriptions
    /// One check at a time, so two never save or delete the same subscription at once.
    private var syncing = false
    @ObservationIgnored public var onFailure: @MainActor (CompanionClientError) -> Void = { _ in }
    /// Approvals are on with a tag: the app asks for notification permission then.
    @ObservationIgnored public var onSubscribed: @MainActor () async -> Void = {}

    public init(caller: any CompanionCalling, subscriptions: any DoorbellSubscriptions) {
        self.caller = caller
        self.subscriptions = subscriptions
    }

    /// `approvals.settings.get`, then the subscription. Cheap and not logged on the Mac, so it
    /// runs on every foreground.
    public func load() async {
        do {
            settings = try await caller.call(ApprovalsSettingsGet.self, EmptyParams())
        } catch {
            onFailure(error)
            return
        }
        await sync()
    }

    /// The switch.
    public func setEnabled(_ enabled: Bool) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        failure = nil
        do {
            settings = try await caller.call(ApprovalsSettingsSet.self, ApprovalSettingsChange(enabled: enabled))
        } catch {
            failure = error
            onFailure(error)
            return
        }
        await sync()
    }

    /// Makes the subscriptions match the settings. Nothing happens before the Mac's answer.
    public func sync() async {
        guard let settings, !syncing else { return }
        syncing = true
        defer { syncing = false }
        let wantsRing = settings.enabled && settings.tag != nil
        guard await subscriptions.accountAvailable() else {
            subscription = wantsRing ? .noICloud : .off
            return
        }
        // Listing can fail on a subscription CloudKit can no longer read back (one naming fields
        // the record type no longer has): the current one is still saved, by its id.
        var listingError: (any Error)?
        let existing: [String]
        do { existing = try await subscriptions.subscriptionIDs() } catch {
            listingError = error
            existing = []
        }
        let plan = DoorbellSubscriptionPlan(settings: settings, existing: existing)
        do {
            // The current tag's subscription first: an old one that CloudKit can't delete (one
            // naming fields the record type no longer has, say) must not keep this one away.
            if let tag = plan.subscribeTag {
                try await subscriptions.subscribe(id: DoorbellSubscriptionPlan.id(tag), tag: tag, alertBody: ApprovalWording.generic)
            }
            subscription = wantsRing ? .subscribed : .off
            subscriptionError = listingError.map { String(describing: $0) }
        } catch {
            subscription = .failed
            subscriptionError = String(describing: error)
            return
        }
        // An old tag's subscription goes quiet anyway: the Mac never rings that tag again.
        if !plan.unsubscribe.isEmpty {
            do { try await subscriptions.unsubscribe(ids: plan.unsubscribe) } catch {
                subscriptionError = String(describing: error)
            }
        }
        if wantsRing { await onSubscribed() }
    }

    /// Unpairing: no ring reaches this iPhone any more.
    public func clear() async {
        settings = nil
        subscription = .unknown
        failure = nil
        guard await subscriptions.accountAvailable(),
              let ids = try? await subscriptions.subscriptionIDs().filter({ $0.hasPrefix(DoorbellSubscriptionPlan.prefix) }),
              !ids.isEmpty else { return }
        try? await subscriptions.unsubscribe(ids: ids)
    }
}
