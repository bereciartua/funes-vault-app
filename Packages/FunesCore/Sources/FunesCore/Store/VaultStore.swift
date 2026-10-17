import Foundation
import FunesProtocol
import GRDB

/// The vault database (spec/architecture/storage.md): a GRDB `DatabasePool` in WAL mode, migrated
/// forward on open. Services run their multi-step flows in one write transaction on `writer`
/// (NFR-REL-01); the methods here are the store-level CRUD that enforces the memory invariants.
public final class VaultStore: Sendable {
    public let writer: DatabasePool
    public let path: URL

    public static let fileName = "vault.sqlite"

    /// Opens `vault.sqlite` in `directory`, creating the folder (0700) and file (0600) when missing.
    /// Fails closed on a folder or file that is a symlink, owned by someone else or readable by
    /// others (storage §1). Backs up before pending migrations of an existing vault.
    public static func open(directory: URL) throws -> VaultStore {
        try FileSafety.prepareDirectory(directory)
        let file = directory.appending(path: fileName)
        try FileSafety.prepareFile(file)
        return try VaultStore(path: file, backupsDirectory: directory.appending(path: "Backups", directoryHint: .isDirectory))
    }

    /// Opens (or creates) the database at `path` without the folder checks; tests use this.
    public init(path: URL, backupsDirectory: URL? = nil) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: path.path, configuration: config)
        let migrator = Schema.migrator
        try pool.read { db in
            if try migrator.hasBeenSuperseded(db) { throw VaultError.newerSchema }
        }
        let pending = try pool.read { db in
            (try migrator.appliedIdentifiers(db).isEmpty == false, try !migrator.hasCompletedMigrations(db))
        }
        if pending.0, pending.1, let backupsDirectory {
            let applied = try pool.read { db in try migrator.appliedIdentifiers(db) }
            let label = migrator.migrations.first { !applied.contains($0) } ?? "migration"
            try Self.backup(pool, into: backupsDirectory, name: "pre-\(label)-\(Self.stamp(Date()))")
        }
        try migrator.migrate(pool)
        writer = pool
        self.path = path
    }

    // MARK: - Backups

    /// An online backup to `url` (GRDB `backup(to:)`), safe while the vault is in use.
    public func backup(to url: URL) throws {
        let destination = try DatabaseQueue(path: url.path)
        try writer.backup(to: destination)
        try destination.close()
        _ = chmod(url.path, 0o600)
    }

    /// The daily backup: `Backups/vault-YYYYMMDD-HHMM.sqlite`, keeping the newest `keep`.
    @discardableResult
    public func dailyBackup(into directory: URL, now: Date, keep: Int = 7) throws -> URL {
        let url = try Self.backup(writer, into: directory, name: "vault-\(Self.stamp(now))")
        let fm = FileManager.default
        let backups = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("vault-") && $0.hasSuffix(".sqlite") }
            .sorted()
        for old in backups.dropLast(keep) {
            try fm.removeItem(at: directory.appending(path: old))
        }
        return url
    }

    @discardableResult
    private static func backup(_ pool: DatabasePool, into directory: URL, name: String) throws -> URL {
        try FileSafety.prepareDirectory(directory)
        let url = directory.appending(path: "\(name).sqlite")
        let destination = try DatabaseQueue(path: url.path)
        try pool.backup(to: destination)
        try destination.close()
        _ = chmod(url.path, 0o600)
        return url
    }

    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d%02d%02d-%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    /// Restore from Backup (FR-G-04), run before the vault opens: the current vault is first saved
    /// as `Backups/pre-restore-<time>.sqlite` with SQLite's online backup, so transactions still in
    /// its WAL are in that one self-contained file like every other backup; then `backupName` (a
    /// file in `Backups/`) replaces `vault.sqlite`, and the old WAL and shared-memory files go.
    /// Nothing changes if the snapshot fails. Returns the snapshot's URL (nil without a vault).
    @discardableResult
    public static func restoreBackup(_ backupName: String, in directory: URL, now: Date) throws -> URL? {
        guard !backupName.contains("/"), backupName.hasSuffix(".sqlite") else { throw VaultError.invalidInput(field: "backup") }
        let manager = FileManager.default
        let backups = directory.appending(path: "Backups", directoryHint: .isDirectory)
        let source = backups.appending(path: backupName)
        guard manager.fileExists(atPath: source.path) else { throw VaultError.notFound }
        let current = directory.appending(path: fileName)
        var snapshot: URL?
        if manager.fileExists(atPath: current.path) {
            try FileSafety.prepareDirectory(backups)
            let url = backups.appending(path: "pre-restore-\(stamp(now))-\(Int(now.timeIntervalSince1970) % 60).sqlite")
            let from = try DatabaseQueue(path: current.path)
            let to = try DatabaseQueue(path: url.path)
            try from.backup(to: to)
            try to.close()
            try from.close()
            _ = chmod(url.path, 0o600)
            snapshot = url
        }
        // The copy goes in under a temporary name first, so a failed copy leaves the vault as it was.
        let incoming = directory.appending(path: fileName + ".restoring")
        try? manager.removeItem(at: incoming)
        try manager.copyItem(at: source, to: incoming)
        _ = chmod(incoming.path, 0o600)
        for suffix in ["", "-wal", "-shm"] {
            let file = directory.appending(path: fileName + suffix)
            if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
        }
        try manager.moveItem(at: incoming, to: current)
        return snapshot
    }

    // MARK: - Meta

    public func meta(_ key: String) throws -> String? {
        try writer.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    /// `PRAGMA quick_check` (the weekly integrity job).
    public func quickCheck() throws -> Bool {
        try writer.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" }
    }
}

/// Ownership and mode checks for the vault folder and files (storage §1, EK Bridge's pattern).
enum FileSafety {
    static func prepareDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw VaultError.unsafeFile(url.lastPathComponent) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw VaultError.unsafeFile(url.lastPathComponent) }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw VaultError.unsafeFile(url.lastPathComponent)
        }
    }

    static func prepareFile(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultError.unsafeFile(url.lastPathComponent) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw VaultError.unsafeFile(url.lastPathComponent)
        }
    }
}
