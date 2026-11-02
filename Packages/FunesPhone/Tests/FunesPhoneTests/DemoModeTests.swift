import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// Demo mode (FR-iOS-10, task 5.7): every tab against the bundled demo vault, through the same
/// models as a paired Mac, and never the network, the Keychain, CloudKit or the real queue.
@MainActor @Suite struct DemoModeTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "demo-tests-\(UUID().uuidString)")

    /// Everything the app does, in demo mode: status, categories, search, a memory's detail with
    /// edit, archive, restore and delete, the Inbox's Save and Reject, a capture through the
    /// demo's queue and delivery, each approval panel answered, and the approvals switch. The
    /// real pieces it was handed are never even built, and nothing reaches them.
    @Test func demoNeverOpensAConnectionOrTouchesThePairing() async throws {
        let live = LiveRecorder()
        let services = PhoneServices(demo: true, live: live.pieces, demoDirectory: directory)
        defer { PhoneServices.discardDemo(in: directory) }
        #expect(services.isDemo)
        #expect(services.client == nil)

        let status = try await services.caller.call(StatusGet.self, EmptyParams())
        #expect(status.inboxPending == 7)

        let categories = CategoryList(caller: services.caller)
        await categories.load()
        #expect(categories.all.count == 8)

        let search = SearchModel(caller: services.caller)
        await search.search()
        #expect(search.results.count == 24)
        search.query = "swift"
        await search.search()
        #expect(search.results.map(\.title).contains("Swift 6 with strict concurrency"))
        search.query = "trains"
        await search.search()
        let hit = try #require(search.results.first { $0.title == "Prefers trains to short flights" })

        let detail = MemoryDetailModel(id: hit.id, caller: services.caller)
        await detail.load()
        #expect(detail.phase == .loaded)
        detail.startEditing()
        detail.draft?.body = "Train first under six hours."
        #expect(await detail.save())
        #expect(detail.memory?.body == "Train first under six hours.")
        #expect(await detail.archive())
        #expect(await detail.restore())
        #expect(await detail.delete())
        #expect(detail.memory?.status == .deleted)

        let inbox = InboxModel(caller: services.caller)
        await inbox.load()
        #expect(inbox.items.count == 7)
        #expect(await inbox.save(inbox.items[0].id))
        #expect(await inbox.reject(inbox.items[0].id))
        #expect(inbox.items.count == 5)

        let queue = try #require(services.queue)
        #expect(queue.url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path)
        try queue.add("Buy tomato seeds", source: .typed)
        let delivery = CaptureDelivery(queue: queue, sender: services.sender)
        #expect(await delivery.deliver(.manual) == .drained(sent: 1, rejected: 0))
        await inbox.load()
        #expect(inbox.items.first?.sourceLabel == DemoVault.captureLabel)
        #expect(inbox.items.first?.title == "Buy tomato seeds")

        let approvals = ApprovalsModel(caller: services.caller)
        await approvals.load()
        #expect(approvals.waiting.map(\.kind) == [.share, .save, .access])
        for (item, choice) in zip(approvals.waiting, [ApprovalChoice.share, .save, .allowOnce]) {
            let panel = ApprovalPanelModel(ref: ApprovalRef(id: item.id), caller: services.caller)
            await panel.load()
            #expect(panel.phase == .ready)
            await panel.answer(choice)
            #expect(panel.phase == .closed(.answered(choice, count: choice == .share ? 3 : 0)))
        }
        await approvals.load(force: true)
        #expect(approvals.items.isEmpty)

        let settings = ApprovalSettingsModel(caller: services.caller, subscriptions: services.subscriptions)
        await settings.load()
        await settings.setEnabled(false)
        await settings.setEnabled(true)
        #expect(settings.settings?.tag == nil)
        #expect(settings.subscription == .off)

        #expect(live.log.isEmpty)
    }

    /// The recorder isn't blind: outside demo mode the same call builds the real pieces and
    /// reads the pairing from the Keychain.
    @Test func outsideDemoTheRealPiecesAreUsed() async {
        let live = LiveRecorder()
        let services = PhoneServices(demo: false, live: live.pieces, demoDirectory: directory)
        #expect(!services.isDemo)
        #expect(services.client != nil)
        await #expect(throws: CompanionClientError.notPaired) { try await services.caller.call(StatusGet.self, EmptyParams()) }
        #expect(live.log.first == "built")
        #expect(live.log.contains { $0.hasPrefix("keychain read") })
    }

    /// UX: iPhone, Demo mode: about 20 sample memories, and every screen has something to show.
    @Test func bundledDemoVaultFillsEveryScreen() async throws {
        let vault = DemoVault()
        // Home's title greets the demo person (ADR-0026); the pairing is never touched.
        #expect(try await vault.call(StatusGet.self, EmptyParams()).calledName == "Alex")
        let categories = Set(try await vault.call(CategoriesList.self, EmptyParams()).map(\.key))
        var all: [MemorySummary] = []
        for status in MemoryStatus.allCases {
            let page = try await vault.call(MemoriesSearch.self, MemorySearchParams(query: "", filters: MemorySearchFilters(status: status), limit: 50))
            #expect(!page.results.isEmpty)
            all += page.results
        }
        #expect((18...30).contains(all.count))
        #expect(all.allSatisfy { Set($0.categories).isSubset(of: categories) })

        let inbox = try await vault.call(InboxList.self, InboxListParams()).items
        #expect(inbox.count == 7)
        #expect(inbox.filter { $0.action == .update }.allSatisfy { $0.targetMemoryId != nil })
        #expect(Set(inbox.filter { $0.origin == .consolidation }.map(\.action)) == [.archive, .merge, .conflict, .split])

        let list = try await vault.call(ApprovalsList.self, EmptyParams()).items
        #expect(Set(list.map(\.kind)) == Set(ApprovalKind.allCases))
        let share = try await vault.call(ApprovalsGet.self, ApprovalRef(id: try #require(list.first { $0.kind == .share }).id))
        #expect(share.share?.rows.count == 4)
        #expect(share.share?.rows.filter(\.weak).count == 1)
        #expect(share.share?.withheld == [.aboveSensitivityCeiling: 1])
    }

    /// The demo's tidy-up cards (ADR-0031): each shows its memories and is answered as on a Mac.
    @Test func demoTidyUpCardsAnswerAsAMacWould() async throws {
        let vault = DemoVault()
        let inbox = try await vault.call(InboxList.self, InboxListParams()).items
        func card(_ action: SuggestionAction) async throws -> InboxDetail {
            let item = try #require(inbox.first { $0.origin == .consolidation && $0.action == action })
            return try await vault.call(InboxGet.self, SuggestionID(suggestionId: item.id))
        }
        let archive = try await card(.archive)
        #expect(archive.memories.map(\.role) == [.target, .survivor] && archive.tidyUp?.archiveReason == .duplicate && !archive.stale)
        let merge = try await card(.merge)
        #expect(merge.memories(.source).count == 2 && merge.tidyUp?.kept.count == 2)
        let conflict = try await card(.conflict)
        #expect(conflict.memories(.target).count == 2)
        let split = try await card(.split)
        #expect(split.memories.count == 1 && split.pieces.map(\.action) == [.create, .create])

        await #expect(throws: CompanionClientError.self) {
            try await vault.call(InboxApply.self, InboxApplyParams(suggestionId: conflict.item.id))
        }
        // A memory edited under a card makes it stale until Review Again; an archived one can't be reviewed.
        let survivor = archive.memories(.survivor)[0]
        _ = try await vault.call(MemoriesUpdate.self, MemoryUpdateParams(id: survivor.id, version: survivor.version,
                                                                         changes: MemoryChanges(body: "No meat; fish is fine.")))
        #expect(try await vault.call(InboxGet.self, SuggestionID(suggestionId: archive.item.id)).stale)
        await #expect(throws: CompanionClientError.method(CompanionError(.targetChanged))) {
            try await vault.call(InboxApply.self, InboxApplyParams(suggestionId: archive.item.id))
        }
        _ = try await vault.call(InboxReviewAgain.self, SuggestionID(suggestionId: archive.item.id))
        let reviewed = try await vault.call(InboxGet.self, SuggestionID(suggestionId: archive.item.id))
        #expect(!reviewed.stale && reviewed.revision != archive.revision)
        let mergeSource = merge.memories(.source)[0]
        _ = try await vault.call(MemoriesArchive.self, MemoryVersionRef(id: mergeSource.id, version: mergeSource.version))
        await #expect(throws: CompanionClientError.method(CompanionError(.targetChanged))) {
            try await vault.call(InboxReviewAgain.self, SuggestionID(suggestionId: merge.item.id))
        }
        _ = try await vault.call(MemoriesRestore.self, MemoryVersionRef(id: mergeSource.id, version: mergeSource.version + 1))
        _ = try await vault.call(InboxReviewAgain.self, SuggestionID(suggestionId: merge.item.id))
        await #expect(throws: CompanionClientError.self) {
            try await vault.call(InboxApply.self, InboxApplyParams(suggestionId: archive.item.id, revision: "other"))
        }
        let kept = conflict.memories(.target)[1]
        _ = try await vault.call(InboxApply.self, InboxApplyParams(suggestionId: conflict.item.id, mode: .keep, keepMemoryId: kept.id,
                                                                   revision: conflict.revision))
        let other = try await vault.call(MemoriesGet.self, MemoryID(id: conflict.memories(.target)[0].id)).memory
        #expect(other.status == .archived)
        for card in [archive, merge, split] {
            let current = try await vault.call(InboxGet.self, SuggestionID(suggestionId: card.item.id))
            _ = try await vault.call(InboxApply.self, InboxApplyParams(suggestionId: card.item.id, revision: current.revision))
        }
        let archived = try await vault.call(MemoriesSearch.self, MemorySearchParams(query: "", filters: MemorySearchFilters(status: .archived), limit: 50))
        // The copy, a merge's two sources, the split's original and the conflict's other, plus the sample one.
        #expect(archived.results.count == 6)
        #expect(try await vault.call(InboxList.self, InboxListParams()).items.allSatisfy { $0.origin != .consolidation })
    }

    /// Edits apply to the session only: a new demo starts from the bundled data, and a stale
    /// version is a conflict as on the Mac.
    @Test func editsStayInTheSession() async throws {
        let vault = DemoVault()
        let hit = try #require(try await vault.call(MemoriesSearch.self, MemorySearchParams(query: "penicillin")).results.first)
        _ = try await vault.call(MemoriesUpdate.self, MemoryUpdateParams(id: hit.id, version: 1, changes: MemoryChanges(body: "Changed")))
        await #expect(throws: CompanionClientError.method(CompanionError(.conflict))) {
            try await vault.call(MemoriesUpdate.self, MemoryUpdateParams(id: hit.id, version: 1, changes: MemoryChanges(body: "Again")))
        }
        let fresh = try await DemoVault().call(MemoriesSearch.self, MemorySearchParams(query: "penicillin")).results
        #expect(fresh.first?.snippet.hasPrefix("Penicillin allergy") == true)
    }

    /// A resent capture is accepted once, as the Mac does (§6).
    @Test func resentCaptureIsTakenOnce() async throws {
        let vault = DemoVault()
        let capture = CompanionCapture(captureId: UUID(), text: "Call the plumber\nabout the kitchen tap", createdAt: t0, source: .share)
        #expect(try await vault.submit([capture]).accepted == [capture.captureId])
        #expect(try await vault.submit([capture]).accepted == [capture.captureId])
        let items = try await vault.call(InboxList.self, InboxListParams()).items
        #expect(items.filter { $0.sourceLabel == DemoVault.captureLabel }.map(\.title) == ["Call the plumber"])
    }

    /// Demo captures are discarded on leaving, and the next demo starts with an empty queue.
    @Test func leavingTheDemoDiscardsItsCaptures() throws {
        let services = PhoneServices(demo: true, live: LiveRecorder().pieces, demoDirectory: directory)
        try services.queue?.add("Demo capture", source: .typed)
        #expect(try services.queue?.queuedCount() == 1)
        PhoneServices.discardDemo(in: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: PhoneServices.demoQueueName).path))
        let again = PhoneServices(demo: true, live: LiveRecorder().pieces, demoDirectory: directory)
        defer { PhoneServices.discardDemo(in: directory) }
        #expect(try again.queue?.queuedCount() == 0)
    }

    /// App Review may take a while: the demo's requests never run out.
    @Test func demoRequestsNeverExpire() async throws {
        let clock = TestClock()
        let vault = DemoVault(clock: { clock.now })
        clock.advance(6 * 3_600)
        let items = try await vault.call(ApprovalsList.self, EmptyParams()).items
        #expect(items.allSatisfy { $0.expiresAt > clock.now })
        let request = try await vault.call(ApprovalsGet.self, ApprovalRef(id: items[1].id))
        let answered = try await vault.call(ApprovalsAnswer.self, ApprovalAnswerParams(id: request.id, revision: request.revision, choice: .discard))
        #expect(answered.choice == .discard)
    }
}

/// The real pieces `PhoneServices` would use, each logging what's asked of it: building them at
/// all, the Keychain, a POST, a Bonjour browse, CloudKit and the App Group queue.
final class LiveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var log: [String] { lock.withLock { entries } }
    func record(_ entry: String) { lock.withLock { entries.append(entry) } }

    var pieces: PhoneServices.Live {
        record("built")
        return PhoneServices.Live(store: Store(recorder: self), transport: Transport(recorder: self), discovery: Discovery(recorder: self),
                                  subscriptions: Subscriptions(recorder: self)) { [self] () throws(CaptureQueueError) in
            record("app group queue")
            throw .storage
        }
    }

    struct Store: SecretStore {
        let recorder: LiveRecorder
        func read(_ account: String) throws(SecretStoreError) -> Data? { recorder.record("keychain read \(account)"); return nil }
        func write(_ data: Data, account: String) throws(SecretStoreError) { recorder.record("keychain write \(account)") }
        func delete(_ account: String) throws(SecretStoreError) { recorder.record("keychain delete \(account)") }
    }

    struct Transport: CompanionTransport {
        let recorder: LiveRecorder
        func post(_ url: URL, body: Data, timeout: TimeInterval) async throws(TransportError) -> TransportResponse {
            recorder.record("post \(url)")
            throw TransportError.timedOut
        }
    }

    struct Discovery: MacDiscovery {
        let recorder: LiveRecorder
        func find(tag: String, timeout: TimeInterval) async -> DiscoveryResult {
            recorder.record("bonjour \(tag)")
            return DiscoveryResult()
        }
    }

    struct Subscriptions: DoorbellSubscriptions {
        let recorder: LiveRecorder
        func accountAvailable() async -> Bool { recorder.record("cloudkit account"); return true }
        func subscriptionIDs() async throws -> [String] { recorder.record("cloudkit list"); return [] }
        func subscribe(id: String, tag: String, alertBody: String) async throws { recorder.record("cloudkit subscribe") }
        func unsubscribe(ids: [String]) async throws { recorder.record("cloudkit unsubscribe") }
    }
}
