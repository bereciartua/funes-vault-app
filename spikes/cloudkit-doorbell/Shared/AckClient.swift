import Foundation

#if os(iOS)
/// Sends an acknowledgement to the Mac's spike app over plain HTTP (LAN or Tailscale).
enum AckClient {
    static func send(_ ack: DoorbellAck, to address: String, timeout: TimeInterval = 8) async -> Bool {
        let host = address.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let url = URL(string: "http://\(host):\(Doorbell.ackPort)/ack") else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(ack)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
#endif
