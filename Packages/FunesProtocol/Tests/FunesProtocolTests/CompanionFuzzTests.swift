import CryptoKit
import Foundation
import Testing
@testable import FunesProtocol

/// SplitMix64: a seeded generator, so a failing input can be reproduced from its seed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Fuzzing the decoders (§9): nothing crashes, and nothing but the genuine bytes opens.
@Suite struct CompanionFuzzTests {
    static let iterations = 3_000

    @Test func randomBytesNeverDecode() {
        var rng = SeededGenerator(state: 0xF00D)
        for _ in 0..<Self.iterations {
            let count = Int.random(in: 0...512, using: &rng)
            let bytes = Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
            #expect(throws: CompanionAuthError.invalidEnvelope) { try CompanionRequestEnvelope(body: bytes) }
            #expect(throws: CompanionError.self) { try CompanionRequestHead(plaintext: bytes) }
            #expect(PairingQRPayload(qrString: String(decoding: bytes, as: UTF8.self)) == nil)
        }
    }

    /// Byte mutations of a genuine envelope: each either fails to verify or, when it only touched
    /// JSON syntax (whitespace, key order), opens to the exact original plaintext.
    @Test func mutatedEnvelopesNeverOpenToSomethingElse() throws {
        var rng = SeededGenerator(state: 0xBEEF)
        let original = Data(#"{"id":"1","method":"memories.get","params":{"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff"}}"#.utf8)
        var opened = 0
        var f = CompanionFixture()
        let body = try f.seal(original).envelope.body
        for i in 0..<Self.iterations {
            f.cache = ReplayCache()
            let mutated = mutate(body, using: &rng)
            do {
                let request = try f.open(mutated)
                #expect(request.plaintext == original, "iteration \(i)")
                opened += 1
            } catch {
                // Any refusal is fine; crashing or opening to other bytes is not.
            }
        }
        #expect(opened < Self.iterations)
    }

    /// Structured mutations: a valid JSON envelope with one field replaced by random values.
    @Test func fieldSubstitutionsAreRefused() throws {
        var rng = SeededGenerator(state: 0xCAFE)
        let fields = ["v", "did", "ts", "nonce", "enc", "ct", "sig"]
        var f = CompanionFixture()
        let body = try f.seal().envelope.body
        for _ in 0..<Self.iterations {
            f.cache = ReplayCache()
            let key = fields.randomElement(using: &rng)!
            let value: Any = switch Int.random(in: 0..<5, using: &rng) {
            case 0: Int.random(in: -5...Int(Int32.max), using: &rng)
            case 1: Base64URL.encode(Data((0..<Int.random(in: 0...80, using: &rng)).map { _ in UInt8.random(in: .min ... .max, using: &rng) }))
            case 2: NSNull()
            case 3: [1, 2, 3]
            default: String(repeating: "A", count: Int.random(in: 0...100, using: &rng))
            }
            #expect(throws: CompanionAuthError.self) { try f.open(replacing(body, key, with: value)) }
        }
    }

    @Test func mutatedResponsesNeverOpenToSomethingElse() throws {
        var rng = SeededGenerator(state: 0xD00D)
        var f = CompanionFixture()
        let sealed = try f.seal()
        let key = try f.open(sealed.envelope.body).responseKey
        let reply = Data(#"{"id":"1","result":{"version":2}}"#.utf8)
        for _ in 0..<Self.iterations {
            let body = mutate(try key.seal(reply), using: &rng)
            if let opened = try? sealed.responseKey.open(body) { #expect(opened == reply) }
        }
    }

    @Test func mutatedPairRequestsNeverOpenToSomethingElse() throws {
        var rng = SeededGenerator(state: 0xFACE)
        let f = PairingFixture()
        let (client, body) = try f.start()
        for _ in 0..<Self.iterations {
            if let opened = try? OpenedPairRequest(body: mutate(body, using: &rng), macHPKEKey: f.macHPKE, now: f.now) {
                #expect(opened.request == client.request)
            }
        }
    }

    @Test func mutatedMethodParamsNeverCrash() throws {
        var rng = SeededGenerator(state: 0xABCD)
        let request = CompanionRequest(MemoriesUpdate.self, id: "1", params: MemoryUpdateParams(
            id: UUID(), version: 2, changes: MemoryChanges(title: "T", body: "B", categories: ["health"], expiresAt: .some(nil))))
        let data = try request.encoded()
        for _ in 0..<Self.iterations {
            let mutated = mutate(data, using: &rng)
            if let head = try? CompanionRequestHead(plaintext: mutated) {
                _ = try? head.params(MemoriesUpdate.self)
            }
        }
    }

    /// Flips, inserts, deletes or duplicates a few bytes.
    func mutate(_ data: Data, using rng: inout SeededGenerator) -> Data {
        var bytes = [UInt8](data)
        for _ in 0..<Int.random(in: 1...4, using: &rng) where !bytes.isEmpty {
            let at = Int.random(in: 0..<bytes.count, using: &rng)
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: bytes[at] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &rng)
            case 1: bytes[at] = UInt8.random(in: .min ... .max, using: &rng)
            case 2: bytes.insert(UInt8.random(in: 0x20...0x7E, using: &rng), at: at)
            case 3: bytes.remove(at: at)
            default: bytes.insert(contentsOf: bytes[at..<min(bytes.count, at + 8)], at: at)
            }
        }
        return Data(bytes)
    }
}
