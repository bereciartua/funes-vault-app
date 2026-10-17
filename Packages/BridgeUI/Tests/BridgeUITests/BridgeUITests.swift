import Foundation
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
