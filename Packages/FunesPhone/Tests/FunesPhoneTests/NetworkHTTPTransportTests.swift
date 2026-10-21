import Foundation
import FunesProtocol
import Network
import Testing
@testable import FunesPhone

@Suite struct HTTPParsingTests {
    func parse(_ text: String, ended: Bool = false) throws -> TransportResponse? {
        try NetworkHTTPTransport.parse(Data(text.utf8), ended: ended)
    }

    @Test func contentLength() throws {
        #expect(try parse("HTTP/1.1 401 Unauthorized\r\nContent-Length: 4\r\n\r\nab") == nil)
        #expect(try parse("HTTP/1.1 401 Unauthorized\r\ncontent-length: 4\r\n\r\nabcdEXTRA")
            == TransportResponse(status: 401, body: Data("abcd".utf8)))
        #expect(throws: TransportError.self) { try parse("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nab", ended: true) }
    }

    @Test func closeDelimited() throws {
        #expect(try parse("HTTP/1.1 200 OK\r\n\r\nabc") == nil)
        #expect(try parse("HTTP/1.1 200 OK\r\n\r\nabc", ended: true) == TransportResponse(status: 200, body: Data("abc".utf8)))
    }

    @Test func refusesWhatIsNotHTTP() {
        #expect(throws: TransportError.self) { try parse("SSH-2.0-OpenSSH\r\n\r\n") }
        #expect(throws: TransportError.self) { try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n") }
        #expect(throws: TransportError.self) { try parse("HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n") }
        #expect(throws: TransportError.self) { try parse("garbage", ended: true) }
    }

    @Test func request() {
        let url = URL(string: "http://100.89.20.22:47636/c/v1/rpc")!
        let text = String(decoding: NetworkHTTPTransport.request(url: url, host: "100.89.20.22", body: Data("{}".utf8)), as: UTF8.self)
        #expect(text == "POST /c/v1/rpc HTTP/1.1\r\nHost: 100.89.20.22:47636\r\nContent-Type: application/funes-envelope+json\r\n"
            + "Content-Length: 2\r\nConnection: close\r\n\r\n{}")
    }
}

/// The transport over a real socket, against a loopback server that answers with canned bytes.
@Suite(.serialized) struct NetworkHTTPTransportTests {
    final class CannedServer: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "canned")
        private let lock = NSLock()
        private var _requests: [Data] = []
        var requests: [Data] { lock.withLock { _requests } }

        init(reply: Data, closeAfter: Bool = true, silent: Bool = false) throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                    self.lock.withLock { self._requests.append(data ?? Data()) }
                    guard !silent else { return }
                    connection.send(content: reply, completion: .contentProcessed { _ in
                        if closeAfter { connection.cancel() }
                    })
                }
            }
        }

        func start() async throws -> UInt16 {
            listener.start(queue: queue)
            for _ in 0..<200 {
                if let port = listener.port?.rawValue, port != 0 { return port }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw TransportError("listener didn't start")
        }

        deinit { listener.cancel() }
    }

    @Test func postsAndReadsTheReply() async throws {
        let server = try CannedServer(reply: Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 28\r\n\r\n{\"error\":\"invalid_envelope\"}".utf8),
                                      closeAfter: false)
        let port = try await server.start()
        let response = try await NetworkHTTPTransport().post(URL(string: "http://127.0.0.1:\(port)/c/v1/rpc")!, body: Data("{}".utf8),
                                                             timeout: 3)
        #expect(response.status == 401)
        #expect(CompanionAuthError(body: response.body) == .invalidEnvelope)
        let request = String(decoding: server.requests.first ?? Data(), as: UTF8.self)
        #expect(request.hasPrefix("POST /c/v1/rpc HTTP/1.1\r\n"))
        #expect(request.hasSuffix("\r\n\r\n{}"))
    }

    @Test func readsToTheEndWithoutContentLength() async throws {
        let server = try CannedServer(reply: Data("HTTP/1.1 200 OK\r\n\r\nhello".utf8))
        let port = try await server.start()
        let response = try await NetworkHTTPTransport().post(URL(string: "http://127.0.0.1:\(port)/x")!, body: Data(), timeout: 3)
        #expect(response == TransportResponse(status: 200, body: Data("hello".utf8)))
    }

    @Test func timesOut() async throws {
        let server = try CannedServer(reply: Data(), silent: true)
        let port = try await server.start()
        let start = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) {
            try await NetworkHTTPTransport().post(URL(string: "http://127.0.0.1:\(port)/x")!, body: Data(), timeout: 0.5)
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func refusedConnection() async throws {
        // A port nothing listens on.
        let server = try CannedServer(reply: Data())
        let port = try await server.start()
        server.listener.cancel()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: TransportError.self) {
            try await NetworkHTTPTransport().post(URL(string: "http://127.0.0.1:\(port)/x")!, body: Data(), timeout: 2)
        }
    }

    @Test func httpsGoesToURLSession() async throws {
        await #expect(throws: TransportError.self) {
            try await NetworkHTTPTransport().post(URL(string: "https://example.invalid/x")!, body: Data(), timeout: 1)
        }
    }
}
