import BridgeKitRemote
import Foundation
import Testing
@testable import BridgeUI

/// Remote Access's automatic turn-off holds whatever the app's server state (PR #9 review).
@MainActor
@Suite("Remote Access controller")
struct RemoteAccessControllerTests {
    final class Calls {
        var starts = 0
        var stops = 0
    }

    func make(_ calls: Calls, configure: (UserDefaults) -> Void = { _ in }) -> (RemoteAccessController, UserDefaults, String) {
        let suite = "funes-remote-controller-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        configure(defaults)
        var host = RemoteAccessHost.inert
        host.start = { _ in calls.starts += 1 }
        host.stop = { calls.stops += 1 }
        let controller = RemoteAccessController(defaults: defaults, appName: "Funes Vault", names: .funes,
                                                defaultPort: 47_627, host: host)
        return (controller, defaults, suite)
    }

    /// Funnel shared with other apps: the guide uses the check's free port, the Tunnel row the
    /// address's, and neither offers a command for a port another app serves.
    @Test func funnelPorts() {
        let calls = Calls()
        let (controller, defaults, suite) = make(calls)
        defer { defaults.removePersistentDomain(forName: suite) }
        func ports(_ entries: [(Int, [Int], Bool)]) -> FunnelPorts {
            FunnelPorts(entries: entries.map { FunnelPorts.Entry(publicPort: $0.0, host: "my-mac.tail1234.ts.net",
                                                                  targets: $0.1, funnel: $0.2) }, port: 47_627)
        }
        let waiting = TunnelHealth.notRunning(reason: .noTunnel)
        controller.reviewSet(enabled: true, origin: nil, tunnel: .tailscaleFunnel, health: waiting,
                             funnel: ports([(443, [47616], true)]))
        #expect(controller.guideFunnelPort == 8443 && controller.funnelExampleAddress == "https://my-mac.tail1234.ts.net:8443",
                "443 serves another app: 8443")
        controller.reviewSet(enabled: true, origin: nil, tunnel: .tailscaleFunnel, health: .unknown)
        #expect(controller.guideFunnelPort == 443 && controller.funnelExampleAddress == "https://my-mac.tail1234.ts.net",
                "couldn't check: 443, with the warning")
        controller.reviewSet(enabled: true, origin: nil, tunnel: .tailscaleFunnel,
                             health: .notRunning(reason: .allPortsTaken),
                             funnel: ports([(443, [47616], true), (8443, [4000], false), (10000, [5432], true)]))
        #expect(controller.guideFunnelPort == nil, "all taken: no command")
        // In use at :8443, Funnel stopped: start it there again, unless another app took 8443.
        controller.reviewSet(enabled: true, origin: "https://my-mac.tail1234.ts.net:8443", tunnel: .tailscaleFunnel,
                             health: waiting, funnel: ports([(443, [47616], true)]))
        #expect(controller.inUseFunnelPort == 8443, "the address's port")
        controller.reviewSet(enabled: true, origin: "https://my-mac.tail1234.ts.net:8443", tunnel: .tailscaleFunnel,
                             health: waiting, funnel: ports([(443, [47616], true), (8443, [4000], true)]))
        #expect(controller.inUseFunnelPort == nil, "another app took the address's port")
    }

    @Test func anExpiredTurnOffAtLaunchTurnsItOff() {
        let calls = Calls()
        let (controller, defaults, suite) = make(calls) {
            $0.set(true, forKey: RemoteAccessController.Key.enabled)
            $0.set(Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate, forKey: RemoteAccessController.Key.offAt)
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.launch()
        #expect(!controller.enabled && calls.starts == 0 && calls.stops == 1)
        #expect(defaults.bool(forKey: RemoteAccessController.Key.enabled) == false)
    }

    /// Agents were off at launch, Remote Access was turned on with a turn-off that has passed by
    /// the time agents are allowed again: it turns off instead of starting.
    @Test func resumingAfterTheTurnOffPassedTurnsItOff() {
        let calls = Calls()
        let (controller, defaults, suite) = make(calls)
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.launch()
        controller.setAutoOff(3_600)
        controller.apply(true)
        #expect(controller.enabled && calls.starts == 1)
        controller.resumeListening()
        #expect(calls.starts == 2, "still within the hour: the listener starts again")
        // A turn-off a moment from now, which passes before agents are allowed again.
        controller.setAutoOff(0.001)
        Thread.sleep(forTimeInterval: 0.01)
        controller.resumeListening()
        #expect(!controller.enabled && calls.starts == 2, "the passed turn-off wins over resuming")
    }
}
