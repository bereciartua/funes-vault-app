import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// The banner's state machine (UX: iPhone, States; FR-iOS-06).
@Suite struct ReachabilityTests {
    static func connection(_ kind: MacAddress.Kind = .lan, host: String = "192.168.1.20") -> MacConnection {
        let address = kind == .tunnel ? MacAddress(kind: .tunnel, base: URL(string: "https://maya.example.ts.net/r/abc")!)
            : MacAddress(kind: kind, host: host, port: 47626)!
        return MacConnection(address: address, status: CompanionStatus(macName: "Maya's MacBook Pro", appVersion: "0.2.0", serverTime: t0,
                                                                       inboxPending: 2, vaultActive: true),
                             roundTrip: .milliseconds(40))
    }

    static let unreachable = CompanionClientError.unreachable(localNetworkDenied: false)
    static let wifi = NetworkPath(isSatisfied: true, usesWiFi: true)
    static let cellular = NetworkPath(isSatisfied: true, usesCellular: true)
    static let offline = NetworkPath(isSatisfied: false)

    @Test func pairedThenConnectedAndStaysConnectedWhileChecking() {
        var tracker = ReachabilityTracker()
        #expect(tracker.state == .notPaired)
        tracker.handle(.pairing(paired: true))
        #expect(tracker.state == .connecting)
        tracker.handle(.checkStarted)
        tracker.handle(.checked(.success(Self.connection()), at: t0))
        #expect(tracker.state == .connected(Self.connection()))
        #expect(tracker.lastChecked == t0)
        // Coming to the front checks again; the banner doesn't drop to "Connecting" meanwhile.
        tracker.handle(.checkStarted)
        #expect(tracker.state.isConnected)
    }

    /// The Mac goes to sleep: a Search call gets no answer, the banner says so, and the next
    /// check after the network comes back reconnects.
    @Test func macAsleepThenAwake() {
        var tracker = ReachabilityTracker()
        tracker.handle(.pairing(paired: true))
        tracker.handle(.checked(.success(Self.connection()), at: t0))
        tracker.handle(.callFailed(Self.unreachable))
        #expect(tracker.state == .unreachable(localNetworkDenied: false))
        #expect(!tracker.state.isConnected)

        tracker.handle(.checkStarted)
        #expect(tracker.state == .connecting)
        tracker.handle(.checked(.failure(Self.unreachable), at: t0.addingTimeInterval(5)))
        #expect(tracker.state == .unreachable(localNetworkDenied: false))
        #expect(tracker.lastChecked == t0.addingTimeInterval(5))

        tracker.handle(.checked(.success(Self.connection(.tailscale, host: "100.101.102.103")), at: t0.addingTimeInterval(60)))
        #expect(tracker.state.isConnected)
    }

    /// A method's error came from a Mac that answered: the banner stays Connected.
    @Test func methodErrorsDontChangeTheBanner() {
        var tracker = ReachabilityTracker()
        tracker.handle(.checked(.success(Self.connection()), at: t0))
        tracker.handle(.callFailed(.method(CompanionError(.conflict))))
        tracker.handle(.callFailed(.method(CompanionError(.notFound))))
        tracker.handle(.callFailed(.local))
        tracker.handle(.delivered(.drained(sent: 3, rejected: 0)))
        #expect(tracker.state.isConnected)
    }

    @Test func removedOnTheMac() {
        var tracker = ReachabilityTracker()
        tracker.handle(.checked(.success(Self.connection()), at: t0))
        tracker.handle(.callFailed(.refused(.revoked)))
        #expect(tracker.state == .revoked)
        // Still removed while checking, and when a later call can't reach the Mac at all.
        tracker.handle(.checkStarted)
        #expect(tracker.state == .revoked)

        var viaDelivery = ReachabilityTracker()
        viaDelivery.handle(.checked(.success(Self.connection()), at: t0))
        viaDelivery.handle(.delivered(.revoked))
        #expect(viaDelivery.state == .revoked)
        viaDelivery.handle(.pairing(paired: false))
        #expect(viaDelivery.state == .notPaired)
        #expect(viaDelivery.lastChecked == nil)

        var unknown = ReachabilityTracker()
        unknown.handle(.checked(.failure(.refused(.unknownDevice)), at: t0))
        #expect(unknown.state == .revoked)
    }

    @Test func deliveryFailureMeansUnreachable() {
        var tracker = ReachabilityTracker()
        tracker.handle(.checked(.success(Self.connection()), at: t0))
        tracker.handle(.delivered(.failed(Self.unreachable, retryAt: t0, sent: 0)))
        #expect(tracker.state == .unreachable(localNetworkDenied: false))
    }

    @Test func networkPathChanges() {
        var tracker = ReachabilityTracker()
        tracker.handle(.checked(.success(Self.connection()), at: t0))
        tracker.handle(.path(Self.offline))
        #expect(tracker.state == .unreachable(localNetworkDenied: false))
        tracker.handle(.path(Self.cellular))
        #expect(tracker.state == .connecting)

        var notPaired = ReachabilityTracker()
        notPaired.handle(.path(Self.offline))
        notPaired.handle(.callFailed(Self.unreachable))
        #expect(notPaired.state == .notPaired)
    }

    @Test func otherFailures() {
        var tracker = ReachabilityTracker()
        tracker.handle(.checked(.failure(.badResponse(status: 404)), at: t0))
        #expect(tracker.state == .failed(.badResponse(status: 404)))
        tracker.handle(.checkStarted)
        #expect(tracker.state == .connecting)
        tracker.handle(.checked(.failure(.unreachable(localNetworkDenied: true)), at: t0))
        #expect(tracker.state == .unreachable(localNetworkDenied: true))
    }

    @Test func banner() {
        #expect(BannerState(.connected(Self.connection()), macName: "Old name", waiting: 0, path: Self.wifi)
            == .connected(macName: "Maya's MacBook Pro", route: .wifi, waiting: 0))
        // A LAN address reached on cellular goes through a VPN (Spike 1e).
        #expect(BannerState(.connected(Self.connection()), macName: nil, waiting: 1, path: Self.cellular)
            == .connected(macName: "Maya's MacBook Pro", route: .vpn, waiting: 1))
        #expect(BannerState(.connected(Self.connection(.tailscale, host: "100.1.2.3")), macName: nil, waiting: 0, path: Self.cellular)
            == .connected(macName: "Maya's MacBook Pro", route: .tailscale, waiting: 0))
        #expect(BannerState(.connected(Self.connection(.tunnel)), macName: nil, waiting: 0, path: nil)
            == .connected(macName: "Maya's MacBook Pro", route: .tunnel, waiting: 0))

        let unreachable = BannerState(.unreachable(localNetworkDenied: false), macName: "Maya's MacBook Pro", waiting: 3, path: Self.wifi)
        #expect(unreachable == .unreachable(waiting: 3))
        #expect(unreachable.offersWhy && !unreachable.offersPairing)
        #expect(BannerState(.unreachable(localNetworkDenied: true), macName: nil, waiting: 0, path: nil) == .localNetworkOff(waiting: 0))
        #expect(BannerState(.connecting, macName: "Maya's MacBook Pro", waiting: 0, path: nil)
            == .connecting(macName: "Maya's MacBook Pro", waiting: 0))

        let revoked = BannerState(.revoked, macName: nil, waiting: 2, path: nil)
        #expect(revoked.offersPairing && !revoked.offersWhy)
        #expect(BannerState(.notPaired, macName: nil, waiting: 0, path: nil).offersPairing)
        #expect(!BannerState(.connected(Self.connection()), macName: nil, waiting: 0, path: nil).offersWhy)
    }

    @Test func whySheetHints() {
        let lanOnly = [Addresses.lan]
        let unreachable = Reachability.unreachable(localNetworkDenied: false)
        #expect(UnreachableDiagnosis(unreachable, path: Self.offline, addresses: Addresses.all, probes: []).hints == [.offline])
        #expect(UnreachableDiagnosis(unreachable, path: Self.wifi, addresses: lanOnly, probes: []).hints == [.sameWiFi, .macAsleep])
        #expect(UnreachableDiagnosis(unreachable, path: Self.cellular, addresses: lanOnly, probes: []).hints
            == [.awayWithoutTailscale, .macAsleep])
        #expect(UnreachableDiagnosis(unreachable, path: Self.cellular, addresses: Addresses.all, probes: []).hints
            == [.checkTailscale, .macAsleep])
        #expect(UnreachableDiagnosis(unreachable, path: Self.cellular, addresses: [Addresses.lan, Addresses.tunnel], probes: []).hints
            == [.macAsleep])

        let refused = [ProbeOutcome(address: MacAddress(Addresses.lan)!, outcome: "POSIXErrorCode(rawValue: 61): Connection refused")]
        #expect(UnreachableDiagnosis(.unreachable(localNetworkDenied: true), path: Self.wifi, addresses: lanOnly, probes: refused).hints
            == [.localNetworkOff, .funesNotListening, .sameWiFi, .macAsleep])
        #expect(UnreachableDiagnosis(.failed(.badResponse(status: 404)), path: nil, addresses: lanOnly, probes: []).hints
            == [.somethingElseAnswered, .sameWiFi, .macAsleep])
    }
}
