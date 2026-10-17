import Accelerate
import CoreML
import Foundation
import Synchronization

/// Where a model runs, for the guardrails and the locality badge (model providers §2).
public enum Locality: String, Sendable, Codable, CaseIterable {
    case onDevice = "on_device"
    case localServer = "local_server"
    case appleCloud = "apple_cloud"
    case cloud

    /// Whether text sent to this provider leaves the Mac's control (the guardrails apply).
    public var isLocal: Bool { self == .onDevice || self == .localServer }
}

/// A stable provider id, e.g. `funes.bundled`, `apple.foundation`, `openai`, `anthropic`.
public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public static let bundled: ProviderID = "funes.bundled"
}

/// Whether a text is a search query or a memory: models like bge prefix queries.
public enum EmbeddingRole: Sendable {
    case query, document
}

/// A model that turns texts into vectors (model providers §3). v0.1 has one, the bundled
/// bge-small; other providers come later (FR-AI-11).
public protocol EmbeddingProvider: Sendable {
    var id: ProviderID { get }
    var locality: Locality { get }
    /// The model id stored with every vector, its dimensions and thresholds.
    var model: EmbeddingModelInfo { get }
    /// One vector per text. Funes L2-normalizes them after return.
    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]]
}

func l2normalize(_ v: [Float]) -> [Float] {
    var norm: Float = 0
    vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
    norm = norm.squareRoot()
    guard norm > 0 else { return v }
    var out = [Float](repeating: 0, count: v.count)
    var divisor = norm
    vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
    return out
}

/// The bundled `bge-small-en-v1.5` Core ML model (ADR-0016): an ML Program (int8 weights, fp16
/// compute) with CLS pooling
/// and L2 normalization inside, run on the CPU only (faster than the Neural Engine or GPU for this
/// model, which re-specialize between input lengths).
public final class BundledBGEEmbedder: EmbeddingProvider {
    public let id = ProviderID.bundled
    public let locality = Locality.onDevice
    public let model = EmbeddingModelInfo.bundled

    /// bge's retrieval instruction, prefixed to queries only.
    public static let queryPrefix = "Represent this sentence for searching relevant passages: "
    public static let compiledModelName = "bge-small-en-v1.5.mlmodelc"
    public static let vocabularyName = "vocab.txt"
    static let lengths = [16, 32, 64, 128, 256]

    let tokenizer: WordPieceTokenizer
    // Predictions are serialized; one is about 4 ms.
    private let mlModel: Mutex<MLModel>

    public enum LoadError: Error { case missingFiles }

    /// Loads `bge-small-en-v1.5.mlmodelc` and `vocab.txt` from `directory` (the app bundle's
    /// resources, or the cache `scripts/fetch_embedding_model.sh` writes).
    public convenience init(directory: URL) throws {
        try self.init(compiledModelURL: directory.appending(path: Self.compiledModelName),
                      vocabURL: directory.appending(path: Self.vocabularyName))
    }

    public init(compiledModelURL: URL, vocabURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: compiledModelURL.path), fm.fileExists(atPath: vocabURL.path) else {
            throw LoadError.missingFiles
        }
        tokenizer = try WordPieceTokenizer(vocabURL: vocabURL)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        mlModel = Mutex(try MLModel(contentsOf: compiledModelURL, configuration: config))
    }

    public func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] {
        try texts.map { try embedOne(role == .query ? Self.queryPrefix + $0 : $0) }
    }

    func embedOne(_ text: String) throws -> [Float] {
        let ids = tokenizer.encode(text, maxLength: Self.lengths.last!)
        let n = Self.lengths.first { $0 >= ids.count } ?? Self.lengths.last!
        let vector: [Float] = try mlModel.withLock { model in
            let idArray = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
            let maskArray = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
            let ip = idArray.dataPointer.bindMemory(to: Int32.self, capacity: n)
            let mp = maskArray.dataPointer.bindMemory(to: Int32.self, capacity: n)
            for i in 0..<n {
                ip[i] = i < ids.count ? ids[i] : 0
                mp[i] = i < ids.count ? 1 : 0
            }
            let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": idArray, "attention_mask": maskArray])
            guard let e = try model.prediction(from: input).featureValue(for: "embedding")?.multiArrayValue else {
                throw LoadError.missingFiles
            }
            var v = [Float](repeating: 0, count: e.count)
            for i in 0..<e.count { v[i] = e[i].floatValue }
            return v
        }
        return l2normalize(vector)
    }
}

/// A deterministic stand-in for tests: a hashed bag of words, so texts that share words are
/// similar. Not a semantic model.
public struct FakeEmbedder: EmbeddingProvider {
    public let id: ProviderID = "funes.fake"
    public let locality = Locality.onDevice
    public let model: EmbeddingModelInfo

    public init(dimensions: Int = 64, vaultThreshold: Float = 0.5, retrievalThreshold: Float = 0.55) {
        model = EmbeddingModelInfo(id: "fake/hash-\(dimensions)", dimensions: dimensions,
                                   vaultThreshold: vaultThreshold, retrievalThreshold: retrievalThreshold)
    }

    public func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] {
        texts.map { text in
            var v = [Float](repeating: 0, count: model.dimensions)
            for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                var h: UInt64 = 1_469_598_103_934_665_603
                for b in word.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
                v[Int(h % UInt64(model.dimensions))] += (h >> 63) == 0 ? 1 : -1
            }
            return l2normalize(v)
        }
    }
}
