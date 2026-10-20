import Foundation
import Network

/// A tiny HTTP listener for `POST /ack` from the phone. Spike only: one request per connection,
/// no keep-alive, bodies up to 16 KiB.
final class AckServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "doorbell.ack")
    private let onAck: @Sendable (DoorbellAck, Date) -> Void

    init(port: UInt16, onAck: @escaping @Sendable (DoorbellAck, Date) -> Void) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        self.onAck = onAck
    }

    func start(onState: @escaping @Sendable (String) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onState("Listening on port \(Doorbell.ackPort)")
            case let .failed(error): onState("Listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let arrived = Date()
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                if let ack = try? JSONDecoder().decode(DoorbellAck.self, from: request) {
                    self.onAck(ack, arrived)
                    self.reply(connection, status: "200 OK")
                } else {
                    self.reply(connection, status: "400 Bad Request")
                }
            } else if isComplete || error != nil || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func reply(_ connection: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The body once the headers and `Content-Length` bytes are in.
    private static func parse(_ buffer: Data) -> Data? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).lowercased()
        let length = head.split(separator: "\r\n")
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = buffer[end.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }
}

/// The Mac's addresses, so the phone knows where to send acknowledgements.
enum LocalAddresses {
    static func all() -> [(kind: String, address: String)] {
        var result: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: entry.ifa_name)
            if ip.hasPrefix("127.") { continue }
            let kind = ip.hasPrefix("100.") ? "Tailscale" : "LAN (\(name))"
            result.append((kind, ip))
        }
        return result
    }
}
