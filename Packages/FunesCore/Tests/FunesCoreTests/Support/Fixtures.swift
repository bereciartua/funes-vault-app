import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// The Spike 2 / 2b benchmark fixtures and the bundled model, when fetched.
enum Fixtures {
    struct FixtureMemory: Decodable {
        let id: String
        let title: String
        let body: String
        let kind: String
        let categories: [String]
        let sensitivity: String
    }
    struct Query: Decodable {
        let id: String
        let query: String
        let keywords: [String]?
        let categories: [String]?
        let relevant: [String]
    }
    private struct MemoriesFile: Decodable { let memories: [FixtureMemory] }
    private struct QueriesFile: Decodable { let queries: [Query] }

    static func url(_ name: String, _ ext: String = "json") throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "fixtures") else {
            throw VaultError.notFound
        }
        return url
    }

    static func memories() throws -> [FixtureMemory] {
        try JSONDecoder().decode(MemoriesFile.self, from: Data(contentsOf: url("memories-200"))).memories
    }

    static func queries(expanded: Bool) throws -> [Query] {
        try JSONDecoder().decode(QueriesFile.self, from: Data(contentsOf: url(expanded ? "queries-30-expanded" : "queries-30"))).queries
    }

    /// Where `scripts/fetch_embedding_model.sh` caches the model: FUNES_EMBEDDING_MODEL_DIR, or the
    /// default cache folder.
    static let modelDirectory: URL? = {
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["FUNES_EMBEDDING_MODEL_DIR"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: env["FUNES_MODEL_CACHE"] ?? (NSHomeDirectory() + "/Library/Caches/com.funesvault.dev"))
                .appending(path: "bge-small-en-v1.5-5c38ec7"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: BundledBGEEmbedder.compiledModelName).path) }
    }()

    static var modelAvailable: Bool { modelDirectory != nil }
    static let modelMissing: Comment = "The embedding model isn't fetched: run sh scripts/fetch_embedding_model.sh"

    /// The repository root, from this file's location.
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The 200 fixture memories in a fresh vault. Returns the vault and fixture id → memory id.
    static func benchmarkVault() throws -> (TestVault, [String: UUID]) {
        let v = try TestVault()
        var ids: [String: UUID] = [:]
        for (i, m) in try memories().enumerated() {
            let memory = try v.store.createMemory(MemoryDraft(
                title: m.title, body: m.body, kind: MemoryKind(rawValue: m.kind)!, categoryKeys: m.categories,
                sensitivity: Sensitivity(name: m.sensitivity)!), now: t0.plus(minutes: Double(i)))
            ids[m.id] = memory.id
        }
        return (v, ids)
    }
}
