import BridgeKitCore
import Foundation
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "companion")

/// Pairing (§2): one QR session at a time, valid 5 minutes, at most 3 attempts, single use. A
/// request whose proof is right waits for the user's **Allow** on the Mac, the second factor, so
/// a photo of the QR code isn't enough. The secret is burned on Allow, Deny or timeout.
public actor PairingService {
    public enum State: Sendable, Equatable {
        case idle
        /// The QR code is showing.
        case waiting(expiresAt: Date)
        /// "<deviceName> wants to pair": Allow or Deny.
        case asking(deviceName: String, model: String)
        case paired(deviceName: String)
        case ended(PairingError)
    }

    /// How long the Allow prompt waits for the user. The phone waits a little longer.
    public static let defaultPromptTimeout: TimeInterval = 60

    private struct Session {
        var payload: PairingQRPayload
        var attempts = 0
        var asking = false
    }

    private let identity: MacIdentity
    private let devices: DeviceService
    private let activity: any ActivityRecorder
    private let promptTimeout: TimeInterval
    private var session: Session?
    private var prompt: CheckedContinuation<Bool, Never>?
    /// Which prompt is showing, so an old prompt's timeout can't answer a newer one.
    private var promptID: UUID?
    private var onChange: @Sendable (State) -> Void = { _ in }
    /// The latest state, as the sheet shows it.
    public private(set) var state = State.idle

    public init(identity: MacIdentity, devices: DeviceService, activity: any ActivityRecorder,
                promptTimeout: TimeInterval = PairingService.defaultPromptTimeout) {
        self.identity = identity
        self.devices = devices
        self.activity = activity
        self.promptTimeout = promptTimeout
    }

    /// `action` is called on the main queue.
    public func observe(_ action: @escaping @Sendable (State) -> Void) {
        onChange = { state in DispatchQueue.main.async { action(state) } }
    }

    private func publish(_ state: State) {
        self.state = state
        onChange(state)
    }

    /// A new session, replacing any other. The returned payload is what the QR code shows.
    public func start(macName: String, addresses: [PairingAddress], now: Date = Date()) -> PairingQRPayload {
        cancelPrompt()
        let (pid, secret) = PairingQRPayload.newSession()
        let payload = PairingQRPayload(pairingID: pid, macID: identity.macID, macName: macName,
                                       macSigningKey: identity.signingKey.publicKey, macHPKEKey: identity.hpkeKey.publicKey,
                                       secret: secret, expiresAt: now.addingTimeInterval(CompanionProtocol.pairingLifetime),
                                       addresses: addresses)
        session = Session(payload: payload)
        publish(.waiting(expiresAt: Date(timeIntervalSince1970: TimeInterval(payload.expiresAt))))
        return payload
    }

    /// The sheet closed: the secret is burned and a waiting prompt is denied.
    public func cancel() {
        session = nil
        cancelPrompt()
        publish(.idle)
    }

    /// The user's answer to "<deviceName> wants to pair".
    public func answer(allow: Bool) {
        guard let prompt else { return }
        self.prompt = nil
        promptID = nil
        prompt.resume(returning: allow)
    }

    /// `POST /c/v1/pair`.
    func handle(body: Data, now: Date = Date()) async -> HTTPResponse {
        let opened: OpenedPairRequest
        do {
            opened = try OpenedPairRequest(body: body, macHPKEKey: identity.hpkeKey, now: now)
        } catch {
            return Self.failure(error)
        }
        guard var current = session, current.payload.pairingID == opened.request.pairingID,
              !current.payload.isExpired(at: now), !current.asking else { return Self.failure(.expired) }
        current.attempts += 1
        guard current.attempts <= CompanionProtocol.maxPairingAttempts else {
            end(.tooManyAttempts)
            return Self.failure(.tooManyAttempts)
        }
        session = current
        let request = opened.request
        guard request.transcript(macID: identity.macID).isValidProof(request.proof, secret: current.payload.secret) else {
            return Self.failure(.invalidProof)
        }
        guard Self.isValidLabel(request.deviceName), Self.isValidLabel(request.model) else { return Self.failure(.invalidRequest) }
        do {
            guard try await devices.devices().count < CompanionProtocol.maxPairedDevices else {
                end(.tooManyDevices)
                return Self.failure(.tooManyDevices)
            }
        } catch {
            return Self.failure(.invalidRequest)
        }

        // Asking: other attempts on this session are refused until the user answers.
        guard var asking = session, asking.payload.pairingID == request.pairingID else { return Self.failure(.expired) }
        asking.asking = true
        session = asking
        publish(.asking(deviceName: request.deviceName, model: request.model))
        let allowed = await ask()
        // Single use, whatever the answer.
        let secret = asking.payload.secret
        session = nil
        guard allowed else {
            publish(.ended(.denied))
            return Self.failure(.denied)
        }
        do {
            let device = try await devices.register(name: request.deviceName, model: request.model,
                                                    signingPublicKey: request.deviceSigningKey,
                                                    hpkePublicKey: request.deviceHPKEKey, now: now)
            let reply = try opened.confirmationBody(deviceID: device.id, macID: identity.macID, secret: secret,
                                                    macSigner: identity.signingKey)
            activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "device_paired",
                                          outcome: "paired", ids: [device.id]))
            publish(.paired(deviceName: request.deviceName))
            return .json(200, reply)
        } catch {
            logger.error("Pairing failed after Allow")
            publish(.ended(.invalidRequest))
            return Self.failure(.invalidRequest)
        }
    }

    private func ask() async -> Bool {
        let id = UUID(), timeout = promptTimeout
        return await withCheckedContinuation { continuation in
            prompt = continuation
            promptID = id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.timeOut(id)
            }
        }
    }

    private func timeOut(_ id: UUID) {
        guard promptID == id else { return }
        answer(allow: false)
    }

    private func cancelPrompt() {
        answer(allow: false)
    }

    private func end(_ error: PairingError) {
        session = nil
        publish(.ended(error))
    }

    /// A device name or model as the Mac shows it: 1–64 characters, no control characters.
    static func isValidLabel(_ text: String) -> Bool {
        (1...64).contains(text.count) && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func failure(_ error: PairingError) -> HTTPResponse {
        .json(PairingError.httpStatus, error.body)
    }
}
