import BridgeKitRemote
import Foundation
import Testing
@testable import BridgeUI

/// The menu bar panel's models (ADR-0029, FR-G-01): Waiting for you, the two tiles and the field.
@MainActor
@Suite("Menu bar panel")
struct MenuBarPanelTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func share(_ id: UUID = UUID(), agent: String = "Claude Code", expires: Date?) -> PanelItem {
        PanelItem.share(id: id, agentID: "a", agentName: agent, destination: nil, task: nil, keywords: [], purpose: nil,
                        keepsIt: nil, sharedWith: [], rows: [PanelItem.Row(id: "m", title: "Title")], note: nil, expiresAt: expires)
    }

    func save(agent: String) -> PanelItem {
        var item = PanelItem(id: UUID(), kind: .save, agentID: "b", title: "Save this memory?", rows: [], primary: "Save",
                             secondary: "Later", announcement: "")
        item.cardTitle = "\(agent) wants to save a memory"
        return item
    }

    func signIn(_ app: String, expires: Date) -> PairingRequest {
        PairingRequest(id: UUID(), clientID: "c", appName: app, appURL: nil, redirectHost: "claude.ai", code: "482 913",
                       expiresAt: expires)
    }

    // MARK: Waiting for you

    /// A live request that times out into Pending requests stays one card throughout, and the
    /// Review Request shortcut follows it.
    @Test func aRequestTimingOutIntoPendingIsOneCard() {
        var clock = t0
        let queue = ApprovalQueue(clock: { clock })
        let id = UUID()
        queue.enqueue(share(id, expires: t0 + 45)) { _ in }
        // DisclosureService.pendingRequests lists the request on screen too.
        let pending = [WaitingItems.Pending(id: id, title: "Claude Code wants 1 memory", expiresAt: t0 + 900)]
        let live = WaitingItems(queue: queue.ordered, current: queue.current, signIns: [], pending: pending, now: clock)
        #expect(live.cards.map(\.route) == [.queueItem(id)])
        #expect(live.cards[0].time == .answerBy(t0 + 45))
        #expect(live.reviewTarget == .queueItem(id))
        #expect(WaitingItems.timeText(live.cards[0].time, now: t0 + 4) == "0:41 to answer")
        #expect(WaitingItems.spokenTime(live.cards[0].time, now: t0 + 4) == "41 seconds to answer")

        clock = t0 + 46
        queue.tick()
        #expect(queue.items.isEmpty)
        let later = WaitingItems(queue: queue.ordered, current: queue.current, signIns: [], pending: pending, now: clock)
        #expect(later.cards.map(\.route) == [.pending(id)])
        #expect(later.cards[0].time == .stillAnswerable(t0 + 900))
        #expect(WaitingItems.timeText(later.cards[0].time, now: clock) == "Still answerable · 15 min left")
        #expect(later.reviewTarget == .pending(id))
    }

    /// Answered on the iPhone: the panel's item is withdrawn and the request no longer pending, so its card goes.
    @Test func answeredOnTheIPhoneTheCardGoes() {
        let queue = ApprovalQueue(clock: { self.t0 })
        let id = UUID()
        queue.enqueue(share(id, expires: t0 + 45)) { _ in }
        queue.withdraw(id)
        let items = WaitingItems(queue: queue.ordered, current: queue.current, signIns: [], pending: [], now: t0)
        #expect(items.isEmpty)
        #expect(items.reviewTarget == nil)
    }

    /// The approval panel's order (on a clock first, soonest first, then a Save), then the first
    /// sign-in, then Pending requests by expiry; an expired sign-in or request has no card.
    @Test func orderAndOverflow() {
        let queue = ApprovalQueue(clock: { self.t0 })
        let saveItem = save(agent: "Codex")
        let late = share(agent: "Cursor", expires: t0 + 40)
        let soon = share(agent: "Claude Code", expires: t0 + 10)
        queue.enqueue(saveItem) { _ in }
        queue.enqueue(late) { _ in }
        queue.enqueue(soon) { _ in }
        let first = signIn("claude.ai", expires: t0 + 300)
        let second = signIn("ChatGPT", expires: t0 + 300)
        let a = WaitingItems.Pending(id: UUID(), title: "Zed wants 2 memories", expiresAt: t0 + 600)
        let b = WaitingItems.Pending(id: UUID(), title: "Codex wants 1 memory", expiresAt: t0 + 120)
        let gone = WaitingItems.Pending(id: UUID(), title: "Old", expiresAt: t0 - 1)
        let items = WaitingItems(queue: queue.ordered, current: queue.current, signIns: [first, second],
                                 pending: [a, b, gone], now: t0)
        #expect(items.cards.map(\.route) == [.queueItem(soon.id), .queueItem(late.id), .queueItem(saveItem.id),
                                             .signIn(first.id), .pending(b.id), .pending(a.id)])
        #expect(items.cards[2].title == "Codex wants to save a memory")
        #expect(items.cards[2].time == .none)
        #expect(items.cards[3].title == "claude.ai wants to connect")
        #expect(items.cards[3].time == .until(t0 + 300))
        #expect(items.shown.count == 3)
        #expect(items.hiddenCount == 3)
        #expect(items.hidesPending)
        #expect(items.reviewTarget == .queueItem(soon.id))

        // A chip chosen in the approval panel is what Review Request reviews.
        queue.select(late.id)
        let chosen = WaitingItems(queue: queue.ordered, current: queue.current, signIns: [], pending: [], now: t0)
        #expect(chosen.reviewTarget == .queueItem(late.id))
        #expect(!chosen.hidesPending)

        let expired = WaitingItems(queue: [], current: nil, signIns: [signIn("x", expires: t0 - 1)], pending: [], now: t0)
        #expect(expired.isEmpty)
    }

    /// Review can only route: the card's model has no answer, withdraw or sign-in decision in it.
    @Test func aCardOnlyRoutes() {
        let routes: [WaitingItems.Route] = [.queueItem(UUID()), .signIn(UUID()), .pending(UUID())]
        for route in routes {
            switch route {
            case .queueItem, .signIn, .pending: break
            }
        }
        // Each panel's own arming outlasts the key press that chose Review.
        #expect(ApprovalPanelView.armingDelay >= 0.5)
    }

    // MARK: The tiles

    @Test func agentsTileOrder() {
        func tile(enabled: Bool = true, _ server: AgentsTile.Server = .listening, paused: Date? = nil, agents: Int = 2) -> AgentsTile {
            AgentsTile(serverEnabled: enabled, server: server, pausedUntil: paused, agents: agents)
        }
        #expect(tile(enabled: false, .failed(portInUse: 47_625), paused: t0) == .offInSettings)
        #expect(tile(.failed(portInUse: 47_625), paused: t0) == .cantConnect(portInUse: 47_625))
        #expect(tile(.starting, paused: t0) == .starting)
        #expect(tile(.off) == .starting)
        #expect(tile(paused: t0, agents: 0) == .paused(until: t0))
        #expect(tile(agents: 0) == .noAgents)
        #expect(tile(agents: 1) == .on(agents: 1))
        #expect(tile(agents: 1).status(now: t0) == "On · 1 agent")
        #expect(tile(agents: 4).status(now: t0) == "On · 4 agents")
        #expect(tile(.failed(portInUse: 47_625)).status(now: t0) == "Port 47625 is in use")
        #expect(tile(.failed(portInUse: nil)).status(now: t0) == "The agent server stopped")
        #expect(tile(paused: .distantFuture).status(now: t0) == "Paused until you resume")
        #expect(tile(paused: .distantFuture).hasSwitch && !tile(paused: .distantFuture).isOn)
        #expect(!tile(agents: 0).hasSwitch && !tile(enabled: false).hasSwitch && !tile(.failed(portInUse: nil)).hasSwitch)
    }

    @Test func remoteTileOrderAndAlwaysASwitchWhileOn() {
        let defaults = UserDefaults(suiteName: "funes-remote-tile-\(UUID().uuidString)")!
        let remote = RemoteAccessController(defaults: defaults, appName: "Funes Vault", names: .funes, defaultPort: 47_627,
                                            host: .inert)
        #expect(remote.showsIntroduction)
        #expect(remote.tile(agentServerUp: true, agentsPaused: false) == .notSetUp)
        #expect(!RemoteTile.notSetUp.hasSwitch)

        remote.reviewSet(enabled: false, origin: "https://my-mac.tail1234.ts.net", tunnel: .tailscaleFunnel)
        #expect(remote.tile(agentServerUp: true, agentsPaused: false) == .off)

        remote.reviewSet(enabled: true, origin: "https://my-mac.tail1234.ts.net", tunnel: .tailscaleFunnel)
        #expect(remote.tile(agentServerUp: true, agentsPaused: false) == .on(cloudAgents: 0, until: nil, agentsPaused: false))
        #expect(remote.tile(agentServerUp: true, agentsPaused: true).status == "On · told it's paused")
        // The agent server off or failed, or the listener down: not listening, and still a switch.
        #expect(remote.tile(agentServerUp: false, agentsPaused: false) == .notListening)
        remote.statusDidChange(.off)
        #expect(remote.tile(agentServerUp: true, agentsPaused: false) == .notListening)
        #expect(RemoteTile.notListening.hasSwitch && RemoteTile.notListening.isOn)

        remote.reviewSet(enabled: true, origin: "https://my-mac.tail1234.ts.net", tunnel: .tailscaleFunnel,
                         health: .notRunning(reason: .noTunnel))
        #expect(remote.tile(agentServerUp: true, agentsPaused: false) == .tunnelDown)
        #expect(RemoteTile.tunnelDown.hasSwitch && RemoteTile.tunnelDown.isOn && RemoteTile.tunnelDown.isWarning)

        // Mid-guide (on, no address yet) isn't "not set up": the switch shows, so it can be turned off.
        remote.reviewSet(enabled: true, origin: nil, tunnel: nil)
        #expect(!remote.showsIntroduction)
        #expect(remote.tile(agentServerUp: true, agentsPaused: false).hasSwitch)

        // The automatic turn-off: "On · until 18:00".
        let until = RemoteTile.on(cloudAgents: 2, until: t0, agentsPaused: false)
        #expect(until.status == "On · until \(t0.formatted(date: .omitted, time: .shortened))")
        #expect(RemoteTile.on(cloudAgents: 2, until: nil, agentsPaused: false).status == "On · 2 cloud agents")
        // Turning off acts at once, with no question.
        remote.reviewSet(enabled: true, origin: "https://my-mac.tail1234.ts.net", tunnel: .tailscaleFunnel)
        remote.apply(false)
        #expect(remote.tile(agentServerUp: true, agentsPaused: false) == .off)
    }

    // MARK: The field

    struct Hit: Identifiable, Equatable, Sendable {
        let id: Int
        let title: String
    }

    final class Calls {
        var stored: [String] = []
        var searches: [String] = []
        var asks: [(String, [Int])] = []
    }

    func field(_ calls: Calls, hits: Int = 7, answersOn: Bool = true, storeFails: Bool = false,
               searchDelay: Duration = .zero, askDelay: Duration = .zero) -> PanelField<Hit, String> {
        let field = PanelField<Hit, String>()
        field.validate = { $0.contains("sk-") ? "That looks like a secret." : nil }
        field.store = { text in
            calls.stored.append(text)
            return storeFails ? "It couldn't be saved. Try again." : nil
        }
        field.search = { query in
            calls.searches.append(query)
            try await Task.sleep(for: searchDelay)
            let rows = (0..<min(hits, 10)).map { Hit(id: $0, title: "QXZ-SENTINEL \(query) \($0)") }
            return .init(rows: rows, total: hits)
        }
        field.answersOn = { answersOn }
        field.ask = { query, ids in
            calls.asks.append((query, ids))
            try await Task.sleep(for: askDelay)
            return "Answer to \(query)"
        }
        field.savedDuration = .milliseconds(50)
        return field
    }

    func settle(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// No retrieved vault content before the user searches: typing and saving show none.
    @Test func noResultsBeforeASearch() async {
        let calls = Calls()
        let field = field(calls)
        #expect(field.page == nil && field.answer == nil && !field.searching)
        field.text = "my coffee order"
        #expect(field.page == nil && field.answer == nil)
        _ = field.returnKey()
        await settle { field.hint == .saved }
        #expect(field.page == nil && field.answer == nil)
        #expect(calls.searches.isEmpty)
    }

    /// ⏎ remembers: the field clears, "Saving…" then "Saved to Inbox", and dictation stops. A
    /// secret stays in the field with the reason, and nothing is saved.
    @Test func returnRemembers() async {
        let calls = Calls()
        let field = field(calls)
        field.text = "  oat milk flat white  "
        let stops = field.dictationStops
        #expect(field.returnKey() == .handled)
        #expect(field.text.isEmpty)
        #expect(field.hint == .saving)
        #expect(field.dictationStops > stops)
        await settle { field.hint == .saved }
        #expect(calls.stored == ["oat milk flat white"])
        await settle { field.hint == .keys }
        #expect(field.hint == .keys)

        field.text = "key sk-abc123"
        _ = field.returnKey()
        #expect(field.text == "key sk-abc123")
        #expect(field.error == "That looks like a secret.")
        #expect(calls.stored.count == 1)
    }

    /// A failed save puts the text back only into an empty field; otherwise Restore swaps it in
    /// and keeps what was typed since as the next draft.
    @Test func aFailedSaveNeverOverwritesTheNextDraft() async {
        let calls = Calls()
        let failing = field(calls, storeFails: true)
        failing.text = "first note"
        _ = failing.returnKey()
        await settle { failing.error != nil }
        #expect(failing.text == "first note")
        #expect(failing.hint == .keys)

        let busy = field(calls, storeFails: true)
        busy.store = { text in
            try? await Task.sleep(for: .milliseconds(30))
            return "It couldn't be saved. Try again."
        }
        busy.text = "lost note"
        _ = busy.returnKey()
        busy.text = "typed since"
        await settle { busy.hint == .notSaved }
        #expect(busy.text == "typed since")
        #expect(busy.unsaved == "lost note")
        busy.restore()
        #expect(busy.text == "lost note")
        #expect(busy.unsaved == nil)
        busy.store = { _ in nil }
        _ = busy.returnKey()
        #expect(busy.text == "typed since")

        // Two notes failing one after the other while typing goes on: neither is lost.
        let twice = field(calls)
        twice.store = { text in
            // A fails first, then B.
            try? await Task.sleep(for: .milliseconds(text == "note A" ? 10 : 60))
            return "It couldn't be saved. Try again."
        }
        twice.text = "note A"
        _ = twice.returnKey()
        twice.text = "note B"
        _ = twice.returnKey()
        twice.text = "note C"
        await settle { twice.unsaved?.contains("note B") == true }
        #expect(twice.unsaved == "note A\n\nnote B")
        #expect(twice.text == "note C")
    }

    /// ⌘⏎ searches and shows 5 of the results; while they show, ⏎ opens the selected one and never saves.
    @Test func whileResultsShowReturnNeverSaves() async {
        let calls = Calls()
        let field = field(calls, answersOn: false)
        field.text = "coffee"
        field.commandReturn()
        await settle { field.page != nil }
        #expect(field.shownRows.count == 5)
        #expect(field.page?.total == 7)
        field.moveSelection(by: 1)
        field.moveSelection(by: 10)
        #expect(field.selection == 4)
        #expect(field.returnKey() == .open(Hit(id: 4, title: "QXZ-SENTINEL coffee 4")))
        #expect(calls.stored.isEmpty)
        // No matches: ⏎ still doesn't save.
        let none = self.field(calls, hits: 0)
        none.text = "nothing"
        none.commandReturn()
        await settle { none.page != nil }
        #expect(none.returnKey() == .handled)
        #expect(calls.stored.isEmpty)
    }

    /// Esc steps back: results → the chart (text stays), then the text clears, then the panel closes.
    @Test func escapeStepsBack() async {
        let calls = Calls()
        let field = field(calls)
        field.text = "coffee"
        field.commandReturn()
        await settle { field.page != nil }
        #expect(field.escape() == .handled)
        #expect(field.page == nil && field.text == "coffee")
        #expect(field.escape() == .handled)
        #expect(field.text.isEmpty)
        #expect(field.escape() == .close)
    }

    /// ⌘⏎ again asks with the results an answer reads; editing the text, Esc and closing cancel a
    /// call, and a late answer is dropped.
    @Test func askingAndLateAnswersAreDropped() async {
        let calls = Calls()
        let field = field(calls, askDelay: .milliseconds(40))
        field.readsAtMost = { 5 }
        field.text = "where do I work?"
        field.commandReturn()
        await settle { field.page != nil }
        field.commandReturn()
        #expect(field.answer == .reading(count: 5))
        await settle { field.answer != .reading(count: 5) }
        #expect(calls.asks.last?.1 == Array(0..<7))
        #expect(field.answer == .answered("Answer to where do I work?"))

        // Editing the text drops the results and the answer in progress; its late result never lands.
        field.clearAnswer()
        field.askNow()
        field.text = "where do I work"
        #expect(field.page == nil && field.answer == nil)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(field.answer == nil && field.page == nil)

        // A provider that ignores cancellation and answers late: its answer is dropped too.
        field.commandReturn()
        await settle { field.page != nil }
        field.ask = { query, _ in
            await withCheckedContinuation { done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { done.resume() }
            }
            return "Late answer to \(query)"
        }
        field.askNow()
        _ = field.escape()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(field.answer == nil && field.page == nil)
        field.ask = { query, _ in
            try await Task.sleep(for: .milliseconds(40))
            return "Answer to \(query)"
        }

        // Closing does the same, and keeps the draft.
        field.commandReturn()
        await settle { field.page != nil }
        field.askNow()
        field.close()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(field.answer == nil && field.page == nil)
        #expect(field.text == "where do I work")
    }

    /// A late search result after the panel closed is dropped too.
    @Test func lateSearchIsDropped() async {
        let calls = Calls()
        let field = field(calls, searchDelay: .milliseconds(40))
        field.text = "coffee"
        field.commandReturn()
        #expect(field.searching)
        field.close()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(field.page == nil && !field.searching)
    }

    /// The automatic answer waits for its pause, and is cancelled by an edit during it.
    @Test func automaticAnswer() async {
        let calls = Calls()
        let field = field(calls)
        field.autoAskPause = { $0.hasSuffix("?") ? .milliseconds(30) : nil }
        field.text = "coffee"
        field.commandReturn()
        await settle { field.page != nil }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(field.answer == nil)

        field.text = "coffee?"
        field.commandReturn()
        await settle { field.page != nil }
        await settle { field.answer == .answered("Answer to coffee?") }
        #expect(field.answer == .answered("Answer to coffee?"))

        let asks = calls.asks.count
        field.text = "tea?"
        field.commandReturn()
        await settle { field.page != nil }
        field.text = "tea"
        try? await Task.sleep(for: .milliseconds(60))
        #expect(calls.asks.count == asks)
    }

    /// The draft lives in memory: nothing the field holds reaches user defaults.
    @Test func theDraftIsNeverWrittenToDefaults() async {
        let calls = Calls()
        let field = field(calls)
        let marker = "QXZ-DRAFT-\(UUID().uuidString)"
        field.text = marker
        field.close()
        #expect(field.text == marker)
        let stored = UserDefaults.standard.dictionaryRepresentation().values.map { "\($0)" }.joined()
        #expect(!stored.contains(marker))
    }
}
