import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 1 task 1.2: schema v1, invariants and FTS sync (spec/architecture/storage.md).
@Suite struct StoreTests {
    @Test func migratesFromEmpty() throws {
        let v = try TestVault()
        let tables = try v.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table') AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'memory_fts_%' AND name != 'grdb_migrations' ORDER BY name")
        }
        #expect(tables == ["access", "access_category", "agent", "capture_receipt", "category", "device", "disclosure",
                           "disclosure_item", "embedding", "import_run", "memory", "memory_category", "memory_fts",
                           "meta", "processing_job", "provenance", "suggestion", "suggestion_group", "suggestion_target",
                           "tidy_up_dismissal", "tidy_up_run", "undo_entry"])
        #expect(try v.store.categories().map(\.key) == MemoryCategory.builtins.map(\.key))
        #expect(try v.store.categories().first { $0.key == "health" }?.defaultSensitivity == .sensitive)
        #expect(try v.store.meta("active_embedding_model") == "bge-small-en-v1.5/coreml-int8")
        let vaultID = try #require(try v.store.meta("vault_id"))
        #expect(UUID(uuidString: vaultID) != nil)
        #expect(try v.store.writer.read { db in try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") } == true)
        #expect(try v.store.writer.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") } == "wal")
        #expect(try v.store.quickCheck())
    }

    @Test func reopensWithoutRemigratingAndRefusesNewerSchemas() throws {
        let v = try TestVault()
        try v.memory("Kept")
        let vaultID = try v.store.meta("vault_id")
        let again = try VaultStore.open(directory: v.directory)
        #expect(try again.meta("vault_id") == vaultID)
        #expect(try again.memories(now: t0).map(\.title) == ["Kept"])
        try again.writer.write { db in try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99_future')") }
        #expect(throws: VaultError.newerSchema) { try VaultStore.open(directory: v.directory) }
    }

    @Test func folderAndFileSafety() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "funes-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fresh = base.appending(path: "FunesVault")
        _ = try VaultStore.open(directory: fresh)
        let dirMode = try FileManager.default.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: fresh.appending(path: "vault.sqlite").path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700 && fileMode == 0o600)

        let open = base.appending(path: "Open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(throws: VaultError.unsafeFile("Open")) { try VaultStore.open(directory: open) }

        let link = base.appending(path: "Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fresh)
        #expect(throws: VaultError.unsafeFile("Link")) { try VaultStore.open(directory: link) }

        let target = base.appending(path: "elsewhere.sqlite")
        FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let linkedFile = base.appending(path: "Linked")
        try FileManager.default.createDirectory(at: linkedFile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: linkedFile.appending(path: "vault.sqlite"), withDestinationURL: target)
        #expect(throws: VaultError.unsafeFile("vault.sqlite")) { try VaultStore.open(directory: linkedFile) }
    }

    // MARK: Invariants

    @Test func memoriesNeedValidCategories() throws {
        let v = try TestVault()
        #expect(throws: VaultError.noCategories) { try v.memory("No category", categories: []) }
        #expect(throws: VaultError.unknownCategory("hobbies")) { try v.memory("Unknown", categories: ["hobbies"]) }
        let tooMany = (0..<13).map { "c\($0)" }
        for key in tooMany { try v.store.createCategory(key: key, name: key) }
        #expect(throws: VaultError.invalidInput(field: "categories")) { try v.memory("Too many", categories: tooMany) }
        let m = try v.memory("Two", categories: ["health", "communication_style", "health"])
        #expect(m.categoryKeys == ["communication_style", "health"])
        #expect(try v.store.memory(id: m.id)?.categoryKeys == ["communication_style", "health"])
        #expect(throws: VaultError.noCategories) { try v.store.updateMemory(id: m.id, MemoryEdit(categoryKeys: []), now: t0) }
        #expect(try v.count("SELECT count(*) FROM memory") == 1)
    }

    @Test func lengthsAreCheckedInUnicodeScalars() throws {
        let v = try TestVault()
        #expect(throws: VaultError.invalidInput(field: "title")) { try v.memory("") }
        #expect(throws: VaultError.invalidInput(field: "title")) { try v.memory(String(repeating: "a", count: 181)) }
        #expect(throws: VaultError.invalidInput(field: "body")) { try v.memory("t", String(repeating: "b", count: 10_001)) }
        // 60 × "👩‍💻" is 60 characters but 180 scalars: the limit SQLite's CHECK enforces.
        try v.memory(String(repeating: "👩‍💻", count: 60))
        #expect(throws: VaultError.invalidInput(field: "title")) { try v.memory(String(repeating: "👩‍💻", count: 61)) }
        try v.memory("Long body", String(repeating: "é", count: 10_000))
    }

    @Test func theSecretScannerBlocksStoring() throws {
        let v = try TestVault()
        let key = "sk-" + String(repeating: "q", count: 30)
        #expect(throws: VaultError.secretLikeContent([.openAIStyleKey])) { try v.memory("Key", "my key is \(key)") }
        let m = try v.memory("Clean")
        #expect(throws: VaultError.secretLikeContent([.openAIStyleKey])) {
            try v.store.updateMemory(id: m.id, MemoryEdit(body: "now \(key)"), now: t0)
        }
        #expect(try v.store.memory(id: m.id)?.body == "Clean body")
        #expect(try v.count("SELECT count(*) FROM memory") == 1)
        #expect(try v.count("SELECT count(*) FROM memory_fts WHERE memory_fts MATCH 'key'") == 0)
    }

    @Test func sensitivityDefaultsToTheCategories() throws {
        let v = try TestVault()
        #expect(try v.memory("Plain", sensitivity: nil).sensitivity == .low)
        #expect(try v.memory("Meds", categories: ["personal_preferences", "health"], sensitivity: nil).sensitivity == .sensitive)
        #expect(try v.memory("Chosen", categories: ["finance"], sensitivity: .public).sensitivity == .public)
    }

    @Test func everyVersionedChangeBumpsTheVersionAndAddsProvenance() throws {
        let v = try TestVault()
        let m = try v.memory("Title", "Body")
        #expect(m.version == 1)
        let edited = try v.store.updateMemory(id: m.id, MemoryEdit(title: "New title", body: "New body", sensitivity: .internal),
                                              now: t0.plus(minutes: 1))
        #expect(edited.version == 2 && edited.updatedAt == t0.plus(minutes: 1))
        #expect(try v.store.updateMemory(id: m.id, MemoryEdit(title: "New title"), now: t0.plus(minutes: 2)).version == 2)
        #expect(try v.store.updateMemory(id: m.id, MemoryEdit(confidence: .some(0.9)), now: t0.plus(minutes: 2)).version == 2)
        #expect(try v.store.updateMemory(id: m.id, MemoryEdit(categoryKeys: ["legal"]), now: t0.plus(minutes: 3)).version == 3)
        #expect(try v.store.updateMemory(id: m.id, MemoryEdit(expiresAt: .some(t0.plus(days: 9))), now: t0.plus(minutes: 4)).version == 4)
        #expect(try v.store.updateMemory(id: m.id, MemoryEdit(kind: .goal), now: t0.plus(minutes: 5)).version == 5)
        #expect(try v.store.archiveMemory(id: m.id, now: t0.plus(minutes: 6)).version == 6)
        #expect(try v.store.restoreMemory(id: m.id, now: t0.plus(minutes: 7)).version == 7)
        let deleted = try v.store.deleteMemory(id: m.id, now: t0.plus(minutes: 8))
        #expect(deleted.version == 8 && deleted.status == .deleted && deleted.deletedAt == t0.plus(minutes: 8))
        #expect(throws: VaultError.notFound) { try v.store.updateMemory(id: m.id, MemoryEdit(title: "x"), now: t0) }
        #expect(try v.store.restoreMemory(id: m.id, now: t0.plus(minutes: 9)).deletedAt == nil)

        let history = try v.store.provenance(memoryID: m.id)
        #expect(history.map(\.event) == [.created, .edited, .edited, .edited, .edited, .edited, .archived, .restored, .deleted, .restored])
        #expect(history[1].fieldsChanged == ["title", "body", "sensitivity"])
        #expect(history[2].fieldsChanged == ["confidence"])
        #expect(history.allSatisfy { $0.actor == "user" })
    }

    @Test func provenanceHoldsNoText() throws {
        let v = try TestVault()
        let m = try v.memory("SENTINEL-TITLE", "SENTINEL-BODY")
        try v.store.updateMemory(id: m.id, MemoryEdit(title: "SENTINEL-2", body: "SENTINEL-3"), now: t0)
        let dump = try v.store.writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM provenance").description }
        #expect(!dump.contains("SENTINEL"))
    }

    @Test func statusTransitions() throws {
        let v = try TestVault()
        let m = try v.memory("A")
        #expect(throws: VaultError.invalidState) { try v.store.restoreMemory(id: m.id, now: t0) }
        try v.store.archiveMemory(id: m.id, now: t0)
        #expect(throws: VaultError.invalidState) { try v.store.archiveMemory(id: m.id, now: t0) }
        #expect(throws: VaultError.invalidState) { try v.store.purgeMemory(id: m.id) }
        try v.store.deleteMemory(id: m.id, now: t0)
        #expect(try v.store.memories(MemoryFilter(status: .recentlyDeleted), now: t0).map(\.id) == [m.id])
        #expect(try v.store.memories(now: t0).isEmpty)
        #expect(throws: VaultError.notFound) { try v.store.archiveMemory(id: UUID(), now: t0) }
    }

    @Test func purgeRemovesEverythingButDisclosureItems() throws {
        let v = try TestVault()
        let gone = try v.memory("Gone", "zebra crossing")
        let old = try v.memory("Old", "zebra stripes")
        let kept = try v.memory("Kept", "zebra fish")
        try v.store.writer.write { db in
            for m in [gone, old] {
                try db.execute(sql: "INSERT INTO embedding (memory_id, model_id, dims, vector, content_hash) VALUES (?, 'x', 1, x'00000000', 'h')",
                               arguments: [m.id.db])
            }
            try db.execute(sql: "INSERT INTO agent (id, name, agent_kind, created_at) VALUES ('a', 'A', 'other', ?)", arguments: [t0])
            try db.execute(sql: """
                INSERT INTO disclosure (id, agent_id, agent_revision, task_hash, task_length, retention, max_tokens, status, created_at)
                VALUES ('d', 'a', 1, 'h', 1, 'unknown', 100, 'delivered', ?)
                """, arguments: [t0])
            try db.execute(sql: """
                INSERT INTO disclosure_item (disclosure_id, memory_id, memory_version, category_key, sensitivity, estimated_tokens)
                VALUES ('d', ?, 1, 'personal_preferences', 1, 3)
                """, arguments: [gone.id.db])
        }
        try v.store.deleteMemory(id: gone.id, now: t0)
        try v.store.deleteMemory(id: old.id, now: t0.plus(days: -31))
        #expect(try v.store.purgeDeletedMemories(now: t0) == 1)
        #expect(try v.store.memory(id: old.id) == nil)
        try v.store.purgeMemory(id: gone.id)
        #expect(try v.count("SELECT count(*) FROM memory") == 1)
        #expect(try v.count("SELECT count(*) FROM memory_category") == 1)
        #expect(try v.count("SELECT count(*) FROM provenance WHERE memory_id != ?", [kept.id.db]) == 0)
        #expect(try v.count("SELECT count(*) FROM embedding") == 0)
        #expect(try v.count("SELECT count(*) FROM memory_fts WHERE memory_fts MATCH 'zebra'") == 1)
        #expect(try v.count("SELECT count(*) FROM disclosure_item WHERE memory_id = ?", [gone.id.db]) == 1)
    }

    // MARK: FTS

    @Test func ftsStaysInSync() throws {
        let v = try TestVault()
        func hits(_ q: String) throws -> Int { try v.count("SELECT count(*) FROM memory_fts WHERE memory_fts MATCH ?", [q]) }
        let m = try v.memory("Running shoes", "I run marathons in the mornings")
        #expect(try hits("marathon") == 1)   // porter stemming
        #expect(try hits("shoe") == 1)
        try v.store.updateMemory(id: m.id, MemoryEdit(title: "Cycling", body: "I cycle to work"), now: t0)
        #expect(try hits("marathon") == 0 && hits("shoe") == 0)
        #expect(try hits("cycling") == 1 && hits("work") == 1)
        try v.store.updateMemory(id: m.id, MemoryEdit(sensitivity: .internal), now: t0)
        #expect(try hits("cycling") == 1)
        try v.memory("Café", "Crème brûlée")
        #expect(try hits("creme") == 1 && hits("cafe") == 1)   // remove_diacritics
        try v.store.deleteMemory(id: m.id, now: t0)
        try v.store.purgeMemory(id: m.id)
        #expect(try hits("cycling") == 0)
        try v.store.writer.write { db in try db.execute(sql: "INSERT INTO memory_fts(memory_fts) VALUES ('integrity-check')") }
    }

    // MARK: Lists and filters

    @Test func filtersAndSort() throws {
        let v = try TestVault()
        let a = try v.memory("Alpha", categories: ["health"], kind: .preference, now: t0)
        let b = try v.memory("beta", categories: ["legal"], sensitivity: .secret, now: t0.plus(minutes: 1))
        let c = try v.memory("Gamma", expiresAt: t0.plus(minutes: 5), now: t0.plus(minutes: 2))
        let now = t0.plus(minutes: 10)
        #expect(try v.store.memories(now: now).map(\.id) == [b.id, a.id])
        #expect(try v.store.memories(MemoryFilter(status: .expired), now: now).map(\.id) == [c.id])
        #expect(try v.store.memories(MemoryFilter(status: .activeIncludingExpired, sort: .title), now: now).map(\.id) == [a.id, b.id, c.id])
        #expect(try v.store.memories(MemoryFilter(categoryKeys: ["health"]), now: now).map(\.id) == [a.id])
        #expect(try v.store.memories(MemoryFilter(kinds: [.preference]), now: now).map(\.id) == [a.id])
        #expect(try v.store.memories(MemoryFilter(sensitivities: [.secret]), now: now).map(\.id) == [b.id])
        #expect(try v.store.memories(MemoryFilter(sources: [.agentWrite]), now: now).isEmpty)
        #expect(try v.store.memories(MemoryFilter(sort: .created), now: now, limit: 1).map(\.id) == [b.id])
    }

    @Test func exactDuplicateHint() throws {
        let v = try TestVault()
        let m = try v.memory("Prefers  Tea", "Green tea,\nno sugar")
        #expect(try v.store.exactDuplicates(title: "prefers tea", body: "green  TEA, no sugar") == [m.id])
        #expect(try v.store.exactDuplicates(title: "prefers tea", body: "green tea, no sugar", excluding: m.id).isEmpty)
        #expect(try v.store.exactDuplicates(title: "prefers tea", body: "black tea").isEmpty)
    }

    // MARK: Categories

    @Test func customCategories() throws {
        let v = try TestVault()
        let c = try v.store.createCategory(key: "side_projects", name: "Side projects")
        #expect(c.sortOrder == 8 && !c.builtin)
        #expect(throws: VaultError.categoryExists) { try v.store.createCategory(key: "side_projects", name: "Again") }
        #expect(throws: VaultError.invalidInput(field: "key")) { try v.store.createCategory(key: "Side Projects", name: "x") }
        try v.store.renameCategory(key: "health", name: "Wellbeing")
        #expect(try v.store.categories().first { $0.key == "health" }?.name == "Wellbeing")
        #expect(throws: VaultError.builtinCategory) { try v.store.deleteCategory(key: "health", now: t0) }
        #expect(throws: VaultError.notFound) { try v.store.deleteCategory(key: "nope", now: t0) }
    }

    @Test func deletingACategoryMovesItsMemories() throws {
        let v = try TestVault()
        try v.store.createCategory(key: "garden", name: "Garden")
        let only = try v.memory("Roses", categories: ["garden"])
        let both = try v.memory("Tomatoes", categories: ["garden", "personal_preferences"])
        #expect(throws: VaultError.categoryInUse) { try v.store.deleteCategory(key: "garden", now: t0) }
        try v.store.deleteCategory(key: "garden", replacement: "personal_preferences", now: t0.plus(minutes: 1))
        #expect(try v.store.memory(id: only.id)?.categoryKeys == ["personal_preferences"])
        #expect(try v.store.memory(id: only.id)?.version == 2)
        #expect(try v.store.memory(id: both.id)?.categoryKeys == ["personal_preferences"])
        #expect(try !v.store.categories().contains { $0.key == "garden" })
    }

    @Test func deletingACategoryNeverWidensAgentAccess() throws {
        let v = try TestVault()
        try v.store.createCategory(key: "garden", name: "Garden")
        try v.store.createCategory(key: "pets", name: "Pets")
        let a1 = UUID(), a2 = UUID(), a3 = UUID()
        try v.store.writer.write { db in
            for (id, rows) in [(a1.db, [("garden", "allow")]), (a2.db, [("garden", "allow"), ("legal", "allow")]), (a3.db, [("garden", "deny")])] {
                try db.execute(sql: "INSERT INTO agent (id, name, agent_kind, created_at) VALUES (?, ?, 'other', ?)", arguments: [id, id, t0])
                for (key, mode) in rows {
                    try db.execute(sql: "INSERT INTO access_category VALUES (?, ?, ?)", arguments: [id, key, mode])
                }
            }
        }
        #expect(throws: VaultError.onlyAllowedCategory(agentIDs: [a1])) { try v.store.deleteCategory(key: "garden", now: t0) }
        try v.store.deleteCategory(key: "garden", replacement: "pets", now: t0)
        let rows = try v.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT agent_id, category_key, mode FROM access_category")
                .map { "\($0["agent_id"] as String) \($0["category_key"] as String) \($0["mode"] as String)" }
        }
        #expect(Set(rows) == ["\(a1.db) pets allow", "\(a2.db) legal allow", "\(a3.db) pets deny"])
        #expect(try v.count("SELECT count(*) FROM agent WHERE revision = 2") == 3)
    }

    // MARK: Backups

    @Test func onlineBackups() throws {
        let v = try TestVault()
        try v.memory("Backed up")
        let backups = v.directory.appending(path: "Backups")
        for i in 0..<9 { try v.store.dailyBackup(into: backups, now: t0.plus(days: Double(i))) }
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        #expect(names.count == 7)
        #expect(names.first == "vault-\(VaultStore.stamp(t0.plus(days: 2))).sqlite")
        let copy = try VaultStore(path: backups.appending(path: names.last!))
        #expect(try copy.memories(now: t0).map(\.title) == ["Backed up"])
    }
}
