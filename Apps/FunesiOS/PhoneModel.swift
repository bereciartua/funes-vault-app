import FunesPhone
import FunesProtocol
import Observation
import os
import SwiftUI
import UIKit

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "app")

/// The app's state: the pairing, how the Mac is reachable (UX: iPhone, States), the capture
/// queue, Search and the Inbox, which read the vault on the Mac, and the requests waiting for an
/// answer (task 5.6). In demo mode (FR-iOS-10) the same models read the demo vault instead, and
/// nothing reaches the network, the pairing or CloudKit.
@MainActor @Observable
final class PhoneModel {
    private(set) var record: PairingRecord?
    /// The name Home's title greets the user by (ADR-0026): the Mac's latest, kept with the
    /// pairing while the Mac is away; none once this iPhone is removed or unpaired.
    var calledName: String? {
        switch reachability {
        case let .connected(connection): connection.status.calledName
        case .revoked, .notPaired: nil
        default: record?.calledName
        }
    }
    /// The Mac's Search answers while it's connected (`status.get`); nil while they're off or the
    /// Mac is away (FR-iOS-13).
    var macAnswers: SearchAnswersStatus? {
        if case let .connected(connection) = reachability { return connection.status.searchAnswers }
        return nil
    }
    /// The connection's state machine (FunesPhone's `ReachabilityTracker`).
    private(set) var tracker = ReachabilityTracker()
    var reachability: Reachability { tracker.state }
    var lastChecked: Date? { tracker.lastChecked }
    var lastReached: ReachabilityTracker.LastReached? { tracker.lastReached }
    /// What the status bar above the tab bar shows, and when (UX: iPhone, Status bar).
    let statusBar = StatusBar()
    /// The phone's network: a LAN address reached off Wi-Fi goes through a VPN.
    private(set) var path: NetworkPath?
    private(set) var usesSecureEnclave: Bool?
    private(set) var protocolChecks: [ProtocolCheck] = []
    /// Each address's probe in the last check (Debug's Spike 1 section).
    private(set) var probes: [ProbeOutcome] = []
    private(set) var spikeMessage: String?
    private var testCaptureID: UUID?

    /// The paired Mac's client, or the demo vault (`PhoneServices`).
    let services: PhoneServices
    var isDemo: Bool { services.isDemo }
    /// Turns demo mode on or off: the app builds a new model (`AppState`).
    @ObservationIgnored var switchDemo: (Bool) -> Void = { _ in }
    let capture: CaptureModel
    let search: SearchModel
    let inbox: InboxModel
    let categories: CategoryList
    /// Requests waiting on the Mac (`approvals.list`).
    let approvals: ApprovalsModel
    /// This iPhone's approvals switch and its doorbell subscription.
    let approvalSettings: ApprovalSettingsModel
    /// The vault's counts for Home and the widgets, cached in the App Group (ADR-0025).
    let overview: OverviewModel
    /// The request whose panel is open, from a notification or the list.
    var openApproval: OpenApproval?
    /// Whether Funes may show notifications; nil until iOS has asked.
    private(set) var notificationsAllowed: Bool?
    /// The pairing sheet, opened from the status bar, Home's pairing card or a disabled tab.
    var presentingPairing = false
    /// The status sheet: tapping the status bar, or Why?.
    var presentingStatus = false
    /// The tab showing: Home, where the app opens, unless a screenshot scene says otherwise.
    #if DEBUG
    var tab = ScreenshotScene.current?.tab ?? RootView.Tab.home
    #else
    var tab = RootView.Tab.home
    #endif
    /// Home's Pulse sheet, open on this range.
    var pulseSheet: PulseRange?
    /// The Control or the Remember widget asked for Home's composer, ready to type or dictate.
    private(set) var captureRequests = 0
    /// How the last request wants it: the widget's 🎙 starts dictation.
    private(set) var captureMode = CaptureLaunch.Mode.type
    private var started = false
    private var refreshing = false

    init(services: PhoneServices) {
        self.services = services
        capture = CaptureModel(queue: services.queue, sender: services.sender, isDemo: services.isDemo)
        search = SearchModel(caller: services.caller)
        inbox = InboxModel(caller: services.caller)
        categories = CategoryList(caller: services.caller)
        approvals = ApprovalsModel(caller: services.caller)
        approvalSettings = ApprovalSettingsModel(caller: services.caller, subscriptions: services.subscriptions)
        overview = OverviewModel(caller: services.caller, cache: OverviewCache.appGroup(), demo: services.isDemo)
        // The widgets read the cache (FR-H-06): they redraw after every write.
        overview.onCacheChange = { FunesWidgets.reload() }
        capture.onOutcome = { [weak self] outcome in self?.delivered(outcome) }
        search.onFailure = { [weak self] error in self?.callFailed(error) }
        inbox.onFailure = { [weak self] error in self?.callFailed(error) }
        approvals.onFailure = { [weak self] error in self?.callFailed(error) }
        approvalSettings.onFailure = { [weak self] error in self?.callFailed(error) }
        overview.onFailure = { [weak self] error in self?.callFailed(error) }
        // There's something to notify about now: iOS asks once.
        approvalSettings.onSubscribed = { [weak self] in self?.notificationsAllowed = await NotificationPermission.ask() }
    }

    /// Opens a request's panel, by id or by the ring's record name; nil just reads the list again
    /// (a tapped notification the extension couldn't word).
    func open(_ ref: ApprovalRef?) {
        guard let ref else {
            Task { if reachability.isConnected { await approvals.load(force: true) } }
            return
        }
        let panel = ApprovalPanelModel(ref: ref, caller: services.caller,
                                       // Answers need the phone unlocked (FR-iOS-12): protected data is
                                       // available only then.
                                       isUnlocked: { UIApplication.shared.isProtectedDataAvailable })
        panel.onFailure = { [weak self] error in self?.callFailed(error) }
        panel.onClosed = { [weak self] id in self?.approvals.remove(id) }
        openApproval = OpenApproval(panel: panel)
    }

    /// A ring arrived while the app is open: something new waits.
    func rang() {
        Task { if reachability.isConnected { await approvals.load(force: true) } }
    }

    /// The connection's state, for the status bar and the disabled tabs.
    var banner: BannerState {
        BannerState(reachability, macName: record?.macName, waiting: capture.queuedCount, path: path)
    }

    /// The status sheet's suggestions.
    var diagnosis: UnreachableDiagnosis {
        UnreachableDiagnosis(reachability, path: path, addresses: record?.addresses ?? [], probes: probes)
    }

    /// The Inbox tab's badge: the whole list once it's read, else what `status.get` said.
    var inboxBadge: Int {
        if inbox.phase == .loaded, inbox.nextCursor == nil { return inbox.items.count }
        if case let .connected(connection) = reachability { return max(connection.status.inboxPending, inbox.items.count) }
        return inbox.items.count
    }

    /// One memory's detail, wired to the connection's state and to Search's list.
    func detailModel(_ id: UUID) -> MemoryDetailModel {
        let detail = MemoryDetailModel(id: id, caller: services.caller)
        detail.onFailure = { [weak self] error in self?.callFailed(error) }
        detail.onChange = { [weak self] change in
            switch change {
            case let .changed(memory): self?.search.changed(memory)
            case let .removed(id): self?.search.removed(id)
            }
        }
        return detail
    }

    /// Home's tiles: Search, newest first, or only the memories at `sensitivity`.
    func openSearch(sensitivity: Sensitivity?) {
        search.query = ""
        search.scope = .active
        search.sensitivity = sensitivity
        tab = .search
    }

    func start() async {
        guard !started else { return }
        started = true
        #if DEBUG
        if let scene = ConnectionScene.current, !isDemo {
            record = scene.record
            tracker.handle(.pairing(paired: true))
            tracker.handle(.checked(scene.check, at: Date()))
            // Home's charts: the demo's counts, as if cached at 10:42 when the Mac is away; and
            // the widgets', with their "as of" (never over a real pairing's, which is read first).
            if overview.overview(.days30) == nil, var sample = try? await DemoVault().overview(.days30) {
                sample.generatedAt = scene.snapshotTime
                overview.show(sample)
                try? OverviewCache.appGroup()?.write(sample)
                FunesWidgets.reload()
            }
            capture.reload()
            if capture.queuedCount < ConnectionScene.waiting { _ = await capture.queueTestCaptures(ConnectionScene.waiting - capture.queuedCount) }
            return
        }
        #endif
        await reload()
        // The demo has no network to watch and no extensions' queue to read.
        if isDemo {
            #if DEBUG
            if let query = ScreenshotScene.current?.searchQuery { search.query = query }
            #endif
            await refresh()
            await capture.deliver(.launch)
            #if DEBUG
            if let kind = ScreenshotScene.current?.approval, let item = approvals.items.first(where: { $0.kind == kind }) {
                open(ApprovalRef(id: item.id))
            }
            if ScreenshotScene.current?.asks == true {
                search.macAnswers = macAnswers
                await search.search()
                await search.ask()
            }
            #endif
            return
        }
        Task { [weak self] in
            for await path in NetworkPathWatcher.updates() {
                guard let self else { return }
                self.path = path
                self.tracker.handle(.path(path))
                await self.services.client?.networkChanged()
                // Start over on a usable path; the first update is the current path, which the
                // foreground refresh already covers.
                if path.isSatisfied, self.record != nil, self.lastChecked != nil {
                    await self.refresh()
                    await self.capture.deliver(.pathChange)
                }
            }
        }
        // The share extension and the App Intents queued something, or the Control asked for
        // Home's composer.
        Task { [weak self] in
            for await _ in AppSignal.queueChanged.updates() {
                guard let self else { return }
                self.capture.reload()
                await self.capture.deliver(.captured)
            }
        }
        Task { [weak self] in
            for await _ in AppSignal.openCapture.updates() { self?.takeCaptureRequest() }
        }
        takeCaptureRequest()
        await refresh()
        await capture.deliver(.launch)
    }

    /// Coming to the front: `status.get`, then the queue (companion protocol §4, §6).
    func foreground() async {
        takeCaptureRequest()
        capture.reload()
        guard started else { return }
        #if DEBUG
        if ConnectionScene.current != nil, !isDemo { return }
        #endif
        await refresh()
        await capture.deliver(.foreground)
        // Suggestions may have been answered or added on the Mac meanwhile.
        if reachability.isConnected, inbox.phase == .loaded { await inbox.load() }
        if !isDemo { notificationsAllowed = await NotificationPermission.current() }
    }

    /// `BGAppRefreshTask`: send what's waiting, then the counts for the widgets when the Mac
    /// answers (a failure keeps the cache), then ask for the next refresh, since the share
    /// extension and the Control can queue more while the app stays closed.
    func backgroundDelivery() async {
        guard !isDemo else { return }
        capture.reload()
        if capture.queuedCount > 0 { await capture.deliver(.background) }
        await overview.load()
        await capture.scheduleBackgroundDelivery()
    }

    private func takeCaptureRequest() {
        guard let mode = CaptureLaunch().take() else { return }
        captureMode = mode
        captureRequests += 1
    }

    private func delivered(_ outcome: DeliveryOutcome) {
        tracker.handle(.delivered(outcome))
        statusBar.delivered(outcome)
        leaveVaultIfGone()
        // Home's counts after captures are delivered (UX: iPhone ▸ Home tab, Data).
        if case let .drained(sent, _) = outcome, sent > 0, reachability.isConnected {
            Task { await overview.load() }
        }
    }

    /// A Search, memory or Inbox call failed: the connection's state hears about it.
    private func callFailed(_ error: CompanionClientError) {
        tracker.handle(.callFailed(error))
        leaveVaultIfGone()
    }

    /// Unpaired or removed: what Search and the Inbox read from the Mac leaves the phone, and so
    /// does the cached overview.
    private func leaveVaultIfGone() {
        switch reachability {
        case .notPaired, .revoked:
            search.clear()
            inbox.clear()
            approvals.clear()
            overview.clear()
            openApproval = nil
        default: break
        }
    }

    private func reload() async {
        guard let client = services.client else {
            // Demo mode: "connected" to the demo vault, never paired.
            record = nil
            tracker.handle(.pairing(paired: true))
            return
        }
        do {
            record = try await client.record()
        } catch {
            logger.error("Couldn't read the pairing")
            record = nil
        }
        usesSecureEnclave = await client.usesSecureEnclave()
        tracker.handle(.pairing(paired: record != nil))
        leaveVaultIfGone()
    }

    /// `status.get`, on the cached address or by selecting one.
    func refresh(fresh: Bool = false) async {
        if let demo = services.demo {
            tracker.handle(.checked(.success(demo.connection), at: Date()))
            await categories.load()
            await approvals.load()
            // The demo's counts, for its Home and widgets; deleted when the demo is left.
            await overview.load()
            return
        }
        #if DEBUG
        if ConnectionScene.current != nil { return }
        #endif
        guard let client = services.client, record != nil else {
            tracker.handle(.pairing(paired: false))
            return
        }
        // Launch and coming to the front both ask; one check at a time is enough.
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        tracker.handle(.checkStarted)
        do {
            tracker.handle(.checked(.success(try await client.status(fresh: fresh)), at: Date()))
        } catch {
            tracker.handle(.checked(.failure(error), at: Date()))
        }
        // The called name the check kept with the pairing, for while the Mac is away.
        record = (try? await client.record()) ?? record
        probes = await client.lastProbes
        leaveVaultIfGone()
        guard reachability.isConnected else { return }
        await categories.load()
        // The tag and the subscription on every foreground (cheap, not logged), then what waits:
        // for a notification that never came or was dismissed.
        await approvalSettings.load()
        await approvals.load()
        // The counts for Home and the widgets, kept in the App Group's cache.
        await overview.load()
    }

    /// Pairs with the scanned Mac. Returns how long it took, Allow click included (Spike 1a).
    func pair(_ payload: PairingQRPayload, deviceName: String) async throws(CompanionClientError) -> Duration {
        guard let client = services.client else { throw .notPaired }
        let start = ContinuousClock.now
        record = try await client.pair(payload, deviceName: deviceName, model: DeviceInfo.model)
        tracker.handle(.pairing(paired: true))
        let elapsed = ContinuousClock.now - start
        usesSecureEnclave = await client.usesSecureEnclave()
        protocolChecks = []
        spikeMessage = nil
        testCaptureID = nil
        // Perhaps another Mac: nothing read from the last one stays.
        search.clear()
        inbox.clear()
        approvals.clear()
        await refresh()
        await categories.load(force: true)
        // Captures made before pairing, or kept from a revoked pairing, go now.
        await capture.deliver(.manual)
        return elapsed
    }

    /// Unpair on the phone (§8): tells the Mac if it can, then forgets the keys and the pairing,
    /// and the queued captures if the user said so.
    func unpair(deletingQueue: Bool) async {
        guard let client = services.client else { return }
        do { try await client.unpair() } catch { logger.error("Couldn't delete the pairing") }
        // No ring for this iPhone any more.
        await approvalSettings.clear()
        if deletingQueue { capture.deleteAll() }
        await reload()
        protocolChecks = []
        spikeMessage = nil
    }

    // MARK: Spike 1 (Debug builds)

    func runProtocolChecks() async {
        guard let client = services.client else { return }
        do { protocolChecks = try await client.protocolChecks() } catch {
            protocolChecks = []
            spikeMessage = Self.message(for: error)
        }
    }

    /// Sends a capture to the Mac (rows 1b and 1c); `again` resends the last one with the same id,
    /// which the Mac accepts as a duplicate without storing it twice.
    func sendTestCapture(again: Bool) async {
        guard let client = services.client else { return }
        let id = again ? (testCaptureID ?? UUID()) : UUID()
        testCaptureID = id
        let capture = CompanionCapture(captureId: id, text: "Spike 1 test capture \(id.uuidString.prefix(8))", createdAt: Date(),
                                       source: .typed)
        let start = ContinuousClock.now
        do {
            let result = try await client.call(CapturesSubmit.self, CapturesSubmitParams(captures: [capture]))
            let ms = (ContinuousClock.now - start).milliseconds
            spikeMessage = result.accepted.contains(id)
                ? String(localized: "Accepted \(String(id.uuidString.prefix(8))) in \(ms) ms")
                : String(localized: "Rejected: \(result.rejected.first?.reason.rawValue ?? "?")")
        } catch {
            spikeMessage = Self.message(for: error)
        }
    }

    #if DEBUG
    /// Queues `count` test captures, then sends them and times it (row 1h, "queue of 1,000").
    func queueAndDrain(_ count: Int) async {
        spikeMessage = String(localized: "Queuing \(count)…")
        let added = await capture.queueTestCaptures(count)
        let start = ContinuousClock.now
        await capture.deliver(.manual)
        let seconds = Double((ContinuousClock.now - start).milliseconds) / 1000
        switch capture.lastOutcome {
        case let .drained(sent, rejected)?:
            spikeMessage = String(localized: "Queued \(added); sent \(sent) in \(seconds.formatted(.number.precision(.fractionLength(1)))) s, \(rejected) not accepted, \(capture.queuedCount) left.")
        case let .failed(error, _, sent)?:
            spikeMessage = String(localized: "Queued \(added); sent \(sent), then: \(Self.message(for: error)) \(capture.queuedCount) left.")
        default:
            spikeMessage = String(localized: "Queued \(added); \(capture.queuedCount) waiting.")
        }
    }
    #endif

    // MARK: Messages

    static func message(for error: CompanionClientError) -> String {
        switch error {
        case .notPaired:
            String(localized: "This iPhone isn't paired with a Mac.")
        case .unreachable(localNetworkDenied: true):
            String(localized: "Funes isn't allowed on your local network. Turn it on in Settings ▸ Privacy & Security ▸ Local Network, then try again.")
        case .unreachable:
            String(localized: "Couldn't reach your Mac. Make sure both are on the same Wi-Fi, or set up Tailscale on both.")
        case .qrExpired, .pairing(.expired):
            String(localized: "This code has expired. Show a new one on your Mac.")
        case .pairing(.denied):
            String(localized: "Pairing was declined on your Mac.")
        case .pairing(.tooManyAttempts):
            String(localized: "Too many tries with this code. Show a new one on your Mac.")
        case .pairing(.tooManyDevices):
            String(localized: "Five iPhones are already paired with this Mac. Remove one in Funes Settings ▸ iPhone.")
        case .pairing:
            String(localized: "This code didn't match your Mac. Show a new one and scan again.")
        case .refused(.revoked), .refused(.unknownDevice):
            String(localized: "This iPhone was removed from Funes on your Mac.")
        case let .refused(refusal):
            String(localized: "Your Mac refused the request (\(refusal.code)).")
        case let .method(error):
            String(localized: "Your Mac couldn't do that (\(error.code.rawValue)).")
        case let .badResponse(status):
            String(localized: "Something else answered at your Mac's address (HTTP \(status)).")
        case .local:
            String(localized: "Something went wrong on this iPhone. Try again.")
        case .answerTimedOut:
            String(localized: "Took too long. Try again.")
        }
    }
}

extension PhoneModel {
    /// A Search, memory or Inbox call's failure, in the words of the screen it happened on.
    static func vaultMessage(for error: CompanionClientError) -> String {
        guard case let .method(failure) = error else { return message(for: error) }
        switch failure.code {
        case .secretLikeContent:
            if let first = failure.findings?.first {
                return String(localized: "This looks like \(CaptureModel.name(first)). Funes doesn't save text that looks like a password, key or card number.")
            }
            return String(localized: "This looks like a password or key. Funes doesn't save text that looks like a password, key or card number.")
        case .invalidInput:
            return String(localized: "Your Mac didn't accept this. Check the title, the text and the categories.")
        case .notFound:
            return String(localized: "This is no longer on your Mac.")
        case .conflict:
            return String(localized: "This changed on your Mac.")
        case .rateLimited:
            return String(localized: "Your Mac is busy. Try again in a moment.")
        case .unavailable:
            return String(localized: "Your vault isn't available on your Mac right now. Try again in a moment.")
        case .unknownMethod:
            return String(localized: "Your Mac's Funes Vault is too old for this. Update it on the Mac.")
        case .internalError:
            return String(localized: "Something went wrong on your Mac. Try again.")
        // Only `approvals.*` sends these; the approval screens (task 5.6) word them themselves.
        case .alreadyAnswered:
            return String(localized: "This was already answered.")
        case .requestExpired:
            return String(localized: "This request expired.")
        case .requestChanged:
            return String(localized: "This changed on your Mac.")
        case .targetChanged:
            return String(localized: "The memory it changes was edited on your Mac since this was suggested. Review it on your Mac.")
        case .unsupportedAction:
            return String(localized: "Review this on your Mac.")
        case .processing:
            return String(localized: "Still processing on your Mac. It can be saved once it's done.")
        // Only `memories.answer` sends these; Search's answer card words them (`AnswerWording`).
        case .answersOff:
            return String(localized: "Search answers are off on your Mac.")
        case .capReached, .modelUnavailable, .modelTimeout, .askRequired:
            return String(localized: "Your Mac's model couldn't answer. Try again.")
        }
    }
}

/// An open approval panel, presented as a sheet.
struct OpenApproval: Identifiable {
    let id = UUID()
    let panel: ApprovalPanelModel
}

extension Duration {
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}
