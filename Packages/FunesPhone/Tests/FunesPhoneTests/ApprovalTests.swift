import Foundation
import FunesProtocol
import Synchronization
import Testing
@testable import FunesPhone

/// The Mac's approvals as the companion methods see them: waiting requests by id and by ring,
/// answered once, with a revision that moves when the panel changes. Failures can be queued.
final class FakeApprovals: CompanionCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var details: [UUID: ApprovalDetail] = [:]
    private var rings: [String: UUID] = [:]
    private var answered: Set<UUID> = []
    private var failures: [CompanionMethod: [CompanionClientError]] = [:]
    private var settings = ApprovalSettings(enabled: true, tag: "tag-1", doorbell: .available)
    private(set) var answers: [ApprovalAnswerParams] = []
    private(set) var calls: [CompanionMethod] = []
    /// `approvals.get` answers only after this.
    var getDelay: Duration?

    @discardableResult
    func share(rows: [ApprovalRow], agent: String = "Claude Code", ring: String? = nil) -> ApprovalDetail {
        let detail = ApprovalDetail(
            id: UUID(), kind: .share, revision: "r1", agentName: agent, agentKind: .claudeCode, task: "Plan the trip",
            createdAt: t0, expiresAt: t0.addingTimeInterval(900),
            share: SharePanel(destination: ApprovalDestination(remote: false), keywords: ["coffee"], purpose: nil, retention: .session,
                              processors: [], declaredRetention: nil, rows: rows, withheld: [.aboveSensitivityCeiling: 2]))
        lock.withLock {
            details[detail.id] = detail
            if let ring { rings[ring] = detail.id }
        }
        return detail
    }

    func add(_ detail: ApprovalDetail, ring: String? = nil) {
        lock.withLock {
            details[detail.id] = detail
            if let ring { rings[ring] = detail.id }
        }
    }

    /// A memory changed on the Mac: the panel's revision moves on, with new rows.
    func change(_ id: UUID, rows: [ApprovalRow]) {
        lock.withLock {
            details[id]?.revision += "+"
            details[id]?.share?.rows = rows
        }
    }

    func macAnswers(_ id: UUID) { _ = lock.withLock { answered.insert(id) } }
    func fail(_ method: CompanionMethod, with error: CompanionClientError) { lock.withLock { failures[method, default: []].append(error) } }
    func setApprovals(enabled: Bool, tag: String?) { lock.withLock { settings = ApprovalSettings(enabled: enabled, tag: tag, doorbell: .available) } }

    func perform<Call: CompanionCall>(_ request: PendingCall<Call>) async throws(CompanionClientError) -> Call.Result {
        if Call.method == .approvalsGet, let delay = getDelay { try? await Task.sleep(for: delay) }
        return try locked(Call.method, request.params) as! Call.Result
    }

    private func locked(_ method: CompanionMethod, _ params: Any) throws(CompanionClientError) -> Any {
        lock.lock()
        defer { lock.unlock() }
        calls.append(method)
        if var queued = failures[method], !queued.isEmpty {
            let error = queued.removeFirst()
            failures[method] = queued
            throw error
        }
        switch method {
        case .approvalsList:
            return ApprovalListResult(items: details.values.filter { !answered.contains($0.id) }.map {
                ApprovalSummary(id: $0.id, kind: $0.kind, agentName: $0.agentName, count: $0.share?.rows.count ?? 1,
                                createdAt: $0.createdAt, expiresAt: $0.expiresAt)
            })
        case .approvalsGet:
            let ref = params as! ApprovalRef
            guard let id = ref.id ?? ref.ring.flatMap({ rings[$0] }), let detail = details[id] else {
                throw .method(CompanionError(.notFound))
            }
            if answered.contains(id) { throw .method(CompanionError(.alreadyAnswered)) }
            return detail
        case .approvalsAnswer:
            let params = params as! ApprovalAnswerParams
            guard let detail = details[params.id] else { throw .method(CompanionError(.notFound)) }
            if answered.contains(params.id) { throw .method(CompanionError(.alreadyAnswered)) }
            if detail.revision != params.revision { throw .method(CompanionError(.requestChanged)) }
            answered.insert(params.id)
            answers.append(params)
            return ApprovalAnswered(choice: params.choice)
        case .approvalsSettingsGet:
            return settings
        case .approvalsSettingsSet:
            let change = params as! ApprovalSettingsChange
            settings = ApprovalSettings(enabled: change.enabled, tag: change.enabled ? "tag-2" : nil, doorbell: .available)
            return settings
        default:
            throw .method(CompanionError(.unknownMethod))
        }
    }
}

/// The CloudKit subscriptions, in memory.
final class FakeSubscriptions: DoorbellSubscriptions, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String: String] = [:]
    private(set) var log: [String] = []
    var signedIn = true
    var saveError: (any Error)?
    var deleteError: (any Error)?
    var listError: (any Error)?

    var current: [String: String] { lock.withLock { ids } }

    func accountAvailable() async -> Bool { signedIn }
    func subscriptionIDs() async throws -> [String] {
        if let listError { throw listError }
        return lock.withLock { Array(ids.keys) }
    }
    func subscribe(id: String, tag: String, alertBody: String) async throws {
        if let saveError { throw saveError }
        lock.withLock {
            ids[id] = tag
            log.append("+\(id)")
        }
    }
    func unsubscribe(ids remove: [String]) async throws {
        if let deleteError { throw deleteError }
        lock.withLock {
            remove.forEach { ids[$0] = nil }
            log += remove.map { "-\($0)" }
        }
    }
}

func row(_ title: String, weak: Bool = false, sensitivity: Sensitivity = .low) -> ApprovalRow {
    ApprovalRow(id: UUID(), title: title, body: "The text of \(title)", version: 1, kind: .preference, categories: ["work"],
                sensitivity: sensitivity, weak: weak)
}

let ring = String(repeating: "ab", count: 16)

// MARK: - The notification

@Suite struct ApprovalAlertTests {
    @Test func wordsAFetchedShareRequestWithoutAnyMemoryText() async {
        let mac = FakeApprovals()
        let detail = mac.share(rows: [row("Coffee order"), row("Gym days"), row("Trip", weak: true)], ring: ring)
        let outcome = await ApprovalAlert.fetch(ring: ring, caller: mac)
        #expect(outcome == .request(detail))
        let alert = ApprovalAlert(outcome)
        #expect(alert.title == "Claude Code wants 3 memories")
        #expect(alert.body == "Open to see exactly what would be shared.")
        #expect(alert.approvalID == detail.id && alert.kind == .share)
        #expect(alert.userInfo == [ApprovalAlert.Key.id: detail.id.uuidString, ApprovalAlert.Key.kind: "share"])
        // The lock screen gets the agent and the count only.
        for text in ["Coffee", "Gym", "Trip", "text of", "Plan the trip"] {
            #expect(!alert.title.contains(text) && !alert.body.contains(text))
        }
        #expect(mac.calls == [.approvalsGet])
    }

    @Test func wordsSaveAndAccessRequests() {
        let save = ApprovalDetail(id: UUID(), kind: .save, revision: "x", agentName: "Cursor", createdAt: t0, expiresAt: t0,
                                  save: SavePanel(action: .create, title: "Secret plan", body: "Body", kind: .fact, categories: [],
                                                  sensitivity: .low))
        #expect(ApprovalAlert(.request(save)).title == "Cursor suggests a memory")
        var correction = save
        correction.save?.targetMemoryId = UUID()
        #expect(ApprovalAlert(.request(correction)).title == "Cursor suggests a correction")
        let access = ApprovalDetail(id: UUID(), kind: .access, revision: "x", agentName: "Codex", createdAt: t0, expiresAt: t0,
                                    access: AccessPanel(operation: .read, categoryKey: "work", categoryName: "Work", allowsOnce: true,
                                                        asksBeforeSharing: true))
        #expect(ApprovalAlert(.request(access)).title == "Codex wants to read Work")
        var suggest = access
        suggest.access = AccessPanel(operation: .suggest, categoryKey: nil, categoryName: nil, allowsOnce: true, asksBeforeSharing: true)
        #expect(ApprovalAlert(.request(suggest)).title == "Codex wants to suggest memories")
        let one = ApprovalDetail(id: UUID(), kind: .share, revision: "x", agentName: "Claude", createdAt: t0, expiresAt: t0,
                                 share: SharePanel(destination: ApprovalDestination(remote: true), keywords: [], purpose: nil,
                                                   retention: .unknown, processors: [], declaredRetention: nil, rows: [row("A")],
                                                   withheld: [:]))
        #expect(ApprovalAlert(.request(one)).title == "Claude wants 1 memory")
    }

    @Test func saysMacNotReachableWhenTheFetchFails() async {
        let mac = FakeApprovals()
        mac.fail(.approvalsGet, with: .unreachable(localNetworkDenied: false))
        let outcome = await ApprovalAlert.fetch(ring: ring, caller: mac)
        #expect(outcome == .unreachable)
        let alert = ApprovalAlert(outcome)
        #expect(alert.title == "You have a request")
        #expect(alert.body.hasPrefix("Mac not reachable."))
        #expect(alert.approvalID == nil && alert.userInfo.isEmpty)
        // Also what shows if iOS ends the extension before the fetch is done.
        #expect(ApprovalAlert.fallback == alert)
    }

    @Test func givesUpAtTheDeadline() async {
        let mac = FakeApprovals()
        mac.share(rows: [row("A")], ring: ring)
        mac.getDelay = .seconds(5)
        let start = ContinuousClock.now
        let outcome = await ApprovalAlert.fetch(ring: ring, caller: mac, timeout: .milliseconds(100))
        #expect(outcome == .unreachable)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func eachFetchFailure() async {
        let cases: [(CompanionClientError, ApprovalAlert.Outcome, String)] = [
            (.method(CompanionError(.alreadyAnswered)), .answered, "Answered on your Mac"),
            (.method(CompanionError(.requestExpired)), .expired, "This request expired"),
            (.method(CompanionError(.notFound)), .unknown, "You have a request"),
            (.refused(.revoked), .removed, "You have a request"),
            (.notPaired, .removed, "You have a request"),
            (.badResponse(status: 500), .unreachable, "You have a request"),
        ]
        for (error, expected, title) in cases {
            let mac = FakeApprovals()
            mac.fail(.approvalsGet, with: error)
            let outcome = await ApprovalAlert.fetch(ring: ring, caller: mac)
            #expect(outcome == expected)
            #expect(ApprovalAlert(outcome).title == title)
        }
        #expect(ApprovalAlert(.removed).body == "This iPhone was removed from Funes on your Mac.")
    }

    @Test func noRingOrABadOneNeverCallsTheMac() async {
        let mac = FakeApprovals()
        #expect(await ApprovalAlert.fetch(ring: nil, caller: mac) == .unknown)
        #expect(await ApprovalAlert.fetch(ring: "not-hex", caller: mac) == .unknown)
        #expect(mac.calls.isEmpty)
    }

    @Test func aTapOpensByIdThenByRing() {
        let id = UUID()
        #expect(ApprovalAlert.ref(fromUserInfo: [ApprovalAlert.Key.id: id.uuidString, ApprovalAlert.Key.ring: ring]) == ApprovalRef(id: id))
        #expect(ApprovalAlert.ref(fromUserInfo: [ApprovalAlert.Key.ring: ring]) == ApprovalRef(ring: ring))
        #expect(ApprovalAlert.ref(fromUserInfo: [ApprovalAlert.Key.ring: "zz"]) == nil)
        #expect(ApprovalAlert.ref(fromUserInfo: ["aps": ["alert": "x"]]) == nil)
    }
}

// MARK: - The panels

@MainActor @Suite struct ApprovalPanelTests {
    @Test func strongRowsStartTickedAndWeakOnesDont() async {
        let mac = FakeApprovals()
        let strong = [row("Coffee"), row("Health", sensitivity: .sensitive)]
        let weak = row("Trip", weak: true)
        let detail = mac.share(rows: [strong[0], weak, strong[1]])
        let panel = ApprovalPanelModel(ref: ApprovalRef(id: detail.id), caller: mac)
        await panel.load()
        #expect(panel.phase == .ready)
        #expect(panel.strongRows.map(\.title) == ["Coffee", "Health"] && panel.weakRows.map(\.title) == ["Trip"])
        #expect(panel.selected == Set(strong.map(\.id)) && panel.selectedCount == 2 && panel.canShare)

        panel.toggle(weak.id)
        panel.toggle(strong[0].id)
        #expect(panel.isSelected(weak.id) && !panel.isSelected(strong[0].id))
        panel.toggle(UUID()) // not on the panel: nothing
        #expect(panel.selectedCount == 2)

        await panel.answer(.share)
        #expect(panel.phase == .closed(.answered(.share, count: 2)))
        // In the panel's order, the ticked ones only, with the revision shown.
        #expect(mac.answers == [ApprovalAnswerParams(id: detail.id, revision: "r1", choice: .share, memoryIds: [weak.id, strong[1].id])])
        #expect(ApprovalWording.closed(.answered(.share, count: 2)) == "Shared 2 memories.")
    }

    @Test func shareNeedsATickedMemory() async {
        let mac = FakeApprovals()
        let only = row("Coffee")
        let detail = mac.share(rows: [only])
        let panel = ApprovalPanelModel(ref: ApprovalRef(id: detail.id), caller: mac)
        await panel.load()
        panel.toggle(only.id)
        #expect(!panel.canShare)
        await panel.answer(.share)
        #expect(mac.answers.isEmpty && panel.phase == .ready)
        // A choice for another kind of panel isn't sent either.
        await panel.answer(.save)
        #expect(mac.answers.isEmpty)
        await panel.answer(.deny)
        #expect(mac.answers.map(\.choice) == [.deny] && mac.answers[0].memoryIds == nil)
    }

    @Test func opensFromTheRing() async {
        let mac = FakeApprovals()
        let detail = mac.share(rows: [row("Coffee")], ring: ring)
        let panel = ApprovalPanelModel(ref: ApprovalRef(ring: ring), caller: mac)
        #expect(panel.id == nil)
        await panel.load()
        #expect(panel.id == detail.id && panel.detail == detail)
    }

    @Test func answeredOnTheMacFirst() async {
        let mac = FakeApprovals()
        let detail = mac.share(rows: [row("Coffee")])
        let panel = ApprovalPanelModel(ref: ApprovalRef(id: detail.id), caller: mac)
        var closed: [UUID] = []
        panel.onClosed = { closed.append($0) }
        await panel.load()
        mac.macAnswers(detail.id)
        await panel.answer(.share)
        #expect(panel.phase == .closed(.answeredOnMac))
        #expect(ApprovalWording.closed(.answeredOnMac) == "Answered on your Mac")
        #expect(closed == [detail.id])
        // Opened after the Mac answered: the same.
        let later = ApprovalPanelModel(ref: ApprovalRef(id: detail.id), caller: mac)
        await later.load()
        #expect(later.phase == .closed(.answeredOnMac))
    }

    @Test func expiredAndGone() async {
        let mac = FakeApprovals()
        let detail = mac.share(rows: [row("Coffee")])
        let panel = ApprovalPanelModel(ref: ApprovalRef(id: detail.id), caller: mac)
        await panel.load()
        mac.fail(.approvalsAnswer, with: .method(CompanionError(.requestExpired)))
        await panel.answer(.share)
        #expect(panel.phase == .closed(.expired))
        #expect(ApprovalWording.closed(.expired) == "This request expired")

        let missing = ApprovalPanelModel(ref: ApprovalRef(id: UUID()), caller: mac)
        await missing.load()
        #expect(missing.phase == .closed(.gone))
    }

    @Test func aChangedRequestIsFetchedAgainToReview() async {
        let mac = FakeApprovals()
        let first = row("Coffee")
        let detail = mac.share(rows: [first, row("Trip", weak: true)])
        let panel = ApprovalPanelModel(ref: ApprovalRef(id: detail.id), caller: mac)
        await panel.load()
        // A memory changes on the Mac while the phone shows the panel.
        let fresh = [row("Coffee, now black"), row("Gym")]
        mac.change(detail.id, rows: fresh)
        await panel.answer(.share)
        #expect(panel.phase == .ready && panel.changed)
        #expect(panel.detail?.revision == "r1+" && panel.strongRows.map(\.title) == ["Coffee, now black", "Gym"])
        // The new panel's defaults, not the old ticks.
        #expect(panel.selected == Set(fresh.map(\.id)))
        #expect(mac.answers.isEmpty)
        await panel.answer(.share)
        #expect(panel.phase == .closed(.answered(.share, count: 2)))
        #expect(mac.answers.first?.revision == "r1+")
    }

    @Test func macNotReachableKeepsThePanel() async {
        let mac = FakeApprovals()
        let detail = mac.share(rows: [row("Coffee")])
        let panel = ApprovalPanelModel(ref: ApprovalRef(id: detail.id), caller: mac)
        var failures: [CompanionClientError] = []
        panel.onFailure = { failures.append($0) }
        await panel.load()
        mac.fail(.approvalsAnswer, with: .unreachable(localNetworkDenied: false))
        await panel.answer(.share)
        #expect(panel.phase == .ready)
        #expect(panel.answerFailure == .call(.unreachable(localNetworkDenied: false)))
        #expect(failures == [.unreachable(localNetworkDenied: false)])
        // Not resent: the user tries again, and the Mac takes it.
        #expect(mac.answers.isEmpty)
        await panel.answer(.share)
        #expect(panel.phase == .closed(.answered(.share, count: 1)))
    }

    @Test func aLostReplyThenAlreadyAnsweredIsNotBlamedOnTheMac() async {
        let mac = FakeApprovals()
        let detail = mac.share(rows: [row("Coffee")])
        let panel = ApprovalPanelModel(ref: ApprovalRef(id: detail.id), caller: mac)
        await panel.load()
        // The Mac took the answer but the reply was lost.
        mac.macAnswers(detail.id)
        mac.fail(.approvalsAnswer, with: .unreachable(localNetworkDenied: false))
        await panel.answer(.share)
        #expect(panel.answerFailure != nil)
        await panel.load()
        #expect(panel.phase == .closed(.alreadyAnswered))
    }

    @Test func unreachableBeforeTheFirstFetch() async {
        let mac = FakeApprovals()
        mac.fail(.approvalsGet, with: .unreachable(localNetworkDenied: false))
        let panel = ApprovalPanelModel(ref: ApprovalRef(id: UUID()), caller: mac)
        await panel.load()
        #expect(panel.phase == .failed(.unreachable(localNetworkDenied: false)))
    }

    @Test func answeringNeedsThePhoneUnlocked() async {
        let mac = FakeApprovals()
        let detail = mac.share(rows: [row("Coffee")])
        var unlocked = false
        let panel = ApprovalPanelModel(ref: ApprovalRef(id: detail.id), caller: mac, isUnlocked: { unlocked })
        await panel.load()
        await panel.answer(.share)
        #expect(panel.answerFailure == .locked && panel.phase == .ready && mac.answers.isEmpty)
        unlocked = true
        await panel.answer(.share)
        #expect(panel.phase == .closed(.answered(.share, count: 1)))
    }

    @Test func accessOffersAllowOnceOnlyWhenThePanelDoes() async {
        let mac = FakeApprovals()
        let detail = ApprovalDetail(id: UUID(), kind: .access, revision: "x", agentName: "Codex", createdAt: t0,
                                    expiresAt: t0.addingTimeInterval(45),
                                    access: AccessPanel(operation: .read, categoryKey: "work", categoryName: "Work", allowsOnce: false,
                                                        asksBeforeSharing: true))
        mac.add(detail)
        let panel = ApprovalPanelModel(ref: ApprovalRef(id: detail.id), caller: mac)
        await panel.load()
        await panel.answer(.allowOnce)
        #expect(mac.answers.isEmpty)
        #expect(ApprovalWording.accessSubtitle(detail.access!) == "It already got what it may read. Always Allow is for next time.")
        #expect(ApprovalWording.alwaysAllow(agent: "Codex", operation: .read, category: "Work") == "Always Allow Codex to Read Work")
        await panel.answer(.notNow)
        #expect(mac.answers.map(\.choice) == [.notNow])
    }

    @Test func theSharePanelsWords() {
        #expect(ApprovalWording.withheld([:]) == nil)
        #expect(ApprovalWording.withheld([.aboveSensitivityCeiling: 2, .deniedCategory: 1])
            == "3 more matched but can't go to this agent (2 above its sensitivity limit, 1 in categories it can't read).")
        #expect(ApprovalWording.destination(agent: "Claude", ApprovalDestination(remote: true, vendor: "Anthropic", tunnel: "Tailscale Funnel"))
            == "Claude, through your Tailscale Funnel, to Anthropic's servers")
        #expect(ApprovalWording.destination(agent: "Cursor", ApprovalDestination(remote: false))
            == "Cursor on your Mac. It may send what it reads to its AI service.")
        #expect(ApprovalWording.retention(.persistent) == "Beyond the session")
    }
}

// MARK: - The list and the switch

@MainActor @Suite struct ApprovalSettingsTests {
    @Test func theListIsSoonestFirst() async {
        let mac = FakeApprovals()
        var late = ApprovalDetail(id: UUID(), kind: .save, revision: "x", agentName: "B", createdAt: t0, expiresAt: t0.addingTimeInterval(1800))
        late.save = SavePanel(action: .create, title: "T", body: "B", kind: nil, categories: [], sensitivity: nil)
        mac.add(late)
        let soon = mac.share(rows: [row("A")])
        let list = ApprovalsModel(caller: mac, clock: { t0 })
        await list.load()
        #expect(list.items.map(\.id) == [soon.id, late.id] && list.phase == .loaded)
        #expect(ApprovalWording.title(list.items[0]) == "Claude Code wants 1 memory")
        list.remove(soon.id)
        #expect(list.items.map(\.id) == [late.id])
        #expect(ApprovalWording.title(list.items[0]) == "B suggests a memory")
    }

    @Test func subscribesOnlyOnceTheMacGaveATag() async {
        let mac = FakeApprovals()
        let cloud = FakeSubscriptions()
        let model = ApprovalSettingsModel(caller: mac, subscriptions: cloud)
        // Nothing from the Mac yet: nothing to subscribe to.
        await model.sync()
        #expect(cloud.log.isEmpty && model.subscription == .unknown)

        mac.setApprovals(enabled: true, tag: nil)
        await model.load()
        #expect(cloud.log.isEmpty && model.subscription == .off)

        mac.setApprovals(enabled: true, tag: "tag-1")
        var asked = 0
        model.onSubscribed = { asked += 1 }
        await model.load()
        #expect(cloud.current == ["doorbell-tag-1": "tag-1"] && model.subscription == .subscribed && asked == 1)
        // Every foreground checks; an existing subscription isn't saved again.
        await model.load()
        #expect(cloud.log == ["+doorbell-tag-1"])
    }

    @Test func theSwitchMovesTheSubscription() async {
        let mac = FakeApprovals()
        let cloud = FakeSubscriptions()
        let model = ApprovalSettingsModel(caller: mac, subscriptions: cloud)
        await model.load()
        await model.setEnabled(false)
        #expect(model.settings?.enabled == false && cloud.current.isEmpty && model.subscription == .off)
        // On again: a new tag, so the old subscription would have gone quiet anyway.
        await model.setEnabled(true)
        #expect(cloud.current == ["doorbell-tag-2": "tag-2"])
        #expect(cloud.log == ["+doorbell-tag-1", "-doorbell-tag-1", "+doorbell-tag-2"])
        #expect(mac.calls.filter { $0 == .approvalsSettingsSet }.count == 2)
    }

    @Test func aStaleTagsSubscriptionGoesAndOthersStay() {
        let settings = ApprovalSettings(enabled: true, tag: "new", doorbell: .available)
        let plan = DoorbellSubscriptionPlan(settings: settings, existing: ["doorbell-old", "something-else"])
        #expect(plan.subscribeTag == "new" && plan.unsubscribe == ["doorbell-old"])
        let off = DoorbellSubscriptionPlan(settings: ApprovalSettings(enabled: false, tag: nil, doorbell: .available),
                                           existing: ["doorbell-new"])
        #expect(off.subscribeTag == nil && off.unsubscribe == ["doorbell-new"])
        #expect(DoorbellSubscriptionPlan(settings: settings, existing: ["doorbell-new"]).isEmpty)
    }

    @Test func withoutICloudOnThePhone() async {
        let mac = FakeApprovals()
        let cloud = FakeSubscriptions()
        cloud.signedIn = false
        let model = ApprovalSettingsModel(caller: mac, subscriptions: cloud)
        await model.load()
        #expect(model.subscription == .noICloud && cloud.log.isEmpty)
    }

    @Test func cloudKitRefusingTheSubscriptionSaysWhy() async {
        let mac = FakeApprovals()
        let cloud = FakeSubscriptions()
        cloud.saveError = CocoaError(.fileWriteNoPermission)
        let model = ApprovalSettingsModel(caller: mac, subscriptions: cloud)
        await model.load()
        #expect(model.subscription == .failed && model.subscriptionError?.isEmpty == false)
        cloud.saveError = nil
        await model.load()
        #expect(model.subscription == .subscribed && model.subscriptionError == nil)
    }

    @Test func anOldSubscriptionCloudKitWontDeleteDoesntBlockTheNewOne() async {
        let mac = FakeApprovals()
        let cloud = FakeSubscriptions()
        try? await cloud.subscribe(id: "doorbell-spike", tag: "spike", alertBody: "x")
        cloud.deleteError = CocoaError(.fileNoSuchFile)
        let model = ApprovalSettingsModel(caller: mac, subscriptions: cloud)
        await model.load()
        #expect(model.subscription == .subscribed && cloud.current["doorbell-tag-1"] == "tag-1")
        // Said in Debug builds, but not a failure: the old tag is never rung again.
        #expect(model.subscriptionError != nil)
    }

    @Test func aListingCloudKitCantAnswerStillSubscribes() async {
        let mac = FakeApprovals()
        let cloud = FakeSubscriptions()
        cloud.listError = CocoaError(.fileReadCorruptFile)
        let model = ApprovalSettingsModel(caller: mac, subscriptions: cloud)
        await model.load()
        #expect(model.subscription == .subscribed && cloud.current == ["doorbell-tag-1": "tag-1"])
        #expect(model.subscriptionError != nil)
    }

    @Test func theListIsntReadAgainRightAway() async {
        let mac = FakeApprovals()
        mac.share(rows: [row("A")])
        let now = Mutex(t0)
        let list = ApprovalsModel(caller: mac, clock: { now.withLock { $0 } })
        await list.load()
        await list.load()
        #expect(mac.calls == [.approvalsList])
        // A ring says something changed.
        await list.load(force: true)
        now.withLock { $0 = t0.addingTimeInterval(ApprovalsModel.freshFor + 1) }
        await list.load()
        #expect(mac.calls == [.approvalsList, .approvalsList, .approvalsList])
    }

    @Test func overlappingChecksSubscribeOnce() async {
        let mac = FakeApprovals()
        let cloud = FakeSubscriptions()
        let model = ApprovalSettingsModel(caller: mac, subscriptions: cloud)
        let list = ApprovalsModel(caller: mac)
        async let a: Void = model.load()
        async let b: Void = model.load()
        async let c: Void = list.load()
        async let d: Void = list.load()
        _ = await (a, b, c, d)
        #expect(cloud.log == ["+doorbell-tag-1"])
        #expect(mac.calls.filter { $0 == .approvalsList }.count <= 2)
    }

    @Test func aFailedSwitchKeepsTheSettings() async {
        let mac = FakeApprovals()
        let model = ApprovalSettingsModel(caller: mac, subscriptions: FakeSubscriptions())
        await model.load()
        mac.fail(.approvalsSettingsSet, with: .unreachable(localNetworkDenied: false))
        await model.setEnabled(false)
        #expect(model.settings?.enabled == true && model.failure == .unreachable(localNetworkDenied: false))
    }

    @Test func unpairingUnsubscribes() async {
        let mac = FakeApprovals()
        let cloud = FakeSubscriptions()
        let model = ApprovalSettingsModel(caller: mac, subscriptions: cloud)
        await model.load()
        await model.clear()
        #expect(cloud.current.isEmpty && model.settings == nil)
    }
}
