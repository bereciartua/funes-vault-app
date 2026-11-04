import Foundation

/// Why the Mac refused an envelope before reading it (§3, verification order). Sent as a plaintext
/// `401` body, `{"error":"<code>"}`, with nothing else except `server_time` on `clock_skew`.
public enum CompanionAuthError: Error, Sendable, Equatable {
    case unknownDevice
    case revoked
    /// The Mac's clock, which isn't secret, so the phone can retry with a corrected `ts`.
    case clockSkew(serverTime: Date)
    case replay
    case invalidSignature
    /// The body isn't a well-formed envelope: bad JSON, a wrong version, a field of the wrong size.
    case invalidEnvelope
    case decryptionFailed

    public var code: String {
        switch self {
        case .unknownDevice: "unknown_device"
        case .revoked: "revoked"
        case .clockSkew: "clock_skew"
        case .replay: "replay"
        case .invalidSignature: "invalid_signature"
        case .invalidEnvelope: "invalid_envelope"
        case .decryptionFailed: "decryption_failed"
        }
    }

    public static let httpStatus = 401

    /// The plaintext body of the `401`.
    public var body: Data {
        let wire = CompanionFailureBody(error: code, serverTime: {
            if case let .clockSkew(time) = self { return time.companionMilliseconds }
            return nil
        }())
        return (try? CompanionJSON.encoder().encode(wire)) ?? Data()
    }

    /// Reads a `401` body back on the phone. Unknown codes are `invalidEnvelope`.
    public init(body: Data) {
        guard let wire = try? CompanionJSON.decoder().decode(CompanionFailureBody.self, from: body) else {
            self = .invalidEnvelope
            return
        }
        switch wire.error {
        case "unknown_device": self = .unknownDevice
        case "revoked": self = .revoked
        case "clock_skew":
            guard let ms = wire.serverTime else { self = .invalidEnvelope; return }
            self = .clockSkew(serverTime: Date(companionMilliseconds: ms))
        case "replay": self = .replay
        case "invalid_signature": self = .invalidSignature
        case "decryption_failed": self = .decryptionFailed
        default: self = .invalidEnvelope
        }
    }
}

/// Why a pairing attempt failed (§2). Sent as a plaintext body like `CompanionAuthError`.
public enum PairingError: String, Error, Sendable, CaseIterable {
    /// No such pairing session, or the QR code's 5 minutes are over.
    case expired = "pairing_expired"
    /// The proof didn't match the QR code's secret.
    case invalidProof = "pairing_invalid"
    /// The user chose Deny on the Mac, or didn't answer.
    case denied = "pairing_denied"
    /// A 4th attempt in one pairing session.
    case tooManyAttempts = "too_many_attempts"
    /// Five devices are already paired.
    case tooManyDevices = "too_many_devices"
    /// The envelope itself was malformed, unsigned or unreadable.
    case invalidRequest = "invalid_request"
    /// The Mac's confirmation didn't verify on the phone. Never sent by the Mac.
    case invalidConfirmation = "invalid_confirmation"

    public static let httpStatus = 403

    public var body: Data {
        (try? CompanionJSON.encoder().encode(CompanionFailureBody(error: rawValue, serverTime: nil))) ?? Data()
    }

    public init(body: Data) {
        let wire = try? CompanionJSON.decoder().decode(CompanionFailureBody.self, from: body)
        self = wire.flatMap { PairingError(rawValue: $0.error) } ?? .invalidRequest
    }
}

struct CompanionFailureBody: Codable {
    var error: String
    var serverTime: Int64?

    enum CodingKeys: String, CodingKey {
        case error
        case serverTime = "server_time"
    }
}

/// The error codes of a method call, inside the encrypted response (§4).
public enum CompanionErrorCode: String, Codable, Sendable, CaseIterable {
    case invalidInput = "invalid_input"
    case secretLikeContent = "secret_like_content"
    case notFound = "not_found"
    case conflict
    case rateLimited = "rate_limited"
    /// The vault is migrating or locked.
    case unavailable
    case unknownMethod = "unknown_method"
    case internalError = "internal_error"
    /// `approvals.*`: the request was answered first, on the Mac or another iPhone.
    case alreadyAnswered = "already_answered"
    /// `approvals.*`: its 15 minutes (or an access request's in-call wait) are over, or it was
    /// withdrawn.
    case requestExpired = "request_expired"
    /// `approvals.answer`: the panel's revision is stale (a memory or the agent's access changed).
    /// Fetch it again and show the new panel.
    case requestChanged = "request_changed"
    /// `inbox.apply`: a memory the suggestion changes was edited, archived or deleted since it was
    /// suggested. The suggestion is still waiting; review it on the Mac.
    case targetChanged = "target_changed"
    /// `inbox.apply`: merge, split and conflict suggestions (and actions this phone doesn't
    /// know) are answered on the Mac.
    case unsupportedAction = "unsupported_action"
    /// `inbox.apply`: New memories processing hasn't finished with this suggestion (the item's
    /// `processing` is `processing`). Its result replaces it; list the Inbox again later.
    case processing
    /// `memories.answer` (v0.6): Search answers are off on the Mac, or no model can answer.
    case answersOff = "answers_off"
    /// `memories.answer`: today's cloud requests are used up.
    case capReached = "cap_reached"
    /// `memories.answer`: the model couldn't answer; `reason` says why (`not_signed_in`,
    /// `needs_update`, `plan_limit`, `provider_error`, `invalid_output`, `tool_blocked`,
    /// `secret_in_search`).
    case modelUnavailable = "model_unavailable"
    /// `memories.answer`: the model took longer than 45 s.
    case modelTimeout = "model_timeout"
    /// `memories.answer` sent on its own (`automatic`), but the Mac now answers this search only
    /// when asked (its setting changed, or Apple on-device answers). Nothing was sent; show Ask.
    case askRequired = "ask_required"
}

/// A method call's error: `{"code":"…","message":"…"}`, plus `findings` for secrets and
/// `retry_after_s` for rate limits. The message is for logs and support, never shown as is.
public struct CompanionError: Error, Codable, Sendable, Equatable {
    public var code: CompanionErrorCode
    public var message: String
    /// The secret types found (`secret_like_content`), never the text.
    public var findings: [SecretPattern]?
    public var retryAfterSeconds: Int?
    /// `model_unavailable`'s reason (v0.6).
    public var reason: String?

    public init(_ code: CompanionErrorCode, message: String = "", findings: [SecretPattern]? = nil,
                retryAfterSeconds: Int? = nil, reason: String? = nil) {
        self.code = code
        self.message = message
        self.findings = findings
        self.retryAfterSeconds = retryAfterSeconds
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case code, message, findings, reason
        case retryAfterSeconds = "retry_after_s"
    }
}
