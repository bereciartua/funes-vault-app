import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// A queue in a fresh temporary folder.
func temporaryQueue() -> CaptureQueue {
    let folder = FileManager.default.temporaryDirectory.appending(path: "funes-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
    return CaptureQueue(url: folder.appending(path: CaptureQueue.fileName))
}

@Suite struct CaptureQueueTests {
    @Test func addsAndReadsBackNewestFirst() throws {
        let queue = temporaryQueue()
        let first = try queue.add("  Sam prefers aisle seats  ", source: .typed, now: t0)
        let second = try queue.add("https://example.com/article", note: " read later ", source: .share, now: t0.addingTimeInterval(1))
        #expect(first.text == "Sam prefers aisle seats")
        #expect(second.note == "read later")
        #expect(try queue.queuedCount() == 2)
        let all = try queue.all()
        #expect(all.map(\.id) == [second.id, first.id])
        #expect(all[0] == second)
        #expect(all[1].source == .typed && all[1].createdAt == t0 && all[1].state == .queued && all[1].attempts == 0)
    }

    @Test func blankNoteIsNoNote() throws {
        let queue = temporaryQueue()
        #expect(try queue.add("Text", note: "   ", source: .share).note == nil)
    }

    @Test func refusesEmptyAndTooLong() throws {
        let queue = temporaryQueue()
        #expect(throws: CaptureQueueError.empty) { try queue.add(" \n ", source: .typed) }
        #expect(throws: CaptureQueueError.tooLong) { try queue.add(String(repeating: "a", count: 10_001), source: .typed) }
        // The note counts too, with the blank line the Mac joins them with.
        #expect(throws: CaptureQueueError.tooLong) {
            try queue.add(String(repeating: "a", count: 9_000), note: String(repeating: "b", count: 999), source: .share)
        }
        try queue.add(String(repeating: "a", count: 9_000), note: String(repeating: "b", count: 998), source: .share)
        #expect(try queue.queuedCount() == 1)
    }

    /// The phone runs the Mac's secret scanner and saves nothing that matches (§6).
    @Test func secretIsBlockedBeforeItIsQueued() throws {
        let queue = temporaryQueue()
        let token = "ghp_" + String(repeating: "A1b2", count: 9)
        #expect(throws: CaptureQueueError.secret([.githubToken])) { try queue.add("my token is \(token)", source: .typed) }
        #expect(throws: CaptureQueueError.secret([.assignedSecret])) {
            try queue.add("Wi-Fi at the cabin", note: "password = correcthorsebattery", source: .share)
        }
        #expect(throws: CaptureQueueError.secret([.creditCard])) { try queue.add("card 4111 1111 1111 1111", source: .dictation) }
        #expect(try queue.queuedCount() == 0)
        #expect(try queue.all().isEmpty)
    }

    @Test func fullAtAThousand() throws {
        let queue = temporaryQueue()
        for i in 0..<CaptureQueue.capacity { try queue.add("Capture \(i)", source: .intent) }
        #expect(throws: CaptureQueueError.full) { try queue.add("One more", source: .typed) }
        #expect(try queue.queuedCount() == CaptureQueue.capacity)
    }

    @Test func sameCaptureIdIsSavedOnce() throws {
        let queue = temporaryQueue()
        let id = UUID()
        try queue.add("Once", source: .intent, id: id)
        try queue.add("Once", source: .intent, id: id)
        #expect(try queue.queuedCount() == 1)
    }

    /// The app and its extensions are separate processes, each with its own connection to the
    /// file: two queues on one file, writing at the same time, then a third reading.
    @Test func sharedBetweenConnectionsWritingAtOnce() async throws {
        let app = temporaryQueue()
        let share = CaptureQueue(url: app.url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (queue, source) in [(app, CaptureSource.typed), (share, .share)] {
                group.addTask {
                    for i in 0..<100 { try queue.add("\(source.rawValue) \(i)", source: source) }
                }
            }
            try await group.waitForAll()
        }
        let later = CaptureQueue(url: app.url)
        let all = try later.all()
        #expect(all.count == 200)
        #expect(Set(all.map(\.id)).count == 200)
        #expect(all.filter { $0.source == .share }.count == 100)
    }

    /// Another process writes the file (the `sqlite3` tool, standing in for the share extension)
    /// and reads what the app wrote.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3")))
    func sharedWithAnotherProcess() throws {
        let queue = temporaryQueue()
        let mine = try queue.add("From the app", source: .typed, now: t0)
        let theirs = UUID()
        try sqlite3(queue.url, """
            INSERT INTO capture (capture_id, text, created_at, source) VALUES ('\(theirs.uuidString)', 'From the extension', \(t0.timeIntervalSince1970 + 1), 'share');
            """)
        #expect(try queue.all().map(\.id) == [theirs, mine.id])
        #expect(try queue.nextBatch().map(\.text) == ["From the app", "From the extension"])
        try queue.remove([mine.id])
        #expect(try sqlite3(queue.url, "SELECT text FROM capture;") == "From the extension\n")
    }

    @Test func batchIsTheOldestFifty() throws {
        let queue = temporaryQueue()
        let ids: [UUID] = try (0..<120).map { i in try queue.add("Capture \(i)", source: .typed, now: t0.addingTimeInterval(Double(i))).id }
        #expect(try queue.nextBatch().map(\.id) == Array(ids.prefix(50)))
    }

    /// Long captures split earlier, so a call stays under the Mac's 256 KiB.
    @Test func batchStaysUnderTheByteBudget() throws {
        let queue = temporaryQueue()
        for i in 0..<30 { try queue.add(String(repeating: "é", count: 9_000) + "\(i)", source: .share, now: t0.addingTimeInterval(Double(i))) }
        let batch = try queue.nextBatch()
        #expect(batch.count == 8)
        let body = try JSONEncoder().encode(CapturesSubmitParams(captures: batch.map(\.wire)))
        #expect(body.count <= CaptureQueue.batchBytes)
        // A capture is always sent, even alone over the budget.
        let big = QueuedCapture(id: UUID(), text: String(repeating: "x", count: 500), createdAt: t0, source: .typed, attempts: 0, state: .queued)
        #expect(CaptureQueue.fitting([big, big], bytes: 10).count == 1)
    }

    @Test func attemptsRejectionsAndRemoval() throws {
        let queue = temporaryQueue()
        let a = try queue.add("A", source: .typed, now: t0).id
        let b = try queue.add("B", source: .typed, now: t0.addingTimeInterval(1)).id
        let c = try queue.add("C", source: .typed, now: t0.addingTimeInterval(2)).id
        try queue.recordAttempt([a, b, c], at: t0.addingTimeInterval(10))
        try queue.reject([CaptureRejection(captureId: a, reason: .invalidInput), CaptureRejection(captureId: b, reason: .rateLimited)])
        try queue.remove([c])
        let all = try queue.all()
        #expect(all.map(\.id) == [b, a])
        #expect(all[1].state == .rejected(.invalidInput))
        #expect(all[0].state == .queued)
        #expect(all.allSatisfy { $0.attempts == 1 && $0.lastAttemptAt == t0.addingTimeInterval(10) })
        // Turned down for good: not sent again, not counted as waiting.
        #expect(try queue.nextBatch().map(\.id) == [b])
        #expect(try queue.queuedCount() == 1)
        try queue.deleteAll()
        #expect(try queue.all().isEmpty)
    }

    @Test func unwritableFolderIsAStorageError() {
        let queue = CaptureQueue(url: URL(filePath: "/dev/null/queue/capture-queue.sqlite"))
        #expect(throws: CaptureQueueError.storage) { try queue.add("Text", source: .typed) }
    }

    @discardableResult
    private func sqlite3(_ url: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = ["-cmd", ".timeout 5000", url.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

@Suite struct CaptureLaunchTests {
    @Test func takesAFreshRequestOnce() {
        let suite = "funes-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let launch = CaptureLaunch(suiteName: suite)
        #expect(!launch.take(now: t0))
        launch.request(now: t0)
        #expect(launch.take(now: t0.addingTimeInterval(2)))
        #expect(!launch.take(now: t0.addingTimeInterval(3)))
        launch.request(now: t0)
        #expect(!launch.take(now: t0.addingTimeInterval(CaptureLaunch.lifetime + 1)))
    }
}
