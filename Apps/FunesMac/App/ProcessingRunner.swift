import Foundation
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "processing")

/// Runs the durable processing queue (memory processing §5.2, task 6.1.4): at launch, resuming
/// what a quit left; after every vault change, since every ingest path queues its job with its
/// input; and once a minute, for retries that came due. One job at a time. With splitting on,
/// each job splits its input (task 6a), and its card waits ("Processing…") until it's done.
@MainActor
final class ProcessingRunner {
    private let queue: ProcessingQueue
    private let processor: NewMemoryProcessor
    private let preferences: Preferences
    private let settings: ModelSettings
    private let splitting: SplittingSwitch
    /// A job's outcome is recorded: an agent's Save panels waiting for it can show (FunesApprovals).
    private let ended: @MainActor @Sendable (UUID) async -> Void
    private var task: Task<Void, Never>?
    /// A change arrived while a drain was running: drain again when it ends.
    private var again = false
    private var timer: Timer?

    init(environment: VaultEnvironment, preferences: Preferences, settings: ModelSettings) {
        queue = ProcessingQueue(store: environment.store, activity: environment.activity)
        self.preferences = preferences
        self.settings = settings
        splitting = environment.splitting
        ended = { [weak environment] id in await environment?.approvals.processingEnded(id) }
        processor = NewMemoryProcessor(
            store: environment.store, captures: environment.captures,
            finder: RelatedMemoryFinder(store: environment.store, indexer: environment.indexer),
            configuration: { @MainActor [store = environment.store, activity = environment.activity] in
                // Splitting needs the router even with proposals off; the job splits only with a
                // local server or cloud model chosen (memory processing §5.2).
                let split = preferences.splitNewMemories
                let router = preferences.classifyCaptures || split
                    ? settings.makeRouter(cap: settings.cap(store: store, activity: activity)) : nil
                return NewMemoryProcessor.Configuration(router: router, split: split,
                                                        autoApply: NewMemoryAutoApply(level: preferences.applyAutomatically))
            },
            finished: { @MainActor router in settings.collectUsage(from: router) })
        updateSplitting()
    }

    func start() {
        let queue = self.queue
        Task {
            do { try await queue.resume(now: Date()) } catch { logger.error("Resuming the processing queue failed") }
            kick()
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.kick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Splitting is on with a local server or cloud model chosen (Apple on-device only
    /// classifies): new cards wait for their split. Read again on every kick and settings change.
    func updateSplitting() {
        splitting.set(preferences.splitNewMemories && settings.chosenName != nil)
    }

    func kick() {
        updateSplitting()
        guard task == nil else {
            again = true
            return
        }
        let queue = self.queue, processor = self.processor, ended = self.ended
        task = Task { [weak self] in
            repeat {
                self?.again = false
                do {
                    try await queue.drain(finished: { job in await ended(job.subject) }, processor.process)
                } catch {
                    logger.error("The processing queue failed")
                }
            } while self?.again == true
            self?.task = nil
        }
    }
}
