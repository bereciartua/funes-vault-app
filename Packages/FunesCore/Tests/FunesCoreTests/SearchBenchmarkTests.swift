import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// The Spike 2b benchmark as a recall regression (Phase 1 task 1.4, ADR-0016): 200 memories,
/// 30 agent tasks, raw and with agent keywords, through `SearchService.retrieve`.
///
/// Re-measured in FunesCore on 2026-10-16 (M1, macOS 27, the bundled int8 model on the CPU,
/// keyword floor 0.15). The floors are the exit criteria of phase-1-core.md; the measured values
/// are recorded in spec/plans/spike-results.md (Phase 1 re-measurement).
///
/// | Path | R@5 | R@30 | MRR | Floor (R@5) |
/// |---|---|---|---|---|
/// | hybrid, task + keywords | 0.939 | 0.989 | 0.967 | 0.92 |
/// | hybrid, raw task | 0.689 | 0.911 | 0.831 | 0.68 |
/// | keyword only, task + keywords | 0.828 | 0.978 | 0.896 | 0.82 |
///
/// `FUNES_SEARCH_SWEEP=1` prints the keyword-floor sweep used to choose
/// `SearchService.defaultKeywordFloor`, and the embedding times.
@Suite struct SearchBenchmarkTests {
    enum Baseline {
        static let hybridExpanded = 0.92
        static let hybridRaw = 0.68
        static let keywordExpanded = 0.82
        // MRR at or above the recorded baseline (testing strategy), with 0.01 of slack.
        static let hybridExpandedMRR = 0.96
        static let hybridRawMRR = 0.81
        static let keywordExpandedMRR = 0.89
    }

    struct Result { var r5 = 0.0, r30 = 0.0, mrr = 0.0, kept = 0.0 }

    static func measure(_ search: SearchService, ids: [String: UUID], expanded: Bool) async throws -> Result {
        let queries = try Fixtures.queries(expanded: expanded)
        let fixtureID = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
        var r = Result()
        for q in queries {
            let all = try await search.retrieveAll(task: q.query, keywords: q.keywords ?? [])
            let ranked = all.prefix(SearchService.retrievalLimit).map { fixtureID[$0.memoryID]! }
            let relevant = Set(q.relevant)
            r.r5 += Double(Set(ranked.prefix(5)).intersection(relevant).count) / Double(relevant.count)
            r.r30 += Double(Set(ranked).intersection(relevant).count) / Double(relevant.count)
            if let first = ranked.firstIndex(where: relevant.contains) { r.mrr += 1 / Double(first + 1) }
            r.kept += Double(all.count)
        }
        let n = Double(queries.count)
        return Result(r5: r.r5 / n, r30: r.r30 / n, mrr: r.mrr / n, kept: r.kept / n)
    }

    @Test func keywordOnlyRecall() async throws {
        let (v, ids) = try Fixtures.benchmarkVault()
        let search = SearchService(store: v.store, indexer: nil)
        let expanded = try await Self.measure(search, ids: ids, expanded: true)
        let raw = try await Self.measure(search, ids: ids, expanded: false)
        #expect(expanded.r5 >= Baseline.keywordExpanded, "keyword-only R@5 (expanded) \(expanded.r5)")
        #expect(expanded.mrr >= Baseline.keywordExpandedMRR, "keyword-only MRR (expanded) \(expanded.mrr)")
        Self.report("keyword-only expanded", expanded)
        Self.report("keyword-only raw", raw)
    }

    @Test(.enabled(if: Fixtures.modelAvailable, Fixtures.modelMissing))
    func hybridRecall() async throws {
        let (v, ids) = try Fixtures.benchmarkVault()
        let dir = try #require(Fixtures.modelDirectory)
        // FUNES_EMBEDDING_MODEL_FILE picks another compiled variant in the cache (the int8 experiment).
        let file = ProcessInfo.processInfo.environment["FUNES_EMBEDDING_MODEL_FILE"] ?? BundledBGEEmbedder.compiledModelName
        let embedder = try BundledBGEEmbedder(compiledModelURL: dir.appending(path: file), vocabURL: dir.appending(path: "vocab.txt"))
        let indexer = EmbeddingIndexer(store: v.store, provider: embedder)
        let start = ContinuousClock.now
        #expect(try await indexer.embedPending() == 200)
        let embedTime = ContinuousClock.now - start
        let search = SearchService(store: v.store, indexer: indexer)
        let expanded = try await Self.measure(search, ids: ids, expanded: true)
        let raw = try await Self.measure(search, ids: ids, expanded: false)
        #expect(expanded.r5 >= Baseline.hybridExpanded, "hybrid R@5 (expanded) \(expanded.r5)")
        #expect(raw.r5 >= Baseline.hybridRaw, "hybrid R@5 (raw) \(raw.r5)")
        #expect(expanded.mrr >= Baseline.hybridExpandedMRR && raw.mrr >= Baseline.hybridRawMRR,
                "hybrid MRR \(expanded.mrr) / \(raw.mrr)")
        Self.report("hybrid expanded", expanded)
        Self.report("hybrid raw", raw)

        if ProcessInfo.processInfo.environment["FUNES_SEARCH_SWEEP"] == "1" {
            var times: [Duration] = []
            for q in try Fixtures.queries(expanded: true) {
                let s = ContinuousClock.now
                _ = try await embedder.embed([([q.query] + (q.keywords ?? [])).joined(separator: " ")], as: .query)
                times.append(ContinuousClock.now - s)
            }
            print("\(file): 200 memories embedded in \(embedTime); query embed p50 \(times.sorted()[times.count / 2])")
            // Duplicate-hint threshold (memory processing §8): nearest-neighbour cosines between the
            // 200 distinct fixture memories, and between each memory and a light rewording of it.
            let fixtures = try Fixtures.memories()
            var nearest: [Float] = []
            for (a, fa) in fixtures.enumerated() {
                let q = try #require(try await embedder.embed([fa.title + "\n" + fa.body], as: .document).first)
                let cos = indexer.index.cosines(q)
                nearest.append(fixtures.indices.filter { $0 != a }.map { cos[ids[fixtures[$0].id]!] ?? -1 }.max()!)
            }
            nearest.sort()
            var reworded: [Float] = []
            for f in fixtures.prefix(50) {
                let docs = try await embedder.embed([f.title + "\n" + f.body, "Note: " + f.body.lowercased() + " Still true."], as: .document)
                reworded.append(zip(docs[0], docs[1]).map(*).reduce(0, +))
            }
            reworded.sort()
            print(String(format: "distinct nearest cosine: median %.3f, p99 %.3f, max %.3f; reworded: min %.3f, median %.3f",
                         nearest[100], nearest[197], nearest[199], reworded[0], reworded[25]))
            for floor: Float in [0, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50] {
                let h = SearchService(store: v.store, indexer: indexer, keywordFloor: floor)
                let k = SearchService(store: v.store, indexer: nil, keywordFloor: floor)
                let he = try await Self.measure(h, ids: ids, expanded: true), hr = try await Self.measure(h, ids: ids, expanded: false)
                let ke = try await Self.measure(k, ids: ids, expanded: true), kr = try await Self.measure(k, ids: ids, expanded: false)
                print(String(format: "| %.2f | %.3f / %.3f / %.1f | %.3f / %.3f / %.1f | %.3f / %.3f / %.1f | %.3f / %.3f / %.1f |",
                             floor, he.r5, he.r30, he.kept, hr.r5, hr.r30, hr.kept, ke.r5, ke.r30, ke.kept, kr.r5, kr.r30, kr.kept))
            }
        }
    }

    static func report(_ label: String, _ r: Result) {
        if ProcessInfo.processInfo.environment["FUNES_SEARCH_SWEEP"] == "1" {
            print(String(format: "%@: R@5 %.3f, R@30 %.3f, MRR %.3f, kept %.1f", label, r.r5, r.r30, r.mrr, r.kept))
        }
    }
}
