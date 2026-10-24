import Foundation
import FunesProtocol
import GRDB
import os
import Synchronization

/// A provider embedding model Funes knows (Phase 6c benchmark, spike results): its dimensions,
/// role prefixes and built-in thresholds. Matched on the model name, whatever the provider calls
/// it (`qwen3-embedding:0.6b` in Ollama, `text-embedding-qwen3-embedding-0.6b` in LM Studio).
public struct KnownEmbeddingModel: Sendable, Hashable {
    /// The name Settings suggests.
    public let name: String
    /// Every one of these must appear in the lowercased model name.
    let tokens: [String]
    public let dimensions: Int?
    public let queryPrefix: String
    public let documentPrefix: String
    /// Built-in thresholds, from the benchmark; nil: uncalibrated (top-K until Calibrate).
    public let vaultThreshold: Float?
    public let retrievalThreshold: Float?

    func info(id: String) -> EmbeddingModelInfo? {
        guard let dimensions, let vaultThreshold, let retrievalThreshold else { return nil }
        return EmbeddingModelInfo(id: id, dimensions: dimensions, vaultThreshold: vaultThreshold, retrievalThreshold: retrievalThreshold)
    }
}

public enum EmbeddingCatalog {
    /// Qwen3-Embedding's queries carry a task instruction; its documents nothing.
    static let qwenInstruction = "Instruct: Given a task that an AI assistant received, retrieve the user's personal notes that help with the task\nQuery:"

    /// The models with built-in thresholds passed the Phase 6c gate (spike results, Phase 6c.1).
    /// The others only get their prefixes, and are uncalibrated.
    public static let models: [KnownEmbeddingModel] = [
        KnownEmbeddingModel(name: "text-embedding-3-small", tokens: ["text-embedding-3-small"], dimensions: 1536,
                            queryPrefix: "", documentPrefix: "", vaultThreshold: 0.20, retrievalThreshold: 0.25),
        KnownEmbeddingModel(name: "text-embedding-3-large", tokens: ["text-embedding-3-large"], dimensions: 3072,
                            queryPrefix: "", documentPrefix: "", vaultThreshold: 0.18, retrievalThreshold: 0.22),
        KnownEmbeddingModel(name: "qwen3-embedding:0.6b", tokens: ["qwen3-embedding", "0.6b"], dimensions: 1024,
                            queryPrefix: qwenInstruction, documentPrefix: "", vaultThreshold: 0.24, retrievalThreshold: 0.28),
        KnownEmbeddingModel(name: "qwen3-embedding", tokens: ["qwen3-embedding"], dimensions: nil,
                            queryPrefix: qwenInstruction, documentPrefix: "", vaultThreshold: nil, retrievalThreshold: nil),
        KnownEmbeddingModel(name: "nomic-embed-text", tokens: ["nomic-embed-text"], dimensions: 768,
                            queryPrefix: "search_query: ", documentPrefix: "search_document: ", vaultThreshold: nil,
                            retrievalThreshold: nil),
    ]

    /// The first entry whose tokens all appear in `model` (lowercased).
    public static func lookup(_ model: String) -> KnownEmbeddingModel? {
        let name = model.lowercased()
        return models.first { $0.tokens.allSatisfy(name.contains) }
    }

    /// Whether a model name looks like an embedding-only model (it can't answer chat requests):
    /// one in the catalog, or a name with "embed" or "bge" in it, as most are named.
    public static func isEmbeddingModel(_ model: String) -> Bool {
        let name = model.lowercased()
        return lookup(model) != nil || name.contains("embed") || name.contains("bge")
    }

    /// The suggestions Settings offers for a provider: OpenAI's for a cloud endpoint, Qwen3 for a
    /// local server.
    public static func suggestions(cloud: Bool) -> [String] {
        cloud ? ["text-embedding-3-small", "text-embedding-3-large"] : ["qwen3-embedding:0.6b"]
    }
}

/// The second index (ADR-0023, model providers §7): a provider model's vectors for the memories
/// within the cloud limit (every memory for a local server), next to the bundled bge-small
/// vectors, which stay on every memory.
///
/// - Vectors are computed in the background, in batches, through `ModelRouter.embed`; a pass picks
///   up where the last stopped (resumable), waits out a 429's `retry-after`, and reports progress.
/// - Each pass also deletes the vectors of memories that left the limit (it dropped, or their
///   sensitivity rose) or now match the secret scanner.
/// - Search uses the index only once a pass has embedded every eligible memory for this cloud limit
///   (`isComplete`); until then it stays bge-only.
public final class ProviderEmbeddingIndexer: Sendable {
    public let store: VaultStore
    public let provider: any EmbeddingProvider
    public let cloudLimit: CloudLimit
    public let index: EmbeddingIndex
    /// Texts per call: 64 for a local server, 96 for a cloud provider (model providers §7).
    public let batchSize: Int

    public enum State: Sendable, Equatable {
        case idle
        case running
        /// Rate-limited: the pass resumes at this time.
        case waiting(until: Date)
        /// The last pass failed (status codes only); the next change or Retry runs another.
        case failed(ProviderError)
        /// Every eligible memory has a vector.
        case complete
    }

    public struct Progress: Sendable, Equatable {
        /// Eligible memories with a current vector, and all eligible memories.
        public var done = 0
        public var total = 0
        public var state = State.idle
    }

    static let metaKey = "provider_embeddings"
    /// The longest input sent: about 256 tokens, as for bge (memory processing §2).
    static let maxCharacters = 1_000
    /// The longest wait for a rate limit before the pass gives up until the next run.
    static let maxWait: TimeInterval = 300

    private struct Completion: Codable, Equatable { var modelID: String; var limit: String }
    private struct RunState { var running = false, again = false }
    private let run = Mutex(RunState())
    private let state = Mutex(Progress())
    private let complete = Mutex(false)
    private let usage = Mutex(ProviderUsage())
    private let queries = Mutex<[String: [Float]]>([:])
    private let onProgress: (@Sendable (Progress) -> Void)?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let logger = Logger(subsystem: "com.funesvault.mac", category: "embeddings")

    public init(store: VaultStore, provider: any EmbeddingProvider, cloudLimit: CloudLimit,
                batchSize: Int? = nil, onProgress: (@Sendable (Progress) -> Void)? = nil,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.store = store
        self.provider = provider
        self.cloudLimit = cloudLimit
        self.batchSize = batchSize ?? (provider.locality.isLocal ? 64 : 96)
        self.onProgress = onProgress
        self.sleep = sleep
        index = EmbeddingIndex(modelID: provider.model.id, dimensions: provider.model.dimensions)
    }

    public var progress: Progress { state.withLock { $0 } }
    public var isComplete: Bool { complete.withLock { $0 } }

    /// The tokens and requests since the last call, for the usage counters (FR-AI-12).
    public func takeUsage() -> ProviderUsage { usage.withLock { u in defer { u = ProviderUsage() }; return u } }

    private var limitName: String {
        switch cloudLimit {
        case let .upTo(level): level.name
        case .never: "never"
        }
    }

    /// Loads the stored vectors and whether the set was complete for this model and limit.
    public func loadIndex() throws {
        try index.load(from: store)
        let stored = try store.writer.read { db in
            JSON.decode(Completion.self, try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [Self.metaKey]))
        }
        complete.withLock { $0 = stored == Completion(modelID: provider.model.id, limit: limitName) }
    }

    /// Whether a memory may have a vector from this provider: not deleted; within the cloud limit
    /// for a cloud provider; and no secret-scanner match for anything not on this Mac.
    func eligible(sensitivity: Sensitivity, text: String) -> Bool {
        if !provider.locality.isLocal && !cloudLimit.allows(sensitivity) { return false }
        return provider.locality == .onDevice || SecretScanner.scan(text).isEmpty
    }

    /// How many memories a full pass would embed, and about how many tokens (4 characters each):
    /// the confirmation before the first one (model providers §7).
    public func estimate() async throws -> (memories: Int, tokens: Int) {
        let items = try await scan().eligible
        return (items.count, items.reduce(0) { $0 + $1.text.count } / 4)
    }

    private struct Item { let id: UUID, text: String, hash: String, sensitivity: Sensitivity }

    private func scan() async throws -> (eligible: [Item], hashes: [UUID: String], stored: Set<UUID>) {
        let modelID = provider.model.id
        return try await store.writer.read { db in
            let names = Dictionary(uniqueKeysWithValues: try CategoryStore.all(db).map { ($0.key, $0.name) })
            var hashes: [UUID: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT memory_id, content_hash FROM embedding WHERE model_id = ?", arguments: [modelID]) {
                if let id = row.uuid("memory_id") { hashes[id] = row["content_hash"] }
            }
            let ids = try String.fetchAll(db, sql: "SELECT id FROM memory WHERE status != 'deleted' ORDER BY seq")
                .compactMap(UUID.init(uuidString:))
            let items = try MemoryStore.fetch(db, ids: ids).compactMap { m -> Item? in
                let text = String(EmbeddingIndexer.embeddingText(title: m.title, kind: m.kind,
                                                                 categoryNames: m.categoryKeys.map { names[$0] ?? $0 },
                                                                 body: m.body).prefix(Self.maxCharacters))
                guard eligible(sensitivity: m.sensitivity, text: text) else { return nil }
                return Item(id: m.id, text: text, hash: EmbeddingIndexer.contentHash(text), sensitivity: m.sensitivity)
            }
            return (items, hashes, Set(hashes.keys))
        }
    }

    /// Embeds every eligible memory whose vector is missing or stale, and deletes the vectors of
    /// memories that aren't eligible any more. Concurrent calls coalesce into one more pass.
    /// Returns the number of vectors written. Cancelling keeps what's written (the next pass resumes).
    @discardableResult
    public func embedPending() async throws -> Int {
        let start = run.withLock { s -> Bool in
            if s.running { s.again = true; return false }
            s.running = true
            return true
        }
        guard start else { return 0 }
        defer { run.withLock { $0.running = false } }
        var written = 0
        do {
            repeat {
                run.withLock { $0.again = false }
                written += try await pass()
            } while run.withLock({ $0.again })
        } catch let error as ProviderError {
            update { $0.state = .failed(error) }
            logger.error("Provider embedding pass failed: \(String(describing: error), privacy: .public)") // log-safe: error code only
            throw error
        } catch {
            update { $0.state = .idle }
            throw error
        }
        return written
    }

    private func update(_ change: (inout Progress) -> Void) {
        let now = state.withLock { s in change(&s); return s }
        onProgress?(now)
    }

    private func pass() async throws -> Int {
        let modelID = provider.model.id
        let (items, hashes, stored) = try await scan()
        let keep = Set(items.map(\.id))
        let gone = stored.subtracting(keep)
        if !gone.isEmpty {
            try await store.writer.write { db in
                for id in gone {
                    try db.execute(sql: "DELETE FROM embedding WHERE memory_id = ? AND model_id = ?", arguments: [id.db, modelID])
                }
            }
            for id in gone { index.remove(id) }
        }
        let pending = items.filter { hashes[$0.id] != $0.hash || !index.contains($0.id) }
        update { $0 = Progress(done: items.count - pending.count, total: items.count, state: pending.isEmpty ? .complete : .running) }

        var written = 0
        var batchStart = 0
        var waits = 0
        while batchStart < pending.count {
            try Task.checkCancellation()
            let batch = Array(pending[batchStart..<min(batchStart + batchSize, pending.count)])
            let vectors: [[Float]], used: ProviderUsage
            do {
                (vectors, used) = try await ModelRouter.embed(batch.map { .memory($0.text, sensitivity: $0.sensitivity) },
                                                              as: .document, with: provider, cloudLimit: cloudLimit,
                                                              timeout: .seconds(60))
            } catch let ProviderError.rateLimited(retryAfter) {
                waits += 1
                guard waits <= 5 else { throw ProviderError.rateLimited(retryAfter: retryAfter) }
                let wait = min(retryAfter ?? 30, Self.maxWait)
                update { $0.state = .waiting(until: Date().addingTimeInterval(wait)) }
                try await sleep(wait)
                update { $0.state = .running }
                continue
            }
            usage.withLock { u in
                u.requests += used.requests
                u.inputTokens += used.inputTokens
            }
            guard vectors.count == batch.count, vectors.allSatisfy({ $0.count == provider.model.dimensions }) else {
                throw ProviderError.invalidOutput
            }
            try await store.writer.write { db in
                for (item, vector) in zip(batch, vectors) {
                    // The memory may have been purged meanwhile; skip it.
                    guard try Bool.fetchOne(db, sql: "SELECT 1 FROM memory WHERE id = ?", arguments: [item.id.db]) == true else { continue }
                    try db.execute(sql: """
                        INSERT INTO embedding (memory_id, model_id, dims, vector, content_hash) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT (memory_id, model_id) DO UPDATE SET dims = excluded.dims, vector = excluded.vector,
                          content_hash = excluded.content_hash
                        """, arguments: [item.id.db, modelID, vector.count, EmbeddingCodec.encode(l2normalize(vector)), item.hash])
                }
            }
            for (item, vector) in zip(batch, vectors) { index.upsert(item.id, vector) }
            written += batch.count
            batchStart += batch.count
            waits = 0
            update { $0.done += batch.count }
        }
        if !isComplete { try markComplete() }
        update { $0.state = .complete }
        return written
    }

    private func markComplete() throws {
        let value = JSON.encode(Completion(modelID: provider.model.id, limit: limitName))
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [Self.metaKey, value])
        }
        complete.withLock { $0 = true }
    }

    /// Deletes every vector of this model (the user cancelled the first pass, or removed the model):
    /// search is bge-only again (model providers §7).
    public func removeAll() throws {
        let modelID = provider.model.id
        try store.writer.write { db in
            try db.execute(sql: "DELETE FROM embedding WHERE model_id = ?", arguments: [modelID])
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [Self.metaKey])
        }
        index.clear()
        complete.withLock { $0 = false }
        update { $0 = Progress() }
    }

    /// Deletes the vectors of every other model than these (a provider model the user replaced or
    /// removed), and the completion mark unless it's for one of them.
    public static func removeOthers(store: VaultStore, keeping models: Set<String>) throws {
        try store.writer.write { db in
            let ids = Array(models)
            try db.execute(sql: "DELETE FROM embedding WHERE model_id NOT IN (\(databaseQuestionMarks(count: max(ids.count, 1))))",
                           arguments: StatementArguments(ids.isEmpty ? [""] : ids))
            let stored = JSON.decode(Completion.self, try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [metaKey]))
            if let stored, !models.contains(stored.modelID) {
                try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [metaKey])
            }
        }
    }

    /// Re-embeds after every commit that touches memories or categories. Keep the returned
    /// cancellable for as long as the observation should run.
    public func startObserving() -> AnyDatabaseCancellable {
        let observation = DatabaseRegionObservation(tracking: Table("memory"), Table("memory_category"), Table("category"))
        return observation.start(in: store.writer, onError: { [logger] _ in
            logger.error("Provider embedding observation failed")
        }, onChange: { [weak self] _ in
            guard let self else { return }
            Task { try? await self.embedPending() }
        })
    }

    /// A query's vector through the guardrails, within 10 s; nil on any failure (search falls back
    /// to bge, FR-AI-10). The last 32 queries are kept, so changing a filter doesn't re-embed.
    func queryVector(_ text: String) async -> [Float]? {
        if let cached = queries.withLock({ $0[text] }) { return cached }
        do {
            let (vectors, used) = try await ModelRouter.embed([.query(text)], as: .query, with: provider, cloudLimit: cloudLimit)
            usage.withLock { u in
                u.requests += used.requests
                u.inputTokens += used.inputTokens
            }
            guard let v = vectors.first, v.count == provider.model.dimensions else { return nil }
            queries.withLock { q in
                if q.count >= 32 { q.removeAll() }
                q[text] = v
            }
            return v
        } catch {
            logger.error("Provider query embedding failed; bge only for this search: \(String(describing: error), privacy: .public)") // log-safe: error code only
            return nil
        }
    }
}

/// **Calibrate** (model providers §8): the bundled benchmark (200 synthetic memories, 30 tasks,
/// nothing of the user's) embedded by the chosen model, and its thresholds from the cosines of the
/// non-relevant memories: retrieval at their 90th percentile, vault at the 78th, the percentiles
/// where bge-small's own thresholds sit (0.54 and 0.50 on this benchmark; it ships 0.55 and 0.50).
/// The built-in thresholds come from the same rule.
public enum EmbeddingCalibration {
    public static let retrievalPercentile = 0.90
    public static let vaultPercentile = 0.78

    struct Memory: Decodable { let id: String, title: String, body: String, kind: String, categories: [String] }
    struct Query: Decodable { let query: String, relevant: [String] }

    static func resource(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "calibration")
    }

    static func load() throws -> (memories: [Memory], queries: [Query]) {
        struct M: Decodable { let memories: [Memory] }
        struct Q: Decodable { let queries: [Query] }
        guard let m = resource("memories-200"), let q = resource("queries-30") else { throw ProviderError.unavailable }
        return (try JSONDecoder().decode(M.self, from: Data(contentsOf: m)).memories,
                try JSONDecoder().decode(Q.self, from: Data(contentsOf: q)).queries)
    }

    /// The texts a run sends: 200 memories as documents, 30 tasks as queries. About 7,000 tokens.
    public static func texts() throws -> (documents: [String], queries: [String]) {
        let (memories, queries) = try load()
        let names = Dictionary(uniqueKeysWithValues: MemoryCategory.builtins.map { ($0.key, $0.name) })
        let documents = memories.map { m in
            EmbeddingIndexer.embeddingText(title: m.title, kind: MemoryKind(rawValue: m.kind) ?? .fact,
                                           categoryNames: m.categories.map { names[$0] ?? $0 }, body: m.body)
        }
        return (documents, queries.map(\.query))
    }

    /// Runs the benchmark through `provider` and returns its thresholds (model id and dimensions
    /// from the vectors it returned).
    public static func run(_ provider: any EmbeddingProvider) async throws -> (EmbeddingModelInfo, ProviderUsage) {
        let (memories, queries) = try load()
        let (documents, tasks) = try texts()
        var used = ProviderUsage()
        var docVectors: [[Float]] = []
        for start in stride(from: 0, to: documents.count, by: 50) {
            let batch = documents[start..<min(start + 50, documents.count)].map { EmbeddingItem.synthetic($0) }
            let (v, u) = try await ModelRouter.embed(batch, as: .document, with: provider, cloudLimit: .never, timeout: .seconds(60))
            docVectors += v
            used.requests += u.requests
            used.inputTokens += u.inputTokens
        }
        let (queryVectors, u) = try await ModelRouter.embed(tasks.map { .synthetic($0) }, as: .query, with: provider,
                                                            cloudLimit: .never, timeout: .seconds(60))
        used.requests += u.requests
        used.inputTokens += u.inputTokens
        guard docVectors.count == memories.count, queryVectors.count == queries.count,
              let dims = docVectors.first?.count, dims > 0,
              (docVectors + queryVectors).allSatisfy({ $0.count == dims }) else { throw ProviderError.invalidOutput }
        let docs = docVectors.map(l2normalize)
        var others: [Float] = []
        for (query, vector) in zip(queries, queryVectors.map(l2normalize)) {
            let relevant = Set(query.relevant)
            for (memory, doc) in zip(memories, docs) where !relevant.contains(memory.id) {
                others.append(zip(vector, doc).reduce(0) { $0 + $1.0 * $1.1 })
            }
        }
        let (vault, retrieval) = thresholds(others)
        return (EmbeddingModelInfo(id: provider.model.id, dimensions: dims, vaultThreshold: vault, retrievalThreshold: retrieval), used)
    }

    /// The vault and retrieval thresholds from non-relevant cosines (linear-interpolated percentiles).
    static func thresholds(_ others: [Float]) -> (vault: Float, retrieval: Float) {
        let sorted = others.sorted()
        func percentile(_ p: Double) -> Float {
            guard !sorted.isEmpty else { return 0 }
            let rank = p * Double(sorted.count - 1)
            let lo = Int(rank.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
            return sorted[lo] + Float(rank - Double(lo)) * (sorted[hi] - sorted[lo])
        }
        return ((percentile(vaultPercentile) * 100).rounded() / 100, (percentile(retrievalPercentile) * 100).rounded() / 100)
    }
}
