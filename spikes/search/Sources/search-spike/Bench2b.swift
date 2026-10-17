// Spike 2b: open embedding models (vectors computed by spikes/embeddings/embed.py) against
// FTS5 porter, with original, agent-expanded and Spanish queries. Run with MODE=2b.
import Foundation

private struct ExpandedQuery: Decodable {
    let id: String
    let query: String
    let keywords: [String]
    let categories: [String]
    let relevant: [String]
}
private struct ExpandedFile: Decodable { let queries: [ExpandedQuery] }
private struct SimpleQuery: Decodable { let id: String; let query: String; let relevant: [String] }
private struct SimpleFile: Decodable { let queries: [SimpleQuery] }

private struct ModelMeta: Decodable {
    let name: String
    let hf_id: String
    let dims: Int
    let runtime: String
    let doc_ms: Double
    let query_ms_p50: Double
    let query_ms_p95: Double
    let size_mb: Double
    let license: String
}

/// One set of query texts sharing the 30 relevance labels.
private struct QuerySet {
    let name: String
    let texts: [String]
    let categories: [[String]]?   // agent-supplied category filter, when used
}

private struct SemSpace {
    let name: String
    let meta: String
    let small: VectorIndex
    let big: VectorIndex
    let queries: [String: [[Float]]]   // query-set name → vectors
    let queryMs: Double?
}

private func readF32(_ url: URL, dims: Int) throws -> [[Float]] {
    let data = try Data(contentsOf: url)
    let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    precondition(floats.count % dims == 0, "\(url.lastPathComponent): \(floats.count) floats, dims \(dims)")
    return stride(from: 0, to: floats.count, by: dims).map { Array(floats[$0..<$0 + dims]) }
}

@MainActor func runSpike2b(fixturesDir: URL, bigN: Int) async throws {
    let env = ProcessInfo.processInfo.environment
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
    func f(_ x: Double, _ d: Int = 3) -> String { String(format: "%.\(d)f", x) }
    func pct(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    let (memories, baseQueries) = try loadFixtures(dir: fixturesDir)
    let base = memories.map { Doc(id: $0.id, sourceId: nil, title: $0.title, body: $0.body, kind: $0.kind, categories: $0.categories) }
    let big = synthesize(from: base, total: bigN)
    let expanded = try JSONDecoder().decode(ExpandedFile.self, from: Data(contentsOf: fixturesDir.appendingPathComponent("queries-30-expanded.json"))).queries
    let spikeDir = URL(fileURLWithPath: env["SPIKE_DIR"] ?? "../embeddings")
    let spanish = try JSONDecoder().decode(SimpleFile.self, from: Data(contentsOf: spikeDir.appendingPathComponent("queries-30-es.json"))).queries
    precondition(expanded.map(\.id) == baseQueries.map(\.id) && spanish.map(\.id) == baseQueries.map(\.id))
    let relevant = baseQueries.map { Set($0.relevant) }

    let agentTexts = expanded.map { ([$0.query] + $0.keywords).joined(separator: " ") }
    let sets = [
        QuerySet(name: "original", texts: baseQueries.map(\.query), categories: nil),
        QuerySet(name: "agent", texts: agentTexts, categories: nil),
        QuerySet(name: "agent+categories", texts: agentTexts, categories: expanded.map(\.categories)),
        QuerySet(name: "spanish", texts: spanish.map(\.query), categories: nil),
    ]
    let vectorSet = ["original": "original", "agent": "agent", "agent+categories": "agent", "spanish": "spanish"]

    // Corpus export for the Python embedder.
    if let out = env["EXPORT"] {
        struct ExportDoc: Encodable { let id: String; let sourceId: String?; let text: String }
        struct Export: Encodable { let docs: [ExportDoc]; let queries: [String: [String]] }
        let e = Export(docs: big.map { ExportDoc(id: $0.id, sourceId: $0.sourceId, text: embeddingText($0)) },
                       queries: ["original": sets[0].texts, "agent": sets[1].texts, "spanish": sets[3].texts])
        try JSONEncoder().encode(e).write(to: URL(fileURLWithPath: out))
        print("exported \(big.count) docs to \(out)")
        return
    }

    print("# Spike 2b: open embedding models\n")
    print("Date: \(ISO8601DateFormatter().string(from: Date()))")
    print("Host: \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.processorCount) cores, \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
    print("Corpus: \(base.count) fixture memories; big corpus \(big.count). Query sets: original, agent (task + keywords), agent+categories (same text, pool narrowed to the agent's categories), spanish.\n")

    // MARK: Semantic spaces: Apple reference (live) + external models (vectors from Python)
    var spaces: [SemSpace] = []
    if env["APPLE"] != "0" {
        let e = try await ContextualEmbedder()
        var vecs = try big.map { try e.embed(embeddingText($0)) }
        let smallIdx = VectorIndex(vectors: Array(vecs.prefix(base.count)), dims: e.dims)
        let mean = smallIdx.mean
        let center = { (v: [Float]) in l2normalize(zip(v, mean).map { $0 - $1 }) }
        vecs = vecs.map(center)
        var qs: [String: [[Float]]] = [:]
        var qms: [Double] = []
        for name in ["original", "agent", "spanish"] {
            let texts = sets.first { $0.name == name }!.texts
            qs[name] = try texts.map { t in let s = now(); let v = try center(e.embed(t)); qms.append(now() - s); return v }
        }
        spaces.append(SemSpace(name: "apple-contextual-centered", meta: "NLContextualEmbedding(en), 512 dims, live in Swift",
                               small: VectorIndex(vectors: Array(vecs.prefix(base.count)), dims: e.dims),
                               big: VectorIndex(vectors: vecs, dims: e.dims), queries: qs, queryMs: pct(qms, 0.5)))
    }
    let vectorsDir = spikeDir.appendingPathComponent("vectors")
    var metas: [ModelMeta] = []
    for name in (env["MODELS"] ?? "").split(separator: ",").map(String.init) {
        let dir = vectorsDir.appendingPathComponent(name)
        let meta = try JSONDecoder().decode(ModelMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
        metas.append(meta)
        let docs = try readF32(dir.appendingPathComponent("docs.f32"), dims: meta.dims)
        precondition(docs.count == big.count, "\(name): \(docs.count) doc vectors, corpus \(big.count)")
        var qs: [String: [[Float]]] = [:]
        for set in ["original", "agent", "spanish"] {
            qs[set] = try readF32(dir.appendingPathComponent("q_\(set).f32"), dims: meta.dims)
        }
        spaces.append(SemSpace(name: name, meta: meta.runtime, small: VectorIndex(vectors: Array(docs.prefix(base.count)), dims: meta.dims),
                               big: VectorIndex(vectors: docs, dims: meta.dims), queries: qs, queryMs: meta.query_ms_p50))
    }

    print("## Models\n")
    print("| Model | HF id | Dims | Licence | Size on disk | Runtime | Embed ms/memory | Embed ms/query p50 / p95 |")
    print("|---|---|---|---|---|---|---|---|")
    for m in metas {
        print("| \(m.name) | \(m.hf_id) | \(m.dims) | \(m.license) | \(f(m.size_mb, 0)) MB | \(m.runtime) | \(f(m.doc_ms, 2)) | \(f(m.query_ms_p50, 1)) / \(f(m.query_ms_p95, 1)) |")
    }
    print("")

    // MARK: Keyword
    let kwSmall = try KeywordIndex(docs: base, tokenizer: "porter unicode61 remove_diacritics 2")
    let kwBig = try KeywordIndex(docs: big, tokenizer: "porter unicode61 remove_diacritics 2")

    struct Prepared {
        let docs: [Doc]
        var kw: [String: [[Int: Float]]] = [:]          // set → per query
        var sem: [String: [String: [[Float]]]] = [:]    // space → set → per query cosines
    }
    func prepare(_ docs: [Doc], _ kwIndex: KeywordIndex, big isBig: Bool) throws -> Prepared {
        let idIndex = Dictionary(uniqueKeysWithValues: docs.enumerated().map { ($1.id, $0) })
        var p = Prepared(docs: docs)
        for s in sets where p.kw[s.name] == nil {
            p.kw[s.name] = try s.texts.map { t in
                Dictionary(uniqueKeysWithValues: normalizeKeyword(try kwIndex.search(t)).map { (idIndex[$0.key]!, $0.value) })
            }
        }
        for sp in spaces {
            var bySet: [String: [[Float]]] = [:]
            for s in sets { bySet[s.name] = sp.queries[vectorSet[s.name]!]!.map { (isBig ? sp.big : sp.small).scores($0) } }
            p.sem[sp.name] = bySet
        }
        return p
    }
    let small = try prepare(base, kwSmall, big: false)
    let large = try prepare(big, kwBig, big: true)

    struct Scores { var r5 = 0.0, r10 = 0.0, mrr = 0.0, rAll = 0.0, kept = 0.0 }
    enum Fusion {
        case linear(Float, Float)   // wk × keyword + ws × max(0, cosine): the spec's formula
        case minmax(Float, Float)   // same, with the cosine min-max normalized per query
        case rrf                    // reciprocal rank fusion, k = 60
    }
    /// sem == nil: keyword only. Threshold (linear only): keep if keyword > 0 or cosine ≥ t.
    /// Paraphrases count as their source; a mixture counts as a relevant memory whose sentence it contains.
    func evaluate(_ p: Prepared, set: QuerySet, sem: String?, fusion: Fusion = .linear(0.45, 0.55), threshold: Float = -1, cap: Int? = nil) -> Scores {
        var s = Scores()
        for qi in 0..<relevant.count {
            let kw = p.kw[set.name]![qi]
            let allowed = set.categories.map { Set($0[qi]) }
            func ok(_ i: Int) -> Bool { allowed.map { !$0.isDisjoint(with: p.docs[i].categories) } ?? true }
            var scored: [(Int, Float)] = []
            if let sem {
                let sv = p.sem[sem]![set.name]![qi]
                switch fusion {
                case let .linear(wk, ws):
                    for i in 0..<p.docs.count where ok(i) {
                        let k = kw[i] ?? 0, c = max(0, sv[i])
                        if k > 0 || c >= threshold { scored.append((i, wk * k + ws * c)) }
                    }
                case let .minmax(wk, ws):
                    let lo = sv.min()!, hi = sv.max()!
                    for i in 0..<p.docs.count where ok(i) { scored.append((i, wk * (kw[i] ?? 0) + ws * (sv[i] - lo) / max(hi - lo, 1e-6))) }
                case .rrf:
                    var kwRank: [Int: Int] = [:]
                    for (r, e) in kw.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).enumerated() { kwRank[e.key] = r }
                    let semOrder = (0..<p.docs.count).sorted { sv[$0] != sv[$1] ? sv[$0] > sv[$1] : $0 < $1 }
                    var semRank = [Int](repeating: 0, count: p.docs.count)
                    for (r, i) in semOrder.enumerated() { semRank[i] = r }
                    for i in 0..<p.docs.count where ok(i) {
                        scored.append((i, 1 / Float(60 + semRank[i]) + (kwRank[i].map { 1 / Float(60 + $0) } ?? 0)))
                    }
                }
            } else {
                for (i, k) in kw where ok(i) { scored.append((i, k)) }
            }
            scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            s.kept += Double(scored.count)
            let rel = relevant[qi]
            var seen = Set<String>(), ids: [String] = []
            for (i, _) in (cap.map { Array(scored.prefix($0)) } ?? scored) {
                let d = p.docs[i]
                let id = d.mixSources.first(where: rel.contains) ?? d.scoringId
                if seen.insert(id).inserted { ids.append(id) }
            }
            func recall(_ k: Int) -> Double { Double(Set(ids.prefix(k)).intersection(rel).count) / Double(rel.count) }
            s.r5 += recall(5); s.r10 += recall(10); s.rAll += recall(ids.count)
            if let r = ids.firstIndex(where: rel.contains) { s.mrr += 1 / Double(r + 1) }
        }
        let n = Double(relevant.count)
        return Scores(r5: s.r5 / n, r10: s.r10 / n, mrr: s.mrr / n, rAll: s.rAll / n, kept: s.kept / n)
    }

    // MARK: Quality tables
    let weights: [Float] = stride(from: 0, through: 20, by: 1).map { Float($0) * 0.05 }
    var bestWeights: [String: Float] = [:]
    for set in sets {
        print("## Quality: \(set.name) queries\n")
        print("| Method | R@5 | R@10 | MRR | R@5 (\(big.count)) | MRR (\(big.count)) |")
        print("|---|---|---|---|---|---|")
        let k = evaluate(small, set: set, sem: nil), kb = evaluate(large, set: set, sem: nil)
        print("| fts5-porter | \(f(k.r5)) | \(f(k.r10)) | \(f(k.mrr)) | \(f(kb.r5)) | \(f(kb.mrr)) |")
        for sp in spaces {
            var rows: [(String, Fusion)] = [("\(sp.name) alone", .linear(0, 1)), ("+ fts5-porter 0.45/0.55", .linear(0.45, 0.55)), ("+ fts5-porter 0.30/0.70", .linear(0.3, 0.7))]
            let best = weights.max { evaluate(small, set: set, sem: sp.name, fusion: .linear($0, 1 - $0)).r5 < evaluate(small, set: set, sem: sp.name, fusion: .linear($1, 1 - $1)).r5 }!
            if set.name == "original" { bestWeights[sp.name] = best }
            rows.append(("+ fts5-porter best \(String(format: "%.2f/%.2f", best, 1 - best))", .linear(best, 1 - best)))
            rows.append(("+ fts5-porter min-max 0.45/0.55", .minmax(0.45, 0.55)))
            rows.append(("+ fts5-porter min-max 0.30/0.70", .minmax(0.3, 0.7)))
            rows.append(("+ fts5-porter RRF", .rrf))
            for (label, fusion) in rows {
                let a = evaluate(small, set: set, sem: sp.name, fusion: fusion), b = evaluate(large, set: set, sem: sp.name, fusion: fusion)
                print("| \(label) | \(f(a.r5)) | \(f(a.r10)) | \(f(a.mrr)) | \(f(b.r5)) | \(f(b.mrr)) |")
            }
        }
        print("")
    }

    print("## Weight sweep (200; R@5, original / agent)\n")
    print("| wk/ws | " + spaces.map(\.name).joined(separator: " | ") + " |")
    print("|---|" + String(repeating: "---|", count: spaces.count))
    for wk in stride(from: Float(0), through: 1.0001, by: 0.1) {
        let cells = spaces.map { sp in
            "\(f(evaluate(small, set: sets[0], sem: sp.name, fusion: .linear(wk, 1 - wk)).r5, 2)) / \(f(evaluate(small, set: sets[1], sem: sp.name, fusion: .linear(wk, 1 - wk)).r5, 2))"
        }
        print("| \(String(format: "%.1f/%.1f", wk, 1 - wk)) | " + cells.joined(separator: " | ") + " |")
    }
    print("")

    // MARK: Similarities and thresholds
    print("## Similarity distribution (200, original queries)\n")
    print("| Model | relevant p10 | relevant median | other median | other p90 | other p99 |")
    print("|---|---|---|---|---|---|")
    var otherP90: [String: Double] = [:]
    for sp in spaces {
        var rel: [Double] = [], other: [Double] = []
        for qi in 0..<relevant.count {
            for (i, c) in small.sem[sp.name]!["original"]![qi].enumerated() {
                if relevant[qi].contains(base[i].id) { rel.append(Double(c)) } else { other.append(Double(c)) }
            }
        }
        otherP90[sp.name] = pct(other, 0.9)
        print("| \(sp.name) | \(f(pct(rel, 0.1), 2)) | \(f(pct(rel, 0.5), 2)) | \(f(pct(other, 0.5), 2)) | \(f(pct(other, 0.9), 2)) | \(f(pct(other, 0.99), 2)) |")
    }
    print("")

    print("## Thresholds (200, 0.45/0.55; keep if keyword > 0 or semantic ≥ T)\n")
    print("Vault = recall of every kept result and mean kept per query; retrieval = recall@30 of the kept results. Original / agent queries.\n")
    for sp in spaces {
        print("### \(sp.name)\n")
        print("| T | vault recall | vault kept | retrieval R@30 | agent: vault recall | agent: kept | agent: R@30 |")
        print("|---|---|---|---|---|---|---|")
        for t in stride(from: Float(0.10), through: 0.9001, by: 0.05) {
            let v = evaluate(small, set: sets[0], sem: sp.name, threshold: t)
            let r = evaluate(small, set: sets[0], sem: sp.name, threshold: t, cap: 30)
            let va = evaluate(small, set: sets[1], sem: sp.name, threshold: t)
            let ra = evaluate(small, set: sets[1], sem: sp.name, threshold: t, cap: 30)
            print("| \(f(Double(t), 2)) | \(f(v.rAll)) | \(f(v.kept, 1)) | \(f(r.rAll)) | \(f(va.rAll)) | \(f(va.kept, 1)) | \(f(ra.rAll)) |")
        }
        print("")
    }
    let ko = evaluate(small, set: sets[0], sem: nil), ka = evaluate(small, set: sets[1], sem: nil)
    print("Keyword > 0 alone: original recall \(f(ko.rAll)), kept \(f(ko.kept, 1)); agent recall \(f(ka.rAll)), kept \(f(ka.kept, 1)).\n")

    // MARK: Latency at 10K with precomputed query vectors (FTS5 + dot + rank in Swift)
    print("## Search latency at \(big.count) without the query embedding (ms; 30 agent queries × 5 runs; 0.45/0.55, top 30)\n")
    print("Add the model's per-query embedding time (Models table, or the Core ML section) for the end-to-end figure.\n")
    print("| Model | FTS5 p50 | dot p50 | rank p50 | search p50 | search p95 | + embed p50 = total p50 |")
    print("|---|---|---|---|---|---|---|")
    let idIndex = Dictionary(uniqueKeysWithValues: big.enumerated().map { ($1.id, $0) })
    for sp in spaces {
        let qv = sp.queries["agent"]!
        let thr = Float(otherP90[sp.name] ?? 0.3)
        var ft: [Double] = [], d: [Double] = [], r: [Double] = [], tot: [Double] = []
        for run in 0..<6 {
            for (qi, text) in agentTexts.enumerated() {
                var t = now()
                let raw = try kwBig.search(text)
                let tf = now() - t
                t = now()
                let sem = sp.big.scores(qv[qi])
                let td = now() - t
                t = now()
                var kwArr = [Float](repeating: 0, count: big.count)
                for (id, v) in normalizeKeyword(raw) { kwArr[idIndex[id]!] = v }
                var scored: [(Int, Float)] = []
                scored.reserveCapacity(512)
                for i in 0..<big.count where kwArr[i] > 0 || sem[i] >= thr { scored.append((i, 0.45 * kwArr[i] + 0.55 * max(0, sem[i]))) }
                let top = scored.sorted { $0.1 > $1.1 }.prefix(30)
                precondition(top.count <= 30)
                let tr = now() - t
                if run > 0 { ft.append(tf); d.append(td); r.append(tr); tot.append(tf + td + tr) }
            }
        }
        let embed = sp.queryMs ?? 0
        print("| \(sp.name) | \(f(pct(ft, 0.5), 2)) | \(f(pct(d, 0.5), 2)) | \(f(pct(r, 0.5), 2)) | \(f(pct(tot, 0.5), 2)) | \(f(pct(tot, 0.95), 2)) | \(f(embed, 1)) → \(f(embed + pct(tot, 0.5), 1)) |")
    }
    print("\nThreshold used for latency: each model's 'other p90' cosine. Vector memory at \(big.count): " +
          spaces.map { "\($0.name) \(f(Double($0.big.data.count * 4) / 1_048_576, 1)) MB" }.joined(separator: ", "))

    // MARK: Per-query detail for the best model
    if let name = env["DUMP_MODEL"], spaces.contains(where: { $0.name == name }) {
        let keyOf = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0.key) })
        let wk = bestWeights[name] ?? 0.45
        for set in [sets[0], sets[1]] {
            print("\n## Dump: \(name) + fts5-porter \(String(format: "%.2f/%.2f", wk, 1 - wk)), \(set.name)\n")
            for qi in 0..<relevant.count {
                let kw = small.kw[set.name]![qi], sv = small.sem[name]![set.name]![qi]
                let ranked = (0..<base.count).map { ($0, wk * (kw[$0] ?? 0) + (1 - wk) * max(0, sv[$0])) }
                    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map { base[$0.0].id }
                let ranks = baseQueries[qi].relevant.map { "\(keyOf[$0]!)@\((ranked.firstIndex(of: $0) ?? 998) + 1)" }
                print("\(baseQueries[qi].id) \(set.texts[qi])\n   relevant: \(ranks.joined(separator: " "))\n   top5: \(ranked.prefix(5).map { keyOf[$0]! }.joined(separator: " "))")
            }
        }
    }
}
