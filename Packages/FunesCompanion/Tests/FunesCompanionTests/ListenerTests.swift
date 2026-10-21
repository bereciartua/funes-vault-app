import BridgeKitCore
import Foundation
import Network
import os
import FunesProtocol
import Testing
@testable import FunesCompanion

/// The listener over a real socket. Only tunnel mode accepts loopback; Same Wi-Fi and Tailscale
/// refuse it before reading, so those modes are tested against the Mac's own LAN and Tailscale
/// addresses where it has them.
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
    func post(port: Int, path: String, host: String? = nil, to address: String = "127.0.0.1",
              body: Data = Data("{}".utf8)) async throws -> Int? {
        let head = "POST \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n"
            + "Content-Type: \(CompanionProtocol.envelopeContentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
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

    /// The Mac's own Tailscale IPv4 address (`100.64.0.0/10`), if Tailscale is up. Connecting
    /// to it from the Mac arrives from that address. Its LAN addresses can't stand in for Same
    /// Wi-Fi here: macOS's Local Network privacy drops LAN traffic for a test runner it hasn't
    /// approved, while Tailscale's CGNAT range isn't "local network".
    static let tailscaleAddress: String? = {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next?.pointee {
            next = entry.ifa_next
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { [UInt8]($0) } }
            if AddressPolicy.classify(bytes) == .tailscale { return bytes.map(String.init).joined(separator: ".") }
        }
        return nil
    }()

    /// Spike 1e: `NWListener` never completed the handshake on Tailscale's `utun` interface.
    @Test(.enabled(if: tailscaleAddress != nil, "Tailscale isn't up"))
    func acceptsOverTailscale() async throws {
        let address = try #require(Self.tailscaleAddress)
        let port = Self.freePort()
        let listener = CompanionListener(port: port, modes: [.sameWiFi, .tailscale], bonjour: nil) { _, transport in
            HTTPResponse(status: transport == .tailscale ? 204 : 500)
        }
        defer { listener.stop() }
        _ = try await start(listener)
        #expect(try await post(port: port, path: "/c/v1/rpc", to: address) == 204)
    }

    @Test(.enabled(if: tailscaleAddress != nil, "Tailscale isn't up"))
    func sameWiFiAloneRefusesTailscale() async throws {
        let address = try #require(Self.tailscaleAddress)
        let port = Self.freePort()
        let listener = CompanionListener(port: port, modes: [.sameWiFi], bonjour: nil) { _, _ in
            Issue.record("A Tailscale request reached the handler")
            return HTTPResponse(status: 200)
        }
        defer { listener.stop() }
        _ = try await start(listener)
        #expect(try await post(port: port, path: "/c/v1/rpc", to: address) == nil)
    }

    /// Tunnel-only binds loopback alone, IPv4 and IPv6: nothing outside the Mac reaches the port.
    @Test func tunnelOnlyListensOnLoopbackOnly() async throws {
        let port = Self.freePort()
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil) { _, transport in
            HTTPResponse(status: transport == .tunnel ? 204 : 500)
        }
        defer { listener.stop() }
        _ = try await start(listener)
        #expect(try await post(port: port, path: "/hello", to: "::1") == 204)
        if let address = Self.tailscaleAddress {
            #expect(try await post(port: port, path: "/hello", to: address) == nil)
        }
    }

    /// Keep-alive through URLSession, and a response larger than the socket's send buffer, which
    /// the listener writes as the socket drains.
    @Test func keepAliveAndLargeResponses() async throws {
        let port = Self.freePort()
        let large = Data((0..<8_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil) { request, _ in
            request.path == "/large" ? HTTPResponse(status: 200, body: large) : HTTPResponse(status: 204)
        }
        defer { listener.stop() }
        _ = try await start(listener)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for path in ["/small", "/large", "/small"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            let (body, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == (path == "/large" ? 200 : 204))
            if path == "/large" { #expect(body == large) }
        }
    }

    /// Settings changes restart the listener on the same port.
    @Test func restartsOnTheSamePort() async throws {
        let port = Self.freePort()
        for _ in 0..<3 {
            let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil) { _, _ in HTTPResponse(status: 204) }
            #expect(try await start(listener) == port)
            #expect(try await post(port: port, path: "/hello") == 204)
            listener.stop()
        }
    }

    @Test func portInUseIsReported() async throws {
        let port = Self.freePort()
        let first = CompanionListener(port: port, modes: [.sameWiFi], bonjour: nil) { _, _ in HTTPResponse(status: 200) }
        defer { first.stop() }
        _ = try await start(first)
        let second = CompanionListener(port: port, modes: [.sameWiFi], bonjour: nil) { _, _ in HTTPResponse(status: 200) }
        defer { second.stop() }
        let states = AsyncStream<CompanionListener.State>.makeStream()
        second.start { states.continuation.yield($0) }
        var failure: CompanionListener.Failure?
        for await state in states.stream {
            if case let .failed(reason) = state { failure = reason; break }
            if case .ready = state { break }
        }
        #expect(failure == .portInUse(port))
    }

    /// Same Wi-Fi advertises `_funes._tcp` with the TXT record, on the bound port.
    @Test func advertisesOverBonjour() async throws {
        let port = Self.freePort()
        let tag = UUID().uuidString.prefix(16).lowercased()
        let listener = CompanionListener(port: port, modes: [.sameWiFi], bonjour: ["v": "1", "mac": tag]) { _, _ in HTTPResponse(status: 200) }
        defer { listener.stop() }
        _ = try await start(listener)
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Identifiers.bonjourServiceType, domain: "local."), using: NWParameters())
        defer { browser.cancel() }
        let found: Bool = await withCheckedContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ found: Bool) {
                guard done.withLock({ let was = $0; $0 = true; return !was }) else { return }
                continuation.resume(returning: found)
            }
            browser.browseResultsChangedHandler = { results, _ in
                if results.contains(where: { if case let .bonjour(txt) = $0.metadata { txt["mac"] == tag } else { false } }) { finish(true) }
            }
            let queue = DispatchQueue(label: "test.browser")
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { finish(false) }
        }
        #expect(found)
    }
}
