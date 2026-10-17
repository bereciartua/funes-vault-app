import Foundation
import SwiftUI
import Testing
@testable import BridgeUI

struct Row: ActivityRow, Equatable {
    var rowID: String
    var at: Date
    var phase: String
    var requestID: String?
    var important: Bool
    var isImportant: Bool { important }
}

/// Ported from EK Bridge's ActivityStoreTests: append, load, file modes, invalid lines, unique
/// ids, compaction and the retention limits at their boundaries.
@Suite("Activity store")
struct ActivityStoreTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridgeui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test func appendLoadAndModes() throws {
        let data = try folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let store = ActivityStore<Row>(dataFolder: data, retention: .funes)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(store.append(Row(rowID: "a", at: now, phase: "event", important: true)))
        #expect(store.append(Row(rowID: "a", at: now, phase: "event", important: false)))
        #expect(store.records().map(\.rowID) == ["a", "a#2"])
        let file = try FileManager.default.attributesOfItem(atPath: store.file.path)
        let dir = try FileManager.default.attributesOfItem(atPath: store.folder.path)
        #expect((file[.posixPermissions] as? Int) == 0o600)
        #expect((dir[.posixPermissions] as? Int) == 0o700)
        // A new store reads the file; a broken line is skipped and counted.
        let handle = try FileHandle(forWritingTo: store.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        let again = ActivityStore<Row>(dataFolder: data, retention: .funes)
        #expect(again.records().map(\.rowID) == ["a", "a#2"])
        #expect(again.skippedLines == 1)
        #expect(again.contains(id: "a#2"))
    }

    @Test func failingSyncRefusesTheRow() throws {
        let data = try folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let store = ActivityStore<Row>(dataFolder: data, retention: .funes, sync: { _ in -1 })
        #expect(!store.append(Row(rowID: "a", at: Date(), phase: "event", important: true)))
        #expect(store.records().isEmpty)
    }

    @Test func retentionBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let rows = [
            Row(rowID: "old-important", at: now - 400 * day, phase: "result", important: true),
            Row(rowID: "kept-important", at: now - 399 * day, phase: "result", important: true),
            Row(rowID: "old-routine", at: now - 30 * day, phase: "result", important: false),
            Row(rowID: "kept-routine", at: now - 29 * day, phase: "result", important: false),
            Row(rowID: "open-start", at: now - 60, phase: "start", requestID: "r1", important: false),
            Row(rowID: "done-start", at: now - 60, phase: "start", requestID: "r2", important: false),
            Row(rowID: "done", at: now - 30, phase: "result", requestID: "r2", important: false),
        ]
        #expect(ActivityRetention.funes.keep(rows, now: now).map(\.rowID)
            == ["kept-important", "kept-routine", "open-start", "done"])
        let limited = ActivityRetention(importantAge: 1e9, importantLimit: 2, routineAge: 1e9, routineLimit: 1)
        let many = (0..<5).map { Row(rowID: "i\($0)", at: now + Double($0), phase: "result", important: $0 < 3) }
        #expect(limited.keep(many, now: now + 10).map(\.rowID) == ["i1", "i2", "i4"])
    }

    @Test func compactionKeepsWhatRetentionKeeps() throws {
        let data = try folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ActivityStore<Row>(dataFolder: data, retention: .funes, now: { now })
        store.append(Row(rowID: "old", at: now - 31 * 86_400, phase: "result", important: false))
        store.append(Row(rowID: "new", at: now, phase: "result", important: false))
        #expect(store.compact())
        #expect(store.records().map(\.rowID) == ["new"])
        #expect(ActivityStore<Row>(dataFolder: data, retention: .funes).records().map(\.rowID) == ["new"])
    }
}

/// Ported from EK Bridge's ApprovalCenterTests: FIFO and selection, the countdown, exactly-once
/// answers, withdraw and row toggling.
@Suite("Approval queue")
@MainActor
struct ApprovalQueueTests {
    func item(_ id: UUID = UUID(), expires: Date? = nil, agent: String = "a") -> PanelItem {
        PanelItem(id: id, kind: .share, agentID: agent, title: "Share?",
                  rows: [PanelItem.Row(id: "m1", title: "One"), PanelItem.Row(id: "m2", title: "Two")],
                  primary: "Share", secondary: "Deny", expiresAt: expires, announcement: "Share?")
    }

    @Test func fifoSelectionAndExactlyOnce() {
        let queue = ApprovalQueue()
        var answers = [String]()
        let first = item(), second = item()
        queue.enqueue(first) { answers.append("first \($0)") }
        queue.enqueue(second) { answers.append("second \($0)") }
        #expect(queue.current?.id == first.id)
        queue.selection = 1
        #expect(queue.current?.id == second.id)
        queue.answer(second.id, .secondary)
        queue.answer(second.id, .tertiary)
        #expect(answers == ["second secondary"])
        #expect(queue.current?.id == first.id)
        queue.toggle(row: "m1", in: first.id)
        #expect(queue.current?.selectedIDs == ["m2"])
        queue.answer(first.id, .primary(selected: queue.current?.selectedIDs ?? []))
        #expect(answers.last == "first primary(selected: [\"m2\"])")
        #expect(queue.current == nil)
    }

    @Test func onlyThreeShown() {
        let queue = ApprovalQueue()
        for _ in 0..<5 { queue.enqueue(item()) { _ in } }
        #expect(queue.shown.count == 3)
        #expect(queue.items.count == 5)
    }

    @Test func countdownExpires() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let queue = ApprovalQueue(clock: { clock })
        var answer: PanelAnswer?
        let waiting = item(expires: clock + 45)
        queue.enqueue(waiting) { answer = $0 }
        #expect(queue.remaining(waiting) == 45)
        clock += 44.5
        queue.tick()
        #expect(answer == nil)
        clock += 1
        queue.tick()
        #expect(answer == .expired)
    }

    @Test func withdrawAll() {
        let queue = ApprovalQueue()
        var answers = [PanelAnswer]()
        for _ in 0..<2 { queue.enqueue(item()) { answers.append($0) } }
        queue.withdrawAll()
        #expect(answers == [.withdrawn, .withdrawn])
        #expect(queue.items.isEmpty)
    }

    @Test func reenqueueKeepsTheFirstCompletion() {
        let queue = ApprovalQueue()
        var answers = [String]()
        let id = UUID()
        queue.enqueue(item(id)) { _ in answers.append("first") }
        var updated = item(id)
        updated.title = "Updated"
        queue.enqueue(updated) { _ in answers.append("second") }
        #expect(queue.items.count == 1 && queue.current?.title == "Updated")
        queue.answer(id, .secondary)
        #expect(answers == ["first"])
    }
}

/// PR #2 review findings on the Share panel (4303295917, 4303295925, 4303295930).
@Suite("Share panel review fixes")
@MainActor
struct SharePanelReviewTests {
    static func shareItem(_ id: UUID, rows: [PanelItem.Row]) -> PanelItem {
        PanelItem(id: id, kind: .share, agentID: "a", title: "Claude Code wants to use your memories",
                  subtitle: "For: plan the week", rows: rows, facts: [PanelItem.Fact(label: "Keeps it", value: "Not said")],
                  note: "2 more matched but can't go to this agent.", primary: "Share", secondary: "Deny",
                  expiresAt: nil, announcement: "Share?")
    }

    static let publicRow = PanelItem.Row(id: "public", title: "Coffee", detail: "Flat white.", version: "1")
    static let privateRow = PanelItem.Row(id: "private", title: "Work hours", detail: "9 to 12.", version: "1")

    // 4303295917: re-enqueuing (open_in_funes) must not re-tick what the user unticked.
    @Test func refreshKeepsTheUsersSelection() {
        let queue = ApprovalQueue()
        let id = UUID()
        queue.enqueue(Self.shareItem(id, rows: [Self.publicRow, Self.privateRow])) { _ in }
        queue.toggle(row: "private", in: id)
        #expect(queue.current?.selectedIDs == ["public"])
        let generation = queue.generation(of: id)
        queue.enqueue(Self.shareItem(id, rows: [Self.publicRow, Self.privateRow])) { _ in }
        #expect(queue.current?.selectedIDs == ["public"])
        #expect(queue.generation(of: id) == generation, "unchanged content keeps the buttons armed")
    }

    // 4303295917: when what would be shared changes, the buttons re-arm (new generation), and a
    // changed memory isn't covered by the old tick.
    @Test func changedContentReArms() {
        let queue = ApprovalQueue()
        let id = UUID()
        queue.enqueue(Self.shareItem(id, rows: [Self.publicRow, Self.privateRow])) { _ in }
        queue.toggle(row: "private", in: id)
        let generation = queue.generation(of: id)
        var edited = Self.publicRow
        edited.detail = "Flat white, oat milk."
        edited.version = "2"
        queue.enqueue(Self.shareItem(id, rows: [edited, Self.privateRow])) { _ in }
        #expect(queue.generation(of: id) == generation + 1)
        #expect(queue.current?.selectedIDs == ["public"], "the unticked unchanged row stays unticked")
        let added = PanelItem.Row(id: "new", title: "New", detail: "Added.", version: "1")
        queue.enqueue(Self.shareItem(id, rows: [edited, Self.privateRow, added])) { _ in }
        #expect(queue.generation(of: id) == generation + 2)
    }

    // 4303295925: the user can read everything they'd share before sharing it.
    @Test func showAllRevealsTheExactText() {
        let long = (1...40).map { "Line \($0) of a long memory body with details." }.joined(separator: " ")
        let multiline = "One\nTwo\nThree\nFour"
        let queue = ApprovalQueue()
        let id = UUID()
        let rows = [PanelItem.Row(id: "long", title: "Long", detail: long),
                    PanelItem.Row(id: "lines", title: "Lines", detail: multiline),
                    PanelItem.Row(id: "short", title: "Short", detail: "Fits.")]
        queue.enqueue(Self.shareItem(id, rows: rows)) { _ in }
        let item = try! #require(queue.current)
        for row in item.rows {
            let shown = try! #require(queue.displayedDetail(row, in: id))
            // Either the whole text is visible, or Show all is offered.
            #expect(shown == row.detail || row.isClipped)
        }
        #expect(item.rows.map(\.isClipped) == [true, true, false])
        #expect(PanelText.preview(long).count <= PanelText.previewCharacters + 1)
        #expect(PanelText.preview(multiline) == "One\nTwo\nThree…")
        queue.toggleExpanded(row: "long", in: id)
        #expect(queue.displayedDetail(item.rows[0], in: id) == long)
        queue.toggleExpanded(row: "long", in: id)
        #expect(queue.displayedDetail(item.rows[0], in: id) == PanelText.preview(long))
    }

    // 4303295930: 30 rows on an 871 pt screen: the panel stays within the screen and the rows scroll.
    @Test func thirtyRowsFitTheScreen() {
        let queue = ApprovalQueue()
        let rows = (1...30).map {
            PanelItem.Row(id: "m\($0)", title: "Memory \($0)", detail: "Body of memory \($0), a sentence or two long.",
                          version: "1", badge: "Low")
        }
        queue.enqueue(Self.shareItem(UUID(), rows: rows)) { _ in }
        let available: CGFloat = 871
        let ideal = ApprovalPanelController.idealHeight(for: queue)
        #expect(ideal > available, "30 rows need more than the screen: \(ideal)")
        #expect(ApprovalPanelController.height(for: queue, available: available) == available)
        // The panel's view laid out in that height doesn't grow past it, so the footer is on screen.
        let host = NSHostingController(rootView: ApprovalPanelView(queue: queue, scrolls: true))
        let fitted = host.sizeThatFits(in: NSSize(width: ApprovalPanelController.width, height: available))
        #expect(fitted.height <= available, "laid out at \(fitted.height) pt")
        // Few rows: the panel is just as tall as its content.
        let small = ApprovalQueue()
        small.enqueue(Self.shareItem(UUID(), rows: Array(rows.prefix(2)))) { _ in }
        #expect(ApprovalPanelController.height(for: small, available: available) < 400)
    }
}

/// The agent's keywords appear as "Looking for" with the task (ADR-0016 decision 3, access policy
/// §3.2, 04-ux-mac.md), previewed to two lines with Show all, and omitted when there are none.
@Suite("Share panel: looking for")
@MainActor
struct LookingForTests {
    static func item(keywords: [String], task: String? = "Plan dinner") -> PanelItem {
        PanelItem.share(id: UUID(), agentID: "a", agentName: "Claude Code", task: task, keywords: keywords,
                        purpose: "menu", keepsIt: "For this session", sharedWith: [],
                        rows: [PanelItem.Row(id: "m", title: "Vegetarian", detail: "No meat.")], note: nil, expiresAt: nil)
    }

    @Test func keywordsAreShownWithTheTask() throws {
        let item = Self.item(keywords: ["dietary restrictions", " food allergies ", "", "favourite cuisines"])
        #expect(item.subtitle == "Task: “Plan dinner”")
        let first = try #require(item.facts.first)
        #expect(first.label == "Looking for")
        #expect(first.value == "dietary restrictions, food allergies, favourite cuisines")
        #expect(item.facts.map(\.label) == ["Looking for", "Purpose", "Keeps it"])
    }

    @Test func noKeywordsNoLine() {
        #expect(!Self.item(keywords: []).facts.contains { $0.label == "Looking for" })
        #expect(!Self.item(keywords: ["  "]).facts.contains { $0.label == "Looking for" })
    }

    @Test func longKeywordListsPreviewWithShowAll() throws {
        let keywords = (1...20).map { "kind of personal context \($0)" }
        let queue = ApprovalQueue()
        let item = Self.item(keywords: keywords)
        queue.enqueue(item) { _ in }
        let fact = try #require(item.facts.first { $0.label == "Looking for" })
        #expect(fact.isClipped)
        let preview = queue.displayedValue(fact, in: item.id)
        #expect(preview.count <= PanelText.factCharacters + 1 && preview.hasSuffix("…"))
        queue.toggleExpanded(row: "fact:Looking for", in: item.id)
        #expect(queue.displayedValue(fact, in: item.id) == keywords.joined(separator: ", "))
        let short = try #require(Self.item(keywords: ["coffee order"]).facts.first)
        #expect(!short.isClipped && queue.displayedValue(short, in: UUID()) == "coffee order")
    }
}

/// Task 3.6: the access-request panel and pending countdowns.
@Suite("Access-request panel")
@MainActor
struct AccessPanelTests {
    @Test func countdownWording() {
        #expect(ApprovalQueue.countdown(41) == "41 s")
        #expect(ApprovalQueue.countdown(60) == "1:00")
        #expect(ApprovalQueue.countdown(545) == "9:05")
    }

    @Test func answersArriveOnce() {
        let queue = ApprovalQueue()
        var answers = [PanelAnswer]()
        let item = PanelItem(id: UUID(), kind: .access, agentID: "a", title: "Cursor wants more access", rows: [],
                             primary: "Always Allow", secondary: "Not Now", tertiary: "Allow Once",
                             expiresAt: Date().addingTimeInterval(45), announcement: "Cursor wants more access")
        queue.enqueue(item) { answers.append($0) }
        queue.answer(item.id, .tertiary)
        queue.answer(item.id, .primary(selected: []))
        #expect(answers == [.tertiary])
        let save = PanelItem(id: UUID(), kind: .save, agentID: "a", title: "Save this memory?", rows: [], primary: "Save",
                             secondary: "Later", tertiary: "Discard", edit: "Edit…", announcement: "x")
        queue.enqueue(save) { answers.append($0) }
        queue.answer(save.id, .edit)
        #expect(answers == [.tertiary, .edit])
    }
}
