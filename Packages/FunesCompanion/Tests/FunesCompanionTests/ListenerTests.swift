import BridgeKitCore
import Foundation
import Network
import os
import FunesProtocol
import Testing
@testable import FunesCompanion

/// The listener over a real socket. Only tunnel mode accepts loopback, so that's what the test
/// can reach; Same Wi-Fi and Tailscale refuse it before reading.
@Suite(.serialized) struct ListenerTests {
    static func freePort() -> Int { Int.random(in: 49_200...49_900) }

    func start(_ listener: CompanionListener) async throws -> Int {
        let ready = AsyncStream<CompanionListener.State>.makeStream()
        listener.start { ready.continuation.yield($0) }
        for await state in ready.stream {
            if case let .ready(port) = state { return port }
            if case .failed = state { throw CancellationError() }
        }
        throw CancellationError()
    }

    /// A raw HTTP/1.1 POST (URLSession may replace a `Host` header). The status code, or nil
    /// when the connection closed without a reply.
    func post(port: Int, path: String, host: String? = nil, body: Data = Data("{}".utf8)) async throws -> Int? {
        let head = "POST \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n"
            + "Content-Type: \(CompanionProtocol.envelopeContentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        defer { connection.cancel() }
        let queue = DispatchQueue(label: "test.client")
        connection.start(queue: queue)
        connection.send(content: Data(head.utf8) + body, completion: .idempotent)
        let reply: Data? = await withCheckedContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ data: Data?) {
                guard done.withLock({ let was = $0; $0 = true; return !was }) else { return }
                continuation.resume(returning: data)
            }
            connection.receive(minimumIncompleteLength: 12, maximumLength: 4_096) { data, _, _, _ in finish(data) }
            queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
        guard let reply, let line = String(data: reply.prefix(16), encoding: .utf8), line.hasPrefix("HTTP/1.1 ") else { return nil }
        return Int(line.dropFirst(9).prefix(3))
    }

    @Test func tunnelModeServesLoopback() async throws {
        let port = Self.freePort()
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil) { request, transport in
            #expect(transport == .tunnel)
            return HTTPResponse(status: request.path == "/hello" ? 204 : 404)
        }
        defer { listener.stop() }
        let bound = try await start(listener)
        #expect(bound == port)
        #expect(try await post(port: port, path: "/hello") == 204)
        #expect(try await post(port: port, path: "/other") == 404)
    }

    @Test func sameWiFiRefusesLoopbackBeforeReading() async throws {
        let port = Self.freePort()
        let listener = CompanionListener(port: port, modes: [.sameWiFi, .tailscale], bonjour: nil) { _, _ in
            Issue.record("A loopback request reached the handler")
            return HTTPResponse(status: 200)
        }
        defer { listener.stop() }
        _ = try await start(listener)
        #expect(try await post(port: port, path: "/c/v1/rpc") == nil)
    }

    @Test func oversizedBodiesAre413() async throws {
        let port = Self.freePort()
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil) { _, _ in HTTPResponse(status: 200) }
        defer { listener.stop() }
        _ = try await start(listener)
        let status = try await post(port: port, path: "/c/v1/rpc", body: Data(count: CompanionProtocol.maxRequestBytes + 1))
        #expect(status == 413 || status == nil)
    }

    /// The router behind the listener, end to end: a tunnel request with the secret path.
    @Test func routerThroughTheSocket() async throws {
        let gate = TunnelGate(secret: TunnelGate.newSecret(), publicHost: "maya.tailnet.ts.net")
        let h = try CompanionHarness(gate: gate)
        let port = Self.freePort()
        let router = h.router
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil) { await router.handle($0, transport: $1) }
        defer { listener.stop() }
        _ = try await start(listener)
        #expect(try await post(port: port, path: "/c/v1/rpc", host: "maya.tailnet.ts.net") == 404)
        #expect(try await post(port: port, path: "/r/\(gate.secret)/c/v1/rpc", host: "evil.example") == 421)
        // Right path and Host, but not an envelope: refused by the envelope check.
        #expect(try await post(port: port, path: "/r/\(gate.secret)/c/v1/rpc", host: "maya.tailnet.ts.net") == 401)
    }
}
