import BridgeKitCore
import CryptoKit
import Foundation
import FunesCore
import FunesProtocol
@testable import FunesCompanion

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A vault, the Mac's companion router, and a phone that can pair and call methods, all in one
/// process. Requests go straight to `CompanionRouter.handle`; `ListenerTests` adds the socket.
final class CompanionHarness: @unchecked Sendable {
    let directory: URL
    let store: VaultStore
    let activity = InMemoryActivityLog()
    let identity = MacIdentity()
    let services: CompanionServices
    let pairing: PairingService
    let router: CompanionRouter
    let clock: Clock

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = t0
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    /// A paired phone's keys and id.
    struct Phone {
        let signer = P256.Signing.PrivateKey()
        let hpke = P256.KeyAgreement.PrivateKey()
        var deviceID: UUID?
    }

    init(gate: TunnelGate? = nil, promptTimeout: TimeInterval = PairingService.defaultPromptTimeout) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "funes-companion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = try VaultStore.open(directory: directory)
        let pause = FunesPause()
        let search = SearchService(store: store, indexer: nil)
        let disclosures = DisclosureService(store: store, retriever: search, activity: activity, pause: pause)
        let agents = AgentService(store: store, keys: InMemoryAgentKeyStore(), activity: activity)
        services = CompanionServices(store: store, devices: DeviceService(store: store, activity: activity),
                                     captures: CaptureService(store: store, activity: activity),
                                     suggestions: SuggestionService(store: store, activity: activity, pause: pause, disclosures: disclosures),
                                     search: search, agents: agents, activity: activity)
        pairing = PairingService(identity: identity, devices: services.devices, activity: activity, promptTimeout: promptTimeout)
        let clock = Clock()
        self.clock = clock
        let handlers = CompanionHandlers(services: services, macName: { "Maya's MacBook Pro" }, appVersion: "0.2.0")
        router = CompanionRouter(identity: identity, devices: services.devices, pairing: pairing, handlers: handlers, gate: gate,
                                 clock: { clock.now })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func request(_ path: String, body: Data, host: String = "192.168.1.20:47626", method: String = "POST",
                        contentType: String = CompanionProtocol.envelopeContentType) -> HTTPRequest {
        HTTPRequest(method: method, target: path, path: path, version: "HTTP/1.1",
                    headers: [("host", host), ("content-type", contentType)], body: body)
    }

    // MARK: Pairing

    func qr() async -> PairingQRPayload {
        await pairing.start(macName: "Maya's MacBook Pro", addresses: [PairingAddress(kind: .lan, host: "maya.local", port: 47626)],
                            now: clock.now)
    }

    /// Sends a pairing request and answers the Allow prompt with `allow` once it shows.
    func pair(_ phone: inout Phone, payload: PairingQRPayload, allow: Bool = true, name: String = "Sam's iPhone",
              transport: DeviceTransport = .lan) async throws -> (HTTPResponse, PairingClient) {
        let (client, body) = try PairingClient.start(payload: payload, deviceName: name, model: "iPhone17,1", signer: phone.signer,
                                                     deviceHPKEKey: phone.hpke, now: clock.now)
        async let response = router.handle(Self.request(CompanionProtocol.pairPath, body: body), transport: transport)
        try await answerWhenAsked(allow)
        let result = await response
        if result.status == 200 { phone.deviceID = try client.finish(responseBody: result.body).deviceID }
        return (result, client)
    }

    /// Waits for the prompt (up to 2 s), then answers.
    func answerWhenAsked(_ allow: Bool) async throws {
        for _ in 0..<200 {
            if await pairing.isAsking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await pairing.answer(allow: allow)
    }

    func pairedPhone() async throws -> Phone {
        var phone = Phone()
        let (response, _) = try await pair(&phone, payload: await qr())
        precondition(response.status == 200)
        return phone
    }

    // MARK: Calls

    /// A sealed call; returns the HTTP response and, on 200, the decoded reply.
    func call<Call: CompanionCall>(_ call: Call.Type, _ params: Call.Params, phone: Phone, at: Date? = nil,
                                   transport: DeviceTransport = .lan) async throws -> (HTTPResponse, CompanionResponse<Call.Result>?) {
        let request = try CompanionRequest(call, params: params).encoded()
        let sealed = try CompanionRequestEnvelope.seal(request, deviceID: phone.deviceID!, macHPKEKey: identity.hpkeKey.publicKey,
                                                       signer: phone.signer, now: at ?? clock.now)
        let response = await router.handle(Self.request(CompanionProtocol.rpcPath, body: sealed.envelope.body), transport: transport)
        guard response.status == 200 else { return (response, nil) }
        let json = try sealed.responseKey.open(response.body)
        return (response, try CompanionResponse<Call.Result>.decode(json))
    }

    /// The result, or the call's error thrown.
    func result<Call: CompanionCall>(_ call: Call.Type, _ params: Call.Params, phone: Phone) async throws -> Call.Result {
        let (response, reply) = try await self.call(call, params, phone: phone)
        guard let reply else { throw CompanionAuthError(body: response.body) }
        return try reply.get()
    }
}

extension PairingService {
    var isAsking: Bool {
        if case .asking = state { return true }
        return false
    }
}
