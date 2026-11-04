import Foundation
import FunesProtocol
import GRDB

/// The fields of a new memory.
public struct MemoryDraft: Sendable, Hashable {
    public var title: String
    public var body: String
    public var kind: MemoryKind
    public var categoryKeys: [String]
    /// `nil` means the default: LOW, raised to the highest default of the memory's categories
    /// (SENSITIVE for Health, Finance and Legal; FR-V-07).
    public var sensitivity: Sensitivity?
    public var expiresAt: Date?
    public var confidence: Double?
    public var source: MemorySource
    public var sourceAgentID: UUID?
    public var sourceDeviceID: UUID?
    /// `nil`: untrusted for an agent's direct write, trusted otherwise.
    public var trust: MemoryTrust?

    public init(title: String, body: String, kind: MemoryKind = .fact, categoryKeys: [String],
                sensitivity: Sensitivity? = nil, expiresAt: Date? = nil, confidence: Double? = nil,
                source: MemorySource = .manual, sourceAgentID: UUID? = nil, sourceDeviceID: UUID? = nil,
                trust: MemoryTrust? = nil) {
        self.title = title
        self.body = body
        self.kind = kind
        self.categoryKeys = categoryKeys
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
        self.confidence = confidence
        self.source = source
        self.sourceAgentID = sourceAgentID
        self.sourceDeviceID = sourceDeviceID
        self.trust = trust
    }
}

/// Changes to a memory; `nil` keeps a field. `expiresAt: .some(nil)` clears the expiry.
public struct MemoryEdit: Sendable, Hashable {
    public var title: String?
    public var body: String?
    public var kind: MemoryKind?
    public var categoryKeys: [String]?
    public var sensitivity: Sensitivity?
    public var expiresAt: Date??
    public var confidence: Double??

    public init(title: String? = nil, body: String? = nil, kind: MemoryKind? = nil, categoryKeys: [String]? = nil,
                sensitivity: Sensitivity? = nil, expiresAt: Date?? = nil, confidence: Double?? = nil) {
        self.title = title
        self.body = body
        self.kind = kind
        self.categoryKeys = categoryKeys
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
        self.confidence = confidence
    }
}

/// Vault search and list filters (FR-V-11).
public struct MemoryFilter: Sendable, Hashable {
    public enum StatusFilter: Sendable, Hashable {
        /// Active and not expired.
        case active
        case archived
        /// Active but past its expiry.
        case expired
        case recentlyDeleted
        /// Active, expired or not.
        case activeIncludingExpired
    }

    public enum Sort: Sendable, Hashable { case updated, created, title }

    public var status: StatusFilter
    public var categoryKeys: Set<String>
    public var kinds: Set<MemoryKind>
    public var sensitivities: Set<Sensitivity>
    public var sources: Set<MemorySource>
    public var sort: Sort

    public init(status: StatusFilter = .active, categoryKeys: Set<String> = [], kinds: Set<MemoryKind> = [],
                sensitivities: Set<Sensitivity> = [], sources: Set<MemorySource> = [], sort: Sort = .updated) {
        self.status = status
        self.categoryKeys = categoryKeys
        self.kinds = kinds
        self.sensitivities = sensitivities
        self.sources = sources
        self.sort = sort
    }
}

/// Memory reads and writes on an open `Database`, so services can combine them in one transaction.
/// Every write keeps the invariants (storage §4): at least one category, the secret scanner, a
/// version bump with `updated_at` on every versioned change, and a provenance row.
enum MemoryStore {
    static let deletedRetention: TimeInterval = 30 * 86_400

    // MARK: Reads

    static func fetch(_ db: Database, id: UUID) throws -> Memory? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory WHERE id = ?", arguments: [id.db]) else {
            return nil
        }
        return try Memory.from(row: row, categoryKeys: categoryKeys(db, memoryID: id))
    }

    /// The memories with these ids that exist, in the order given.
    static func fetch(_ db: Database, ids: [UUID]) throws -> [Memory] {
        guard !ids.isEmpty else { return [] }
        var found: [UUID: Memory] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = databaseQuestionMarks(count: chunk.count)
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM memory WHERE id IN (\(marks))",
                                        arguments: StatementArguments(chunk.map(\.db)))
            let cats = try categoryKeys(db, memoryIDs: chunk)
            for row in rows {
                let id = try row.requiredUUID("id")
                found[id] = try Memory.from(row: row, categoryKeys: cats[id] ?? [])
            }
        }
        return ids.compactMap { found[$0] }
    }

    static func categoryKeys(_ db: Database, memoryID: UUID) throws -> [String] {
        // In category order (sort_order, then key): the first is the memory's primary category.
        try String.fetchAll(db, sql: """
            SELECT mc.category_key FROM memory_category mc JOIN category c ON c.key = mc.category_key
            WHERE mc.memory_id = ? ORDER BY c.sort_order, c.key
            """, arguments: [memoryID.db])
    }

    static func categoryKeys(_ db: Database, memoryIDs: [UUID]) throws -> [UUID: [String]] {
        let marks = databaseQuestionMarks(count: memoryIDs.count)
        var out: [UUID: [String]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT mc.memory_id, mc.category_key FROM memory_category mc JOIN category c ON c.key = mc.category_key
            WHERE mc.memory_id IN (\(marks)) ORDER BY c.sort_order, c.key
            """, arguments: StatementArguments(memoryIDs.map(\.db))) {
            out[try row.requiredUUID("memory_id"), default: []].append(row["category_key"])
        }
        return out
    }

    static func list(_ db: Database, filter: MemoryFilter, now: Date, limit: Int? = nil) throws -> [Memory] {
        try fetch(db, ids: listed(db, filter: filter, now: now, limit: limit).map(\.id))
    }

    /// The ids and update times of `list`, in its order, without reading the memories (search's
    /// pool: reading 10,000 bodies took most of FR-V-10's 150 ms).
    static func listed(_ db: Database, filter: MemoryFilter, now: Date, limit: Int? = nil) throws -> [(id: UUID, updatedAt: Date)] {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []
        switch filter.status {
        case .active:
            clauses.append("status = 'active' AND (expires_at IS NULL OR expires_at > ?)")
            args.append(now)
        case .expired:
            clauses.append("status = 'active' AND expires_at IS NOT NULL AND expires_at <= ?")
            args.append(now)
        case .archived: clauses.append("status = 'archived'")
        case .recentlyDeleted: clauses.append("status = 'deleted'")
        case .activeIncludingExpired: clauses.append("status = 'active'")
        }
        if !filter.categoryKeys.isEmpty {
            clauses.append("id IN (SELECT memory_id FROM memory_category WHERE category_key IN (\(databaseQuestionMarks(count: filter.categoryKeys.count))))")
            args += filter.categoryKeys.sorted()
        }
        if !filter.kinds.isEmpty {
            clauses.append("kind IN (\(databaseQuestionMarks(count: filter.kinds.count)))")
            args += filter.kinds.map(\.rawValue).sorted()
        }
        if !filter.sensitivities.isEmpty {
            clauses.append("sensitivity IN (\(databaseQuestionMarks(count: filter.sensitivities.count)))")
            args += filter.sensitivities.map(\.rawValue).sorted()
        }
        if !filter.sources.isEmpty {
            clauses.append("source IN (\(databaseQuestionMarks(count: filter.sources.count)))")
            args += filter.sources.map(\.rawValue).sorted()
        }
        let order = switch filter.sort {
        case .updated: "updated_at DESC, seq DESC"
        case .created: "created_at DESC, seq DESC"
        case .title: "title COLLATE NOCASE, seq"
        }
        return try Row.fetchAll(db, sql: """
            SELECT id, updated_at FROM memory WHERE \(clauses.joined(separator: " AND ")) ORDER BY \(order)\(limit.map { " LIMIT \($0)" } ?? "")
            """, arguments: StatementArguments(args)).compactMap { row in
            row.uuid("id").map { (id: $0, updatedAt: row["updated_at"] as Date) }
        }
    }

    static func provenance(_ db: Database, memoryID: UUID) throws -> [ProvenanceEntry] {
        try Row.fetchAll(db, sql: "SELECT * FROM provenance WHERE memory_id = ? ORDER BY id", arguments: [memoryID.db])
            .map { row in
                ProvenanceEntry(memoryID: memoryID, at: row["at"], event: try row.required("event"), actor: row["actor"],
                                fieldsChanged: JSON.decode([String].self, row["fields_changed"]) ?? [],
                                relatedMemoryID: row.uuid("related_memory_id"), engine: row["engine"])
            }
    }

    /// `expected`: the version the caller showed. Another one is `versionConflict`; nil skips the check.
    static func checkVersion(_ db: Database, id: UUID, expected: Int?) throws {
        guard let expected else { return }
        guard let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [id.db]) else {
            throw VaultError.notFound
        }
        guard version == expected else { throw VaultError.versionConflict }
    }

    static func trust(_ db: Database, id: UUID) throws -> MemoryTrust? {
        try String.fetchOne(db, sql: "SELECT trust FROM memory WHERE id = ?", arguments: [id.db]).flatMap(MemoryTrust.init)
    }

    // MARK: Validation

    /// Checks the lengths and categories, and runs the secret scanner. Returns the category keys
    /// without duplicates, in category order.
    static func validate(_ db: Database, title: String, body: String, categoryKeys: [String],
                         extraTexts: [String] = []) throws -> [String] {
        guard InputLimits.title.contains(InputLimits.length(of: title)) else { throw VaultError.invalidInput(field: "title") }
        guard InputLimits.body.contains(InputLimits.length(of: body)) else { throw VaultError.invalidInput(field: "body") }
        let keys = try validateCategories(db, categoryKeys)
        let findings = SecretScanner.scan([title, body] + extraTexts)
        guard findings.isEmpty else { throw VaultError.secretLikeContent(findings) }
        return keys
    }

    static func validateCategories(_ db: Database, _ categoryKeys: [String]) throws -> [String] {
        var seen = Set<String>()
        let keys = categoryKeys.filter { seen.insert($0).inserted }
        guard !keys.isEmpty else { throw VaultError.noCategories }
        guard keys.count <= InputLimits.memoryCategories else { throw VaultError.invalidInput(field: "categories") }
        var order: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, sort_order FROM category") { order[row["key"]] = row["sort_order"] }
        if let unknown = keys.first(where: { order[$0] == nil }) { throw VaultError.unknownCategory(unknown) }
        return keys.sorted { (order[$0]!, $0) < (order[$1]!, $1) }
    }

    /// The highest default sensitivity of these categories, at least LOW.
    static func defaultSensitivity(_ db: Database, categoryKeys: [String]) throws -> Sensitivity {
        guard !categoryKeys.isEmpty else { return .low }
        let ranks = try Int.fetchAll(db, sql: """
            SELECT default_sensitivity FROM category WHERE key IN (\(databaseQuestionMarks(count: categoryKeys.count)))
            """, arguments: StatementArguments(categoryKeys))
        return max(.low, ranks.compactMap(Sensitivity.init(rawValue:)).max() ?? .low)
    }

    // MARK: Writes

    @discardableResult
    static func insert(_ db: Database, _ draft: MemoryDraft, actor: Actor, now: Date, id: UUID = UUID()) throws -> Memory {
        let keys = try validate(db, title: draft.title, body: draft.body, categoryKeys: draft.categoryKeys)
        if let confidence = draft.confidence, !(0...1).contains(confidence) { throw VaultError.invalidInput(field: "confidence") }
        let sensitivity = try draft.sensitivity ?? defaultSensitivity(db, categoryKeys: keys)
        let memory = Memory(
            id: id, title: draft.title, body: draft.body, kind: draft.kind, categoryKeys: keys, sensitivity: sensitivity,
            expiresAt: draft.expiresAt, confidence: draft.confidence, source: draft.source,
            sourceAgentID: draft.sourceAgentID, sourceDeviceID: draft.sourceDeviceID, createdAt: now, updatedAt: now)
        let trust = draft.trust ?? (draft.source == .agentWrite ? .untrusted : .trusted)
        try db.execute(sql: """
            INSERT INTO memory (id, title, body, kind, sensitivity, status, expires_at, confidence, source,
              source_agent_id, source_device_id, created_at, updated_at, version, trust)
            VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?, 1, ?)
            """, arguments: [memory.id.db, memory.title, memory.body, memory.kind.rawValue, sensitivity.rawValue,
                             memory.expiresAt, memory.confidence, memory.source.rawValue, memory.sourceAgentID?.db,
                             memory.sourceDeviceID?.db, now, now, trust.rawValue])
        try setCategories(db, memoryID: memory.id, keys: keys)
        try appendProvenance(db, memoryID: memory.id, event: .created, actor: actor, at: now)
        return memory
    }

    /// Applies `edit` to an active or archived memory. Versioned fields that actually change bump
    /// the version once and add one `edited` provenance row naming them. A change by the owner
    /// (the user, or a paired iPhone) makes the memory trusted.
    @discardableResult
    static func update(_ db: Database, id: UUID, _ edit: MemoryEdit, actor: Actor, now: Date,
                       event: ProvenanceEvent = .edited) throws -> Memory {
        guard var m = try fetch(db, id: id), m.status != .deleted else { throw VaultError.notFound }
        let old = m
        var changed: [String] = []
        if let title = edit.title, title != m.title { m.title = title; changed.append("title") }
        if let body = edit.body, body != m.body { m.body = body; changed.append("body") }
        if let kind = edit.kind, kind != m.kind { m.kind = kind; changed.append("kind") }
        if let keys = edit.categoryKeys {
            let valid = try validateCategories(db, keys)
            if valid != m.categoryKeys { m.categoryKeys = valid; changed.append("categories") }
        }
        if let s = edit.sensitivity, s != m.sensitivity { m.sensitivity = s; changed.append("sensitivity") }
        if let e = edit.expiresAt, e != m.expiresAt { m.expiresAt = e; changed.append("expires_at") }
        var confidenceChanged = false
        if let c = edit.confidence, c != m.confidence {
            if let c, !(0...1).contains(c) { throw VaultError.invalidInput(field: "confidence") }
            m.confidence = c
            confidenceChanged = true
        }
        guard !changed.isEmpty || confidenceChanged else { return m }
        _ = try validate(db, title: m.title, body: m.body, categoryKeys: m.categoryKeys)
        if !changed.isEmpty {
            try RevisionStore.record(db, old, actor: actor, at: now)
            m.version += 1
            m.updatedAt = now
        }
        try db.execute(sql: """
            UPDATE memory SET title = ?, body = ?, kind = ?, sensitivity = ?, expires_at = ?, confidence = ?,
              updated_at = ?, version = ? WHERE id = ?
            """, arguments: [m.title, m.body, m.kind.rawValue, m.sensitivity.rawValue, m.expiresAt, m.confidence,
                             m.updatedAt, m.version, id.db])
        if changed.contains("categories") { try setCategories(db, memoryID: id, keys: m.categoryKeys) }
        if !changed.isEmpty, actor.isOwner {
            try db.execute(sql: "UPDATE memory SET trust = 'trusted' WHERE id = ?", arguments: [id.db])
        }
        try appendProvenance(db, memoryID: id, event: event, actor: actor, at: now,
                             fields: changed + (confidenceChanged ? ["confidence"] : []))
        return m
    }

    /// archive (active → archived), restore (archived or deleted → active) and delete (→ deleted).
    @discardableResult
    static func setStatus(_ db: Database, id: UUID, to status: MemoryStatus, actor: Actor, now: Date) throws -> Memory {
        guard var m = try fetch(db, id: id) else { throw VaultError.notFound }
        let event: ProvenanceEvent
        switch (m.status, status) {
        case (.active, .archived): event = .archived
        case (.archived, .active), (.deleted, .active): event = .restored
        case (.active, .deleted), (.archived, .deleted): event = .deleted
        default: throw VaultError.invalidState
        }
        try RevisionStore.record(db, m, actor: actor, at: now)
        m.status = status
        m.version += 1
        m.updatedAt = now
        m.deletedAt = status == .deleted ? now : nil
        try db.execute(sql: "UPDATE memory SET status = ?, deleted_at = ?, updated_at = ?, version = ? WHERE id = ?",
                       arguments: [status.rawValue, m.deletedAt, now, m.version, id.db])
        try appendProvenance(db, memoryID: id, event: event, actor: actor, at: now, fields: ["status"])
        return m
    }

    /// "Still true" (FR-V-15). Not a versioned change.
    static func confirm(_ db: Database, id: UUID, actor: Actor, now: Date) throws {
        guard let m = try fetch(db, id: id), m.status != .deleted else { throw VaultError.notFound }
        try db.execute(sql: "UPDATE memory SET last_confirmed_at = ? WHERE id = ?", arguments: [now, id.db])
        try appendProvenance(db, memoryID: id, event: .confirmed, actor: actor, at: now)
    }

    /// Hard-deletes a deleted memory: its row, categories, FTS rows, embeddings, provenance and
    /// the undo entries holding its earlier text.
    /// Disclosure items keep the id for Activity labels.
    static func purge(_ db: Database, id: UUID) throws {
        guard let status = try String.fetchOne(db, sql: "SELECT status FROM memory WHERE id = ?", arguments: [id.db]) else {
            throw VaultError.notFound
        }
        guard status == MemoryStatus.deleted.rawValue else { throw VaultError.invalidState }
        try UndoLog.purge(db, memoryIDs: [id.db])
        try dropGroupText(db, memoryIDs: [id.db])
        try db.execute(sql: "DELETE FROM memory WHERE id = ?", arguments: [id.db])
    }

    /// The daily job: purges memories deleted more than 30 days before `now`. Returns how many.
    static func purgeDeleted(_ db: Database, now: Date) throws -> Int {
        let cutoff = now.addingTimeInterval(-deletedRetention)
        let ids = try String.fetchAll(db, sql: "SELECT id FROM memory WHERE status = 'deleted' AND deleted_at <= ?", arguments: [cutoff])
        try UndoLog.purge(db, memoryIDs: ids)
        try dropGroupText(db, memoryIDs: ids)
        try db.execute(sql: "DELETE FROM memory WHERE status = 'deleted' AND deleted_at <= ?", arguments: [cutoff])
        return db.changesCount
    }

    /// A purged memory leaves no copy of its text (FR-V-04, storage §2): the piece it was saved
    /// from, and its split input's original text, lose theirs.
    static func dropGroupText(_ db: Database, memoryIDs: [String]) throws {
        guard !memoryIDs.isEmpty else { return }
        let marks = databaseQuestionMarks(count: memoryIDs.count)
        let groups = try String.fetchAll(db, sql: """
            SELECT DISTINCT group_id FROM suggestion WHERE group_id IS NOT NULL AND result_memory_id IN (\(marks))
            """, arguments: StatementArguments(memoryIDs))
        try db.execute(sql: "UPDATE suggestion SET title = '', body = '', evidence = NULL WHERE group_id IS NOT NULL AND result_memory_id IN (\(marks))",
                       arguments: StatementArguments(memoryIDs))
        for group in groups {
            try db.execute(sql: "UPDATE suggestion_group SET source_text = NULL WHERE id = ?", arguments: [group])
            try db.execute(sql: "UPDATE suggestion SET title = '', body = '' WHERE id = ? AND status = 'split'", arguments: [group])
        }
    }

    static func setCategories(_ db: Database, memoryID: UUID, keys: [String]) throws {
        try db.execute(sql: "DELETE FROM memory_category WHERE memory_id = ?", arguments: [memoryID.db])
        for key in keys {
            try db.execute(sql: "INSERT INTO memory_category (memory_id, category_key) VALUES (?, ?)",
                           arguments: [memoryID.db, key])
        }
    }

    static func appendProvenance(_ db: Database, memoryID: UUID, event: ProvenanceEvent, actor: Actor, at: Date,
                                 fields: [String] = [], relatedMemoryID: UUID? = nil, engine: String? = nil) throws {
        try db.execute(sql: """
            INSERT INTO provenance (memory_id, at, event, actor, fields_changed, related_memory_id, engine)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [memoryID.db, at, event.rawValue, actor.description, fields.isEmpty ? nil : JSON.encode(fields),
                             relatedMemoryID?.db, engine])
    }

    /// Lowercased with whitespace collapsed: the duplicate hint's exact match (memory processing §8).
    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Active memories whose normalized title and body equal these.
    static func exactDuplicates(_ db: Database, title: String, body: String, excluding: UUID? = nil) throws -> [UUID] {
        let t = normalized(title), b = normalized(body)
        // Narrow with SQL on the lowercased title, then compare exactly in Swift.
        let rows = try Row.fetchAll(db, sql: "SELECT id, title, body FROM memory WHERE status = 'active'")
        return rows.compactMap { row -> UUID? in
            guard let id = row.uuid("id"), id != excluding,
                  normalized(row["title"]) == t, normalized(row["body"]) == b else { return nil }
            return id
        }
    }
}

// MARK: - Public store API

extension VaultStore {
    public func memory(id: UUID) throws -> Memory? {
        try writer.read { db in try MemoryStore.fetch(db, id: id) }
    }

    public func memories(ids: [UUID]) throws -> [Memory] {
        try writer.read { db in try MemoryStore.fetch(db, ids: ids) }
    }

    public func memories(_ filter: MemoryFilter = MemoryFilter(), now: Date, limit: Int? = nil) throws -> [Memory] {
        try writer.read { db in try MemoryStore.list(db, filter: filter, now: now, limit: limit) }
    }

    public func provenance(memoryID: UUID) throws -> [ProvenanceEntry] {
        try writer.read { db in try MemoryStore.provenance(db, memoryID: memoryID) }
    }

    public func trust(memoryID: UUID) throws -> MemoryTrust? {
        try writer.read { db in try MemoryStore.trust(db, id: memoryID) }
    }

    /// Creates a memory (FR-V-01). Runs validation and the secret scanner.
    @discardableResult
    public func createMemory(_ draft: MemoryDraft, actor: Actor = .user, now: Date) throws -> Memory {
        try writer.write { db in try MemoryStore.insert(db, draft, actor: actor, now: now) }
    }

    /// Edits a memory (FR-V-02). `expectedVersion` is the version the editor showed: another one
    /// is `versionConflict` and nothing is saved, so a change made meanwhile isn't overwritten.
    @discardableResult
    public func updateMemory(id: UUID, _ edit: MemoryEdit, expectedVersion: Int? = nil, actor: Actor = .user,
                             now: Date) throws -> Memory {
        try writer.write { db in
            try MemoryStore.checkVersion(db, id: id, expected: expectedVersion)
            return try MemoryStore.update(db, id: id, edit, actor: actor, now: now)
        }
    }

    @discardableResult
    public func archiveMemory(id: UUID, expectedVersion: Int? = nil, actor: Actor = .user, now: Date) throws -> Memory {
        try setStatus(id: id, to: .archived, expectedVersion: expectedVersion, actor: actor, now: now)
    }

    /// Restores an archived memory, or a deleted one within 30 days.
    @discardableResult
    public func restoreMemory(id: UUID, expectedVersion: Int? = nil, actor: Actor = .user, now: Date) throws -> Memory {
        try setStatus(id: id, to: .active, expectedVersion: expectedVersion, actor: actor, now: now)
    }

    /// Moves a memory to Recently Deleted (FR-V-04).
    @discardableResult
    public func deleteMemory(id: UUID, expectedVersion: Int? = nil, actor: Actor = .user, now: Date) throws -> Memory {
        try setStatus(id: id, to: .deleted, expectedVersion: expectedVersion, actor: actor, now: now)
    }

    private func setStatus(id: UUID, to status: MemoryStatus, expectedVersion: Int?, actor: Actor, now: Date) throws -> Memory {
        try writer.write { db in
            try MemoryStore.checkVersion(db, id: id, expected: expectedVersion)
            return try MemoryStore.setStatus(db, id: id, to: status, actor: actor, now: now)
        }
    }

    /// Delete Now: purges a deleted memory immediately.
    public func purgeMemory(id: UUID) throws {
        try writer.write { db in try MemoryStore.purge(db, id: id) }
    }

    @discardableResult
    public func purgeDeletedMemories(now: Date) throws -> Int {
        try writer.write { db in try MemoryStore.purgeDeleted(db, now: now) }
    }

    public func confirmMemory(id: UUID, actor: Actor = .user, now: Date) throws {
        try writer.write { db in try MemoryStore.confirm(db, id: id, actor: actor, now: now) }
    }

    /// The duplicate hint's exact part: active memories with the same normalized title and body.
    public func exactDuplicates(title: String, body: String, excluding: UUID? = nil) throws -> [UUID] {
        try writer.read { db in try MemoryStore.exactDuplicates(db, title: title, body: body, excluding: excluding) }
    }
}
