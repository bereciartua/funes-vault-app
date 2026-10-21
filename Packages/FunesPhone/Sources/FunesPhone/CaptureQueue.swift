import Foundation
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "queue")

/// A capture waiting on this iPhone for the Mac, or one the Mac turned down.
public struct QueuedCapture: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case queued
        /// The Mac won't take it, whatever the retry (`invalid_input`, `secret_like_content`): kept
        /// until the user deletes it.
        case rejected(CompanionErrorCode)
    }

    /// The `captureId`: given once, when the capture is queued, so every resend is the same capture.
    public var id: UUID
    public var text: String
    public var note: String?
    public var createdAt: Date
    public var source: CaptureSource
    public var attempts: Int
    public var lastAttemptAt: Date?
    public var state: State

    public var wire: CompanionCapture { CompanionCapture(captureId: id, text: text, createdAt: createdAt, source: source, note: note) }
}

/// Why a capture wasn't queued, or the queue couldn't be read.
public enum CaptureQueueError: Error, Sendable, Equatable {
    case empty
    /// Over 10,000 characters, the note included: the Mac would refuse it.
    case tooLong
    /// The secret scanner matched (the same rules as the Mac's): nothing was saved.
    case secret([SecretPattern])
    /// 1,000 captures are already waiting: "Queue full: connect to your Mac."
    case full
    /// The App Group container or the database failed.
    case storage
}

/// The offline capture queue (companion protocol §6): a SQLite file in the App Group container,
/// shared by the app, the share extension and the App Intents. Extensions only add; the app
/// delivers (`CaptureDelivery`) and deletes a capture only once the Mac has accepted it.
///
/// Each call opens its own connection and closes it, so the app and its extensions can use the
/// file at the same time, and nothing holds a lock while the app is suspended.
public final class CaptureQueue: Sendable {
    public static let capacity = 1_000
    public static let fileName = "capture-queue.sqlite"
    /// The JSON size of one call's captures. The Mac reads at most 256 KiB of envelope, and the
    /// ciphertext grows by a third in base64.
    public static let batchBytes = 150_000
    /// Mac-side reasons that a later try may get past.
    static let transientRejections: Set<CompanionErrorCode> = [.rateLimited, .unavailable, .internalError]

    public let url: URL

    /// The queue at `url`, created on first use.
    public init(url: URL) { self.url = url }

    /// The queue the app and its extensions share, in the App Group container.
    public static func appGroup() throws(CaptureQueueError) -> CaptureQueue {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Identifiers.appGroup) else {
            logger.error("No App Group container")
            throw .storage
        }
        return CaptureQueue(url: container.appending(path: "CaptureQueue", directoryHint: .isDirectory).appending(path: fileName))
    }

    // MARK: Adding

    /// Checks a capture the way `add` will, without saving it: trimmed text and note, or why not.
    public static func check(_ text: String, note: String? = nil) throws(CaptureQueueError) -> (text: String, note: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !text.isEmpty else { throw .empty }
        // The Mac stores text and note together, joined by a blank line.
        let length = InputLimits.length(of: text) + (note.map { InputLimits.length(of: $0) + 2 } ?? 0)
        guard length <= InputLimits.body.upperBound else { throw .tooLong }
        let found = SecretScanner.scan([text, note ?? ""])
        guard found.isEmpty else { throw .secret(found) }
        return (text, note)
    }

    /// Scans and saves a capture. Saved is the user-visible success; delivery comes after.
    @discardableResult
    public func add(_ text: String, note: String? = nil, source: CaptureSource, id: UUID = UUID(),
                    now: Date = Date()) throws(CaptureQueueError) -> QueuedCapture {
        let (text, note) = try Self.check(text, note: note)
        let capture = QueuedCapture(id: id, text: text, note: note, createdAt: now, source: source, attempts: 0, lastAttemptAt: nil,
                                    state: .queued)
        let saved = try database { db throws(SQLiteError) in
            try db.transaction { () throws(SQLiteError) -> Bool in
                guard try db.scalar("SELECT count(*) FROM capture") < Self.capacity else { return false }
                try db.run("""
                    INSERT OR IGNORE INTO capture (capture_id, text, note, created_at, source, attempts, state)
                    VALUES (?, ?, ?, ?, ?, 0, 'queued')
                    """, [.text(id.uuidString), .text(text), SQLiteValue(note), SQLiteValue(now), .text(source.rawValue)])
                return true
            }
        }
        guard saved else { throw .full }
        logger.info("Queued a capture from \(source.rawValue, privacy: .public)") // log-safe: the source kind, not the text
        return capture
    }

    // MARK: Reading

    /// Captures waiting to be sent (not those the Mac turned down).
    public func queuedCount() throws(CaptureQueueError) -> Int {
        try database { db throws(SQLiteError) in Int(try db.scalar("SELECT count(*) FROM capture WHERE state = 'queued'")) }
    }

    /// Everything on this iPhone, newest first: waiting and turned down.
    public func all(limit: Int = capacity) throws(CaptureQueueError) -> [QueuedCapture] {
        try database { db throws(SQLiteError) in
            try Self.select(db, "ORDER BY created_at DESC, rowid DESC LIMIT ?", [.int(Int64(limit))])
        }
    }

    /// The next call's captures: the oldest waiting ones, at most 50 and `batchBytes` of JSON
    /// (always at least one).
    public func nextBatch() throws(CaptureQueueError) -> [QueuedCapture] {
        let candidates = try database { db throws(SQLiteError) in
            try Self.select(db, "WHERE state = 'queued' ORDER BY created_at, rowid LIMIT ?", [.int(Int64(CompanionProtocol.maxCapturesPerCall))])
        }
        return Self.fitting(candidates, bytes: Self.batchBytes)
    }

    static func fitting(_ captures: [QueuedCapture], bytes budget: Int) -> [QueuedCapture] {
        let encoder = JSONEncoder()
        var batch: [QueuedCapture] = [], used = 0
        for capture in captures {
            // A few bytes more for the separator and the encoder's date format.
            let size = ((try? encoder.encode(capture.wire))?.count ?? budget) + 16
            guard batch.isEmpty || used + size <= budget else { break }
            batch.append(capture)
            used += size
        }
        return batch
    }

    // MARK: Delivery bookkeeping

    /// One more try for each, at `date`.
    public func recordAttempt(_ ids: [UUID], at date: Date) throws(CaptureQueueError) {
        try update(ids, "UPDATE capture SET attempts = attempts + 1, last_attempt_at = ? WHERE capture_id = ?", [SQLiteValue(date)])
    }

    /// The Mac accepted these (or already had them): they're gone from the phone.
    public func remove(_ ids: [UUID]) throws(CaptureQueueError) {
        try update(ids, "DELETE FROM capture WHERE capture_id = ?")
    }

    /// The Mac turned these down. Those a later try may get past stay queued.
    public func reject(_ rejections: [CaptureRejection]) throws(CaptureQueueError) {
        let final = rejections.filter { !Self.transientRejections.contains($0.reason) }
        guard !final.isEmpty else { return }
        try database { db throws(SQLiteError) in
            try db.transaction { () throws(SQLiteError) in
                for rejection in final {
                    try db.run("UPDATE capture SET state = 'rejected', reject_reason = ? WHERE capture_id = ?",
                               [.text(rejection.reason.rawValue), .text(rejection.captureId.uuidString)])
                }
            }
        }
    }

    /// "Delete queued captures…", and unpairing.
    public func deleteAll() throws(CaptureQueueError) {
        try database { db throws(SQLiteError) in try db.execute("DELETE FROM capture") }
    }

    // MARK: Database

    private func update(_ ids: [UUID], _ sql: String, _ leading: [SQLiteValue] = []) throws(CaptureQueueError) {
        guard !ids.isEmpty else { return }
        try database { db throws(SQLiteError) in
            try db.transaction { () throws(SQLiteError) in
                for id in ids { try db.run(sql, leading + [.text(id.uuidString)]) }
            }
        }
    }

    private static func select(_ db: SQLiteConnection, _ tail: String, _ bindings: [SQLiteValue]) throws(SQLiteError) -> [QueuedCapture] {
        var captures: [QueuedCapture] = []
        try db.run("""
            SELECT capture_id, text, note, created_at, source, attempts, last_attempt_at, state, reject_reason
            FROM capture \(tail)
            """, bindings) { row in
            guard let id = row.text(0).flatMap(UUID.init(uuidString:)), let text = row.text(1), let createdAt = row.date(3),
                  let source = row.text(4).flatMap(CaptureSource.init(rawValue:))
            else { return }
            let state: QueuedCapture.State = row.text(7) == "rejected"
                ? .rejected(row.text(8).flatMap(CompanionErrorCode.init(rawValue:)) ?? .invalidInput)
                : .queued
            captures.append(QueuedCapture(id: id, text: text, note: row.text(2), createdAt: createdAt, source: source,
                                          attempts: Int(row.int(5)), lastAttemptAt: row.date(6), state: state))
        }
        return captures
    }

    private func database<T>(_ body: (SQLiteConnection) throws(SQLiteError) -> T) throws(CaptureQueueError) -> T {
        do {
            return try body(try open())
        } catch {
            logger.error("Capture queue: \(error.description, privacy: .public)") // log-safe: a SQLite code and message, no rows
            throw .storage
        }
    }

    private func open() throws(SQLiteError) -> SQLiteConnection {
        let directory = url.deletingLastPathComponent()
        let fresh = !FileManager.default.fileExists(atPath: url.path)
        if fresh {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: Self.protection)
            } catch {
                throw SQLiteError(code: -1, message: "couldn't create the queue's folder")
            }
        }
        let db = try SQLiteConnection(path: url.path)
        try db.execute(Self.schema)
        if fresh, let protection = Self.protection {
            // Readable in the background once the phone has been unlocked once since boot, so a
            // background refresh can deliver (§6).
            try? FileManager.default.setAttributes(protection, ofItemAtPath: url.path)
        }
        return db
    }

    private static var protection: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        nil
        #endif
    }

    static let schema = """
        CREATE TABLE IF NOT EXISTS capture (
          capture_id      TEXT PRIMARY KEY,
          text            TEXT NOT NULL,
          note            TEXT,
          created_at      REAL NOT NULL,
          source          TEXT NOT NULL,
          attempts        INTEGER NOT NULL DEFAULT 0,
          last_attempt_at REAL,
          state           TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'rejected')),
          reject_reason   TEXT
        );
        CREATE INDEX IF NOT EXISTS capture_state_created ON capture (state, created_at);
        """
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
