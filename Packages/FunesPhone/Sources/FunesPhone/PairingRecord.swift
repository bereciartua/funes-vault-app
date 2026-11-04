import CryptoKit
import Foundation
import FunesProtocol

/// What the phone keeps after pairing (§2.2, step 5): the Mac's id, name and public keys, the
/// device id the Mac assigned, and the addresses from the QR code. No secrets: the pairing secret
/// is single use and the device keys are separate items.
public struct PairingRecord: Codable, Sendable, Equatable {
    public var macID: UUID
    public var macName: String
    /// X9.63 public keys, from the QR code.
    public var macSigningKey: Data
    public var macHPKEKey: Data
    public var deviceID: UUID
    public var deviceName: String
    public var addresses: [PairingAddress]
    public var pairedAt: Date
    /// The last name `status.get` said to call the user by (ADR-0026), for Home's title while the
    /// Mac is away. Goes with the record on unpair and revocation.
    public var calledName: String?

    public init(payload: PairingQRPayload, confirmation: PairConfirmation, deviceName: String, pairedAt: Date) {
        macID = payload.macID
        macName = payload.macName
        macSigningKey = payload.macSigningKey
        macHPKEKey = payload.macHPKEKey
        deviceID = confirmation.deviceID
        self.deviceName = deviceName
        addresses = payload.addresses
        self.pairedAt = pairedAt
    }

    public var hpkeKey: P256.KeyAgreement.PublicKey {
        get throws { try P256.KeyAgreement.PublicKey(x963Representation: macHPKEKey) }
    }

    /// The TXT record's `mac` value the paired Mac advertises over Bonjour.
    public var bonjourTag: String { CompanionBonjour.macTag(macID) }
}

/// Keeps the pairing record in a `SecretStore`, next to the device keys.
public struct PairingRecordStore: Sendable {
    static let account = "pairing"

    let store: any SecretStore

    public init(store: any SecretStore) { self.store = store }

    public func load() throws(SecretStoreError) -> PairingRecord? {
        guard let data = try store.read(Self.account) else { return nil }
        return try? CompanionJSON.decoder().decode(PairingRecord.self, from: data)
    }

    public func save(_ record: PairingRecord) throws(SecretStoreError) {
        try store.write((try? CompanionJSON.encoder().encode(record)) ?? Data(), account: Self.account)
    }

    public func delete() throws(SecretStoreError) { try store.delete(Self.account) }
}
