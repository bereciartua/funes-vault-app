import CryptoKit
import Foundation
import FunesCore
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
/// vault), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, in the data-protection Keychain so
/// it never moves to another Mac. An identity from before is moved there from the login
/// keychain on first read, verified before the old item goes (`MigratingKeychain`); a build that
/// can't use the data-protection Keychain keeps using the old item, so no phone is unpaired.
public struct KeychainMacIdentityStore: MacIdentityStore {
    public static let account = "mac-identity"
    public var service: String { keychain.service }
    let keychain: MigratingKeychain

    public init(service: String = Identifiers.companionKeychainService, backend: any KeychainBackend = SystemKeychain()) {
        keychain = MigratingKeychain(service: service, backend: backend)
    }

    public func load() throws -> MacIdentity? {
        let data: Data?
        do { data = try keychain.read(account: Self.account) } catch { throw CompanionKeychainError(error) }
        guard let data else { return nil }
        return try MacIdentity(JSONDecoder().decode(MacIdentity.Stored.self, from: data))
    }

    public func save(_ identity: MacIdentity) throws {
        let data = try JSONEncoder().encode(identity.stored)
        do { try keychain.write(data, account: Self.account) } catch { throw CompanionKeychainError(error) }
    }

    public func delete() throws {
        do { try keychain.delete(account: Self.account) } catch { throw CompanionKeychainError(error) }
    }
}

public enum CompanionKeychainError: Error, Equatable {
    case status(OSStatus)

    init(_ error: KeychainError) {
        switch error { case let .status(status): self = .status(status) }
    }
}

/// For tests.
public final class InMemoryMacIdentityStore: MacIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: MacIdentity?

    public init(_ identity: MacIdentity? = nil) { self.identity = identity }

    public func load() throws -> MacIdentity? { lock.withLock { identity } }
    public func save(_ identity: MacIdentity) throws { lock.withLock { self.identity = identity } }
    public func delete() throws { lock.withLock { identity = nil } }
}
