import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// A provider model's stand-in: FakeEmbedder's hashed bag of words after mapping a few Spanish
/// words to English, so only it matches "la cena" to a memory about dinner. Records every text it
/// gets, and fails or rate-limits on cue.
final class TranslatingEmbedder: EmbeddingProvider {
    let id: ProviderID = "test.provider"
    let locality: Locality
    let model: EmbeddingModelInfo
    private let base = FakeEmbedder(dimensions: 48)

    struct Script {
        var texts: [String] = []
        var calls = 0
        var failing: Set<Int> = []
        var rateLimited: Set<Int> = []
        var down = false
        var hang: Set<Int> = []
    }
    let script = Mutex(Script())

    static let words = ["cena": "dinner", "jardín": "garden", "alergia": "allergy"]

    init(locality: Locality = .cloud, calibrated: Bool = true) {
        self.locality = locality
        model = calibrated
            ? EmbeddingModelInfo(id: "test.provider/translating", dimensions: 48, vaultThreshold: 0.3, retrievalThreshold: 0.3)
            : .uncalibrated(id: "test.provider/translating", dimensions: 48)
    }

    var texts: [String] { script.withLock { $0.texts } }
    var calls: Int { script.withLock { $0.calls } }

    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] {
        let (call, s) = script.withLock { s -> (Int, Script) in
            s.calls += 1
            s.texts += texts
            return (s.calls, s)
        }
        if s.down || s.failing.contains(call) { throw ProviderError.server(status: 503) }
        if s.rateLimited.contains(call) { throw ProviderError.rateLimited(retryAfter: 2) }
        if s.hang.contains(call) { try await Task.sleep(for: .seconds(60)) }
        let translated = texts.map { t in
            t.lowercased().split(separator: " ").map { Self.words[String($0)] ?? String($0) }.joined(separator: " ")
        }
        return try await base.embed(translated, as: role)
    }
}

/// Phase 6c (ADR-0023, FR-AI-11): the `/v1/embeddings` adapter, the guardrails, the second index
/// and its scoring, re-embedding, and Calibrate. No live calls.
@Suite struct ProviderEmbeddingTests {
    static func embeddingReply(_ vectors: [[Float]], reversed: Bool = false, tokens: Int = 9) -> StubURLProtocol.Reply {
        var data = vectors.enumerated().map { ["index": $0.offset, "embedding": $0.element.map(Double.init)] as [String: Any] }
        if reversed { data.reverse() }
        return .json(["data": data, "usage": ["prompt_tokens": tokens, "total_tokens": tokens]])
    }

    // MARK: Adapter

    @Test func openAIEmbeddingsContract() async throws {
        let stub = StubURLProtocol.Session { _ in Self.embeddingReply([[1, 0], [0, 1]], reversed: true) }
        let embedder = try OpenAICompatibleEmbedder(endpoint: .openAI(), model: "text-embedding-3-small", apiKey: "test-key",
                                                    session: stub.session)
        #expect(embedder.model == EmbeddingModelInfo(id: "openai/text-embedding-3-small", dimensions: 1536,
                                                     vaultThreshold: 0.20, retrievalThreshold: 0.25))
        #expect(embedder.locality == .cloud)
        let (vectors, usage) = try await embedder.embedCounting(["a", "b"], as: .document)
        #expect(vectors == [[1, 0], [0, 1]])  // reordered by index
        #expect(usage == ProviderUsage(requests: 1, inputTokens: 9))
        let sent = try #require(stub.requests.first)
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/embeddings" && sent.method == "POST")
        #expect(sent.headers["Authorization"] == "Bearer test-key")
        #expect(sent.json["model"] as? String == "text-embedding-3-small" && sent.json["encoding_format"] as? String == "float")
        #expect(sent.json["input"] as? [String] == ["a", "b"])
    }

    @Test func rolePrefixesForModelsThatUseThem() async throws {
        let stub = StubURLProtocol.Session { req in
            let n = (req.json["input"] as? [String])?.count ?? 0
            return Self.embeddingReply(Array(repeating: [1, 0], count: n))
        }
        let qwen = try OpenAICompatibleEmbedder(endpoint: .ollama(), model: "qwen3-embedding:0.6b", apiKey: nil, session: stub.session)
        #expect(qwen.locality == .localServer && qwen.model.id == "ollama/qwen3-embedding:0.6b" && qwen.model.dimensions == 1024)
        #expect(qwen.model.retrievalThreshold == 0.28 && qwen.model.vaultThreshold == 0.24)
        _ = try await qwen.embed(["plan dinners"], as: .query)
        _ = try await qwen.embed(["memory"], as: .document)
        let nomic = try OpenAICompatibleEmbedder(endpoint: .lmStudio(), model: "text-embedding-nomic-embed-text-v1.5",
                                                 apiKey: nil, session: stub.session)
        #expect(!nomic.model.isCalibrated && nomic.model.dimensions == 768)
        _ = try await nomic.embed(["q"], as: .query)
        _ = try await nomic.embed(["d"], as: .document)
        let inputs = stub.requests.map { $0.json["input"] as? [String] ?? [] }
        #expect(inputs == [[EmbeddingCatalog.qwenInstruction + "plan dinners"], ["memory"],
                           ["search_query: q"], ["search_document: d"]])
        #expect(stub.requests.allSatisfy { $0.headers["Authorization"] == nil })
    }

    @Test func unknownModelsNeedTheirDimensionsAndAreUncalibrated() throws {
        #expect(throws: ProviderError.unavailable) {
            try OpenAICompatibleEmbedder(endpoint: .ollama(), model: "mxbai-embed-large", apiKey: nil)
        }
        let e = try OpenAICompatibleEmbedder(endpoint: .ollama(), model: "mxbai-embed-large", dimensions: 1024, apiKey: nil)
        #expect(e.model == .uncalibrated(id: "ollama/mxbai-embed-large", dimensions: 1024) && !e.model.isCalibrated)
        #expect(EmbeddingCatalog.lookup("Qwen/Qwen3-Embedding-0.6B")?.retrievalThreshold == 0.28)
        #expect(EmbeddingCatalog.lookup("qwen3-embedding:4b")?.retrievalThreshold == nil)
        #expect(EmbeddingCatalog.lookup("openai/text-embedding-3-large")?.dimensions == 3072)
        #expect(throws: ProviderError.insecureEndpoint) {
            try OpenAICompatibleEmbedder(endpoint: ProviderEndpoint(id: "x", kind: .openAICompatible,
                                                                    baseURL: URL(string: "http://api.example.com/v1")!),
                                         model: "text-embedding-3-small", apiKey: "k")
        }
    }

    @Test func badEmbeddingResponses() async throws {
        let cases: [StubURLProtocol.Reply] = [
            .json(["data": [["index": 0, "embedding": [1.0, 0.0]]]]),                                  // one vector for two texts
            .json(["data": [["index": 0, "embedding": [1.0, 0.0]], ["index": 1, "embedding": [1.0]]]]), // mixed dimensions
            .json(["object": "list"]),
            .json(["error": ["message": "no"]], status: 401),
        ]
        for (reply, error) in zip(cases, [ProviderError.invalidOutput, .invalidOutput, .invalidOutput, .unauthorized]) {
            let stub = StubURLProtocol.Session { _ in reply }
            let e = try OpenAICompatibleEmbedder(endpoint: .openAI(), model: "text-embedding-3-small", apiKey: "k", session: stub.session)
            await #expect(throws: error) { try await e.embed(["a", "b"], as: .document) }
        }
    }

    // MARK: Guardrails

    @Test func theEmbeddingGuardRefusesBeforeAnyRequest() async throws {
        let cloud = TranslatingEmbedder()
        let secret = "token ghp_" + String(repeating: "x", count: 30)
        let refused: [[EmbeddingItem]] = [
            [], [.memory("fine", sensitivity: .low), .memory("health", sensitivity: .sensitive)],
            [.memory("unknown", sensitivity: nil)], [.query(secret)], [.memory(secret, sensitivity: .public)], [.synthetic(secret)],
        ]
        for items in refused {
            await #expect(throws: ProviderError.blocked) {
                try await ModelRouter.embed(items, as: .document, with: cloud, cloudLimit: .upTo(.internal))
            }
        }
        #expect(cloud.calls == 0)
        _ = try await ModelRouter.embed([.memory("work", sensitivity: .internal), .query("plan dinners"), .synthetic("tea")],
                                        as: .document, with: cloud, cloudLimit: .upTo(.internal))
        await #expect(throws: ProviderError.blocked) {
            try await ModelRouter.embed([.memory("work", sensitivity: .low)], as: .document, with: cloud, cloudLimit: .never)
        }
        // A local server isn't held to the cloud limit, but still never gets a secret.
        let local = TranslatingEmbedder(locality: .localServer)
        _ = try await ModelRouter.embed([.memory("health", sensitivity: .secret), .memory("x", sensitivity: nil)], as: .document,
                                        with: local, cloudLimit: .never)
        await #expect(throws: ProviderError.blocked) {
            try await ModelRouter.embed([.query(secret)], as: .query, with: local, cloudLimit: .never)
        }
        #expect(cloud.calls == 1 && local.calls == 1)
    }

    /// Nothing above the limit is ever embedded by a cloud provider (FR-AI-07, FR-AI-11).
    @Test func nothingAboveTheLimitReachesACloudProvider() async throws {
        let v = try TestVault()
        for level in Sensitivity.allCases {
            try v.memory("Note \(level.name)", "SENTINEL-\(level.name.uppercased()) text", sensitivity: level)
        }
        let cloud = TranslatingEmbedder()
        let indexer = ProviderEmbeddingIndexer(store: v.store, provider: cloud, cloudLimit: .upTo(.internal))
        #expect(try await indexer.estimate().memories == 3)
        #expect(try await indexer.embedPending() == 3)
        let sent = cloud.texts.joined(separator: "\n")
        for level in Sensitivity.allCases {
            #expect(sent.contains("SENTINEL-\(level.name.uppercased())") == (level <= .internal))
        }
        #expect(try v.count("SELECT count(*) FROM embedding WHERE model_id = 'test.provider/translating'") == 3)
        #expect(indexer.isComplete && indexer.progress == .init(done: 3, total: 3, state: .complete))

        // A local server embeds every memory.
        let local = TranslatingEmbedder(locality: .localServer)
        let localIndexer = ProviderEmbeddingIndexer(store: v.store, provider: local, cloudLimit: .upTo(.internal))
        try localIndexer.loadIndex()
        #expect(try await localIndexer.embedPending() == 3)  // the other 3 already have current vectors under this model id
        #expect(local.texts.joined().contains("SENTINEL-SECRET"))
    }

    @Test func providerVectorsAreDeletedWhenTheLimitDropsOrSensitivityRises() async throws {
        let v = try TestVault()
        let low = try v.memory("Coffee", "Black coffee", sensitivity: .low)
        let work = try v.memory("Harbor", "Project Harbor", sensitivity: .internal)
        let health = try v.memory("Allergy", "Peanut allergy", sensitivity: .sensitive)
        let cloud = TranslatingEmbedder()
        let wide = ProviderEmbeddingIndexer(store: v.store, provider: cloud, cloudLimit: .upTo(.sensitive))
        #expect(try await wide.embedPending() == 3)

        let narrow = ProviderEmbeddingIndexer(store: v.store, provider: cloud, cloudLimit: .upTo(.internal))
        try narrow.loadIndex()
        #expect(!narrow.isComplete)  // completed for another limit
        #expect(try await narrow.embedPending() == 0)
        #expect(narrow.isComplete && !narrow.index.contains(health.id) && narrow.index.contains(work.id))
        #expect(try v.count("SELECT count(*) FROM embedding WHERE memory_id = ?", [health.id.db]) == 0)

        try v.store.updateMemory(id: work.id, MemoryEdit(sensitivity: .restricted), now: t0)
        try await narrow.embedPending()
        #expect(!narrow.index.contains(work.id) && narrow.index.contains(low.id))
        #expect(try v.count("SELECT count(*) FROM embedding WHERE model_id = 'test.provider/translating'") == 1)

        // Removing the model deletes its vectors and keeps the others.
        let bge = EmbeddingIndexer(store: v.store, provider: FakeEmbedder())
        try await bge.embedPending()
        try narrow.removeAll()
        #expect(try v.count("SELECT count(*) FROM embedding WHERE model_id = 'test.provider/translating'") == 0)
        #expect(try v.count("SELECT count(*) FROM embedding WHERE model_id = 'fake/hash-64'") == 3 && !narrow.isComplete)
        try await narrow.embedPending()
        try ProviderEmbeddingIndexer.removeOthers(store: v.store, keeping: ["fake/hash-64"])
        #expect(try v.count("SELECT count(*) FROM embedding") == 3)
        #expect(try v.count("SELECT count(*) FROM meta WHERE key = 'provider_embeddings'") == 0)
    }

    // MARK: Re-embedding

    @Test func aFailedPassResumesWhereItStopped() async throws {
        let v = try TestVault()
        for i in 0..<5 { try v.memory("Note \(i)", "body \(i)") }
        let cloud = TranslatingEmbedder()
        cloud.script.withLock { $0.failing = [2] }
        let indexer = ProviderEmbeddingIndexer(store: v.store, provider: cloud, cloudLimit: .upTo(.internal), batchSize: 2)
        await #expect(throws: ProviderError.server(status: 503)) { try await indexer.embedPending() }
        #expect(indexer.progress == .init(done: 2, total: 5, state: .failed(.server(status: 503))) && !indexer.isComplete)
        #expect(try await indexer.embedPending() == 3)
        #expect(cloud.texts.count == 2 + 2 + 3 && indexer.isComplete)
    }

    @Test func cancellingKeepsWhatWasWritten() async throws {
        let v = try TestVault()
        for i in 0..<4 { try v.memory("Note \(i)", "body \(i)") }
        let cloud = TranslatingEmbedder()
        cloud.script.withLock { $0.hang = [2] }
        let indexer = ProviderEmbeddingIndexer(store: v.store, provider: cloud, cloudLimit: .upTo(.internal), batchSize: 2)
        let task = Task { try await indexer.embedPending() }
        for _ in 0..<200 where cloud.calls < 2 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(indexer.index.count == 2 && !indexer.isComplete)
        let reloaded = ProviderEmbeddingIndexer(store: v.store, provider: cloud, cloudLimit: .upTo(.internal), batchSize: 2)
        try reloaded.loadIndex()
        #expect(reloaded.index.count == 2 && !reloaded.isComplete)
        #expect(try await reloaded.embedPending() == 2 && reloaded.isComplete)
    }

    @Test func rateLimitsAreWaitedOut() async throws {
        let v = try TestVault()
        for i in 0..<3 { try v.memory("Note \(i)", "body \(i)") }
        let cloud = TranslatingEmbedder()
        cloud.script.withLock { $0.rateLimited = [1] }
        let waits = Mutex<[TimeInterval]>([])
        let states = Mutex<[ProviderEmbeddingIndexer.State]>([])
        let indexer = ProviderEmbeddingIndexer(store: v.store, provider: cloud, cloudLimit: .upTo(.internal),
                                               onProgress: { p in states.withLock { $0.append(p.state) } },
                                               sleep: { t in waits.withLock { $0.append(t) } })
        #expect(try await indexer.embedPending() == 3)
        #expect(waits.withLock { $0 } == [2])
        #expect(states.withLock { $0 }.contains { if case .waiting = $0 { true } else { false } })
        cloud.script.withLock { $0.rateLimited = Set(2...20) }
        try v.memory("Another", "note")
        await #expect(throws: ProviderError.rateLimited(retryAfter: 2)) { try await indexer.embedPending() }
    }

    // MARK: Search with the second index

    /// A vault where only the provider matches "la cena" (Spanish) to the dinner memory, and the
    /// allergy is above the cloud limit.
    struct Scene {
        let v: TestVault
        let dinner: Memory, allergy: Memory, garden: Memory
        let bge: EmbeddingIndexer
        let provider: TranslatingEmbedder
        let indexer: ProviderEmbeddingIndexer
        let search: SearchService

        init(calibrated: Bool = true, embedsAgentTasks: Bool = true) async throws {
            v = try TestVault()
            dinner = try v.memory("Dinner", "pasta for dinner on weekdays")
            allergy = try v.memory("Allergy", "peanut allergy, carry the pen", categories: ["health"], sensitivity: .sensitive)
            garden = try v.memory("Garden", "tomatoes and roses in the garden")
            for i in 0..<12 { try v.memory("Filler \(i)", "unrelated note number \(i) about filler") }
            bge = EmbeddingIndexer(store: v.store, provider: FakeEmbedder())
            try await bge.embedPending()
            provider = TranslatingEmbedder(calibrated: calibrated)
            indexer = ProviderEmbeddingIndexer(store: v.store, provider: provider, cloudLimit: .upTo(.internal))
            search = SearchService(store: v.store, indexer: bge)
            search.secondIndex = SecondIndex(indexer: indexer, embedsAgentTasks: embedsAgentTasks)
        }
    }

    @Test func searchStaysBgeOnlyUntilTheSetIsComplete() async throws {
        let s = try await Scene()
        #expect(try await s.search.retrieve(task: "ideas para la cena").isEmpty)
        #expect(s.provider.calls == 0)  // incomplete: the provider isn't asked

        try await s.indexer.embedPending()
        let hits = try await s.search.retrieve(task: "ideas para la cena")
        #expect(hits.first?.memoryID == s.dinner.id)
        // The allergy has no provider vector, and is still found with bge.
        #expect(!s.indexer.index.contains(s.allergy.id))
        let allergy = try await s.search.retrieve(task: "peanut allergy pen")
        let bgeQuery = try await FakeEmbedder().embed(["peanut allergy pen"], as: .query)[0]
        #expect(allergy.first?.memoryID == s.allergy.id && allergy.first?.cosine == s.bge.index.cosines(bgeQuery)[s.allergy.id])
        #expect(!s.provider.texts.contains { $0.contains("carry the pen") })
        #expect(try await s.search.vaultSearch("la cena", now: t0).first?.memoryID == s.dinner.id)
    }

    @Test func aProviderFailureFallsBackToBge() async throws {
        let s = try await Scene()
        try await s.indexer.embedPending()
        s.provider.script.withLock { $0.down = true }
        #expect(try await s.search.retrieve(task: "ideas para el jardín").isEmpty)
        let bgeOnly = SearchService(store: s.v.store, indexer: s.bge)
        #expect(try await s.search.retrieve(task: "tomatoes roses").map(\.memoryID)
            == bgeOnly.retrieve(task: "tomatoes roses").map(\.memoryID))
    }

    @Test func agentTasksStayOffTheCloudModelWhenSwitchedOff() async throws {
        let s = try await Scene(embedsAgentTasks: false)
        try await s.indexer.embedPending()
        let calls = s.provider.calls
        #expect(try await s.search.retrieve(task: "ideas para la cena").isEmpty)
        #expect(s.provider.calls == calls)
        #expect(try await s.search.vaultSearch("la cena", now: t0).first?.memoryID == s.dinner.id)
        #expect(s.provider.calls == calls + 1)
        _ = try await s.search.vaultSearch("la cena", now: t0)  // cached
        #expect(s.provider.calls == calls + 1)
        // A local server always embeds agents' tasks.
        let local = ProviderEmbeddingIndexer(store: s.v.store, provider: TranslatingEmbedder(locality: .localServer),
                                             cloudLimit: .upTo(.internal))
        #expect(SecondIndex(indexer: local, embedsAgentTasks: false).embedsAgentTasks)
    }

    @Test func uncalibratedModelsKeepTheirTopTen() async throws {
        let s = try await Scene(calibrated: false)
        try await s.indexer.embedPending()
        let hits = try await s.search.retrieveAll(task: "ideas para la cena")
        #expect(hits.first?.memoryID == s.dinner.id)
        let providerKept = hits.filter { s.indexer.index.contains($0.memoryID) && $0.keyword < SearchService.defaultKeywordFloor }
        #expect(providerKept.count <= EmbeddingModelInfo.topK)
    }

    // MARK: Calibrate

    @Test func calibrationThresholdsFromTheBundledBenchmark() async throws {
        let (documents, queries) = try EmbeddingCalibration.texts()
        #expect(documents.count == 200 && queries.count == 30)
        let (info, usage) = try await EmbeddingCalibration.run(TranslatingEmbedder(calibrated: false))
        #expect(info.id == "test.provider/translating" && info.dimensions == 48 && info.isCalibrated)
        #expect(info.vaultThreshold <= info.retrievalThreshold && usage.requests == 5)
        let others = (0...100).map { Float($0) / 100 }
        #expect(EmbeddingCalibration.thresholds(others) == (vault: 0.78, retrieval: 0.90))
        // The bundled copy is the test fixture.
        for name in ["memories-200", "queries-30"] {
            let bundled = try #require(EmbeddingCalibration.resource(name))
            #expect(try Data(contentsOf: bundled) == Data(contentsOf: Fixtures.url(name)))
        }
    }

    /// The rule gives bge-small its own thresholds back (it ships 0.50 and 0.55).
    @Test(.enabled(if: Fixtures.modelAvailable, Fixtures.modelMissing))
    func calibratingBgeGivesItsShippedThresholds() async throws {
        let bge = try BundledBGEEmbedder(directory: try #require(Fixtures.modelDirectory))
        let (info, _) = try await EmbeddingCalibration.run(bge)
        #expect(info.vaultThreshold == 0.50 && abs(info.retrievalThreshold - 0.54) <= 0.01)
    }
}

/// One real call to OpenAI's embeddings with two made-up texts (FUNES_LIVE_OPENAI=1 and
/// OPENAI_API_KEY; off in test.sh and CI). Checks the adapter against the live API.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FUNES_LIVE_OPENAI"] == "1"
      && ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil))
func liveOpenAIEmbeddings() async throws {
    let key = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
    for (model, dims) in [("text-embedding-3-small", 1536), ("text-embedding-3-large", 3072)] {
        let e = try OpenAICompatibleEmbedder(endpoint: .openAI(), model: model, apiKey: key)
        let (vectors, usage) = try await ModelRouter.embed([.synthetic("Prefers green tea in the afternoon."),
                                                            .query("What tea do I like?")], as: .document, with: e,
                                                           cloudLimit: .upTo(.internal))
        #expect(vectors.count == 2 && vectors.allSatisfy { $0.count == dims } && usage.inputTokens > 0)
    }
}
