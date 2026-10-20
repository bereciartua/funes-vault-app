import Foundation
import Synchronization

/// Records every outgoing request and answers from a handler, per session (no live calls).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        var text: String { String(decoding: body, as: UTF8.self) }
    }
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data("{}".utf8)
        var delay: Duration = .zero
        var fail = false

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }
    typealias Handler = @Sendable (Captured) -> Reply

    private static let handlers = Mutex<[String: Handler]>([:])
    private static let captured = Mutex<[String: [Captured]]>([:])
    private static let answered = Mutex<[String: Int]>([:])
    static let header = "X-Stub-Session"

    /// A session whose requests go to `handler`; `requests()` lists what it sent.
    final class Session: Sendable {
        let id = UUID().uuidString
        let session: URLSession

        init(_ handler: @escaping Handler) {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubURLProtocol.self]
            config.httpAdditionalHeaders = [StubURLProtocol.header: id]
            session = URLSession(configuration: config)
            StubURLProtocol.handlers.withLock { $0[id] = handler }
        }

        var requests: [Captured] { StubURLProtocol.captured.withLock { $0[id] ?? [] } }
        /// How many requests got their reply; a delayed reply to a cancelled request never arrives.
        var answers: Int { StubURLProtocol.answered.withLock { $0[id] ?? 0 } }
    }

    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: header) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers.removeValue(forKey: Self.header)
        let captured = Captured(url: request.url!, method: request.httpMethod ?? "GET", headers: headers, body: body)
        Self.captured.withLock { $0[id, default: []].append(captured) }
        let reply = Self.handlers.withLock { $0[id] }?(captured) ?? Reply(status: 599)
        let client = self.client
        let finish: @Sendable () -> Void = { [weak self] in
            guard let self, !self.stopped.withLock({ $0 }) else { return }
            Self.answered.withLock { $0[id, default: 0] += 1 }
            if reply.fail {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay == .zero {
            finish()
        } else {
            Task {
                try? await Task.sleep(for: reply.delay)
                finish()
            }
        }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }
}
