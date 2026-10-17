import Accelerate
import CryptoKit
import Foundation
import FunesProtocol
import GRDB
import os
import Synchronization

/// All vectors of one embedding model in memory, as a row-major N × d matrix: a query is one
/// `vDSP_mmul` (under 1 ms at 10,000 × 384; memory processing §2). No approximate index.
public final class EmbeddingIndex: Sendable {
    public let modelID: String
    public let dimensions: Int

    private struct State {
        var rows: [UUID: Int] = [:]
        var ids: [UUID] = []
        var data: [Float] = []
    }
    private let state = Mutex(State())

    public init(modelID: String, dimensions: Int) {
        self.modelID = modelID
        self.dimensions = dimensions
    }

    public var count: Int { state.withLock { $0.ids.count } }

    public func contains(_ id: UUID) -> Bool { state.withLock { $0.rows[id] != nil } }

    /// Adds or replaces a vector (normalized here).
    public func upsert(_ id: UUID, _ vector: [Float]) {
        precondition(vector.count == dimensions, "vector dimensions")
        let v = l2normalize(vector)
        state.withLock { s in
            if let row = s.rows[id] {
                s.data.replaceSubrange(row * dimensions..<(row + 1) * dimensions, with: v)
            } else {
                s.rows[id] = s.ids.count
                s.ids.append(id)
                s.data.append(contentsOf: v)
            }
        }
    }

    public func remove(_ id: UUID) {
        state.withLock { s in
            guard let row = s.rows.removeValue(forKey: id) else { return }
            let last = s.ids.count - 1
            if row != last {
                let moved = s.ids[last]
                s.ids[row] = moved
                s.rows[moved] = row
                s.data.replaceSubrange(row * dimensions..<(row + 1) * dimensions,
                                       with: s.data[last * dimensions..<(last + 1) * dimensions])
            }
            s.ids.removeLast()
            s.data.removeLast(dimensions)
        }
    }

    /// The cosine between `query` and every indexed vector (vectors are normalized, so a dot product).
    public func cosines(_ query: [Float]) -> [UUID: Float] {
        let q = l2normalize(query)
        guard q.count == dimensions else { return [:] }
        return state.withLock { s in
            guard !s.ids.isEmpty else { return [:] }
            var out = [Float](repeating: 0, count: s.ids.count)
            vDSP_mmul(s.data, 1, q, 1, &out, 1, vDSP_Length(s.ids.count), 1, vDSP_Length(dimensions))
            var result: [UUID: Float] = [:]
            result.reserveCapacity(s.ids.count)
            for (i, id) in s.ids.enumerated() { result[id] = out[i] }
            return result
        }
    }

    /// Replaces the index with this model's stored vectors.
    public func load(from store: VaultStore) throws {
        let rows = try store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT memory_id, vector FROM embedding WHERE model_id = ? AND dims = ?",
                             arguments: [modelID, dimensions])
        }
        state.withLock { $0 = State() }
        for row in rows {
            guard let id = row.uuid("memory_id"), let blob: Data = row["vector"] else { continue }
            upsert(id, EmbeddingCodec.decode(blob))
        }
    }
}

/// Float32 little-endian blobs (storage §2).
enum EmbeddingCodec {
    static func encode(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 4)
        for x in v { withUnsafeBytes(of: x.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func decode(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count - 3, by: 4).map { i in
            let bits = UInt32(data[data.startIndex + i]) | UInt32(data[data.startIndex + i + 1]) << 8
                | UInt32(data[data.startIndex + i + 2]) << 16 | UInt32(data[data.startIndex + i + 3]) << 24
            return Float(bitPattern: bits)
        }
    }
}

/// Keeps every non-deleted memory's vector current for one embedding provider (FR-AI-01): computes
/// missing or stale vectors in the background (a vector is stale when its content hash or model id
/// differs), stores them, and updates the in-memory index. Search treats a memory without a vector
/// as semantic 0 until then.
public final class EmbeddingIndexer: Sendable {
    public let store: VaultStore
    public let provider: any EmbeddingProvider
    public let index: EmbeddingIndex

    private struct RunState { var running = false, again = false }
    private let run = Mutex(RunState())
    private let logger = Logger(subsystem: "com.funesvault.mac", category: "embeddings")

    public init(store: VaultStore, provider: any EmbeddingProvider) {
        self.store = store
        self.provider = provider
        index = EmbeddingIndex(modelID: provider.model.id, dimensions: provider.model.dimensions)
    }

    /// The text a memory is embedded as: `title \n kind \n category names \n body` (memory processing §2).
    public static func embeddingText(title: String, kind: MemoryKind, categoryNames: [String], body: String) -> String {
        "\(title)\n\(kind.words)\n\(categoryNames.joined(separator: ", "))\n\(body)"
    }

    static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Loads the stored vectors into the index.
    public func loadIndex() throws { try index.load(from: store) }

    /// Embeds every non-deleted memory whose vector is missing or stale, in batches. Concurrent
    /// calls coalesce into one more pass. Returns the number of vectors written.
    @discardableResult
    public func embedPending(batchSize: Int = 64) async throws -> Int {
        let start = run.withLock { s -> Bool in
            if s.running { s.again = true; return false }
            s.running = true
            return true
        }
        guard start else { return 0 }
        var written = 0
        do {
            repeat {
                run.withLock { $0.again = false }
                written += try await pass(batchSize: batchSize)
            } while run.withLock({ $0.again })
        } catch {
            run.withLock { $0.running = false }
            logger.error("Embedding pass failed")
            throw error
        }
        run.withLock { $0.running = false }
        return written
    }

    private struct Pending { let id: UUID, text: String, hash: String }

    private func pass(batchSize: Int) async throws -> Int {
        let modelID = provider.model.id
        let pending: [Pending] = try await store.writer.read { db in
            let names = Dictionary(uniqueKeysWithValues: try CategoryStore.all(db).map { ($0.key, $0.name) })
            let hashes = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                SELECT memory_id, content_hash FROM embedding WHERE model_id = ?
                """, arguments: [modelID]).compactMap { row in row.uuid("memory_id").map { ($0, row["content_hash"] as String) } })
            let ids = try String.fetchAll(db, sql: "SELECT id FROM memory WHERE status != 'deleted' ORDER BY seq")
                .compactMap(UUID.init(uuidString:))
            return try MemoryStore.fetch(db, ids: ids).compactMap { m in
                let text = Self.embeddingText(title: m.title, kind: m.kind, categoryNames: m.categoryKeys.map { names[$0] ?? $0 },
                                              body: m.body)
                let hash = Self.contentHash(text)
                return hashes[m.id] == hash && index.contains(m.id) ? nil : Pending(id: m.id, text: text, hash: hash)
            }
        }
        var written = 0
        for batchStart in stride(from: 0, to: pending.count, by: batchSize) {
            let batch = Array(pending[batchStart..<min(batchStart + batchSize, pending.count)])
            let vectors = try await provider.embed(batch.map(\.text), as: .document)
            guard vectors.count == batch.count, vectors.allSatisfy({ $0.count == provider.model.dimensions }) else {
                throw EmbeddingIndexerError.badVectors
            }
            try await store.writer.write { db in
                for (item, vector) in zip(batch, vectors) {
                    // The memory may have been purged meanwhile; skip it.
                    guard try Bool.fetchOne(db, sql: "SELECT 1 FROM memory WHERE id = ?", arguments: [item.id.db]) == true else {
                        continue
                    }
                    try db.execute(sql: """
                        INSERT INTO embedding (memory_id, model_id, dims, vector, content_hash) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT (memory_id, model_id) DO UPDATE SET dims = excluded.dims, vector = excluded.vector,
                          content_hash = excluded.content_hash
                        """, arguments: [item.id.db, modelID, vector.count, EmbeddingCodec.encode(l2normalize(vector)), item.hash])
                }
            }
            for (item, vector) in zip(batch, vectors) { index.upsert(item.id, vector) }
            written += batch.count
        }
        return written
    }

    /// Re-embeds after every commit that touches memories or categories ("update on change").
    /// Keep the returned cancellable for as long as the observation should run.
    public func startObserving() -> AnyDatabaseCancellable {
        let observation = DatabaseRegionObservation(tracking: Table("memory"), Table("memory_category"), Table("category"))
        return observation.start(in: store.writer, onError: { [logger] _ in
            logger.error("Embedding observation failed")
        }, onChange: { [weak self] _ in
            guard let self else { return }
            Task { try? await self.embedPending() }
        })
    }
}

public enum EmbeddingIndexerError: Error { case badVectors }
