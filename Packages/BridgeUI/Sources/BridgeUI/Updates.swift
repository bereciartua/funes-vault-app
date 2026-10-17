import Foundation

// Adapted from EK Bridge's Updates (Upstream/Updates.swift): public, otherwise unchanged. The
// Sparkle wrapper itself (SparkleUpdater) lives in the app target, the only one linking Sparkle.

/// The updater as the app sees it. The live Sparkle wrapper provides the controls; the UI-review
/// build passes fakes, so it never checks GitHub.
@MainActor
public struct UpdaterControls {
    /// False when this copy can't update itself: a build without Sparkle's public key (built from
    /// source), or the updater couldn't start.
    public var isAvailable: () -> Bool
    /// Opens Sparkle's window: checks now, or shows an update it already found.
    public var checkForUpdates: () -> Void
    public var automaticChecks: () -> Bool
    public var setAutomaticChecks: (Bool) -> Void
    public var lastCheck: () -> Date?

    public init(isAvailable: @escaping () -> Bool, checkForUpdates: @escaping () -> Void,
                automaticChecks: @escaping () -> Bool, setAutomaticChecks: @escaping (Bool) -> Void,
                lastCheck: @escaping () -> Date?) {
        self.isAvailable = isAvailable
        self.checkForUpdates = checkForUpdates
        self.automaticChecks = automaticChecks
        self.setAutomaticChecks = setAutomaticChecks
        self.lastCheck = lastCheck
    }

    public static let unavailable = UpdaterControls(
        isAvailable: { false }, checkForUpdates: {}, automaticChecks: { false },
        setAutomaticChecks: { _ in }, lastCheck: { nil })
}

/// An update a scheduled check found, shown in the menu until the user opens it (Sparkle's
/// gentle reminders: a scheduled check never opens a window on its own).
public struct FoundUpdate: Equatable, Sendable {
    public let version: String
    /// Marked `sparkle:criticalUpdate` in the appcast: a security fix.
    public let critical: Bool

    public init(version: String, critical: Bool) {
        self.version = version
        self.critical = critical
    }
}

/// Holds Sparkle's relaunch while requests wait for the user, so installing an update never
/// refuses something the user is about to allow (FR-G-03). Once nothing waits, or after
/// `maximumWait`, Sparkle quits the app as any quit does.
@MainActor
public final class UpdateRelaunchGate {
    public static let pollInterval: TimeInterval = 0.5

    private let pendingApprovals: () -> Int
    private let maximumWait: TimeInterval
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    public private(set) var isWaiting = false

    /// `maximumWait` is the approval timeout plus a margin, so every waiting request is answered
    /// or times out first.
    public init(pendingApprovals: @escaping () -> Int, maximumWait: TimeInterval,
                now: @escaping () -> Date = Date.init,
                schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(action) }
                }) {
        self.pendingApprovals = pendingApprovals
        self.maximumWait = maximumWait
        self.now = now
        self.schedule = schedule
    }

    /// Sparkle's `shouldPostponeRelaunchForUpdate`. False lets it relaunch now; true means
    /// `proceed` runs later, exactly once.
    public func postpone(_ proceed: @escaping () -> Void) -> Bool {
        guard !isWaiting, pendingApprovals() > 0 else { return false }
        isWaiting = true
        wait(until: now().addingTimeInterval(maximumWait), proceed)
        return true
    }

    private func wait(until deadline: Date, _ proceed: @escaping () -> Void) {
        schedule(Self.pollInterval) { [weak self] in
            guard let self else { return }
            if self.pendingApprovals() == 0 || self.now() >= deadline {
                self.isWaiting = false
                proceed()
            } else {
                self.wait(until: deadline, proceed)
            }
        }
    }
}
