import Foundation

/// The companion methods (§4). Each acts as the owner and is logged in Activity as `device:<id>`.
public enum CompanionMethod: String, Codable, Sendable, CaseIterable {
    case statusGet = "status.get"
    case capturesSubmit = "captures.submit"
    /// The vault's counts for Home and the widgets (v0.4, ADR-0025).
    case overviewGet = "overview.get"
    case categoriesList = "categories.list"
    case memoriesSearch = "memories.search"
    case memoriesGet = "memories.get"
    case memoriesCreate = "memories.create"
    case memoriesUpdate = "memories.update"
    case memoriesArchive = "memories.archive"
    case memoriesRestore = "memories.restore"
    case memoriesDelete = "memories.delete"
    case inboxList = "inbox.list"
    case inboxApply = "inbox.apply"
    case inboxReject = "inbox.reject"
    /// Try again / Keep as one on an item whose split failed (memory processing §5.2).
    case inboxRetry = "inbox.retry"
    case inboxKeep = "inbox.keep"
    case deviceUnpair = "device.unpair"
    // Approvals from the iPhone (task 5.6, FR-iOS-12).
    case approvalsList = "approvals.list"
    case approvalsGet = "approvals.get"
    case approvalsAnswer = "approvals.answer"
    case approvalsSettingsGet = "approvals.settings.get"
    case approvalsSettingsSet = "approvals.settings.set"
}

/// A method with its parameter and result types, so calls are typed on both ends.
public protocol CompanionCall {
    associatedtype Params: Codable & Sendable
    associatedtype Result: Codable & Sendable
    static var method: CompanionMethod { get }
}

/// `{"id":"<call id>","method":"…","params":{…}}`, the plaintext inside an envelope.
public struct CompanionRequest<Params: Codable & Sendable>: Codable, Sendable {
    public var id: String
    public var method: CompanionMethod
    public var params: Params

    public init<Call: CompanionCall>(_ call: Call.Type, id: String = UUID().uuidString.lowercased(), params: Call.Params)
        where Call.Params == Params {
        self.id = id
        self.method = Call.method
        self.params = params
    }

    public func encoded() throws -> Data { try CompanionJSON.encoder().encode(self) }
}

/// The first look at a request on the Mac: its id and method, before its params are decoded with
/// the method's own type.
public struct CompanionRequestHead: Sendable {
    public var id: String
    /// Nil for a method this Mac doesn't know (answer `unknown_method`).
    public var method: CompanionMethod?
    private let plaintext: Data

    public init(plaintext: Data) throws(CompanionError) {
        guard let head = try? JSONDecoder().decode(Head.self, from: plaintext) else {
            throw CompanionError(.invalidInput, message: "Not a request")
        }
        id = head.id
        method = CompanionMethod(rawValue: head.method)
        self.plaintext = plaintext
    }

    /// The params as `Call` expects them. A method without params also accepts none at all.
    public func params<Call: CompanionCall>(_ call: Call.Type) throws(CompanionError) -> Call.Params {
        guard method == Call.method else { throw CompanionError(.invalidInput, message: "Wrong method") }
        let decoder = CompanionJSON.decoder()
        if let request = try? decoder.decode(CompanionRequest<Call.Params>.self, from: plaintext) {
            return request.params
        }
        if Call.Params.self == EmptyParams.self, let empty = EmptyParams() as? Call.Params {
            return empty
        }
        throw CompanionError(.invalidInput, message: "Bad params")
    }

    private struct Head: Decodable {
        var id: String
        var method: String
    }
}

/// `{"id":"…","result":{…}}` or `{"id":"…","error":{"code":"…","message":"…"}}`.
public struct CompanionResponse<Result: Codable & Sendable>: Codable, Sendable {
    public var id: String
    public var result: Result?
    public var error: CompanionError?

    public init(id: String, result: Result) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: String, error: CompanionError) {
        self.id = id
        self.result = nil
        self.error = error
    }

    public func encoded() throws -> Data { try CompanionJSON.encoder().encode(self) }

    /// The result, or the call's error thrown.
    public func get() throws(CompanionError) -> Result {
        if let error { throw error }
        guard let result else { throw CompanionError(.internalError, message: "Empty response") }
        return result
    }

    public static func decode(_ json: Data) throws(CompanionError) -> Self {
        do { return try CompanionJSON.decoder().decode(Self.self, from: json) } catch {
            throw CompanionError(.internalError, message: "Unreadable response")
        }
    }
}

public struct EmptyParams: Codable, Sendable, Equatable {
    public init() {}
}

public struct EmptyResult: Codable, Sendable, Equatable {
    public init() {}
}

// MARK: - status.get

public enum StatusGet: CompanionCall {
    public static let method = CompanionMethod.statusGet
    public typealias Params = EmptyParams
    public typealias Result = CompanionStatus
}

public struct CompanionStatus: Codable, Sendable, Equatable {
    public var macName: String
    public var appVersion: String
    public var serverTime: Date
    public var inboxPending: Int
    public var vaultActive: Bool
    /// The name the profile says to call the user (preferred, else given), for Home's title
    /// (v0.5, ADR-0026). Absent without one, and from older Macs.
    public var calledName: String?

    public init(macName: String, appVersion: String, serverTime: Date, inboxPending: Int, vaultActive: Bool,
                calledName: String? = nil) {
        self.macName = macName
        self.appVersion = appVersion
        self.serverTime = serverTime
        self.inboxPending = inboxPending
        self.vaultActive = vaultActive
        self.calledName = calledName
    }
}

// MARK: - captures.submit

public enum CapturesSubmit: CompanionCall {
    public static let method = CompanionMethod.capturesSubmit
    public typealias Params = CapturesSubmitParams
    public typealias Result = CapturesSubmitResult
}

/// How a capture was made on the phone.
public enum CaptureSource: String, Codable, Sendable, CaseIterable {
    case typed, dictation, share, intent
}

public struct CompanionCapture: Codable, Sendable, Equatable {
    /// The idempotency key: a repeat is accepted without creating anything (§6).
    public var captureId: UUID
    public var text: String
    public var createdAt: Date
    public var source: CaptureSource
    public var note: String?

    public init(captureId: UUID, text: String, createdAt: Date, source: CaptureSource, note: String? = nil) {
        self.captureId = captureId
        self.text = text
        self.createdAt = createdAt
        self.source = source
        self.note = note
    }
}

public struct CapturesSubmitParams: Codable, Sendable, Equatable {
    /// At most 50, oldest first.
    public var captures: [CompanionCapture]

    public init(captures: [CompanionCapture]) { self.captures = captures }

    public func validate() throws(CompanionError) {
        guard (1...CompanionProtocol.maxCapturesPerCall).contains(captures.count) else {
            throw CompanionError(.invalidInput, message: "1 to 50 captures per call")
        }
    }
}

public struct CaptureRejection: Codable, Sendable, Equatable {
    public var captureId: UUID
    public var reason: CompanionErrorCode

    public init(captureId: UUID, reason: CompanionErrorCode) {
        self.captureId = captureId
        self.reason = reason
    }
}

public struct CapturesSubmitResult: Codable, Sendable, Equatable {
    /// Includes duplicates: the phone deletes these.
    public var accepted: [UUID]
    public var rejected: [CaptureRejection]

    public init(accepted: [UUID], rejected: [CaptureRejection]) {
        self.accepted = accepted
        self.rejected = rejected
    }
}

// MARK: - categories.list

public enum CategoriesList: CompanionCall {
    public static let method = CompanionMethod.categoriesList
    public typealias Params = EmptyParams
    public typealias Result = [CompanionCategory]
}

public struct CompanionCategory: Codable, Sendable, Equatable {
    public var key: String
    public var name: String
    public var description: String
    public var builtin: Bool
    public var defaultSensitivity: Sensitivity

    public init(_ category: MemoryCategory) {
        key = category.key
        name = category.name
        description = category.description
        builtin = category.builtin
        defaultSensitivity = category.defaultSensitivity
    }
}

// MARK: - memories.*

public enum MemoriesSearch: CompanionCall {
    public static let method = CompanionMethod.memoriesSearch
    public typealias Params = MemorySearchParams
    public typealias Result = MemorySearchResult
}

public struct MemorySearchFilters: Codable, Sendable, Equatable {
    public var categories: [String]?
    public var kinds: [MemoryKind]?
    public var sensitivities: [Sensitivity]?
    /// Active when absent.
    public var status: MemoryStatus?

    public init(categories: [String]? = nil, kinds: [MemoryKind]? = nil, sensitivities: [Sensitivity]? = nil,
                status: MemoryStatus? = nil) {
        self.categories = categories
        self.kinds = kinds
        self.sensitivities = sensitivities
        self.status = status
    }
}

public struct MemorySearchParams: Codable, Sendable, Equatable {
    /// Empty lists the most recently updated memories.
    public var query: String
    public var filters: MemorySearchFilters?
    /// At most 50.
    public var limit: Int?
    public var cursor: String?

    public init(query: String, filters: MemorySearchFilters? = nil, limit: Int? = nil, cursor: String? = nil) {
        self.query = query
        self.filters = filters
        self.limit = limit
        self.cursor = cursor
    }

    public func validate() throws(CompanionError) {
        if let limit, !(1...CompanionProtocol.maxSearchLimit).contains(limit) {
            throw CompanionError(.invalidInput, message: "limit is 1 to 50")
        }
        guard InputLimits.length(of: query) <= InputLimits.task.upperBound else {
            throw CompanionError(.invalidInput, message: "Query too long")
        }
    }
}

public struct MemorySummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var snippet: String
    /// The search's matches inside `snippet`, as UTF-16 `[start, length]` pairs (v0.6, FR-V-17;
    /// absent from an older Mac, and without a match).
    public var snippetMatches: [[Int]]?
    public var kind: MemoryKind
    public var categories: [String]
    public var sensitivity: Sensitivity
    public var updatedAt: Date
    public var expiresAt: Date?

    public init(id: UUID, title: String, snippet: String, snippetMatches: [[Int]]? = nil, kind: MemoryKind, categories: [String],
                sensitivity: Sensitivity, updatedAt: Date, expiresAt: Date? = nil) {
        self.id = id
        self.title = title
        self.snippet = snippet
        self.snippetMatches = snippetMatches
        self.kind = kind
        self.categories = categories
        self.sensitivity = sensitivity
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

public struct MemorySearchResult: Codable, Sendable, Equatable {
    public var results: [MemorySummary]
    public var nextCursor: String?

    public init(results: [MemorySummary], nextCursor: String? = nil) {
        self.results = results
        self.nextCursor = nextCursor
    }
}

public enum MemoriesGet: CompanionCall {
    public static let method = CompanionMethod.memoriesGet
    public typealias Params = MemoryID
    public typealias Result = CompanionMemory
}

public struct MemoryID: Codable, Sendable, Equatable {
    public var id: UUID

    public init(id: UUID) { self.id = id }
}

/// One line of a memory's history, worded on the Mac ("Created on Sam's iPhone").
public struct ProvenanceLabel: Codable, Sendable, Equatable {
    public var at: Date
    public var event: String
    public var label: String

    public init(at: Date, event: String, label: String) {
        self.at = at
        self.event = event
        self.label = label
    }
}

/// `memories.get`: the full memory, its history as labels, and how often it was shared.
public struct CompanionMemory: Codable, Sendable, Equatable {
    public var memory: Memory
    public var provenance: [ProvenanceLabel]
    public var sharedCount: Int
    public var lastSharedAt: Date?

    public init(memory: Memory, provenance: [ProvenanceLabel], sharedCount: Int, lastSharedAt: Date? = nil) {
        self.memory = memory
        self.provenance = provenance
        self.sharedCount = sharedCount
        self.lastSharedAt = lastSharedAt
    }
}

public enum MemoriesCreate: CompanionCall {
    public static let method = CompanionMethod.memoriesCreate
    public typealias Params = MemoryCreateParams
    public typealias Result = MemoryCreated
}

public struct MemoryCreateParams: Codable, Sendable, Equatable {
    public var title: String
    public var body: String
    public var kind: MemoryKind
    public var categories: [String]
    public var sensitivity: Sensitivity
    public var expiresAt: Date?

    public init(title: String, body: String, kind: MemoryKind, categories: [String], sensitivity: Sensitivity,
                expiresAt: Date? = nil) {
        self.title = title
        self.body = body
        self.kind = kind
        self.categories = categories
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
    }
}

public struct MemoryCreated: Codable, Sendable, Equatable {
    public var id: UUID
    public var version: Int

    public init(id: UUID, version: Int) {
        self.id = id
        self.version = version
    }
}

/// The fields an edit changes. Absent means unchanged; for `expiresAt`, an explicit `null`
/// removes the expiry.
public struct MemoryChanges: Codable, Sendable, Equatable {
    public var title: String?
    public var body: String?
    public var kind: MemoryKind?
    public var categories: [String]?
    public var sensitivity: Sensitivity?
    /// Nil: unchanged. `.some(nil)`: no expiry. `.some(date)`: expires then.
    public var expiresAt: Date??

    public init(title: String? = nil, body: String? = nil, kind: MemoryKind? = nil, categories: [String]? = nil,
                sensitivity: Sensitivity? = nil, expiresAt: Date?? = nil) {
        self.title = title
        self.body = body
        self.kind = kind
        self.categories = categories
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
    }

    public var isEmpty: Bool {
        title == nil && body == nil && kind == nil && categories == nil && sensitivity == nil && expiresAt == nil
    }

    enum CodingKeys: String, CodingKey {
        case title, body, kind, categories, sensitivity, expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        kind = try c.decodeIfPresent(MemoryKind.self, forKey: .kind)
        categories = try c.decodeIfPresent([String].self, forKey: .categories)
        sensitivity = try c.decodeIfPresent(Sensitivity.self, forKey: .sensitivity)
        if c.contains(.expiresAt) {
            expiresAt = .some(try c.decodeNil(forKey: .expiresAt) ? nil : try c.decode(Date.self, forKey: .expiresAt))
        } else {
            expiresAt = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(categories, forKey: .categories)
        try c.encodeIfPresent(sensitivity, forKey: .sensitivity)
        switch expiresAt {
        case .none: break
        case .some(.none): try c.encodeNil(forKey: .expiresAt)
        case let .some(.some(date)): try c.encode(date, forKey: .expiresAt)
        }
    }
}

public enum MemoriesUpdate: CompanionCall {
    public static let method = CompanionMethod.memoriesUpdate
    public typealias Params = MemoryUpdateParams
    public typealias Result = MemoryVersion
}

public struct MemoryUpdateParams: Codable, Sendable, Equatable {
    public var id: UUID
    /// The version the phone last saw; a stale one is `conflict`.
    public var version: Int
    public var changes: MemoryChanges

    public init(id: UUID, version: Int, changes: MemoryChanges) {
        self.id = id
        self.version = version
        self.changes = changes
    }
}

/// `memories.archive`, `memories.restore` and `memories.delete` name a memory at a version.
public struct MemoryVersionRef: Codable, Sendable, Equatable {
    public var id: UUID
    public var version: Int

    public init(id: UUID, version: Int) {
        self.id = id
        self.version = version
    }
}

public struct MemoryVersion: Codable, Sendable, Equatable {
    public var version: Int

    public init(version: Int) { self.version = version }
}

public enum MemoriesArchive: CompanionCall {
    public static let method = CompanionMethod.memoriesArchive
    public typealias Params = MemoryVersionRef
    public typealias Result = MemoryVersion
}

public enum MemoriesRestore: CompanionCall {
    public static let method = CompanionMethod.memoriesRestore
    public typealias Params = MemoryVersionRef
    public typealias Result = MemoryVersion
}

public enum MemoriesDelete: CompanionCall {
    public static let method = CompanionMethod.memoriesDelete
    public typealias Params = MemoryVersionRef
    public typealias Result = MemoryVersion
}

// MARK: - inbox.*

public enum InboxList: CompanionCall {
    public static let method = CompanionMethod.inboxList
    public typealias Params = InboxListParams
    public typealias Result = InboxListResult
}

public struct InboxListParams: Codable, Sendable, Equatable {
    public var cursor: String?

    public init(cursor: String? = nil) { self.cursor = cursor }
}

/// A pending suggestion, as the Inbox card shows it. `sourceLabel` is worded on the Mac
/// ("Claude Code", "Sam's iPhone").
public struct InboxItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var origin: SuggestionOrigin
    public var action: SuggestionAction
    public var sourceLabel: String
    public var targetMemoryId: UUID?
    public var title: String
    public var body: String
    public var kind: MemoryKind
    public var categories: [String]
    public var sensitivity: Sensitivity
    public var expiresAt: Date?
    public var evidence: String?
    public var purpose: String?
    public var createdAt: Date
    /// The target's version when it was suggested; the Mac refuses a changed one (`target_changed`).
    public var targetMemoryVersion: Int?
    /// The input this piece was split from (Phase 6), and how the Mac words it ("ChatGPT · 12 pieces").
    public var groupId: UUID?
    public var groupLabel: String?
    /// Outside the agent's scope: never applied in bulk.
    public var outsideScope: Bool
    /// New memories processing hasn't finished with it (`processing`: greyed, can't be saved,
    /// only rejected), or its split failed (`failed`: Try again or Keep as one). Nil otherwise.
    public var processing: InboxProcessing?

    public init(id: UUID, origin: SuggestionOrigin, action: SuggestionAction, sourceLabel: String, targetMemoryId: UUID? = nil,
                title: String, body: String, kind: MemoryKind, categories: [String], sensitivity: Sensitivity,
                expiresAt: Date? = nil, evidence: String? = nil, purpose: String? = nil, createdAt: Date,
                targetMemoryVersion: Int? = nil, groupId: UUID? = nil, groupLabel: String? = nil, outsideScope: Bool = false,
                processing: InboxProcessing? = nil) {
        self.processing = processing
        self.targetMemoryVersion = targetMemoryVersion
        self.groupId = groupId
        self.groupLabel = groupLabel
        self.outsideScope = outsideScope
        self.id = id
        self.origin = origin
        self.action = action
        self.sourceLabel = sourceLabel
        self.targetMemoryId = targetMemoryId
        self.title = title
        self.body = body
        self.kind = kind
        self.categories = categories
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
        self.evidence = evidence
        self.purpose = purpose
        self.createdAt = createdAt
    }
}

/// An Inbox item New memories processing holds (memory processing §5.2).
public enum InboxProcessing: String, Codable, Sendable, Equatable {
    /// Queued, running or waiting: "Processing…". `inbox.apply` refuses it with `processing`.
    case processing
    /// The split failed: "Couldn't split", with Try again (`inbox.retry`) and Keep as one (`inbox.keep`).
    case failed
}

public struct InboxListResult: Codable, Sendable, Equatable {
    public var items: [InboxItem]
    public var nextCursor: String?

    public init(items: [InboxItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum InboxApply: CompanionCall {
    public static let method = CompanionMethod.inboxApply
    public typealias Params = InboxApplyParams
    public typealias Result = InboxApplied
}

public struct InboxApplyParams: Codable, Sendable, Equatable {
    public var suggestionId: UUID
    /// Edit & Apply.
    public var edits: MemoryChanges?

    public init(suggestionId: UUID, edits: MemoryChanges? = nil) {
        self.suggestionId = suggestionId
        self.edits = edits
    }
}

public struct InboxApplied: Codable, Sendable, Equatable {
    public var memoryId: UUID

    public init(memoryId: UUID) { self.memoryId = memoryId }
}

public enum InboxReject: CompanionCall {
    public static let method = CompanionMethod.inboxReject
    public typealias Params = SuggestionID
    public typealias Result = EmptyResult
}

/// Try again: a failed split goes back to the queue. `conflict` when it isn't failed any more.
public enum InboxRetry: CompanionCall {
    public static let method = CompanionMethod.inboxRetry
    public typealias Params = SuggestionID
    public typealias Result = EmptyResult
}

/// Keep as one: a failed split stays one suggestion, then saved like any other.
public enum InboxKeep: CompanionCall {
    public static let method = CompanionMethod.inboxKeep
    public typealias Params = SuggestionID
    public typealias Result = EmptyResult
}

public struct SuggestionID: Codable, Sendable, Equatable {
    public var suggestionId: UUID

    public init(suggestionId: UUID) { self.suggestionId = suggestionId }
}

// MARK: - device.unpair

/// The phone removes itself; the Mac marks the device revoked.
public enum DeviceUnpair: CompanionCall {
    public static let method = CompanionMethod.deviceUnpair
    public typealias Params = EmptyParams
    public typealias Result = EmptyResult
}
