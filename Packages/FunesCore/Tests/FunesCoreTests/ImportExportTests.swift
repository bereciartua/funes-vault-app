import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// Task 1.10: import parsers, preview, commit and export (FR-X-01..06, memory processing §7).
@Suite struct ImportExportTests {
    static func fixture(_ name: String) throws -> Data {
        let parts = name.split(separator: ".")
        let url = try #require(Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]),
                                                 subdirectory: "fixtures/import"))
        return try Data(contentsOf: url)
    }

    // MARK: Parsers

    @Test func chatGPTExportsInEveryShape() throws {
        #expect(try ImportParser.chatGPT(Self.fixture("chatgpt-strings.json")).map(\.body) == [
            "Prefers concise answers with the conclusion first.", "Is learning Portuguese for a trip to Porto.",
        ])
        let objects = try ImportParser.chatGPT(Self.fixture("chatgpt-objects.json"))
        #expect(objects.map(\.body) == ["Uses pnpm and Vitest in TypeScript projects.", "Has a peanut allergy.",
                                        "Works at a small design studio in Lisbon.", "Likes jazz on Sunday mornings."])
        #expect(objects[0].createdAt == Date(timeIntervalSince1970: 1_741_083_630))
        #expect(objects[1].createdAt == Date(timeIntervalSince1970: 1_741_083_630))
        #expect(objects[2].createdAt == nil && objects[3].createdAt != nil)
        #expect(try ImportParser.chatGPT(Self.fixture("chatgpt-wrapped.json")).map(\.title) == [
            "Prefers British spelling.", "Runs every Tuesday.",
        ])
        #expect(throws: ImportError.unreadable) { try ImportParser.chatGPT(Data("not json".utf8)) }
        #expect(throws: ImportError.unsupportedFormat) { try ImportParser.chatGPT(Data(#"[{"x": 1}]"#.utf8)) }
        #expect(try ImportParser.chatGPT(Data("[]".utf8)).isEmpty)
    }

    @Test func claudePaste() throws {
        let text = String(decoding: try Self.fixture("claude-paste.txt"), as: UTF8.self)
        #expect(ImportParser.claude(text).map(\.body) == [
            "Prefers short answers", "Uses Swift 6 with strict concurrency", "Keeps a vegetarian diet",
            "Lives in Buenos Aires", "Has two cats", "Plain line without a bullet",
        ])
    }

    @Test func markdownHeadingsMapToCategories() throws {
        let text = String(decoding: try Self.fixture("notes.md"), as: UTF8.self)
        let items = ImportParser.markdown(text, categories: MemoryCategory.builtins)
        #expect(items.map(\.body) == ["Squash commits before merging.", "Use pnpm, never npm.",
                                      "Allergic to penicillin. Mention it to any doctor before a prescription.",
                                      "Plays chess on weekends."])
        #expect(items.map(\.categoryKeys) == [["software_development"], ["software_development"], ["health"], []])
        #expect(items[3].unmatchedHeading == "Hobbies" && items[0].unmatchedHeading == nil)
    }

    @Test func funesExportFiles() throws {
        let export = try ImportParser.funesExport(Self.fixture("funes-export.json"))
        #expect(export.categories.map(\.key) == ["communication_style", "garden"] && export.memories.count == 2)
        #expect(export.memories[1].status == .archived && export.memories[1].expiresAt != nil)
        #expect(throws: ImportError.unsupportedFormat) {
            try ImportParser.funesExport(Data(#"{"format": "other.v9", "exportedAt": "2026-10-01T12:00:00Z", "categories": [], "memories": []}"#.utf8))
        }
    }

    // MARK: Preview and commit

    @Test func previewCountsDuplicatesBlocksAndLongItems() async throws {
        let v = try TestVault()
        let existing = try v.memory("Prefers tea", "Green tea, no sugar")
        let service = ImportService(store: v.store, activity: InMemoryActivityLog())
        let items = [
            ImportItem(title: "Prefers Tea", body: "green tea,  no sugar"),
            ImportItem(title: "New", body: "A new fact"),
            ImportItem(title: "New", body: "a new  FACT"),
            ImportItem(title: "Key", body: "token ghp_" + String(repeating: "x", count: 30)),
            ImportItem(title: "Long", body: String(repeating: "w", count: 10_500)),
        ]
        let p = try await service.preview(items, source: .claude)
        #expect(p.entries.map(\.status) == [.duplicate(of: existing.id), .ready, .duplicate(of: nil), .blocked([.githubToken]), .tooLong])
        #expect(p.total == 5 && p.duplicates == 2 && p.blocked == 1 && p.tooLong == 1)
        let split = p.resolvingLongItems(.split)
        #expect(split.count == 6 && split[4].title == "Long (1/2)" && split[5].body.unicodeScalars.count == 500)
        let truncated = p.resolvingLongItems(.truncate)
        #expect(truncated.count == 5 && truncated[4].body.unicodeScalars.count == 10_000)
    }

    @Test func commitCreatesSuggestionsWithAnImportRun() async throws {
        let v = try TestVault()
        let log = InMemoryActivityLog()
        let service = ImportService(store: v.store, activity: log)
        let items = try ImportParser.chatGPT(Self.fixture("chatgpt-objects.json"))
            + [ImportItem(title: "Key", body: "AKIA" + String(repeating: "Z", count: 16))]
        let result = try await service.commit(try await service.preview(items, source: .chatgpt), now: t0)
        #expect(result.suggestionIDs.count == 4 && result.memoryIDs.isEmpty && result.skipped == 1)
        let suggestions = SuggestionService(store: v.store, activity: log, pause: FunesPause())
        let first = try #require(try await suggestions.suggestion(id: result.suggestionIDs[0]))
        #expect(first.origin == .import && first.importRunID == result.importRunID && first.categoryKeys == ["software_development"])
        let allergy = try #require(try await suggestions.suggestion(id: result.suggestionIDs[1]))
        #expect(allergy.categoryKeys == ["health"] && allergy.sensitivity == .sensitive)
        #expect(try v.count("SELECT item_count FROM import_run") == 5 && v.count("SELECT blocked FROM import_run") == 1)
        #expect(try v.count("SELECT count(*) FROM suggestion WHERE body LIKE 'AKIA%'") == 0)
        // Applying keeps the import as the source.
        let applied = try await suggestions.apply(suggestionID: result.suggestionIDs[0], now: t0)
        let m = try #require(try v.store.memory(id: applied.memoryID))
        #expect(m.source == .importChatGPT)
        #expect(try v.store.provenance(memoryID: m.id).first?.actor == "import:\(result.importRunID.db)")
        // Imports never create agents or access.
        #expect(try v.count("SELECT count(*) FROM agent") == 0 && v.count("SELECT count(*) FROM access") == 0)
    }

    /// PR #1 review: preview entries are editable, so commit rescans what it stores.
    @Test func commitRescansEditedPreviews() async throws {
        let v = try TestVault()
        let service = ImportService(store: v.store, activity: InMemoryActivityLog())
        var preview = try await service.preview([ImportItem(title: "Note", body: "Prefers short emails"),
                                                 ImportItem(title: "Other", body: "Likes hiking")], source: .markdown)
        #expect(preview.entries.map(\.status) == [.ready, .ready])
        preview.entries[0].item.body = "password=abcdefghijklmnopqrstuv"
        #expect(!SecretScanner.scan([preview.entries[0].item.body]).isEmpty)
        preview.entries[1].item.title = String(repeating: "t", count: 181)
        let result = try await service.commit(preview, now: t0)
        #expect(result.suggestionIDs.isEmpty && result.skipped == 2)
        #expect(try v.count("SELECT count(*) FROM suggestion") == 0)
        #expect(try v.count("SELECT blocked FROM import_run") == 1)
    }

    @Test func activeMemoriesOnlyFromAFunesExport() async throws {
        let v = try TestVault()
        let service = ImportService(store: v.store, activity: InMemoryActivityLog())
        let p = try await service.preview([ImportItem(title: "t", body: "b")], source: .markdown)
        await #expect(throws: VaultError.invalidInput(field: "as_memories")) { try await service.commit(p, asMemories: true, now: t0) }
    }

    // MARK: Export

    @Test func exportRoundTripsIntoAFreshVault() async throws {
        let v = try TestVault()
        try v.store.createCategory(key: "garden", name: "Garden", description: "Plants")
        let a = try v.memory("No emojis", "Don't use emojis.", categories: ["communication_style"], kind: .instruction)
        let b = try v.memory("Tomatoes", "Plant tomatoes in October.", categories: ["garden"], expiresAt: t0.plus(days: 90))
        let archived = try v.memory("Old flat", "Lived on Rua X.")
        try v.store.archiveMemory(id: archived.id, now: t0)
        let deleted = try v.memory("Gone", "Deleted thing.")
        try v.store.deleteMemory(id: deleted.id, now: t0)

        let service = ImportService(store: v.store, activity: InMemoryActivityLog())
        let data = try await service.export(now: t0)
        let export = try ImportParser.funesExport(data)
        #expect(Set(export.memories.map(\.title)) == ["No emojis", "Tomatoes"])
        #expect(try ImportParser.funesExport(await service.export(includeArchived: true, now: t0)).memories.count == 3)
        #expect(export.categories.contains { $0.key == "garden" && $0.description == "Plants" })

        let fresh = try TestVault()
        let importer = ImportService(store: fresh.store, activity: InMemoryActivityLog())
        let preview = try await importer.preview(funesExport: export)
        #expect(preview.newCategories.map(\.key) == ["garden"])
        let result = try await importer.commit(preview, asMemories: true, now: t0)
        let restored = try fresh.store.memories(ids: result.memoryIDs)
        #expect(Set(restored.map(\.title)) == ["No emojis", "Tomatoes"])
        let tomatoes = try #require(restored.first { $0.title == "Tomatoes" })
        #expect(tomatoes.categoryKeys == ["garden"] && tomatoes.expiresAt == b.expiresAt && tomatoes.source == .importFunes)
        #expect(restored.first { $0.title == "No emojis" }?.kind == a.kind)
        // Importing the same file again finds the duplicates.
        #expect(try await importer.preview(funesExport: export).duplicates == 2)
    }

    /// Task 6.1.8: a restore keeps status and split and merge links, marks memories reconciled,
    /// and the export never carries the undo log.
    @Test func restoreKeepsStatusLinksAndReconciles() async throws {
        let v = try TestVault()
        let original = try v.memory("Dump", "Peanuts. Lisbon.")
        let piece = try v.memory("Peanuts", "Allergic to peanuts")
        try await v.store.writer.write { db in
            try MemoryStore.appendProvenance(db, memoryID: piece.id, event: .splitFrom, actor: .user, at: t0, relatedMemoryID: original.id)
            try MemoryStore.appendProvenance(db, memoryID: original.id, event: .splitInto, actor: .user, at: t0, relatedMemoryID: piece.id)
            try MemoryStore.setStatus(db, id: original.id, to: .archived, actor: .user, now: t0)
            try UndoLog.record(db, action: "update", memoryIDs: [piece.id], now: t0) {
                try MemoryStore.update(db, id: piece.id, MemoryEdit(title: "Peanut allergy"), actor: .system, now: t0)
                return []
            }
        }
        let service = ImportService(store: v.store, activity: InMemoryActivityLog())
        let data = try await service.export(includeArchived: true, now: t0)
        #expect(!String(decoding: data, as: UTF8.self).contains("before_state"))
        let export = try ImportParser.funesExport(data)
        #expect(export.memories.first { $0.id == piece.id }?.links == [FunesExport.Link(event: .splitFrom, memoryId: original.id)])

        let fresh = try TestVault()
        let importer = ImportService(store: fresh.store, activity: InMemoryActivityLog())
        let result = try await importer.commit(try await importer.preview(funesExport: export), asMemories: true, now: t0)
        #expect(Set(result.memoryIDs) == [original.id, piece.id])
        #expect(try fresh.store.memory(id: original.id)?.status == .archived)
        #expect(try fresh.store.provenance(memoryID: piece.id).last?.event == .splitFrom)
        #expect(try fresh.store.provenance(memoryID: piece.id).last?.relatedMemoryID == original.id)
        #expect(try fresh.count("SELECT COUNT(*) FROM memory WHERE reconciled_version = version") == 2)
        #expect(try fresh.count("SELECT COUNT(*) FROM undo_entry") == 0)
    }

    @Test func exportsNeverContainKeysAgentsOrDevices() async throws {
        let v = try TestVault()
        try v.memory("Fact", "A fact")
        let agents = AgentService(store: v.store, keys: InMemoryAgentKeyStore(), activity: InMemoryActivityLog())
        let (_, key) = try await agents.create(name: "SENTINEL-AGENT", kind: .cursor, access: Access.Preset.readLowAskFirst.access, now: t0)
        _ = try await DeviceService(store: v.store, activity: InMemoryActivityLog())
            .register(name: "SENTINEL-PHONE", model: "iPhone", signingPublicKey: Data([1]), hpkePublicKey: Data([2]), now: t0)
        let text = String(decoding: try await ImportService(store: v.store, activity: InMemoryActivityLog()).export(now: t0), as: UTF8.self)
        #expect(!text.contains(key.plaintext) && !text.contains("fns_mcp") && !text.contains("SENTINEL"))
        #expect(!text.contains("access") && !text.contains("agent") && text.contains("funesvault.export.v1"))
    }
}
