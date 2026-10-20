import CryptoKit
import Foundation

/// A way to reach the Mac, as listed in the QR code (§2.1).
public struct PairingAddress: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case lan, tailscale = "ts", tunnel = "tun"
    }

    public var kind: Kind
    public var host: String?
    public var port: UInt16?
    /// The tunnel's public URL, including its secret path prefix.
    public var url: String?

    public init(kind: Kind, host: String? = nil, port: UInt16? = nil, url: String? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.url = url
    }

    enum CodingKeys: String, CodingKey {
        case kind = "t", host, port, url
    }
}

/// What the Mac's QR code carries: its public keys, a single-use secret and its addresses (§2.1).
/// The QR code is the out-of-band trust anchor.
public struct PairingQRPayload: Codable, Sendable, Equatable {
    public var v: Int
    /// The pairing session, 16 random bytes.
    public var pairingID: String
    public var macID: UUID
    public var macName: String
    /// X9.63 public keys.
    public var macSigningKey: Data
    public var macHPKEKey: Data
    /// 32 random bytes. Never leaves the QR code and the Mac.
    public var secret: Data
    /// Seconds since 1970.
    public var expiresAt: Int64
    public var addresses: [PairingAddress]

    public init(pairingID: String, macID: UUID, macName: String, macSigningKey: P256.Signing.PublicKey,
                macHPKEKey: P256.KeyAgreement.PublicKey, secret: Data, expiresAt: Date, addresses: [PairingAddress]) {
        self.v = CompanionProtocol.version
        self.pairingID = pairingID
        self.macID = macID
        self.macName = macName
        self.macSigningKey = macSigningKey.x963Representation
        self.macHPKEKey = macHPKEKey.x963Representation
        self.secret = secret
        self.expiresAt = Int64(expiresAt.timeIntervalSince1970.rounded(.down))
        self.addresses = addresses
    }

    /// A new pairing session's id and secret.
    public static func newSession() -> (pairingID: String, secret: Data) {
        (Base64URL.encode(randomBytes(16)), randomBytes(CompanionProtocol.pairingSecretBytes))
    }

    /// The QR code's text: base64url JSON.
    public var qrString: String {
        Base64URL.encode((try? CompanionJSON.encoder().encode(self)) ?? Data())
    }

    /// Reads a scanned QR code. Nil unless it is a version-1 payload with valid keys and secret.
    public init?(qrString: String) {
        guard qrString.utf8.count <= 4_096, let json = Base64URL.decode(qrString),
              let payload = try? CompanionJSON.decoder().decode(Self.self, from: json),
              payload.v == CompanionProtocol.version, payload.secret.count == CompanionProtocol.pairingSecretBytes,
              (try? P256.Signing.PublicKey(x963Representation: payload.macSigningKey)) != nil,
              (try? P256.KeyAgreement.PublicKey(x963Representation: payload.macHPKEKey)) != nil
        else { return nil }
        self = payload
    }

    public func isExpired(at now: Date) -> Bool { now.timeIntervalSince1970 >= Double(expiresAt) }

    public var signingKey: P256.Signing.PublicKey {
        get throws { try P256.Signing.PublicKey(x963Representation: macSigningKey) }
    }

    public var hpkeKey: P256.KeyAgreement.PublicKey {
        get throws { try P256.KeyAgreement.PublicKey(x963Representation: macHPKEKey) }
    }

    enum CodingKeys: String, CodingKey {
        case v, pairingID = "pid", macID = "mac", macName = "name", macSigningKey = "sig", macHPKEKey = "hpke"
        case secret = "sec", expiresAt = "exp", addresses = "addr"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        pairingID = try c.decode(String.self, forKey: .pairingID)
        guard let mac = UUID(companionString: try c.decode(String.self, forKey: .macID)) else {
            throw DecodingError.dataCorruptedError(forKey: .macID, in: c, debugDescription: "Bad Mac id")
        }
        macID = mac
        macName = try c.decode(String.self, forKey: .macName)
        macSigningKey = try c.decodeBase64URL(.macSigningKey)
        macHPKEKey = try c.decodeBase64URL(.macHPKEKey)
        secret = try c.decodeBase64URL(.secret)
        expiresAt = try c.decode(Int64.self, forKey: .expiresAt)
        addresses = try c.decode([PairingAddress].self, forKey: .addresses)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(pairingID, forKey: .pairingID)
        try c.encode(macID.companionString, forKey: .macID)
        try c.encode(macName, forKey: .macName)
        try c.encode(Base64URL.encode(macSigningKey), forKey: .macSigningKey)
        try c.encode(Base64URL.encode(macHPKEKey), forKey: .macHPKEKey)
        try c.encode(Base64URL.encode(secret), forKey: .secret)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(addresses, forKey: .addresses)
    }
}

/// `T = "funes-pair-v1" ‖ pid ‖ mac ‖ devSigPub ‖ devHpkePub ‖ deviceName ‖ model` (§2.2).
public struct PairingTranscript: Sendable, Equatable {
    public let bytes: Data

    public init(pairingID: String, macID: UUID, deviceSigningKey: Data, deviceHPKEKey: Data, deviceName: String, model: String) {
        var t = Transcript("funes-pair-v1")
        t.append(pairingID)
        t.append(macID.companionString)
        t.append(deviceSigningKey)
        t.append(deviceHPKEKey)
        t.append(deviceName)
        t.append(model)
        bytes = t.bytes
    }

    /// `P = HMAC-SHA256(sec, T)`: the phone saw the QR code.
    public func proof(secret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: secret)))
    }

    /// `HMAC-SHA256(sec, "mac-confirm" ‖ T)`: the Mac knew the same secret.
    public func macConfirmation(secret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: confirmationBytes, using: SymmetricKey(data: secret)))
    }

    /// Constant-time comparisons.
    public func isValidProof(_ proof: Data, secret: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: bytes, using: SymmetricKey(data: secret))
    }

    public func isValidMacConfirmation(_ confirm: Data, secret: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(confirm, authenticating: confirmationBytes, using: SymmetricKey(data: secret))
    }

    private var confirmationBytes: Data {
        var t = Transcript("mac-confirm")
        t.append(bytes)
        return t.bytes
    }
}

/// What the phone sends, sealed, to `/c/v1/pair` (§2.2, step 2).
public struct PairRequest: Codable, Sendable, Equatable {
    public var pairingID: String
    public var deviceName: String
    public var model: String
    public var deviceSigningKey: Data
    public var deviceHPKEKey: Data
    public var proof: Data

    /// The transcript names the Mac, which the request doesn't carry: the Mac adds its own id.
    public func transcript(macID: UUID) -> PairingTranscript {
        PairingTranscript(pairingID: pairingID, macID: macID, deviceSigningKey: deviceSigningKey, deviceHPKEKey: deviceHPKEKey,
                          deviceName: deviceName, model: model)
    }

    enum CodingKeys: String, CodingKey {
        case pairingID = "pid", deviceName, model, deviceSigningKey = "devSigPub", deviceHPKEKey = "devHpkePub", proof
    }

    public init(pairingID: String, deviceName: String, model: String, deviceSigningKey: Data, deviceHPKEKey: Data, proof: Data) {
        self.pairingID = pairingID
        self.deviceName = deviceName
        self.model = model
        self.deviceSigningKey = deviceSigningKey
        self.deviceHPKEKey = deviceHPKEKey
        self.proof = proof
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairingID = try c.decode(String.self, forKey: .pairingID)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        model = try c.decode(String.self, forKey: .model)
        deviceSigningKey = try c.decodeBase64URL(.deviceSigningKey)
        deviceHPKEKey = try c.decodeBase64URL(.deviceHPKEKey)
        proof = try c.decodeBase64URL(.proof)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pairingID, forKey: .pairingID)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(model, forKey: .model)
        try c.encode(Base64URL.encode(deviceSigningKey), forKey: .deviceSigningKey)
        try c.encode(Base64URL.encode(deviceHPKEKey), forKey: .deviceHPKEKey)
        try c.encode(Base64URL.encode(proof), forKey: .proof)
    }
}

/// What the Mac answers on Allow, sealed to the device (§2.2, step 4).
public struct PairConfirmation: Codable, Sendable, Equatable {
    public var deviceID: UUID
    public var macID: UUID
    public var confirm: Data

    enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId", macID = "mac", confirm
    }

    public init(deviceID: UUID, macID: UUID, confirm: Data) {
        self.deviceID = deviceID
        self.macID = macID
        self.confirm = confirm
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let device = UUID(companionString: try c.decode(String.self, forKey: .deviceID)),
              let mac = UUID(companionString: try c.decode(String.self, forKey: .macID))
        else { throw DecodingError.dataCorruptedError(forKey: .deviceID, in: c, debugDescription: "Bad id") }
        deviceID = device
        macID = mac
        confirm = try c.decodeBase64URL(.confirm)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceID.companionString, forKey: .deviceID)
        try c.encode(macID.companionString, forKey: .macID)
        try c.encode(Base64URL.encode(confirm), forKey: .confirm)
    }
}

// MARK: - Pairing envelopes

/// The phone's side of pairing: builds the sealed, signed request and checks the Mac's answer.
public struct PairingClient: Sendable {
    public let payload: PairingQRPayload
    public let request: PairRequest
    let nonce: Data
    let transcript: PairingTranscript
    let deviceHPKEKey: P256.KeyAgreement.PrivateKey

    /// The request for `payload`, with the device's keys. `body` is what to POST to `/c/v1/pair`.
    public static func start(payload: PairingQRPayload, deviceName: String, model: String, signer: some CompanionSigner,
                             deviceHPKEKey: P256.KeyAgreement.PrivateKey, now: Date = Date())
        throws -> (client: PairingClient, body: Data) {
        let sigPub = signer.publicKey.x963Representation
        let hpkePub = deviceHPKEKey.publicKey.x963Representation
        let transcript = PairingTranscript(pairingID: payload.pairingID, macID: payload.macID, deviceSigningKey: sigPub,
                                           deviceHPKEKey: hpkePub, deviceName: deviceName, model: model)
        let request = PairRequest(pairingID: payload.pairingID, deviceName: deviceName, model: model,
                                  deviceSigningKey: sigPub, deviceHPKEKey: hpkePub, proof: transcript.proof(secret: payload.secret))
        let nonce = randomBytes(CompanionProtocol.nonceBytes)
        let ts = now.companionMilliseconds
        var sender = try HPKE.Sender(recipientKey: try payload.hpkeKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                     info: Data(PairingWire.requestInfo.utf8))
        let ct = try sender.seal(try CompanionJSON.encoder().encode(request), authenticating: PairingWire.requestAAD(ts: ts, nonce: nonce))
        let enc = sender.encapsulatedKey
        let sig = try signer.signature(for: PairingWire.requestSigned(ts: ts, nonce: nonce, enc: enc, ct: ct)).rawRepresentation
        let wire = PairingWire.Request(v: CompanionProtocol.version, ts: ts, nonce: Base64URL.encode(nonce),
                                       enc: Base64URL.encode(enc), ct: Base64URL.encode(ct), sig: Base64URL.encode(sig))
        let client = PairingClient(payload: payload, request: request, nonce: nonce, transcript: transcript, deviceHPKEKey: deviceHPKEKey)
        return (client, try CompanionJSON.encoder().encode(wire))
    }

    /// Verifies the Mac's answer (§2.2, step 5): its signature with the QR code's key, then the
    /// confirmation HMAC. Returns the device id the Mac assigned.
    public func finish(responseBody: Data) throws(PairingError) -> PairConfirmation {
        guard responseBody.count <= CompanionProtocol.maxRequestBytes,
              let wire = try? JSONDecoder().decode(PairingWire.Response.self, from: responseBody),
              wire.v == CompanionProtocol.version,
              let enc = Base64URL.decode(wire.enc), enc.count == CompanionProtocol.encapsulatedKeyBytes,
              let ct = Base64URL.decode(wire.ct), ct.count >= CompanionProtocol.gcmTagBytes,
              let sigBytes = Base64URL.decode(wire.sig), let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigBytes),
              let macKey = try? payload.signingKey,
              macKey.isValidSignature(sig, for: PairingWire.responseSigned(requestNonce: nonce, enc: enc, ct: ct))
        else { throw .invalidConfirmation }
        guard var recipient = try? HPKE.Recipient(privateKey: deviceHPKEKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                                  info: Data(PairingWire.responseInfo.utf8), encapsulatedKey: enc),
              let plaintext = try? recipient.open(ct, authenticating: PairingWire.responseAAD(requestNonce: nonce)),
              let confirmation = try? CompanionJSON.decoder().decode(PairConfirmation.self, from: plaintext),
              confirmation.macID == payload.macID,
              transcript.isValidMacConfirmation(confirmation.confirm, secret: payload.secret)
        else { throw .invalidConfirmation }
        return confirmation
    }
}

/// A pairing request the Mac has opened and whose signature verified. The pairing service still
/// has to check the session, the proof and the attempt count, and ask the user.
public struct OpenedPairRequest: Sendable {
    public let request: PairRequest
    public let sentAt: Date
    let nonce: Data

    /// Opens a `/c/v1/pair` body: the clock, the HPKE open, then the signature with the device key
    /// the request carries.
    public init(body: Data, macHPKEKey: P256.KeyAgreement.PrivateKey, now: Date = Date()) throws(PairingError) {
        guard body.count <= CompanionProtocol.maxRequestBytes,
              let wire = try? JSONDecoder().decode(PairingWire.Request.self, from: body),
              wire.v == CompanionProtocol.version,
              let nonce = Base64URL.decode(wire.nonce), nonce.count == CompanionProtocol.nonceBytes,
              let enc = Base64URL.decode(wire.enc), enc.count == CompanionProtocol.encapsulatedKeyBytes,
              let ct = Base64URL.decode(wire.ct), ct.count >= CompanionProtocol.gcmTagBytes,
              let sigBytes = Base64URL.decode(wire.sig), let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigBytes)
        else { throw .invalidRequest }
        let sent = Date(companionMilliseconds: wire.ts)
        // A stale request is refused as expired: the QR code it came from can't be fresh either.
        guard abs(sent.timeIntervalSince(now)) <= CompanionProtocol.maxClockSkew else { throw .expired }
        guard var recipient = try? HPKE.Recipient(privateKey: macHPKEKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                                  info: Data(PairingWire.requestInfo.utf8), encapsulatedKey: enc),
              let plaintext = try? recipient.open(ct, authenticating: PairingWire.requestAAD(ts: wire.ts, nonce: nonce)),
              let request = try? CompanionJSON.decoder().decode(PairRequest.self, from: plaintext),
              let deviceKey = try? P256.Signing.PublicKey(x963Representation: request.deviceSigningKey),
              (try? P256.KeyAgreement.PublicKey(x963Representation: request.deviceHPKEKey)) != nil,
              deviceKey.isValidSignature(sig, for: PairingWire.requestSigned(ts: wire.ts, nonce: nonce, enc: enc, ct: ct))
        else { throw .invalidRequest }
        self.request = request
        self.sentAt = sent
        self.nonce = nonce
    }

    /// The answer on Allow: the confirmation sealed to the device and signed by the Mac.
    public func confirmationBody(deviceID: UUID, macID: UUID, secret: Data, macSigner: some CompanionSigner) throws -> Data {
        let confirmation = PairConfirmation(deviceID: deviceID, macID: macID,
                                            confirm: request.transcript(macID: macID).macConfirmation(secret: secret))
        let deviceKey = try P256.KeyAgreement.PublicKey(x963Representation: request.deviceHPKEKey)
        var sender = try HPKE.Sender(recipientKey: deviceKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                     info: Data(PairingWire.responseInfo.utf8))
        let ct = try sender.seal(try CompanionJSON.encoder().encode(confirmation), authenticating: PairingWire.responseAAD(requestNonce: nonce))
        let enc = sender.encapsulatedKey
        let sig = try macSigner.signature(for: PairingWire.responseSigned(requestNonce: nonce, enc: enc, ct: ct)).rawRepresentation
        let wire = PairingWire.Response(v: CompanionProtocol.version, enc: Base64URL.encode(enc), ct: Base64URL.encode(ct),
                                        sig: Base64URL.encode(sig))
        return try CompanionJSON.encoder().encode(wire)
    }
}

/// The pairing envelopes: `{"v","ts","nonce","enc","ct","sig"}` from the phone and
/// `{"v","enc","ct","sig"}` from the Mac. The answer is bound to the request by its nonce.
enum PairingWire {
    static let requestInfo = "funes-pair-v1"
    static let responseInfo = "funes-pair-confirm-v1"

    struct Request: Codable {
        var v: Int
        var ts: Int64
        var nonce: String
        var enc: String
        var ct: String
        var sig: String
    }

    struct Response: Codable {
        var v: Int
        var enc: String
        var ct: String
        var sig: String
    }

    static func requestAAD(ts: Int64, nonce: Data) -> Data {
        var t = Transcript("funes-pair-v1")
        t.append(CompanionProtocol.version)
        t.append(ts)
        t.append(nonce)
        return t.bytes
    }

    static func requestSigned(ts: Int64, nonce: Data, enc: Data, ct: Data) -> Data {
        var t = Transcript("funes-pair-req-v1")
        t.append(CompanionProtocol.version)
        t.append(ts)
        t.append(nonce)
        t.append(enc)
        t.append(ct)
        return t.bytes
    }

    static func responseAAD(requestNonce: Data) -> Data {
        var t = Transcript("funes-pair-confirm-v1")
        t.append(CompanionProtocol.version)
        t.append(requestNonce)
        return t.bytes
    }

    static func responseSigned(requestNonce: Data, enc: Data, ct: Data) -> Data {
        var t = Transcript("funes-pair-confirm-sig-v1")
        t.append(CompanionProtocol.version)
        t.append(requestNonce)
        t.append(enc)
        t.append(ct)
        return t.bytes
    }
}

extension KeyedDecodingContainer {
    func decodeBase64URL(_ key: Key) throws -> Data {
        guard let data = Base64URL.decode(try decode(String.self, forKey: key)) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not base64url")
        }
        return data
    }
}

// MARK: - Bonjour

public enum CompanionBonjour {
    /// The TXT record's `mac` value: the first 8 bytes of SHA-256(macId), as hex (§5).
    public static func macTag(_ macID: UUID) -> String {
        SHA256.hash(data: Data(macID.companionString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func txtRecord(macID: UUID) -> [String: String] {
        ["v": String(CompanionProtocol.version), "mac": macTag(macID)]
    }
}
