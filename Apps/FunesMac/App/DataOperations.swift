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

    /// At launch, before the vault opens: FunesCore saves the current vault as a self-contained
    /// `Backups/pre-restore-…` backup (with what was still in its WAL), then puts the chosen backup in
    /// place (`VaultStore.restoreBackup`).
    static func applyPendingRestore(dataFolder: URL) {
        let manager = FileManager.default
        let marker = dataFolder.appendingPathComponent(restoreMarker)
        guard let data = manager.contents(atPath: marker.path) else { return }
        try? manager.removeItem(at: marker)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let name = object["backup"] else { return }
        do {
            try VaultStore.restoreBackup(name, in: dataFolder, now: Date())
        } catch {
            logger.error("Restoring a backup failed")
        }
    }

    // MARK: Export (FR-X-05)

    func export(includeArchived: Bool) async throws -> Data {
        try await environment.imports.export(includeArchived: includeArchived, now: Date())
    }

    // MARK: Erase All Data (FR-G-05)

    /// Deletes the vault, keys, Activity and backups in the data folder, the AI provider keys and
    /// the app's settings, then relaunches empty. Agents' own config files aren't touched.
    func eraseAll(modelSettings: ModelSettings) {
        let manager = FileManager.default
        for provider in modelSettings.providers { modelSettings.remove(provider.id) }
        if let items = try? manager.contentsOfDirectory(at: environment.dataFolder, includingPropertiesForKeys: nil) {
            for item in items { try? manager.removeItem(at: item) }
        }
        let domain = Preferences.isDevelopmentVault ? "com.funesvault.dev" : Identifiers.macBundleID
        preferences.defaults.removePersistentDomain(forName: domain)
        Self.relaunch()
    }

    /// Opens a new copy of the app (with this one's environment and arguments) and quits.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ProcessInfo.processInfo.environment
        configuration.arguments = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--dev-seed" }
        let me = ProcessInfo.processInfo.processIdentifier
        configuration.arguments += [AppMover.waitForArgument, String(me)]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
