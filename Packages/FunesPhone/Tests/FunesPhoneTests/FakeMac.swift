import CryptoKit
import Foundation
import FunesProtocol
@testable import FunesPhone

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date = t0) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// A Mac built from FunesProtocol's Mac-side pieces: it opens pairing requests and envelopes,
/// answers `status.get`, `captures.submit` and `device.unpair`, and counts what it saw.
final class FakeMac: @unchecked Sendable {
    let macID = UUID()
    let signing = P256.Signing.PrivateKey()
    let hpke = P256.KeyAgreement.PrivateKey()
    let clock: TestClock
    private let lock = NSLock()
    private var devices: [UUID: CompanionDeviceRecord] = [:]
    private var cache = ReplayCache()
    private var secret = Data()
    private var receipts: Set<UUID> = []
    /// Captures stored, in order: a duplicate `captureId` isn't stored again.
    private(set) var stored: [UUID] = []
    var allow = true
    /// What `status.get` says to call the user by (ADR-0026).
    var calledName: String?
    private(set) var statusCalls = 0
    private(set) var captureCalls = 0
    private(set) var unpaired: [UUID] = []
    private(set) var pairAttempts = 0

    /// How far the Mac's clock is ahead of the phone's.
    var skew: TimeInterval = 0
    var now: Date { clock.now.addingTimeInterval(skew) }

    init(clock: TestClock) { self.clock = clock }

    func payload(_ addresses: [PairingAddress], expiresIn: TimeInterval = 300) -> PairingQRPayload {
        let (pid, secret) = PairingQRPayload.newSession()
        lock.withLock { self.secret = secret }
        return PairingQRPayload(pairingID: pid, macID: macID, macName: "Maya's MacBook Pro", macSigningKey: signing.publicKey,
                                macHPKEKey: hpke.publicKey, secret: secret, expiresAt: now.addingTimeInterval(expiresIn),
                                addresses: addresses)
    }

    func revoke(_ deviceID: UUID) { lock.withLock { devices[deviceID]?.isRevoked = true } }

    var receiptCount: Int { lock.withLock { receipts.count } }

    func handle(path: String, body: Data) -> TransportResponse {
        // A tunnel URL's secret prefix comes first.
        guard let range = path.range(of: "/c/v1/") else { return TransportResponse(status: 404, body: Data()) }
        switch "/c/v1/" + path[range.upperBound...] {
        case CompanionProtocol.pairPath: return pair(body)
        case CompanionProtocol.rpcPath: return rpc(body)
        default: return TransportResponse(status: 404, body: Data())
        }
    }

    private func pair(_ body: Data) -> TransportResponse {
        lock.withLock { pairAttempts += 1 }
        do {
            let opened = try OpenedPairRequest(body: body, macHPKEKey: hpke, now: now)
            let secret = lock.withLock { self.secret }
            guard opened.request.transcript(macID: macID).isValidProof(opened.request.proof, secret: secret) else {
                throw PairingError.invalidProof
            }
            guard allow else { throw PairingError.denied }
            let deviceID = UUID()
            let key = try P256.Signing.PublicKey(x963Representation: opened.request.deviceSigningKey)
            lock.withLock { devices[deviceID] = CompanionDeviceRecord(id: deviceID, signingKey: key, isRevoked: false) }
            return TransportResponse(status: 200, body: try opened.confirmationBody(deviceID: deviceID, macID: macID, secret: secret,
                                                                                    macSigner: signing))
        } catch let error as PairingError {
            return TransportResponse(status: PairingError.httpStatus, body: error.body)
        } catch {
            return TransportResponse(status: 500, body: Data())
        }
    }

    private func rpc(_ body: Data) -> TransportResponse {
        let opened: OpenedCompanionRequest
        do {
            let envelope = try CompanionRequestEnvelope(body: body)
            opened = try lock.withLock {
                try envelope.open(device: devices[envelope.deviceID], macHPKEKey: hpke, replayCache: &cache, now: now)
            }
        } catch let error as CompanionAuthError {
            return TransportResponse(status: CompanionAuthError.httpStatus, body: error.body)
        } catch {
            return TransportResponse(status: 500, body: Data())
        }
        guard let head = try? CompanionRequestHead(plaintext: opened.plaintext) else { return TransportResponse(status: 500, body: Data()) }
        let reply: Data
        switch head.method {
        case .statusGet:
            lock.withLock { statusCalls += 1 }
            let status = CompanionStatus(macName: "Maya's MacBook Pro", appVersion: "0.2.0", serverTime: now, inboxPending: 2,
                                         vaultActive: true, calledName: lock.withLock { calledName })
            reply = try! CompanionResponse(id: head.id, result: status).encoded()
        case .capturesSubmit:
            let params = try! head.params(CapturesSubmit.self)
            let ids = params.captures.map(\.captureId)
            lock.withLock {
                captureCalls += 1
                for id in ids where receipts.insert(id).inserted { stored.append(id) }
            }
            reply = try! CompanionResponse(id: head.id, result: CapturesSubmitResult(accepted: ids, rejected: [])).encoded()
        case .deviceUnpair:
            lock.withLock {
                unpaired.append(opened.deviceID)
                devices[opened.deviceID]?.isRevoked = true
            }
            reply = try! CompanionResponse(id: head.id, result: EmptyResult()).encoded()
        default:
            reply = try! CompanionResponse<EmptyResult>(id: head.id, error: CompanionError(.unknownMethod)).encoded()
        }
        return TransportResponse(status: 200, body: try! opened.responseKey.seal(reply))
    }
}

/// Routes each request by its host: to the fake Mac, to nothing (refused), to silence (times
/// out after the caller's timeout), or to another HTTP service.
final class RoutedTransport: CompanionTransport, @unchecked Sendable {
    enum Route {
        case mac(FakeMac)
        case refused
        case silent
        case status(Int)
    }

    private let lock = NSLock()
    private var routes: [String: Route]
    private(set) var hosts: [String] = []
    /// Drops the Mac's answer after it has handled the request, like a lost response.
    var dropResponses = false

    init(_ routes: [String: Route]) { self.routes = routes }

    func set(_ host: String, _ route: Route) { lock.withLock { routes[host] = route } }

    func post(_ url: URL, body: Data, timeout: TimeInterval) async throws(TransportError) -> TransportResponse {
        let host = url.host() ?? ""
        let (route, drop) = lock.withLock {
            hosts.append(host)
            return (routes[host] ?? .refused, dropResponses)
        }
        switch route {
        case let .mac(mac):
            let response = mac.handle(path: url.path(), body: body)
            if drop { throw TransportError("connection lost") }
            return response
        case .refused:
            throw TransportError("refused")
        case .silent:
            try? await Task.sleep(for: .seconds(timeout))
            throw .timedOut
        case let .status(code):
            return TransportResponse(status: code, body: Data())
        }
    }

    func count(_ host: String) -> Int { lock.withLock { hosts.filter { $0 == host }.count } }
}

struct FakeDiscovery: MacDiscovery {
    var result: DiscoveryResult
    var delay: Duration = .zero

    func find(tag: String, timeout: TimeInterval) async -> DiscoveryResult {
        if delay > .zero { try? await Task.sleep(for: delay) }
        return result
    }
}

enum Addresses {
    static let lan = PairingAddress(kind: .lan, host: "192.168.1.20", port: 47626)
    static let tailscale = PairingAddress(kind: .tailscale, host: "100.101.102.103", port: 47626)
    static let tunnel = PairingAddress(kind: .tunnel, url: "https://maya.example.ts.net/r/abc123")
    static let all = [lan, tailscale, tunnel]
}
