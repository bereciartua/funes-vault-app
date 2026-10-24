import Foundation
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "processing")

/// Runs the durable processing queue (memory processing §5.2, task 6.1.4): at launch, resuming
/// what a quit left; after every vault change, since every ingest path queues its job with its
/// input; and once a minute, for retries that came due. One job at a time.
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
            router: { @MainActor in preferences.classifyCaptures ? settings.makeRouter() : nil },
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
