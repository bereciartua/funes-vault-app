// The domain enumerations (spec/domain/domain-model.md#enumerations). Raw values are the wire and
// database spellings and are final from the first public release.

/// What a memory is about (FR-V-08).
public enum MemoryKind: String, Codable, Sendable, CaseIterable {
    case fact, preference, instruction, goal
    case projectContext = "project_context"
    case relationship, constraint, event, summary

    /// The kind as words, as it appears in a memory's embedding text: `project context`.
    public var words: String { rawValue.replacingOccurrences(of: "_", with: " ") }
}

/// Six ordered levels, PUBLIC < LOW < INTERNAL < SENSITIVE < RESTRICTED < SECRET (FR-V-07).
///
/// The raw value is the rank stored in the database (0…5). On the wire and in JSON a level is its
/// name (`"low"`), so `Codable` uses `name`.
public enum Sensitivity: Int, Sendable, CaseIterable, Comparable, Codable {
    case `public` = 0, low, `internal`, sensitive, restricted, secret

    public var name: String {
        switch self {
        case .public: "public"
        case .low: "low"
        case .internal: "internal"
        case .sensitive: "sensitive"
        case .restricted: "restricted"
        case .secret: "secret"
        }
    }

    public init?(name: String) {
        guard let level = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = level
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let level = Sensitivity(name: name) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown sensitivity")
        }
        self = level
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

/// What an agent may do (Access.operations). The spec calls it `Operation`, which would clash with Foundation.
public enum AccessOperation: String, Codable, Sendable, CaseIterable {
    case read, suggest, write
}

/// How an agent says it keeps what it receives (FR-A-12). Informational only.
public enum Retention: String, Codable, Sendable, CaseIterable {
    case none, session, persistent, unknown
}

public enum MemoryStatus: String, Codable, Sendable, CaseIterable {
    case active, archived, deleted
}

/// The disclosure state machine (spec/domain/domain-model.md#disclosure).
public enum DisclosureStatus: String, Codable, Sendable, CaseIterable {
    case evaluating, fulfilled
    case needsApproval = "needs_approval"
    case approved, delivered, denied, failed
}

public enum SuggestionStatus: String, Codable, Sendable, CaseIterable {
    case pending, applied, rejected, expired
}

public enum SuggestionAction: String, Codable, Sendable, CaseIterable {
    case create, update, archive
}

/// Where a memory came from.
public enum MemorySource: String, Codable, Sendable, CaseIterable {
    case manual
    case captureMac = "capture_mac"
    case captureIPhone = "capture_iphone"
    case agentSuggestion = "agent_suggestion"
    case agentWrite = "agent_write"
    case importChatGPT = "import_chatgpt"
    case importClaude = "import_claude"
    case importMarkdown = "import_markdown"
    case importFunes = "import_funes"
    case seedQuestion = "seed_question"
}

/// Where a suggestion came from.
public enum SuggestionOrigin: String, Codable, Sendable, CaseIterable {
    case agent
    case captureMac = "capture_mac"
    case captureIPhone = "capture_iphone"
    case `import`
    case seedQuestion = "seed_question"
    case consolidation
}

/// The reason codes of spec/domain/access-policy.md#8-reason-codes, shown to agents and in Activity.
public enum ReasonCode: String, Codable, Sendable, CaseIterable {
    // Gate
    case funesPaused = "funes_paused"
    case agentPaused = "agent_paused"
    case accessExpired = "access_expired"
    case operationNotAllowed = "operation_not_allowed"
    // Retrieval
    case noMatchingMemories = "no_matching_memories"
    // Per memory
    case inactiveMemory = "inactive_memory"
    case expiredMemory = "expired_memory"
    case aboveSensitivityCeiling = "above_sensitivity_ceiling"
    case deniedCategory = "denied_category"
    case categoryNotAllowed = "category_not_allowed"
    // Decision
    case noAllowedMemories = "no_allowed_memories"
    case confirmationRequired = "confirmation_required"
    case allowed
    case allowedByWindow = "allowed_by_window"
    // Approval and delivery
    case deniedByUser = "denied_by_user"
    case approvalExpired = "approval_expired"
    case policyChanged = "policy_changed"
    case alreadyDelivered = "already_delivered"
    case notFound = "not_found"
    // Suggest validation
    case invalidInput = "invalid_input"
    case unknownCategory = "unknown_category"
    case secretLikeContent = "secret_like_content"
    // Transport
    case rateLimited = "rate_limited"
    case funesQuit = "funes_quit"
}

/// The detected type of an MCP client; drives the icon and setup snippets.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude_code"
    case claudeDesktop = "claude_desktop"
    case cursor, codex, vscode, zed
    case geminiCLI = "gemini_cli"
    case devinDesktop = "devin_desktop"
    case cline
    case jetBrains = "jetbrains"
    case other
}

/// Events recorded in a memory's provenance (FR-V-12). Never holds text.
public enum ProvenanceEvent: String, Codable, Sendable, CaseIterable {
    case created, edited, archived, restored, deleted, shared, confirmed
    case suggestedCorrection = "suggested_correction"
    case appliedFromSuggestion = "applied_from_suggestion"
}

/// How a paired iPhone last reached the Mac.
public enum DeviceTransport: String, Codable, Sendable, CaseIterable {
    case lan, tailscale, tunnel
}
