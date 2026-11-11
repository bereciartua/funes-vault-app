import BridgeUI
import Foundation
import Testing

/// The update and unsaved-edits rules (Funes FR-V-02, FR-G-03; spec 04-ux-mac.md ▸ Vault ▸
/// Unsaved edits), walked through the paths the reviews of PR #97 used.
@MainActor
final class UpdateHarness {
    var drafts: [UUID: String] = [:]
    var approvals = 0
    var installerLive = false
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var answer = true
    private(set) var asked: [UpdateCoordinator<String>.Question] = []
    private(set) var installs = 0
    private(set) var discards = 0
    private(set) var busy = 0
    private(set) var unfinished: [AppRelaunch] = []
    private var scheduled: [@MainActor () -> Void] = []
    let coordinator: UpdateCoordinator<String>

    init(gate: Bool = true) {
        coordinator = UpdateCoordinator<String>()
        coordinator.now = { [unowned self] in clock }
        coordinator.drafts = { [unowned self] in drafts }
        coordinator.discardDrafts = { [unowned self] in
            discards += 1
            drafts = [:]
        }
        coordinator.ask = { [unowned self] question in
            asked.append(question)
            return answer
        }
        coordinator.installerLive = { [unowned self] in installerLive }
        coordinator.showInstallerBusy = { [unowned self] in busy += 1 }
        coordinator.showRelaunchUnfinished = { [unowned self] in unfinished.append($0) }
        if gate {
            coordinator.gate = UpdateRelaunchGate(pendingApprovals: { [unowned self] in approvals }, maximumWait: 75,
                                                  now: { [unowned self] in clock },
                                                  schedule: { [unowned self] _, action in scheduled.append(action) })
        }
    }

    /// Sparkle hands over an update: true when it's postponed.
    func update() -> Bool { coordinator.postponeRelaunch { [unowned self] in installs += 1 } }

    /// Runs the approvals' wait's ticks until it stops scheduling.
    func tick() {
        while !scheduled.isEmpty { scheduled.removeFirst()() }
    }

    func edit() { drafts[UUID()] = "edited" }
    func pass(_ seconds: TimeInterval) { clock += seconds }
}

@Suite @MainActor struct UpdateCoordinatorTests {
    @Test func noDraftsNoApprovalsRelaunchesAtOnce() {
        let h = UpdateHarness()
        #expect(!h.update())
        #expect(h.installs == 0 && !h.coordinator.updateHeld && h.asked.isEmpty)
    }

    @Test func noDraftsWaitsForApprovalsThenInstallsOnce() {
        let h = UpdateHarness()
        h.approvals = 1
        #expect(h.update())
        #expect(h.installs == 0 && !h.coordinator.updateHeld)
        h.approvals = 0
        h.tick()
        #expect(h.installs == 1)
        h.tick()
        #expect(h.installs == 1)
    }

    @Test func draftsHoldTheUpdateUntilInstallNow() {
        let h = UpdateHarness()
        h.edit()
        #expect(h.update())
        #expect(h.coordinator.updateHeld && h.installs == 0 && h.asked.isEmpty)
        // Install Now, then Cancel: still held.
        h.answer = false
        h.coordinator.installHeldUpdate()
        #expect(h.asked == [.discardAndInstall] && h.installs == 0 && h.coordinator.updateHeld)
        // Install Now, Discard and Install: it installs; the edits wait for the quit it brings.
        h.answer = true
        h.coordinator.installHeldUpdate()
        #expect(h.installs == 1 && !h.coordinator.updateHeld && h.discards == 0)
        // That quit doesn't ask again and drops the edits.
        h.pass(2)
        #expect(h.coordinator.confirmTermination())
        #expect(h.asked == [.discardAndInstall, .discardAndInstall] && h.discards == 1)
        // A second Install Now has nothing to install.
        h.coordinator.installHeldUpdate()
        #expect(h.installs == 1)
    }

    @Test func installNowWaitsForApprovalsAndItsAnswerLastsThrough() {
        let h = UpdateHarness()
        h.edit()
        h.approvals = 1
        #expect(h.update())
        #expect(h.coordinator.updateHeld)
        h.coordinator.installHeldUpdate()
        #expect(h.installs == 0)
        // The approvals' wait takes 80 s: Install Now's answer (90 s) still holds, then 10 s from the install.
        h.pass(80)
        h.approvals = 0
        h.tick()
        #expect(h.installs == 1)
        h.pass(9)
        #expect(h.coordinator.confirmTermination())
        #expect(h.asked == [.discardAndInstall])
    }

    @Test func editsChangedAfterTheQuestionAreAskedAbout() {
        let h = UpdateHarness()
        let id = UUID()
        h.drafts[id] = "first"
        #expect(h.update())
        h.coordinator.installHeldUpdate()
        #expect(h.installs == 1)
        h.drafts[id] = "changed"
        h.answer = false
        #expect(!h.coordinator.confirmTermination())
        #expect(h.asked == [.discardAndInstall, .discardAndQuit] && h.discards == 0)
    }

    /// An install whose quit never comes: the edits are kept, and a later quit asks about them.
    @Test func aDeadInstallHandlerKeepsTheEdits() {
        let h = UpdateHarness()
        h.edit()
        #expect(h.update())
        h.coordinator.installHeldUpdate()
        #expect(h.installs == 1 && h.discards == 0)
        h.pass(UpdateCoordinator<String>.installQuit + 1)
        h.answer = false
        #expect(!h.coordinator.confirmTermination())
        #expect(h.asked.last == .discardAndQuit && h.discards == 0 && h.installs == 1)
    }

    @Test func anAbortLetsGoOfTheHeldUpdate() {
        let h = UpdateHarness()
        h.edit()
        #expect(h.update())
        h.coordinator.updateAborted()
        #expect(!h.coordinator.updateHeld)
        h.coordinator.installHeldUpdate()
        #expect(h.installs == 0 && h.asked.isEmpty)
        // Nothing is pending: Restore can go.
        #expect(h.coordinator.confirmAppRelaunch(.dataChange))
    }

    /// An abort drops Install Now's answer, not a Restore's.
    @Test func anAbortKeepsARelaunchAnswer() {
        let h = UpdateHarness()
        h.edit()
        #expect(h.coordinator.confirmAppRelaunch(.move))
        h.coordinator.updateAborted()
        #expect(h.coordinator.confirmTermination())
        #expect(h.asked == [.discardAndQuit] && h.discards == 1)
    }

    @Test func aQuitWithAHeldUpdateDropsItsInstall() {
        let h = UpdateHarness()
        h.edit()
        #expect(h.update())
        #expect(h.coordinator.confirmTermination())
        #expect(h.installs == 0 && !h.coordinator.updateHeld && h.discards == 1)
        h.coordinator.installHeldUpdate()
        h.tick()
        #expect(h.installs == 0)
    }

    @Test func aQuitDuringTheApprovalsWaitCancelsIt() {
        let h = UpdateHarness()
        h.approvals = 1
        #expect(h.update())
        #expect(h.coordinator.confirmTermination())
        #expect(h.asked.isEmpty)
        h.approvals = 0
        h.tick()
        #expect(h.installs == 0)
    }

    @Test func aCancelledQuitShowsTheHeldUpdateAgain() {
        let h = UpdateHarness()
        h.edit()
        #expect(h.update())
        h.answer = false
        #expect(!h.coordinator.confirmTermination())
        #expect(h.coordinator.updateHeld && h.installs == 0 && h.discards == 0)
    }

    /// Edits saved while the quit's alert was up, then Cancel: the update goes, as it's free now.
    @Test func aCancelledQuitInstallsWhenTheEditsWentMeanwhile() {
        let h = UpdateHarness()
        h.edit()
        #expect(h.update())
        h.coordinator.ask = { [unowned h] _ in
            h.drafts = [:]
            return false
        }
        #expect(!h.coordinator.confirmTermination())
        #expect(h.installs == 1 && !h.coordinator.updateHeld)
    }

    @Test func aQuitWithoutEditsOrUpdateDoesntAsk() {
        let h = UpdateHarness()
        #expect(h.coordinator.confirmTermination())
        #expect(h.asked.isEmpty && h.discards == 1)
    }

    @Test func relaunchesAreRefusedWhileTheInstallerMayRun() {
        let h = UpdateHarness()
        h.installerLive = true
        #expect(!h.coordinator.confirmAppRelaunch(.dataChange))
        #expect(!h.coordinator.confirmAppRelaunch(.move))
        #expect(h.busy == 2 && h.asked.isEmpty)
        // Or while an update is held.
        h.installerLive = false
        h.edit()
        #expect(h.update())
        #expect(!h.coordinator.confirmAppRelaunch(.dataChange))
        #expect(h.busy == 3)
    }

    /// The installer starts while the question is up: refused after the answer too.
    @Test func anInstallerThatStartsDuringTheQuestionRefusesIt() {
        let h = UpdateHarness()
        h.edit()
        h.coordinator.ask = { [unowned h] _ in
            h.installerLive = true
            return true
        }
        #expect(!h.coordinator.confirmAppRelaunch(.dataChange))
        #expect(h.busy == 1)
    }

    @Test func aRelaunchAnswerHoldsForItsQuitThenExpires() {
        let h = UpdateHarness()
        h.edit()
        h.answer = true
        #expect(h.coordinator.confirmAppRelaunch(.dataChange))
        h.pass(UpdateCoordinator<String>.relaunchAnswer - 1)
        #expect(h.coordinator.confirmTermination())
        #expect(h.asked == [.discardAndQuit])

        let late = UpdateHarness()
        late.edit()
        #expect(late.coordinator.confirmAppRelaunch(.dataChange))
        late.pass(UpdateCoordinator<String>.relaunchAnswer + 1)
        #expect(late.coordinator.confirmTermination())
        #expect(late.asked == [.discardAndQuit, .discardAndQuit])
    }

    @Test func aRelaunchCalledOffAsksAgainAtTheQuit() {
        let h = UpdateHarness()
        h.edit()
        #expect(h.coordinator.confirmAppRelaunch(.move))
        h.coordinator.appRelaunchCalledOff()
        h.answer = false
        #expect(!h.coordinator.confirmTermination())
        #expect(h.asked == [.discardAndQuit, .discardAndQuit] && h.unfinished.isEmpty)
    }

    /// A Restore's quit cancelled (an edit made just then): the app says it didn't finish.
    @Test func aCancelledRelaunchQuitSaysSo() {
        let h = UpdateHarness()
        h.edit()
        #expect(h.coordinator.confirmAppRelaunch(.dataChange))
        h.edit()
        h.answer = false
        #expect(!h.coordinator.confirmTermination())
        #expect(h.unfinished == [.dataChange])
        // Said once.
        #expect(!h.coordinator.confirmTermination())
        #expect(h.unfinished == [.dataChange])
    }

    @Test func refusingTheRelaunchQuestionStartsNothing() {
        let h = UpdateHarness()
        h.edit()
        h.answer = false
        #expect(!h.coordinator.confirmAppRelaunch(.move))
        #expect(!h.coordinator.confirmTermination())
        #expect(h.asked == [.discardAndQuit, .discardAndQuit] && h.unfinished.isEmpty)
    }

    @Test func withoutAGateItInstallsAtOnce() {
        let h = UpdateHarness(gate: false)
        h.edit()
        #expect(h.update())
        h.coordinator.installHeldUpdate()
        h.coordinator.installHeldUpdate()
        #expect(h.installs == 1)
    }
}
