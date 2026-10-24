import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 6.1.6: the undo log (memory processing §5.7, §9.5; storage §5).
@Suite struct UndoLogTests {
    static func make() throws -> (TestVault, UndoLog, InMemoryActivityLog) {
        let v = try TestVault()
        let log = InMemoryActivityLog()
        return (v, UndoLog(store: v.store, activity: log), log)
    }

    /// An automatic edit of `id`, as auto-apply will make it.
    @discardableResult
    static func autoEdit(_ v: TestVault, _ id: UUID, body: String, at now: Date = t0) throws -> UUID {
        try v.store.writer.write { db in
            try UndoLog.record(db, action: "update", memoryIDs: [id], now: now) {
                try MemoryStore.update(db, id: id, MemoryEdit(body: body), actor: .system, now: now)
                return []
            }
        }
    }

    @Test func undoRestoresTheTextAndDeletesWhatWasSaved() async throws {
        let (v, undo, log) = try Self.make()
        let m = try v.memory("Coffee", "Black")
        let edit = try Self.autoEdit(v, m.id, body: "Black, no sugar")
        let saved = UUID()
        let save = try await v.store.writer.write { db in
            try UndoLog.record(db, action: "create", memoryIDs: [], now: t0) {
                try MemoryStore.insert(db, MemoryDraft(title: "Tea", body: "Green", categoryKeys: ["personal_preferences"],
                                                       trust: .untrusted), actor: .system, now: t0, id: saved)
                return [saved]
            }
        }
        #expect(try await undo.entries(now: t0).map(\.id) == [save, edit])
        #expect(try await undo.undo(entryID: edit, now: t0.plus(minutes: 1)) == [edit])
        #expect(try v.store.memory(id: m.id)?.body == "Black")
        #expect(try v.store.provenance(memoryID: m.id).last?.event == .undone)
        try await undo.undo(entryID: save, now: t0)
        #expect(try v.store.memory(id: saved)?.status == .deleted)  // Recently Deleted
        #expect(log.events.last?.event == "undone")
        await #expect(throws: VaultError.undoNotPossible) { try await undo.undo(entryID: edit, now: t0) }
        #expect(try await undo.entries(now: t0).isEmpty)
    }

    @Test func laterChangesAreUndoneTogetherOrNotAtAll() async throws {
        let (v, undo, _) = try Self.make()
        let m = try v.memory("Editor", "Vim")
        let first = try Self.autoEdit(v, m.id, body: "Helix")
        let second = try Self.autoEdit(v, m.id, body: "Zed", at: t0.plus(minutes: 1))
        await #expect(throws: VaultError.undoNeedsLater(1)) { try await undo.undo(entryID: first, now: t0) }
        #expect(try await undo.undo(entryID: first, includingLater: true, now: t0.plus(minutes: 2)) == [second, first])
        #expect(try v.store.memory(id: m.id)?.body == "Vim")

        // A change by the user since refuses, with nothing undone.
        let third = try Self.autoEdit(v, m.id, body: "Emacs")
        try v.store.updateMemory(id: m.id, MemoryEdit(title: "Editors"), now: t0)
        await #expect(throws: VaultError.undoNotPossible) { try await undo.undo(entryID: third, now: t0) }
        #expect(try v.store.memory(id: m.id)?.body == "Emacs")
    }

    @Test func aMergeIsUndoneByRestoringItsSources() async throws {
        let (v, undo, _) = try Self.make()
        let a = try v.memory("A"), b = try v.memory("B")
        let merged = UUID()
        let entry = try await v.store.writer.write { db in
            try UndoLog.record(db, action: "merge", memoryIDs: [a.id, b.id], now: t0) {
                try MemoryStore.insert(db, MemoryDraft(title: "AB", body: "Both", categoryKeys: ["personal_preferences"]),
                                       actor: .system, now: t0, id: merged)
                for id in [a.id, b.id] { try MemoryStore.setStatus(db, id: id, to: .archived, actor: .system, now: t0) }
                return [merged]
            }
        }
        try await undo.undo(entryID: entry, now: t0)
        #expect(try v.store.memories(ids: [a.id, b.id]).allSatisfy { $0.status == .active })
        #expect(try v.store.memory(id: merged)?.status == .archived)
    }

    /// Purged with its memories (daily purge, Delete Now); cleaned up after 30 days.
    @Test func purgedWithItsMemoriesAndAfter30Days() async throws {
        let (v, undo, _) = try Self.make()
        let kept = try v.memory("Kept"), gone = try v.memory("Gone"), old = try v.memory("Old")
        try Self.autoEdit(v, kept.id, body: "Kept, edited")
        try Self.autoEdit(v, gone.id, body: "Secret-ish old text")
        try Self.autoEdit(v, old.id, body: "Older text")
        try v.store.deleteMemory(id: gone.id, now: t0)
        try v.store.purgeMemory(id: gone.id)
        try v.store.deleteMemory(id: old.id, now: t0)
        _ = try v.store.purgeDeletedMemories(now: t0.plus(days: 31))
        #expect(try v.count("SELECT COUNT(*) FROM undo_entry") == 1)
        #expect(try v.count("SELECT COUNT(*) FROM undo_entry WHERE before_state LIKE '%Gone%' OR before_state LIKE '%Old%'") == 0)
        #expect(try await undo.cleanup(now: t0.plus(days: 30)) == 1)
        #expect(try v.count("SELECT COUNT(*) FROM undo_entry") == 0)
    }
}
