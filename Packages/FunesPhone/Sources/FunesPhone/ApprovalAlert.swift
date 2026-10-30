import Foundation
import FunesProtocol
import Synchronization

/// What the notification service extension shows for a doorbell ring (ADR-0019 §2, FR-iOS-12).
/// The push carries only the ring's record name; the extension fetches the request with
/// `approvals.get {ring}` over the companion channel and words the alert here. If the Mac doesn't
/// answer in time, the alert says "Mac not reachable" and keeps the generic text.
public struct ApprovalAlert: Sendable, Equatable {
    /// The `userInfo` keys a tap reads back to open the request.
    public enum Key {
        public static let id = "funesApprovalID"
        public static let kind = "funesApprovalKind"
        public static let ring = "funesRing"
    }

    /// What fetching the ring's request came to.
    public enum Outcome: Sendable, Equatable {
        case request(ApprovalDetail)
        /// Answered on the Mac (or another iPhone) before this one could show it.
        case answered
        case expired
        /// The Mac doesn't know the ring (it relaunched meanwhile), or the push had none.
        case unknown
        /// No answer in time, or no address answered.
        case unreachable
        /// This iPhone was removed on the Mac, or isn't paired.
        case removed
    }

    /// How long the extension waits for the Mac; iOS gives it about 30 s in all.
    public static let fetchTimeout: Duration = .seconds(10)

    public var title: String
    public var body: String
    /// The request to open on a tap, when the fetch found it.
    public var approvalID: UUID?
    public var kind: ApprovalKind?

    public init(title: String, body: String, approvalID: UUID? = nil, kind: ApprovalKind? = nil) {
        self.title = title
        self.body = body
        self.approvalID = approvalID
        self.kind = kind
    }

    /// The words for an outcome. Only the agent's name, the count and a category name reach the
    /// lock screen; never a memory's title or text, nor the task.
    public init(_ outcome: Outcome) {
        switch outcome {
        case let .request(detail):
            self.init(title: ApprovalWording.title(detail), body: ApprovalWording.alertBody(detail.kind), approvalID: detail.id,
                      kind: detail.kind)
        case .answered:
            self.init(title: String(localized: "Answered on your Mac"), body: String(localized: "There's nothing to answer here."))
        case .expired:
            self.init(title: String(localized: "This request expired"), body: String(localized: "There's nothing to answer any more."))
        case .unknown:
            self.init(title: ApprovalWording.generic, body: String(localized: "Open Funes to see what's waiting."))
        case .unreachable:
            self.init(title: ApprovalWording.generic,
                      body: String(localized: "Mac not reachable. Answer on your Mac, or open Funes when your Mac is reachable."))
        case .removed:
            self.init(title: ApprovalWording.generic, body: String(localized: "This iPhone was removed from Funes on your Mac."))
        }
    }

    /// What the alert shows until the fetch is done, and if iOS ends the extension first.
    public static var fallback: ApprovalAlert { ApprovalAlert(.unreachable) }

    /// Merged into the notification's `userInfo`.
    public var userInfo: [String: String] {
        var info: [String: String] = [:]
        if let approvalID { info[Key.id] = approvalID.uuidString }
        if let kind { info[Key.kind] = kind.rawValue }
        return info
    }

    /// What a tapped notification opens: the request by id when the extension found it, else by
    /// the ring's record name. Nil opens the list.
    public static func ref(fromUserInfo userInfo: [AnyHashable: Any]) -> ApprovalRef? {
        if let id = (userInfo[Key.id] as? String).flatMap(UUID.init(uuidString:)) { return ApprovalRef(id: id) }
        if let ring = userInfo[Key.ring] as? String {
            let ref = ApprovalRef(ring: ring)
            if (try? ref.validate()) != nil { return ref }
        }
        return nil
    }

    /// `approvals.get {ring}`, given at most `timeout`. A call still running then is cancelled
    /// and left behind, so a slow address can't hold the alert past it.
    public static func fetch(ring: String?, caller: any CompanionCalling, timeout: Duration = fetchTimeout) async -> Outcome {
        guard let ring else { return .unknown }
        let ref = ApprovalRef(ring: ring)
        guard (try? ref.validate()) != nil else { return .unknown }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let finish: @Sendable (Outcome) -> Void = { outcome in
                if once.claim() { continuation.resume(returning: outcome) }
            }
            let work = Task {
                do throws(CompanionClientError) {
                    finish(.request(try await caller.call(ApprovalsGet.self, ref)))
                } catch {
                    finish(outcome(for: error))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                work.cancel()
                finish(.unreachable)
            }
        }
    }

    /// The first of the call and the deadline to finish.
    private final class Once: Sendable {
        private let claimed = Mutex(false)

        func claim() -> Bool {
            claimed.withLock { claimed in
                guard !claimed else { return false }
                claimed = true
                return true
            }
        }
    }

    static func outcome(for error: CompanionClientError) -> Outcome {
        switch error {
        case .method(let failure):
            switch failure.code {
            case .alreadyAnswered: .answered
            case .requestExpired: .expired
            case .unavailable, .rateLimited: .unreachable
            default: .unknown
            }
        case .unreachable, .badResponse: .unreachable
        case .notPaired, .refused(.revoked), .refused(.unknownDevice): .removed
        case .refused, .pairing, .qrExpired, .local, .answerTimedOut: .unknown
        }
    }
}
