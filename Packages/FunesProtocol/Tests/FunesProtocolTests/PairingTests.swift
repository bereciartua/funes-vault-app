import CryptoKit
import Foundation
import Testing
@testable import FunesProtocol

struct PairingFixture {
    let macSigner = P256.Signing.PrivateKey()
    let macHPKE = P256.KeyAgreement.PrivateKey()
    let macID = UUID()
    let deviceSigner = P256.Signing.PrivateKey()
    let deviceHPKE = P256.KeyAgreement.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    let session = PairingQRPayload.newSession()

    var payload: PairingQRPayload {
        PairingQRPayload(pairingID: session.pairingID, macID: macID, macName: "Maya's MacBook Pro",
                         macSigningKey: macSigner.publicKey, macHPKEKey: macHPKE.publicKey, secret: session.secret,
                         expiresAt: now.addingTimeInterval(CompanionProtocol.pairingLifetime),
                         addresses: [PairingAddress(kind: .lan, host: "maya-mbp.local", port: 47626),
                                     PairingAddress(kind: .tailscale, host: "100.101.102.103", port: 47626)])
    }

    func start(_ payload: PairingQRPayload? = nil) throws -> (client: PairingClient, body: Data) {
        try PairingClient.start(payload: payload ?? self.payload, deviceName: "Sam's iPhone", model: "iPhone17,1",
                                signer: deviceSigner, deviceHPKEKey: deviceHPKE, now: now)
    }
}

@Suite struct PairingTests {
    @Test func happyPath() throws {
        let f = PairingFixture()
        let qr = f.payload.qrString
        let scanned = try #require(PairingQRPayload(qrString: qr))
        #expect(scanned == f.payload)

        let (client, body) = try f.start(scanned)
        let opened = try OpenedPairRequest(body: body, macHPKEKey: f.macHPKE, now: f.now)
        #expect(opened.request.deviceName == "Sam's iPhone")
        #expect(opened.request.model == "iPhone17,1")
        #expect(opened.request.deviceSigningKey == f.deviceSigner.publicKey.x963Representation)
        // The Mac's checks: the proof is for this session's secret.
        #expect(opened.request.transcript(macID: f.macID).isValidProof(opened.request.proof, secret: f.session.secret))

        let deviceID = UUID()
        let reply = try opened.confirmationBody(deviceID: deviceID, macID: f.macID, secret: f.session.secret, macSigner: f.macSigner)
        let confirmation = try client.finish(responseBody: reply)
        #expect(confirmation.deviceID == deviceID)
        #expect(confirmation.macID == f.macID)
    }

    @Test func qrWireShapeMatchesTheSpec() throws {
        let f = PairingFixture()
        let json = try #require(Base64URL.decode(f.payload.qrString))
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["v", "pid", "mac", "name", "sig", "hpke", "sec", "exp", "addr"])
        #expect(object["exp"] as? Int == 1_792_000_300)
        let addr = try #require(object["addr"] as? [[String: Any]])
        #expect(addr.first?["t"] as? String == "lan")
        #expect(addr.last?["t"] as? String == "ts")
        // A QR code stays scannable: well under the ~2,900 bytes of a version-40 code.
        #expect(f.payload.qrString.utf8.count < 1_000)
    }

    @Test func rejectsBadQRCodes() throws {
        let f = PairingFixture()
        #expect(PairingQRPayload(qrString: "hello") == nil)
        var short = f.payload
        short.secret = Data(count: 16)
        #expect(PairingQRPayload(qrString: short.qrString) == nil)
        var badKey = f.payload
        badKey.macHPKEKey = Data(repeating: 4, count: 65)
        #expect(PairingQRPayload(qrString: badKey.qrString) == nil)
        var future = f.payload
        future.v = 2
        #expect(PairingQRPayload(qrString: future.qrString) == nil)
    }

    @Test func expiry() {
        let f = PairingFixture()
        #expect(!f.payload.isExpired(at: f.now.addingTimeInterval(299)))
        #expect(f.payload.isExpired(at: f.now.addingTimeInterval(300)))
    }

    /// A phone that didn't see this QR code can't produce the proof.
    @Test func wrongSecretFailsTheProof() throws {
        let f = PairingFixture()
        var guessed = f.payload
        guessed.secret = Data(repeating: 9, count: 32)
        let (_, body) = try f.start(guessed)
        let opened = try OpenedPairRequest(body: body, macHPKEKey: f.macHPKE, now: f.now)
        #expect(!opened.request.transcript(macID: f.macID).isValidProof(opened.request.proof, secret: f.session.secret))
    }

    @Test func transcriptBindsEveryField() {
        let base = PairingTranscript(pairingID: "p", macID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                     deviceSigningKey: Data([1]), deviceHPKEKey: Data([2]), deviceName: "ab", model: "c")
        // Moving a byte between fields changes the transcript (length prefixes).
        let shifted = PairingTranscript(pairingID: "p", macID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                        deviceSigningKey: Data([1]), deviceHPKEKey: Data([2]), deviceName: "a", model: "bc")
        #expect(base != shifted)
        let secret = Data(repeating: 1, count: 32)
        #expect(!shifted.isValidProof(base.proof(secret: secret), secret: secret))
    }

    @Test func tamperedPairRequestIsRefused() throws {
        let f = PairingFixture()
        let (_, body) = try f.start()
        for key in ["ct", "enc", "sig", "nonce"] {
            #expect(throws: PairingError.invalidRequest) {
                try OpenedPairRequest(body: flippingBit(body, key, byte: 2), macHPKEKey: f.macHPKE, now: f.now)
            }
        }
        #expect(throws: PairingError.invalidRequest) {
            try OpenedPairRequest(body: body, macHPKEKey: P256.KeyAgreement.PrivateKey(), now: f.now)
        }
        #expect(throws: PairingError.expired) {
            try OpenedPairRequest(body: body, macHPKEKey: f.macHPKE, now: f.now.addingTimeInterval(600))
        }
    }

    @Test func confirmationFromAnotherMacIsRefused() throws {
        let f = PairingFixture()
        let (client, body) = try f.start()
        let opened = try OpenedPairRequest(body: body, macHPKEKey: f.macHPKE, now: f.now)
        // Signed by a key that isn't in the QR code.
        let impostor = try opened.confirmationBody(deviceID: UUID(), macID: f.macID, secret: f.session.secret,
                                                   macSigner: P256.Signing.PrivateKey())
        #expect(throws: PairingError.invalidConfirmation) { try client.finish(responseBody: impostor) }
        // The right key but the wrong secret (the Mac never saw this session).
        let wrongSecret = try opened.confirmationBody(deviceID: UUID(), macID: f.macID, secret: Data(count: 32), macSigner: f.macSigner)
        #expect(throws: PairingError.invalidConfirmation) { try client.finish(responseBody: wrongSecret) }
        // Another Mac id.
        let wrongMac = try opened.confirmationBody(deviceID: UUID(), macID: UUID(), secret: f.session.secret, macSigner: f.macSigner)
        #expect(throws: PairingError.invalidConfirmation) { try client.finish(responseBody: wrongMac) }
        // A good confirmation, tampered.
        let good = try opened.confirmationBody(deviceID: UUID(), macID: f.macID, secret: f.session.secret, macSigner: f.macSigner)
        #expect(throws: PairingError.invalidConfirmation) { try client.finish(responseBody: flippingBit(good, "ct")) }
    }

    /// The answer to one pairing request can't finish another.
    @Test func confirmationIsBoundToItsRequest() throws {
        let f = PairingFixture()
        let (first, _) = try f.start()
        let (_, secondBody) = try f.start()
        let opened = try OpenedPairRequest(body: secondBody, macHPKEKey: f.macHPKE, now: f.now)
        let reply = try opened.confirmationBody(deviceID: UUID(), macID: f.macID, secret: f.session.secret, macSigner: f.macSigner)
        #expect(throws: PairingError.invalidConfirmation) { try first.finish(responseBody: reply) }
    }

    @Test func failureBodies() {
        for error in PairingError.allCases {
            #expect(PairingError(body: error.body) == error)
        }
        #expect(String(decoding: PairingError.denied.body, as: UTF8.self) == #"{"error":"pairing_denied"}"#)
    }

    @Test func bonjourTag() {
        let mac = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let tag = CompanionBonjour.macTag(mac)
        #expect(tag.count == 16)
        #expect(tag == tag.lowercased())
        #expect(CompanionBonjour.txtRecord(macID: mac) == ["v": "1", "mac": tag])
        #expect(CompanionBonjour.macTag(UUID()) != tag)
    }
}
