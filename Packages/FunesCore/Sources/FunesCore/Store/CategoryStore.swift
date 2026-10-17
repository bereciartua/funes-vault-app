import Foundation
import FunesProtocol
import GRDB

/// Category reads and writes (FR-V-05, FR-V-06).
enum CategoryStore {
    static func all(_ db: Database) throws -> [MemoryCategory] {
        try Row.fetchAll(db, sql: "SELECT * FROM category ORDER BY sort_order, key").map(MemoryCategory.from(row:))
    }

    static func fetch(_ db: Database, key: String) throws -> MemoryCategory? {
        try Row.fetchOne(db, sql: "SELECT * FROM category WHERE key = ?", arguments: [key]).map(MemoryCategory.from(row:))
    }
}

extension MemoryCategory {
    /// The immutable key for a new custom category named `name` (FR-V-06): lowercase ASCII letters,
    /// digits and underscores from the name, starting with a letter, unique among `existing`.
    public static func key(forName name: String, existing: Set<String>) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
        var key = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                key.unicodeScalars.append(scalar)
            } else if !key.hasSuffix("_"), !key.isEmpty {
                key += "_"
            }
        }
        while key.hasSuffix("_") { key.removeLast() }
        if key.isEmpty || !("a"..."z").contains(key.unicodeScalars.first!) { key = "category_" + key }
        key = String(key.prefix(60))
        while key.hasSuffix("_") { key.removeLast() }
        var candidate = key
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(key)_\(n)"
            n += 1
        }
        return candidate
    }
}

extension VaultStore {
    public func categories() throws -> [MemoryCategory] {
        try writer.read { db in try CategoryStore.all(db) }
    }

    /// Creates a custom category (FR-V-06). The key is an immutable slug.
    @discardableResult
    public func createCategory(key: String, name: String, description: String = "",
                               defaultSensitivity: Sensitivity = .low) throws -> MemoryCategory {
        guard MemoryCategory.isValidKey(key) else { throw VaultError.invalidInput(field: "key") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(InputLimits.length(of: name)) else { throw VaultError.invalidInput(field: "name") }
        guard InputLimits.length(of: description) <= 500 else { throw VaultError.invalidInput(field: "description") }
        return try writer.write { db in
            guard try CategoryStore.fetch(db, key: key) == nil else { throw VaultError.categoryExists }
            let order = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM category") ?? 0) + 1
            try db.execute(sql: """
                INSERT INTO category (key, name, description, builtin, default_sensitivity, sort_order) VALUES (?, ?, ?, 0, ?, ?)
                """, arguments: [key, name, description, defaultSensitivity.rawValue, order])
            return MemoryCategory(key: key, name: name, description: description, defaultSensitivity: defaultSensitivity,
                                  sortOrder: order)
        }
    }

    /// Renames a category; built-in ones too (FR-V-05). The key never changes.
    public func renameCategory(key: String, name: String, description: String? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(InputLimits.length(of: name)) else { throw VaultError.invalidInput(field: "name") }
        try writer.write { db in
            guard try CategoryStore.fetch(db, key: key) != nil else { throw VaultError.notFound }
            try db.execute(sql: "UPDATE category SET name = ?, description = COALESCE(?, description) WHERE key = ?",
                           arguments: [name, description, key])
        }
    }

    /// Deletes a custom category (FR-V-06).
    ///
    /// - Memories in it move to `replacement` when given; otherwise the category is removed from
    ///   them, and that is refused (`categoryInUse`) if any would be left without a category.
    /// - Agents' deny lists: with a replacement, the replacement is denied too, so memories that
    ///   were hidden stay hidden. Allow lists drop the key; if that would leave an agent's allow list
    ///   empty (meaning *all* categories) the deletion is refused (`onlyAllowedCategory`), because a
    ///   removed allowed category must never silently widen access. Each changed agent's revision
    ///   goes up, which invalidates its pending approvals.
    public func deleteCategory(key: String, replacement: String? = nil, now: Date) throws {
        try writer.write { db in
            guard let category = try CategoryStore.fetch(db, key: key) else { throw VaultError.notFound }
            guard !category.builtin else { throw VaultError.builtinCategory }
            if let replacement {
                guard replacement != key, try CategoryStore.fetch(db, key: replacement) != nil else {
                    throw VaultError.unknownCategory(replacement)
                }
            }
            // Agents whose allow list is exactly this category.
            let onlyAllowed = try String.fetchAll(db, sql: """
                SELECT agent_id FROM access_category a WHERE mode = 'allow' AND category_key = ?
                  AND NOT EXISTS (SELECT 1 FROM access_category b WHERE b.agent_id = a.agent_id AND b.mode = 'allow'
                                  AND b.category_key != a.category_key)
                """, arguments: [key]).compactMap(UUID.init(uuidString:))
            if replacement == nil, !onlyAllowed.isEmpty { throw VaultError.onlyAllowedCategory(agentIDs: onlyAllowed) }

            let memoryIDs = try String.fetchAll(db, sql: "SELECT memory_id FROM memory_category WHERE category_key = ?",
                                                arguments: [key]).compactMap(UUID.init(uuidString:))
            for id in memoryIDs {
                var keys = try MemoryStore.categoryKeys(db, memoryID: id).filter { $0 != key }
                if let replacement, !keys.contains(replacement) { keys.append(replacement) }
                guard !keys.isEmpty else { throw VaultError.categoryInUse }
                let status = try String.fetchOne(db, sql: "SELECT status FROM memory WHERE id = ?", arguments: [id.db])
                if status == MemoryStatus.deleted.rawValue {
                    try MemoryStore.setCategories(db, memoryID: id, keys: try MemoryStore.validateCategories(db, keys))
                } else {
                    try MemoryStore.update(db, id: id, MemoryEdit(categoryKeys: keys), actor: .user, now: now)
                }
            }

            let agents = try String.fetchAll(db, sql: "SELECT DISTINCT agent_id FROM access_category WHERE category_key = ?",
                                             arguments: [key])
            for agent in agents {
                let modes = Set(try String.fetchAll(db, sql: "SELECT mode FROM access_category WHERE agent_id = ? AND category_key = ?",
                                                    arguments: [agent, key]))
                if let replacement {
                    if modes.contains("deny") {
                        try db.execute(sql: "INSERT OR IGNORE INTO access_category (agent_id, category_key, mode) VALUES (?, ?, 'deny')",
                                       arguments: [agent, replacement])
                    }
                    if modes.contains("allow"), onlyAllowed.contains(where: { $0.db == agent }) {
                        // Keep the agent narrowed to what replaced its only allowed category.
                        try db.execute(sql: "INSERT OR IGNORE INTO access_category (agent_id, category_key, mode) VALUES (?, ?, 'allow')",
                                       arguments: [agent, replacement])
                    }
                }
                try db.execute(sql: "UPDATE agent SET revision = revision + 1 WHERE id = ?", arguments: [agent])
            }
            try db.execute(sql: "DELETE FROM access_category WHERE category_key = ?", arguments: [key])
            try db.execute(sql: "DELETE FROM category WHERE key = ?", arguments: [key])
        }
    }
}
