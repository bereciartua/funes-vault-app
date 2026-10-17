import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Search mechanics with the deterministic FakeEmbedder (task 1.4). The benchmark against the real
/// model is SearchBenchmarkTests.
@Suite struct SearchTests {
    @Test func ftsQueryBuilding() {
        #expect(KeywordSearch.ftsQuery("Plan a week of dinners for me") == #""plan" OR "week" OR "dinners""#)
        #expect(KeywordSearch.ftsQuery("the and of") == nil)
        #expect(KeywordSearch.ftsQuery("") == nil)
        #expect(KeywordSearch.ftsQuery("pnp", prefix: true) == #""pnp" OR "pnp"*"#)
        #expect(KeywordSearch.ftsQuery("Vitest, vitest; \"quotes\" (x) AND OR NEAR", prefix: false)
            == #""vitest" OR "quotes" OR "near""#)
        #expect(KeywordSearch.terms("Café 2026 a b") == ["café", "2026"])
    }

    @Test func indexUpsertRemoveAndCosines() {
        let index = EmbeddingIndex(modelID: "m", dimensions: 3)
        let a = UUID(), b = UUID(), c = UUID()
        index.upsert(a, [1, 0, 0])
        index.upsert(b, [0, 2, 0])
        index.upsert(c, [1, 1, 0])
        var cos = index.cosines([1, 0, 0])
        #expect(cos[a] == 1 && cos[b] == 0 && abs(cos[c]! - 0.7071) < 0.001)
        index.remove(a)
        index.upsert(c, [0, 0, 5])
        cos = index.cosines([0, 0, 1])
        #expect(index.count == 2 && cos[a] == nil && cos[b] == 0 && cos[c] == 1)
        #expect(index.cosines([1, 0]).isEmpty)
        #expect(EmbeddingCodec.decode(EmbeddingCodec.encode([1.5, -2, 0.25])) == [1.5, -2, 0.25])
    }

    @Test func indexerEmbedsMissingAndStaleVectors() async throws {
        let v = try TestVault()
        let a = try v.memory("Tea", "Green tea")
        let b = try v.memory("Coffee", "Black coffee")
        let indexer = EmbeddingIndexer(store: v.store, provider: FakeEmbedder())
        #expect(try await indexer.embedPending() == 2)
        #expect(try await indexer.embedPending() == 0)
        try v.store.updateMemory(id: a.id, MemoryEdit(body: "Jasmine tea"), now: t0)
        try v.store.updateMemory(id: b.id, MemoryEdit(sensitivity: .internal), now: t0)  // not in the embedding text
        #expect(try await indexer.embedPending() == 1)
        try v.store.renameCategory(key: "personal_preferences", name: "Likes")         // category names are
        #expect(try await indexer.embedPending() == 2)
        try v.store.archiveMemory(id: b.id, now: t0)                                       // archived keep vectors
        try v.store.deleteMemory(id: a.id, now: t0)
        #expect(try await indexer.embedPending() == 0)
        #expect(try v.count("SELECT count(*) FROM embedding WHERE model_id = 'fake/hash-64' AND dims = 64") == 2)
        try v.store.purgeMemory(id: a.id)
        #expect(try v.count("SELECT count(*) FROM embedding") == 1)

        let reloaded = EmbeddingIndexer(store: v.store, provider: FakeEmbedder())
        try reloaded.loadIndex()
        #expect(reloaded.index.count == 1 && reloaded.index.contains(b.id))
    }

    @Test func indexerFollowsCommits() async throws {
        let v = try TestVault()
        let indexer = EmbeddingIndexer(store: v.store, provider: FakeEmbedder())
        let observation = indexer.startObserving()
        defer { observation.cancel() }
        let m = try v.memory("Observed", "watched memory")
        for _ in 0..<200 where !indexer.index.contains(m.id) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(indexer.index.contains(m.id))
    }

    @Test func keywordOnlyKeepsMatchesAboveTheFloorAndRanksTiesByRecency() async throws {
        let v = try TestVault()
        let older = try v.memory("Sailing club", "Treasurer of the sailing club", now: t0)
        let newer = try v.memory("Sailing club", "Treasurer of the sailing club", now: t0.plus(minutes: 5))
        try v.memory("Gardening", "Tomatoes and roses")
        let search = SearchService(store: v.store, indexer: nil)
        let hits = try await search.retrieve(task: "email the sailing club treasurer")
        #expect(hits.map(\.memoryID) == [newer.id, older.id])
        #expect(hits.allSatisfy { $0.semantic == 0 && $0.cosine == nil && $0.keyword == 1 })
        #expect(try await search.retrieve(task: "the of and").isEmpty)
    }

    @Test func retrievalPoolIsActiveIncludingExpiredAndNarrowedByCategories() async throws {
        let v = try TestVault()
        let active = try v.memory("Kayak", "kayak trips", categories: ["personal_preferences"])
        let expired = try v.memory("Kayak old", "kayak club", expiresAt: t0)
        let health = try v.memory("Kayak injury", "kayak shoulder", categories: ["health"])
        let archived = try v.memory("Kayak gone", "kayak archive")
        try v.store.archiveMemory(id: archived.id, now: t0)
        let deleted = try v.memory("Kayak deleted", "kayak deleted")
        try v.store.deleteMemory(id: deleted.id, now: t0)
        let search = SearchService(store: v.store, indexer: nil)
        #expect(Set(try await search.retrieve(task: "kayak").map(\.memoryID)) == [active.id, expired.id, health.id])
        #expect(try await search.retrieve(task: "kayak", categories: ["health"]).map(\.memoryID) == [health.id])
        #expect(try await search.retrieve(task: "kayak", categories: ["health", "nope"]).map(\.memoryID) == [health.id])
        #expect(try await search.retrieve(task: "kayak", categories: ["nope"]).isEmpty)
    }

    @Test func retrievalReturnsAtMost30() async throws {
        let v = try TestVault()
        for i in 0..<40 { try v.memory("Bike \(i)", "bike ride \(i)") }
        #expect(try await SearchService(store: v.store, indexer: nil).retrieve(task: "bike").count == 30)
        #expect(try await SearchService(store: v.store, indexer: nil).vaultSearch("bike", now: t0).count == 40)
    }

    @Test func hybridUsesMinMaxSemanticAndRawCosineThresholds() async throws {
        let v = try TestVault()
        let tea = try v.memory("Tea", "green tea jasmine tea")
        let coffee = try v.memory("Coffee", "black coffee espresso")
        let mixed = try v.memory("Drinks", "tea or coffee")
        let indexer = EmbeddingIndexer(store: v.store, provider: FakeEmbedder(retrievalThreshold: 0.3))
        try await indexer.embedPending()
        let hits = try await SearchService(store: v.store, indexer: indexer, keywordFloor: 0).retrieve(task: "jasmine green tea")
        #expect(hits.first?.memoryID == tea.id)
        #expect(hits.first?.semantic == 1)
        let byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.memoryID, $0) })
        for hit in hits { #expect(abs(hit.score - (0.3 * hit.keyword + 0.7 * hit.semantic)) < 1e-5) }
        // Coffee shares no words: no keyword match and a raw cosine under the threshold, so it's dropped.
        #expect(byID[coffee.id] == nil)
        #expect(byID[mixed.id] != nil)  // a weak keyword match, kept with no floor
        let floored = try await SearchService(store: v.store, indexer: indexer, keywordFloor: 0.9).retrieve(task: "jasmine green tea")
        #expect(!floored.contains { $0.memoryID == mixed.id })
    }

    final class FailingEmbedder: EmbeddingProvider {
        let id: ProviderID = "test.failing"
        let locality = Locality.onDevice
        let model = FakeEmbedder().model
        let calls = Mutex(0)
        let fail: Bool
        init(fail: Bool) { self.fail = fail }
        func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] {
            calls.withLock { $0 += 1 }
            if fail { throw URLError(.cannotLoadFromNetwork) }
            return try await FakeEmbedder().embed(texts, as: role)
        }
    }

    @Test func aFailingModelFallsBackToKeywords() async throws {
        let v = try TestVault()
        let m = try v.memory("Kayak", "kayak trips")
        let provider = FailingEmbedder(fail: true)
        let search = SearchService(store: v.store, indexer: EmbeddingIndexer(store: v.store, provider: provider))
        let hits = try await search.retrieve(task: "kayak")
        #expect(hits.map(\.memoryID) == [m.id] && hits[0].semantic == 0)
    }

    @Test func secretLikeQueriesSkipEmbedding() async throws {
        let v = try TestVault()
        try v.memory("Kayak", "kayak trips")
        let provider = FailingEmbedder(fail: false)
        let indexer = EmbeddingIndexer(store: v.store, provider: provider)
        try await indexer.embedPending()
        let before = provider.calls.withLock { $0 }
        let search = SearchService(store: v.store, indexer: indexer)
        _ = try await search.vaultSearch("kayak sk-" + String(repeating: "z", count: 24), now: t0)
        #expect(provider.calls.withLock { $0 } == before)
        _ = try await search.vaultSearch("kayak", now: t0)
        #expect(provider.calls.withLock { $0 } == before + 1)
    }

    @Test func vaultSearchFiltersFirstAndMatchesPrefixes() async throws {
        let v = try TestVault()
        let pnpm = try v.memory("Prefers pnpm", "use pnpm for packages", categories: ["software_development"])
        try v.memory("Health pnpm", "pnpm", categories: ["health"])
        let search = SearchService(store: v.store, indexer: nil)
        let filter = MemoryFilter(categoryKeys: ["software_development"])
        #expect(try await search.vaultSearch("pnp", filter: filter, now: t0).map(\.memoryID) == [pnpm.id])
        #expect(try await search.vaultSearch("  ", filter: filter, now: t0).map(\.memoryID) == [pnpm.id])
        #expect(try await search.vaultSearch("packages pn", now: t0).first?.memoryID == pnpm.id)
    }

    @Test func nearDuplicatesByCosine() async throws {
        let v = try TestVault()
        let tea = try v.memory("Tea", "green tea jasmine", kind: .fact)
        try v.memory("Coffee", "black coffee espresso")
        let indexer = EmbeddingIndexer(store: v.store, provider: FakeEmbedder())
        try await indexer.embedPending()
        let search = SearchService(store: v.store, indexer: indexer)
        #expect(try await search.nearDuplicates(title: "Tea", body: "green tea jasmine", kind: .fact,
                                                categoryNames: ["Personal preferences"]) == [tea.id])
        #expect(try await search.nearDuplicates(title: "Tea", body: "green tea jasmine", kind: .fact,
                                                categoryNames: ["Personal preferences"], excluding: tea.id).isEmpty)
        #expect(try await SearchService(store: v.store, indexer: nil).nearDuplicates(title: "Tea", body: "x", kind: .fact,
                                                                                    categoryNames: []).isEmpty)
    }

    @Test func missingModelFilesFailToLoad() {
        #expect(throws: BundledBGEEmbedder.LoadError.self) { try BundledBGEEmbedder(directory: URL(fileURLWithPath: "/nonexistent")) }
    }
}
