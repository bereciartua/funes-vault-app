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
    let guardian: EnvelopeGuard
    let limits = DeviceLimits()
    let clock: @Sendable () -> Date

    /// `guardian` is the server's replay cache, kept across the routers a settings change makes;
    /// nil makes one starting now.
    public init(identity: MacIdentity, devices: DeviceService, pairing: PairingService, handlers: CompanionHandlers,
                gate: TunnelGate?, guardian: EnvelopeGuard? = nil, clock: @escaping @Sendable () -> Date = Date.init) {
        self.identity = identity
        self.devices = devices
        self.pairing = pairing
        self.handlers = handlers
        self.gate = gate
        self.guardian = guardian ?? EnvelopeGuard()
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
        let envelope: CompanionRequestEnvelope
        do { envelope = try CompanionRequestEnvelope(body: body) } catch {
            // Nothing parsed to bind a signature to.
            return .json(CompanionAuthError.httpStatus, error.body)
        }
        let opened: OpenedCompanionRequest
        do throws(CompanionAuthError) {
            let device: Device?
            // In a task of its own, so a client going away (which cancels this handler) can't
            // turn the lookup into `unavailable`.
            let lookup = Task { [devices] in try await devices.device(id: envelope.deviceID) }
            do { device = try await lookup.value } catch {
                // The database failed for a moment: not a verdict on the device (§3, step 1).
                logger.error("Couldn't look up a companion device")
                throw CompanionAuthError.unavailable
            }
            let record = device.flatMap { d in
                (try? P256.Signing.PublicKey(x963Representation: d.signingPublicKey))
                    .map { CompanionDeviceRecord(id: d.id, signingKey: $0, isRevoked: d.isRevoked) }
            }
            opened = try await guardian.open(envelope, device: record, macKey: identity.hpkeKey, now: now)
        } catch {
            // Signed and bound to this request, so the phone can trust it and nobody can replay it.
            return .json(CompanionAuthError.httpStatus,
                         error.signedBody(deviceID: envelope.deviceID, nonce: envelope.nonce, signer: identity.signingKey))
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

/// Holds the replay cache, so the check and the record happen together. One per server, kept
/// across settings changes, and with a journal on disk (`NonceJournal`) across relaunches: each
/// nonce is written through before its call runs, and loaded back at launch. So replay
/// protection doesn't depend on the phone's and the Mac's clocks agreeing.
///
/// Fails closed, refusing calls with `unavailable` (the phone retries), on the monotonic clock:
/// - a journal that exists but can't be read: for the replay window, since its nonces could be
///   replayed meanwhile;
/// - no journal (the first launch with one, or deleted): for twice the clock skew, past which
///   nothing the last run accepted can still pass the clock check (a phone up to the skew fast
///   sends a timestamp up to the skew ahead, which stays acceptable for up to twice the skew).
///   The file isn't created until a call is accepted after that, so a relaunch inside the window
///   starts it again;
/// - a nonce that can't be written: its call.
public actor EnvelopeGuard {
    private var cache = ReplayCache()
    private var journal: NonceJournal?
    private var blindUntil: ContinuousClock.Instant?
    /// With no journal, the window also waits for the wall clock: step 2 compares wall time, so a
    /// clock that steps back during it would otherwise let an old timestamp pass afterwards.
    private var blindUntilWall: Date?
    private let monotonic: @Sendable () -> ContinuousClock.Instant

    /// `journal` is the file to keep the nonces in; nil keeps them in memory only (tests).
    /// `monotonic` is the clock the refusal windows run on (tests move it).
    public init(journal url: URL? = nil, now: Date = Date(),
                monotonic: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.monotonic = monotonic
        guard let url else { return }
        var journal = NonceJournal(url: url)
        do {
            switch try journal.load(since: now.addingTimeInterval(-cache.window)) {
            case .missing:
                logger.error("No companion nonce journal; refusing calls for twice the clock-skew window")
                blindUntil = monotonic() + .seconds(2 * CompanionProtocol.maxClockSkew)
                blindUntilWall = now.addingTimeInterval(2 * CompanionProtocol.maxClockSkew)
            case let .entries(entries):
                for entry in entries {
                    cache.record(nonce: entry.nonce, deviceID: entry.deviceID, sentAt: entry.sentAt, now: entry.recordedAt)
                }
                try? journal.rewrite(cache.entries)
            }
        } catch {
            logger.error("The companion's nonce journal couldn't be read; refusing calls for the replay window")
            blindUntil = monotonic() + .seconds(cache.window)
        }
        self.journal = journal
    }

    /// The journal in the vault's folder.
    public static func journalURL(dataDirectory: URL) -> URL { dataDirectory.appending(path: NonceJournal.fileName) }

    func open(_ envelope: CompanionRequestEnvelope, device: CompanionDeviceRecord?, macKey: P256.KeyAgreement.PrivateKey,
              now: Date) throws(CompanionAuthError) -> OpenedCompanionRequest {
        if let blindUntil {
            guard monotonic() >= blindUntil, blindUntilWall.map({ now >= $0 }) ?? true else { throw .unavailable }
            self.blindUntil = nil
            blindUntilWall = nil
        }
        do {
            let opened = try envelope.open(device: device, macHPKEKey: macKey, replayCache: &cache, now: now)
            try write(envelope, now: now)
            return opened
        } catch .decryptionFailed {
            // Only after the signature verified, which is when the nonce was remembered.
            try write(envelope, now: now)
            throw .decryptionFailed
        }
    }

    private func write(_ envelope: CompanionRequestEnvelope, now: Date) throws(CompanionAuthError) {
        guard var journal else { return }
        defer { self.journal = journal }
        do {
            try journal.append(ReplayCache.Entry(deviceID: envelope.deviceID, nonce: envelope.nonce,
                                                 sentAt: Date(timeIntervalSince1970: Double(envelope.timestamp) / 1000), recordedAt: now))
            let live = cache.entries
            if journal.needsRewrite(live: live.count) { try journal.rewrite(live) }
        } catch {
            logger.error("The companion's nonce journal couldn't be written")
            throw .unavailable
        }
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
