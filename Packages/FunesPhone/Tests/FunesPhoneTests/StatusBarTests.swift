import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// The status bar above the tab bar (UX: iPhone, Status bar; FR-iOS-06): the 2-second wait and
/// "Back online".
@Suite struct StatusBarTests {
    let start = ContinuousClock.now
    let connected = BannerState.connected(macName: "Maya's MacBook Pro", route: .wifi, waiting: 0)

    func at(_ seconds: Double) -> ContinuousClock.Instant { start + .milliseconds(Int(seconds * 1000)) }

    @Test func nothingWhileConnected() {
        var bar = StatusBarTimeline()
        bar.update(connected, isDemo: false, at: at(0))
        bar.tick(at: at(10))
        #expect(bar.shown == nil)
        #expect(bar.deadline == nil)
    }

    /// The launch: the pairing isn't read yet ("not paired"), then it checks, then it connects in
    /// under 2 s. The bar never shows.
    @Test func aQuickLaunchNeverShowsTheBar() {
        var bar = StatusBarTimeline()
        bar.update(.notPaired(waiting: 0), isDemo: false, at: at(0))
        bar.update(.connecting(macName: "Maya's MacBook Pro", waiting: 0), isDemo: false, at: at(0.1))
        bar.tick(at: at(1.5))
        #expect(bar.shown == nil)
        bar.update(connected, isDemo: false, at: at(1.9))
        bar.tick(at: at(5))
        #expect(bar.shown == nil)
        #expect(bar.deadline == nil)
    }

    @Test func aStateShowsOnceItHasLastedTwoSeconds() {
        var bar = StatusBarTimeline()
        bar.update(connected, isDemo: false, at: at(0))
        bar.update(.unreachable(waiting: 2), isDemo: false, at: at(10))
        #expect(bar.shown == nil)
        #expect(bar.deadline == at(12))
        bar.tick(at: at(11.9))
        #expect(bar.shown == nil)
        bar.tick(at: at(12))
        #expect(bar.shown == .state(.unreachable(waiting: 2)))
        #expect(bar.deadline == nil)
    }

    /// Counts and names change in place: a new capture while unreachable updates "· 3 waiting"
    /// at once, and doesn't restart the wait.
    @Test func newNumbersShowAtOnce() {
        var bar = StatusBarTimeline()
        bar.update(.unreachable(waiting: 2), isDemo: false, at: at(0))
        bar.update(.unreachable(waiting: 3), isDemo: false, at: at(1))
        bar.tick(at: at(2))
        #expect(bar.shown == .state(.unreachable(waiting: 3)))
        bar.update(.unreachable(waiting: 4), isDemo: false, at: at(3))
        #expect(bar.shown == .state(.unreachable(waiting: 4)))
    }

    /// A count that changes while a state waits its 2 s shows with it.
    @Test func aCountChangedWhileWaitingShows() {
        var bar = StatusBarTimeline()
        bar.update(.notPaired(waiting: 2), isDemo: false, at: at(0))
        bar.update(.unreachable(waiting: 0), isDemo: false, at: at(0.1))
        bar.update(.unreachable(waiting: 2), isDemo: false, at: at(0.5))
        bar.tick(at: at(2.1))
        #expect(bar.shown == .state(.unreachable(waiting: 2)))
    }

    /// Another state waits its own 2 s; the one shown stays meanwhile.
    @Test func aDifferentStateWaitsItsTurn() {
        var bar = StatusBarTimeline()
        bar.update(.unreachable(waiting: 0), isDemo: false, at: at(0))
        bar.tick(at: at(2))
        bar.update(.localNetworkOff(waiting: 0), isDemo: false, at: at(5))
        bar.tick(at: at(6))
        #expect(bar.shown == .state(.unreachable(waiting: 0)))
        bar.tick(at: at(7))
        #expect(bar.shown == .state(.localNetworkOff(waiting: 0)))
    }

    /// The Mac drops for a second and comes back: nothing flashes, either way.
    @Test func aQuickReconnectNeverFlashes() {
        var bar = StatusBarTimeline()
        bar.update(connected, isDemo: false, at: at(0))
        bar.update(.unreachable(waiting: 0), isDemo: false, at: at(1))
        bar.update(connected, isDemo: false, at: at(2))
        bar.tick(at: at(10))
        #expect(bar.shown == nil)

        // Shown, then connected for a second, then gone again: still "Mac not reachable".
        bar.update(.unreachable(waiting: 0), isDemo: false, at: at(20))
        bar.tick(at: at(22))
        bar.update(connected, isDemo: false, at: at(30))
        bar.update(.unreachable(waiting: 0), isDemo: false, at: at(31))
        bar.tick(at: at(40))
        #expect(bar.shown == .state(.unreachable(waiting: 0)))
        #expect(bar.deadline == nil)
    }

    @Test func backOnlineCountsTheCapturesSentThenGoes() {
        var bar = StatusBarTimeline()
        bar.update(.unreachable(waiting: 3), isDemo: false, at: at(0))
        bar.tick(at: at(2))
        // It checks again, and the check finds the Mac.
        bar.update(.connecting(macName: "Maya's MacBook Pro", waiting: 3), isDemo: false, at: at(10))
        bar.update(.connected(macName: "Maya's MacBook Pro", route: .wifi, waiting: 3), isDemo: false, at: at(10.5))
        bar.delivered(3)
        bar.update(connected, isDemo: false, at: at(11))
        #expect(bar.shown == .state(.unreachable(waiting: 3)))
        bar.tick(at: at(12.5))
        #expect(bar.shown == .backOnline(sent: 3))
        #expect(bar.deadline == at(15.5))
        bar.tick(at: at(15.4))
        #expect(bar.shown == .backOnline(sent: 3))
        bar.tick(at: at(15.5))
        #expect(bar.shown == nil)
        #expect(bar.deadline == nil)
    }

    /// Captures that go while "Back online" shows are added to its count.
    @Test func backOnlineCountsLateDeliveries() {
        var bar = StatusBarTimeline()
        bar.update(.failed(.badResponse(status: 404), waiting: 1), isDemo: false, at: at(0))
        bar.tick(at: at(2))
        bar.update(connected, isDemo: false, at: at(5))
        bar.tick(at: at(7))
        #expect(bar.shown == .backOnline(sent: 0))
        bar.delivered(1)
        #expect(bar.shown == .backOnline(sent: 1))
        // The next time away, the count starts again.
        bar.tick(at: at(10))
        bar.update(.unreachable(waiting: 0), isDemo: false, at: at(20))
        bar.tick(at: at(22))
        bar.update(connected, isDemo: false, at: at(30))
        bar.tick(at: at(32))
        #expect(bar.shown == .backOnline(sent: 0))
    }

    /// Captures sent while connected aren't news.
    @Test func deliveriesWhileConnectedDontCount() {
        var bar = StatusBarTimeline()
        bar.update(connected, isDemo: false, at: at(0))
        bar.delivered(5)
        bar.update(.unreachable(waiting: 0), isDemo: false, at: at(1))
        bar.tick(at: at(3))
        bar.update(connected, isDemo: false, at: at(4))
        bar.tick(at: at(6))
        #expect(bar.shown == .backOnline(sent: 0))
    }

    /// The Mac goes again while "Back online" shows: that state waits its 2 s, then replaces it.
    @Test func droppingAgainReplacesBackOnline() {
        var bar = StatusBarTimeline()
        bar.update(.unreachable(waiting: 0), isDemo: false, at: at(0))
        bar.tick(at: at(2))
        bar.update(connected, isDemo: false, at: at(3))
        bar.tick(at: at(5))
        bar.update(.unreachable(waiting: 1), isDemo: false, at: at(6))
        #expect(bar.deadline == at(8))
        bar.tick(at: at(7))
        #expect(bar.shown == .backOnline(sent: 0))
        bar.tick(at: at(8))
        #expect(bar.shown == .state(.unreachable(waiting: 1)))
        bar.tick(at: at(20))
        #expect(bar.shown == .state(.unreachable(waiting: 1)))
    }

    /// Connecting after pairing, or a slow first check, isn't "Back online": the bar just goes.
    @Test func connectingThenConnectedJustGoes() {
        var bar = StatusBarTimeline()
        bar.update(.notPaired(waiting: 0), isDemo: false, at: at(0))
        bar.tick(at: at(2))
        #expect(bar.shown == .state(.notPaired(waiting: 0)))
        bar.update(.connecting(macName: "Maya's MacBook Pro", waiting: 0), isDemo: false, at: at(10))
        bar.tick(at: at(12))
        #expect(bar.shown == .state(.connecting(macName: "Maya's MacBook Pro", waiting: 0)))
        bar.update(connected, isDemo: false, at: at(13))
        #expect(bar.shown == nil)
        #expect(bar.deadline == nil)
    }

    /// Removed on the Mac, then paired again: no "Back online" either.
    @Test func revokedThenPairedAgainIsNotBackOnline() {
        var bar = StatusBarTimeline()
        bar.update(.unreachable(waiting: 0), isDemo: false, at: at(0))
        bar.tick(at: at(2))
        bar.update(.revoked(waiting: 2), isDemo: false, at: at(5))
        bar.tick(at: at(7))
        #expect(bar.shown == .state(.revoked(waiting: 2)))
        bar.update(connected, isDemo: false, at: at(20))
        #expect(bar.shown == nil)
    }

    /// App Review needs the demo label on every screen, from the first frame.
    @Test func theDemoShowsAtOnceAndStays() {
        var bar = StatusBarTimeline()
        bar.update(.notPaired(waiting: 0), isDemo: true, at: at(0))
        #expect(bar.shown == .demo)
        bar.update(connected, isDemo: true, at: at(1))
        bar.delivered(2)
        bar.tick(at: at(10))
        #expect(bar.shown == .demo)
        #expect(bar.deadline == nil)
    }

    @Test func lastReachedIsWhenAndHow() {
        var tracker = ReachabilityTracker()
        tracker.handle(.pairing(paired: true))
        #expect(tracker.lastReached == nil)
        tracker.handle(.path(ReachabilityTests.cellular))
        tracker.handle(.checked(.success(ReachabilityTests.connection(.tailscale, host: "100.101.102.103")), at: t0))
        tracker.handle(.callFailed(ReachabilityTests.unreachable))
        tracker.handle(.checked(.failure(ReachabilityTests.unreachable), at: t0.addingTimeInterval(60)))
        #expect(tracker.lastReached == .init(at: t0, route: .tailscale))
        #expect(tracker.lastChecked == t0.addingTimeInterval(60))
        tracker.handle(.pairing(paired: false))
        #expect(tracker.lastReached == nil)
    }

    /// The real clock: a state shows after its 2 s without anyone calling `tick`.
    @MainActor @Test func theAppsBarShowsAfterTheWait() async throws {
        let bar = StatusBar()
        bar.update(.unreachable(waiting: 1), isDemo: false)
        #expect(bar.item == nil)
        try await Task.sleep(for: .milliseconds(2300))
        #expect(bar.item == .state(.unreachable(waiting: 1)))
        bar.update(.unreachable(waiting: 2), isDemo: false)
        #expect(bar.item == .state(.unreachable(waiting: 2)))
    }
}
