import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 6.1.1–6.1.3: every suggestion action applies as itself, targets are version-checked, and
/// the v4 schema with trust (FR-I-02, FR-I-03, FR-S-06; domain model, Suggestion; storage §3).
@Suite struct PerActionApplyTests {
    static func make() throws -> (TestVault, SuggestionService, InMemoryActivityLog) {
        let v = try TestVault()
        let log = InMemoryActivityLog()
        return (v, SuggestionService(store: v.store, activity: log, pause: FunesPause()), log)
    }

    /// A pending suggestion with this action, as the tidy-up or extraction will store it.
    @discardableResult
    static func suggestion(_ v: TestVault, _ action: SuggestionAction, title: String = "Proposed", body: String = "Proposed body",
                           target: UUID? = nil, targets: [(UUID, SuggestionTarget.Role)] = [], groupID: UUID? = nil,
                           categories: [String] = ["personal_preferences"], sensitivity: Sensitivity? = nil,
                           origin: SuggestionOrigin = .consolidation) throws -> UUID {
        try v.store.writer.write { db in
            try SuggestionService.insertSuggestion(
                db, origin: origin, action: action,
                input: SuggestInput(title: title, body: body, categories: categories, targetMemoryID: target),
                categories: categories, sensitivity: sensitivity, targets: targets, groupID: groupID, now: t0)
        }
    }

    // MARK: Actions

    @Test func createSavesANewMemory() async throws {
        let (v, s, log) = try Self.make()
        let id = try Self.suggestion(v, .create, origin: .captureMac)
        let result = try await s.apply(suggestionID: id, now: t0)
        let m = try #require(try v.store.memory(id: result.memoryID))
        #expect(m.title == "Proposed" && m.source == .captureMac && result.memoryIDs == [m.id])
        #expect(try v.store.trust(memoryID: m.id) == .trusted)
        #expect(log.events.last?.event == "suggestion_applied" && log.events.last?.ids == [id, m.id])
        await #expect(throws: VaultError.unsupportedAction) {
            try await s.apply(suggestionID: try Self.suggestion(v, .create), mode: .replace, now: t0)
        }
    }

    @Test func updateReplacesByDefaultOrKeepsBoth() async throws {
        let (v, s, _) = try Self.make()
        let old = try v.memory("Old")
        let replace = try Self.suggestion(v, .update, title: "New", target: old.id)
        #expect(try await s.suggestion(id: replace)?.targetMemoryVersion == 1)
        let replaced = try await s.apply(suggestionID: replace, now: t0.plus(minutes: 1))
        #expect(replaced.memoryID == old.id && replaced.memoryIDs == [old.id])
        #expect(try v.store.memory(id: old.id)?.title == "New" && v.count("SELECT COUNT(*) FROM memory") == 1)

        let keep = try Self.suggestion(v, .update, title: "Another", target: old.id)
        let kept = try await s.apply(suggestionID: keep, mode: .keepBoth, now: t0)
        #expect(try kept.memoryID != old.id && v.store.memory(id: old.id)?.title == "New")
        await #expect(throws: VaultError.unsupportedAction) {
            try await s.apply(suggestionID: try Self.suggestion(v, .update, target: old.id), mode: .bothTrue, now: t0)
        }
    }

    /// The bug 6.1.1 fixes: an archive suggestion used to save a new memory.
    @Test func archiveArchivesTheTargetAndCreatesNothing() async throws {
        let (v, s, _) = try Self.make()
        let dup = try v.memory("Copy")
        let survivor = try v.memory("Original")
        let id = try Self.suggestion(v, .archive, title: dup.title, body: dup.body, target: dup.id, targets: [(survivor.id, .survivor)])
        let result = try await s.apply(suggestionID: id, now: t0.plus(minutes: 1))
        #expect(result.memoryID == dup.id && result.memoryIDs == [dup.id])
        #expect(try v.store.memory(id: dup.id)?.status == .archived && v.count("SELECT COUNT(*) FROM memory") == 2)
        let last = try #require(try v.store.provenance(memoryID: dup.id).last)
        #expect(last.event == .appliedFromSuggestion && last.relatedMemoryID == survivor.id)
        #expect(try await s.suggestion(id: id)?.resultMemoryID == dup.id)
    }

    @Test func archiveRefusesWhenTheSurvivorIsGone() async throws {
        let (v, s, _) = try Self.make()
        let dup = try v.memory("Copy")
        let survivor = try v.memory("Original")
        let id = try Self.suggestion(v, .archive, target: dup.id, targets: [(survivor.id, .survivor)])
        try v.store.deleteMemory(id: survivor.id, now: t0)
        await #expect(throws: VaultError.targetChanged) { try await s.apply(suggestionID: id, now: t0) }
        #expect(try v.store.memory(id: dup.id)?.status == .active)
        #expect(try await s.suggestion(id: id)?.status == .pending)
    }

    @Test func duplicateChangesNothing() async throws {
        let (v, s, _) = try Self.make()
        let existing = try v.memory("Saved")
        let id = try Self.suggestion(v, .duplicate, title: "Saved", target: existing.id)
        let result = try await s.apply(suggestionID: id, now: t0.plus(minutes: 1))
        #expect(result.memoryID == existing.id && result.memoryIDs.isEmpty)
        #expect(try v.count("SELECT COUNT(*) FROM memory") == 1 && v.store.memory(id: existing.id)?.version == 1)
        #expect(try await s.suggestion(id: id)?.status == .applied)
    }

    @Test func splitSavesThePiecesAndArchivesTheOriginal() async throws {
        let (v, s, _) = try Self.make()
        let original = try v.memory("Dump", "Allergic to peanuts. Lives in Lisbon.", categories: ["health"], sensitivity: .sensitive)
        let split = try Self.suggestion(v, .split, title: "Dump", target: original.id)
        try Self.suggestion(v, .create, title: "Peanut allergy", body: "Allergic to peanuts", groupID: split,
                            categories: ["health"], sensitivity: .low)
        let rejected = try Self.suggestion(v, .create, title: "Not this", groupID: split)
        try await s.reject(suggestionID: rejected, now: t0)
        try Self.suggestion(v, .create, title: "Lisbon", body: "Lives in Lisbon", groupID: split, categories: [])

        let result = try await s.apply(suggestionID: split, now: t0.plus(minutes: 1))
        let pieces = try v.store.memories(ids: Array(result.memoryIDs.dropLast()))
        #expect(pieces.map(\.title) == ["Peanut allergy", "Lisbon"] && result.memoryIDs.last == original.id)
        // Never below the original's sensitivity; no categories → the original's.
        #expect(pieces.allSatisfy { $0.sensitivity == .sensitive && $0.source == .tidyUp })
        #expect(pieces[1].categoryKeys == ["health"])
        #expect(try v.store.memory(id: original.id)?.status == .archived)
        #expect(try v.store.provenance(memoryID: pieces[0].id).last?.event == .splitFrom)
        #expect(try v.store.provenance(memoryID: pieces[0].id).last?.relatedMemoryID == original.id)
        #expect(try v.store.provenance(memoryID: original.id).filter { $0.event == .splitInto }.map(\.relatedMemoryID)
                == pieces.map(\.id))
        #expect(try await s.pieces(groupID: split).isEmpty)
        #expect(try await s.suggestion(id: rejected)?.status == .rejected)
    }

    @Test func mergeSavesOneMemoryAndArchivesTheSources() async throws {
        let (v, s, _) = try Self.make()
        let a = try v.memory("Coffee", "Drinks coffee black", sensitivity: .low)
        let b = try v.memory("Coffee mornings", "Coffee in the morning", sensitivity: .internal)
        let id = try Self.suggestion(v, .merge, title: "Coffee", body: "Drinks black coffee in the morning",
                                     targets: [(a.id, .source), (b.id, .source)], categories: [])
        #expect(try await s.targets(suggestionID: id).map(\.memoryID) == [a.id, b.id])
        let result = try await s.apply(suggestionID: id, now: t0.plus(minutes: 1))
        let merged = try #require(try v.store.memory(id: result.memoryID))
        #expect(merged.body == "Drinks black coffee in the morning" && merged.source == .tidyUp)
        #expect(merged.sensitivity == .internal && merged.categoryKeys == ["personal_preferences"])
        #expect(result.memoryIDs == [merged.id, a.id, b.id])
        #expect(try v.store.memories(ids: [a.id, b.id]).allSatisfy { $0.status == .archived })
        #expect(try v.store.provenance(memoryID: merged.id).filter { $0.event == .mergedFrom }.map(\.relatedMemoryID) == [a.id, b.id])
        #expect(try v.store.provenance(memoryID: a.id).last?.event == .mergedInto)
        #expect(try v.store.provenance(memoryID: a.id).last?.relatedMemoryID == merged.id)
    }

    @Test func conflictTakesTheUsersAnswer() async throws {
        let (v, s, _) = try Self.make()
        let a = try v.memory("Lives in Lisbon")
        let b = try v.memory("Lives in Porto")
        let pair: [(UUID, SuggestionTarget.Role)] = [(a.id, .target), (b.id, .target)]

        let unanswered = try Self.suggestion(v, .conflict, targets: pair)
        await #expect(throws: VaultError.unsupportedAction) { try await s.apply(suggestionID: unanswered, now: t0) }
        await #expect(throws: VaultError.unsupportedAction) {
            try await s.apply(suggestionID: unanswered, mode: .keep(UUID()), now: t0)
        }

        let both = try await s.apply(suggestionID: unanswered, mode: .bothTrue, now: t0)
        #expect(try both.memoryIDs.isEmpty && v.store.memories(ids: [a.id, b.id]).allSatisfy { $0.status == .active && $0.version == 1 })

        let edit = try Self.suggestion(v, .conflict, targets: pair)
        let kept = try await s.apply(suggestionID: edit, edits: SuggestionEdit(body: "Lisbon since 2025"), mode: .keep(a.id),
                                     now: t0.plus(minutes: 1))
        #expect(kept.memoryID == a.id && kept.memoryIDs == [a.id, b.id])
        #expect(try v.store.memory(id: a.id)?.body == "Lisbon since 2025" && v.store.memory(id: b.id)?.status == .archived)
    }

    @Test func unknownActionsAreRefused() async throws {
        let (v, s, _) = try Self.make()
        let id = try Self.suggestion(v, .unknown)
        await #expect(throws: VaultError.unsupportedAction) { try await s.apply(suggestionID: id, now: t0) }
    }

    // MARK: Version-checked targets (6.1.2)

    @Test func aChangedTargetIsRefusedUntilReviewedAgain() async throws {
        let (v, s, _) = try Self.make()
        let m = try v.memory("Editor")
        let id = try Self.suggestion(v, .update, title: "Uses Zed", target: m.id)
        try v.store.updateMemory(id: m.id, MemoryEdit(body: "Uses Vim now"), now: t0.plus(minutes: 1))
        let suggestion = try #require(try await s.suggestion(id: id))
        #expect(try await s.isStale(suggestion))
        await #expect(throws: VaultError.targetChanged) { try await s.apply(suggestionID: id, now: t0) }
        #expect(try v.store.memory(id: m.id)?.body == "Uses Vim now")
        // Keep both doesn't touch the target, so it doesn't need it unchanged.
        let keep = try Self.suggestion(v, .update, target: m.id)
        try v.store.updateMemory(id: m.id, MemoryEdit(title: "Editors"), now: t0.plus(minutes: 2))
        _ = try await s.apply(suggestionID: keep, mode: .keepBoth, now: t0)

        try await s.reviewAgain(suggestionID: id)
        #expect(try await s.isStale(try #require(try await s.suggestion(id: id))) == false)
        _ = try await s.apply(suggestionID: id, now: t0.plus(minutes: 3))
        #expect(try v.store.memory(id: m.id)?.title == "Uses Zed")
    }

    @Test func archivedOrDeletedTargetsAreRefusedAndCantBeReviewedAgain() async throws {
        let (v, s, _) = try Self.make()
        let m = try v.memory("Gone")
        let archive = try Self.suggestion(v, .archive, target: m.id)
        let merge = try Self.suggestion(v, .merge, targets: [(m.id, .source), (try v.memory("Other").id, .source)])
        try v.store.archiveMemory(id: m.id, now: t0)
        for id in [archive, merge] {
            await #expect(throws: VaultError.targetChanged) { try await s.apply(suggestionID: id, now: t0) }
            await #expect(throws: VaultError.targetChanged) { try await s.reviewAgain(suggestionID: id) }
        }
        try v.store.restoreMemory(id: m.id, now: t0)
        await #expect(throws: VaultError.targetChanged) { try await s.apply(suggestionID: archive, now: t0) }
        try await s.reviewAgain(suggestionID: archive)
        _ = try await s.apply(suggestionID: archive, now: t0)
    }

    /// A target deleted for good goes null in the suggestion (ON DELETE SET NULL): it's stale, and
    /// Review Again can't make it appliable (companion protocol §4.2).
    @Test func aPurgedTargetIsStaleAndCantBeReviewedAgain() async throws {
        let (v, s, _) = try Self.make()
        let m = try v.memory("Gone for good")
        let archive = try Self.suggestion(v, .archive, target: m.id)
        try v.store.deleteMemory(id: m.id, now: t0)
        try v.store.purgeMemory(id: m.id)
        let suggestion = try #require(try await s.suggestion(id: archive))
        #expect(suggestion.targetMemoryID == nil && suggestion.targetMemoryVersion == 1)
        #expect(try await s.isStale(suggestion))
        await #expect(throws: VaultError.targetChanged) { try await s.reviewAgain(suggestionID: archive) }
        await #expect(throws: VaultError.targetChanged) { try await s.apply(suggestionID: archive, now: t0) }
        // A new memory never had a target: not stale.
        let create = try #require(try await s.suggestion(id: try Self.suggestion(v, .create)))
        #expect(try await s.isStale(create) == false)
    }

    @Test func agentCorrectionsRecordTheTargetsVersion() async throws {
        let fx = try ServiceFixture()
        let s = SuggestionService(store: fx.store, activity: fx.activity, pause: fx.pause)
        try fx.setAccess { $0.operations = [.suggest] }
        try fx.store.updateMemory(id: fx.id("m1"), MemoryEdit(body: "Edited first"), now: fx.now)
        var input = SuggestInput(title: "Memory m1", body: "Corrected", categories: ["communication_style"], sensitivity: .low)
        input.targetMemoryID = fx.id("m1")
        let out = try await s.suggest(agentID: fx.agentID, input, now: fx.now)
        #expect(try await s.suggestion(id: out.suggestionID!)?.targetMemoryVersion == 2)
        try fx.store.updateMemory(id: fx.id("m1"), MemoryEdit(body: "Edited again"), now: fx.now)
        await #expect(throws: VaultError.targetChanged) { try await s.apply(suggestionID: out.suggestionID!, now: fx.now) }
    }

    /// The Mac's editor sends the version it showed, like the phone: a change made meanwhile isn't overwritten.
    @Test func theEditorsExpectedVersionIsChecked() throws {
        let v = try TestVault()
        let m = try v.memory("Shown")
        try v.store.updateMemory(id: m.id, MemoryEdit(body: "Changed on the phone"), actor: .device(UUID()), now: t0)
        #expect(throws: VaultError.versionConflict) {
            try v.store.updateMemory(id: m.id, MemoryEdit(title: "Edited on the Mac"), expectedVersion: m.version, now: t0)
        }
        #expect(throws: VaultError.versionConflict) { try v.store.archiveMemory(id: m.id, expectedVersion: m.version, now: t0) }
        #expect(try v.store.memory(id: m.id)?.title == "Shown")
        let saved = try v.store.updateMemory(id: m.id, MemoryEdit(title: "Edited on the Mac"), expectedVersion: 2, now: t0)
        #expect(saved.version == 3 && saved.body == "Changed on the phone")
    }

    // MARK: Schema v4 and trust (6.1.3)

    @Test func trustFollowsWhoWroteTheText() throws {
        let v = try TestVault()
        let agentID = UUID()
        try v.store.writer.write { db in
            try db.execute(sql: "INSERT INTO agent (id, name, agent_kind, created_at) VALUES (?, 'A', 'other', ?)", arguments: [agentID.db, t0])
        }
        let written = try v.store.createMemory(MemoryDraft(title: "Agent", body: "Saved directly", categoryKeys: ["personal_preferences"],
                                                           source: .agentWrite, sourceAgentID: agentID), actor: .agent(agentID), now: t0)
        #expect(try v.store.trust(memoryID: written.id) == .untrusted)
        #expect(try v.store.trust(memoryID: try v.memory("Typed").id) == .trusted)
        try v.store.updateMemory(id: written.id, MemoryEdit(body: "Checked by the user"), now: t0)
        #expect(try v.store.trust(memoryID: written.id) == .trusted)
    }

    /// Storage §3: a v0.2 (v3) vault migrates to v4 with a backup first; agent writes become
    /// untrusted, everything else trusted, and pending suggestions keep working without a version.
    @Test func migratesAVersion3Vault() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "funes-v3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "vault.sqlite")
        let typed = UUID(), written = UUID(), suggestion = UUID()
        do {
            let queue = try DatabaseQueue(path: file.path)
            try Schema.migrator.migrate(queue, upTo: "v3_device_approvals")
            try await queue.write { db in
                for (id, source) in [(typed, "manual"), (written, "agent_write")] {
                    try db.execute(sql: """
                        INSERT INTO memory (id, title, body, kind, sensitivity, status, source, created_at, updated_at, version)
                        VALUES (?, 'T', 'B', 'fact', 1, 'active', ?, ?, ?, 3)
                        """, arguments: [id.db, source, t0, t0])
                    try db.execute(sql: "INSERT INTO memory_category (memory_id, category_key) VALUES (?, 'personal_preferences')",
                                   arguments: [id.db])
                    try db.execute(sql: "INSERT INTO provenance (memory_id, at, event, actor) VALUES (?, ?, 'created', 'user')",
                                   arguments: [id.db, t0])
                }
                try db.execute(sql: """
                    INSERT INTO suggestion (id, origin, target_memory_id, action, title, body, category_keys, created_at, expires_after)
                    VALUES (?, 'agent', ?, 'update', 'New', 'New body', '["personal_preferences"]', ?, ?)
                    """, arguments: [suggestion.db, typed.db, t0, t0.plus(days: 30)])
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = try VaultStore.open(directory: directory)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Backups").path)
        #expect(backups.contains { $0.hasPrefix("pre-v4_memory_processing") })
        #expect(try store.trust(memoryID: typed) == .trusted && store.trust(memoryID: written) == .untrusted)
        #expect(try store.provenance(memoryID: typed).first?.relatedMemoryID == nil)
        let s = SuggestionService(store: store, activity: InMemoryActivityLog(), pause: FunesPause())
        let pending = try #require(try await s.suggestion(id: suggestion))
        #expect(pending.targetMemoryVersion == nil && pending.groupID == nil && !pending.outsideScope)
        _ = try await s.apply(suggestionID: suggestion, now: t0)
        #expect(try store.memory(id: typed)?.title == "New")
        #expect(try store.quickCheck())
    }
}
