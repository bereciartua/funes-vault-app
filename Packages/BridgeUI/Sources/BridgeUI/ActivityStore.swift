import Darwin
import Foundation

// Adapted from EK Bridge's ActivityStore (Upstream/ActivityStore.swift): generic over
// the app's row type, with the retention limits as parameters. The file handling is
// unchanged: append-only JSON Lines, fsync per row, 0600 in a 0700 folder, compaction
// in the background.

/// One Activity row. The app's type holds ids, codes and counts only: never content.
public protocol ActivityRow: Codable, Sendable {
    /// Unique per row; a repeated id gets `#2`, `#3`… appended.
    var rowID: String { get set }
    var at: Date { get }
    /// `start`, `result` or `event`.
    var phase: String { get }
    /// Joins a start row to its result.
    var requestID: String? { get }
    /// Kept longer: changes, refusals, approvals.
    var isImportant: Bool { get }
}

/// How long Activity keeps a row. EK Bridge: 90 days or 5,000 important rows, 7 days or 2,000
/// others. Funes: 400 days or 20,000 important rows (`.funes`).
public struct ActivityRetention: Sendable, Equatable {
    public var importantAge: TimeInterval
    public var importantLimit: Int
    public var routineAge: TimeInterval
    public var routineLimit: Int
    public var startAge: TimeInterval

    public init(importantAge: TimeInterval, importantLimit: Int, routineAge: TimeInterval, routineLimit: Int,
                startAge: TimeInterval = 86_400) {
        self.importantAge = importantAge
        self.importantLimit = importantLimit
        self.routineAge = routineAge
        self.routineLimit = routineLimit
        self.startAge = startAge
    }

    public static let ekBridge = ActivityRetention(importantAge: 90 * 86_400, importantLimit: 5_000,
                                                   routineAge: 7 * 86_400, routineLimit: 2_000)
    public static let funes = ActivityRetention(importantAge: 400 * 86_400, importantLimit: 20_000,
                                                routineAge: 30 * 86_400, routineLimit: 5_000)

    /// `records` oldest first; the result keeps that order. A start row is kept only while its
    /// request hasn't finished, and for at most `startAge`.
    public func keep<Row: ActivityRow>(_ records: [Row], now: Date) -> [Row] {
        let finished = Set(records.compactMap { $0.phase == "start" ? nil : $0.requestID })
        var importantLeft = importantLimit
        var routineLeft = routineLimit
        var kept = [Row]()
        kept.reserveCapacity(min(records.count, importantLimit + routineLimit))
        // Newest first, so the limits drop the oldest rows.
        for record in records.reversed() {
            let age = now.timeIntervalSince(record.at)
            if record.phase == "start" {
                guard age < startAge, let request = record.requestID, !finished.contains(request)
                else { continue }
                kept.append(record)
            } else if record.isImportant {
                guard age < importantAge, importantLeft > 0 else { continue }
                importantLeft -= 1
                kept.append(record)
            } else {
                guard age < routineAge, routineLeft > 0 else { continue }
                routineLeft -= 1
                kept.append(record)
            }
        }
        return kept.reversed()
    }
}

/// `<data>/activity/activity.jsonl`: append-only JSON Lines, one
/// row per line, 0600 in a 0700 folder.
///
/// Activity is a log, not a security decision, so it doesn't fail closed: an
/// unreadable line is skipped and counted.
///
/// Thread-safe. Compaction runs on a background queue and rows appended
/// meanwhile go to both files.
public final class ActivityStore<Record: ActivityRow>: @unchecked Sendable {
    public static var folderName: String { "activity" }
    public static var fileName: String { "activity.jsonl" }
    /// Only the newest 16 MB are read at launch.
    static var maxReadBytes: Int { 16 << 20 }
    /// Compact when the file grows past this, and at least every 6 hours.
    static var compactBytes: Int { 8 << 20 }
    static var compactInterval: TimeInterval { 6 * 3_600 }

    public let folder: URL
    public let file: URL
    private var retention: ActivityRetention
    private let now: @Sendable () -> Date
    private let autoCompact: Bool
    private let sync: @Sendable (Int32) -> Int32
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ActivityStore.compaction", qos: .utility)

    private var loaded = false
    private var rows = [Record]()
    private var ids = Set<String>()
    private var descriptor: Int32 = -1
    private var fileBytes = 0
    private var compacting = false
    private var appendedWhileCompacting = [Record]()
    private var lastCompaction: Date?
    /// Lines skipped at load because they didn't decode.
    private(set) var invalidLines = 0

    /// `dataFolder` is the app's data folder; the store uses `activity/` in it.
    /// `sync` is `fsync`, injectable to test a failing disk.
    public init(dataFolder: URL, retention: ActivityRetention, now: @escaping @Sendable () -> Date = Date.init,
                autoCompact: Bool = false, sync: @escaping @Sendable (Int32) -> Int32 = { fsync($0) }) {
        folder = dataFolder.appendingPathComponent(Self.folderName, isDirectory: true)
        file = folder.appendingPathComponent(Self.fileName)
        self.retention = retention
        self.now = now
        self.autoCompact = autoCompact
        self.sync = sync
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// The limits compaction keeps to; a change applies from the next compaction, which this
    /// schedules (Settings ▸ Advanced).
    public func setRetention(_ retention: ActivityRetention) {
        lock.lock()
        self.retention = retention
        lock.unlock()
        scheduleCompaction()
    }

    /// Every kept row, oldest first.
    public func records() -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return rows
    }

    public func contains(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return ids.contains(id)
    }

    public var skippedLines: Int {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return invalidLines
    }

    /// Appends and syncs one row; false when it couldn't be written.
    @discardableResult
    public func append(_ record: Record) -> Bool {
        lock.lock()
        loadIfNeeded()
        var record = record
        // Request IDs are unique per connection, but a reused one (or a
        // second row in the same phase) must still get its own row ID.
        if ids.contains(record.rowID) {
            var ordinal = 2
            while ids.contains("\(record.rowID)#\(ordinal)") { ordinal += 1 }
            record.rowID = "\(record.rowID)#\(ordinal)"
        }
        guard let line = Self.encode(record), openForAppend() else {
            lock.unlock()
            return false
        }
        // A write that fails partway (a full disk) or isn't synced is taken
        // back, so a torn line can't swallow the next row.
        let end = lseek(descriptor, 0, SEEK_END)
        guard end >= 0, write(line, to: descriptor) else {
            if end >= 0 { ftruncate(descriptor, end) }
            lock.unlock()
            return false
        }
        fileBytes += line.count
        rows.append(record)
        ids.insert(record.rowID)
        if compacting { appendedWhileCompacting.append(record) }
        let due = autoCompact && !compacting && (fileBytes > Self.compactBytes ||
            lastCompaction.map { now().timeIntervalSince($0) >= Self.compactInterval } ?? true)
        lock.unlock()
        if due { scheduleCompaction() }
        return true
    }

    /// Compacts in the background (at launch, and when `append` finds it due).
    public func scheduleCompaction() {
        queue.async { [weak self] in _ = self?.compact() }
    }

    /// Rewrites the file with only the rows `ActivityRetention` keeps. Rows
    /// appended meanwhile are added to the new file before it replaces the old.
    @discardableResult
    public func compact() -> Bool {
        lock.lock()
        loadIfNeeded()
        guard !compacting else { lock.unlock(); return false }
        compacting = true
        appendedWhileCompacting = []
        let snapshot = rows
        let at = now()
        let limits = retention
        lock.unlock()

        let kept = limits.keep(snapshot, now: at)
        var data = Data()
        for record in kept { if let line = Self.encode(record) { data.append(line) } }
        let temporary = folder.appendingPathComponent(Self.fileName + ".tmp")
        unlink(temporary.path)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var ok = fd >= 0 && write(data, to: fd)

        lock.lock()
        defer {
            compacting = false
            appendedWhileCompacting = []
            lock.unlock()
        }
        var tail = Data()
        for record in appendedWhileCompacting { if let line = Self.encode(record) { tail.append(line) } }
        ok = ok && write(tail, to: fd) && sync(fd) == 0
        if fd >= 0 { close(fd) }
        guard ok, Darwin.rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        syncFolder()
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        rows = kept + appendedWhileCompacting
        ids = Set(rows.map(\.rowID))
        fileBytes = data.count + tail.count
        lastCompaction = at
        return true
    }

    // MARK: File

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func encode(_ record: Record) -> Data? {
        guard var data = try? encoder().encode(record) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Reads the newest `maxReadBytes` of the file. Caller holds the lock.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { return }
        let size = Int(info.st_size)
        fileBytes = size
        let skip = max(0, size - Self.maxReadBytes)
        if skip > 0 { lseek(fd, off_t(skip), SEEK_SET) }
        guard var data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            .read(upToCount: Self.maxReadBytes) else { return }
        // Starting mid-file: drop the partial first line.
        if skip > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        let decoder = Self.decoder()
        var seen = Set<String>()
        var loadedRows = [Record]()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(Record.self, from: line),
                  !seen.contains(record.rowID) else {
                invalidLines += 1
                continue
            }
            seen.insert(record.rowID)
            loadedRows.append(record)
        }
        rows = loadedRows
        ids = seen
    }

    /// Opens the file for appending, creating the folder (0700) and file
    /// (0600). Refuses links and files owned by someone else. Caller holds the lock.
    private func openForAppend() -> Bool {
        if descriptor >= 0 { return true }
        // The data folder too, if it isn't there yet.
        let parent = folder.deletingLastPathComponent().path
        if mkdir(parent, 0o700) != 0 && errno != EEXIST { return false }
        if mkdir(folder.path, 0o700) != 0 && errno != EEXIST { return false }
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR else { return false }
        if info.st_mode & 0o077 != 0 { chmod(folder.path, 0o700) }
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return false
        }
        if info.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }
        descriptor = fd
        return true
    }

    private func write(_ data: Data, to fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        if data.isEmpty { return true }
        let written = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        // Appends sync themselves; compaction syncs once at the end.
        return written && (fd != descriptor || sync(fd) == 0)
    }

    private func syncFolder() {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = sync(fd)
        close(fd)
    }
}
