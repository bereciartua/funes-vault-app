import Foundation
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "processing")

/// Runs the durable processing queue (memory processing §5.2, task 6.1.4): at launch, resuming
/// what a quit left; after every vault change, since every ingest path queues its job with its
/// input; and once a minute, for retries that came due. One job at a time. With splitting on,
/// each job splits its input (task 6a), and its card waits ("Processing…") until it's done.
///
/// Facts jobs (memory processing §11.3) run in the low-priority lane while *Learn from memories* is on
/// (`FactsLane`, admitted atomically with the claim), each with a configuration built for it: the
/// chosen model and its fallback, the cloud limit, your names from About you, and the shipped
/// qualification records with the local off-switches. A group no model resolves for waits
/// (`no_model`) until the Facts settings change.
///
/// The first Facts backfill (FR-F-03) is started from the Facts page with an extractor built the same way
/// (`factsExtractor`); its marked jobs run here like any other. At launch an ended backfill is settled, and at launch and
/// on every Facts settings change the facts lane's catch-up queues what the model should read and hasn't (a raised
/// limit, a model back, grown coverage, a registry extraction change), under the cap.
@MainActor
final class ProcessingRunner {
    private let queue: ProcessingQueue
    private let processor: NewMemoryProcessor
    private let preferences: Preferences
    private let settings: ModelSettings
    private let splitting: SplittingSwitch
    private let environment: VaultEnvironment
    /// A job's outcome is recorded: an agent's Save panels waiting for it can show (FunesApprovals).
    private let ended: @MainActor @Sendable (UUID) async -> Void
    private var task: Task<Void, Never>?
    /// A change arrived while a drain was running: drain again when it ends.
    private var again = false
    private var timer: Timer?
    /// Facts jobs that ended waiting for a model, with the generation that was decided under: a settings change since
    /// (which woke only the jobs already waiting) wakes them once their outcome is recorded.
    private var noModelAt: [UUID: Int] = [:]
    /// Bumped when the daily cap changes: a job that decided "wait for tomorrow's cap" under an older cap is due now.
    private var capGeneration = 0
    /// Facts jobs that ended waiting for tomorrow's cap, with the cap generation they decided under.
    private var capWaitAt: [UUID: Int] = [:]

    init(environment: VaultEnvironment, preferences: Preferences, settings: ModelSettings) {
        queue = ProcessingQueue(store: environment.store, activity: environment.activity)
        self.environment = environment
        self.preferences = preferences
        self.settings = settings
        splitting = environment.splitting
        ended = { [weak environment] id in await environment?.approvals.processingEnded(id) }
        processor = NewMemoryProcessor(
            store: environment.store, captures: environment.captures,
            finder: RelatedMemoryFinder(store: environment.store, indexer: environment.indexer),
            configuration: { @MainActor [store = environment.store, activity = environment.activity] in
                // Splitting needs the router even with proposals off; the job splits only with a
                // local server or cloud model chosen (memory processing §5.2), and classifies only
                // with proposals on (§5.1).
                let split = preferences.splitNewMemories, classify = preferences.classifyCaptures
                var router: ModelRouter?
                if classify || split {
                    // Built off the main actor, where building a client can wait.
                    let build = settings.newMemoriesRouterBuilder(cap: settings.cap(store: store, activity: activity))
                    router = await Task.detached(priority: .utility) { build() }.value
                }
                return NewMemoryProcessor.Configuration(router: router, classify: classify, split: split,
                                                        autoApply: NewMemoryAutoApply(level: preferences.applyAutomatically))
            },
            finished: { @MainActor router in settings.collectUsage(from: router) })
        updateSplitting()
    }

    func start() {
        let queue = self.queue
        Task {
            do { try await queue.resume(now: Date()) } catch { logger.error("Resuming the processing queue failed") }
            // The plans' CLIs are found now: a facts job that waited for a model may have one.
            _ = try? await queue.wakeFacts(code: Self.noModel, now: Date())
            do { try await environment.store.settleFactsBackfill(activity: environment.activity) } catch {
                logger.error("Settling the facts backfill failed")
            }
            await catchUpFacts()
            kick()
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.kick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Splitting is on with a local server or cloud model chosen (Apple on-device only
    /// classifies): new cards wait for their split. Read again on every kick and settings change.
    func updateSplitting() {
        splitting.set(preferences.splitNewMemories && settings.newMemoriesModel != nil)
    }

    func kick() {
        updateSplitting()
        guard task == nil else {
            again = true
            return
        }
        let queue = self.queue, processor = self.processor, ended = self.ended
        let facts: @Sendable (ProcessingJob) async throws -> ProcessingQueue.Outcome = { [weak self] job in
            guard let self else { return .later(until: Date(), code: "quit") }
            return try await self.runFacts(job)
        }
        let factsEnded: @Sendable (ProcessingJob) async -> Void = { [weak self] job in await self?.factsJobEnded(job) }
        task = Task { [weak self] in
            repeat {
                self?.again = false
                do {
                    try await queue.drain(finished: { job in
                        await ended(job.subject)
                        if job.kind == .facts { await factsEnded(job) }
                    }) { job in
                        job.kind == .facts ? try await facts(job) : try await processor.process(job)
                    }
                } catch {
                    logger.error("The processing queue failed")
                }
            } while self?.again == true
            self?.task = nil
        }
    }

    /// The Facts settings changed: jobs that waited for a model may run now.
    func factsSettingsChanged() {
        let queue = self.queue
        Task {
            _ = try? await queue.wakeFacts(code: Self.noModel, now: Date())
            await catchUpFacts()
            kick()
        }
    }

    /// The daily cap changed: Facts jobs that waited for tomorrow's cap may run now (they wait again if it's still used up).
    func capChanged() {
        capGeneration += 1
        let queue = self.queue
        Task {
            _ = try? await queue.wakeFacts(code: "cap", now: Date())
            kick()
        }
    }

    /// The facts lane's catch-up (`FactsQueueWorker.scheduleCatchUp`), while learning is on with a model.
    private func catchUpFacts() async {
        guard settings.factsLearn, let extractor = await factsExtractor() else { return }
        do { try await FactsQueueWorker(extractor: extractor).scheduleCatchUp() } catch { logger.error("The facts catch-up failed") }
    }

    /// A Facts extractor as a job would get it now (the configuration, your names, the records with the local
    /// off-switches), for the backfill's estimate and start and the catch-up; nil when no model resolves.
    func factsExtractor() async -> FactsExtractor? {
        let store = environment.store, activity = environment.activity, profiles = environment.profiles
        guard let configuration = settings.factsConfiguration(cap: settings.cap(store: store, activity: activity)) else { return nil }
        return await Task.detached(priority: .utility) { () async -> FactsExtractor? in
            guard let aliases = try? await profiles.profile().factsAliases,
                  let qualification = try? await store.writer.read({ db in try FactsQualification.bundled.withOffSwitches(db) })
            else { return nil }
            return FactsExtractor(store: store, router: configuration.router(qualification: qualification), activity: activity,
                                  userAliases: aliases)
        }.value
    }

    /// A facts job's outcome is recorded: if it was "no model" and the settings changed since that was decided, wake it.
    private func factsJobEnded(_ job: ProcessingJob) {
        // Decided "tomorrow's cap" under a cap that changed before its outcome was recorded: it's due now.
        if let at = capWaitAt.removeValue(forKey: job.id), capGeneration != at { capChanged() }
        guard let decided = noModelAt.removeValue(forKey: job.id) else { return }
        if environment.store.factsLane.generation != decided { factsSettingsChanged() }
    }

    /// Why a facts job waits: no model resolves for its call group.
    nonisolated static let noModel = "no_model"

    /// One facts job with a configuration built now (model providers §4). The generation is read before the
    /// configuration, so any change after it stops the job at its next send (`FactsExtractor.permit`).
    private func runFacts(_ job: ProcessingJob) async throws -> ProcessingQueue.Outcome {
        let lane = environment.store.factsLane, store = environment.store, activity = environment.activity
        let generation = lane.generation, capAt = capGeneration
        let cap = settings.cap(store: store, activity: activity)
        guard let configuration = settings.factsConfiguration(cap: cap) else {
            noModelAt[job.id] = generation
            // A backfill job with no model: the backfill pauses for a review rather than waiting unseen.
            if job.exemptVersion != nil { try? await store.pauseFactsBackfillForChange() }
            return .later(until: Date().addingTimeInterval(86_400), code: Self.noModel)
        }
        let profiles = environment.profiles
        let (result, router) = await Task.detached(priority: .utility) { () async -> (Result<ProcessingQueue.Outcome, any Error>, ModelRouter?) in
            var router: ModelRouter?
            do {
                let aliases = try await profiles.profile().factsAliases
                let qualification = try await store.writer.read { db in try FactsQualification.bundled.withOffSwitches(db) }
                let built = configuration.router(qualification: qualification)
                router = built
                if let group = job.callGroup, built.factsModels[group] == nil {
                    return (.success(.later(until: Date().addingTimeInterval(86_400), code: Self.noModel)), router)
                }
                var extractor = FactsExtractor(store: store, router: built, activity: activity, userAliases: aliases)
                extractor.permit = { lane.permits(generation) }
                return (.success(try await FactsQueueWorker(extractor: extractor).process(job)), router)
            } catch {
                return (.failure(error), router)
            }
        }.value
        // Requests made before a failure count too.
        if let router { settings.collectUsage(from: router) }
        let outcome = try result.get()
        if case let .later(_, code) = outcome, code == Self.noModel {
            noModelAt[job.id] = generation
            if job.exemptVersion != nil { try? await store.pauseFactsBackfillForChange() }
        }
        // The cap changed while it ran: its wait for tomorrow is over (it waits again if the cap is still used up). One
        // changing after this, before the outcome is recorded, wakes it from `factsJobEnded`.
        if case let .later(_, code) = outcome, code == "cap" {
            if capGeneration != capAt { return .later(until: Date(), code: code) }
            capWaitAt[job.id] = capAt
        }
        return outcome
    }
}
