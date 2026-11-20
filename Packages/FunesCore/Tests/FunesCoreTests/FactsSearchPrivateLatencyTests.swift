import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// Phase 13b's latency row on the author's own vault ("Search latency with links": 50 queries, FR-V-10's 150 ms at
/// p95). The author runs it, never CI or an agent: `sh scripts/facts_search_latency.sh <queries.txt>` copies the vault
/// to a temporary folder, runs this in release on the copy, and deletes it. It prints timings only (p50, p95 and max,
/// with and without links, and the first search with a cold index), never a query, a memory, a title or a name.
@Suite(.serialized) struct FactsSearchPrivateLatencyTests {
    static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool { env["FUNES_FACTS_LATENCY_VAULT"] != nil && env["FUNES_FACTS_LATENCY_QUERIES"] != nil }

    static func ms(_ d: Duration) -> String {
        String(format: "%.1f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    static func percentile(_ xs: [Duration], _ p: Double) -> Duration {
        let s = xs.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count) * p).rounded(.up)) - 1))]
    }

    @Test(.enabled(if: enabled, "the author's own run: sh scripts/facts_search_latency.sh <queries.txt>"))
    func authorsVaultWithLinksUnder150Milliseconds() async throws {
        let copy = URL(fileURLWithPath: try #require(Self.env["FUNES_FACTS_LATENCY_VAULT"]))
        let queries = try String(contentsOfFile: try #require(Self.env["FUNES_FACTS_LATENCY_QUERIES"]), encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = queries.first else {
            Issue.record("the queries file is empty")
            return
        }
        let store = try VaultStore.open(directory: copy)
        let dir = try #require(Fixtures.modelDirectory, "the embedding model isn't fetched: sh scripts/fetch_embedding_model.sh")
        let bge = try BundledBGEEmbedder(compiledModelURL: dir.appending(path: BundledBGEEmbedder.compiledModelName),
                                         vocabURL: dir.appending(path: "vocab.txt"))
        let indexer = EmbeddingIndexer(store: store, provider: bge)
        try indexer.loadIndex()
        _ = try await indexer.embedPending()          // the copy only
        let aliases = try await ProfileService(store: store, activity: InMemoryActivityLog()).profile().factsAliases
        // As the app runs with Claude Haiku 5.5 through the Claude plan: the shipped records decide what's on.
        let haiku = FactsEngine(model: "claude-code/claude-haiku-5-5", adapter: "claude-code/1;effort=low")
        let config = FactsSearchConfig(engines: Dictionary(uniqueKeysWithValues: FactsRegistry.bundled.callGroups.keys.map { ($0, haiku) }),
                                       userAliases: aliases, cloudLimit: .upTo(.internal))
        let withLinks = SearchService(store: store, indexer: indexer)
        withLinks.facts = config
        let plain = SearchService(store: store, indexer: indexer)
        let clock = ContinuousClock()
        let filter = MemoryFilter(status: .active)
        let cold = try await clock.measure { _ = try await withLinks.vaultSearch(first, filter: filter, now: Date()) }
        var linked: [Duration] = [], unlinked: [Duration] = []
        for _ in 0..<3 {
            for q in queries {
                linked.append(try await clock.measure { _ = try await withLinks.vaultSearch(q, filter: filter, now: Date()) })
                unlinked.append(try await clock.measure { _ = try await plain.vaultSearch(q, filter: filter, now: Date()) })
            }
        }
        let p95 = Self.percentile(linked, 0.95)
        print("facts-latency: \(queries.count) queries × 3 runs")
        print("facts-latency: with links p50 \(Self.ms(Self.percentile(linked, 0.5))), p95 \(Self.ms(p95)), max \(Self.ms(linked.max()!))")
        print("facts-latency: plain p50 \(Self.ms(Self.percentile(unlinked, 0.5))), p95 \(Self.ms(Self.percentile(unlinked, 0.95))), "
              + "max \(Self.ms(unlinked.max()!))")
        print("facts-latency: first search with a cold index \(Self.ms(cold))")
        print("facts-latency: \(p95 < .milliseconds(150) ? "PASS" : "FAIL") (FR-V-10: 150 ms at p95)")
        #expect(p95 < .milliseconds(150), "p95 \(Self.ms(p95))")
    }
}
