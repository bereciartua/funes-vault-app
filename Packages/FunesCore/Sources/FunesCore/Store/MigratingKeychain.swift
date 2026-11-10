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
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
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
/// Only status codes are logged, never data.
public struct MigratingKeychain: Sendable {
    public let service: String
    let backend: any KeychainBackend

    public init(service: String, backend: any KeychainBackend = SystemKeychain()) {
        self.service = service
        self.backend = backend
    }

    public func read(account: String) throws(KeychainError) -> Data? {
        let modern = backend.read(service: service, account: account, dataProtection: true)
        if modern.status == errSecSuccess, let data = modern.data { return data }
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
            // Only our own copy goes; one that was already there and differs is left alone.
            if added == errSecSuccess { _ = backend.delete(service: service, account: account, dataProtection: true) }
            return
        }
        let deleted = backend.delete(service: service, account: account, dataProtection: false)
        if deleted != errSecSuccess && deleted != errSecItemNotFound {
            logger.error("Keychain migration: the legacy item stayed: \(deleted, privacy: .public)") // log-safe: a status code
        }
    }

    public func write(_ data: Data, account: String) throws(KeychainError) {
        try delete(account: account)
        let added = backend.add(data, service: service, account: account, dataProtection: true)
        if added == errSecSuccess { return }
        logger.error("Data-protection Keychain write: \(added, privacy: .public); using the login keychain") // log-safe: a status code
        let legacy = backend.add(data, service: service, account: account, dataProtection: false)
        guard legacy == errSecSuccess else { throw .status(legacy) }
    }

    public func delete(account: String) throws(KeychainError) {
        let modern = backend.delete(service: service, account: account, dataProtection: true)
        let legacy = backend.delete(service: service, account: account, dataProtection: false)
        let fine: Set<OSStatus> = [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement]
        guard fine.contains(modern) else { throw .status(modern) }
        guard legacy == errSecSuccess || legacy == errSecItemNotFound else { throw .status(legacy) }
    }
}
