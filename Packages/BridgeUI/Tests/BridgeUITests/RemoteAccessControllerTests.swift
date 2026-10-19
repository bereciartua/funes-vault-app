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

    /// Funnel shared with other apps by path: the guide uses 443 unless it can't take the paths,
    /// the Tunnel row the address's port and the missing paths, and neither offers a command that
    /// would make another app's tailnet-only entry public.
    @Test func funnelPorts() {
        let calls = Calls()
        let (controller, defaults, suite) = make(calls)
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.reviewSet(enabled: true, origin: nil, tunnel: .tailscaleFunnel, health: .unknown)
        let paths = controller.publicPaths
        #expect(paths.count == 4 && paths[0] == "/r/" + controller.secret, "the secret prefix and three discovery paths")
        func entry(_ port: Int, _ handlers: [(String, Int, String)], funnel: Bool) -> FunnelPorts.Entry {
            FunnelPorts.Entry(publicPort: port, host: "my-mac.tail1234.ts.net",
                              handlers: handlers.map { FunnelPorts.Handler(path: $0.0, port: $0.1, targetPath: $0.2) },
                              funnel: funnel)
        }
        func ports(_ entries: [FunnelPorts.Entry]) -> FunnelPorts { FunnelPorts(entries: entries, port: 47_627, paths: paths) }
        let waiting = TunnelHealth.notRunning(reason: .noTunnel)
        let ek = entry(443, [("/", 47616, "")], funnel: true)
        controller.reviewSet(enabled: true, origin: nil, tunnel: .tailscaleFunnel, health: waiting, funnel: ports([ek]))
        #expect(controller.guideFunnelPort == 443 && controller.funnelExampleAddress == "https://my-mac.tail1234.ts.net",
                "EK Bridge's / on 443 is shared: 443, no port in the address")
        #expect(controller.guideFunnelPort == 443 && controller.funnelExampleAddress == "https://my-mac.tail1234.ts.net")
        controller.reviewSet(enabled: true, origin: nil, tunnel: .tailscaleFunnel, health: waiting,
                             funnel: ports([entry(443, [("/", 4000, "")], funnel: false)]))
        #expect(controller.guideFunnelPort == 8443 && controller.funnelExampleAddress == "https://my-mac.tail1234.ts.net:8443",
                "a tailnet-only 443 would become public: 8443")
        controller.reviewSet(enabled: true, origin: nil, tunnel: .tailscaleFunnel, health: .notRunning(reason: .noSharablePort),
                             funnel: ports([entry(443, [("/", 4000, "")], funnel: false),
                                            entry(8443, [("/", 4001, "")], funnel: false),
                                            FunnelPorts.Entry(publicPort: 10000, host: nil, handlers: [], funnel: true,
                                                              tcpForward: 5432)]))
        #expect(controller.guideFunnelPort == nil, "nothing shareable: no command")
        // In use with three of four paths: the Tunnel row adds the missing one, on the address's port.
        let three = paths.prefix(3).map { ($0, 47_627, $0) }
        controller.reviewSet(enabled: true, origin: "https://my-mac.tail1234.ts.net", tunnel: .tailscaleFunnel,
                             health: .incomplete(address: "https://my-mac.tail1234.ts.net", missing: 1),
                             funnel: ports([entry(443, [("/", 47616, "")] + three, funnel: true)]))
        #expect(controller.inUseFunnelPort == 443 && controller.inUseFunnelPaths == [paths[3]], "the missing path")
        // The address's port now tailnet-only: no command.
        controller.reviewSet(enabled: true, origin: "https://my-mac.tail1234.ts.net:8443", tunnel: .tailscaleFunnel,
                             health: waiting, funnel: ports([entry(8443, [("/", 4000, "")], funnel: false)]))
        #expect(controller.inUseFunnelPort == nil, "a tailnet-only entry took the address's port")
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
