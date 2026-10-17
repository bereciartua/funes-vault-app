/// An embedding model's id, size and per-model search thresholds
/// (spec/domain/memory-processing.md#4-ranking, ADR-0016).
public struct EmbeddingModelInfo: Sendable, Hashable {
    /// Stored with every vector; a vector from another model id is never compared.
    public let id: String
    public let dimensions: Int
    /// Vault search keeps a memory whose raw cosine reaches this, keyword match or not.
    public let vaultThreshold: Float
    /// Agent retrieval keeps a memory whose raw cosine reaches this, keyword match or not.
    public let retrievalThreshold: Float
    /// The bundled model, `bge-small-en-v1.5` as Core ML with int8 weights (fp16 compute).
    public static let bundled = EmbeddingModelInfo(
        id: "bge-small-en-v1.5/coreml-int8", dimensions: 384, vaultThreshold: 0.50, retrievalThreshold: 0.55)
}
