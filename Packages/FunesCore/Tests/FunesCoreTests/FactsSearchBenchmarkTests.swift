import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 13b's latency gate on fixtures: search with links within FR-V-10's 150 ms at p95. The author's-vault row
/// (50 queries on the author's vault) is a private run with the author's go-ahead; this is its fixture stand-in:
///
/// - **Vault size of the author's:** the busy search fixture (368 memories, 30 people, the spike's r3 reads), its 44
///   queries plus the main set's 6 people queries; with bge-small when it's fetched. p95 over every run (3 rounds),
///   with the facts index warm (the app builds it after a change), and the cold build on its own.
/// - **10,000 memories:** `SnippetBenchmarkTests`' vault, every memory read, with people named in some; queries
///   naming them, warm.
///
/// Run alone, in release, as test.sh does outside CI: `FUNES_SEARCH_BENCHMARK=1 swift test -c release -Xswiftc
/// -enable-testing --package-path Packages/FunesCore --filter FactsSearchBenchmarkTests`.
@Suite(.serialized) struct FactsSearchBenchmarkTests {
    static let budget: Duration = .milliseconds(150)
    static let enabled = ProcessInfo.processInfo.environment["FUNES_SEARCH_BENCHMARK"] != nil

    static func p95(_ xs: [Duration]) -> Duration {
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
    }

    static func ms(_ d: Duration) -> String { String(format: "%.1f ms", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }

    @Test(.enabled(if: enabled, "FUNES_SEARCH_BENCHMARK=1, alone, in release"))
    func authorsVaultSizeWithLinksUnder150Milliseconds() async throws {
        let set = FactsSearchGateTests.sets[2]
        let (v, ids, texts) = try SearchGate.vault(SearchGate.spike(set.vault))
        try SearchGate.applyPeople(v, ids: ids, texts: texts, backfill: SearchGate.spike(set.backfill))
        var indexer: EmbeddingIndexer?
        if let dir = Fixtures.modelDirectory {
            let bge = try BundledBGEEmbedder(compiledModelURL: dir.appending(path: BundledBGEEmbedder.compiledModelName),
                                             vocabURL: dir.appending(path: "vocab.txt"))
            indexer = EmbeddingIndexer(store: v.store, provider: bge)
            _ = try await indexer!.embedPending()
        }
        let search = SearchService(store: v.store, indexer: indexer)
        search.facts = SearchGate.shipped
        let queries = try SearchGate.queries(SearchGate.spike(set.queries)).map(\.query)
            + SearchGate.queries(SearchGate.spike(FactsSearchGateTests.sets[0].queries)).filter { $0.set == "people" }.prefix(6).map(\.query)
        #expect(queries.count == 50)
        let clock = ContinuousClock()
        let cold = try await clock.measure { _ = try await search.vaultSearch(queries[0], filter: MemoryFilter(status: .active), now: t0) }
        var times: [Duration] = [], plainTimes: [Duration] = []
        let plain = SearchService(store: v.store, indexer: indexer)
        // Every run counts: p95 over all 150 searches (3 rounds of the 50), not each query's best.
        for _ in 0..<3 {
            for q in queries {
                times.append(try await clock.measure { _ = try await search.vaultSearch(q, filter: MemoryFilter(status: .active), now: t0) })
                plainTimes.append(try await clock.measure { _ = try await plain.vaultSearch(q, filter: MemoryFilter(status: .active), now: t0) })
            }
        }
        let p = Self.p95(times)
        print("368 memories, \(indexer == nil ? "keyword-only" : "bge-small"): with links p95 \(Self.ms(p)), "
                             + "max \(Self.ms(times.max()!)); plain p95 \(Self.ms(Self.p95(plainTimes))); first search with a cold index \(Self.ms(cold))")
        #expect(p < Self.budget)
        #expect(cold < .milliseconds(500), "a cold build: \(Self.ms(cold))")
    }

    @Test(.enabled(if: enabled, "FUNES_SEARCH_BENCHMARK=1, alone, in release"))
    func tenThousandMemoriesWithLinksUnder150Milliseconds() async throws {
        let v = try SnippetBenchmarkTests.fixture()
        let sib = FX.personPredicate { $0.lexicon.contains { $0.words.contains("sister") } }
        let names = ["Maria", "Elena", "Jordan", "Priya", "Tomás", "Lucía", "Erik", "Dana"]
        // Every memory read (a finished facts job each); 400 name someone, with a fact each (never a long body).
        let group = FX.registry.predicate(sib)!.callGroup
        let rows = try await v.store.writer.read { db in try String.fetchAll(db, sql: "SELECT id FROM memory ORDER BY seq") }
        try await v.store.writer.write { db in
            for (i, id) in rows.enumerated() {
                guard i % 25 == 1 else {
                    try db.execute(sql: """
                        INSERT INTO processing_job (id, subject, kind, state, memory_version, call_group, created_at, updated_at)
                        VALUES (?, ?, 'facts', 'done', 1, ?, ?, ?)
                        """, arguments: [UUID().db, id, group, t0, t0])
                    continue
                }
                let n = names[(i / 25) % names.count]
                try db.execute(sql: "UPDATE memory SET body = body || ? WHERE id = ?", arguments: [" \(n) is my sister.", id])
                let x = FactsExtraction(people: [ExtractedPerson(name: n, quote: n)],
                                        facts: [ExtractedFact(predicate: sib, name: n, label: "sister", quote: "\(n) is my sister")])
                let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [id]) ?? 1
                try FactStore.apply(db, memoryID: id, version: version, extraction: x, callGroup: group,
                                    registry: .bundled, uses: .everyDeclared(.bundled), now: t0)
            }
        }
        let search = SearchService(store: v.store, indexer: nil)
        var config = SearchGate.shipped
        config.measuredUses = .everyDeclared(.bundled)
        search.facts = config
        let clock = ContinuousClock()
        let cold = try await clock.measure { await search.prepareFacts(now: t0) }
        var times: [Duration] = []
        for _ in 0..<3 {
            for q in names.map({ "What does \($0) like?" }) + ["my sister's plans", "notes from my sister", "Maria and Elena"] {
                times.append(try await clock.measure { _ = try await search.vaultSearch(q, filter: MemoryFilter(status: .active), now: t0) })
            }
        }
        print("10,000 memories, keyword-only: with links p95 \(Self.ms(Self.p95(times))); index build \(Self.ms(cold))")
        #expect(Self.p95(times) < Self.budget)
    }
}
