import Foundation
import FunesCore
import FunesProtocol
import Synchronization
import Testing
@testable import FunesCompanion

/// What the doorbell adapter is given, so a test can read every byte that would go to iCloud.
final class RecordingDoorbell: DoorbellChannel {
    private let state = Mutex<(rung: [DoorbellRing], removed: [String], cleared: [[String]])>(([], [], []))

    var rung: [DoorbellRing] { state.withLock { $0.rung } }
    var removed: [String] { state.withLock { $0.removed } }
    var cleared: [[String]] { state.withLock { $0.cleared } }
    /// Rung and not removed: what would still sit in the private database.
    var live: Set<String> { Set(rung.map(\.recordName)).subtracting(removed) }

    func availability() async -> DoorbellAvailability { .available }
    func ring(_ rings: [DoorbellRing]) async throws { state.withLock { $0.rung += rings } }
    func remove(recordNames: [String]) async throws { state.withLock { $0.removed += recordNames } }
    func removeAll(tags: [String]) async throws { state.withLock { $0.cleared.append(tags) } }
}

/// Approvals from the iPhone (task 5.6, FR-iOS-12, ADR-0019), against the real router and vault.
@Suite struct ApprovalsTests {
    static let task = "What coffee does Maya like in the morning?"
    static let title = "Coffee order"
    static let body = "Oat flat white, extra hot, no sugar"
    static let agentName = "Claude Code"

    /// A paired phone with approvals on and its tag fetched, ringing on.
    func ready(_ h: CompanionHarness) async throws -> (CompanionHarness.Phone, ApprovalSettings) {
        let phone = try await h.pairedPhone()
        let settings = try await h.result(ApprovalsSettingsGet.self, EmptyParams(), phone: phone)
        await h.approvals.setRinging(true)
        return (phone, settings)
    }

    /// A Share request waiting for the user, with its panel shown on the Mac.
    func shareRequest(_ h: CompanionHarness, memories: Int = 1) async throws -> (UUID, [UUID]) {
        let existing = try await h.services.agents.agents().first { $0.name == Self.agentName }
        var agent: Agent
        if let existing { agent = existing } else {
            agent = try await h.services.agents.create(
                name: Self.agentName, kind: .claudeCode, access: Access(operations: [.read], maxSensitivity: .internal),
                now: h.clock.now).0
        }
        var ids: [UUID] = []
        for n in 0..<memories {
            ids.append(try h.store.createMemory(MemoryDraft(title: Self.title + (n == 0 ? "" : " \(n)"), body: Self.body + " coffee",
                                                            categoryKeys: ["personal_preferences"]), now: h.clock.now).id)
        }
        let outcome = try await h.disclosures.request(agentID: agent.id, MemoryRequest(task: Self.task), now: h.clock.now)
        #expect(outcome.status == .needsApproval)
        let id = try #require(outcome.requestID)
        await h.approvals.waiting(.share(id), now: h.clock.now)
        return (id, ids)
    }

    func code<Call: CompanionCall>(_ call: Call.Type, _ params: Call.Params, _ h: CompanionHarness,
                                   phone: CompanionHarness.Phone) async throws -> CompanionErrorCode? {
        do {
            _ = try await h.result(call, params, phone: phone)
            return nil
        } catch let error as CompanionError {
            return error.code
        }
    }

    // MARK: The doorbell

    @Test func theDoorbellCarriesNoText() async throws {
        let h = try CompanionHarness()
        let (phone, settings) = try await ready(h)
        let (id, memories) = try await shareRequest(h)
        let rings = h.doorbell.rung
        #expect(rings.count == 1)
        let ring = try #require(rings.first)
        // Only a tag and a random name: no field holds anything else.
        #expect(Mirror(reflecting: ring).children.compactMap(\.label).sorted() == ["recordName", "tag"])
        #expect(ring.tag == settings.tag)
        #expect(ring.recordName.count == Doorbell.recordNameLength && ring.recordName.allSatisfy { "0123456789abcdef".contains($0) })
        let forbidden = [Self.task, Self.title, Self.body, Self.agentName, "coffee", "Coffee", "Claude",
                         id.uuidString, id.uuidString.lowercased(), memories[0].uuidString.lowercased(),
                         phone.deviceID!.uuidString.lowercased()]
        for field in [ring.recordName, ring.tag] {
            for text in forbidden { #expect(!field.contains(text)) }
        }
        // The ring's name is enough for the phone to fetch the panel over the companion channel.
        let detail = try await h.result(ApprovalsGet.self, ApprovalRef(ring: ring.recordName), phone: phone)
        #expect(detail.id == id && detail.kind == .share && detail.task == Self.task)
        #expect(detail.share?.rows.map(\.body) == [Self.body + " coffee"])
    }

    @Test func eachRequestRingsOncePerDeviceWithApprovalsOn() async throws {
        let h = try CompanionHarness()
        let (_, _) = try await ready(h)
        let second = try await h.pairedPhone()
        _ = try await h.result(ApprovalsSettingsGet.self, EmptyParams(), phone: second)
        // A third has approvals turned off; a fourth never fetched its tag (no subscription).
        let third = try await h.pairedPhone()
        _ = try await h.result(ApprovalsSettingsSet.self, ApprovalSettingsChange(enabled: false), phone: third)
        _ = try await h.pairedPhone()
        let (id, _) = try await shareRequest(h)
        await h.approvals.waiting(.share(id), now: h.clock.now)
        let tags = Set(try await h.services.devices.devices().filter(\.rings).compactMap(\.doorbellTag))
        #expect(h.doorbell.rung.count == 2 && Set(h.doorbell.rung.map(\.tag)) == tags)
        #expect(Set(h.doorbell.rung.map(\.recordName)).count == 2)
    }

    @Test func noRingsWhileIPhoneAccessIsOffAndOffTakesThemBack() async throws {
        let h = try CompanionHarness()
        let (phone, _) = try await ready(h)
        await h.approvals.setRinging(false)
        _ = try await shareRequest(h)
        #expect(h.doorbell.rung.isEmpty)
        await h.approvals.setRinging(true)
        _ = try await shareRequest(h)
        #expect(h.doorbell.live.count == 1)
        await h.approvals.setRinging(false)
        #expect(h.doorbell.live.isEmpty)
        // The phone can still see what waits when it opens the app.
        #expect(try await h.result(ApprovalsList.self, EmptyParams(), phone: phone).items.count == 2)
    }

    @Test func ringsGoWhenTheRequestStopsWaiting() async throws {
        let h = try CompanionHarness()
        let (phone, _) = try await ready(h)
        // Answered on the Mac.
        let (first, memories) = try await shareRequest(h)
        let panel = try #require(try await h.disclosures.panel(requestID: first, now: h.clock.now))
        try await h.disclosures.approve(requestID: first, snapshotRevision: panel.snapshotRevision, memoryIDs: memories, now: h.clock.now)
        await h.approvals.ended(.share(first), answered: true, now: h.clock.now)
        #expect(h.doorbell.live.isEmpty)
        // Expired: the minute job's sweep.
        _ = try await shareRequest(h)
        #expect(h.doorbell.live.count == 1)
        h.clock.advance(DisclosureService.window + 1)
        await h.approvals.sweep(now: h.clock.now)
        #expect(h.doorbell.live.isEmpty)
        // At launch, whatever a previous run left is deleted by tag.
        await h.approvals.launch()
        #expect(h.doorbell.cleared == [[try #require(try await h.services.devices.device(id: phone.deviceID!)?.doorbellTag)]])
        // Turning approvals off on the Mac takes the device's rings back too.
        h.clock.advance(1)
        _ = try await shareRequest(h)
        #expect(h.doorbell.live.count == 1)
        try await h.approvals.setApprovals(deviceID: phone.deviceID!, enabled: false, now: h.clock.now)
        #expect(h.doorbell.live.isEmpty)
    }

    // MARK: Answers

    @Test func aPhoneAnswerAndAMacAnswerRacing() async throws {
        for round in 0..<12 {
            let h = try CompanionHarness()
            let (phone, _) = try await ready(h)
            let (id, memories) = try await shareRequest(h)
            let detail = try await h.result(ApprovalsGet.self, ApprovalRef(id: id), phone: phone)
            let macDenies = round.isMultiple(of: 2)
            async let fromPhone = code(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: detail.revision, choice: .share,
                                                                                   memoryIds: memories), h, phone: phone)
            async let fromMac: Bool = {
                do {
                    if macDenies {
                        try await h.disclosures.deny(requestID: id, now: h.clock.now, waitingOnly: true)
                    } else {
                        try await h.disclosures.approve(requestID: id, snapshotRevision: detail.revision, memoryIDs: memories,
                                                        now: h.clock.now)
                    }
                    return true
                } catch VaultError.invalidState {
                    return false
                }
            }()
            let (phoneCode, macWon) = try await (fromPhone, fromMac)
            // Exactly one answer counts; the other is told it was already answered.
            #expect((phoneCode == nil) != macWon)
            if macWon { #expect(phoneCode == .alreadyAnswered) }
            let d = try #require(try await h.disclosures.disclosure(requestID: id))
            #expect(d.status == (macWon && macDenies ? .denied : .approved))
            let decided = h.activity.events.filter { $0.event == "approval" }
            #expect(decided.count == 1 && decided[0].actor == (macWon ? "user" : "device:\(phone.deviceID!.db)"))
            // Whoever lost sees it as answered from then on.
            #expect(try await code(ApprovalsGet.self, ApprovalRef(id: id), h, phone: phone) == .alreadyAnswered)
        }
    }

    @Test func aPhoneWinWithdrawsTheMacsPanel() async throws {
        let h = try CompanionHarness()
        let (phone, _) = try await ready(h)
        let withdrawn = Mutex<[(CompanionApprovals.Key, String)]>([])
        await h.approvals.onPhoneAnswered { key, name in withdrawn.withLock { $0.append((key, name)) } }
        let (id, memories) = try await shareRequest(h)
        let detail = try await h.result(ApprovalsGet.self, ApprovalRef(id: id), phone: phone)
        let answered = try await h.result(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: detail.revision, choice: .share,
                                                                                    memoryIds: memories), phone: phone)
        #expect(answered.choice == .share)
        #expect(withdrawn.withLock { $0.map(\.0) } == [.share(id)] && withdrawn.withLock { $0.first?.1 } == "Sam's iPhone")
        #expect(h.doorbell.live.isEmpty)
        // The agent waiting in its call is woken and gets the memories.
        #expect(await h.disclosures.waitForDecision(requestID: id, timeout: .seconds(1)) == .approved)
        // The same answer again is refused: single use.
        #expect(try await code(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: detail.revision, choice: .share,
                                                                           memoryIds: memories), h, phone: phone) == .alreadyAnswered)
    }

    @Test func aStaleSnapshotRevisionIsRefused() async throws {
        let h = try CompanionHarness()
        let (phone, _) = try await ready(h)
        let (id, memories) = try await shareRequest(h)
        let shown = try await h.result(ApprovalsGet.self, ApprovalRef(id: id), phone: phone)
        // The memory changes on the Mac while the phone shows the panel.
        try h.store.updateMemory(id: memories[0], MemoryEdit(body: "Black coffee now"), now: h.clock.now)
        for choice in [ApprovalChoice.share, .deny] {
            let params = ApprovalAnswerParams(id: id, revision: shown.revision, choice: choice,
                                              memoryIds: choice == .share ? memories : nil)
            #expect(try await code(ApprovalsAnswer.self, params, h, phone: phone) == .requestChanged)
        }
        #expect(try await h.disclosures.disclosure(requestID: id)?.status == .needsApproval)
        // Fetching again shows the new text with a new revision, which works.
        let fresh = try await h.result(ApprovalsGet.self, ApprovalRef(id: id), phone: phone)
        #expect(fresh.revision != shown.revision && fresh.share?.rows.first?.body == "Black coffee now")
        _ = try await h.result(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: fresh.revision, choice: .share,
                                                                         memoryIds: memories), phone: phone)
        #expect(try await h.disclosures.disclosure(requestID: id)?.status == .approved)
    }

    @Test func anExpiredRequestIsRefused() async throws {
        let h = try CompanionHarness()
        let (phone, _) = try await ready(h)
        let (id, memories) = try await shareRequest(h)
        let shown = try await h.result(ApprovalsGet.self, ApprovalRef(id: id), phone: phone)
        let ring = try #require(h.doorbell.rung.first)
        h.clock.advance(DisclosureService.window + 1)
        let params = ApprovalAnswerParams(id: id, revision: shown.revision, choice: .share, memoryIds: memories)
        #expect(try await code(ApprovalsAnswer.self, params, h, phone: phone) == .requestExpired)
        #expect(try await code(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: shown.revision, choice: .deny), h,
                               phone: phone) == .requestExpired)
        // A late notification still learns why.
        #expect(try await code(ApprovalsGet.self, ApprovalRef(ring: ring.recordName), h, phone: phone) == .requestExpired)
        #expect(try await h.result(ApprovalsList.self, EmptyParams(), phone: phone).items.isEmpty)
        let d = try #require(try await h.disclosures.disclosure(requestID: id))
        #expect(d.status != .approved && h.activity.events.filter { $0.event == "approval" && $0.outcome == "approved" }.isEmpty)
    }

    @Test func aRevokedDevicesAnswerIsRefused() async throws {
        let h = try CompanionHarness()
        let (phone, _) = try await ready(h)
        let (id, memories) = try await shareRequest(h)
        let shown = try await h.result(ApprovalsGet.self, ApprovalRef(id: id), phone: phone)
        try await h.services.devices.revoke(deviceID: phone.deviceID!, now: h.clock.now)
        let (response, _) = try await h.call(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: shown.revision, choice: .share,
                                                                                       memoryIds: memories), phone: phone)
        #expect(response.status == 401 && CompanionAuthError(body: response.body) == .revoked)
        #expect(try await h.disclosures.disclosure(requestID: id)?.status == .needsApproval)
        // And the desk refuses it on its own too, should the router ever let one through.
        await #expect(throws: VaultError.unauthenticated) {
            try await h.approvals.answer(ApprovalAnswerParams(id: id, revision: shown.revision, choice: .share, memoryIds: memories),
                                         device: phone.deviceID!, now: h.clock.now)
        }
        #expect(try await h.disclosures.disclosure(requestID: id)?.status == .needsApproval)
        // Removing it on the Mac takes back its doorbell record.
        #expect(h.doorbell.live.count == 1)
        await h.approvals.forget(deviceID: phone.deviceID!)
        #expect(h.doorbell.live.isEmpty)
    }

    @Test func activityRowsAreUnderTheDevice() async throws {
        let h = try CompanionHarness()
        let (phone, _) = try await ready(h)
        let (id, memories) = try await shareRequest(h)
        _ = try await h.result(ApprovalsList.self, EmptyParams(), phone: phone)
        let shown = try await h.result(ApprovalsGet.self, ApprovalRef(id: id), phone: phone)
        _ = try await h.result(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: shown.revision, choice: .share,
                                                                         memoryIds: memories), phone: phone)
        let device = "device:\(phone.deviceID!.db)"
        let rows = h.activity.events.filter { $0.actor == device }
        #expect(rows.map(\.event) == ["approvals_listed", "approval_viewed", "approval"])
        #expect(rows.allSatisfy { $0.via == .companion })
        #expect(rows.last?.outcome == "approved" && rows.last?.requestID == id && rows.last?.counts == ["approved": 1])
        #expect(rows[1].requestID == id)
        // Never any text in a row.
        let encoded = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
        for text in [Self.task, Self.title, Self.body] { #expect(!encoded.contains(text)) }
    }

    // MARK: Save and access panels

    @Test func aSavePanelFromThePhone() async throws {
        let h = try CompanionHarness()
        let (phone, _) = try await ready(h)
        let (agent, _) = try await h.services.agents.create(name: "Cursor", kind: .cursor,
                                                            access: Access(operations: [.suggest]), now: h.clock.now)
        let outcome = try await h.services.suggestions.suggest(
            agentID: agent.id, SuggestInput(title: "Editor", body: "Uses Vim keys", categories: ["personal_preferences"]), now: h.clock.now)
        let id = try #require(outcome.suggestionID)
        await h.approvals.waiting(.save(id), now: h.clock.now)
        #expect(h.doorbell.rung.count == 1)
        let shown = try await h.result(ApprovalsGet.self, ApprovalRef(id: id), phone: phone)
        #expect(shown.kind == .save && shown.save?.body == "Uses Vim keys" && shown.agentName == "Cursor")
        // Wrong kind of answer for this panel.
        #expect(try await code(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: shown.revision, choice: .deny), h,
                               phone: phone) == .invalidInput)
        // A revision the Mac never gave is refused.
        #expect(try await code(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: "stale", choice: .save), h,
                               phone: phone) == .requestChanged)
        let saved = try await h.result(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: shown.revision, choice: .save),
                                       phone: phone)
        let memoryID = try #require(saved.memoryId)
        let memory = try #require(try h.store.memory(id: memoryID))
        #expect(memory.body == "Uses Vim keys")
        #expect(try await code(ApprovalsAnswer.self, ApprovalAnswerParams(id: id, revision: shown.revision, choice: .discard), h,
                               phone: phone) == .alreadyAnswered)
        #expect(h.doorbell.live.isEmpty)
        #expect(h.activity.events.contains { $0.actor == "device:\(phone.deviceID!.db)" && $0.via == .companion
            && $0.ids.contains(memory.id) })
    }

    @Test func anAccessPanelFromThePhoneAndTheMacFirst() async throws {
        let h = try CompanionHarness()
        let (phone, _) = try await ready(h)
        let (agent, _) = try await h.services.agents.create(name: "Cursor", kind: .cursor, access: Access(operations: [.read]),
                                                            now: h.clock.now)
        let request = CompanionApprovals.AccessRequest(agentID: agent.id, categoryKey: "health", operation: .read, task: Self.task,
                                                       expiresAt: h.clock.now + 45, allowsOnce: true)
        // The app's panel: answered once, by whoever comes first.
        let panel = Mutex<ApprovalChoice?>(nil)
        let answer: CompanionApprovals.AccessAnswerer = { choice in
            panel.withLock { current in
                guard current == nil else { return false }
                current = choice
                return true
            }
        }
        let first = UUID()
        await h.approvals.waitingForAccess(id: first, request, now: h.clock.now, answer: answer)
        let shown = try await h.result(ApprovalsGet.self, ApprovalRef(id: first), phone: phone)
        #expect(shown.access?.categoryName == "Health" && shown.access?.allowsOnce == true && shown.task == Self.task)
        _ = try await h.result(ApprovalsAnswer.self, ApprovalAnswerParams(id: first, revision: shown.revision, choice: .allowOnce),
                               phone: phone)
        #expect(panel.withLock { $0 } == .allowOnce)
        #expect(h.activity.events.last?.event == "access_answered" && h.activity.events.last?.actor == "device:\(phone.deviceID!.db)")
        #expect(try await code(ApprovalsAnswer.self, ApprovalAnswerParams(id: first, revision: shown.revision, choice: .notNow), h,
                               phone: phone) == .alreadyAnswered)

        // The Mac answers first: the phone is told so, and nothing else happens.
        let second = UUID()
        let macPanel = Mutex(false)
        await h.approvals.waitingForAccess(id: second, request, now: h.clock.now) { _ in macPanel.withLock { !$0 } }
        let other = try await h.result(ApprovalsGet.self, ApprovalRef(id: second), phone: phone)
        macPanel.withLock { $0 = true }
        await h.approvals.ended(.access(second), answered: true, now: h.clock.now)
        #expect(try await code(ApprovalsAnswer.self, ApprovalAnswerParams(id: second, revision: other.revision, choice: .alwaysAllow), h,
                               phone: phone) == .alreadyAnswered)

        // An in-call wait that ran out.
        let third = UUID()
        await h.approvals.waitingForAccess(id: third, request, now: h.clock.now, answer: answer)
        let late = try await h.result(ApprovalsGet.self, ApprovalRef(id: third), phone: phone)
        h.clock.advance(46)
        #expect(try await code(ApprovalsAnswer.self, ApprovalAnswerParams(id: third, revision: late.revision, choice: .notNow), h,
                               phone: phone) == .requestExpired)
        #expect(h.doorbell.live.isEmpty)
    }

    // MARK: Settings

    @Test func settingsFromThePhone() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let on = try await h.result(ApprovalsSettingsGet.self, EmptyParams(), phone: phone)
        #expect(on.enabled && on.tag != nil && on.container == "iCloud.com.funesvault" && on.recordType == "Doorbell"
            && on.doorbell == .available)
        let off = try await h.result(ApprovalsSettingsSet.self, ApprovalSettingsChange(enabled: false), phone: phone)
        #expect(!off.enabled && off.tag == nil)
        let again = try await h.result(ApprovalsSettingsSet.self, ApprovalSettingsChange(enabled: true), phone: phone)
        #expect(again.enabled && again.tag != nil && again.tag != on.tag)
        #expect(h.activity.events.filter { $0.event == "device_approvals" }.map(\.actor)
            == Array(repeating: "device:\(phone.deviceID!.db)", count: 2))
    }

    @Test func unknownIdsAndRings() async throws {
        let h = try CompanionHarness()
        let (phone, _) = try await ready(h)
        #expect(try await code(ApprovalsGet.self, ApprovalRef(id: UUID()), h, phone: phone) == .notFound)
        #expect(try await code(ApprovalsGet.self, ApprovalRef(ring: String(repeating: "0", count: 32)), h, phone: phone) == .notFound)
        #expect(try await code(ApprovalsGet.self, ApprovalRef(ring: "nope"), h, phone: phone) == .invalidInput)
        // A capture's suggestion isn't an approval.
        let capture = try await h.services.captures.capture("Buy milk", origin: .captureIPhone, captureID: UUID(),
                                                            deviceID: phone.deviceID!, now: h.clock.now)
        #expect(try await code(ApprovalsGet.self, ApprovalRef(id: capture.suggestionID), h, phone: phone) == .notFound)
    }
}
