import CryptoKit
import Foundation
import FunesProtocol
import Security

/// The Mac's companion identity (§1): its id, a P-256 signing key for pairing confirmations and a
/// P-256 HPKE key every phone request is sealed to. Created once, kept in the Keychain.
public struct MacIdentity: Sendable {
    public let macID: UUID
    public let signingKey: P256.Signing.PrivateKey
    public let hpkeKey: P256.KeyAgreement.PrivateKey

    public init(macID: UUID = UUID(), signingKey: P256.Signing.PrivateKey = .init(),
                hpkeKey: P256.KeyAgreement.PrivateKey = .init()) {
        self.macID = macID
        self.signingKey = signingKey
        self.hpkeKey = hpkeKey
    }

    struct Stored: Codable {
        var macID: UUID
        var signing: Data
        var hpke: Data
    }

    var stored: Stored { Stored(macID: macID, signing: signingKey.rawRepresentation, hpke: hpkeKey.rawRepresentation) }

    init(_ stored: Stored) throws {
        macID = stored.macID
        signingKey = try P256.Signing.PrivateKey(rawRepresentation: stored.signing)
        hpkeKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: stored.hpke)
    }
}

public protocol MacIdentityStore: Sendable {
    func load() throws -> MacIdentity?
    func save(_ identity: MacIdentity) throws
    func delete() throws
}

extension MacIdentityStore {
    /// The saved identity, or a new one saved now.
    public func loadOrCreate() throws -> MacIdentity {
        if let identity = try load() { return identity }
        let identity = MacIdentity()
        try save(identity)
        return identity
    }
}

/// `kSecClassGenericPassword`, service `com.funesvault.companion` (`.dev` for a development
/// vault), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it never moves to another Mac.
public struct KeychainMacIdentityStore: MacIdentityStore {
    public static let account = "mac-identity"
    public let service: String

    public init(service: String = Identifiers.companionKeychainService) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    public func load() throws -> MacIdentity? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw CompanionKeychainError.status(status) }
        return try MacIdentity(JSONDecoder().decode(MacIdentity.Stored.self, from: data))
    }

    public func save(_ identity: MacIdentity) throws {
        try delete()
        var q = query
        q[kSecValueData as String] = try JSONEncoder().encode(identity.stored)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw CompanionKeychainError.status(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CompanionKeychainError.status(status) }
    }
}

public enum CompanionKeychainError: Error, Equatable { case status(OSStatus) }

/// For tests.
public final class InMemoryMacIdentityStore: MacIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: MacIdentity?

    public init(_ identity: MacIdentity? = nil) { self.identity = identity }

    public func load() throws -> MacIdentity? { lock.withLock { identity } }
    public func save(_ identity: MacIdentity) throws { lock.withLock { self.identity = identity } }
    public func delete() throws { lock.withLock { identity = nil } }
}
