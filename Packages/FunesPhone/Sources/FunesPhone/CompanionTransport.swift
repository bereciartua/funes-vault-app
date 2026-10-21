import Foundation
import FunesProtocol

/// An HTTP status and body.
public struct TransportResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Couldn't get any HTTP answer: no route, refused, timed out, cancelled.
public struct TransportError: Error, Sendable, Equatable {
    public var reason: String

    public init(_ reason: String) { self.reason = reason }

    public static let timedOut = TransportError("timed out")
}

/// POSTs an envelope. `URLSessionTransport` on the phone; tests route straight to a Mac.
public protocol CompanionTransport: Sendable {
    /// Gives up after `timeout` seconds in total, not just of silence.
    func post(_ url: URL, body: Data, timeout: TimeInterval) async throws(TransportError) -> TransportResponse
}

/// Plain `URLSession`, ephemeral: no cookies, no cache, no credentials. Used for the tunnel's
/// HTTPS; plain HTTP goes through `NetworkHTTPTransport`, since ATS refuses it to Tailscale
/// addresses.
public struct URLSessionTransport: CompanionTransport {
    let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    public func post(_ url: URL, body: Data, timeout: TimeInterval) async throws(TransportError) -> TransportResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(CompanionProtocol.envelopeContentType, forHTTPHeaderField: "Content-Type")
        do {
            return try await withDeadline(timeout) { [session, request] in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw TransportError("not HTTP") }
                return TransportResponse(status: http.statusCode, body: data)
            }
        } catch let error as TransportError {
            throw error
        } catch let error as URLError {
            throw error.code == .timedOut ? .timedOut : TransportError("URLError \(error.code.rawValue)")
        } catch is CancellationError {
            throw TransportError("cancelled")
        } catch {
            throw TransportError("\(type(of: error))")
        }
    }
}

/// Runs `work`, cancelling it after `seconds`: `URLRequest.timeoutInterval` only bounds silence.
func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TransportError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TransportError.timedOut }
        return first
    }
}
