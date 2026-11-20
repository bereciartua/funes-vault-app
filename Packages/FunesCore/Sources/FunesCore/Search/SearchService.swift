import Foundation
import FunesProtocol
import GRDB
import os
import Synchronization

/// One ranked memory. `cosine` is the raw query–memory cosine; `semantic` is its min-max
/// normalized value over the pool; `keyword` is BM25 divided by the best score.
public struct SearchHit: Sendable, Hashable {
    public let memoryID: UUID
    public let score: Float
    public let keyword: Float
    public let semantic: Float
    public let cosine: Float?
    /// With learned facts in use (vault search only): how a link or a timeline answer admitted it, nil when plain search
    /// kept it on its own.
    public var admission: SearchAdmission? = nil
    /// It lost 0.10: linked only to entities the search doesn't name, or to a timeline's anchor.
    public var demoted = false
    /// Its place in the facts-free ranking (plain search's own order), nil when plain search wouldn't keep it. Answers
    /// read by it until 13d's selection (memory processing §11.9).
    public var plainRank: Int? = nil
}

/// FTS5 query building and BM25 (memory processing §3).
enum KeywordSearch {
    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "am", "an", "and", "any", "are", "as", "at", "be",
        "because", "been", "before", "being", "below", "between", "both", "but", "by", "can", "could", "did",
        "do", "does", "doing", "don", "down", "during", "each", "few", "for", "from", "further", "had", "has",
        "have", "having", "he", "her", "here", "hers", "him", "his", "how", "i", "if", "in", "into", "is", "it",
        "its", "just", "me", "more", "most", "my", "myself", "no", "nor", "not", "now", "of", "off", "on",
        "once", "only", "or", "other", "our", "out", "over", "own", "same", "she", "should", "so", "some",
        "such", "than", "that", "the", "their", "them", "then", "there", "these", "they", "this", "those",
        "through", "to", "too", "under", "until", "up", "very", "was", "we", "were", "what", "when", "where",
        "which", "while", "who", "whom", "why", "will", "with", "would", "you", "your", "yours", "anything",
        "something", "s", "t", "ll", "ve", "re", "d", "m",
    ]

    /// The text's non-stopword terms (lowercased letters and digits, at least two characters), once each.
    static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// An FTS5 OR query of the terms, each quoted. With `prefix`, the last term also matches as a
    /// prefix (`"pnp"*`), for as-you-type vault search. `nil` when there are no indexable terms.
    static func ftsQuery(_ text: String, prefix: Bool = false) -> String? {
        let terms = terms(text)
        guard let last = terms.last else { return nil }
        var parts = terms.map { "\"\($0)\"" }
        if prefix { parts.append("\"\(last)\"*") }
        return parts.joined(separator: " OR ")
    }

    /// Normalized BM25 (best = 1) for the matching active memories, restricted to `pool`.
    static func scores(_ db: Database, text: String, prefix: Bool, pool: Set<UUID>) throws -> [UUID: Float] {
        guard let query = ftsQuery(text, prefix: prefix) else { return [:] }
        var raw: [UUID: Float] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT memory.id AS id, -bm25(memory_fts) AS s
            FROM memory_fts JOIN memory ON memory.seq = memory_fts.rowid
            WHERE memory_fts MATCH ? AND memory.status != 'deleted'
            """, arguments: [query]) {
            guard let id = row.uuid("id"), pool.contains(id) else { continue }
            raw[id] = Float(row["s"] as Double)
        }
        guard let best = raw.values.max(), best > 0 else { return [:] }
        return raw.mapValues { $0 / best }
    }
}

/// A provider embedding model as the second index (ADR-0023): its indexer, and whether agents'
/// task text may be embedded with it (FR-AI-09; a local server's always may).
public struct SecondIndex: Sendable {
    public let indexer: ProviderEmbeddingIndexer
    public let embedsAgentTasks: Bool

    public init(indexer: ProviderEmbeddingIndexer, embedsAgentTasks: Bool = true) {
        self.indexer = indexer
        self.embedsAgentTasks = embedsAgentTasks || indexer.provider.locality.isLocal
    }
}

/// Hybrid search for the vault UI and for agent retrieval (memory processing §4, access policy
/// §3.2, ADR-0016): `score = 0.30 × keyword + 0.70 × semantic`, with the cosine min-max
/// normalized over the pool. A memory is kept if its keyword score reaches the keyword floor or
/// its raw cosine reaches the model's threshold. Without a model (it failed to load, or a memory
/// has no vector yet) semantic is 0 and search is keyword-only; it never fails because of the model.
///
/// With a second index (ADR-0023), once its set is complete: a memory with a provider vector uses
/// the provider's cosine, min-max normalized over the memories that have one, and the provider's
/// threshold (the top 10 for an uncalibrated model); the others keep bge's, normalized over the
/// whole pool. If the provider fails or times out, that search is bge-only (FR-AI-10).
public final class SearchService: Sendable {
    public static let keywordWeight: Float = 0.30
    public static let semanticWeight: Float = 0.70
    /// The most memories agent retrieval returns.
    public static let retrievalLimit = 30
    /// The minimum normalized keyword score that keeps a memory without a semantic match, tuned
    /// on the Spike 2b benchmark (see `SearchBenchmarkTests`).
    public static let defaultKeywordFloor: Float = 0.15

    public let store: VaultStore
    public let indexer: EmbeddingIndexer?
    public let keywordFloor: Float
    private let second = Mutex<SecondIndex?>(nil)
    private let factsConfig = Mutex<FactsSearchConfig?>(nil)
    /// Learned facts have shaped a search since launch (set once, never cleared): answers check what they read from then on.
    private let factsUsed = Mutex(false)
    /// The facts index, and the one as a cloud call may see it (for the second index's rule), by what they were built from.
    private let factsIndexes = Mutex<[FactsIndexKey: FactsSearchIndex]>([:])
    private let rolePhrases = RolePhraseCache()
    private let builds = SerialRunner()
    private let logger = Logger(subsystem: "com.funesvault.mac", category: "search")

    public init(store: VaultStore, indexer: EmbeddingIndexer?, keywordFloor: Float = SearchService.defaultKeywordFloor) {
        self.store = store
        self.indexer = indexer
        self.keywordFloor = keywordFloor
    }

    /// The provider model's index, or nil for bge-only search.
    public var secondIndex: SecondIndex? {
        get { second.withLock { $0 } }
        set { second.withLock { $0 = newValue } }
    }

    /// Learned facts in vault search (memory processing §4): set while *Use in search and answers* is on, nil otherwise.
    /// Agent retrieval, the duplicate hint and the related-memories finder never read it.
    public var facts: FactsSearchConfig? {
        get { factsConfig.withLock { $0 } }
        set {
            factsConfig.withLock { $0 = newValue }
            if newValue != nil, !factsUsed.withLock({ $0 }) {
                factsUsed.withLock { $0 = true }
                // Kept in the vault too, so answers check what they read after a relaunch (a phone's results kept since).
                try? store.writer.write { db in
                    try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('facts_search_used', '1')")
                }
            }
            if newValue == nil {                  // nothing learned stays in memory
                factsIndexes.withLock { $0.removeAll() }
                rolePhrases.clear()
            }
        }
    }

    /// Vault search (FR-V-10): filters apply before ranking; the vault threshold; prefix matching
    /// on the last word. An empty query lists the filtered memories in the filter's order.
    public func vaultSearch(_ query: String, filter: MemoryFilter = MemoryFilter(), now: Date) async throws -> [SearchHit] {
        let pool = try await store.writer.read { db in
            try MemoryStore.listed(db, filter: filter, now: now)
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return pool.map { SearchHit(memoryID: $0.id, score: 0, keyword: 0, semantic: 0, cosine: nil) }
        }
        let pairs = pool.map { (id: $0.id, updatedAt: $0.updatedAt) }
        // One second index for the whole search: what authorizes the rest of the query is what embeds and scores it.
        let second = secondIndex
        if let config = facts, let planned = await factsPlan(query, config: config, second: second, now: now),
           facts.map({ Self.same($0, config) }) == true {      // still the configuration it was planned under
            do {
                return try await rankWithFacts(query, pool: pairs, planned: planned, second: second)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("Learned facts failed; plain search for this query")   // fails closed to plain search
            }
        }
        return try await rank(text: query, pool: pairs, prefix: true, threshold: \.vaultThreshold, agentTask: false, limit: nil,
                              second: second)
    }

    /// What an answer may read of `ids` (the results as shown, in order) until 13d's selection. Once learned facts have
    /// been in use since launch (on now, or on when the list was made: a list not reloaded, a phone's cached results),
    /// only those in plain search's top `count` under the same filter, in shown order, with no refill: plain search
    /// never reads learned facts, so no fact decides which memories go to a model (memory processing §11.9). An error
    /// refuses rather than reading the ids as given. Never used since launch: `ids` as given, as before Phase 13.
    public func answerSelection(_ query: String, ids: [UUID], filter: MemoryFilter, count: Int, now: Date) async throws -> [UUID] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ids }
        let (used, pool) = try await store.writer.read { db in
            (try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'facts_search_used'") == "1",
             try MemoryStore.listed(db, filter: filter, now: now))
        }
        guard used || factsUsed.withLock({ $0 }) else { return ids }
        let plain = try await rank(text: query, pool: pool.map { (id: $0.id, updatedAt: $0.updatedAt) }, prefix: true,
                                   threshold: \.vaultThreshold, agentTask: false, limit: count)
        // In plain search's order, so not even the order a prompt lists them in is the facts'.
        let shown = Set(ids)
        return plain.map(\.memoryID).filter(shown.contains)
    }

    /// Whether a configuration is still the one a search was planned under (the app replaces it on every change).
    static func same(_ a: FactsSearchConfig, _ b: FactsSearchConfig) -> Bool {
        a.engines == b.engines && a.userAliases == b.userAliases && a.cloudLimit == b.cloudLimit
            && a.registry.fingerprint == b.registry.fingerprint
    }

    /// Where each of `ids` matches `query` in its body, for snippets and answers (memory processing
    /// §10.1): one `highlight()` query with the MATCH query vault search used (`prefix`, as typed).
    public func bodyMatches(_ query: String, ids: [UUID], prefix: Bool = true) async throws -> [UUID: BodyMatches] {
        try await store.writer.read { db in try BodyMatches.find(db, ids: ids, query: query, prefix: prefix) }
    }

    /// Agent retrieval (access policy §3.2): active memories including expired ones (so expiry shows
    /// in withheld counts), narrowed to `categories` when given (unknown keys are ignored, so only
    /// unknown keys narrow to nothing), ranked on the task plus keywords. At most 30.
    public func retrieve(task: String, keywords: [String] = [], categories: [String] = []) async throws -> [SearchHit] {
        Array(try await retrieveAll(task: task, keywords: keywords, categories: categories).prefix(Self.retrievalLimit))
    }

    /// Every kept memory, ranked, before the top-30 cut (for tuning).
    func retrieveAll(task: String, keywords: [String] = [], categories: [String] = []) async throws -> [SearchHit] {
        let pool = try await store.writer.read { db -> [(id: UUID, updatedAt: Date)] in
            var sql = "SELECT id, updated_at FROM memory WHERE status = 'active'"
            var args: [String] = []
            if !categories.isEmpty {
                sql += " AND id IN (SELECT memory_id FROM memory_category WHERE category_key IN (\(databaseQuestionMarks(count: categories.count))))"
                args = categories
            }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).compactMap { row in
                row.uuid("id").map { ($0, row["updated_at"] as Date) }
            }
        }
        let text = ([task] + keywords).joined(separator: " ")
        return try await rank(text: text, pool: pool, prefix: false, threshold: \.retrievalThreshold, agentTask: true, limit: nil)
    }

    /// The duplicate hint's semantic half (memory processing §8): active memories whose raw cosine
    /// with this text is at least `threshold` (0.92 for bge-small, re-checked in Phase 1). Empty
    /// without a model. A hint only.
    public func nearDuplicates(title: String, body: String, kind: MemoryKind, categoryNames: [String],
                               excluding: UUID? = nil, threshold: Float = 0.92) async throws -> [UUID] {
        guard let indexer, SecretScanner.scan([title, body]).isEmpty else { return [] }
        let text = EmbeddingIndexer.embeddingText(title: title, kind: kind, categoryNames: categoryNames, body: body)
        guard let v = try? await indexer.provider.embed([text], as: .document).first else { return [] }
        let active = Set(try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM memory WHERE status = 'active'").compactMap(UUID.init(uuidString:))
        })
        return indexer.index.cosines(v).filter { $0.value >= threshold && active.contains($0.key) && $0.key != excluding }
            .sorted { $0.value > $1.value }.map(\.key)
    }

    /// Plain search (memory processing §4): every kept memory, ranked. Agent retrieval, the duplicate hint's callers and
    /// vault search without learned facts all come here; nothing in it reads learned facts.
    func rank(text: String, pool: [(id: UUID, updatedAt: Date)], prefix: Bool,
                      threshold: KeyPath<EmbeddingModelInfo, Float>, agentTask: Bool, limit: Int?,
                      second given: SecondIndex?? = nil) async throws -> [SearchHit] {
        guard !pool.isEmpty else { return [] }
        let poolIDs = Set(pool.map(\.id))
        let second = given ?? secondIndex
        let vectors = await embed([text], agentTask: agentTask, second: second)
        let scored = try await score(text: text, poolIDs: poolIDs, prefix: prefix, threshold: threshold,
                                     bge: vectors.bge.first ?? nil, provider: vectors.provider.first ?? nil, second: vectors.second)
        let ranked = Self.finish(scored, pool: pool)
        return limit.map { Array(ranked.prefix($0)) } ?? ranked
    }

    /// Kept memories by score; ties: the most recently updated, then the id. Each hit's `plainRank` is its place.
    static func finish(_ scored: [UUID: Scored], pool: [(id: UUID, updatedAt: Date)]) -> [SearchHit] {
        var hits: [(SearchHit, Date)] = []
        for (id, updatedAt) in pool {
            guard let s = scored[id], s.kept else { continue }
            hits.append((SearchHit(memoryID: id, score: s.score, keyword: s.keyword, semantic: s.semantic, cosine: s.cosine), updatedAt))
        }
        hits.sort { a, b in
            if a.0.score != b.0.score { return a.0.score > b.0.score }
            if a.1 != b.1 { return a.1 > b.1 }  // ties: most recently updated
            return a.0.memoryID.db < b.0.memoryID.db
        }
        return hits.enumerated().map { i, h in
            var hit = h.0
            hit.plainRank = i
            return hit
        }
    }

    /// The query vectors for some texts: bge's in one call, the second index's (once its set is complete, for agent
    /// text only when it may) one request each, concurrently. Secret-looking text, and any text when the model failed,
    /// gets none (keyword-only for it). `provider: false` keeps a text off the second index.
    private func embed(_ texts: [String], agentTask: Bool, second given: SecondIndex?, provider allowed: [Bool]? = nil) async
        -> (bge: [[Float]?], provider: [[Float]?], second: SecondIndex?) {
        let clean = texts.map { SecretScanner.scan($0).isEmpty }
        var bge = [[Float]?](repeating: nil, count: texts.count)
        let wanted = texts.indices.filter { clean[$0] }
        var provider = [[Float]?](repeating: nil, count: texts.count)
        let second = given.flatMap { s in s.indexer.isComplete && (!agentTask || s.embedsAgentTasks) ? s : nil }
        async let fromProvider: [[Float]?] = {
            guard let second else { return [[Float]?](repeating: nil, count: texts.count) }
            return await withTaskGroup(of: (Int, [Float]?).self) { group in
                for i in texts.indices where clean[i] && (allowed?[i] ?? true) {
                    group.addTask { (i, await second.indexer.queryVector(texts[i])) }
                }
                var out = [[Float]?](repeating: nil, count: texts.count)
                for await (i, v) in group { out[i] = v }
                return out
            }
        }()
        if let indexer, !wanted.isEmpty {
            do {
                let vs = try await indexer.provider.embed(wanted.map { texts[$0] }, as: .query)
                for (k, i) in wanted.enumerated() where k < vs.count { bge[i] = vs[k] }
            } catch {
                logger.error("Query embedding failed; keyword-only for this search")
            }
        }
        provider = await fromProvider
        return (bge, provider, second)
    }

    /// Every pool memory's scores for a text (memory processing §4), and whether it's kept: `keyword ≥ floor` or its raw
    /// cosine at the model's threshold (a memory with a provider vector: the provider's cosine and threshold, or its
    /// top K uncalibrated).
    private func score(text: String, poolIDs: Set<UUID>, prefix: Bool, threshold: KeyPath<EmbeddingModelInfo, Float>,
                       bge q: [Float]?, provider pq: [Float]?, second: SecondIndex?) async throws -> [UUID: Scored] {
        let keyword = try await store.writer.read { db in try KeywordSearch.scores(db, text: text, prefix: prefix, pool: poolIDs) }

        var cosines: [UUID: Float] = [:]
        var cut: Float = .infinity
        if let indexer, let q {
            cosines = indexer.index.cosines(q).filter { poolIDs.contains($0.key) }
            cut = indexer.provider.model[keyPath: threshold]
        }
        let lo = cosines.values.min() ?? 0, hi = cosines.values.max() ?? 0
        let span = hi - lo

        // The second index: provider cosines for the memories that have a provider vector.
        var provider: [UUID: Float] = [:]
        var providerCut: Float = .infinity
        var providerTop: Set<UUID>?
        if let second, let pq, pq.count == second.indexer.provider.model.dimensions {
            provider = second.indexer.index.cosines(pq).filter { poolIDs.contains($0.key) }
            let model = second.indexer.provider.model
            if model.isCalibrated {
                providerCut = model[keyPath: threshold]
            } else {
                providerTop = Set(provider.sorted { $0.value > $1.value }.prefix(EmbeddingModelInfo.topK).map(\.key))
            }
        }
        let plo = provider.values.min() ?? 0, phi = provider.values.max() ?? 0
        let pspan = phi - plo

        var out: [UUID: Scored] = [:]
        for id in poolIDs {
            let k = keyword[id] ?? 0
            let c: Float?, s: Float, semanticKeep: Bool
            if let pc = provider[id] {
                c = pc
                s = pspan > 0 ? (pc - plo) / pspan : 0
                semanticKeep = providerTop.map { $0.contains(id) } ?? (pc >= providerCut)
            } else {
                c = cosines[id]
                s = if let c, span > 0 { (c - lo) / span } else { 0 }
                semanticKeep = (c ?? -1) >= cut
            }
            out[id] = Scored(score: Self.keywordWeight * k + Self.semanticWeight * s, keyword: k, semantic: s, cosine: c,
                             kept: k >= keywordFloor && k > 0 || semanticKeep)
        }
        return out
    }

    // MARK: Learned facts (memory processing §4, owner side only)

    /// Vault search with learned facts: the query's and the rest's scores, then admission without a boost.
    func rankWithFacts(_ query: String, pool: [(id: UUID, updatedAt: Date)], planned: PlannedFacts,
                               second: SecondIndex?) async throws -> [SearchHit] {
        guard !pool.isEmpty else { return [] }
        let poolIDs = Set(pool.map(\.id))
        let rest = planned.plan.rest
        let texts = rest.isEmpty ? [query] : [query, rest]
        let vectors = await embed(texts, agentTask: false, second: second,
                                  provider: rest.isEmpty ? [true] : [true, planned.restMayUseProvider])
        // bge failed on the query (and its rest): plain search, which tries the query alone.
        if indexer != nil, SecretScanner.scan(query).isEmpty, vectors.bge[0] == nil { throw FactsSearchFallback.embedding }
        let plain = try await score(text: query, poolIDs: poolIDs, prefix: true, threshold: \.vaultThreshold,
                                    bge: vectors.bge[0], provider: vectors.provider[0], second: vectors.second)
        var restScores: [UUID: Scored]?
        if !rest.isEmpty {
            restScores = try await score(text: rest, poolIDs: poolIDs, prefix: true, threshold: \.vaultThreshold,
                                         bge: vectors.bge[1], provider: vectors.provider[1], second: vectors.second)
        }
        return SearchFacts.rank(pool: pool, plain: plain, rest: restScores, plan: planned.plan, index: planned.index)
    }

    /// Builds the facts index ahead of the next search when the vault or learned facts changed (the app calls it after
    /// a change), so a search rarely waits for it. Nothing happens while learned facts aren't in use.
    public func prepareFacts(now: Date = Date()) async {
        guard let config = facts else { return }
        _ = try? await factsIndex(config)
    }

    /// A plan worth searching with: the index it came from, and whether the rest of the query may go to the second index.
    struct PlannedFacts {
        var index: FactsSearchIndex
        var plan: FactsQueryPlan
        var restMayUseProvider: Bool
    }

    /// The query's plan, or nil when learned facts change nothing: no use on, nothing the query names, or any error (search
    /// then fails closed to plain search).
    func factsPlan(_ query: String, config: FactsSearchConfig, second: SecondIndex?, now: Date) async -> PlannedFacts? {
        let today = FactStore.writtenDay(now)
        do {
            guard let (index, uses, key) = try await factsIndex(config) else { return nil }
            let plan = index.plan(query, today: today)
            guard !plan.isEmpty else { return nil }
            let may = try await restMayUseProvider(plan, query: query, config: config, uses: uses, key: key, today: today, second: second)
            return PlannedFacts(index: index, plan: plan, restMayUseProvider: may)
        } catch {
            logger.error("Learned facts unavailable; plain search for this query")
            return nil
        }
    }

    /// The facts index for what's on now (read in one transaction with it), built when the vault or learned facts
    /// changed. Builds run one at a time, so a burst of changes builds once more, not once each.
    func factsIndex(_ config: FactsSearchConfig) async throws -> (FactsSearchIndex, FactsUses, FactsIndexKey)? {
        let current: (FactsUses, FactsIndexKey, FactsSearchIndex?)? = try await store.writer.read { db in
            let uses = try config.uses(db)
            guard !uses.predicates(.linked).isEmpty else { return nil }
            let key = try FactsIndexKey(db, config: config, uses: uses, sendable: nil)
            return (uses, key, self.factsIndexes.withLock { $0[key] })
        }
        guard let (uses, key, cached) = current else { return nil }
        if let cached { return (cached, uses, key) }
        return try await builds.run {
            try await self.store.writer.read { db in
                let uses = try config.uses(db)
                guard !uses.predicates(.linked).isEmpty else { return nil }
                let key = try FactsIndexKey(db, config: config, uses: uses, sendable: nil)
                if let cached = self.factsIndexes.withLock({ $0[key] }) { return (cached, uses, key) }
                let built = try FactsSearchIndex.build(db, registry: config.registry, userAliases: config.userAliases, uses: uses,
                                                       phrases: self.rolePhrases, measured: config.measuredLinks)
                self.factsIndexes.withLock { cache in
                    cache = cache.filter { $0.key.sendable != nil && $0.key.sameState(key) }
                    if self.facts != nil { cache[key] = built }     // turned off meanwhile: keep nothing learned
                }
                return (built, uses, key)
            }
        }
    }

    /// The graph a cloud call may see under `limit` (memory processing §11.9), with its links, for the state `key` names:
    /// cached beside the full index, built one at a time.
    func sendableIndex(_ config: FactsSearchConfig, uses: FactsUses, key: FactsIndexKey, limit: CloudLimit) async throws
        -> FactsSearchIndex {
        try await builds.run {
            try await self.store.writer.read { db in
                var k = key
                k.sendable = String(describing: limit)
                if let cached = self.factsIndexes.withLock({ $0[k] }) { return cached }
                let built = try FactsSearchIndex.build(db, registry: config.registry, userAliases: config.userAliases, uses: uses,
                                                       sendable: limit, measured: config.measuredLinks)
                self.factsIndexes.withLock { if self.facts != nil { $0[k] = built } }
                return built
            }
        }
    }

    /// The rest of the query goes to the second index only when it's local, or every match comes from sendable facts
    /// (memory processing §11.9): the plan, made again on the graph a cloud call may see under the cloud limit, matches
    /// the same entities over the same words. `second` is the index the search embeds and scores with.
    private func restMayUseProvider(_ plan: FactsQueryPlan, query: String, config: FactsSearchConfig, uses: FactsUses,
                                    key: FactsIndexKey, today: String, second: SecondIndex?) async throws -> Bool {
        guard !plan.rest.isEmpty, let second, second.indexer.isComplete else { return false }
        if second.indexer.provider.locality.isLocal { return true }
        let sendable = try await sendableIndex(config, uses: uses, key: key, limit: config.cloudLimit)
        let other = sendable.plan(query, today: today)
        func shape(_ p: FactsQueryPlan) -> Set<String> { Set(p.matches.map { "\($0.entity)|\($0.start)|\($0.end)" }) }
        return shape(other) == shape(plan)
    }
}

/// Runs async work one piece at a time, in the order asked.
final class SerialRunner: Sendable {
    private let last = Mutex<Task<Void, Never>?>(nil)

    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task: Task<T, any Error> = last.withLock { tail in
            let previous = tail
            let t = Task { () async throws -> T in
                await previous?.value
                return try await work()
            }
            tail = Task { _ = try? await t.value }
            return t
        }
        return try await task.value
    }
}

/// What a facts index was built from: the facts revision (with its epoch), the vault's memories and the Facts task's
/// dealings with them, what's on, your names, the registry, and the cloud limit for a sendable one.
struct FactsIndexKey: Hashable, Sendable {
    var revision: String
    var vault: String
    var uses: String
    var aliases: [String]
    var registry: String
    var sendable: String?
    /// A measurement's links (`FactsSearchConfig.measuredLinks`): another set is another index.
    var measured: [String: [MemoryLink]]

    init(_ db: Database, config: FactsSearchConfig, uses: FactsUses, sendable: String?) throws {
        revision = try FactStore.revision(db)
        let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n, COALESCE(SUM(version), 0) AS v, COALESCE(MAX(seq), 0) AS s, COALESCE(MAX(updated_at), '') AS u,
              (SELECT COUNT(*) FROM facts_asked) AS a,
              (SELECT COUNT(*) FROM processing_job WHERE kind = 'facts' AND state IN ('done','failed')) AS j
            FROM memory
            """)
        vault = row.map { "\($0["n"] as Int).\($0["v"] as Int).\($0["s"] as Int).\($0["u"] as String).\($0["a"] as Int).\($0["j"] as Int)" } ?? ""
        self.uses = config.registry.predicates.map { p in
            p.id + ":" + [FactsUse.recorded, .linked, .timeline].filter { uses.isOn(p.id, $0) }.map(\.rawValue).joined(separator: ",")
        }.joined(separator: ";")
        aliases = config.userAliases
        registry = config.registry.fingerprint
        measured = config.measuredLinks
        self.sendable = sendable
    }

    /// The same state, whatever the limit.
    func sameState(_ o: FactsIndexKey) -> Bool {
        revision == o.revision && vault == o.vault && uses == o.uses && aliases == o.aliases && registry == o.registry
            && measured == o.measured
    }
}

/// Why a search with learned facts gave way to plain search.
enum FactsSearchFallback: Error { case embedding }
