import Foundation
import FunesProtocol
import GRDB
import os

/// One ranked memory. `cosine` is the raw query–memory cosine; `semantic` is its min-max
/// normalized value over the pool; `keyword` is BM25 divided by the best score.
public struct SearchHit: Sendable, Hashable {
    public let memoryID: UUID
    public let score: Float
    public let keyword: Float
    public let semantic: Float
    public let cosine: Float?
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

/// Hybrid search for the vault UI and for agent retrieval (memory processing §4, access policy
/// §3.2, ADR-0016): `score = 0.30 × keyword + 0.70 × semantic`, with the cosine min-max
/// normalized over the pool. A memory is kept if its keyword score reaches the keyword floor or
/// its raw cosine reaches the model's threshold. Without a model (it failed to load, or a memory
/// has no vector yet) semantic is 0 and search is keyword-only; it never fails because of the model.
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
    private let logger = Logger(subsystem: "com.funesvault.mac", category: "search")

    public init(store: VaultStore, indexer: EmbeddingIndexer?, keywordFloor: Float = SearchService.defaultKeywordFloor) {
        self.store = store
        self.indexer = indexer
        self.keywordFloor = keywordFloor
    }

    /// Vault search (FR-V-10): filters apply before ranking; the vault threshold; prefix matching
    /// on the last word. An empty query lists the filtered memories in the filter's order.
    public func vaultSearch(_ query: String, filter: MemoryFilter = MemoryFilter(), now: Date) async throws -> [SearchHit] {
        let pool = try await store.writer.read { db in
            try MemoryStore.list(db, filter: filter, now: now).map { (id: $0.id, updatedAt: $0.updatedAt) }
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return pool.map { SearchHit(memoryID: $0.id, score: 0, keyword: 0, semantic: 0, cosine: nil) }
        }
        return try await rank(text: query, pool: pool, prefix: true, threshold: \.vaultThreshold, limit: nil)
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
        return try await rank(text: text, pool: pool, prefix: false, threshold: \.retrievalThreshold, limit: nil)
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

    private func rank(text: String, pool: [(id: UUID, updatedAt: Date)], prefix: Bool,
                      threshold: KeyPath<EmbeddingModelInfo, Float>, limit: Int?) async throws -> [SearchHit] {
        guard !pool.isEmpty else { return [] }
        let poolIDs = Set(pool.map(\.id))
        let keyword = try await store.writer.read { db in try KeywordSearch.scores(db, text: text, prefix: prefix, pool: poolIDs) }

        // Semantic: skipped for secret-like queries, and when the model is unavailable.
        var cosines: [UUID: Float] = [:]
        var cut: Float = .infinity
        if let indexer, SecretScanner.scan(text).isEmpty {
            do {
                if let q = try await indexer.provider.embed([text], as: .query).first {
                    cosines = indexer.index.cosines(q).filter { poolIDs.contains($0.key) }
                    cut = indexer.provider.model[keyPath: threshold]
                }
            } catch {
                logger.error("Query embedding failed; keyword-only for this search")
            }
        }
        let lo = cosines.values.min() ?? 0, hi = cosines.values.max() ?? 0
        let span = hi - lo

        var hits: [(SearchHit, Date)] = []
        for (id, updatedAt) in pool {
            let k = keyword[id] ?? 0
            let c = cosines[id]
            guard k >= keywordFloor && k > 0 || (c ?? -1) >= cut else { continue }
            let s: Float = if let c, span > 0 { (c - lo) / span } else { 0 }
            hits.append((SearchHit(memoryID: id, score: Self.keywordWeight * k + Self.semanticWeight * s,
                                   keyword: k, semantic: s, cosine: c), updatedAt))
        }
        hits.sort { a, b in
            if a.0.score != b.0.score { return a.0.score > b.0.score }
            if a.1 != b.1 { return a.1 > b.1 }  // ties: most recently updated
            return a.0.memoryID.db < b.0.memoryID.db
        }
        let ranked = hits.map(\.0)
        return limit.map { Array(ranked.prefix($0)) } ?? ranked
    }
}
