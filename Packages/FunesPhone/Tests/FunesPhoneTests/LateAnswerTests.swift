import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// Answers that arrive after the phone moved on: unpaired, paired again, answered, or asked again.
@MainActor @Suite struct LateAnswerTests {
    /// A status check that comes back after unpairing doesn't show the Mac as connected.
    @Test func aLateCheckAfterUnpairingChangesNothing() {
        var tracker = ReachabilityTracker()
        tracker.handle(.pairing(paired: true))
        tracker.handle(.checkStarted)
        tracker.handle(.pairing(paired: false))
        tracker.handle(.checked(.success(ReachabilityTests.connection()), at: t0))
        #expect(tracker.state == .notPaired)
        tracker.handle(.checked(.failure(ReachabilityTests.unreachable), at: t0))
        #expect(tracker.state == .notPaired && tracker.lastChecked == nil)
        // Paired again, the next check counts.
        tracker.handle(.pairing(paired: true))
        tracker.handle(.checked(.success(ReachabilityTests.connection()), at: t0))
        #expect(tracker.state.isConnected)
    }

    /// An overview on its way when the counts left the phone is neither shown nor cached.
    @Test func aLateOverviewIsNotCached() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "late-overview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = OverviewCache(url: directory.appending(path: OverviewCache.fileName))
        let gate = Gate()
        let vault = DemoVault(content: nil, calendar: OverviewCacheTests.calendar, clock: { t0 })
        let model = OverviewModel(caller: GatedCaller(inner: vault, method: .overviewGet, gate: gate), cache: cache)
        let loading = Task { await model.load() }
        await gate.arrived()
        model.clear()
        gate.open()
        await loading.value
        #expect(model.overview(.days30) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))
        // The next one is kept.
        await model.load()
        #expect(model.overview(.days30) != nil && cache.read()[.days30] != nil)
    }

    /// Reload after a conflict that can't reach the Mac keeps the edit and the question.
    @Test func aFailedReloadKeepsTheDraft() async throws {
        let vault = FakeVault()
        let original = vault.add("Seat", body: "Prefers aisle seats")
        let detail = MemoryDetailModel(id: original.id, caller: vault)
        await detail.load()
        detail.startEditing()
        detail.draft?.body = "Prefers window seats"
        vault.macEdit(original.id, body: "Prefers aisle seats, front of the plane")
        #expect(await detail.save() == false)
        #expect(detail.conflict)

        vault.fail(.memoriesGet, with: .unreachable(localNetworkDenied: false))
        await detail.reload()
        #expect(detail.draft?.body == "Prefers window seats")
        #expect(detail.conflict)

        await detail.reload()
        #expect(!detail.conflict)
        #expect(detail.draft?.body == "Prefers aisle seats, front of the plane")
    }

    /// A list the Mac sent before an answer reached it doesn't bring the answered row back.
    @Test func aStaleListDoesNotBringAnAnsweredRowBack() async throws {
        let vault = FakeVault()
        let seat = vault.suggest("Seat")
        let coffee = vault.suggest("Coffee")
        let gate = Gate()
        let inbox = InboxModel(caller: GatedCaller(inner: vault, method: .inboxList, gate: gate))
        gate.open()
        await inbox.load()
        #expect(inbox.items.map(\.id) == [seat.id, coffee.id])

        gate.close()
        let loading = Task { await inbox.load() }
        await gate.arrived()
        #expect(await inbox.reject(seat.id))
        gate.open()
        await loading.value
        #expect(inbox.items.map(\.id) == [coffee.id])
        await inbox.load()
        #expect(inbox.items.map(\.id) == [coffee.id])
    }

    /// A forced load asked for while another runs (a ring during a foreground) goes once that one
    /// is back, so what the ring announced shows.
    @Test func aForcedLoadDuringAnotherRunsAfterIt() async throws {
        let approvals = FakeApprovals()
        let gate = Gate()
        let model = ApprovalsModel(caller: GatedCaller(inner: approvals, method: .approvalsList, gate: gate), clock: { t0 })
        let loading = Task { await model.load() }
        await gate.arrived()
        let rung = approvals.share(rows: [])
        await model.load(force: true)
        gate.open()
        await loading.value
        #expect(approvals.calls.filter { $0 == .approvalsList }.count == 2)
        #expect(model.items.map(\.id) == [rung.id])
    }

    /// A capture keeps everything after an embedded NUL.
    @Test func aNulDoesNotCutACapture() throws {
        let queue = temporaryQueue()
        let added = try queue.add("before\u{0}after", note: "a\u{0}b", source: .share, now: t0)
        let read = try #require(try queue.all().first)
        #expect(read.text == "before\u{0}after" && read.note == "a\u{0}b")
        #expect(read == added)
    }
}

/// A status check from an old pairing, coming back after pairing again, doesn't write its address
/// or the old Mac's name into the new pairing.
@Suite struct OldPairingTests {
    @Test func aCheckFromTheOldPairingStaysOut() async throws {
        let rig = Rig(routes: { ["192.168.1.20": .mac($0), "100.101.102.103": .mac($0)] })
        try await rig.pair([Addresses.lan])
        rig.mac.calledName = "Old"
        let gate = Gate()
        rig.transport.set("192.168.1.20", .held(gate, rig.mac))
        let check = Task { try await rig.client.status(fresh: true) }
        await gate.arrived()
        rig.mac.calledName = nil
        let second = try await rig.pair([Addresses.tailscale])
        rig.mac.calledName = "Old"
        gate.open()
        await #expect(throws: CompanionClientError.unreachable(localNetworkDenied: false)) { try await check.value }
        #expect(await rig.client.currentAddress?.kind == .tailscale)
        #expect(try await rig.client.record() == second)
        #expect(await rig.client.lastProbes.map(\.address.kind) == [.tailscale])
    }
}
