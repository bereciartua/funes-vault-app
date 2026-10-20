import BridgeKitCore
import Foundation
import FunesProtocol
import Network
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "companion")

/// The companion's TCP listener (§5): every interface on 47626, but each connection is accepted
/// or refused by its remote address before a byte is read (`AddressPolicy`). Plain HTTP/1.1:
/// confidentiality and integrity come from the envelope. Advertises `_funes._tcp` while Same
/// Wi-Fi is on.
///
/// One request at a time per connection, with fixed deadlines that later bytes don't extend: the
/// whole request within 10 s of its first byte, 30 s idle between requests.
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
    public static let maxConnections = 32

    private let queue = DispatchQueue(label: "com.funesvault.companion.listener")
    private let port: Int
    private let modes: CompanionModes
    private let bonjour: [String: String]?
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var stateChanged: (@Sendable (State) -> Void)?

    /// `bonjour` is the TXT record to advertise, or nil not to advertise.
    public init(port: Int, modes: CompanionModes, bonjour: [String: String]?, handler: @escaping Handler) {
        self.port = port
        self.modes = modes
        self.bonjour = bonjour
        self.handler = handler
    }

    /// `stateChanged` is called on the main queue.
    public func start(stateChanged: @escaping @Sendable (State) -> Void) {
        queue.async { [self] in
            self.stateChanged = stateChanged
            report(.starting)
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Tunnel-only: nothing outside the Mac needs to reach the port.
            if modes == [.tunnel] { parameters.acceptLocalOnly = true }
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any)
            } catch {
                report(.failed(Self.failure(error, port: self.port)))
                return
            }
            if let bonjour, modes.contains(.sameWiFi) {
                listener.service = NWListener.Service(type: Identifiers.bonjourServiceType, txtRecord: NWTXTRecord(bonjour).data)
            }
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.report(.ready(port: Int(listener.port?.rawValue ?? UInt16(clamping: self.port))))
                case let .failed(error), let .waiting(error):
                    listener.cancel()
                    self.closeAll()
                    self.report(.failed(Self.failure(error, port: self.port)))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            stateChanged = nil
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
            closeAll()
        }
    }

    private func accept(_ raw: NWConnection) {
        guard connections.count < Self.maxConnections,
              let transport = AddressPolicy.transport(for: raw.endpoint, modes: modes) else {
            raw.cancel()
            return
        }
        let connection = Connection(raw, transport: transport, queue: queue, handler: handler)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.onClose = { [weak self] in self?.connections[key] = nil }
        connection.start()
    }

    private func closeAll() {
        for connection in Array(connections.values) { connection.close() }
        connections.removeAll()
    }

    private func report(_ state: State) {
        let callback = stateChanged
        DispatchQueue.main.async { callback?(state) }
    }

    private static func failure(_ error: Error, port: Int) -> Failure {
        if case let .posix(code) = error as? NWError, code == .EADDRINUSE { return .portInUse(port) }
        return .other((error as? NWError).map { "\($0)" } ?? error.localizedDescription)
    }

    /// One accepted connection. All state is touched on the listener's queue.
    private final class Connection: @unchecked Sendable {
        private let connection: NWConnection
        private let transport: DeviceTransport
        private let queue: DispatchQueue
        private let handler: Handler
        private var parser = HTTPParser(limits: HTTPLimits(maxBodyBytes: CompanionProtocol.maxRequestBytes))
        private var busy = false
        private var closed = false
        private var timer: DispatchSourceTimer?
        var onClose: (@Sendable () -> Void)?

        init(_ connection: NWConnection, transport: DeviceTransport, queue: DispatchQueue, handler: @escaping Handler) {
            self.connection = connection
            self.transport = transport
            self.queue = queue
            self.handler = handler
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
            connection.start(queue: queue)
            arm(Self.idle)
            receive()
        }

        private static let idle = CompanionListener.idleTimeout
        private static let request = CompanionListener.requestTimeout

        private func receive() {
            guard !closed, !busy else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    if !self.parser.hasBufferedBytes { self.arm(Self.request) }
                    self.feed(data)
                }
                if isComplete || error != nil { self.close() } else if !self.busy { self.receive() }
            }
        }

        private func feed(_ data: Data) {
            switch parser.feed(data) {
            case .needMore: break
            case .expectContinue:
                connection.send(content: HTTPResponse.continueBytes, completion: .contentProcessed { _ in })
            case let .request(request): handle(request)
            case let .error(status): write(HTTPResponse(status: status), close: true)
            }
        }

        private func handle(_ request: HTTPRequest) {
            busy = true
            timer?.cancel()
            let transport = self.transport, handler = self.handler
            Task {
                let response = await handler(request, transport)
                self.queue.async {
                    guard !self.closed else { return }
                    self.write(response, close: request.wantsClose) {
                        self.busy = false
                        self.arm(Self.idle)
                        // A pipelined request may already be buffered.
                        if self.parser.hasBufferedBytes { self.feed(Data()) }
                        if !self.busy { self.receive() }
                    }
                }
            }
        }

        private func write(_ response: HTTPResponse, close: Bool, then: (@Sendable () -> Void)? = nil) {
            connection.send(content: response.serialized(close: close), completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.queue.async { if close { self.close() } else if !self.closed { then?() } }
            })
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

        func close() {
            guard !closed else { return }
            closed = true
            timer?.cancel()
            timer = nil
            connection.cancel()
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
