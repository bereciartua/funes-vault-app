import CryptoKit
import Foundation

/// Signs on behalf of a device or the Mac. On the iPhone this is a Secure Enclave key; elsewhere a
/// software `P256.Signing.PrivateKey`, which conforms as is.
public protocol CompanionSigner: Sendable {
    var publicKey: P256.Signing.PublicKey { get }
    func signature(for data: Data) throws -> P256.Signing.ECDSASignature
}

extension P256.Signing.PrivateKey: CompanionSigner {}

/// What the Mac knows about the device an envelope names (from its `device` table).
public struct CompanionDeviceRecord: Sendable {
    public var id: UUID
    public var signingKey: P256.Signing.PublicKey
    public var isRevoked: Bool

    public init(id: UUID, signingKey: P256.Signing.PublicKey, isRevoked: Bool) {
        self.id = id
        self.signingKey = signingKey
        self.isRevoked = isRevoked
    }
}

/// A request envelope (§3): `{"v":1,"did":…,"ts":…,"nonce":…,"enc":…,"ct":…,"sig":…}`. Every
/// binary field is decoded and size-checked here, so a value of this type is well formed but not
/// yet trusted: `open` does the rest of the verification.
public struct CompanionRequestEnvelope: Sendable, Equatable {
    public let deviceID: UUID
    /// Milliseconds since 1970 on the phone's clock.
    public let timestamp: Int64
    public let nonce: Data
    public let encapsulatedKey: Data
    public let ciphertext: Data
    public let signature: Data

    /// Parses a request body. Anything malformed, oversized or of another version is `invalidEnvelope`.
    public init(body: Data) throws(CompanionAuthError) {
        guard body.count <= CompanionProtocol.maxRequestBytes,
              let wire = try? JSONDecoder().decode(Wire.self, from: body),
              wire.v == CompanionProtocol.version,
              let did = UUID(companionString: wire.did),
              let nonce = Base64URL.decode(wire.nonce), nonce.count == CompanionProtocol.nonceBytes,
              let enc = Base64URL.decode(wire.enc), enc.count == CompanionProtocol.encapsulatedKeyBytes,
              let ct = Base64URL.decode(wire.ct), ct.count >= CompanionProtocol.gcmTagBytes,
              let sig = Base64URL.decode(wire.sig), sig.count == CompanionProtocol.signatureBytes
        else { throw .invalidEnvelope }
        self.init(deviceID: did, timestamp: wire.ts, nonce: nonce, encapsulatedKey: enc, ciphertext: ct, signature: sig)
    }

    init(deviceID: UUID, timestamp: Int64, nonce: Data, encapsulatedKey: Data, ciphertext: Data, signature: Data) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.nonce = nonce
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
        self.signature = signature
    }

    /// The JSON body to POST to `/c/v1/rpc`.
    public var body: Data {
        let wire = Wire(v: CompanionProtocol.version, did: deviceID.companionString, ts: timestamp,
                        nonce: Base64URL.encode(nonce), enc: Base64URL.encode(encapsulatedKey),
                        ct: Base64URL.encode(ciphertext), sig: Base64URL.encode(signature))
        return (try? CompanionJSON.encoder().encode(wire)) ?? Data()
    }

    // MARK: Phone side

    /// Seals and signs `plaintext` (a method request's JSON) for the Mac. Keep the result's
    /// `responseKey` to read the reply.
    public static func seal(_ plaintext: Data, deviceID: UUID, macHPKEKey: P256.KeyAgreement.PublicKey,
                            signer: some CompanionSigner, now: Date = Date(), nonce: Data? = nil) throws -> SealedCompanionRequest {
        let nonce = nonce ?? randomBytes(CompanionProtocol.nonceBytes)
        let ts = now.companionMilliseconds
        var sender = try HPKE.Sender(recipientKey: macHPKEKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                     info: info(deviceID))
        let ct = try sender.seal(plaintext, authenticating: aad(deviceID: deviceID, ts: ts, nonce: nonce))
        let enc = sender.encapsulatedKey
        let toSign = signedBytes(deviceID: deviceID, ts: ts, nonce: nonce, enc: enc, ct: ct)
        let sig = try signer.signature(for: toSign).rawRepresentation
        let envelope = CompanionRequestEnvelope(deviceID: deviceID, timestamp: ts, nonce: nonce, encapsulatedKey: enc,
                                                ciphertext: ct, signature: sig)
        let key = try sender.exportSecret(context: Data(responseContext.utf8), outputByteCount: 32)
        return SealedCompanionRequest(envelope: envelope, responseKey: CompanionResponseKey(key))
    }

    // MARK: Mac side

    /// Verifies the envelope in the spec's order: the device (the caller looks up `deviceID` and
    /// passes what it found, or nil), the clock, the nonce, the signature, then the HPKE open.
    ///
    /// The nonce is remembered only once the signature verifies, so nobody without the device key
    /// can fill the cache and push a real nonce out of it.
    public func open(device: CompanionDeviceRecord?, macHPKEKey: P256.KeyAgreement.PrivateKey,
                     replayCache: inout ReplayCache, now: Date = Date()) throws(CompanionAuthError) -> OpenedCompanionRequest {
        guard let device, device.id == deviceID else { throw .unknownDevice }
        guard !device.isRevoked else { throw .revoked }
        let sent = Date(companionMilliseconds: timestamp)
        guard abs(sent.timeIntervalSince(now)) <= CompanionProtocol.maxClockSkew else { throw .clockSkew(serverTime: now) }
        guard !replayCache.isReplay(nonce: nonce, deviceID: deviceID, sentAt: sent, now: now) else { throw .replay }

        guard let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              device.signingKey.isValidSignature(sig, for: Self.signedBytes(deviceID: deviceID, ts: timestamp, nonce: nonce,
                                                                             enc: encapsulatedKey, ct: ciphertext))
        else { throw .invalidSignature }
        replayCache.record(nonce: nonce, deviceID: deviceID, sentAt: sent, now: now)

        do {
            var recipient = try HPKE.Recipient(privateKey: macHPKEKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                               info: Self.info(deviceID), encapsulatedKey: encapsulatedKey)
            let plaintext = try recipient.open(ciphertext, authenticating: Self.aad(deviceID: deviceID, ts: timestamp, nonce: nonce))
            let key = try recipient.exportSecret(context: Data(Self.responseContext.utf8), outputByteCount: 32)
            return OpenedCompanionRequest(deviceID: deviceID, sentAt: sent, plaintext: plaintext,
                                          responseKey: CompanionResponseKey(key))
        } catch {
            throw .decryptionFailed
        }
    }

    // MARK: Bytes

    static let responseContext = "funes-resp-v1"

    static func info(_ deviceID: UUID) -> Data { Data("funes-companion-v1|\(deviceID.companionString)".utf8) }

    /// `v ‖ did ‖ ts ‖ nonce`.
    static func aad(deviceID: UUID, ts: Int64, nonce: Data) -> Data {
        var t = Transcript("funes-aad-v1")
        t.append(CompanionProtocol.version)
        t.append(deviceID.companionString)
        t.append(ts)
        t.append(nonce)
        return t.bytes
    }

    /// `"funes-req-v1" ‖ v ‖ did ‖ ts ‖ nonce ‖ enc ‖ ct`.
    static func signedBytes(deviceID: UUID, ts: Int64, nonce: Data, enc: Data, ct: Data) -> Data {
        var t = Transcript("funes-req-v1")
        t.append(CompanionProtocol.version)
        t.append(deviceID.companionString)
        t.append(ts)
        t.append(nonce)
        t.append(enc)
        t.append(ct)
        return t.bytes
    }

    private struct Wire: Codable {
        var v: Int
        var did: String
        var ts: Int64
        var nonce: String
        var enc: String
        var ct: String
        var sig: String
    }
}

/// A sealed request and the key that reads its reply.
public struct SealedCompanionRequest: Sendable {
    public let envelope: CompanionRequestEnvelope
    public let responseKey: CompanionResponseKey
}

/// A verified, decrypted request on the Mac. Reply with `responseKey.seal(_:)`.
public struct OpenedCompanionRequest: Sendable {
    public let deviceID: UUID
    public let sentAt: Date
    /// The method request's JSON.
    public let plaintext: Data
    public let responseKey: CompanionResponseKey
}

/// The key exported from a request's HPKE context (`funes-resp-v1`). Only the device that sealed
/// the request and the Mac can derive it, so the reply is bound to that one exchange.
public struct CompanionResponseKey: Sendable {
    let key: SymmetricKey

    init(_ key: SymmetricKey) { self.key = key }

    /// `{"v":1,"n":"<12B nonce>","ct":"<AES-GCM-256(k, n, json)>"}`.
    public func seal(_ json: Data) throws -> Data {
        let box = try AES.GCM.seal(json, using: key, nonce: AES.GCM.Nonce())
        let wire = ResponseWire(v: CompanionProtocol.version, n: Base64URL.encode(Data(box.nonce)),
                                ct: Base64URL.encode(box.ciphertext + box.tag))
        return try CompanionJSON.encoder().encode(wire)
    }

    /// The reply's JSON, or `invalidEnvelope` / `decryptionFailed`.
    public func open(_ body: Data) throws(CompanionAuthError) -> Data {
        guard body.count <= CompanionProtocol.maxResponseBytes,
              let wire = try? JSONDecoder().decode(ResponseWire.self, from: body), wire.v == CompanionProtocol.version,
              let n = Base64URL.decode(wire.n), n.count == CompanionProtocol.responseNonceBytes,
              let ct = Base64URL.decode(wire.ct), ct.count >= CompanionProtocol.gcmTagBytes
        else { throw .invalidEnvelope }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: n), ciphertext: ct.dropLast(CompanionProtocol.gcmTagBytes),
                                            tag: ct.suffix(CompanionProtocol.gcmTagBytes))
            return try AES.GCM.open(box, using: key)
        } catch {
            throw .decryptionFailed
        }
    }

    private struct ResponseWire: Codable {
        var v: Int
        var n: String
        var ct: String
    }
}

func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}
