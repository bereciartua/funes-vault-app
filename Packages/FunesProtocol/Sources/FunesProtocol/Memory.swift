import Foundation

/// A durable piece of personal context (spec/domain/domain-model.md#memory). Shared with the
/// iPhone, which shows memories but never stores them.
public struct Memory: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var kind: MemoryKind
    /// At least one; the first is the memory's primary category in bundles.
    public var categoryKeys: [String]
    public var sensitivity: Sensitivity
    public var status: MemoryStatus
    public var expiresAt: Date?
    public var confidence: Double?
    public var source: MemorySource
    public var sourceAgentID: UUID?
    public var sourceDeviceID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastConfirmedAt: Date?
    public var deletedAt: Date?
    /// +1 on every change to the title, body, kind, categories, sensitivity, status or expiry.
    public var version: Int

    public init(
        id: UUID = UUID(), title: String, body: String, kind: MemoryKind, categoryKeys: [String],
        sensitivity: Sensitivity, status: MemoryStatus = .active, expiresAt: Date? = nil, confidence: Double? = nil,
        source: MemorySource, sourceAgentID: UUID? = nil, sourceDeviceID: UUID? = nil,
        createdAt: Date, updatedAt: Date, lastConfirmedAt: Date? = nil, deletedAt: Date? = nil, version: Int = 1
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.categoryKeys = categoryKeys
        self.sensitivity = sensitivity
        self.status = status
        self.expiresAt = expiresAt
        self.confidence = confidence
        self.source = source
        self.sourceAgentID = sourceAgentID
        self.sourceDeviceID = sourceDeviceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConfirmedAt = lastConfirmedAt
        self.deletedAt = deletedAt
        self.version = version
    }

    /// Expiry is computed, not a status: expired when `expiresAt <= now`.
    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// The text released to agents (spec/domain/access-policy.md#4-bundle-compilation).
    public var disclosureText: String { "\(title): \(body)" }
}

/// A category (spec/domain/domain-model.md#category). The key is an immutable slug.
public struct Category: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var name: String
    public var description: String
    public var builtin: Bool
    public var defaultSensitivity: Sensitivity
    public var sortOrder: Int

    public var id: String { key }

    public init(key: String, name: String, description: String = "", builtin: Bool = false,
                defaultSensitivity: Sensitivity = .low, sortOrder: Int = 0) {
        self.key = key
        self.name = name
        self.description = description
        self.builtin = builtin
        self.defaultSensitivity = defaultSensitivity
        self.sortOrder = sortOrder
    }

    /// The eight built-in categories (FR-V-05), keys from the web version.
    public static let builtins: [Category] = [
        Category(key: "communication_style", name: "Communication style",
                 description: "How you like assistants to write, format and talk to you.", builtin: true, sortOrder: 0),
        Category(key: "personal_preferences", name: "Personal preferences",
                 description: "Likes, dislikes, habits and everyday choices.", builtin: true, sortOrder: 1),
        Category(key: "software_development", name: "Software development",
                 description: "Languages, tools, conventions and how you build software.", builtin: true, sortOrder: 2),
        Category(key: "project_context", name: "Project context",
                 description: "Current projects, goals, people and constraints around your work.", builtin: true, sortOrder: 3),
        Category(key: "privacy_preferences", name: "Privacy preferences",
                 description: "What assistants should be careful with or never share.", builtin: true, sortOrder: 4),
        Category(key: "health", name: "Health",
                 description: "Medical, dietary and wellbeing information.", builtin: true, defaultSensitivity: .sensitive, sortOrder: 5),
        Category(key: "finance", name: "Finance",
                 description: "Money, accounts, income and financial plans.", builtin: true, defaultSensitivity: .sensitive, sortOrder: 6),
        Category(key: "legal", name: "Legal",
                 description: "Contracts, legal matters and official documents.", builtin: true, defaultSensitivity: .sensitive, sortOrder: 7),
    ]

    /// Whether `key` is a valid category slug: lowercase ASCII letters, digits and underscores,
    /// starting with a letter, 1–64 characters.
    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, ("a"..."z").contains(first), key.unicodeScalars.count <= 64 else {
            return false
        }
        return key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
}
