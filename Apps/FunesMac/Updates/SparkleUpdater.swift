import AppKit
import BridgeUI
import os
import Security
import Sparkle

private let logger = Logger(subsystem: "com.funesvault.mac", category: "updates")

/// In-app updates (FR-G-03), adapted from EK Bridge's SparkleUpdater (BridgeUI/Upstream): Sparkle 2
/// with its standard window, reading `SUFeedURL`, and checking each download's EdDSA signature
/// against `SUPublicEDKey` before installing anything. Scheduled checks are daily and use Sparkle's
/// gentle reminders (a found update shows in the menu); installing always takes a click
/// (`SUAllowsAutomaticUpdates` is off). The relaunch waits while requests wait for the user.
///
/// Only a copy signed with Funes's Developer ID checks (`isConfigured`): a build from source, an
/// Xcode run or a Debug build never does, though the committed Info.plist has the feed and the key
/// (docs/MAINTAINING.md "Updates").
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

    /// The team scripts/release.sh signs releases with.
    private static let releaseTeam = "JVNJ326L7B"

    /// True only in a copy signed with Funes's Developer ID that has the feed and the public key.
    /// Builds from source and Xcode runs (signed ad hoc, or with a development certificate even of
    /// the same team) never check, and the Updates settings say so.
    static var isConfigured: Bool {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? ""
        return !key.isEmpty && !feed.isEmpty && isSignedForRelease
    }

    /// Whether the running app meets Apple's Developer ID requirement for the release team.
    private static var isSignedForRelease: Bool {
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(releaseTeam)\""
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    func start() {
        guard !started else { return }
        guard Self.isConfigured else {
            logger.notice("Updates are off: this copy isn't signed for release")
            return
        }
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
