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
        guard !running else { return }
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
