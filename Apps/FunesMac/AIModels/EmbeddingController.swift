import Foundation
import FunesCore
import FunesProtocol
import Observation
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "embeddings")

/// The provider embedding model on the Mac (ADR-0023, model providers §7, task 6c.3): builds the
/// second index from Settings, keeps it current in the background, and hands it to search once
/// it's complete. Rebuilt whenever the choice, the cloud limit or the provider changes. Removing
/// the model, or cancelling its first pass, deletes its vectors: search is bge-only again.
@MainActor @Observable
final class EmbeddingController {
    /// The current pass, for Settings; nil without a provider model.
    private(set) var progress: ProviderEmbeddingIndexer.Progress?
    /// The model in use and where it runs.
    private(set) var model: EmbeddingModelInfo?
    private(set) var locality: Locality?
    /// Why the chosen model couldn't be used (no dimensions, a cloud address over http…).
    private(set) var problem: ProviderError?
    private(set) var calibrating = false
    /// Every eligible memory has a provider vector, so search uses them.
    private(set) var isComplete = false

    @ObservationIgnored private let environment: VaultEnvironment
    @ObservationIgnored private let settings: ModelSettings
    @ObservationIgnored private var indexer: ProviderEmbeddingIndexer?
    @ObservationIgnored private var observation: AnyObject?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var backoff: TimeInterval = 60
    @ObservationIgnored private var generation = 0

    init(environment: VaultEnvironment, settings: ModelSettings) {
        self.environment = environment
        self.settings = settings
    }

    /// The bundled model's id, whose vectors are never touched here.
    private var bundledID: String { environment.indexer?.provider.model.id ?? EmbeddingModelInfo.bundled.id }

    /// Memories above the cloud limit are searched on this Mac only (model providers §5.2).
    func searchedOnThisMacOnly(_ sensitivity: Sensitivity) -> Bool {
        guard let locality, !locality.isLocal else { return false }
        return !settings.cloudLimit.allows(sensitivity)
    }

    /// At launch, and after every change the index depends on.
    func apply() {
        generation += 1
        let current = generation
        task?.cancel()
        retry?.cancel()
        task = nil
        observation = nil
        indexer = nil
        environment.search.secondIndex = nil
        backoff = 60
        let store = environment.store, bundled = bundledID
        guard let choice = settings.embedding, let recipe = settings.embeddingRecipe(choice) else {
            progress = nil
            model = nil
            locality = nil
            problem = nil
            isComplete = false
            Task.detached(priority: .utility) { try? ProviderEmbeddingIndexer.removeOthers(store: store, keeping: [bundled]) }
            return
        }
        Task { [weak self] in
            do {
                let embedder = try await Task.detached(priority: .userInitiated) { try recipe.make() }.value
                guard let self, current == self.generation else { return }
                self.start(embedder, choice: choice, generation: current)
            } catch {
                guard let self, current == self.generation else { return }
                self.problem = error as? ProviderError ?? .unavailable
                self.model = nil
                self.progress = nil
            }
        }
    }

    private func start(_ embedder: OpenAICompatibleEmbedder, choice: EmbeddingChoice, generation current: Int) {
        let store = environment.store, bundled = bundledID
        let indexer = ProviderEmbeddingIndexer(store: store, provider: embedder, cloudLimit: settings.cloudLimit,
                                               onProgress: { [weak self] p in
                                                   Task { @MainActor in if self?.generation == current { self?.changed(p) } }
                                               })
        self.indexer = indexer
        model = embedder.model
        locality = embedder.locality
        problem = nil
        progress = indexer.progress
        isComplete = false
        // Search asks the provider only once the set is complete (model providers §7.3).
        environment.search.secondIndex = SecondIndex(indexer: indexer, embedsAgentTasks: choice.embedsAgentTasks)
        observation = indexer.startObserving()
        task = Task.detached(priority: .utility) {
            try? ProviderEmbeddingIndexer.removeOthers(store: store, keeping: [bundled, embedder.model.id])
            try? indexer.loadIndex()
            _ = try? await indexer.embedPending()
        }
    }

    private func changed(_ p: ProviderEmbeddingIndexer.Progress) {
        guard let indexer else { return }
        progress = p
        isComplete = indexer.isComplete
        switch p.state {
        case .complete:
            backoff = 60
            collectUsage()
        case let .failed(error):
            collectUsage()
            // A provider that's down is retried with backoff; a bad key waits for the user (§6).
            guard error != .unauthorized else { return }
            retry?.cancel()
            let wait = backoff
            backoff = min(backoff * 2, 30 * 60)
            retry = Task { [indexer] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                _ = try? await indexer.embedPending()
            }
        default:
            break
        }
    }

    /// Adds the index's embedding tokens to the provider's counters (FR-AI-12).
    func collectUsage() {
        guard let indexer, let id = settings.embedding?.provider else { return }
        settings.addUsage(indexer.takeUsage(), for: id)
    }

    /// Retry after a failure (Settings).
    func retryNow() {
        retry?.cancel()
        guard let indexer else { return apply() }
        task = Task.detached(priority: .utility) { _ = try? await indexer.embedPending() }
    }

    /// Cancel the first pass, or stop using the model: its vectors are deleted (model providers §7.4).
    func remove() {
        task?.cancel()
        retry?.cancel()
        let indexer = self.indexer
        self.indexer = nil
        environment.search.secondIndex = nil
        try? indexer?.removeAll()
        settings.setEmbedding(nil)
    }

    // MARK: Choosing a model

    /// What Settings confirms before the first pass: the memories and tokens, and where they go.
    struct Plan: Sendable {
        var choice: EmbeddingChoice
        var memories: Int
        var tokens: Int
        var locality: Locality
        var calibrated: Bool
    }

    /// Checks the model with one made-up text (its dimensions, for a model Funes doesn't know) and
    /// estimates the first pass. Nothing of the user's is sent.
    func prepare(_ choice: EmbeddingChoice) async throws -> Plan {
        guard var recipe = settings.embeddingRecipe(choice) else { throw ProviderError.unavailable }
        let known = EmbeddingCatalog.lookup(choice.model)?.dimensions
        if recipe.info == nil, known == nil { recipe.dimensions = 1 }  // replaced by the probe's answer
        let probe = try await Task.detached(priority: .userInitiated) { [recipe] in try recipe.make() }.value
        let (vectors, used) = try await ModelRouter.embed([.synthetic(ModelRouter.testNote)], as: .document, with: probe,
                                                          cloudLimit: .never)
        settings.addUsage(used, for: choice.provider)
        guard let dims = vectors.first?.count, dims > 0 else { throw ProviderError.invalidOutput }
        if let expected = recipe.info?.dimensions ?? known, expected != dims { throw ProviderError.invalidOutput }
        var choice = choice
        choice.dimensions = known == nil ? dims : nil
        recipe.dimensions = choice.dimensions
        let embedder = try await Task.detached(priority: .userInitiated) { [recipe] in try recipe.make() }.value
        let estimate = try await ProviderEmbeddingIndexer(store: environment.store, provider: embedder,
                                                          cloudLimit: settings.cloudLimit).estimate()
        return Plan(choice: choice, memories: estimate.memories, tokens: estimate.tokens, locality: embedder.locality,
                    calibrated: embedder.model.isCalibrated)
    }

    /// **Calibrate…** (model providers §8): Funes's 230 made-up benchmark texts, none of the user's.
    func calibrate() async throws {
        guard let indexer, let provider = settings.embedding?.provider else { throw ProviderError.unavailable }
        calibrating = true
        defer { calibrating = false }
        let (info, used) = try await EmbeddingCalibration.run(indexer.provider)
        settings.addUsage(used, for: provider)
        logger.notice("Calibrated a provider embedding model")
        settings.setCalibration(CalibratedThresholds(dimensions: info.dimensions, vault: info.vaultThreshold,
                                                     retrieval: info.retrievalThreshold), for: info.id)
    }
}
