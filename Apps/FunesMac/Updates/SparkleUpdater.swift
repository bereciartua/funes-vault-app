import AppKit
import BridgeUI
import os
import Sparkle

private let logger = Logger(subsystem: "com.funesvault.mac", category: "updates")

/// In-app updates (FR-G-03), adapted from EK Bridge's SparkleUpdater (BridgeUI/Upstream): Sparkle 2
/// with its standard window, reading `SUFeedURL`, and checking each download's EdDSA signature
/// against `SUPublicEDKey` before installing anything. Scheduled checks are daily and use Sparkle's
/// gentle reminders (a found update shows in the menu); installing always takes a click
/// (`SUAllowsAutomaticUpdates` is off). The relaunch waits while requests wait for the user.
///
/// `isConfigured` is false, and the build never checks, while either Info.plist key is empty (a
/// build without Funes's Sparkle key, docs/MAINTAINING.md "Updates").
@MainActor
final class SparkleUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var foundUpdateChanged: (FoundUpdate?) -> Void = { _ in }

    private let gate: UpdateRelaunchGate
    private var controller: SPUStandardUpdaterController!
    private var started = false

    init(gate: UpdateRelaunchGate) {
        self.gate = gate
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    /// A build without the public key and feed (one built from source, or before the first
    /// release) can't verify updates, so it never checks.
    static var isConfigured: Bool {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? ""
        return !key.isEmpty && !feed.isEmpty
    }

    func start() {
        guard Self.isConfigured, !started else { return }
        do {
            try controller.updater.start()
            started = true
        } catch {
            logger.error("Updates are off: Sparkle couldn't start")
        }
    }

    var controls: UpdaterControls {
        UpdaterControls(
            isAvailable: { [weak self] in self?.started ?? false },
            checkForUpdates: { [weak self] in
                guard let self, self.started else { return }
                self.controller.checkForUpdates(nil)
            },
            automaticChecks: { [weak self] in
                guard let self, self.started else { return false }
                return self.controller.updater.automaticallyChecksForUpdates
            },
            setAutomaticChecks: { [weak self] on in
                guard let self, self.started else { return }
                self.controller.updater.automaticallyChecksForUpdates = on
            },
            lastCheck: { [weak self] in self?.controller.updater.lastUpdateCheckDate })
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        gate.postpone(installHandler)
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let found = FoundUpdate(version: update.displayVersionString, critical: update.isCriticalUpdate)
        MainActor.assumeIsolated { foundUpdateChanged(found) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { foundUpdateChanged(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { foundUpdateChanged(nil) }
    }
}
