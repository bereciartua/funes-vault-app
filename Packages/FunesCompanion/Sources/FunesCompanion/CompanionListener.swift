import BridgeKitCore
import Foundation
import Darwin
import FunesProtocol

/// The companion's TCP listener (§5): every interface on 47626, but each connection is accepted
/// or refused by its remote address before a byte is read (`AddressPolicy`). Plain HTTP/1.1:
/// confidentiality and integrity come from the envelope. Advertises `_funes._tcp` while Same
/// Wi-Fi is on.
///
/// BSD sockets with dispatch sources, not `NWListener`, which never completes the handshake for
/// connections arriving over Tailscale (`ListeningSocket`). One dual-stack socket on `::`; in
/// tunnel-only mode, `127.0.0.1` and `::1` instead, so nothing outside the Mac reaches the port.
///
/// One request at a time per connection, with fixed deadlines that later bytes don't extend: the
/// first byte within 5 s of the connection, the whole request within 10 s of its first byte, 30 s
/// idle between requests. At most 32 connections, 8 from any one address and 16 from any one IPv6
/// /64 (a host can take any number of IPv6 aliases), so
/// one host on the network can't hold every slot.
public final class CompanionListener: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest, DeviceTransport) async -> HTTPResponse

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready(port: Int)
        case failed(Failure)
    }

    public enum Failure: Equatable, Sendable {
        case portInUse(Int)
        case other(String)
    }

    public static let requestTimeout: TimeInterval = 10
    public static let idleTimeout: TimeInterval = 30
    /// A new connection that sends nothing for this long is closed.
    public static let firstByteTimeout: TimeInterval = 5
    public static let maxConnections = 32
    public static let maxConnectionsPerAddress = 8
    /// Every address in one IPv6 /64 together: half the slots, so a host with many aliases can't
    /// take them all, and ordinary IPv6 neighbours on the same network keep their own 8 each.
    public static let maxConnectionsPerIPv6Prefix = 16

    private let queue = DispatchQueue(label: "com.funesvault.companion.listener")
    private let port: Int
    private let modes: CompanionModes
    private let bonjour: [String: String]?
    private let handler: Handler
    private let limits: Limits
    private var sources: [DispatchSourceRead] = []
    private let socketsClosed = DispatchGroup()
    private var stopped = false
    private var advertiser: BonjourAdvertiser?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var stateChanged: (@Sendable (State) -> Void)?

    /// The connection caps and deadlines; tests shorten them.
    struct Limits: Sendable {
        var maxConnections = CompanionListener.maxConnections
        var maxPerAddress = CompanionListener.maxConnectionsPerAddress
        var maxPerIPv6Prefix = CompanionListener.maxConnectionsPerIPv6Prefix
        var firstByte = CompanionListener.firstByteTimeout
        var request = CompanionListener.requestTimeout
        var idle = CompanionListener.idleTimeout
    }

    /// `bonjour` is the TXT record to advertise, or nil not to advertise.
    public convenience init(port: Int, modes: CompanionModes, bonjour: [String: String]?, handler: @escaping Handler) {
        self.init(port: port, modes: modes, bonjour: bonjour, limits: Limits(), handler: handler)
    }

    init(port: Int, modes: CompanionModes, bonjour: [String: String]?, limits: Limits, handler: @escaping Handler) {
        self.port = port
        self.modes = modes
        self.bonjour = bonjour
        self.limits = limits
        self.handler = handler
    }

    /// `stateChanged` is called on the main queue.
    public func start(stateChanged: @escaping @Sendable (State) -> Void) {
        queue.async { [self] in
            guard !stopped else { return }
            self.stateChanged = stateChanged
            report(.starting)
            let sockets: [ListeningSocket]
            do throws(POSIXError) {
                sockets = try Self.bind(port: port, localOnly: modes == [.tunnel])
            } catch {
                report(.failed(error.code == .EADDRINUSE ? .portInUse(port) : .other(String(cString: strerror(error.code.rawValue)))))
                return
            }
            for socket in sockets {
                let source = DispatchSource.makeReadSource(fileDescriptor: socket.fd, queue: queue)
                source.setEventHandler { [weak self] in
                    while let (fd, address) = socket.accept() {
                        if let self { self.accept(fd, address: address) } else { Darwin.close(fd) }
                    }
                }
                socketsClosed.enter()
                source.setCancelHandler { [socketsClosed] in
                    Darwin.close(socket.fd)
                    socketsClosed.leave()
                }
                source.resume()
                sources.append(source)
            }
            let bound = sockets[0].port
            if let bonjour, modes.contains(.sameWiFi) {
                advertiser = BonjourAdvertiser(port: bound, txtRecord: bonjour, queue: queue)
            }
            report(.ready(port: bound))
        }
    }

    /// Returns once the port is free again, so a new listener can bind it at once.
    public func stop() {
        queue.sync {
            stopped = true
            stateChanged = nil
            advertiser?.stop()
            advertiser = nil
            for source in sources { source.cancel() }
            sources = []
            closeAll()
        }
        _ = socketsClosed.wait(timeout: .now() + 1)
    }

    /// Port 0 binds the first socket to a free port and the rest to the same one.
    private static func bind(port: Int, localOnly: Bool) throws(POSIXError) -> [ListeningSocket] {
        guard localOnly else { return [try ListeningSocket(.any, port: port)] }
        let first = try ListeningSocket(.loopbackIPv4, port: port)
        do {
            return [first, try ListeningSocket(.loopbackIPv6, port: first.port)]
        } catch where error.code == .EADDRNOTAVAIL || error.code == .EAFNOSUPPORT {
            return [first]  // No IPv6 loopback.
        } catch {
            Darwin.close(first.fd)
            throw error
        }
    }

    private func accept(_ fd: Int32, address: [UInt8]) {
        guard let transport = AddressPolicy.transport(forAddress: address, modes: modes),
              Self.admits(address, among: connections.values.map(\.address), limits: limits) else {
            Darwin.close(fd)
            return
        }
        let connection = Connection(fd, address: address, transport: transport, limits: limits, queue: queue, handler: handler)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.onClose = { [weak self] in self?.connections[key] = nil }
        connection.start()
    }

    /// Whether a connection from `address` fits beside those from `open`: under the total, under
    /// 8 from that address, and, for IPv6, under 16 from its /64.
    static func admits(_ address: [UInt8], among open: [[UInt8]], limits: Limits) -> Bool {
        guard open.count < limits.maxConnections else { return false }
        let peer = peerAddress(address)
        guard open.count(where: { peerAddress($0) == peer }) < limits.maxPerAddress else { return false }
        guard let prefix = ipv6Prefix(address) else { return true }
        return open.count(where: { ipv6Prefix($0) == prefix }) < limits.maxPerIPv6Prefix
    }

    /// An IPv4-mapped IPv6 address as the IPv4 address it is (the socket is dual-stack).
    static func peerAddress(_ address: [UInt8]) -> [UInt8] {
        guard address.count == 16, address[0..<10].allSatisfy({ $0 == 0 }), address[10] == 0xff, address[11] == 0xff else {
            return address
        }
        return Array(address[12...])
    }

    /// The /64 of an IPv6 address; nil for IPv4, plain or mapped.
    static func ipv6Prefix(_ address: [UInt8]) -> [UInt8]? {
        let peer = peerAddress(address)
        return peer.count == 16 ? Array(peer[0..<8]) : nil
    }

    private func closeAll() {
        for connection in Array(connections.values) { connection.close() }
        connections.removeAll()
    }

    private func report(_ state: State) {
        let callback = stateChanged
        DispatchQueue.main.async { callback?(state) }
    }

    /// One accepted connection on a non-blocking socket. All state is touched on the listener's
    /// queue. The socket is closed once every dispatch source on it has been cancelled.
    private final class Connection: @unchecked Sendable {
        private let fd: Int32
        /// The remote address, for the per-address cap.
        let address: [UInt8]
        private let transport: DeviceTransport
        private let limits: Limits
        private let queue: DispatchQueue
        private let handler: Handler
        private var parser = HTTPParser(limits: HTTPLimits(maxBodyBytes: CompanionProtocol.maxRequestBytes))
        private var busy = false
        private var closed = false
        private var timer: DispatchSourceTimer?
        private var reader: DispatchSourceRead?
        private var readerSuspended = false
        private var writer: DispatchSourceWrite?
        private var liveSources = 0
        private var outbox = Data()
        private var written = 0
        private var drained: [@Sendable () -> Void] = []
        /// The handler of the request being answered, cancelled if the client goes away.
        private var handling: Task<Void, Never>?
        var onClose: (@Sendable () -> Void)?

        init(_ fd: Int32, address: [UInt8], transport: DeviceTransport, limits: Limits, queue: DispatchQueue,
             handler: @escaping Handler) {
            self.fd = fd
            self.address = address
            self.transport = transport
            self.limits = limits
            self.queue = queue
            self.handler = handler
        }

        func start() {
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            track(reader)
            reader.setEventHandler { [weak self] in self?.readAvailable() }
            self.reader = reader
            reader.resume()
            arm(limits.firstByte)
        }

        /// Reads only while no request is being handled; bytes that arrive meanwhile wait in the
        /// socket.
        private func receive() {
            guard !closed, !busy, readerSuspended, let reader else { return }
            readerSuspended = false
            reader.resume()
        }

        private func pauseReading() {
            guard !readerSuspended, let reader else { return }
            readerSuspended = true
            reader.suspend()
        }

        private func readAvailable() {
            guard !closed else { return }
            if busy {
                clientGoneWhileBusy()
                return
            }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if !parser.hasBufferedBytes { arm(limits.request) }
                feed(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                close()
            }
        }

        private func feed(_ data: Data) {
            switch parser.feed(data) {
            case .needMore: break
            case .expectContinue: send(HTTPResponse.continueBytes)
            case let .request(request): handle(request)
            case let .error(status): write(HTTPResponse(status: status), close: true)
            }
        }

        /// While a request is handled the socket is only watched, not read: a client that goes
        /// away cancels its handler (a pairing request waiting for Allow is then denied, §2.2),
        /// and a pipelined request waits in the socket until this one is answered.
        private func clientGoneWhileBusy() {
            var byte: UInt8 = 0
            let peeked = recv(fd, &byte, 1, MSG_PEEK)
            if peeked > 0 {
                pauseReading()
            } else if peeked == 0 || (errno != EAGAIN && errno != EINTR) {
                handling?.cancel()
                close()
            }
        }

        private func handle(_ request: HTTPRequest) {
            busy = true
            timer?.cancel()
            let transport = self.transport, handler = self.handler
            handling = Task {
                let response = await handler(request, transport)
                self.queue.async {
                    guard !self.closed else { return }
                    self.write(response, close: request.wantsClose) {
                        self.busy = false
                        self.arm(self.limits.idle)
                        // A pipelined request may already be buffered.
                        if self.parser.hasBufferedBytes { self.feed(Data()) }
                        if !self.busy { self.receive() }
                    }
                }
            }
        }

        private func write(_ response: HTTPResponse, close: Bool, then: (@Sendable () -> Void)? = nil) {
            if close { pauseReading() }
            send(response.serialized(close: close)) { [weak self] in
                guard let self else { return }
                if close { self.close() } else if !self.closed { then?() }
            }
        }

        /// Queues `data` and writes what the socket takes; `then` runs once all of it is written.
        private func send(_ data: Data, then: (@Sendable () -> Void)? = nil) {
            guard !closed else { return }
            outbox.append(data)
            if let then { drained.append(then) }
            flush()
        }

        private func flush() {
            while written < outbox.count {
                let count = outbox.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + written, $0.count - written) }
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN {
                    if writer == nil {
                        let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                        track(writer)
                        writer.setEventHandler { [weak self] in self?.flush() }
                        self.writer = writer
                        writer.resume()
                    }
                    return
                } else {
                    close()
                    return
                }
            }
            outbox = Data()
            written = 0
            writer?.cancel()
            writer = nil
            let callbacks = drained
            drained = []
            for callback in callbacks { callback() }
        }

        private func arm(_ seconds: TimeInterval) {
            timer?.cancel()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + seconds)
            source.setEventHandler { [weak self] in
                guard let self, !self.closed, !self.busy else { return }
                if self.parser.hasBufferedBytes {
                    self.write(HTTPResponse(status: 408), close: true)
                } else {
                    self.close()
                }
            }
            source.resume()
            timer = source
        }

        /// The socket stays open until the kernel has let go of every source watching it.
        private func track(_ source: DispatchSourceProtocol) {
            liveSources += 1
            source.setCancelHandler { [self] in
                liveSources -= 1
                if closed, liveSources == 0 { Darwin.close(fd) }
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            timer?.cancel()
            timer = nil
            writer?.cancel()
            writer = nil
            if readerSuspended { reader?.resume() }  // A suspended source can't finish cancelling.
            reader?.cancel()
            reader = nil
            outbox = Data()
            drained = []
            if liveSources == 0 { Darwin.close(fd) }
            onClose?()
            onClose = nil
        }
    }
}

extension HTTPResponse {
    static func json(_ status: Int, _ body: Data, contentType: String = "application/json") -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", contentType), ("Cache-Control", "no-store")], body: body)
    }
}
