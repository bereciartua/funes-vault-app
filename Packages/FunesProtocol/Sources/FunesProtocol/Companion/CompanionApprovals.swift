import Foundation

// Approvals from the iPhone (task 5.6, FR-iOS-12, ADR-0019). A Share, Save or access request
// waiting on the Mac rings a CloudKit "doorbell" that carries nothing but a per-device tag; the
// phone then fetches the panel over the companion channel and answers it there. The Mac words
// nothing for the phone: these are data, worded and localized on the phone.

/// What the Mac, the iPhone app and its notification service extension agree on about the
/// doorbell (ADR-0019 §1–2).
public enum Doorbell {
    /// Permanent: an iCloud container can't be deleted or renamed.
    public static let container = "iCloud.com.funesvault"
    public static let recordType = "Doorbell"
    /// The record's only field: the device's random tag. The phone's `CKQuerySubscription` matches
    /// `tag == <its tag>`, firing on creation.
    public static let tagField = "tag"
    /// The record name, a fresh random 128-bit id per ring, as 32 lowercase hex digits. It's never
    /// a request id: the Mac maps it to the request in memory while the request waits.
    public static let recordNameLength = 32
}

/// The three kinds of panel (FR-iOS-12): Share memories, Save a suggested memory, or let an
/// agent read or add to more.
public enum ApprovalKind: String, Codable, Sendable, CaseIterable {
    case share, save, access
}

/// An answer, by panel:
/// - Share: `share` (with the ticked memories) or `deny`;
/// - Save: `save` or `discard` (Later is no answer: it stays in the Inbox);
/// - access: `allowOnce` (only when the panel offers it), `alwaysAllow` or `notNow`.
public enum ApprovalChoice: String, Codable, Sendable, CaseIterable {
    case share, deny
    case save, discard
    case allowOnce = "allow_once"
    case alwaysAllow = "always_allow"
    case notNow = "not_now"

    public var kind: ApprovalKind {
        switch self {
        case .share, .deny: .share
        case .save, .discard: .save
        case .allowOnce, .alwaysAllow, .notNow: .access
        }
    }
}

// MARK: - approvals.list

/// What waits for the user now, soonest deadline first: for the phone app's list, and for a
/// notification that never came.
public enum ApprovalsList: CompanionCall {
    public static let method = CompanionMethod.approvalsList
    public typealias Params = EmptyParams
    public typealias Result = ApprovalListResult
}

public struct ApprovalSummary: Codable, Sendable, Equatable, Identifiable {
    /// The request id (Share), the suggestion id (Save), or the Mac's id for an access request.
    public var id: UUID
    public var kind: ApprovalKind
    public var agentName: String
    public var agentKind: AgentKind?
    /// Share: the memories offered. Save: 1. Access: 0.
    public var count: Int
    public var createdAt: Date
    /// After this it can't be answered (`request_expired`).
    public var expiresAt: Date

    public init(id: UUID, kind: ApprovalKind, agentName: String, agentKind: AgentKind? = nil, count: Int, createdAt: Date,
                expiresAt: Date) {
        self.id = id
        self.kind = kind
        self.agentName = agentName
        self.agentKind = agentKind
        self.count = count
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct ApprovalListResult: Codable, Sendable, Equatable {
    public var items: [ApprovalSummary]

    public init(items: [ApprovalSummary]) { self.items = items }
}

// MARK: - approvals.get

/// The panel's contents, built fresh on the Mac. Name the request by `id` (the list, or a panel
/// already shown) or by `ring`, the doorbell record's name from the push. Exactly one.
public enum ApprovalsGet: CompanionCall {
    public static let method = CompanionMethod.approvalsGet
    public typealias Params = ApprovalRef
    public typealias Result = ApprovalDetail
}

public struct ApprovalRef: Codable, Sendable, Equatable {
    public var id: UUID?
    public var ring: String?

    public init(id: UUID) {
        self.id = id
        self.ring = nil
    }

    public init(ring: String) {
        self.id = nil
        self.ring = ring
    }

    public func validate() throws(CompanionError) {
        switch (id, ring) {
        case (_?, nil): return
        case let (nil, ring?) where ring.count == Doorbell.recordNameLength && ring.allSatisfy(\.isHexDigit): return
        default: throw CompanionError(.invalidInput, message: "Give id or ring")
        }
    }
}

/// One memory on the Share panel: its current text in full (the user approves the exact text),
/// with the badge's sensitivity.
public struct ApprovalRow: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var version: Int
    public var kind: MemoryKind
    public var categories: [String]
    public var sensitivity: Sensitivity
    /// A weaker match (access policy §3.2): offered unticked under "Also matched".
    public var weak: Bool

    public init(id: UUID, title: String, body: String, version: Int, kind: MemoryKind, categories: [String],
                sensitivity: Sensitivity, weak: Bool) {
        self.id = id
        self.title = title
        self.body = body
        self.version = version
        self.kind = kind
        self.categories = categories
        self.sensitivity = sensitivity
        self.weak = weak
    }
}

/// Where shared text goes, from what the Mac knows (the Goes to line): an agent on the Mac, or a
/// cloud agent through Remote Access, with its vendor and tunnel when known.
public struct ApprovalDestination: Codable, Sendable, Equatable {
    public var remote: Bool
    /// "Anthropic", "OpenAI"…
    public var vendor: String?
    /// "Tailscale Funnel"…
    public var tunnel: String?

    public init(remote: Bool, vendor: String? = nil, tunnel: String? = nil) {
        self.remote = remote
        self.vendor = vendor
        self.tunnel = tunnel
    }
}

/// The Share panel: what the agent said (shown as reported, never checked), then the memories.
public struct SharePanel: Codable, Sendable, Equatable {
    public var destination: ApprovalDestination
    public var keywords: [String]
    public var purpose: String?
    /// What the agent says it does with what it gets.
    public var retention: Retention
    public var processors: [String]
    /// The user's own note on the agent (Keeps what it gets), when set.
    public var declaredRetention: Retention?
    /// In score order; strong matches first is the phone's to do, as on the Mac.
    public var rows: [ApprovalRow]
    /// "2 more matched but can't go to this agent": counts by reason, never ids (ADR-0012).
    public var withheld: [ReasonCode: Int]

    public init(destination: ApprovalDestination, keywords: [String], purpose: String?, retention: Retention,
                processors: [String], declaredRetention: Retention?, rows: [ApprovalRow], withheld: [ReasonCode: Int]) {
        self.destination = destination
        self.keywords = keywords
        self.purpose = purpose
        self.retention = retention
        self.processors = processors
        self.declaredRetention = declaredRetention
        self.rows = rows
        self.withheld = withheld
    }

    enum CodingKeys: String, CodingKey {
        case destination, keywords, purpose, retention, processors, declaredRetention, rows, withheld
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destination = try c.decode(ApprovalDestination.self, forKey: .destination)
        keywords = try c.decode([String].self, forKey: .keywords)
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose)
        retention = try c.decode(Retention.self, forKey: .retention)
        processors = try c.decode([String].self, forKey: .processors)
        declaredRetention = try c.decodeIfPresent(Retention.self, forKey: .declaredRetention)
        rows = try c.decode([ApprovalRow].self, forKey: .rows)
        // An object keyed by reason code; an unknown code (a newer Mac) is dropped, not an error.
        let raw = try c.decode([String: Int].self, forKey: .withheld)
        withheld = Dictionary(uniqueKeysWithValues: raw.compactMap { key, count in ReasonCode(rawValue: key).map { ($0, count) } })
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(destination, forKey: .destination)
        try c.encode(keywords, forKey: .keywords)
        try c.encodeIfPresent(purpose, forKey: .purpose)
        try c.encode(retention, forKey: .retention)
        try c.encode(processors, forKey: .processors)
        try c.encodeIfPresent(declaredRetention, forKey: .declaredRetention)
        try c.encode(rows, forKey: .rows)
        try c.encode(Dictionary(uniqueKeysWithValues: withheld.map { ($0.key.rawValue, $0.value) }), forKey: .withheld)
    }
}

/// The Save panel: the suggested memory, as the agent proposed it (Edit… is the Inbox's).
public struct SavePanel: Codable, Sendable, Equatable {
    public var action: SuggestionAction
    /// A correction of this memory.
    public var targetMemoryId: UUID?
    public var title: String
    public var body: String
    public var kind: MemoryKind?
    public var categories: [String]
    public var sensitivity: Sensitivity?
    public var expiresAt: Date?
    /// The agent's Why, shown as reported.
    public var evidence: String?
    public var purpose: String?

    public init(action: SuggestionAction, targetMemoryId: UUID? = nil, title: String, body: String, kind: MemoryKind?,
                categories: [String], sensitivity: Sensitivity?, expiresAt: Date? = nil, evidence: String? = nil,
                purpose: String? = nil) {
        self.action = action
        self.targetMemoryId = targetMemoryId
        self.title = title
        self.body = body
        self.kind = kind
        self.categories = categories
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
        self.evidence = evidence
        self.purpose = purpose
    }
}

/// "<Agent> wants to read <Category>" (access policy §7).
public struct AccessPanel: Codable, Sendable, Equatable {
    public var operation: AccessOperation
    /// Nil when an operation is missing ("wants to suggest memories").
    public var categoryKey: String?
    public var categoryName: String?
    /// False when the agent already got its answer: only Not Now and Always Allow.
    public var allowsOnce: Bool
    /// Whether the agent asks before sharing, for the panel's line under the title.
    public var asksBeforeSharing: Bool

    public init(operation: AccessOperation, categoryKey: String?, categoryName: String?, allowsOnce: Bool,
                asksBeforeSharing: Bool) {
        self.operation = operation
        self.categoryKey = categoryKey
        self.categoryName = categoryName
        self.allowsOnce = allowsOnce
        self.asksBeforeSharing = asksBeforeSharing
    }
}

/// `approvals.get`: one panel. Exactly one of `share`, `save` and `access` is set, as `kind` says.
public struct ApprovalDetail: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: ApprovalKind
    /// Send it back with the answer. A stale one is `request_changed` (access policy §3.6).
    public var revision: String
    public var agentName: String
    public var agentKind: AgentKind?
    /// The task as the agent stated it, while the Mac still holds it (15 minutes).
    public var task: String?
    public var createdAt: Date
    public var expiresAt: Date
    public var share: SharePanel?
    public var save: SavePanel?
    public var access: AccessPanel?

    public init(id: UUID, kind: ApprovalKind, revision: String, agentName: String, agentKind: AgentKind? = nil,
                task: String? = nil, createdAt: Date, expiresAt: Date, share: SharePanel? = nil, save: SavePanel? = nil,
                access: AccessPanel? = nil) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.agentName = agentName
        self.agentKind = agentKind
        self.task = task
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.share = share
        self.save = save
        self.access = access
    }
}

// MARK: - approvals.answer

/// Answers one panel, once. Bound to the id and the revision the phone showed; the first answer
/// wins on the Mac or a phone, and a later one is `already_answered`. Not resent automatically.
public enum ApprovalsAnswer: CompanionCall {
    public static let method = CompanionMethod.approvalsAnswer
    public typealias Params = ApprovalAnswerParams
    public typealias Result = ApprovalAnswered
}

public struct ApprovalAnswerParams: Codable, Sendable, Equatable {
    public var id: UUID
    public var revision: String
    public var choice: ApprovalChoice
    /// `share` only: the ticked memories, at least one.
    public var memoryIds: [UUID]?

    public init(id: UUID, revision: String, choice: ApprovalChoice, memoryIds: [UUID]? = nil) {
        self.id = id
        self.revision = revision
        self.choice = choice
        self.memoryIds = memoryIds
    }

    public func validate() throws(CompanionError) {
        guard !revision.isEmpty, revision.count <= 128 else { throw CompanionError(.invalidInput, message: "Bad revision") }
        if choice == .share {
            guard let memoryIds, !memoryIds.isEmpty, memoryIds.count <= 200, Set(memoryIds).count == memoryIds.count else {
                throw CompanionError(.invalidInput, message: "Tick at least one memory")
            }
        } else if memoryIds != nil {
            throw CompanionError(.invalidInput, message: "memoryIds is for share only")
        }
    }
}

public struct ApprovalAnswered: Codable, Sendable, Equatable {
    public var choice: ApprovalChoice
    /// `save`: the memory created or updated.
    public var memoryId: UUID?

    public init(choice: ApprovalChoice, memoryId: UUID? = nil) {
        self.choice = choice
        self.memoryId = memoryId
    }
}

// MARK: - approvals.settings.*

/// This device's approvals switch (on by default once paired), shared by Settings ▸ iPhone on
/// the Mac and Settings on the phone. `get` hands the phone its doorbell tag while approvals are
/// on, so it can subscribe; turning them off drops the tag, and the next one is new.
public enum ApprovalsSettingsGet: CompanionCall {
    public static let method = CompanionMethod.approvalsSettingsGet
    public typealias Params = EmptyParams
    public typealias Result = ApprovalSettings
}

public enum ApprovalsSettingsSet: CompanionCall {
    public static let method = CompanionMethod.approvalsSettingsSet
    public typealias Params = ApprovalSettingsChange
    public typealias Result = ApprovalSettings
}

public struct ApprovalSettingsChange: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool) { self.enabled = enabled }
}

/// Whether the Mac can ring the doorbell at all. Approvals still work without it: on the Mac, or
/// in the phone app's list when it's opened.
public enum DoorbellAvailability: String, Codable, Sendable, CaseIterable {
    case available
    /// The Mac isn't signed in to iCloud.
    case noAccount = "no_account"
    /// iCloud is restricted (Screen Time, a managed Mac) or temporarily unavailable.
    case restricted
    /// This build of the Mac app has no iCloud entitlement (a development build).
    case unsupported
}

public struct ApprovalSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// The value to subscribe to (`tag == <tag>`), while `enabled`.
    public var tag: String?
    public var container: String
    public var recordType: String
    public var doorbell: DoorbellAvailability

    public init(enabled: Bool, tag: String?, container: String = Doorbell.container, recordType: String = Doorbell.recordType,
                doorbell: DoorbellAvailability) {
        self.enabled = enabled
        self.tag = tag
        self.container = container
        self.recordType = recordType
        self.doorbell = doorbell
    }
}
