import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// CI sets FUNES_REQUIRE_EMBEDDING_MODEL=1, so a missing model fails there instead of skipping.
@Test func theEmbeddingModelIsFetchedWhenRequired() {
    if ProcessInfo.processInfo.environment["FUNES_REQUIRE_EMBEDDING_MODEL"] == "1" {
        #expect(Fixtures.modelAvailable, Fixtures.modelMissing)
    }
}

/// The bundled model and its tokenizer (ADR-0016). Skipped when the model isn't fetched.
@Suite(.enabled(if: Fixtures.modelAvailable, Fixtures.modelMissing))
struct EmbeddingModelTests {
    struct TokenizerFixture: Decodable {
        struct Item: Decodable { let text: String; let ids: [Int32] }
        let items: [Item]
    }

    @Test func tokenizerMatchesHuggingFaceOnEveryFixtureText() throws {
        let dir = try #require(Fixtures.modelDirectory)
        let tokenizer = try WordPieceTokenizer(vocabURL: dir.appending(path: "vocab.txt"))
        let fixture = try JSONDecoder().decode(TokenizerFixture.self, from: Data(contentsOf: Fixtures.url("tokenizer-bge-small")))
        #expect(fixture.items.count == 268)
        for item in fixture.items {
            #expect(tokenizer.encode(item.text) == item.ids, "\(item.text.prefix(60))")
        }
    }

    /// The embedding text the fixture was made with is the one the indexer builds.
    @Test func tokenizerFixtureUsesTheIndexersEmbeddingText() throws {
        let fixture = try JSONDecoder().decode(TokenizerFixture.self, from: Data(contentsOf: Fixtures.url("tokenizer-bge-small")))
        let names = Dictionary(uniqueKeysWithValues: MemoryCategory.builtins.map { ($0.key, $0.name) })
        let m = try Fixtures.memories()[0]
        let text = EmbeddingIndexer.embeddingText(title: m.title, kind: MemoryKind(rawValue: m.kind)!,
                                                  categoryNames: m.categories.map { names[$0]! }, body: m.body)
        #expect(fixture.items[0].text == text)
    }

    struct Reference: Decodable {
        struct Item: Decodable { let text: String; let vector: [Float] }
        let items: [Item]
    }

    /// Core ML on the CPU against sentence-transformers' fp32 vectors (scripts/embedding_model/reference.json).
    @Test func coreMLMatchesTheReferenceVectors() async throws {
        let embedder = try BundledBGEEmbedder(directory: #require(Fixtures.modelDirectory))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: Fixtures.repoRoot
            .appending(path: "scripts/embedding_model/reference.json")))
        for item in reference.items {
            // The reference texts already carry the query prefix where they are queries.
            let v = try #require(try await embedder.embed([item.text], as: .document).first)
            let cos = zip(v, l2normalize(item.vector)).map(*).reduce(0, +)
            #expect(cos > 0.999, "\(item.text.prefix(40)): \(cos)")
            #expect(v.count == 384)
        }
        let q = try await embedder.embed(["Plan a week of dinners for me"], as: .query)
        let qRef = try await embedder.embed([BundledBGEEmbedder.queryPrefix + "Plan a week of dinners for me"], as: .document)
        #expect(q == qRef)
    }
}
