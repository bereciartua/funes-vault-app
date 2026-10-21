import CryptoKit
import Foundation
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "companion")

/// Why a companion call or pairing didn't work, as the UI tells it apart.
public enum CompanionClientError: Error, Sendable, Equatable {
    case notPaired
    /// No address answered. `localNetworkDenied` when iOS refused the Bonjour browse, so the
    /// answer is Settings ▸ Privacy ▸ Local Network rather than "same Wi-Fi?".
    case unreachable(localNetworkDenied: Bool)
    /// The Mac refused the envelope (`401`): `revoked`, `unknown_device`, …
    case refused(CompanionAuthError)
    case pairing(PairingError)
    /// The QR code's 5 minutes are over.
    case qrExpired
    /// The call reached the Mac and returned an error (§4).
    case method(CompanionError)
    /// An answer that isn't the protocol's: another service on that port, or a broken reply.
    case badResponse(status: Int)
    /// Something on this iPhone failed: the Keychain or a key.
    case local
}

/// The paired Mac, reachable: where, what `status.get` said, and how long the round trip took.
public struct MacConnection: Sendable, Equatable {
    public var address: MacAddress
    public var status: CompanionStatus
    public var roundTrip: Duration
}

/// What one address's probe came to in the last address selection, for diagnosis.
public struct ProbeOutcome: Sendable, Equatable, Identifiable {
    public var address: MacAddress
    /// "ok", or why not: a transport error ("URLError -1022", "timed out") or a refusal code.
    public var outcome: String
    public var id: String { address.description }
}

/// One of Spike 1's protocol checks (row 1f) run from the phone against the Mac.
public struct ProtocolCheck: Sendable, Equatable, Identifiable {
    public var name: String
    public var expected: String
    public var got: String
    public var passed: Bool { expected == got }
    public var id: String { name }
}

/// The phone's side of the companion protocol (spec/architecture/companion-protocol.md): pairing
/// (§2), sealed calls (§3) and address selection (§5).
///
/// **Address selection:** a Bonjour hit for the paired Mac or a saved LAN address (same Wi-Fi),
/// then the saved Tailscale IP, then the tunnel URL. They're probed together with `status.get`
/// (3 s each), and the best-ranked one that answers wins as soon as nothing better is still
/// running. It's cached for 10 minutes, or until `networkChanged()`.
///
/// **Retries:** a `clock_skew` refusal is retried once with the Mac's clock. A call that gets no
/// answer at all starts address selection over and, if the method is safe to repeat, is sent
/// once more.
public actor CompanionClient {
    public static let probeTimeout: TimeInterval = 3
    public static let addressLifetime: TimeInterval = 600
    public static let bonjourTimeout: TimeInterval = 2
    /// The Mac gives a call 10 s (§7); a little more for the network.
    public static let callTimeout: TimeInterval = 15
    /// The Mac's Allow prompt waits 60 s; the phone waits at least 65 (§2.2, step 3).
    public static let pairTimeout: TimeInterval = 70

    /// Methods that can be sent twice without harm: reads, and captures (a duplicate `captureId`
    /// is accepted without creating anything, §6).
    static let repeatable: Set<CompanionMethod> = [.statusGet, .capturesSubmit, .categoriesList, .memoriesSearch, .memoriesGet, .inboxList]

    struct Paired {
        var record: PairingRecord
        var keys: DeviceKeys
        var macHPKEKey: P256.KeyAgreement.PublicKey
    }

    enum SendFailure: Error {
        /// No HTTP answer at all.
        case transport(TransportError)
        case client(CompanionClientError)
    }

    private let keyStore: DeviceKeyStore
    private let recordStore: PairingRecordStore
    private let transport: any CompanionTransport
    private let discovery: any MacDiscovery
    private let secureEnclave: Bool
    private let clock: @Sendable () -> Date

    private var paired: Paired?
    private var cached: (address: MacAddress, at: Date)?
    /// The Mac's clock minus ours, learnt from a `clock_skew` refusal.
    private var clockOffset: TimeInterval = 0
    /// Each probe of the last address selection (or pairing's), in the order they finished.
    public private(set) var lastProbes: [ProbeOutcome] = []

    public init(store: any SecretStore, transport: any CompanionTransport = CompanionHTTPTransport(),
                discovery: any MacDiscovery = BonjourDiscovery(), secureEnclave: Bool = SecureEnclave.isAvailable,
                clock: @escaping @Sendable () -> Date = Date.init) {
        keyStore = DeviceKeyStore(store: store)
        recordStore = PairingRecordStore(store: store)
        self.transport = transport
        self.discovery = discovery
        self.secureEnclave = secureEnclave
        self.clock = clock
    }

    // MARK: State

    /// The pairing record, or nil when this iPhone isn't paired.
    public func record() throws(CompanionClientError) -> PairingRecord? {
        do { return try loadPaired().record } catch {
            if error == .notPaired { return nil }
            throw error
        }
    }

    /// Whether the signing key is in the Secure Enclave. Nil when not paired.
    public func usesSecureEnclave() -> Bool? { (try? loadPaired())?.keys.signer.isSecureEnclave }

    /// The cached address, while it's fresh.
    public var currentAddress: MacAddress? {
        guard let cached, clock().timeIntervalSince(cached.at) < Self.addressLifetime else { return nil }
        return cached.address
    }

    /// The network changed (`NWPathMonitor`): select an address again on the next call.
    public func networkChanged() { cached = nil }

    private func loadPaired() throws(CompanionClientError) -> Paired {
        if let paired { return paired }
        let record: PairingRecord?, keys: DeviceKeys?
        do {
            record = try recordStore.load()
            keys = try keyStore.load()
        } catch {
            logger.error("Couldn't read the pairing from the Keychain")
            throw .local
        }
        guard let record, let keys else { throw .notPaired }
        guard let macKey = try? record.hpkeKey else { throw .local }
        let loaded = Paired(record: record, keys: keys, macHPKEKey: macKey)
        paired = loaded
        return loaded
    }

    private func now() -> Date { clock().addingTimeInterval(clockOffset) }

    // MARK: Status and calls

    /// `status.get` on the cached address, or address selection when there is none (or `fresh`).
    /// The reachability probe the app sends on every foreground.
    public func status(fresh: Bool = false) async throws(CompanionClientError) -> MacConnection {
        let paired = try loadPaired()
        if !fresh, let address = currentAddress {
            do { return try await probe(address, paired: paired, timeout: Self.probeTimeout) } catch {
                guard case .transport = error else { throw Self.clientError(error) }
                cached = nil
            }
        }
        return try await select(paired)
    }

    /// Sends one method call and returns its result.
    public func call<Call: CompanionCall>(_ call: Call.Type, _ params: Call.Params) async throws(CompanionClientError) -> Call.Result {
        let paired = try loadPaired()
        let address = try await reachableAddress(paired)
        do { return try await send(call, params, to: address, paired: paired, timeout: Self.callTimeout) } catch {
            guard case .transport = error else { throw Self.clientError(error) }
            cached = nil
            guard Self.repeatable.contains(Call.method) else { throw .unreachable(localNetworkDenied: false) }
        }
        let retry = try await select(paired).address
        do { return try await send(call, params, to: retry, paired: paired, timeout: Self.callTimeout) } catch {
            if case .transport = error { cached = nil }
            throw Self.clientError(error)
        }
    }

    private func reachableAddress(_ paired: Paired) async throws(CompanionClientError) -> MacAddress {
        if let address = currentAddress { return address }
        return try await select(paired).address
    }

    private func probe(_ address: MacAddress, paired: Paired, timeout: TimeInterval) async throws(SendFailure) -> MacConnection {
        let start = ContinuousClock.now
        let status = try await send(StatusGet.self, EmptyParams(), to: address, paired: paired, timeout: timeout)
        return MacConnection(address: address, status: status, roundTrip: ContinuousClock.now - start)
    }

    /// Seals, posts and opens one call. A `clock_skew` refusal is retried once with the Mac's time.
    private func send<Call: CompanionCall>(_ call: Call.Type, _ params: Call.Params, to address: MacAddress, paired: Paired,
                                           timeout: TimeInterval, skewRetry: Bool = true) async throws(SendFailure) -> Call.Result {
        let request = CompanionRequest(call, params: params)
        let sealed: SealedCompanionRequest
        do {
            sealed = try CompanionRequestEnvelope.seal(try request.encoded(), deviceID: paired.record.deviceID,
                                                       macHPKEKey: paired.macHPKEKey, signer: paired.keys.signer, now: now())
        } catch {
            logger.error("Couldn't seal a companion request")
            throw .client(.local)
        }
        let response: TransportResponse
        do { response = try await transport.post(address.url(CompanionProtocol.rpcPath), body: sealed.envelope.body, timeout: timeout) } catch {
            throw .transport(error)
        }
        switch response.status {
        case 200:
            guard let json = try? sealed.responseKey.open(response.body),
                  let reply = try? CompanionResponse<Call.Result>.decode(json), reply.id == request.id
            else { throw .client(.badResponse(status: 200)) }
            do { return try reply.get() } catch { throw .client(.method(error)) }
        case CompanionAuthError.httpStatus:
            let refusal = CompanionAuthError(body: response.body)
            if case let .clockSkew(serverTime) = refusal, skewRetry {
                clockOffset = serverTime.timeIntervalSince(clock())
                return try await send(call, params, to: address, paired: paired, timeout: timeout, skewRetry: false)
            }
            throw .client(.refused(refusal))
        default:
            throw .client(.badResponse(status: response.status))
        }
    }

    private static func clientError(_ failure: SendFailure) -> CompanionClientError {
        switch failure {
        case .transport: .unreachable(localNetworkDenied: false)
        case let .client(error): error
        }
    }

    // MARK: Address selection

    private func select(_ paired: Paired) async throws(CompanionClientError) -> MacConnection {
        let race = await race(saved: paired.record.addresses.macAddresses, tag: paired.record.bonjourTag) { address throws(SendFailure) in
            try await self.probe(address, paired: paired, timeout: Self.probeTimeout)
        }
        lastProbes = race.probes
        if let (address, connection) = race.winner {
            cached = (address, clock())
            logger.info("Reached the Mac over \(address.kind.rawValue, privacy: .public)") // log-safe: an address kind, not the address
            return connection
        }
        // Nothing answered properly. A refusal says more than silence; `revoked` most of all,
        // since only the paired Mac knows this device.
        let refusals = race.failures.compactMap { failure -> CompanionClientError? in
            if case let .client(error) = failure { return error }
            return nil
        }
        if refusals.contains(.refused(.revoked)) { throw .refused(.revoked) }
        if let refusal = refusals.first(where: { if case .refused = $0 { true } else { false } }) { throw refusal }
        throw .unreachable(localNetworkDenied: race.localNetworkDenied)
    }

    struct RaceResult<T: Sendable>: Sendable {
        var winner: (MacAddress, T)?
        var failures: [SendFailure] = []
        var probes: [ProbeOutcome] = []
        var localNetworkDenied = false
    }

    private enum RaceEvent<T: Sendable>: Sendable {
        case probed(MacAddress, Result<T, SendFailure>)
        case discovered(DiscoveryResult)
    }

    /// Probes the saved addresses and, at the same time, browses Bonjour and probes what it
    /// finds. Returns the best-ranked address that answered as soon as no better-ranked probe
    /// (or the browse, which counts as same Wi-Fi) is still running.
    private func race<T: Sendable>(saved: [MacAddress], tag: String,
                                   probe: @escaping @Sendable (MacAddress) async throws(SendFailure) -> T) async -> RaceResult<T> {
        let discovery = self.discovery
        return await withTaskGroup(of: RaceEvent<T>.self) { group in
            var pending: [Int] = []
            func start(_ address: MacAddress) {
                pending.append(address.kind.rank)
                group.addTask {
                    do throws(SendFailure) { return .probed(address, .success(try await probe(address))) } catch {
                        return .probed(address, .failure(error))
                    }
                }
            }
            saved.forEach(start)
            pending.append(MacAddress.Kind.bonjour.rank)
            group.addTask { .discovered(await discovery.find(tag: tag, timeout: Self.bonjourTimeout)) }

            var result = RaceResult<T>()
            while let event = await group.next() {
                switch event {
                case let .discovered(found):
                    pending.remove(at: pending.firstIndex(of: MacAddress.Kind.bonjour.rank)!)
                    result.localNetworkDenied = found.localNetworkDenied
                    found.addresses.filter { !saved.contains($0) }.forEach(start)
                case let .probed(address, outcome):
                    pending.remove(at: pending.firstIndex(of: address.kind.rank)!)
                    switch outcome {
                    case let .success(value):
                        if result.winner.map({ address.kind.rank < $0.0.kind.rank }) ?? true { result.winner = (address, value) }
                        result.probes.append(ProbeOutcome(address: address, outcome: "ok"))
                    case let .failure(failure):
                        result.failures.append(failure)
                        result.probes.append(ProbeOutcome(address: address, outcome: Self.describe(failure)))
                    }
                }
                if let winner = result.winner, !pending.contains(where: { $0 < winner.0.kind.rank }) {
                    group.cancelAll()
                    break
                }
            }
            // Probes still running when a winner was picked were cancelled.
            let finished = Set(result.probes.map(\.address))
            result.probes += saved.filter { !finished.contains($0) }.map { ProbeOutcome(address: $0, outcome: "not needed") }
            return result
        }
    }

    static func describe(_ failure: SendFailure) -> String {
        switch failure {
        case let .transport(error): error.reason
        case let .client(.refused(refusal)): refusal.code
        case let .client(.badResponse(status)): "HTTP \(status)"
        case let .client(error): "\(error)"
        }
    }

    // MARK: Pairing

    /// Pairs with the Mac whose QR code was scanned (§2.2): finds an address that answers, makes
    /// fresh device keys, and sends the sealed request, which waits for **Allow** on the Mac (up
    /// to 60 s). On success the keys and the pairing record are saved, replacing any older ones.
    public func pair(_ payload: PairingQRPayload, deviceName: String, model: String) async throws(CompanionClientError) -> PairingRecord {
        guard !payload.isExpired(at: clock()) else { throw .qrExpired }
        let race = await race(saved: payload.addresses.macAddresses, tag: CompanionBonjour.macTag(payload.macID)) { address throws(SendFailure) in
            try await self.hello(address)
        }
        lastProbes = race.probes
        guard let (address, _) = race.winner else { throw .unreachable(localNetworkDenied: race.localNetworkDenied) }

        let keys = DeviceKeys.fresh(secureEnclave: secureEnclave)
        let client: PairingClient, body: Data
        do {
            (client, body) = try PairingClient.start(payload: payload, deviceName: deviceName, model: model, signer: keys.signer,
                                                     deviceHPKEKey: keys.hpke, now: clock())
        } catch {
            logger.error("Couldn't build the pairing request")
            throw .local
        }
        let response: TransportResponse
        do { response = try await transport.post(address.url(CompanionProtocol.pairPath), body: body, timeout: Self.pairTimeout) } catch {
            throw .unreachable(localNetworkDenied: false)
        }
        let confirmation: PairConfirmation
        switch response.status {
        case 200:
            do { confirmation = try client.finish(responseBody: response.body) } catch { throw .pairing(error) }
        case PairingError.httpStatus:
            throw .pairing(PairingError(body: response.body))
        default:
            throw .badResponse(status: response.status)
        }

        let record = PairingRecord(payload: payload, confirmation: confirmation, deviceName: deviceName, pairedAt: clock())
        guard let macKey = try? record.hpkeKey else { throw .local }
        do {
            try keyStore.save(keys)
            try recordStore.save(record)
        } catch {
            logger.error("Couldn't save the pairing to the Keychain")
            throw .local
        }
        paired = Paired(record: record, keys: keys, macHPKEKey: macKey)
        cached = (address, clock())
        clockOffset = 0
        logger.info("Paired over \(address.kind.rawValue, privacy: .public)") // log-safe: an address kind, not the address
        return record
    }

    /// Before pairing there's no device id to seal a `status.get` with, so the probe is an empty
    /// POST to `/c/v1/rpc`: a Funes Mac answers `401 invalid_envelope` without reading further,
    /// and the pairing session's attempts aren't touched.
    private func hello(_ address: MacAddress) async throws(SendFailure) {
        let response: TransportResponse
        do { response = try await transport.post(address.url(CompanionProtocol.rpcPath), body: Data("{}".utf8), timeout: Self.probeTimeout) } catch {
            throw .transport(error)
        }
        guard response.status == CompanionAuthError.httpStatus, CompanionAuthError(body: response.body) == .invalidEnvelope else {
            throw .client(.badResponse(status: response.status))
        }
    }

    /// Unpair on the phone (§8): `device.unpair` if the Mac answers (best effort), then the keys
    /// and the pairing record are deleted either way.
    public func unpair() async throws(CompanionClientError) {
        if let paired = try? loadPaired(), let address = try? await reachableAddress(paired) {
            _ = try? await send(DeviceUnpair.self, EmptyParams(), to: address, paired: paired, timeout: Self.probeTimeout)
        }
        try forget()
    }

    /// Deletes the keys and the pairing record, without telling the Mac.
    public func forget() throws(CompanionClientError) {
        paired = nil
        cached = nil
        clockOffset = 0
        do {
            try recordStore.delete()
            try keyStore.delete()
        } catch {
            throw .local
        }
    }

    // MARK: Spike 1, row 1f

    /// Sends deliberately bad envelopes and reports what the Mac answered: a good call, the same
    /// envelope again, a tampered ciphertext, and a clock five minutes behind.
    public func protocolChecks() async throws(CompanionClientError) -> [ProtocolCheck] {
        let paired = try loadPaired()
        let address = try await reachableAddress(paired)
        func seal(at date: Date) throws(CompanionClientError) -> Data {
            do {
                let request = try CompanionRequest(StatusGet.self, params: EmptyParams()).encoded()
                return try CompanionRequestEnvelope.seal(request, deviceID: paired.record.deviceID, macHPKEKey: paired.macHPKEKey,
                                                         signer: paired.keys.signer, now: date).envelope.body
            } catch { throw .local }
        }
        func outcome(_ body: Data) async -> String {
            guard let response = try? await transport.post(address.url(CompanionProtocol.rpcPath), body: body, timeout: Self.callTimeout)
            else { return "no answer" }
            switch response.status {
            case 200: return "ok"
            case CompanionAuthError.httpStatus: return CompanionAuthError(body: response.body).code
            default: return "HTTP \(response.status)"
            }
        }
        let good = try seal(at: now())
        var checks = [ProtocolCheck(name: "Good envelope", expected: "ok", got: await outcome(good))]
        checks.append(ProtocolCheck(name: "Same envelope again", expected: "replay", got: await outcome(good)))
        checks.append(ProtocolCheck(name: "Tampered ciphertext", expected: "invalid_signature",
                                    got: await outcome(Self.flippingLastByte(of: "ct", in: try seal(at: now())))))
        checks.append(ProtocolCheck(name: "Clock 5 minutes behind", expected: "clock_skew",
                                    got: await outcome(try seal(at: now().addingTimeInterval(-300)))))
        return checks
    }

    static func flippingLastByte(of field: String, in body: Data) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let value = json[field] as? String, var bytes = Base64URL.decode(value), !bytes.isEmpty
        else { return body }
        bytes[bytes.count - 1] ^= 0x01
        json[field] = Base64URL.encode(bytes)
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }
}
