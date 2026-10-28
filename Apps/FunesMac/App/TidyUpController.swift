import AppKit
import Foundation
import FunesCore
import FunesProtocol
import Observation
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "tidy-up")

/// The daily tidy-up on the Mac (memory processing §9, task 6b.1): daily at the user's time with
/// `NSBackgroundActivityScheduler`, a catch-up at launch or wake after a missed run, and Tidy Up
/// Now. Off by default. One run at a time; each ends with a notification when it found anything.
@MainActor @Observable
final class TidyUpController {
    /// A run is going on.
    private(set) var running = false
    private(set) var lastRun: TidyUpRun?
    /// Before the first run: the memories to check and roughly how many requests (§9.6).
    private(set) var estimate: TidyUpEstimate?
    /// Tidy Up on one memory (§9.7): the memory it's looking at.
    private(set) var tidying: UUID?
    /// What Tidy Up found for each memory this session, with the version it looked at, for its
    /// detail pane: once the memory changes, the line goes.
    private(set) var memoryResults: [UUID: (version: Int, result: MemoryResult)] = [:]

    /// What Tidy Up on one memory came back with.
    enum MemoryResult: Equatable {
        /// Proposals left in the Inbox, by suggestion id.
        case suggestions([UUID])
        case nothing
        case refused(TidyUpMemoryRefusal)
        /// Stopped early: `cap_reached` or a provider error code.
        case stopped(String)
    }

    /// A tidy-up model is chosen: without one only the code-only rules run, which a single memory
    /// doesn't need.
    var canTidyMemory: Bool { settings.tidyUpName != nil }

    /// After a run with results: applied and left for review. Never memory text.
    @ObservationIgnored var finished: (TidyUpRun) -> Void = { _ in }

    @ObservationIgnored private let environment: VaultEnvironment
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let settings: ModelSettings
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var wake: NSObjectProtocol?

    init(environment: VaultEnvironment, preferences: Preferences, settings: ModelSettings) {
        self.environment = environment
        self.preferences = preferences
        self.settings = settings
    }

    private var service: TidyUpService {
        TidyUpService(store: environment.store, activity: environment.activity,
                      finder: RelatedMemoryFinder(store: environment.store, indexer: environment.indexer), holds: environment.holds)
    }

    /// At launch: checks every half hour in the background (macOS picks a good moment within the
    /// tolerance), and at every wake, for a run that's due.
    func start() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.funesvault.mac.tidy-up")
        scheduler.repeats = true
        scheduler.interval = 30 * 60
        scheduler.tolerance = 10 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.runIfDue()
                completion(.finished)
            }
        }
        self.scheduler = scheduler
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.runIfDue() } }
        }
        Task { await runIfDue() }
    }

    /// Reads the last run and, before the first, the estimate.
    func load() async {
        lastRun = try? await service.lastRun()
        estimate = lastRun == nil ? try? await service.estimate() : nil
    }

    /// The day's run, or the catch-up after one was missed, when the tidy-up is on.
    func runIfDue(now: Date = Date()) async {
        guard preferences.tidyUpDaily, !running else { return }
        await load()
        let since = [lastRun?.startedAt, preferences.tidyUpOnSince].compactMap { $0 }.max()
        guard preferences.tidyUpSchedule.isDue(now: now, since: since) else { return }
        await runNow()
    }

    /// Tidy Up Now, or a scheduled run.
    func runNow() async {
        guard !running, tidying == nil else { return }
        running = true
        defer { running = false }
        let cap = settings.cap(store: environment.store, activity: environment.activity)
        let router = settings.makeTidyUpRouter(cap: cap)
        do {
            let run = try await service.run(.init(router: router, autoApply: TidyUpAutoApply(level: preferences.applyAutomatically)))
            settings.collectUsage(from: router)
            lastRun = run
            estimate = nil
            if run.applied + run.suggestions > 0 { finished(run) }
        } catch {
            logger.error("The tidy-up failed")
        }
    }

    /// Tidy Up on one memory (§9.7). Everything it finds is left for review, whatever Apply
    /// changes automatically says: the user is looking at it.
    func tidy(memoryID: UUID, version: Int) async {
        guard !running, tidying == nil else { return }
        tidying = memoryID
        memoryResults[memoryID] = nil
        defer { tidying = nil }
        let cap = settings.cap(store: environment.store, activity: environment.activity)
        let router = settings.makeTidyUpRouter(cap: cap)
        do {
            let result = try await service.tidy(memoryID: memoryID, .init(router: router, honorDismissals: false))
            settings.collectUsage(from: router)
            let found: MemoryResult = if !result.suggestions.isEmpty { .suggestions(result.suggestions) }
                else if let error = result.run.error { .stopped(error) }
                else { .nothing }
            memoryResults[memoryID] = (version, found)
        } catch let refusal as TidyUpMemoryRefusal {
            memoryResults[memoryID] = (version, .refused(refusal))
        } catch {
            logger.error("Tidy Up on one memory failed")
            memoryResults[memoryID] = (version, .stopped("failed"))
        }
    }

    #if FUNES_UI_REVIEW
    /// The UI review's Tidy Up scene: a result without a model.
    func reviewResult(_ result: MemoryResult, for memory: Memory) { memoryResults[memory.id] = (memory.version, result) }
    #endif

    /// The memory's Tidy Up result, while it's still at the version Tidy Up looked at.
    func memoryResult(_ memory: Memory) -> MemoryResult? {
        memoryResults[memory.id].flatMap { $0.version == memory.version ? $0.result : nil }
    }

    /// The detail pane's line for a Tidy Up result. No memory text.
    static func memoryNotice(_ result: MemoryResult) -> String {
        switch result {
        case .suggestions(let ids):
            ids.count == 1 ? String(localized: "Funes has a suggestion for this memory in the Inbox.")
                : String(localized: "Funes has \(ids.count) suggestions for this memory in the Inbox.")
        case .nothing: String(localized: "Nothing to tidy up: this memory looks right.")
        case .refused(.busy): String(localized: "This memory is already in a suggestion or a share waiting for you.")
        case .refused(.noModel): String(localized: "Choose a tidy-up model in Settings ▸ AI Models first.")
        case .refused(.aboveCloudLimit): String(localized: "This memory is above what you let cloud models see.")
        case .refused(.notActive): String(localized: "Only active memories can be tidied up.")
        case .stopped("cap_reached"): String(localized: "Stopped at today's cloud limit. Try again tomorrow.")
        case .stopped("blocked"): String(localized: "Funes didn't send it: it looked like a secret, or was above the cloud limit.")
        case .stopped: String(localized: "The model didn't answer. Try again later.")
        }
    }

    /// "Funes applied 3 changes and has 2 for you to review." (§9.5) No memory text.
    static func notice(_ run: TidyUpRun) -> String {
        switch (run.applied, run.suggestions) {
        case (0, let review): String(localized: "Funes has \(review) tidy-up suggestions for you to review.")
        case (let applied, 0): String(localized: "Funes applied \(applied) changes. You can undo them in the Inbox.")
        case let (applied, review): String(localized: "Funes applied \(applied) changes and has \(review) for you to review.")
        }
    }

    /// "Last tidy-up: today 03:04 · 37 memories checked · 4 suggestions".
    static func summary(_ run: TidyUpRun) -> String {
        let time = run.startedAt.formatted(date: .omitted, time: .shortened)
        let when = Calendar.current.isDateInToday(run.startedAt) ? String(localized: "today \(time)")
            : Calendar.current.isDateInYesterday(run.startedAt) ? String(localized: "yesterday \(time)") : RelativeTime.full(run.startedAt)
        var parts = [String(localized: "Last tidy-up: \(when)"),
                     String(localized: "\(run.inspected) memories checked"),
                     String(localized: "\(run.suggestions) suggestions")]
        if run.applied > 0 { parts.append(String(localized: "\(run.applied) applied")) }
        if run.error == "cap_reached" {
            parts.append(String(localized: "stopped at today's cloud limit"))
        } else if run.error != nil {
            parts.append(String(localized: "stopped early: the model didn't answer"))
        } else if run.partial {
            parts.append(String(localized: "more next time"))
        }
        return parts.joined(separator: " · ")
    }
}
