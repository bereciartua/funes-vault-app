import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Earlier versions of memories (ADR-0027): kept by every change, 90 days, at most 50 a memory.
@Suite struct RevisionStoreTests {
    @Test func everyVersionedChangeKeepsTheVersionItReplaced() async throws {
        let v = try TestVault()
        let agent = UUID()
        let m = try v.memory("Coffee", "Black")
        try v.store.updateMemory(id: m.id, MemoryEdit(body: "Black, no sugar"), now: t0.plus(minutes: 1))
        try v.store.updateMemory(id: m.id, MemoryEdit(sensitivity: .internal), actor: .agent(agent), now: t0.plus(minutes: 2))
        try v.store.archiveMemory(id: m.id, actor: .system, now: t0.plus(minutes: 3))
        try v.store.restoreMemory(id: m.id, now: t0.plus(minutes: 4))
        // Not versioned: no earlier version.
        try v.store.confirmMemory(id: m.id, now: t0.plus(minutes: 5))
        try v.store.updateMemory(id: m.id, MemoryEdit(confidence: 0.9), now: t0.plus(minutes: 6))
        try v.store.updateMemory(id: m.id, MemoryEdit(body: "Black, no sugar"), now: t0.plus(minutes: 7))

        let changes = try v.store.revisionChanges(memoryID: m.id)
        #expect(changes.map(\.version) == [1, 2, 3, 4])
        #expect(changes.map(\.actor) == ["user", "agent:\(agent.uuidString.lowercased())", "system", "user"])
        #expect(changes[0].before.body == "Black")
        #expect(changes[0].after?.body == "Black, no sugar")
        #expect(changes[1].before.sensitivity == .low && changes[1].after?.sensitivity == .internal)
        #expect(changes[2].after?.status == .archived)
        #expect(changes[3].after?.status == .active)  // the memory as it is now
        #expect(changes[0].at == t0.plus(minutes: 1))
    }

    @Test func turningThemOffDeletesThemAndKeepsNoMore() async throws {
        let v = try TestVault()
        let m = try v.memory("Editor", "Vim")
        try v.store.updateMemory(id: m.id, MemoryEdit(body: "Helix"), now: t0)
        #expect(try v.store.keepsEarlierVersions())
        try v.store.setKeepsEarlierVersions(false)
        #expect(try !v.store.keepsEarlierVersions())
        #expect(try v.count("SELECT COUNT(*) FROM memory_revision") == 0)
        try v.store.updateMemory(id: m.id, MemoryEdit(body: "Zed"), now: t0)
        #expect(try v.count("SELECT COUNT(*) FROM memory_revision") == 0)

        try v.store.setKeepsEarlierVersions(true)
        try v.store.updateMemory(id: m.id, MemoryEdit(body: "Emacs"), now: t0)
        let changes = try v.store.revisionChanges(memoryID: m.id)
        #expect(changes.map(\.before.body) == ["Zed"])
        #expect(changes.first?.after?.body == "Emacs")
    }

    @Test func aGapLeavesTheAfterStateUnknown() async throws {
        let v = try TestVault()
        let m = try v.memory("Editor", "Vim")
        try v.store.updateMemory(id: m.id, MemoryEdit(body: "Helix"), now: t0)
        try await v.store.writer.write { db in
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('keep_revisions', '0')")
        }
        try v.store.updateMemory(id: m.id, MemoryEdit(body: "Zed"), now: t0)  // version 2 isn't kept
        let changes = try v.store.revisionChanges(memoryID: m.id)
        #expect(changes.count == 1)
        #expect(changes[0].before.body == "Vim")
        #expect(changes[0].after == nil)
    }

    /// The daily job (storage §5): 90 days, and each memory's newest 50.
    @Test func cleanupKeepsNinetyDaysAndFiftyAMemory() async throws {
        let v = try TestVault()
        let busy = try v.memory("Busy", "0"), quiet = try v.memory("Quiet", "a")
        for i in 1...55 { try v.store.updateMemory(id: busy.id, MemoryEdit(body: "\(i)"), now: t0) }
        try v.store.updateMemory(id: quiet.id, MemoryEdit(body: "b"), now: t0.plus(days: 10))

        #expect(try await v.store.cleanUpEarlierVersions(now: t0) == 5)
        #expect(try v.store.revisionChanges(memoryID: busy.id).map(\.version) == Array(6...55))
        #expect(try await v.store.cleanUpEarlierVersions(now: t0.plus(days: 90)) == 50)
        #expect(try v.store.revisionChanges(memoryID: quiet.id).count == 1)
        #expect(try await v.store.cleanUpEarlierVersions(now: t0.plus(days: 100)) == 1)
    }

    @Test func forgottenAndPurgedWithTheMemoryAndNeverExported() async throws {
        let v = try TestVault()
        let kept = try v.memory("Kept", "Old kept text"), forgotten = try v.memory("Forgotten", "Old forgotten text")
        let gone = try v.memory("Gone", "Old gone text")
        for m in [kept, forgotten, gone] { try v.store.updateMemory(id: m.id, MemoryEdit(body: "New"), now: t0) }

        #expect(try v.store.forgetEarlierVersions(memoryID: forgotten.id) == 1)
        try v.store.deleteMemory(id: gone.id, now: t0)
        try v.store.purgeMemory(id: gone.id)
        #expect(try v.count("SELECT COUNT(*) FROM memory_revision") == 1)
        #expect(try v.store.revisionChanges(memoryID: kept.id).first?.before.body == "Old kept text")

        let data = try await ImportService(store: v.store, activity: InMemoryActivityLog()).export(includeArchived: true, now: t0)
        #expect(!String(decoding: data, as: UTF8.self).contains("Old kept text"))
    }
}
