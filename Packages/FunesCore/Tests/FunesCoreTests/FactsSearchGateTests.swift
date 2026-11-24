import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// Phase 13b's gate, "Search with links on" (the Phase 13 plan's acceptance table): people and work fixtures, Spike G
/// and the search benchmark, with bge-small and with a second index; 0 targets ranked worse, 0 out of the top 3, 0 out
/// of the top 10. Fixtures only, no model calls (the second index is Ollama's qwen3-embedding on this Mac).
///
/// - Always: keyword-only on the main set (a regression guard that needs no model).
/// - `FUNES_FACTS_GATES=1`: every set with bge-small; with Ollama running `qwen3-embedding:0.6b`, also with it as the
///   second index (calibrated, uncalibrated, and as if it were a cloud model, so the rest of the query only goes when
///   every match is sendable and documents above the cloud limit keep bge). Writes `spikes/people/results-13b/`.
@Suite(.serialized) struct FactsSearchGateTests {
    static let sets: [(name: String, vault: String, queries: String, backfill: String)] = [
        ("main", "fixtures/search-vault.json", "fixtures/search-queries.json", "results-search/backfill-r3.json"),
        ("astra", "fixtures/search-vault-astra.json", "fixtures/search-queries-astra.json", "results-search/backfill-astra-r3.json"),
        ("busy", "fixtures/search-vault-busy.json", "fixtures/search-queries-busy.json", "results-search/backfill-busy-r3.json"),
    ]
    static var full: Bool { ProcessInfo.processInfo.environment["FUNES_FACTS_GATES"] == "1" }
    static let now = SearchGate.date("2026-11-19")

    @Test func keywordOnlyMainSetLosesNoTarget() async throws {
        let s = Self.sets[0]
        let (v, ids, texts) = try SearchGate.vault(SearchGate.spike(s.vault))
        try SearchGate.applyPeople(v, ids: ids, texts: texts, backfill: SearchGate.spike(s.backfill))
        let search = SearchService(store: v.store, indexer: nil)
        let queries = try SearchGate.queries(SearchGate.spike(s.queries))
        let shipsLinks = try await v.store.writer.read { db in try SearchGate.shipped.uses(db) }.predicates(.linked).isEmpty == false
        for (arm, config) in [("shipped", SearchGate.shipped), ("every declared", SearchGate.everyDeclared)] {
            let (t, lines) = try await SearchGate.compare(search, facts: config, queries: queries, ids: ids, now: Self.now)
            #expect(t.passes, "\(arm): \(t)\n\(lines.joined(separator: "\n"))")
            // While nothing ships (13e.1's records await its gate runs), the shipped arm is plain search.
            if arm == "shipped", !shipsLinks { continue }
            #expect(t.matched > 0 && t.admitted > 0, "\(arm): the feature wasn't exercised: \(t)")
        }
    }

    enum Index: String, CaseIterable { case bge, qwen, qwenUncalibrated = "qwen-uncalibrated", qwenAsCloud = "qwen-as-cloud" }

    static func ollamaUp() async -> Bool {
        var req = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return false }
        return String(decoding: data, as: UTF8.self).contains("qwen3-embedding:0.6b")
    }

    func search(_ v: TestVault, _ index: Index) async throws -> SearchService? {
        let dir = try #require(Fixtures.modelDirectory)
        let bge = try BundledBGEEmbedder(compiledModelURL: dir.appending(path: BundledBGEEmbedder.compiledModelName),
                                         vocabURL: dir.appending(path: "vocab.txt"))
        let indexer = EmbeddingIndexer(store: v.store, provider: bge)
        _ = try await indexer.embedPending()
        let s = SearchService(store: v.store, indexer: indexer)
        guard index != .bge else { return s }
        guard await Self.ollamaUp() else { return nil }
        let info: EmbeddingModelInfo? = index == .qwenUncalibrated
            ? .uncalibrated(id: OpenAICompatibleEmbedder.modelID(provider: ProviderEndpoint.ollama().id, model: "qwen3-embedding:0.6b"),
                            dimensions: 1024) : nil
        let qwen = try OpenAICompatibleEmbedder(endpoint: .ollama(), model: "qwen3-embedding:0.6b", info: info, apiKey: nil)
        let provider: any EmbeddingProvider = index == .qwenAsCloud ? AsCloud(base: qwen) : qwen
        let second = ProviderEmbeddingIndexer(store: v.store, provider: provider, cloudLimit: .upTo(.internal))
        _ = try await second.embedPending()
        guard second.isComplete else { return nil }
        s.secondIndex = SecondIndex(indexer: second)
        return s
    }

    @Test(.enabled(if: full && Fixtures.modelAvailable, "FUNES_FACTS_GATES=1 and the embedding model"))
    func everySetWithEveryIndex() async throws {
        var report = ["# Phase 13b gate: search with links on", "",
                      "Fixtures only; learned facts from the spike's r3 reads through `FactStore.apply`; no model calls. "
                      + "Pass: 0 targets worse, 0 out of the top 3, 0 out of the top 10.", ""]
        var failures: [String] = []
        let work = ("work", "fixtures/work-vault.json", "fixtures/work-queries.json", "results-search/work-extract-fixture.jsonl")
        for s in Self.sets + [work] {
            let (v, ids, texts) = try SearchGate.vault(SearchGate.spike(s.1))
            if s.0 == "work" {
                try SearchGate.applyWork(v, ids: ids, jsonl: SearchGate.spike(s.3))
            } else {
                try SearchGate.applyPeople(v, ids: ids, texts: texts, backfill: SearchGate.spike(s.3))
            }
            let queries = try SearchGate.queries(SearchGate.spike(s.2))
            for index in Index.allCases {
                guard let search = try await search(v, index) else {
                    report.append("- \(s.0), \(index.rawValue): skipped (Ollama with qwen3-embedding:0.6b isn't running)")
                    continue
                }
                for (arm, config) in [("shipped uses", SearchGate.shipped), ("every declared use", SearchGate.everyDeclared)] {
                    let (t, lines) = try await SearchGate.compare(search, facts: config, queries: queries, ids: ids, now: Self.now)
                    report.append("## \(s.0) · \(index.rawValue) · \(arm)")
                    report.append("")
                    report.append("\(t.passes ? "PASS" : "FAIL"): \(t)")
                    report += lines
                    report.append("")
                    // The gate judges what ships (the shipped uses) on every set, and every declared use on the people
                    // sets; works at with every use on is reported (its linked and timeline uses have no record yet).
                    let judged = arm == "shipped uses" || s.0 != "work"
                    if !t.passes, judged { failures.append("\(s.0)/\(index.rawValue)/\(arm): \(t)") }
                }
            }
        }
        let out = SearchGate.spike("results-13b")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try report.joined(separator: "\n").write(to: out.appending(path: "search-gate.md"), atomically: true, encoding: .utf8)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}

/// The local model as if it were a cloud one: the guardrails apply (memories above the cloud limit keep bge-small) and
/// the rest of a query goes to it only when every match is sendable. Nothing leaves the Mac.
struct AsCloud: EmbeddingProvider {
    let base: any EmbeddingProvider
    var id: ProviderID { base.id }
    var locality: Locality { .cloud }
    var model: EmbeddingModelInfo { base.model }
    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] { try await base.embed(texts, as: role) }
}
