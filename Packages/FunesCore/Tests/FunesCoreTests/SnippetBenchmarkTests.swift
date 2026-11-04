import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// FR-V-17's acceptance: vault search with snippets within FR-V-10's 150 ms on a 10,000-memory
/// vault. The vault is the Spike 2 benchmark's 200 memories, 50 times over with a number each, every
/// tenth body lengthened to 2,000–10,000 characters; the 30 benchmark queries, as typed (prefix
/// matching on the last word), keyword-only (the bundled model adds about 5 ms a search: Spike 2b).
/// Two paths: the iPhone's page (the search, the first 30 memories and their snippets) and the
/// Vault's list (the search, every hit read, the first 50 snippets); one `highlight()` query each.
/// The slowest of the 30 queries must be under budget. Wall-clock, the best of 5.
///
/// The budget is the shipped app's, so it runs in release, alone, with `FUNES_SEARCH_BENCHMARK=1`,
/// as test.sh does outside CI (see OverviewBenchmarkTests for why alone). Measured on the author's
/// M1 (2026-10-29), release: iPhone page 50 ms, 23 ms of it snippets (q20, 1,085 hits); Vault list
/// 86 ms, 26 ms of it snippets (q08, 2,274 hits). A debug build takes 85 and 175 ms: most of the
/// Vault's is reading every hit, as it did before snippets.
@Suite struct SnippetBenchmarkTests {
    static let budget: Duration = .milliseconds(150)

    static func fixture() throws -> TestVault {
        let vault = try TestVault()
        let memories = try Fixtures.memories()
        try vault.store.writer.write { db in
            for i in 0..<10_000 {
                let m = memories[i % memories.count]
                var body = m.body + " (\(i))"
                if i % 10 == 0 {
                    let extra = 2_000 + (i * 37) % 8_000
                    while body.count < extra { body += " " + memories[(i + body.count) % memories.count].body }
                    body = String(body.prefix(10_000))
                }
                try OverviewSeed(db: db).memory("\(m.title) \(i)", body: body, source: .manual, at: t0.addingTimeInterval(-Double(i) * 600),
                                                kind: MemoryKind(rawValue: m.kind) ?? .fact, categories: m.categories)
            }
        }
        return vault
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUNES_SEARCH_BENCHMARK"] != nil,
                   "Run alone, in release: FUNES_SEARCH_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing --package-path Packages/FunesCore --filter SnippetBenchmarkTests"))
    func searchWithSnippetsUnder150Milliseconds() async throws {
        let vault = try Self.fixture()
        #expect(try vault.count("SELECT COUNT(*) FROM memory") == 10_000)
        let search = SearchService(store: vault.store, indexer: nil)
        let clock = ContinuousClock()
        let ms = Duration.UnitsFormatStyle.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))
        // The iPhone's page: the first 30 memories and their snippets. The Vault's list: every
        // hit read (it lists them all) and the first 50 snippets, as `VaultModel.load` does.
        for (label, read, snippets) in [("iPhone page", 30, 30), ("Vault list", Int.max, 50)] {
            var slowest = (Duration.zero, Duration.zero, "", 0)
            for q in try Fixtures.queries(expanded: false) {
                var best = (total: Duration.seconds(10), snippets: Duration.zero, hits: 0)
                for _ in 0..<5 {
                    var snippetTime = Duration.zero, count = 0
                    let total = try await clock.measure {
                        let hits = try await search.vaultSearch(q.query, now: t0)
                        count = hits.count
                        let listed = try vault.store.memories(ids: hits.prefix(read).map(\.memoryID))
                        let page = listed.prefix(snippets)
                        let start = clock.now
                        let matches = try await search.bodyMatches(q.query, ids: page.map(\.id))
                        for m in page {
                            let snippet = matches[m.id]?.snippet() ?? BodyMatches.plainSnippet(m.body)
                            #expect(snippet.text.count <= 160)
                        }
                        snippetTime = clock.now - start
                    }
                    if total < best.total { best = (total, snippetTime, count) }
                }
                if best.total > slowest.0 { slowest = (best.total, best.snippets, q.id, best.hits) }
            }
            print("search with snippets, \(label), slowest query \(slowest.2) (\(slowest.3) hits): "
                  + "\(slowest.0.formatted(ms)) (snippets \(slowest.1.formatted(ms)))")
            #expect(slowest.0 < Self.budget, "\(label): query \(slowest.2) took \(slowest.0)")
        }
    }
}
