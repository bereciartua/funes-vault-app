import Foundation
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "processing")

/// Runs the durable processing queue (memory processing §5.2, task 6.1.4): at launch, resuming
/// what a quit left; after every vault change, since every ingest path queues its job with its
/// input; and once a minute, for retries that came due. One job at a time. With splitting on,
/// each job splits its input (task 6a).
@MainActor
final class ProcessingRunner {
    private let queue: ProcessingQueue
    private let processor: NewMemoryProcessor
    private var task: Task<Void, Never>?
    /// A change arrived while a drain was running: drain again when it ends.
    private var again = false
    private var timer: Timer?

    init(environment: VaultEnvironment, preferences: Preferences, settings: ModelSettings) {
        queue = ProcessingQueue(store: environment.store, activity: environment.activity)
        processor = NewMemoryProcessor(
            store: environment.store, captures: environment.captures,
            finder: RelatedMemoryFinder(store: environment.store, indexer: environment.indexer), holds: environment.holds,
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

    func kick() {
        guard task == nil else {
            again = true
            return
        }
        let queue = self.queue, processor = self.processor
        task = Task { [weak self] in
            repeat {
                self?.again = false
                do {
                    try await queue.drain(processor.process)
                } catch {
                    logger.error("The processing queue failed")
                }
            } while self?.again == true
            self?.task = nil
        }
    }
}
