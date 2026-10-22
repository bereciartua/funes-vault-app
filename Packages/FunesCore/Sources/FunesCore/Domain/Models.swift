import Foundation
import FunesProtocol

/// Who did something, as recorded in provenance and Activity: `user`, `agent:<id>`,
/// `device:<id>` or `import:<id>`.
public enum Actor: Sendable, Hashable, CustomStringConvertible {
    case user
    case agent(UUID)
    case device(UUID)
    case importRun(UUID)
    case system

    public var description: String {
        switch self {
        case .user: "user"
        case let .agent(id): "agent:\(id.db)"
        case let .device(id): "device:\(id.db)"
        case let .importRun(id): "import:\(id.db)"
        case .system: "system"
        }
    }
}

/// One entry of a memory's history. Field names only, never values (FR-V-12).
public struct ProvenanceEntry: Sendable, Hashable {
    public var memoryID: UUID
    public var at: Date
    public var event: ProvenanceEvent
    public var actor: String
    public var fieldsChanged: [String]
}

/// An agent's access (spec/domain/domain-model.md#access-one-per-agent). The defaults are no access.
public struct Access: Sendable, Hashable, Codable {
    public var operations: Set<AccessOperation>
    public var maxSensitivity: Sensitivity
    /// Empty means all categories.
    public var allowedCategoryKeys: Set<String>
    public var deniedCategoryKeys: Set<String>
    public var askBeforeSharing: Bool
    public var askBeforeSaving: Bool
    public var expiresAt: Date?

    public init(operations: Set<AccessOperation> = [], maxSensitivity: Sensitivity = .low,
                allowedCategoryKeys: Set<String> = [], deniedCategoryKeys: Set<String> = [],
                askBeforeSharing: Bool = true, askBeforeSaving: Bool = true, expiresAt: Date? = nil) {
        self.operations = operations
        self.maxSensitivity = maxSensitivity
        self.allowedCategoryKeys = allowedCategoryKeys
        self.deniedCategoryKeys = deniedCategoryKeys
        self.askBeforeSharing = askBeforeSharing
        self.askBeforeSaving = askBeforeSaving
        self.expiresAt = expiresAt
    }

    /// Starting access presets (FR-A-02).
    public enum Preset: String, Sendable, CaseIterable {
        case nothingYet = "nothing_yet"
        case readLowAskFirst = "read_low_ask_first"
        case readAndSuggestAskFirst = "read_and_suggest_ask_first"

        public var access: Access {
            switch self {
            case .nothingYet: Access()
            case .readLowAskFirst: Access(operations: [.read], maxSensitivity: .low)
            case .readAndSuggestAskFirst:
                Access(operations: [.read, .suggest], maxSensitivity: .internal,
                       deniedCategoryKeys: ["health", "finance", "legal"])
            }
        }
    }
}

/// An MCP client the user added (spec/domain/domain-model.md#agent).
public struct Agent: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var agentKind: AgentKind
    public var keyIssuedAt: Date?
    public var paused: Bool
    /// +1 on any change to access, pause or key. Pending approvals bind to it.
    public var revision: Int
    public var declaredRetention: Retention
    public var asksForAccess: Bool
    public var firstRequestAt: Date?
    public var lastRequestAt: Date?
    public var createdAt: Date
    public var removedAt: Date?
    public var access: Access
    /// Remote Access (ADR-0018): its remote token and OAuth-connected cloud apps may reach it
    /// through the tunnel. Off by default; it never changes `access`.
    public var cloudAccess = false
    /// When the remote token (`fns_mcpr_v1_`) was issued; nil without one.
    public var remoteKeyIssuedAt: Date?

    public var isRemoved: Bool { removedAt != nil }
    public var hasRemoteKey: Bool { remoteKeyIssuedAt != nil }
}

/// A paired iPhone (spec/domain/domain-model.md#device-a-paired-iphone).
public struct Device: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var model: String
    public var signingPublicKey: Data
    public var hpkePublicKey: Data
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var lastTransport: DeviceTransport?
    public var revokedAt: Date?
    /// Approvals from this iPhone (FR-iOS-12): on by default once paired.
    public var approvalsEnabled = true
    /// The doorbell's tag (ADR-0019): random, handed to the phone over the companion channel
    /// while approvals are on. Nil until the phone asks, and dropped when they're turned off.
    public var doorbellTag: String?

    public var isRevoked: Bool { revokedAt != nil }
    /// The Mac rings this device when a request starts waiting.
    public var rings: Bool { !isRevoked && approvalsEnabled && doorbellTag != nil }
}

/// A proposed memory waiting for review (spec/domain/domain-model.md#suggestion).
public struct Suggestion: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var origin: SuggestionOrigin
    public var agentID: UUID?
    public var deviceID: UUID?
    public var importRunID: UUID?
    public var captureID: UUID?
    public var targetMemoryID: UUID?
    public var action: SuggestionAction
    public var title: String
    public var body: String
    public var kind: MemoryKind?
    public var categoryKeys: [String]
    public var sensitivity: Sensitivity?
    public var expiresAt: Date?
    public var confidence: Double?
    public var evidence: String?
    public var purpose: String?
    /// Inert JSON from the caller; never interpreted (FR-S-05).
    public var callerMetadata: String?
    /// Proposed fields plus the engine that produced them (JSON).
    public var classification: String?
    public var status: SuggestionStatus
    public var createdAt: Date
    public var decidedAt: Date?
    /// `createdAt` + 30 days.
    public var expiresAfter: Date
    public var resultMemoryID: UUID?
}

/// One `{memoryId, version}` of a disclosure's candidate snapshot, with its search score. The
/// score only decides which panel rows start ticked; `snapshotRevision` hashes id and version alone.
/// Rows stored before scores were kept decode with `score` nil.
public struct SnapshotItem: Sendable, Hashable, Codable {
    public var id: UUID
    public var version: Int
    public var score: Double?

    public init(id: UUID, version: Int, score: Double? = nil) {
        self.id = id
        self.version = version
        self.score = score
    }
}

/// A request from an agent to read memories (spec/domain/domain-model.md#disclosure-a-request-from-an-agent-to-read-memories).
/// The task text is never stored.
public struct Disclosure: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var agentID: UUID
    public var agentRevisionAtRequest: Int
    public var taskHash: String
    public var taskLength: Int
    public var purpose: String?
    public var retention: Retention
    public var processors: [String]
    public var maxTokens: Int
    public var requestedCategoryKeys: [String]
    public var status: DisclosureStatus
    public var reason: ReasonCode?
    /// The eligible memories when the request was evaluated, in score order.
    public var candidateSnapshot: [SnapshotItem]
    public var snapshotRevision: String?
    public var approvedMemoryIDs: [UUID]?
    public var approvalExpiresAt: Date?
    /// `{reasonCode: count}`; never ids.
    public var withheld: [ReasonCode: Int]
    public var createdAt: Date
    public var decidedAt: Date?
    public var deliveredAt: Date?
}

/// Written when a disclosure is delivered. The text isn't stored.
public struct DisclosureItem: Sendable, Hashable {
    public var disclosureID: UUID
    public var memoryID: UUID
    public var memoryVersion: Int
    public var sensitivity: Sensitivity
    public var categoryKey: String
    public var estimatedTokens: Int
    public var clipped: Bool
}

extension UUID {
    /// The database and wire spelling of an id: lowercase UUID text.
    public var db: String { uuidString.lowercased() }
}
