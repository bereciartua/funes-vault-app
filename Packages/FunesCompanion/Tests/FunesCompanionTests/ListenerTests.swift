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

    /// A connection that's open and ready, sending nothing.
    func openIdle(port: Int) async -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    if done.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume() }
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "test.idle"))
        }
        return connection
    }

    /// Whether the listener closes `connection` within `seconds`.
    func closes(_ connection: NWConnection, within seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ closed: Bool) {
                guard done.withLock({ let was = $0; $0 = true; return !was }) else { return }
                continuation.resume(returning: closed)
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, complete, error in
                finish(complete || error != nil || data == nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(false) }
        }
    }

    /// One address can't hold every slot: past its share, its connections are closed at once,
    /// and a slot comes back when one of its connections goes.
    @Test func capsConnectionsPerAddress() async throws {
        let port = Self.freePort()
        var limits = CompanionListener.Limits()
        limits.maxPerAddress = 2
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil, limits: limits) { _, _ in HTTPResponse(status: 204) }
        defer { listener.stop() }
        _ = try await start(listener)
        // The kernel hands connections over in order, so these two are taken before the third.
        let first = await openIdle(port: port), second = await openIdle(port: port)
        #expect(try await post(port: port, path: "/hello") == nil)
        first.cancel()
        // Its slot comes back once the listener sees it close.
        var status: Int?
        for _ in 0..<50 where status == nil { status = try await post(port: port, path: "/hello") }
        #expect(status == 204)
        second.cancel()
    }

    /// 8 from any one address; 16 from one IPv6 /64, however many aliases, so a neighbour on the
    /// same network keeps its own 8; IPv4 addresses (plain or mapped) only the first cap.
    @Test func capGroups() {
        let limits = CompanionListener.Limits()
        func v6(_ host: UInt8, net: UInt8 = 1) -> [UInt8] { [0xfd, 0x12, 0x34, 0x56, 0, 0, 0, net, 0xaa, 0, 0, 0, 0, 0, 0, host] }
        func mapped(_ host: UInt8) -> [UInt8] { [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, host] }
        // Every open connection busy, so a full table refuses rather than evicts.
        func admits(_ address: [UInt8], _ open: [[UInt8]]) -> Bool {
            CompanionListener.admission(address, among: open.map { .init(address: $0, busy: true, idleSince: 0) }, limits: limits) != .refuse
        }

        // One address: 8.
        #expect(admits(v6(1), Array(repeating: v6(1), count: 7)))
        #expect(!admits(v6(1), Array(repeating: v6(1), count: 8)))
        // Aliases in one /64 (8 each from two of them): no more from that /64, a neighbour too.
        let aliases = Array(repeating: v6(1), count: 8) + Array(repeating: v6(2), count: 8)
        #expect(!admits(v6(3), aliases))
        // Under 16 there, a neighbour gets its own 8; another /64 isn't counted.
        #expect(admits(v6(3), Array(repeating: v6(1), count: 8) + Array(repeating: v6(2), count: 7)))
        #expect(admits(v6(1, net: 2), aliases))
        // IPv4, plain or mapped, is one address each, and never counts against a /64.
        #expect(admits([192, 168, 1, 21], Array(repeating: [192, 168, 1, 20], count: 8)))
        #expect(!admits(mapped(20), Array(repeating: [192, 168, 1, 20], count: 8)))
        #expect(admits(mapped(21), Array(repeating: mapped(20), count: 8) + aliases))
        // The total stays 32.
        #expect(!admits([10, 0, 0, 1], (0..<32).map { [10, 0, 1, UInt8($0)] }))
    }

    /// A full table makes way for a newcomer by closing the connection idle longest, never one
    /// handling a request; with every connection busy, the newcomer is refused. A newcomer over
    /// its own address's cap never evicts anyone.
    @Test func aFullTableEvictsTheLongestIdle() {
        let limits = CompanionListener.Limits()
        let hosts: [[UInt8]] = (0..<32).map { [192, 168, 1, UInt8(100 + $0)] }
        var open = hosts.enumerated().map { CompanionListener.Peer(address: $1, busy: false, idleSince: UInt64(100 + $0)) }
        open[5].idleSince = 7
        open[3].busy = true
        open[3].idleSince = 1
        #expect(CompanionListener.admission([192, 168, 1, 20], among: open, limits: limits) == .evict(5))
        let allBusy = open.map { CompanionListener.Peer(address: $0.address, busy: true, idleSince: $0.idleSince) }
        #expect(CompanionListener.admission([192, 168, 1, 20], among: allBusy, limits: limits) == .refuse)
        let sameHost = Array(repeating: CompanionListener.Peer(address: [192, 168, 1, 9], busy: false, idleSince: 1), count: 8)
            + open.prefix(24)
        #expect(CompanionListener.admission([192, 168, 1, 9], among: sameHost, limits: limits) == .refuse)
        #expect(CompanionListener.admission([192, 168, 1, 20], among: Array(open.prefix(31)), limits: limits) == .admit)
    }

    /// Over a real socket: a table full of idle connections lets the phone in; one full of
    /// connections handling requests doesn't, and none of them is closed.
    @Test func aFullTableOfIdleConnectionsAdmitsANewcomer() async throws {
        let port = Self.freePort()
        var limits = CompanionListener.Limits()
        limits.maxConnections = 3
        let released = OSAllocatedUnfairLock(initialState: false)
        let started = AsyncStream<Void>.makeStream()
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil, limits: limits) { request, _ in
            if request.path == "/hold" {
                started.continuation.yield()
                while !released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
            }
            return HTTPResponse(status: 204)
        }
        defer { listener.stop() }
        _ = try await start(listener)
        let idle = [await openIdle(port: port), await openIdle(port: port), await openIdle(port: port)]
        defer { idle.forEach { $0.cancel() } }
        var status: Int?
        for _ in 0..<50 where status == nil { status = try await post(port: port, path: "/hello") }
        #expect(status == 204)
        #expect(await closes(idle[0], within: 3))

        // Three requests in progress fill it: the newcomer is refused, and they all finish.
        let held = [await send(port: port, path: "/hold", host: "127.0.0.1:\(port)", body: Data("{}".utf8)),
                    await send(port: port, path: "/hold", host: "127.0.0.1:\(port)", body: Data("{}".utf8)),
                    await send(port: port, path: "/hold", host: "127.0.0.1:\(port)", body: Data("{}".utf8))]
        defer { held.forEach { $0.cancel() } }
        var arrivals = started.stream.makeAsyncIterator()
        for _ in 0..<3 { _ = await arrivals.next() }
        #expect(try await post(port: port, path: "/hello") == nil)
        for connection in held { #expect(!(await closes(connection, within: 0.3))) }
        released.withLock { $0 = true }
    }

    /// A connection that sends nothing is closed after the first-byte deadline, well before the
    /// 30 s idle one.
    @Test func closesAConnectionThatSendsNothing() async throws {
        let port = Self.freePort()
        var limits = CompanionListener.Limits()
        limits.firstByte = 0.3
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil, limits: limits) { _, _ in HTTPResponse(status: 204) }
        defer { listener.stop() }
        _ = try await start(listener)
        let silent = await openIdle(port: port)
        defer { silent.cancel() }
        #expect(await closes(silent, within: 3))
        #expect(try await post(port: port, path: "/hello") == 204)
        #expect(CompanionListener.firstByteTimeout < CompanionListener.idleTimeout)
    }

    /// Sends a request on a raw connection and leaves it open, for the caller to close.
    func send(port: Int, path: String, host: String, body: Data) async -> NWConnection {
        let connection = await openIdle(port: port)
        let head = "POST \(path) HTTP/1.1\r\nHost: \(host)\r\nContent-Type: \(CompanionProtocol.envelopeContentType)\r\n"
            + "Content-Length: \(body.count)\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .idempotent)
        return connection
    }

    /// A client that goes away while its request is handled cancels the handler.
    @Test func aClientThatGoesAwayCancelsItsHandler() async throws {
        let port = Self.freePort()
        let gate = AsyncStream<String>.makeStream()
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil) { _, _ in
            gate.continuation.yield("started")
            await withTaskCancellationHandler {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            } onCancel: { gate.continuation.yield("cancelled") }
            return HTTPResponse(status: 204)
        }
        defer { listener.stop() }
        _ = try await start(listener)
        let client = await send(port: port, path: "/hello", host: "127.0.0.1:\(port)", body: Data("{}".utf8))
        var events = gate.stream.makeAsyncIterator()
        #expect(await events.next() == "started")
        client.cancel()
        #expect(await events.next() == "cancelled")
    }

    /// The phone cancels its pairing while the Mac asks: the prompt is withdrawn as a Deny, and
    /// an Allow afterwards registers nothing.
    @Test func aPairingWhoseClientGoesAwayIsWithdrawn() async throws {
        let gate = TunnelGate(secret: TunnelGate.newSecret(), publicHost: "maya.tailnet.ts.net")
        let h = try CompanionHarness(gate: gate)
        let port = Self.freePort()
        let router = h.router
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil) { await router.handle($0, transport: $1) }
        defer { listener.stop() }
        _ = try await start(listener)
        let phone = CompanionHarness.Phone()
        let (_, body) = try PairingClient.start(payload: await h.qr(), deviceName: "Sam's iPhone", model: "iPhone17,1",
                                                signer: phone.signer, deviceHPKEKey: phone.hpke, now: h.clock.now)
        let client = await send(port: port, path: "/r/\(gate.secret)\(CompanionProtocol.pairPath)", host: "maya.tailnet.ts.net", body: body)
        for _ in 0..<300 where !(await h.pairing.isAsking) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await h.pairing.isAsking)
        client.cancel()
        for _ in 0..<300 where await h.pairing.isAsking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await h.pairing.state == .ended(.denied))
        await h.pairing.answer(allow: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await h.services.devices.devices().isEmpty)
    }

    /// A listener that stops (a Settings ▸ iPhone change restarts it) while the Mac asks closes
    /// the phone's connection and withdraws the prompt the same way.
    @Test func aPairingIsWithdrawnWhenTheListenerStops() async throws {
        let gate = TunnelGate(secret: TunnelGate.newSecret(), publicHost: "maya.tailnet.ts.net")
        let h = try CompanionHarness(gate: gate)
        let port = Self.freePort()
        let router = h.router
        let listener = CompanionListener(port: port, modes: [.tunnel], bonjour: nil) { await router.handle($0, transport: $1) }
        _ = try await start(listener)
        let phone = CompanionHarness.Phone()
        let (_, body) = try PairingClient.start(payload: await h.qr(), deviceName: "Sam's iPhone", model: "iPhone17,1",
                                                signer: phone.signer, deviceHPKEKey: phone.hpke, now: h.clock.now)
        let client = await send(port: port, path: "/r/\(gate.secret)\(CompanionProtocol.pairPath)", host: "maya.tailnet.ts.net", body: body)
        defer { client.cancel() }
        for _ in 0..<300 where !(await h.pairing.isAsking) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await h.pairing.isAsking)
        listener.stop()
        for _ in 0..<300 where await h.pairing.isAsking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await h.pairing.state == .ended(.denied))
        await h.pairing.answer(allow: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await h.services.devices.devices().isEmpty)
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
