import BackgroundTasks
import FunesPhone
import FunesProtocol
import Observation
import os
import SwiftUI

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "capture")

/// The capture queue as the app shows it, and its delivery (companion protocol §6): what's
/// waiting, what went this session, and the triggers (launch, foreground, a new network path,
/// a new capture, background refresh, and the backoff's retry).
@MainActor @Observable
final class CaptureModel {
    /// A row of "Recent captures".
    struct Recent: Identifiable, Equatable {
        enum Status: Equatable {
            case waiting
            case sent
            case rejected(CompanionErrorCode)
        }

        var id: UUID
        var text: String
        var createdAt: Date
        var status: Status
    }

    /// Captures waiting for the Mac.
    private(set) var queuedCount = 0
    /// Waiting, and those the Mac turned down.
    private(set) var storedCount = 0
    private(set) var recent: [Recent] = []
    private(set) var lastOutcome: DeliveryOutcome?
    /// A delivery is running.
    var delivering: Bool { runs > 0 }
    /// The queue's file couldn't be opened (no App Group container).
    private(set) var unavailable = false
    /// Delivery's result for the rest of the app: the Mac said this iPhone was removed, say.
    var onOutcome: ((DeliveryOutcome) -> Void)?

    private let queue: CaptureQueue?
    private let delivery: CaptureDelivery?
    private var stored: [QueuedCapture] = []
    /// Delivered this session. Kept in memory only: the phone stores just what's waiting.
    private var sent: [Recent] = []
    private var retry: Task<Void, Never>?
    private var runs = 0

    static let recentLimit = 20

    init(client: CompanionClient) {
        do {
            let queue = try CaptureQueue.appGroup()
            self.queue = queue
            delivery = CaptureDelivery(queue: queue, sender: client)
        } catch {
            queue = nil
            delivery = nil
            unavailable = true
        }
        reload()
    }

    // MARK: Capturing

    /// Scans and queues, then tries to deliver. Throws why it wasn't queued.
    func remember(_ text: String, note: String? = nil, source: CaptureSource) throws(CaptureQueueError) {
        guard let queue else { throw .storage }
        try queue.add(text, note: note, source: source)
        reload()
        Task { await deliver(.captured) }
    }

    /// Re-reads the queue: the extensions add to it from their own processes.
    func reload() {
        guard let queue else { return }
        do {
            stored = try queue.all()
            queuedCount = stored.filter { $0.state == .queued }.count
            storedCount = stored.count
        } catch {
            logger.error("Couldn't read the capture queue")
        }
        recent = Self.merge(stored: stored, sent: sent)
    }

    private static func merge(stored: [QueuedCapture], sent: [Recent]) -> [Recent] {
        let waiting = stored.prefix(recentLimit).map { capture in
            Recent(id: capture.id, text: capture.text, createdAt: capture.createdAt, status: {
                if case let .rejected(code) = capture.state { return .rejected(code) }
                return .waiting
            }())
        }
        return Array((waiting + sent).sorted { $0.createdAt > $1.createdAt }.prefix(recentLimit))
    }

    // MARK: Delivery

    func deliver(_ trigger: DeliveryTrigger) async {
        guard let delivery else { return }
        let before = stored
        runs += 1
        let outcome = await delivery.deliver(trigger)
        runs -= 1
        if outcome == .busy { return }
        lastOutcome = outcome
        reload()
        // What left the queue went to the Mac.
        let left = Set(stored.map(\.id))
        let delivered = before.filter { $0.state == .queued && !left.contains($0.id) }
        sent = Array((delivered.map { Recent(id: $0.id, text: $0.text, createdAt: $0.createdAt, status: .sent) } + sent)
            .prefix(Self.recentLimit))
        recent = Self.merge(stored: stored, sent: sent)
        scheduleRetry(after: outcome)
        onOutcome?(outcome)
    }

    /// While the app is open, try again when the backoff's wait is over.
    private func scheduleRetry(after outcome: DeliveryOutcome) {
        retry?.cancel()
        guard case let .failed(_, retryAt, _) = outcome else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, retryAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.deliver(.retry)
        }
    }

    /// Asks iOS for a background refresh, so captures from the share sheet or the Control go
    /// even if the app isn't opened: not before the backoff allows, nor in under 15 minutes.
    func scheduleBackgroundDelivery() async {
        let earliest = max(Date(timeIntervalSinceNow: 15 * 60), await delivery?.nextAttempt ?? .distantPast)
        let request = BGAppRefreshTaskRequest(identifier: Identifiers.iOSDeliveryTaskID)
        request.earliestBeginDate = earliest
        do { try BGTaskScheduler.shared.submit(request) } catch {
            logger.error("Couldn't schedule background delivery: \(error.localizedDescription, privacy: .public)") // log-safe: a system error
        }
    }

    #if DEBUG
    /// Spike 1 row 1h and the manual matrix's "queue of 1,000": fills the queue without sending.
    func queueTestCaptures(_ count: Int) async -> Int {
        guard let queue else { return 0 }
        let run = UUID().uuidString.prefix(4)
        let added = await Task.detached {
            var added = 0
            for i in 1...count {
                guard (try? queue.add("Spike test capture \(i) of \(count) (\(run))", source: .typed)) != nil else { break }
                added += 1
            }
            return added
        }.value
        reload()
        return added
    }
    #endif

    // MARK: Deleting

    /// One capture the Mac turned down, or that the user no longer wants sent.
    func delete(_ id: UUID) {
        try? queue?.remove([id])
        reload()
    }

    /// "Delete queued captures…", and unpairing.
    func deleteAll() {
        try? queue?.deleteAll()
        sent = []
        reload()
    }

    // MARK: Messages

    static func message(for error: CaptureQueueError) -> String {
        switch error {
        case .empty: String(localized: "Type or dictate something to remember.")
        case .tooLong: String(localized: "That's over 10,000 characters. Shorten it, or split it in two.")
        case let .secret(patterns):
            String(localized: "Blocked: looks like a secret (\(patterns.map(Self.name).formatted(.list(type: .and)))). Funes never stores passwords, keys or card numbers.")
        case .full: String(localized: "Queue full: connect to your Mac.")
        case .storage: String(localized: "Couldn't save on this iPhone. Try again.")
        }
    }

    static func name(_ pattern: SecretPattern) -> String {
        switch pattern {
        case .privateKey: String(localized: "a private key")
        case .awsAccessKey: String(localized: "an AWS key")
        case .openAIStyleKey, .googleAPIKey, .stripeKey: String(localized: "an API key")
        case .githubToken: String(localized: "a GitHub token")
        case .jwt: String(localized: "a sign-in token")
        case .assignedSecret: String(localized: "a password or key")
        case .slackToken: String(localized: "a Slack token")
        case .funesOrEKBKey: String(localized: "a Funes key")
        case .creditCard: String(localized: "a card number")
        }
    }

    static func message(for code: CompanionErrorCode) -> String {
        switch code {
        case .secretLikeContent: String(localized: "Not accepted by your Mac: looks like a secret")
        case .invalidInput: String(localized: "Not accepted by your Mac")
        default: String(localized: "Not accepted by your Mac (\(code.rawValue))")
        }
    }
}
