import Foundation
import FunesProtocol
import Security

/// Small secrets by name: the device keys and the pairing record. On the iPhone this is the
/// Keychain; tests use `MemorySecretStore`.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws(SecretStoreError) -> Data?
    func write(_ data: Data, account: String) throws(SecretStoreError)
    func delete(_ account: String) throws(SecretStoreError)
}

public enum SecretStoreError: Error, Sendable, Equatable {
    /// A Keychain status other than success or "not found".
    case keychain(OSStatus)
}

/// Generic-password items under `Identifiers.phoneKeychainService`, readable only after the
/// first unlock and never restored to another device (`…AfterFirstUnlockThisDeviceOnly`), in
/// the access group the app and its extensions share.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    /// `<team>.com.funesvault.shared`, or nil for the app's default group.
    public let accessGroup: String?

    public init(service: String = Identifiers.phoneKeychainService, accessGroup: String? = KeychainSecretStore.sharedAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// The shared group, from the `FunesKeychainGroup` Info.plist key, which the build sets to
    /// `$(AppIdentifierPrefix)com.funesvault.shared`. Nil outside a signed app bundle, where the
    /// team prefix is missing.
    public static var sharedAccessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FunesKeychainGroup") as? String,
              group.hasSuffix("." + Identifiers.phoneKeychainGroupSuffix), !group.hasPrefix("$(")
        else { return nil }
        return group
    }

    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func read(_ account: String) throws(SecretStoreError) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw .keychain(status)
        }
    }

    public func write(_ data: Data, account: String) throws(SecretStoreError) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw .keychain(status) }
        let added = SecItemAdd(query(account).merging(attributes) { $1 } as CFDictionary, nil)
        guard added == errSecSuccess else { throw .keychain(added) }
    }

    public func delete(_ account: String) throws(SecretStoreError) {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
    }
}

/// An in-memory store for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(_ account: String) throws(SecretStoreError) -> Data? { lock.withLock { items[account] } }

    public func write(_ data: Data, account: String) throws(SecretStoreError) { lock.withLock { items[account] = data } }

    public func delete(_ account: String) throws(SecretStoreError) { lock.withLock { items[account] = nil } }

    public var accounts: Set<String> { lock.withLock { Set(items.keys) } }
}
