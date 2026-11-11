import Darwin
import Foundation
import FunesProtocol

/// The replay cache's entries on disk (§3, step 3), so a relaunch remembers the nonces of the
/// last 10 minutes instead of trusting the clocks to agree. One file in the Mac's data folder,
/// 0600: a fixed-size record per nonce, appended as each is recorded, and rewritten atomically
/// with only the live entries at launch and whenever it holds twice as many as it needs.
///
/// A record is 48 bytes: the device id (16), the nonce (16), the envelope's `ts` and when the
/// Mac recorded it (milliseconds, 8 each, big-endian). Each append is synced before its call
/// runs. A torn last record (a crash mid-write) is ignored on load and cut off before the next
/// append, and a short or failed append is cut back to the last whole record, so records never
/// drift out of line. Nothing in it is secret: nonces are random and the device ids are the
/// phone's.
struct NonceJournal {
    static let fileName = "companion-nonces"
    static let recordBytes = 48

    enum Failure: Error { case unreadable, unwritable }

    enum Loaded: Equatable {
        /// No journal: a first launch with it, or one deleted. What the last run saw is unknown.
        case missing
        case entries([ReplayCache.Entry])
    }

    let url: URL
    private var appendedSinceRewrite = 0

    init(url: URL) { self.url = url }

    /// The entries recorded since `cutoff`, oldest first, or `missing`. One that exists but can't
    /// be opened as a plain file (a symlink, wrong permissions) or read is `unreadable`.
    func load(since cutoff: Date) throws(Failure) -> Loaded {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return .missing }
            throw .unreadable
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .unreadable }
        let data: Data
        do { data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data() } catch { throw .unreadable }
        var entries: [ReplayCache.Entry] = []
        var offset = data.startIndex
        while offset + Self.recordBytes <= data.endIndex {
            let record = data[offset..<offset + Self.recordBytes]
            offset += Self.recordBytes
            guard let entry = Self.decode(record), entry.recordedAt > cutoff else { continue }
            entries.append(entry)
        }
        return .entries(entries.sorted { $0.recordedAt < $1.recordedAt })
    }

    /// Adds one entry and syncs it; a new file is created 0600. A torn tail is cut off first, and
    /// a short or failed write is cut back, so the file only ever holds whole records.
    mutating func append(_ entry: ReplayCache.Entry) throws(Failure) {
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .unwritable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .unwritable }
        let whole = info.st_size - info.st_size % off_t(Self.recordBytes)
        if whole != info.st_size { guard ftruncate(fd, whole) == 0 else { throw .unwritable } }
        let bytes = Self.encode(entry)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count, fsync(fd) == 0 else {
            _ = ftruncate(fd, whole)
            throw .unwritable
        }
        appendedSinceRewrite += 1
    }

    /// Whether the file holds enough dead entries to be worth rewriting.
    func needsRewrite(live: Int) -> Bool { appendedSinceRewrite > max(1_024, live) }

    /// Replaces the file with `entries`: a temporary file (0600) renamed over it.
    mutating func rewrite(_ entries: [ReplayCache.Entry]) throws(Failure) {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(Self.fileName)-\(UUID().uuidString)")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .unwritable }
        var data = Data(capacity: entries.count * Self.recordBytes)
        for entry in entries { data.append(Self.encode(entry)) }
        let written = data.withUnsafeBytes { $0.count == 0 ? 0 : Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        Darwin.close(fd)
        guard written == data.count, synced, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw .unwritable
        }
        appendedSinceRewrite = 0
    }

    static func encode(_ entry: ReplayCache.Entry) -> Data {
        var data = Data(capacity: recordBytes)
        withUnsafeBytes(of: entry.deviceID.uuid) { data.append(contentsOf: $0) }
        data.append(entry.nonce.prefix(16))
        if entry.nonce.count < 16 { data.append(Data(count: 16 - entry.nonce.count)) }
        for date in [entry.sentAt, entry.recordedAt] {
            var ms = UInt64(bitPattern: Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()) ?? 0).bigEndian
            withUnsafeBytes(of: &ms) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ record: Data) -> ReplayCache.Entry? {
        guard record.count == recordBytes else { return nil }
        let bytes = [UInt8](record)
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        func date(at start: Int) -> Date {
            let raw = bytes[start..<start + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return Date(timeIntervalSince1970: Double(Int64(bitPattern: raw)) / 1000)
        }
        return ReplayCache.Entry(deviceID: id, nonce: Data(bytes[16..<32]), sentAt: date(at: 32), recordedAt: date(at: 40))
    }
}
