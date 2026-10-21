import Foundation
import FunesProtocol
import Network

/// The phone's transport: plain HTTP (LAN and Tailscale) over Network.framework, HTTPS (the
/// tunnel) over `URLSession`.
///
/// Why: App Transport Security, which governs `URLSession`, refuses plain HTTP to Tailscale's
/// `100.64.0.0/10` addresses even with `NSAllowsLocalNetworking`, which covers only `.local`
/// names and private ranges (Spike 1e: `URLError -1022`). Network.framework isn't subject to
/// ATS. Confidentiality and integrity come from the envelope either way (§3).
public struct CompanionHTTPTransport: CompanionTransport {
    let plain = NetworkHTTPTransport()
    let secure = URLSessionTransport()

    public init() {}

    public func post(_ url: URL, body: Data, timeout: TimeInterval) async throws(TransportError) -> TransportResponse {
        url.scheme == "http" ? try await plain.post(url, body: body, timeout: timeout)
            : try await secure.post(url, body: body, timeout: timeout)
    }
}

/// A minimal HTTP/1.1 client over `NWConnection` for `http://` URLs: one POST per connection,
/// `Connection: close`, and a response read up to its `Content-Length` (or the end of the
/// connection), at most `CompanionProtocol.maxResponseBytes`.
public struct NetworkHTTPTransport: CompanionTransport {
    public init() {}

    public func post(_ url: URL, body: Data, timeout: TimeInterval) async throws(TransportError) -> TransportResponse {
        guard url.scheme == "http", let host = url.host(percentEncoded: false), !host.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80))
        else { throw TransportError("not an http URL") }
        let request = Self.request(url: url, host: host, body: body)
        let exchange = HTTPExchange(host: host, port: port)
        do {
            return try await withDeadline(timeout) {
                try await withTaskCancellationHandler {
                    try await exchange.run(request)
                } onCancel: {
                    exchange.cancel()
                }
            }
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError("\(type(of: error))")
        }
    }

    static func request(url: URL, host: String, body: Data) -> Data {
        let path = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        let authority = host.contains(":") ? "[\(host)]" : host
        let hostHeader = url.port.map { "\(authority):\($0)" } ?? authority
        var head = "POST \(path) HTTP/1.1\r\n"
        head += "Host: \(hostHeader)\r\n"
        head += "Content-Type: \(CompanionProtocol.envelopeContentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Parses what has arrived so far. Nil while the response is incomplete; `ended` says the
    /// connection closed, which completes a response without `Content-Length`.
    static func parse(_ data: Data, ended: Bool) throws(TransportError) -> TransportResponse? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            if ended || data.count > 16 * 1024 { throw TransportError("bad HTTP response") }
            return nil
        }
        guard let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw TransportError("bad HTTP response") }
        let lines = head.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ")
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]), (100...599).contains(code) else {
            throw TransportError("bad HTTP response")
        }
        var length: Int?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard let n = Int(value), n >= 0 else { throw TransportError("bad HTTP response") }
                length = n
            } else if name == "transfer-encoding", value.lowercased() != "identity" {
                throw TransportError("chunked HTTP response")
            }
        }
        let body = data[split.upperBound...]
        if let length {
            guard length <= CompanionProtocol.maxResponseBytes else { throw TransportError("HTTP response too large") }
            guard body.count >= length else {
                if ended { throw TransportError("HTTP response cut short") }
                return nil
            }
            return TransportResponse(status: code, body: Data(body.prefix(length)))
        }
        guard body.count <= CompanionProtocol.maxResponseBytes else { throw TransportError("HTTP response too large") }
        return ended ? TransportResponse(status: code, body: Data(body)) : nil
    }
}

/// One connection, one request, one response. All state is on `queue`.
private final class HTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.funesvault.ios.http")
    private var continuation: CheckedContinuation<TransportResponse, any Error>?
    private var received = Data()
    private var finished = false

    init(host: String, port: NWEndpoint.Port) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    func run(_ request: Data) async throws -> TransportResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !finished else { return continuation.resume(throwing: TransportError("cancelled")) }
                self.continuation = continuation
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state, request: request) }
                connection.start(queue: queue)
            }
        }
    }

    func cancel() { queue.async { [self] in finish(.failure(TransportError("cancelled"))) } }

    private func stateChanged(_ state: NWConnection.State, request: Data) {
        switch state {
        case .ready:
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { return finish(.failure(TransportError("send: \(error)"))) }
                receive()
            })
        case let .waiting(error), let .failed(error):
            // `waiting` means no route now; a probe shouldn't sit and wait for one.
            finish(.failure(TransportError("\(error)")))
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { received.append(data) }
            do {
                if let response = try NetworkHTTPTransport.parse(received, ended: isComplete) {
                    return finish(.success(response))
                }
            } catch {
                return finish(.failure(error))
            }
            if let error { return finish(.failure(TransportError("receive: \(error)"))) }
            if isComplete { return finish(.failure(TransportError("HTTP response cut short"))) }
            receive()
        }
    }

    private func finish(_ result: Result<TransportResponse, any Error>) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}
