import AppKit
import BridgeUI
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "data")

/// Settings ▸ Data and the maintenance jobs (FR-G-04, FR-G-05, FR-X-05, storage §5): backups,
/// restore, export, Show in Finder, Erase All Data, and the daily and weekly jobs.
@MainActor
final class DataOperations {
    static let restoreMarker = "restore-pending.json"

    private let environment: VaultEnvironment
    private let preferences: Preferences
    private var timer: Timer?
    /// The weekly integrity check failed: Settings ▸ Data offers a restore.
    private(set) var integrityProblem = false
    var integrityFailed: () -> Void = {}

    init(environment: VaultEnvironment, preferences: Preferences) {
        self.environment = environment
        self.preferences = preferences
    }

    var backupsFolder: URL { environment.dataFolder.appendingPathComponent("Backups", isDirectory: true) }

    /// Newest first.
    func backups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    var lastBackup: Date? { preferences.defaults.object(forKey: Preferences.Key.lastBackup) as? Date }

    @discardableResult
    func backUpNow() throws -> URL {
        let url = try environment.store.dailyBackup(into: backupsFolder, now: Date())
        preferences.defaults.set(Date(), forKey: Preferences.Key.lastBackup)
        return url
    }

    // MARK: Jobs

    /// At launch (after a short delay) and then hourly, runs whatever is due: the daily backup,
    /// purging memories deleted over 30 days ago, old capture receipts, decided groups' text, and the
    /// weekly check.
    func startJobs() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in MainActor.assumeIsolated { self?.runDueJobs() } }
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.runDueJobs() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func runDueJobs(now: Date = Date()) {
        let store = environment.store
        if preferences.defaults.bool(forKey: Preferences.Key.automaticBackups),
           lastBackup.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true {
            do { try backUpNow() } catch { logger.error("The daily backup failed") }
        }
        _ = try? store.purgeDeletedMemories(now: now)
        let captures = environment.captures
        let processing = ProcessingQueue(store: store, activity: environment.activity)
        let undo = UndoLog(store: store, activity: environment.activity)
        let suggestions = environment.suggestions
        Task {
            _ = try? await captures.cleanupReceipts(now: now)
            _ = try? await processing.cleanup(now: now)
            _ = try? await undo.cleanup(now: now)
            // Earlier versions past 90 days, or beyond 50 for a memory (ADR-0027).
            _ = try? await store.cleanUpEarlierVersions(now: now)
            // Split inputs whose every piece is decided keep no copy of their text (storage §5).
            _ = try? await suggestions.dropDecidedGroupText()
        }
        let lastCheck = preferences.defaults.object(forKey: Preferences.Key.lastIntegrityCheck) as? Date
        if lastCheck.map({ now.timeIntervalSince($0) >= 7 * 86_400 }) ?? true {
            preferences.defaults.set(now, forKey: Preferences.Key.lastIntegrityCheck)
            if (try? store.quickCheck()) != true {
                integrityProblem = true
                logger.error("The weekly integrity check failed")
                integrityFailed()
            }
        }
    }

    // MARK: Restore (FR-G-04)

    /// Restoring replaces the open database, so it happens at the next launch, before the vault
    /// opens: this writes the marker and relaunches.
    func restore(_ backup: URL) throws {
        let marker = environment.dataFolder.appendingPathComponent(Self.restoreMarker)
        let data = try JSONSerialization.data(withJSONObject: ["backup": backup.lastPathComponent])
        try data.write(to: marker, options: .atomic)
        _ = chmod(marker.path, 0o600)
        Self.relaunch()
    }

    /// How the restore asked for before this launch went, said once the app is up.
    enum RestoreOutcome { case restored, failed }
    private(set) static var restoreOutcome: RestoreOutcome?

    /// At launch, before the vault opens: FunesCore saves the current vault as a self-contained
    /// `Backups/pre-restore-…` backup (with what was still in its WAL), then puts the chosen backup in
    /// place (`VaultStore.restoreBackup`). The marker goes first, so a restore that fails is never
    /// tried at every launch; `restoreOutcome` keeps the result for the user.
    static func applyPendingRestore(dataFolder: URL) {
        let manager = FileManager.default
        let marker = dataFolder.appendingPathComponent(restoreMarker)
        guard let data = manager.contents(atPath: marker.path) else { return }
        try? manager.removeItem(at: marker)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let name = object["backup"] else {
            logger.error("The restore marker was unreadable")
            restoreOutcome = .failed
            return
        }
        do {
            try VaultStore.restoreBackup(name, in: dataFolder, now: Date())
            restoreOutcome = .restored
        } catch {
            logger.error("Restoring a backup failed")
            restoreOutcome = .failed
        }
    }

    // MARK: Export (FR-X-05)

    func export(includeArchived: Bool) async throws -> Data {
        try await environment.imports.export(includeArchived: includeArchived, now: Date())
    }

    // MARK: Erase All Data (FR-G-05)

    static let eraseMarker = "erase-pending"

    /// Deletes the vault, keys, Activity and backups in the data folder, the AI provider keys and
    /// the app's settings, then relaunches empty. Agents' own config files aren't touched. The
    /// files and settings go at the next launch, before anything opens them (as a restore does),
    /// so no service still running writes them back; this writes the marker, removes the provider
    /// keys and relaunches. Throws, deleting nothing, when the marker can't be written.
    func eraseAll(modelSettings: ModelSettings) throws {
        let marker = environment.dataFolder.appendingPathComponent(Self.eraseMarker)
        try Data().write(to: marker, options: .atomic)
        for account in modelSettings.accounts { modelSettings.removeAccount(account.id) }
        Self.relaunch()
    }

    /// Something in the data folder couldn't be deleted by the last erase: said once the app is up,
    /// with the folder, so the user can finish it.
    private(set) static var eraseIncomplete = false

    /// At launch, after the previous copy quit and before the settings are read or the vault
    /// opens: carries out a pending Erase All Data. The marker goes last, so an erase cut short
    /// by a crash runs again at the next launch; one that couldn't delete something isn't retried
    /// (it would erase what the next session keeps) but reported (`eraseIncomplete`).
    static func applyPendingErase(dataFolder: URL, defaults: UserDefaults) {
        let manager = FileManager.default
        let marker = dataFolder.appendingPathComponent(eraseMarker)
        guard manager.fileExists(atPath: marker.path) else { return }
        var failed = false
        do {
            let items = try manager.contentsOfDirectory(at: dataFolder, includingPropertiesForKeys: nil)
            // The instance lock stays: this copy holds it.
            for item in items where ![eraseMarker, AppDelegate.instanceLockName].contains(item.lastPathComponent) {
                do { try manager.removeItem(at: item) } catch { failed = true }
            }
        } catch {
            failed = true
        }
        let domain = Preferences.isDevelopmentVault ? "com.funesvault.dev" : Identifiers.macBundleID
        defaults.removePersistentDomain(forName: domain)
        try? manager.removeItem(at: marker)
        eraseIncomplete = failed
        if failed { logger.error("Erase All Data left something in the data folder") } else { logger.notice("Erased all data") }
    }

    /// Opens a new copy of the app (with this one's environment and arguments) and quits.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ProcessInfo.processInfo.environment
        configuration.arguments = relaunchArguments(Array(CommandLine.arguments.dropFirst()),
                                                    pid: ProcessInfo.processInfo.processIdentifier)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    /// This copy's arguments for the next one: without `--dev-seed`, and without the
    /// `--wait-for-pid` and `--moved-from` pairs this copy was launched with, so the next copy
    /// waits for this one (`AppMover.waitForPreviousCopy` reads the first pair it finds).
    static func relaunchArguments(_ arguments: [String], pid: Int32) -> [String] {
        var kept: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == AppMover.waitForArgument || argument == AppMover.movedFromArgument {
                index += 2
                continue
            }
            if argument != "--dev-seed" { kept.append(argument) }
            index += 1
        }
        return kept + [AppMover.waitForArgument, String(pid)]
    }
}
