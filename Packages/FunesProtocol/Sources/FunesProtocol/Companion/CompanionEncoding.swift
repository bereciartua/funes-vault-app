import Foundation

/// The constants of the companion protocol (spec/architecture/companion-protocol.md).
public enum CompanionProtocol {
    public static let version = 1
    /// TCP port of the Mac's companion listener. Local MCP is 47625, Remote Access 47627.
    public static let port: UInt16 = 47626
    public static let rpcPath = "/c/v1/rpc"
    public static let pairPath = "/c/v1/pair"
    public static let envelopeContentType = "application/funes-envelope+json"

    /// `|now − ts|` above this is `clock_skew` (§3, step 2).
    public static let maxClockSkew: TimeInterval = 120
    /// How long a nonce is remembered (§3, step 3).
    public static let replayWindow: TimeInterval = 600
    public static let replayCapacityPerDevice = 10_000
    /// The largest request body the Mac reads (§7).
    public static let maxRequestBytes = 256 * 1024
    /// The largest reply the phone reads.
    public static let maxResponseBytes = 4 * 1024 * 1024
    public static let maxCapturesPerCall = 50
    public static let maxSearchLimit = 50
    /// A QR code's pairing session (§2).
    public static let pairingLifetime: TimeInterval = 300
    public static let maxPairingAttempts = 3
    public static let maxPairedDevices = 5

    static let nonceBytes = 16
    static let responseNonceBytes = 12
    /// An uncompressed P-256 point, the HPKE encapsulated key.
    static let encapsulatedKeyBytes = 65
    /// A raw (r ‖ s) P-256 ECDSA signature.
    static let signatureBytes = 64
    static let gcmTagBytes = 16
    static let pairingSecretBytes = 32
}

/// Base64url without padding (RFC 4648 §5), the spelling of every binary field on the wire.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The bytes of `string`, or nil unless it is canonical unpadded base64url: no padding, no
    /// other alphabets, no whitespace, and no stray bits in the last character. So each value has
    /// exactly one spelling.
    public static func decode(_ string: String) -> Data? {
        guard string.utf8.allSatisfy(isAlphabet), string.utf8.count % 4 != 1 else { return nil }
        var standard = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), encode(data) == string else { return nil }
        return data
    }

    private static func isAlphabet(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
    }
}

/// The spec's "‖": each field as a 4-byte big-endian length and then its bytes, so two different
/// field lists never produce the same bytes. Strings are UTF-8; integers are 8-byte big-endian.
struct Transcript {
    private(set) var bytes = Data()

    init(_ label: String) { append(label) }

    mutating func append(_ field: Data) {
        var length = UInt32(field.count).bigEndian
        bytes.append(Data(bytes: &length, count: 4))
        bytes.append(field)
    }

    mutating func append(_ field: String) { append(Data(field.utf8)) }

    mutating func append(_ field: Int64) {
        var value = UInt64(bitPattern: field).bigEndian
        append(Data(bytes: &value, count: 8))
    }

    mutating func append(_ field: Int) { append(Int64(field)) }
}

/// JSON coders for method requests and responses: dates are milliseconds since 1970, like `ts`.
public enum CompanionJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

extension Date {
    /// Milliseconds since 1970, the protocol's `ts`.
    var companionMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(companionMilliseconds ms: Int64) { self.init(timeIntervalSince1970: Double(ms) / 1000) }
}

extension UUID {
    /// The lowercase spelling the protocol uses for device and Mac ids.
    var companionString: String { uuidString.lowercased() }

    /// Parses only the lowercase spelling, so a device id has one form in signatures and caches.
    init?(companionString string: String) {
        guard string == string.lowercased(), let id = UUID(uuidString: string) else { return nil }
        self = id
    }
}
