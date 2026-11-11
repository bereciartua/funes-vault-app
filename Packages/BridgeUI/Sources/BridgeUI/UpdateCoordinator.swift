import Foundation
import Observation

/// What a Restore, Erase or Move that asked is about to do by quitting.
public enum AppRelaunch: Sendable, Equatable {
    case dataChange, move
}

/// Updates and unsaved edits (Funes FR-V-02, FR-G-03): edits are asked about in one place, the
/// quit. An update with edits around is held (the app offers Install Now); without, it waits only
/// for the approvals (`UpdateRelaunchGate`). A quit the user asks for never relaunches: the held
/// install is dropped and Sparkle installs at that quit. While Sparkle's installer may be running,
/// Restore, Erase and Move aren't started, so the app never relaunches itself under it.
///
/// Pure decisions: no AppKit. The app gives it the drafts, the alerts, the installer's state and
/// the clock, and wires Sparkle's delegate and `applicationShouldTerminate` to it.
@MainActor @Observable
public final class UpdateCoordinator<Draft: Equatable> {
    /// The two questions it asks about unsaved edits; the app words them.
    public enum Question: Sendable, Equatable { case discardAndQuit, discardAndInstall }

    /// An update is downloaded and ready, held because there are unsaved edits: the app says so
    /// and offers Install Now.
    public private(set) var updateHeld = false

    /// The unsaved edits now, by id.
    @ObservationIgnored public var drafts: () -> [UUID: Draft] = { [:] }
    /// Drops every unsaved edit (a quit the user confirmed).
    @ObservationIgnored public var discardDrafts: () -> Void = {}
    /// Asks before unsaved edits are dropped; true when the user agreed. Never called without edits.
    @ObservationIgnored public var ask: (Question) -> Bool = { _ in true }
    /// Whether Sparkle's installer may be running (from an update's download until the app quits).
    @ObservationIgnored public var installerLive: () -> Bool = { false }
    /// Tells the user an update is installing, so Restore, Erase or Move must wait.
    @ObservationIgnored public var showInstallerBusy: () -> Void = {}
    /// Tells the user a Restore, Erase or Move didn't finish because its quit was cancelled.
    @ObservationIgnored public var showRelaunchUnfinished: (AppRelaunch) -> Void = { _ in }
    /// Waits for approval panels before a relaunch.
    @ObservationIgnored public var gate: UpdateRelaunchGate?
    @ObservationIgnored public var now: () -> Date

    /// How long an answer holds for the quit that follows: Install Now's through the approvals'
    /// wait, then from the install; a Restore's, Erase's or Move's.
    public static var installAnswer: TimeInterval { 90 }
    public static var installQuit: TimeInterval { 10 }
    public static var relaunchAnswer: TimeInterval { 60 }

    /// Sparkle's install handler, until it's let go or dropped by a quit.
    @ObservationIgnored private var pendingInstall: (() -> Void)?
    /// A quit's alert is up: the approvals' wait doesn't start an install meanwhile.
    @ObservationIgnored private var quitting = false
    /// The edits a Restore, Erase, Move or Install Now just asked about, as they were then, and
    /// until when that answer holds: the quit that follows doesn't ask about them again, unless
    /// they changed since (it asks about those, and about any others).
    @ObservationIgnored private var asked: (drafts: [UUID: Draft], until: Date, forInstall: Bool)?
    /// A Restore, Erase or Move has asked and is about to quit the app.
    @ObservationIgnored private var relaunchRequested: AppRelaunch?

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    private var hasDrafts: Bool { !drafts().isEmpty }

    /// Sparkle's `shouldPostponeRelaunchForUpdate`: false relaunches now; true keeps `install`
    /// for later (held for edits, or the approvals' wait).
    public func postponeRelaunch(_ install: @escaping () -> Void) -> Bool {
        pendingInstall = install
        return !installIfFree(sparkleRelaunches: true)
    }

    /// Lets the update go if nothing holds it; true when it did. With `sparkleRelaunches`, Sparkle
    /// relaunches itself (its delegate returned false), so `install` isn't called here.
    @discardableResult
    private func installIfFree(sparkleRelaunches: Bool = false, approvalsWaited: Bool = false,
                               ignoringDrafts: Bool = false) -> Bool {
        guard let install = pendingInstall, !quitting else { return false }
        updateHeld = !ignoringDrafts && hasDrafts
        guard !updateHeld else { return false }
        if let gate, !approvalsWaited {
            if gate.isWaiting { return false }
            if gate.postpone({ [weak self] in self?.installIfFree(approvalsWaited: true, ignoringDrafts: ignoringDrafts) }) {
                return false
            }
        }
        pendingInstall = nil
        // Install Now's answer holds only for the quit this install brings, right away.
        if ignoringDrafts { asked?.until = now().addingTimeInterval(Self.installQuit) }
        if !sparkleRelaunches { install() }
        return true
    }

    /// Install Now: asks about unsaved edits (`discardAndInstall`) and lets the update go (after
    /// any approvals' wait); the edits go at the quit it brings.
    public func installHeldUpdate() {
        guard pendingInstall != nil, !hasDrafts || ask(.discardAndInstall) else { return }
        // The alert's run loop can deliver an abort; re-check. The edits go at the quit the install
        // brings, which doesn't ask about them again; if it never comes, they're kept.
        guard pendingInstall != nil else { return }
        // Held through the approvals' wait (up to the gate's maximum), then a little from the install.
        asked = (drafts(), now().addingTimeInterval(Self.installAnswer), true)
        updateHeld = false
        // An approvals' wait started earlier carries the old rule (hold for edits): start it again.
        gate?.cancel()
        installIfFree(ignoringDrafts: true)
    }

    /// Sparkle ended the update with an error: nothing is held any more.
    public func updateAborted() {
        // Only Install Now's answer depended on the update; a Restore's, Erase's or Move's stands.
        if asked?.forInstall == true { asked = nil }
        pendingInstall = nil
        updateHeld = false
        gate?.cancel()
    }

    /// `applicationShouldTerminate`: asks about unsaved edits (except ones a Restore, Erase, Move
    /// or Install Now just asked about, unchanged since), with no install starting while it asks.
    /// True: the quit goes on; the edits are dropped and a held install is let go so Sparkle
    /// installs at this quit without relaunching.
    public func confirmTermination() -> Bool {
        quitting = true
        let answer = asked.flatMap { now() < $0.until ? $0.drafts : nil } ?? [:]
        asked = nil
        let current = drafts()
        let answered = current.allSatisfy { id, draft in answer[id] == draft }
        guard answered || ask(.discardAndQuit) else {
            quitting = false
            if let relaunch = relaunchRequested {
                relaunchRequested = nil
                showRelaunchUnfinished(relaunch)
            }
            // An install held while the alert was up shows again (Install Now), or goes if free.
            installIfFree()
            return false
        }
        quitting = false
        relaunchRequested = nil
        pendingInstall = nil
        updateHeld = false
        gate?.cancel()
        discardDrafts()
        return true
    }

    /// Before Restore, Erase All Data or Move to Applications relaunch the app: refused while
    /// Sparkle's installer may be running (`showInstallerBusy` says so), then asks about unsaved
    /// edits. True: go on; the quit that follows won't ask about these edits again (and drops them
    /// then, not before, so a move whose copy never opens loses nothing).
    public func confirmAppRelaunch(_ relaunch: AppRelaunch) -> Bool {
        if installerLive() || pendingInstall != nil {
            showInstallerBusy()
            return false
        }
        guard !hasDrafts || ask(.discardAndQuit) else { return false }
        // The alert's run loop can deliver an extraction or an install; check again.
        if installerLive() || pendingInstall != nil {
            showInstallerBusy()
            return false
        }
        asked = (drafts(), now().addingTimeInterval(Self.relaunchAnswer), false)
        relaunchRequested = relaunch
        return true
    }

    /// The Restore, Erase or Move didn't start after all (its marker couldn't be written, the move
    /// failed, or the moved copy didn't open): the edits it asked about are asked about again.
    public func appRelaunchCalledOff() {
        asked = nil
        relaunchRequested = nil
    }
}
