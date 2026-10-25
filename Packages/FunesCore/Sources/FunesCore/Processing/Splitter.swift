import Foundation
import FunesProtocol
import GRDB

/// One input for the splitter (memory processing §5.2, step 4).
public struct SplitRequest: Sendable {
    public var text: String
    /// The title and written date for the note tag (§5.3): a suggestion's or memory's title and
    /// date, a capture's date only. Nil: the text alone.
    public var note: ExtractionNote?
    public var variant: ExtractionVariant
    public var hint: ExtractionHint?
    /// The "at least" level the user picked when capturing.
    public var sensitivityHint: Sensitivity?
    /// The agent's declared level (agent input).
    public var declared: Sensitivity?
    /// The original memory's level (splitting a saved memory).
    public var original: Sensitivity?
    /// Never link candidates: the original memory.
    public var excluding: Set<UUID>
    /// Link only against these, when given (anything auto-applied for an agent, §5.5).
    public var linkPool: Set<UUID>?
    public var requester: CloudRequestCap.Requester

    public init(text: String, note: ExtractionNote? = nil, variant: ExtractionVariant, hint: ExtractionHint? = nil,
                sensitivityHint: Sensitivity? = nil, declared: Sensitivity? = nil, original: Sensitivity? = nil,
                excluding: Set<UUID> = [], linkPool: Set<UUID>? = nil, requester: CloudRequestCap.Requester = .user) {
        self.text = text
        self.note = note
        self.variant = variant
        self.hint = hint
        self.sensitivityHint = sensitivityHint
        self.declared = declared
        self.original = original
        self.excluding = excluding
        self.linkPool = linkPool
        self.requester = requester
    }

    var floors: ExtractionValidator.Floors { .init(hint: sensitivityHint, declared: declared, original: original) }
}

/// A piece with its decision and the memories the finder supplied for it.
public struct SplitPiece: Sendable, Hashable {
    public var piece: ExtractedPiece
    public var decision: LinkDecision
    public var related: [UUID]
}

public struct SplitResult: Sendable {
    /// `<provider>/<model>`.
    public var engine: String
    public var pieces: [SplitPiece]
    /// Pieces beyond the 40 an input keeps.
    public var truncated: Int
    /// Pieces validation dropped, by reason.
    public var dropped: [String: Int]
    /// Model calls made (extraction and decisions).
    public var calls: Int
}

/// Why nothing came of a split. The original stays as it is (§5.4).
public enum SplitError: Error, Sendable, Equatable {
    /// The engine doesn't split (Apple on-device, or nothing chosen).
    case noSplitter
    /// A secret, or above the cloud limit: nothing left the Mac.
    case keptOnDevice
    /// Today's cloud request cap (or the agents' share) is used up (ADR-0022).
    case capReached
    /// The provider failed or returned something unusable.
    case failed(ProviderError)
}

/// Extraction per chunk, validation, the finder, then the decision call (memory processing
/// §5.3–§5.5; Spike E: two calls). Writes nothing: the processing job stores the result.
public struct MemorySplitter: Sendable {
    /// Pieces per decision call: a small local model's context (Spike E ran Ollama's 4k window
    /// with 4) or one call for the whole input on a cloud model.
    static func decisionBatch(_ locality: Locality) -> Int { locality == .cloud || locality == .appleCloud ? 40 : 4 }
    /// Characters of the previous chunk given as context.
    static let contextCharacters = 2_000

    public let store: VaultStore
    public let router: ModelRouter
    public let finder: RelatedMemoryFinder

    public init(store: VaultStore, router: ModelRouter, finder: RelatedMemoryFinder) {
        self.store = store
        self.router = router
        self.finder = finder
    }

    public func split(_ input: SplitRequest, now: Date) async throws -> SplitResult {
        guard let provider = router.splitter else { throw SplitError.noSplitter }
        let categories = try store.categories()
        let text = String(input.text.prefix(Chunker.maxInput))
        // The title is sent with every chunk and is part of what quotes and words are checked against.
        let header = input.note?.header() ?? ""
        let estimate = max(ModelRouter.prescreen(header + text, categories: categories, declared: input.declared,
                                                 hint: input.sensitivityHint),
                           input.original ?? .public)
        var calls = 0

        // Extraction, one call per chunk; any failure keeps the original whole.
        let chunks = Chunker.chunks(text)
        var raw: [[ExtractionPrompt.RawPiece]] = []
        for (i, chunk) in chunks.enumerated() {
            let context = i > 0 ? String(chunks[i - 1].suffix(Self.contextCharacters)) : nil
            let request = ExtractionPrompt.request(chunk: chunk, context: context, hint: input.hint, note: input.note,
                                                   variant: input.variant, categories: categories)
            let items = ([chunk] + (context.map { [$0] } ?? []) + (input.note?.titleText.map { [$0] } ?? []))
                .map { ModelItem($0, sensitivity: estimate) }
            calls += 1
            raw.append(try await call(request, items: items, provider: provider, input: input, now: now).pieces)
        }
        let outcome = ExtractionValidator.validate(raw, source: header + text, categories: categories, floors: input.floors)
        var result = SplitResult(engine: ModelRouter.engine(provider), pieces: [], truncated: outcome.truncated,
                                 dropped: Dictionary(uniqueKeysWithValues: outcome.dropped.map { ($0.key.rawValue, $0.value) }),
                                 calls: calls)
        guard !outcome.pieces.isEmpty else { return result }

        // The finder, then one decision call for the input (in batches on a small local model).
        let related = try await finder.related(outcome.pieces.map {
            RelatedMemoryFinder.Query(title: $0.title, body: $0.body, kind: $0.kind, categoryKeys: $0.categoryKeys)
        }, excluding: input.excluding, pool: input.linkPool)
        let memories = try await store.writer.read { db in
            Dictionary(uniqueKeysWithValues: try MemoryStore.fetch(db, ids: Array(Set(related.flatMap { $0 }))).map { ($0.id, $0) })
        }
        let local = provider.locality.isLocal
        var decisions: [Int: LinkDecision] = [:]
        // A cloud provider gets only pieces and memories within the cloud limit (§5.5).
        let linkable = outcome.pieces.indices.filter { local || router.cloudLimit.allows(outcome.pieces[$0].sensitivity) }
        let withCandidates = linkable.filter { !related[$0].isEmpty }
        let batchSize = Self.decisionBatch(provider.locality)
        for start in stride(from: 0, to: withCandidates.count, by: batchSize) {
            let indices = Array(withCandidates[start..<min(start + batchSize, withCandidates.count)])
            var aliases: [UUID: String] = [:]
            var batch = DecisionPrompt.Batch(pieces: indices.map { ($0, outcome.pieces[$0]) }, related: [:])
            for i in indices {
                batch.related[i] = related[i].compactMap { id in
                    guard let m = memories[id], local || router.cloudLimit.allows(m.sensitivity) else { return nil }
                    if aliases[id] == nil { aliases[id] = "m\(aliases.count + 1)" }
                    return (aliases[id]!, m)
                }
            }
            let items = indices.map { ModelItem("\(outcome.pieces[$0].title)\n\(outcome.pieces[$0].body)", sensitivity: outcome.pieces[$0].sensitivity) }
                + batch.related.values.flatMap { $0 }.map { ModelItem("\($0.memory.title)\n\($0.memory.body)", sensitivity: $0.memory.sensitivity) }
            calls += 1
            do {
                let output = try await call(DecisionPrompt.request(batch), items: items, provider: provider, input: input, now: now)
                decisions.merge(DecisionPrompt.validate(output, batch: batch)) { a, _ in a }
            } catch SplitError.capReached {
                throw SplitError.capReached
            } catch {
                // Linking failed: these pieces are proposed as new, with the duplicate hint.
            }
        }
        result.calls = calls
        result.pieces = outcome.pieces.enumerated().map { i, piece in
            SplitPiece(piece: piece, decision: decisions[i] ?? .create, related: related[i])
        }
        return result
    }

    private func call<T: Decodable & Sendable>(_ request: StructuredRequest<T>, items: [ModelItem], provider: any GenerationProvider,
                                               input: SplitRequest, now: Date) async throws -> T {
        do {
            return try await router.call(request, items: items, with: provider, requester: input.requester, now: now)
        } catch ProviderError.blocked {
            throw SplitError.keptOnDevice
        } catch ProviderError.capReached {
            throw SplitError.capReached
        } catch let error as ProviderError {
            throw SplitError.failed(error)
        } catch {
            throw SplitError.failed(.transport)
        }
    }
}
