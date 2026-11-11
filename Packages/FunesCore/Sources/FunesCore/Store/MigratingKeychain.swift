import Foundation
import os
import Security

private let logger = Logger(subsystem: "com.funesvault.mac", category: "keychain")

/// The two Keychains a Mac app can use for a generic password (`kSecClassGenericPassword`).
/// The seam `MigratingKeychain` works through, so its migration is tested with a fake.
public protocol KeychainBackend: Sendable {
    /// The item's data, `errSecItemNotFound`, or another status.
    func read(service: String, account: String, dataProtection: Bool) -> (status: OSStatus, data: Data?)
    /// Adds the item, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
    func add(_ data: Data, service: String, account: String, dataProtection: Bool) -> OSStatus
    func delete(service: String, account: String, dataProtection: Bool) -> OSStatus
}

/// The system's Keychain. `dataProtection` adds `kSecUseDataProtectionKeychain`: the
/// data-protection Keychain, where `…ThisDeviceOnly` holds and items never leave this Mac
/// (not with Migration Assistant either). It needs the app signed with an application
/// identifier; unsigned and `swift test` builds get `errSecMissingEntitlement`. Without it, the
/// file-based login keychain, which ignores the accessibility attribute.
public struct SystemKeychain: KeychainBackend {
    public init() {}

    private func query(_ service: String, _ account: String, _ dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        // Said either way: a legacy query that left it out must never match the data-protection
        // item, or deleting the old copy after a migration could delete the new one.
        query[kSecUseDataProtectionKeychain as String] = dataProtection
        return query
    }

    public func read(service: String, account: String, dataProtection: Bool) -> (status: OSStatus, data: Data?) {
        var q = query(service, account, dataProtection)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return (status, out as? Data)
    }

    public func add(_ data: Data, service: String, account: String, dataProtection: Bool) -> OSStatus {
        var q = query(service, account, dataProtection)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil)
    }

    public func delete(service: String, account: String, dataProtection: Bool) -> OSStatus {
        SecItemDelete(query(service, account, dataProtection) as CFDictionary)
    }
}

/// A Keychain item that lives in the data-protection Keychain, moving there from the legacy
/// file-based keychain the first time it's read, without ever losing it:
///
/// - **Read:** the data-protection Keychain first. Not there: the legacy item, which is copied
///   to the data-protection Keychain, read back and compared, and only then deleted. A copy that
///   is refused or doesn't read back the same leaves the legacy item as it was, and it's used.
///   A data-protection Keychain this build can't use (`errSecMissingEntitlement`) means the
///   legacy item, as before. Nil only when neither has it.
/// - **Write:** the data-protection Keychain when it takes it, otherwise the legacy one.
/// - **Delete:** both.
///
/// Every operation runs under one process-wide lock, so a migrating read can't interleave with a
/// write, a delete or another migrating read (a save lost, a deleted key brought back, both
/// copies gone). A legacy item whose delete failed is deleted again on a later read, once per
/// account for each instance. Only status codes are logged, never data.
public struct MigratingKeychain: Sendable {
    public let service: String
    let backend: any KeychainBackend
    private let cleaned = Cleaned()

    /// One process, one Keychain: every instance's operations take turns.
    private static let lock = NSLock()

    /// The accounts whose legacy item this instance has already made sure is gone.
    private final class Cleaned: @unchecked Sendable {
        private var accounts: Set<String> = []
        /// True the first time for `account` (called under `lock`).
        func first(_ account: String) -> Bool { accounts.insert(account).inserted }
    }

    public init(service: String, backend: any KeychainBackend = SystemKeychain()) {
        self.service = service
        self.backend = backend
    }

    public func read(account: String) throws(KeychainError) -> Data? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let modern = backend.read(service: service, account: account, dataProtection: true)
        if modern.status == errSecSuccess, let data = modern.data {
            // A legacy copy whose delete failed after an earlier migration goes now, but only one
            // that's the same key: a different one (written by an older build after a downgrade)
            // stays, shadowed, rather than being deleted unseen.
            if cleaned.first(account) {
                let legacy = backend.read(service: service, account: account, dataProtection: false)
                if legacy.status == errSecSuccess, legacy.data == data {
                    deleteLegacy(account: account)
                } else if legacy.status == errSecSuccess {
                    logger.error("Keychain migration: a different legacy item stays") // log-safe: no key material
                }
            }
            return data
        }
        let usable = modern.status == errSecItemNotFound
        if !usable { logger.error("Data-protection Keychain read: \(modern.status, privacy: .public)") } // log-safe: a status code

        let legacy = backend.read(service: service, account: account, dataProtection: false)
        switch legacy.status {
        case errSecSuccess:
            guard let data = legacy.data else { throw .status(errSecDecode) }
            if usable { migrate(data, account: account) }
            return data
        case errSecItemNotFound:
            // Neither has it. A data-protection Keychain that failed for another reason than "not
            // here" or "not for this build" might still hold it: that's an error, not "none".
            if usable || modern.status == errSecMissingEntitlement { return nil }
            throw .status(modern.status)
        default:
            throw .status(legacy.status)
        }
    }

    /// Copies the legacy item's `data` to the data-protection Keychain, and deletes the legacy
    /// item only once the copy reads back the same.
    private func migrate(_ data: Data, account: String) {
        let added = backend.add(data, service: service, account: account, dataProtection: true)
        guard added == errSecSuccess || added == errSecDuplicateItem else {
            logger.error("Keychain migration: the copy was refused: \(added, privacy: .public)") // log-safe: a status code
            return
        }
        let copy = backend.read(service: service, account: account, dataProtection: true)
        guard copy.status == errSecSuccess, copy.data == data else {
            logger.error("Keychain migration: the copy didn't read back: \(copy.status, privacy: .public)") // log-safe: a status code
            // Only the copy this call made goes (under the lock nothing else can have verified it);
            // one that was already there is left alone.
            if added == errSecSuccess { _ = backend.delete(service: service, account: account, dataProtection: true) }
            return
        }
        // Marked only once it's gone: if this delete fails, the next read tries again.
        if deleteLegacy(account: account) { _ = cleaned.first(account) }
    }

    @discardableResult
    private func deleteLegacy(account: String) -> Bool {
        let deleted = backend.delete(service: service, account: account, dataProtection: false)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            logger.error("Keychain migration: the legacy item stayed: \(deleted, privacy: .public)") // log-safe: a status code
            return false
        }
        return true
    }

    public func write(_ data: Data, account: String) throws(KeychainError) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try deleteBoth(account: account)
        let added = backend.add(data, service: service, account: account, dataProtection: true)
        if added == errSecSuccess { return }
        logger.error("Data-protection Keychain write: \(added, privacy: .public); using the login keychain") // log-safe: a status code
        let legacy = backend.add(data, service: service, account: account, dataProtection: false)
        guard legacy == errSecSuccess else { throw .status(legacy) }
    }

    public func delete(account: String) throws(KeychainError) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try deleteBoth(account: account)
    }

    private func deleteBoth(account: String) throws(KeychainError) {
        let modern = backend.delete(service: service, account: account, dataProtection: true)
        let legacy = backend.delete(service: service, account: account, dataProtection: false)
        let fine: Set<OSStatus> = [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement]
        guard fine.contains(modern) else { throw .status(modern) }
        guard legacy == errSecSuccess || legacy == errSecItemNotFound else { throw .status(legacy) }
    }
}
