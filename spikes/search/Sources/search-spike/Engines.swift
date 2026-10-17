import Accelerate
import Foundation
import GRDB
import NaturalLanguage

// MARK: - Embedders

protocol Embedder {
    var name: String { get }
    var dims: Int { get }
    var info: String { get }
    func embed(_ text: String) throws -> [Float]
}

enum SpikeError: Error { case unavailable(String), noVector }

func l2normalize(_ v: [Float]) -> [Float] {
    var norm: Float = 0
    vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
    norm = norm.squareRoot()
    guard norm > 0 else { return v }
    return v.map { $0 / norm }
}

/// `NLEmbedding.sentenceEmbedding(for: .english)`.
final class SentenceEmbedder: Embedder {
    let model: NLEmbedding
    let name = "nl-sentence"
    var dims: Int { model.dimension }
    var info: String { "NLEmbedding.sentenceEmbedding(en) revision \(model.revision), dims \(model.dimension)" }

    init() throws {
        guard let m = NLEmbedding.sentenceEmbedding(for: .english) else { throw SpikeError.unavailable("sentence") }
        model = m
    }

    func embed(_ text: String) throws -> [Float] {
        guard let v = model.vector(for: text) else { throw SpikeError.noVector }
        return l2normalize(v.map(Float.init))
    }
}

/// `NLContextualEmbedding(language: .english)`, token vectors mean-pooled.
final class ContextualEmbedder: Embedder {
    let model: NLContextualEmbedding
    let name = "nl-contextual"
    var dims: Int { model.dimension }
    var info: String {
        "NLContextualEmbedding(en) \(model.modelIdentifier) revision \(model.revision), dims \(model.dimension), max \(model.maximumSequenceLength) tokens"
    }

    init() async throws {
        guard let m = NLContextualEmbedding(language: .english) else { throw SpikeError.unavailable("contextual") }
        if !m.hasAvailableAssets {
            let result = try await m.requestAssets()
            guard result == .available else { throw SpikeError.unavailable("contextual assets: \(result)") }
        }
        try m.load()
        model = m
    }

    func embed(_ text: String) throws -> [Float] {
        let result = try model.embeddingResult(for: text, language: .english)
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            vDSP_vaddD(sum, 1, vector, 1, &sum, 1, vDSP_Length(sum.count))
            count += 1
            return true
        }
        guard count > 0 else { throw SpikeError.noVector }
        return l2normalize(sum.map { Float($0 / Double(count)) })
    }
}

/// Row-major N × d matrix of L2-normalized vectors; `scores` is one matrix–vector multiply.
struct VectorIndex {
    let dims: Int
    var data: [Float]
    var count: Int { data.count / dims }

    init(vectors: [[Float]], dims: Int) {
        self.dims = dims
        data = vectors.flatMap { $0 }
    }

    func scores(_ q: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        vDSP_mmul(data, 1, q, 1, &out, 1, vDSP_Length(count), 1, vDSP_Length(dims))
        return out
    }

    /// Subtracts `mean` from every row and re-normalizes (an anisotropy correction).
    func centered(by mean: [Float]) -> VectorIndex {
        var rows: [[Float]] = []
        for i in 0..<count {
            let row = Array(data[i * dims..<(i + 1) * dims])
            rows.append(l2normalize(zip(row, mean).map { $0 - $1 }))
        }
        return VectorIndex(vectors: rows, dims: dims)
    }

    var mean: [Float] {
        var m = [Float](repeating: 0, count: dims)
        for i in 0..<count {
            data.withUnsafeBufferPointer { p in
                vDSP_vadd(m, 1, p.baseAddress! + i * dims, 1, &m, 1, vDSP_Length(dims))
            }
        }
        return m.map { $0 / Float(count) }
    }
}

// MARK: - Keyword search (FTS5 BM25 through GRDB)

private let stopwords: Set<String> = [
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

/// Builds an FTS5 OR query from free text: lowercased word tokens minus stopwords, each quoted.
func ftsQuery(_ text: String) -> String? {
    var seen = Set<String>()
    let terms = text.lowercased()
        .split { !($0.isLetter || $0.isNumber) }
        .map(String.init)
        .filter { $0.count > 1 && !stopwords.contains($0) && seen.insert($0).inserted }
    return terms.isEmpty ? nil : terms.map { "\"\($0)\"" }.joined(separator: " OR ")
}

final class KeywordIndex {
    let db: DatabasePool
    let tokenizer: String
    let path: URL

    /// `tokenizer` is the FTS5 tokenize argument, e.g. "unicode61 remove_diacritics 2".
    init(docs: [Doc], tokenizer: String) throws {
        self.tokenizer = tokenizer
        path = FileManager.default.temporaryDirectory.appendingPathComponent("search-spike-\(UUID().uuidString).sqlite")
        db = try DatabasePool(path: path.path)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE memory (id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL);
                CREATE VIRTUAL TABLE memory_fts USING fts5(
                  title, body, content='memory', content_rowid='rowid', tokenize='\(tokenizer)');
                CREATE TRIGGER memory_ai AFTER INSERT ON memory BEGIN
                  INSERT INTO memory_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
                END;
                """)
            for d in docs {
                try db.execute(sql: "INSERT INTO memory (id, title, body) VALUES (?, ?, ?)", arguments: [d.id, d.title, d.body])
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: path) }

    /// Positive BM25 scores (higher is better) for every match, keyed by memory id.
    func search(_ text: String) throws -> [String: Float] {
        guard let q = ftsQuery(text) else { return [:] }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT memory.id AS id, -bm25(memory_fts) AS s
                FROM memory_fts JOIN memory ON memory.rowid = memory_fts.rowid
                WHERE memory_fts MATCH ?
                """, arguments: [q])
            var out: [String: Float] = [:]
            for r in rows { out[r["id"]] = Float(r["s"] as Double) }
            return out
        }
    }
}

/// Normalizes BM25 by the best score of the query, giving keyword ∈ [0,1].
func normalizeKeyword(_ raw: [String: Float]) -> [String: Float] {
    guard let best = raw.values.max(), best > 0 else { return [:] }
    return raw.mapValues { $0 / best }
}
