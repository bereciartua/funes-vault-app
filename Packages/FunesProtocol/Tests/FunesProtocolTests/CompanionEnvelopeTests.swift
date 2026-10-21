import CryptoKit
import Foundation
import Testing
@testable import FunesProtocol

/// A Mac and one paired device, with fresh keys.
struct CompanionFixture {
    let macHPKE = P256.KeyAgreement.PrivateKey()
    let deviceSigner = P256.Signing.PrivateKey()
    let deviceID = UUID()
    let now = Date(timeIntervalSince1970: 1_792_000_123.456)
    var cache = ReplayCache()

    var record: CompanionDeviceRecord { CompanionDeviceRecord(id: deviceID, signingKey: deviceSigner.publicKey, isRevoked: false) }

    func seal(_ plaintext: Data = Data(#"{"id":"1","method":"status.get","params":{}}"#.utf8), at time: Date? = nil,
              nonce: Data? = nil) throws -> SealedCompanionRequest {
        try CompanionRequestEnvelope.seal(plaintext, deviceID: deviceID, macHPKEKey: macHPKE.publicKey, signer: deviceSigner,
                                          now: time ?? now, nonce: nonce)
    }

    mutating func open(_ body: Data, device: CompanionDeviceRecord? = nil, at time: Date? = nil) throws(CompanionAuthError)
        -> OpenedCompanionRequest {
        let envelope = try CompanionRequestEnvelope(body: body)
        return try envelope.open(device: device ?? record, macHPKEKey: macHPKE, replayCache: &cache, now: time ?? now)
    }
}

/// Replaces one field of a JSON object body.
func replacing(_ body: Data, _ key: String, with value: Any) -> Data {
    var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    object[key] = value
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

func field(_ body: Data, _ key: String) -> Any? {
    ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?[key]
}

/// The base64url field with one bit flipped in its decoded bytes.
func flippingBit(_ body: Data, _ key: String, byte: Int = 0) -> Data {
    var bytes = Base64URL.decode(field(body, key) as? String ?? "") ?? Data()
    bytes[bytes.startIndex + byte] ^= 0x01
    return replacing(body, key, with: Base64URL.encode(bytes))
}

@Suite struct CompanionEnvelopeTests {
    @Test func sealOpenAndReplyRoundTrip() throws {
        var f = CompanionFixture()
        let plaintext = Data(#"{"id":"abc","method":"captures.submit","params":{"captures":[]}}"#.utf8)
        let sealed = try f.seal(plaintext)
        let opened = try f.open(sealed.envelope.body)
        #expect(opened.plaintext == plaintext)
        #expect(opened.deviceID == f.deviceID)

        let reply = Data(#"{"id":"abc","result":{}}"#.utf8)
        let replyBody = try opened.responseKey.seal(reply)
        #expect(try sealed.responseKey.open(replyBody) == reply)
    }

    @Test func wireShapeMatchesTheSpec() throws {
        let f = CompanionFixture()
        let body = try f.seal().envelope.body
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["v", "did", "ts", "nonce", "enc", "ct", "sig"])
        #expect(object["v"] as? Int == 1)
        #expect(object["did"] as? String == f.deviceID.uuidString.lowercased())
        #expect(object["ts"] as? Int64 == 1_792_000_123_456)
        #expect(Base64URL.decode(object["nonce"] as? String ?? "")?.count == 16)
        #expect(Base64URL.decode(object["enc"] as? String ?? "")?.count == 65)
        #expect(Base64URL.decode(object["sig"] as? String ?? "")?.count == 64)
    }

    @Test func plaintextIsNotInTheEnvelope() throws {
        let f = CompanionFixture()
        let secret = "remember-the-blue-door"
        let body = try f.seal(Data(#"{"id":"1","method":"captures.submit","params":{"text":"\#(secret)"}}"#.utf8)).envelope.body
        let text = String(decoding: body, as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains("captures.submit"))
    }

    @Test func eachRequestHasItsOwnResponseKey() throws {
        var f = CompanionFixture()
        let first = try f.seal()
        let second = try f.seal()
        let opened = try f.open(second.envelope.body)
        let reply = try opened.responseKey.seal(Data("{}".utf8))
        #expect(throws: CompanionAuthError.decryptionFailed) { try first.responseKey.open(reply) }
    }

    @Test(arguments: ["ct", "enc", "sig", "nonce"])
    func tamperedFieldIsRefused(_ key: String) throws {
        var f = CompanionFixture()
        let body = flippingBit(try f.seal().envelope.body, key, byte: 3)
        #expect(throws: CompanionAuthError.invalidSignature) { try f.open(body) }
    }

    @Test func tamperedTimestampIsRefused() throws {
        var f = CompanionFixture()
        let body = try f.seal().envelope.body
        let ts = try #require(field(body, "ts") as? Int64)
        #expect(throws: CompanionAuthError.invalidSignature) { try f.open(replacing(body, "ts", with: ts + 1)) }
    }

    @Test func envelopeMovedToAnotherDeviceIsRefused() throws {
        var f = CompanionFixture()
        let other = P256.Signing.PrivateKey()
        let otherID = UUID()
        let body = replacing(try f.seal().envelope.body, "did", with: otherID.uuidString.lowercased())
        let record = CompanionDeviceRecord(id: otherID, signingKey: other.publicKey, isRevoked: false)
        #expect(throws: CompanionAuthError.invalidSignature) { try f.open(body, device: record) }
    }

    @Test func signatureByAnotherKeyIsRefused() throws {
        var f = CompanionFixture()
        let impostor = CompanionDeviceRecord(id: f.deviceID, signingKey: P256.Signing.PrivateKey().publicKey, isRevoked: false)
        #expect(throws: CompanionAuthError.invalidSignature) { try f.open(try f.seal().envelope.body, device: impostor) }
    }

    /// A ciphertext the device signed but that doesn't open: tampered before signing, or sealed to
    /// the wrong Mac.
    @Test func signedButUnreadableIsDecryptionFailed() throws {
        var f = CompanionFixture()
        let env = try f.seal().envelope
        var ct = env.ciphertext
        ct[ct.startIndex] ^= 0x01
        let sig = try f.deviceSigner.signature(for: CompanionRequestEnvelope.signedBytes(
            deviceID: env.deviceID, ts: env.timestamp, nonce: env.nonce, enc: env.encapsulatedKey, ct: ct)).rawRepresentation
        let forged = CompanionRequestEnvelope(deviceID: env.deviceID, timestamp: env.timestamp, nonce: env.nonce,
                                              encapsulatedKey: env.encapsulatedKey, ciphertext: ct, signature: sig)
        #expect(throws: CompanionAuthError.decryptionFailed) { try f.open(forged.body) }

        let otherMac = try CompanionRequestEnvelope.seal(Data("{}".utf8), deviceID: f.deviceID,
                                                         macHPKEKey: P256.KeyAgreement.PrivateKey().publicKey,
                                                         signer: f.deviceSigner, now: f.now)
        #expect(throws: CompanionAuthError.decryptionFailed) { try f.open(otherMac.envelope.body) }
    }

    @Test func unknownAndRevokedDevices() throws {
        var f = CompanionFixture()
        let body = try f.seal().envelope.body
        let envelope = try CompanionRequestEnvelope(body: body)
        #expect(throws: CompanionAuthError.unknownDevice) {
            try envelope.open(device: nil, macHPKEKey: f.macHPKE, replayCache: &f.cache, now: f.now)
        }
        let revoked = CompanionDeviceRecord(id: f.deviceID, signingKey: f.deviceSigner.publicKey, isRevoked: true)
        #expect(throws: CompanionAuthError.revoked) { try f.open(body, device: revoked) }
        // A record for some other device than the envelope names is unknown, not trusted.
        let mismatched = CompanionDeviceRecord(id: UUID(), signingKey: f.deviceSigner.publicKey, isRevoked: false)
        #expect(throws: CompanionAuthError.unknownDevice) { try f.open(body, device: mismatched) }
    }

    @Test(arguments: [-121.0, 121.0, -3_600.0, 86_400.0])
    func skewedClockIsRefusedWithServerTime(_ offset: Double) throws {
        var f = CompanionFixture()
        let body = try f.seal(at: f.now.addingTimeInterval(offset)).envelope.body
        #expect(throws: CompanionAuthError.clockSkew(serverTime: f.now)) { try f.open(body) }
    }

    @Test(arguments: [-119.0, 0.0, 119.0])
    func skewWithinTwoMinutesIsAccepted(_ offset: Double) throws {
        var f = CompanionFixture()
        let body = try f.seal(at: f.now.addingTimeInterval(offset)).envelope.body
        _ = try f.open(body)
    }

    @Test func replayedEnvelopeIsRefused() throws {
        var f = CompanionFixture()
        let body = try f.seal().envelope.body
        _ = try f.open(body)
        #expect(throws: CompanionAuthError.replay) { try f.open(body, at: f.now.addingTimeInterval(30)) }
    }

    @Test func sameNonceInANewEnvelopeIsAReplay() throws {
        var f = CompanionFixture()
        let nonce = Data(repeating: 7, count: 16)
        _ = try f.open(try f.seal(nonce: nonce).envelope.body)
        let again = try f.seal(at: f.now.addingTimeInterval(1), nonce: nonce).envelope.body
        #expect(throws: CompanionAuthError.replay) { try f.open(again, at: f.now.addingTimeInterval(1)) }
    }

    /// A forged envelope never reaches the cache, so it can't block the real one.
    @Test func badSignatureDoesNotRecordTheNonce() throws {
        var f = CompanionFixture()
        let body = try f.seal().envelope.body
        #expect(throws: CompanionAuthError.invalidSignature) { try f.open(flippingBit(body, "sig")) }
        _ = try f.open(body)
    }

    @Test func failureBodiesAreMinimal() throws {
        let skew = CompanionAuthError.clockSkew(serverTime: Date(timeIntervalSince1970: 1_792_000_000))
        #expect(String(decoding: skew.body, as: UTF8.self) == #"{"error":"clock_skew","server_time":1792000000000}"#)
        #expect(String(decoding: CompanionAuthError.replay.body, as: UTF8.self) == #"{"error":"replay"}"#)
        for error in [CompanionAuthError.unknownDevice, .revoked, skew, .replay, .invalidSignature, .invalidEnvelope, .decryptionFailed] {
            #expect(CompanionAuthError(body: error.body) == error)
        }
        #expect(CompanionAuthError(body: Data("nonsense".utf8)) == .invalidEnvelope)
    }

    @Test func tamperedResponseIsRefused() throws {
        var f = CompanionFixture()
        let sealed = try f.seal()
        let opened = try f.open(sealed.envelope.body)
        let reply = try opened.responseKey.seal(Data(#"{"id":"1","result":{}}"#.utf8))
        #expect(throws: CompanionAuthError.decryptionFailed) { try sealed.responseKey.open(flippingBit(reply, "ct")) }
        #expect(throws: CompanionAuthError.decryptionFailed) { try sealed.responseKey.open(flippingBit(reply, "n")) }
        #expect(throws: CompanionAuthError.invalidEnvelope) { try sealed.responseKey.open(replacing(reply, "v", with: 2)) }
    }

    @Test func malformedEnvelopesAreInvalid() throws {
        let f = CompanionFixture()
        let body = try f.seal().envelope.body
        let cases: [Data] = [
            Data(),
            Data("[]".utf8),
            replacing(body, "v", with: 2),
            replacing(body, "did", with: f.deviceID.uuidString),  // uppercase: not the canonical spelling
            replacing(body, "did", with: "not-a-uuid"),
            replacing(body, "nonce", with: Base64URL.encode(Data(count: 15))),
            replacing(body, "enc", with: Base64URL.encode(Data(count: 33))),
            replacing(body, "sig", with: Base64URL.encode(Data(count: 72))),
            replacing(body, "ct", with: Base64URL.encode(Data(count: 15))),
            replacing(body, "ct", with: (field(body, "ct") as? String ?? "") + "="),
            replacing(body, "ts", with: "1792000123456"),
            Data(repeating: 0x20, count: CompanionProtocol.maxRequestBytes + 1),
        ]
        for bad in cases {
            #expect(throws: CompanionAuthError.invalidEnvelope) { try CompanionRequestEnvelope(body: bad) }
        }
    }
}

@Suite struct Base64URLTests {
    @Test func roundTripsEveryLength() {
        for length in 0..<70 {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let text = Base64URL.encode(data)
            #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
            #expect(Base64URL.decode(text) == data)
        }
    }

    @Test func refusesNonCanonicalSpellings() {
        #expect(Base64URL.decode("AQ==") == nil)   // padding
        #expect(Base64URL.decode("A+8") == nil)    // standard alphabet
        #expect(Base64URL.decode("AQ\n") == nil)   // whitespace
        #expect(Base64URL.decode("AR") == nil)     // stray bits in the last character ("AQ" is canonical)
        #expect(Base64URL.decode("A") == nil)      // impossible length
        #expect(Base64URL.decode("AQ") == Data([1]))
    }
}
