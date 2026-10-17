// Spike 2 benchmark: FTS5 BM25 vs Apple NaturalLanguage embeddings vs hybrids, plus the
// Foundation Models query-expansion fallback. Results: spec/plans/spike-results.md.
// Usage: swift run -c release search-spike [fixturesDir] [bigCorpusSize]   (DUMP=1 for per-query detail)
import Foundation

let args = CommandLine.arguments
let fixturesDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "../../Packages/FunesCore/Tests/FunesCoreTests/fixtures")
let bigN = args.count > 2 ? Int(args[2])! : 10_000

// Spike 2b (open embedding models) lives in Bench2b.swift.
if ProcessInfo.processInfo.environment["MODE"] == "2b" {
    try await runSpike2b(fixturesDir: fixturesDir, bigN: bigN)
    exit(0)
}
if ProcessInfo.processInfo.environment["MODE"] == "coreml" {
    try await runCoreMLBench()
    exit(0)
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }  // ms
func f(_ x: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", x) }
func pct(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

let (memories, queries) = try loadFixtures(dir: fixturesDir)
let base = memories.map { Doc(id: $0.id, sourceId: nil, title: $0.title, body: $0.body, kind: $0.kind, categories: $0.categories) }
let big = synthesize(from: base, total: bigN)
print("# Spike 2 search benchmark\n")
print("Date: \(ISO8601DateFormatter().string(from: Date()))")
print("Host: \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.processorCount) cores, \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
print("Corpus: \(base.count) fixture memories, \(queries.count) queries; big corpus \(big.count) (\(big.filter { $0.sourceId != nil }.count) paraphrases, \(big.count - base.count - big.filter { $0.sourceId != nil }.count) mixtures)\n")

// MARK: Query expansion (Foundation Models)

var expansions: [[String]]? = nil
var expansionMs: [Double] = []
var expansionFailures = 0
if foundationModelsAvailable(), #available(macOS 26, *) {
    _ = try await expandQuery("warm up")
    var out: [[String]] = []
    for q in queries {
        let t = now()
        do { out.append(try await expandQuery(q.query)) } catch { out.append([]); expansionFailures += 1 }
        expansionMs.append(now() - t)
    }
    expansions = out
}
let expandedTexts = queries.indices.map { i in ([queries[i].query] + (expansions?[i] ?? [])).joined(separator: " ") }

// MARK: Embeddings

struct SemModel {
    let name: String
    let small: VectorIndex   // the 200 fixture memories
    let big: VectorIndex     // fixture memories first, then synthesized ones
    let queryVectors: [[Float]]
    let expandedVectors: [[Float]]
    let embed: (String) throws -> [Float]
}

var models: [SemModel] = []
let embedders: [any Embedder] = [try SentenceEmbedder(), try await ContextualEmbedder()]
print("## Models\n")
print("| Model | Details | Embed ms/memory (200) | Embed ms/memory (\(big.count)) | Embed ms/query |")
print("|---|---|---|---|---|")
for e in embedders {
    _ = try e.embed("warm up")
    var t = now()
    var vecs = try base.map { try e.embed(embeddingText($0)) }
    let perDocSmall = (now() - t) / Double(base.count)
    t = now()
    vecs += try big.dropFirst(base.count).map { try e.embed(embeddingText($0)) }
    let perDocBig = (now() - t) / Double(big.count - base.count)
    t = now()
    let qv = try queries.map { try e.embed($0.query) }
    let perQuery = (now() - t) / Double(queries.count)
    let xv = try expandedTexts.map { try e.embed($0) }
    let bigIndex = VectorIndex(vectors: vecs, dims: e.dims)
    let smallIndex = VectorIndex(vectors: Array(vecs.prefix(base.count)), dims: e.dims)
    models.append(SemModel(name: e.name, small: smallIndex, big: bigIndex, queryVectors: qv, expandedVectors: xv, embed: e.embed))
    print("| \(e.name) | \(e.info) | \(f(perDocSmall, 2)) | \(f(perDocBig, 2)) | \(f(perQuery, 2)) |")

    // Mean-centered variant: subtract the mean of the 200 fixture vectors (an anisotropy fix).
    let mean = smallIndex.mean
    let center = { (v: [Float]) in l2normalize(zip(v, mean).map { $0 - $1 }) }
    models.append(SemModel(name: e.name + "-centered", small: smallIndex.centered(by: mean), big: bigIndex.centered(by: mean),
                           queryVectors: qv.map(center), expandedVectors: xv.map(center), embed: { try center(e.embed($0)) }))
}
print("\nOllama and OpenAI embeddings: not run (no local Ollama server, no API key on this machine).")
if let expansions {
    print("\nFoundation Models query expansion: \(f(pct(expansionMs, 0.5), 0)) ms p50, \(f(pct(expansionMs, 0.95), 0)) ms p95, \(f(expansionMs.max()!, 0)) ms max per query (greedy sampling); \(expansionFailures) of \(queries.count) refused.")
} else {
    print("\nFoundation Models: unavailable; expansion not run.")
}
print("")

// MARK: Keyword indexes

let tokenizers = [("fts5", "unicode61 remove_diacritics 2"), ("fts5-porter", "porter unicode61 remove_diacritics 2")]
var kwSmall: [String: KeywordIndex] = [:], kwBig: [String: KeywordIndex] = [:]
for (name, tok) in tokenizers {
    kwSmall[name] = try KeywordIndex(docs: base, tokenizer: tok)
    kwBig[name] = try KeywordIndex(docs: big, tokenizer: tok)
}

// MARK: Scoring

struct Corpus {
    let docs: [Doc]
    let idIndex: [String: Int]
    let kw: [String: [[Int: Float]]]          // per tokenizer, per query: doc index → keyword ∈ [0,1]
    let sem: [String: [[Float]]]               // per model, per query: cosine per doc
}

@MainActor func buildCorpus(_ docs: [Doc], kwIndexes: [String: KeywordIndex], big: Bool, expanded: Bool) throws -> Corpus {
    let idIndex = Dictionary(uniqueKeysWithValues: docs.enumerated().map { ($1.id, $0) })
    let texts = expanded ? expandedTexts : queries.map(\.query)
    var kw: [String: [[Int: Float]]] = [:]
    for (name, index) in kwIndexes {
        kw[name] = try texts.map { text in
            Dictionary(uniqueKeysWithValues: normalizeKeyword(try index.search(text)).map { (idIndex[$0.key]!, $0.value) })
        }
    }
    var sem: [String: [[Float]]] = [:]
    for m in models {
        sem[m.name] = (expanded ? m.expandedVectors : m.queryVectors).map { (big ? m.big : m.small).scores($0) }
    }
    return Corpus(docs: docs, idIndex: idIndex, kw: kw, sem: sem)
}

enum Method {
    case keyword(String)
    case semantic(String)
    case hybrid(kw: String, sem: String, wk: Float, ws: Float, threshold: Float)

    var label: String {
        switch self {
        case .keyword(let k): return k
        case .semantic(let s): return s
        case let .hybrid(k, s, wk, ws, t):
            return "\(s) + \(k) \(String(format: "%.2f/%.2f", wk, ws))" + (t > 0 ? " T=\(String(format: "%.2f", t))" : "")
        }
    }
}

/// Ranked doc indices for query `qi` (only documents that pass the method's filter).
func rank(_ m: Method, _ c: Corpus, _ qi: Int) -> [Int] {
    var scored: [(Int, Float)] = []
    switch m {
    case .keyword(let k):
        scored = c.kw[k]![qi].map { ($0.key, $0.value) }
    case .semantic(let s):
        scored = c.sem[s]![qi].enumerated().map { ($0, max(0, $1)) }
    case let .hybrid(k, s, wk, ws, t):
        let kw = c.kw[k]![qi], sem = c.sem[s]![qi]
        for i in 0..<c.docs.count {
            let kv = kw[i] ?? 0, sv = max(0, sem[i])
            if kv > 0 || sv >= t { scored.append((i, wk * kv + ws * sv)) }
        }
    }
    return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
}

struct Scores { var recall5 = 0.0, recall10 = 0.0, mrr = 0.0, recallAll = 0.0, kept = 0.0 }

/// Paraphrases count as their source; repeated sources are collapsed to their first rank.
@MainActor func evaluate(_ m: Method, _ c: Corpus, cap: Int? = nil) -> Scores {
    var s = Scores()
    for (qi, q) in queries.enumerated() {
        let ranked = rank(m, c, qi)
        s.kept += Double(ranked.count)
        var seen = Set<String>(), ids: [String] = []
        for i in (cap.map { Array(ranked.prefix($0)) } ?? ranked) {
            let id = c.docs[i].scoringId
            if seen.insert(id).inserted { ids.append(id) }
        }
        let rel = Set(q.relevant)
        func recall(_ k: Int) -> Double { Double(Set(ids.prefix(k)).intersection(rel).count) / Double(rel.count) }
        s.recall5 += recall(5); s.recall10 += recall(10); s.recallAll += recall(ids.count)
        if let r = ids.firstIndex(where: rel.contains) { s.mrr += 1 / Double(r + 1) }
    }
    let n = Double(queries.count)
    return Scores(recall5: s.recall5 / n, recall10: s.recall10 / n, mrr: s.mrr / n, recallAll: s.recallAll / n, kept: s.kept / n)
}

let small = try buildCorpus(base, kwIndexes: kwSmall, big: false, expanded: false)
let large = try buildCorpus(big, kwIndexes: kwBig, big: true, expanded: false)
let smallX = try buildCorpus(base, kwIndexes: kwSmall, big: false, expanded: true)
let largeX = try buildCorpus(big, kwIndexes: kwBig, big: true, expanded: true)

var methods: [Method] = tokenizers.map { .keyword($0.0) } + models.map { .semantic($0.name) }
for m in models {
    for (wk, ws) in [(Float(0.45), Float(0.55)), (0.3, 0.7)] {
        for (k, _) in tokenizers { methods.append(.hybrid(kw: k, sem: m.name, wk: wk, ws: ws, threshold: 0)) }
    }
}

@MainActor func qualityTable(_ title: String, _ a: Corpus, _ b: Corpus) {
    print("## \(title)\n")
    print("| Method | R@5 (200) | R@10 (200) | MRR (200) | R@5 (\(big.count)) | MRR (\(big.count)) |")
    print("|---|---|---|---|---|---|")
    for m in methods {
        let x = evaluate(m, a), y = evaluate(m, b)
        print("| \(m.label) | \(f(x.recall5)) | \(f(x.recall10)) | \(f(x.mrr)) | \(f(y.recall5)) | \(f(y.mrr)) |")
    }
    print("")
}

print("Recall@k: share of each query's relevant memories in the top k, averaged over the 30 queries. At \(big.count), a paraphrase counts as its source memory.\n")
qualityTable("Quality: original queries (no threshold)", small, large)
if expansions != nil { qualityTable("Quality: Foundation Models–expanded queries (no threshold)", smallX, largeX) }

@MainActor func sweep(_ title: String, _ c: Corpus, kw: String) {
    print("## Weight sweep: \(title) (200, \(kw); R@5 / MRR)\n")
    print("| wk/ws | " + models.map(\.name).joined(separator: " | ") + " |")
    print("|---|" + String(repeating: "---|", count: models.count))
    for step in stride(from: 0, through: 20, by: 1) {
        let wk = Float(step) * 0.05
        let cells = models.map { m -> String in
            let s = evaluate(.hybrid(kw: kw, sem: m.name, wk: wk, ws: 1 - wk, threshold: 0), c)
            return "\(f(s.recall5, 2)) / \(f(s.mrr, 2))"
        }
        print("| \(String(format: "%.2f/%.2f", wk, 1 - wk)) | " + cells.joined(separator: " | ") + " |")
    }
    print("")
}
sweep("original queries", small, kw: "fts5-porter")
if expansions != nil { sweep("expanded queries", smallX, kw: "fts5-porter") }

print("## Similarity distribution (200, original queries)\n")
print("Cosine of each query against its relevant memories vs all other memories.\n")
print("| Model | relevant min | relevant p10 | relevant median | other median | other p90 | other p99 | other max |")
print("|---|---|---|---|---|---|---|---|")
for m in models {
    var rel: [Double] = [], other: [Double] = []
    for (qi, q) in queries.enumerated() {
        let r = Set(q.relevant.map { small.idIndex[$0]! })
        for (i, s) in small.sem[m.name]![qi].enumerated() { if r.contains(i) { rel.append(Double(s)) } else { other.append(Double(s)) } }
    }
    print("| \(m.name) | \(f(rel.min()!, 2)) | \(f(pct(rel, 0.1), 2)) | \(f(pct(rel, 0.5), 2)) | \(f(pct(other, 0.5), 2)) | \(f(pct(other, 0.9), 2)) | \(f(pct(other, 0.99), 2)) | \(f(other.max()!, 2)) |")
}
print("")

@MainActor func thresholds(_ title: String, _ c: Corpus) {
    print("## Thresholds: \(title) (200, fts5-porter; keep if keyword > 0 or semantic ≥ T)\n")
    print("Vault: every kept result (recall, mean kept per query). Retrieval: top 30 of the kept results (recall@30).\n")
    for m in models {
        print("### \(m.name)\n")
        print("| T | vault recall | vault kept | retrieval R@30 0.45/0.55 | retrieval R@30 0.3/0.7 |")
        print("|---|---|---|---|---|")
        for step in stride(from: 0, through: 18, by: 1) {
            let t = Float(step) * 0.05
            let v = evaluate(.hybrid(kw: "fts5-porter", sem: m.name, wk: 0.45, ws: 0.55, threshold: t), c)
            let a = evaluate(.hybrid(kw: "fts5-porter", sem: m.name, wk: 0.45, ws: 0.55, threshold: t), c, cap: 30)
            let b = evaluate(.hybrid(kw: "fts5-porter", sem: m.name, wk: 0.3, ws: 0.7, threshold: t), c, cap: 30)
            print("| \(f(Double(t), 2)) | \(f(v.recallAll)) | \(f(v.kept, 1)) | \(f(a.recallAll)) | \(f(b.recallAll)) |")
        }
        print("")
    }
    let k = evaluate(.keyword("fts5-porter"), c)
    print("Keyword > 0 alone: recall \(f(k.recallAll)), mean kept \(f(k.kept, 1)).\n")
}
thresholds("original queries", small)
if expansions != nil { thresholds("expanded queries", smallX) }

// MARK: Latency (full query path: embed query, FTS5, dot product, combine, filter, top 30)

@MainActor func timedRetrieve(_ text: String, model: SemModel?, index: VectorIndex?, kw: KeywordIndex, docs: [Doc], idIndex: [String: Int],
                              wk: Float, ws: Float, threshold: Float) throws -> (embed: Double, fts: Double, dot: Double, rank: Double) {
    var t = now()
    let q = try model?.embed(text)
    let tEmbed = now() - t
    t = now()
    let raw = try kw.search(text)
    let tFts = now() - t
    t = now()
    let sem = q.map { index!.scores($0) }
    let tDot = now() - t
    t = now()
    var kwArr = [Float](repeating: 0, count: docs.count)
    for (id, v) in normalizeKeyword(raw) { kwArr[idIndex[id]!] = v }
    var scored: [(Int, Float)] = []
    scored.reserveCapacity(256)
    for i in 0..<docs.count {
        let sv = sem.map { max(0, $0[i]) } ?? 0
        if kwArr[i] > 0 || sv >= threshold { scored.append((i, wk * kwArr[i] + ws * sv)) }
    }
    let top = scored.sorted { $0.1 > $1.1 }.prefix(30)
    precondition(top.count <= 30)
    return (tEmbed, tFts, tDot, now() - t)
}

print("## Query latency (ms; 30 queries × 5 runs after a warm-up; fts5-porter, weights 0.3/0.7, top 30)\n")
print("Thresholds: 0.35 raw, 0.20 for -centered. Expansion time is not included here; see above.\n")
print("| Corpus | Method | embed p50 | FTS5 p50 | dot p50 | rank p50 | total p50 | total p95 | total max |")
print("|---|---|---|---|---|---|---|---|---|")
var textSets: [(String, [String])] = [("", queries.map(\.query))]
if expansions != nil { textSets.append((" (expanded text)", expandedTexts)) }
for (label, docs, kwIndexes, isBig) in [("200", base, kwSmall, false), ("\(big.count)", big, kwBig, true)] {
    let idIndex = Dictionary(uniqueKeysWithValues: docs.enumerated().map { ($1.id, $0) })
    let variants: [(String, SemModel?)] = [("fts5-porter only", nil)] + models.map { ($0.name + " + fts5-porter", $0) }
    for (name, model) in variants {
        let index = model.map { isBig ? $0.big : $0.small }
        let threshold: Float = (model?.name.hasSuffix("centered") ?? false) ? 0.20 : 0.35
        let kwIndex = kwIndexes["fts5-porter"]!
        for (tag, texts) in textSets {
            for q in texts { _ = try timedRetrieve(q, model: model, index: index, kw: kwIndex, docs: docs, idIndex: idIndex, wk: 0.3, ws: 0.7, threshold: threshold) }
            var e: [Double] = [], ft: [Double] = [], d: [Double] = [], r: [Double] = [], tot: [Double] = []
            for _ in 0..<5 {
                for q in texts {
                    let x = try timedRetrieve(q, model: model, index: index, kw: kwIndex, docs: docs, idIndex: idIndex, wk: 0.3, ws: 0.7, threshold: threshold)
                    e.append(x.embed); ft.append(x.fts); d.append(x.dot); r.append(x.rank); tot.append(x.embed + x.fts + x.dot + x.rank)
                }
            }
            print("| \(label) | \(name)\(tag) | \(f(pct(e, 0.5), 2)) | \(f(pct(ft, 0.5), 2)) | \(f(pct(d, 0.5), 2)) | \(f(pct(r, 0.5), 2)) | \(f(pct(tot, 0.5), 2)) | \(f(pct(tot, 0.95), 2)) | \(f(tot.max()!, 2)) |")
        }
    }
}
print("\nVector memory at \(big.count): " + models.filter { !$0.name.hasSuffix("centered") }.map { "\($0.name) \($0.big.dims) dims = \(f(Double($0.big.data.count * 4) / 1_048_576, 1)) MB" }.joined(separator: ", "))

if let expansions {
    print("\n## Expansions (Foundation Models, greedy)\n")
    for (q, x) in zip(queries, expansions) { print("- \(q.id) \(q.query) → \(x.joined(separator: ", "))") }
}

// MARK: Foundation Models re-ranking of the top 30 (200 only; the pool size, not the corpus, sets its cost)

if expansions != nil, ProcessInfo.processInfo.environment["RERANK"] != "0", #available(macOS 26, *) {
    print("\n## Foundation Models re-rank of the top 30 (200)\n")
    print("| Pool | R@30 of pool | R@5 after re-rank | MRR after re-rank | re-rank ms p50 | p95 | guided / permissive retry / refused |")
    print("|---|---|---|---|---|---|---|")
    let pools: [(String, Method, Corpus)] = [
        ("nl-contextual-centered + fts5-porter 0.30/0.70, original", .hybrid(kw: "fts5-porter", sem: "nl-contextual-centered", wk: 0.3, ws: 0.7, threshold: 0), small),
        ("nl-contextual-centered + fts5-porter 0.30/0.70, expanded", .hybrid(kw: "fts5-porter", sem: "nl-contextual-centered", wk: 0.3, ws: 0.7, threshold: 0), smallX),
    ]
    for (label, m, c) in pools {
        var r5 = 0.0, mrr = 0.0, poolRecall = 0.0, ms: [Double] = [], outcomes = [0, 0, 0]
        for (qi, q) in queries.enumerated() {
            let ranked = rank(m, c, qi)
            let pool = Array(ranked.prefix(30))
            let t = now()
            let outcome = await rerankWithFoundationModels(task: q.query, candidates: pool.map { "\(base[$0].title): \(base[$0].body)" })
            ms.append(now() - t)
            var picked: [Int] = []
            switch outcome {
            case .guided(let p): picked = p; outcomes[0] += 1
            case .permissive(let p): picked = p; outcomes[1] += 1
            case .refused: outcomes[2] += 1
            }
            var order: [Int] = []
            for p in picked where pool.indices.contains(p) && !order.contains(pool[p]) { order.append(pool[p]) }
            order += ranked.filter { !order.contains($0) }
            let ids = order.map { base[$0].id }, rel = Set(q.relevant)
            poolRecall += Double(Set(pool.map { base[$0].id }).intersection(rel).count) / Double(rel.count)
            r5 += Double(Set(ids.prefix(5)).intersection(rel).count) / Double(rel.count)
            if let r = ids.firstIndex(where: rel.contains) { mrr += 1 / Double(r + 1) }
        }
        let n = Double(queries.count)
        print("| \(label) | \(f(poolRecall / n)) | \(f(r5 / n)) | \(f(mrr / n)) | \(f(pct(ms, 0.5), 0)) | \(f(pct(ms, 0.95), 0)) | \(outcomes.map(String.init).joined(separator: " / ")) |")
    }
}

// MARK: Per-query dump (DUMP=1), to check the relevance labels.
if ProcessInfo.processInfo.environment["DUMP"] == "1" {
    let keyOf = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0.key) })
    let dumps: [(String, Method, Corpus)] = [
        ("original", .hybrid(kw: "fts5-porter", sem: "nl-contextual", wk: 0.45, ws: 0.55, threshold: 0), small),
        ("expanded", .hybrid(kw: "fts5-porter", sem: "nl-contextual", wk: 0.45, ws: 0.55, threshold: 0), smallX),
    ]
    for (tag, m, c) in dumps {
        print("\n## Dump (\(tag)): \(m.label)\n")
        for (qi, q) in queries.enumerated() {
            let ranked = rank(m, c, qi).map { base[$0].id }
            let ranks = q.relevant.map { r in "\(keyOf[r]!)@\((ranked.firstIndex(of: r) ?? 998) + 1)" }
            print("\(q.id) \(q.query)\n   relevant: \(ranks.joined(separator: " "))\n   top5: \(ranked.prefix(5).map { keyOf[$0]! }.joined(separator: " "))")
        }
    }
}
