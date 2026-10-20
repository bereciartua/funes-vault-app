import BridgeKitCore
import CryptoKit
import Foundation
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "companion")

/// Routes one HTTP request (§3, §5): the tunnel's secret path and `Host`, then pairing or the
/// envelope. Refusals carry only a code. Never logs a body.
public final class CompanionRouter: Sendable {
    let identity: MacIdentity
    let devices: DeviceService
    let pairing: PairingService
    let handlers: CompanionHandlers
    let gate: TunnelGate?
    let guardian = EnvelopeGuard()
    let limits = DeviceLimits()
    let clock: @Sendable () -> Date

    public init(identity: MacIdentity, devices: DeviceService, pairing: PairingService, handlers: CompanionHandlers,
                gate: TunnelGate?, clock: @escaping @Sendable () -> Date = Date.init) {
        self.identity = identity
        self.devices = devices
        self.pairing = pairing
        self.handlers = handlers
        self.gate = gate
        self.clock = clock
    }

    public func handle(_ request: HTTPRequest, transport: DeviceTransport) async -> HTTPResponse {
        var path = request.path
        if transport == .tunnel {
            guard let gate else { return HTTPResponse(status: 404) }
            switch gate.check(path: path, host: request.header("host")) {
            case let .allowed(inner): path = inner
            case .notFound: return HTTPResponse(status: 404)
            case .misdirected: return HTTPResponse(status: 421)
            }
        } else if path.hasPrefix("/r/") {
            return HTTPResponse(status: 404)
        }
        guard path == CompanionProtocol.rpcPath || path == CompanionProtocol.pairPath else { return HTTPResponse(status: 404) }
        guard request.method == "POST" else { return HTTPResponse(status: 405, headers: [("Allow", "POST")]) }
        let type = request.header("content-type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard type == CompanionProtocol.envelopeContentType else { return HTTPResponse(status: 415) }
        if path == CompanionProtocol.pairPath { return await pairing.handle(body: request.body, now: clock()) }
        return await rpc(request.body, transport: transport)
    }

    func rpc(_ body: Data, transport: DeviceTransport) async -> HTTPResponse {
        let now = clock()
        let opened: OpenedCompanionRequest
        do {
            let envelope = try CompanionRequestEnvelope(body: body)
            let device = try? await devices.device(id: envelope.deviceID)
            let record = device.flatMap { d in
                (try? P256.Signing.PublicKey(x963Representation: d.signingPublicKey))
                    .map { CompanionDeviceRecord(id: d.id, signingKey: $0, isRevoked: d.isRevoked) }
            }
            opened = try await guardian.open(envelope, device: record, macKey: identity.hpkeKey, now: now)
        } catch {
            return .json(CompanionAuthError.httpStatus, error.body)
        }
        try? await devices.touch(deviceID: opened.deviceID, transport: transport, now: now)
        let reply: Data
        if let wait = await limits.admitCall(deviceID: opened.deviceID, now: now) {
            reply = CompanionHandlers.errorReply(id: (try? CompanionRequestHead(plaintext: opened.plaintext).id) ?? "",
                                                 CompanionError(.rateLimited, retryAfterSeconds: wait))
        } else {
            reply = await handlers.handle(opened.plaintext, deviceID: opened.deviceID, limits: limits, now: now)
        }
        do {
            return .json(200, try opened.responseKey.seal(reply), contentType: CompanionProtocol.envelopeContentType)
        } catch {
            logger.error("Couldn't seal a companion reply")
            return HTTPResponse(status: 500)
        }
    }

    /// A revoked device's nonces and limits are dropped with it.
    public func forget(deviceID: UUID) async {
        await guardian.forget(deviceID: deviceID)
        await limits.forget(deviceID: deviceID)
    }
}

/// Holds the replay cache, so the check and the record happen together.
actor EnvelopeGuard {
    private var cache = ReplayCache()

    func open(_ envelope: CompanionRequestEnvelope, device: CompanionDeviceRecord?, macKey: P256.KeyAgreement.PrivateKey,
              now: Date) throws(CompanionAuthError) -> OpenedCompanionRequest {
        try envelope.open(device: device, macHPKEKey: macKey, replayCache: &cache, now: now)
    }

    func forget(deviceID: UUID) { cache.remove(deviceID: deviceID) }
}

/// Per-device limits (§7): 300 calls a minute, 2,000 captures a day.
actor DeviceLimits {
    static let callsPerMinute = 300
    static let capturesPerDay = 2_000

    private var calls: [UUID: [Date]] = [:]
    private var captures: [UUID: (day: Date, count: Int)] = [:]

    /// Nil when admitted, else the seconds until the oldest call leaves the window.
    func admitCall(deviceID: UUID, now: Date) -> Int? {
        var recent = calls[deviceID, default: []].filter { now.timeIntervalSince($0) < 60 }
        if recent.count >= Self.callsPerMinute {
            calls[deviceID] = recent
            return max(1, Int((60 - now.timeIntervalSince(recent[0])).rounded(.up)))
        }
        recent.append(now)
        calls[deviceID] = recent
        return nil
    }

    /// How many of `count` captures today's limit still takes, counting them.
    func admitCaptures(deviceID: UUID, count: Int, now: Date) -> Int {
        let day = Calendar(identifier: .gregorian).startOfDay(for: now)
        var entry: (day: Date, count: Int) = captures[deviceID].flatMap { $0.day == day ? $0 : nil } ?? (day: day, count: 0)
        let admitted = max(0, min(count, Self.capturesPerDay - entry.count))
        entry.count += admitted
        captures[deviceID] = entry
        return admitted
    }

    func forget(deviceID: UUID) {
        calls[deviceID] = nil
        captures[deviceID] = nil
    }
}
