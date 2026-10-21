import CryptoKit
import Foundation
import FunesProtocol
import os
import Security

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "keys")

/// The device signing key (companion protocol §1): a Secure Enclave key where there is one, else
/// a software P-256 key kept in the Keychain. Signs every request.
public struct DeviceSigner: CompanionSigner, @unchecked Sendable {
    // @unchecked: CryptoKit's key types are immutable values; the Secure Enclave one just isn't
    // annotated Sendable in every SDK.
    enum Backing {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    let backing: Backing

    public var publicKey: P256.Signing.PublicKey {
        switch backing {
        case let .secureEnclave(key): key.publicKey
        case let .software(key): key.publicKey
        }
    }

    public var isSecureEnclave: Bool {
        if case .secureEnclave = backing { return true }
        return false
    }

    public func signature(for data: Data) throws -> P256.Signing.ECDSASignature {
        switch backing {
        case let .secureEnclave(key): try key.signature(for: data)
        case let .software(key): try key.signature(for: data)
        }
    }

    /// A new key: in the Secure Enclave when `secureEnclave` is true and that works, usable after
    /// the first unlock so background delivery can sign; otherwise in software.
    static func fresh(secureEnclave: Bool) -> DeviceSigner {
        if secureEnclave {
            do {
                var error: Unmanaged<CFError>?
                guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                                   .privateKeyUsage, &error)
                else { throw error!.takeRetainedValue() as Error }
                return DeviceSigner(backing: .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)))
            } catch {
                logger.error("Secure Enclave key failed, using a Keychain key: \(error.localizedDescription, privacy: .public)") // log-safe: a CryptoKit error, no user content
            }
        }
        return DeviceSigner(backing: .software(P256.Signing.PrivateKey()))
    }

    /// What the Keychain keeps: the Secure Enclave's wrapped key blob (usable only by this
    /// device's Secure Enclave) or the software key's raw bytes.
    var stored: Stored {
        switch backing {
        case let .secureEnclave(key): Stored(kind: .secureEnclave, key: key.dataRepresentation)
        case let .software(key): Stored(kind: .software, key: key.rawRepresentation)
        }
    }

    init(backing: Backing) { self.backing = backing }

    init(stored: Stored) throws {
        switch stored.kind {
        case .secureEnclave: backing = .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.key))
        case .software: backing = .software(try P256.Signing.PrivateKey(rawRepresentation: stored.key))
        }
    }

    struct Stored: Codable {
        enum Kind: String, Codable { case secureEnclave = "se", software = "sw" }
        var kind: Kind
        var key: Data
    }
}

/// The device's two keys: the signing key and the HPKE key pairing confirmations are sealed to.
public struct DeviceKeys: Sendable {
    public let signer: DeviceSigner
    public let hpke: P256.KeyAgreement.PrivateKey

    /// Fresh keys, as pairing makes them (§2.2, step 1). Not stored until pairing succeeds.
    public static func fresh(secureEnclave: Bool = SecureEnclave.isAvailable) -> DeviceKeys {
        DeviceKeys(signer: .fresh(secureEnclave: secureEnclave), hpke: P256.KeyAgreement.PrivateKey())
    }

    public init(signer: DeviceSigner, hpke: P256.KeyAgreement.PrivateKey) {
        self.signer = signer
        self.hpke = hpke
    }
}

public enum DeviceKeyError: Error, Sendable, Equatable {
    case store(SecretStoreError)
    /// An item exists but doesn't load, for example a Secure Enclave blob from another device.
    case unreadable
}

/// Keeps the device keys in a `SecretStore` (the Keychain on the iPhone).
public struct DeviceKeyStore: Sendable {
    static let signingAccount = "device-signing"
    static let hpkeAccount = "device-hpke"

    let store: any SecretStore

    public init(store: any SecretStore) { self.store = store }

    /// The saved keys, or nil when this iPhone has none.
    public func load() throws(DeviceKeyError) -> DeviceKeys? {
        let signing: Data?, hpke: Data?
        do {
            signing = try store.read(Self.signingAccount)
            hpke = try store.read(Self.hpkeAccount)
        } catch { throw .store(error) }
        guard let signing, let hpke else { return nil }
        guard let stored = try? JSONDecoder().decode(DeviceSigner.Stored.self, from: signing),
              let signer = try? DeviceSigner(stored: stored),
              let hpkeKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: hpke)
        else { throw .unreadable }
        return DeviceKeys(signer: signer, hpke: hpkeKey)
    }

    public func save(_ keys: DeviceKeys) throws(DeviceKeyError) {
        do {
            try store.write((try? JSONEncoder().encode(keys.signer.stored)) ?? Data(), account: Self.signingAccount)
            try store.write(keys.hpke.rawRepresentation, account: Self.hpkeAccount)
        } catch { throw .store(error) }
    }

    public func delete() throws(DeviceKeyError) {
        do {
            try store.delete(Self.signingAccount)
            try store.delete(Self.hpkeAccount)
        } catch { throw .store(error) }
    }
}
