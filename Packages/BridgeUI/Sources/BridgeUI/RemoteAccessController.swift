import AppKit
import BridgeKitCore
import BridgeKitRemote
import Foundation
import Observation

// Adapted from EK Bridge's BridgeAppModel, its Remote Access part (e753b22): the settings, the
// four-step guide, the tunnel checks, Test, Switch Tunnel… and Address ▸ Edit…, the automatic
// turn-off and keep-awake. The app's side (its listener, its agents and their cloud apps, its
// notifications) comes through `RemoteAccessHost`. No app types here.

/// What a reachability test found, for the Status row.
public enum RemoteTestState: Equatable, Sendable {
    case notTested
    case testing
    case reachable(rtt: TimeInterval, tunnel: TunnelProvider?, at: Date)
    case notReachable(reason: String, at: Date)
}

/// The guide's steps: 1 choose a tunnel, 2 turn on and start it, 3 paste its address, 4 test.
/// Derived, not stored, apart from the tunnel choice and "I've started it" (EK Bridge's RemoteGuide).
public enum RemoteGuide {
    public enum Step: Int, Equatable, Sendable { case chooseTunnel = 1, startTunnel, pasteAddress, test, done }

    public static func step(tunnelChosen: Bool, remoteOn: Bool, started: Bool, origin: String?,
                            reachable: Bool) -> Step {
        guard tunnelChosen else { return .chooseTunnel }
        guard remoteOn, started || origin != nil else { return .startTunnel }
        guard origin != nil else { return .pasteAddress }
        return reachable ? .done : .test
    }
}

/// One agent with cloud access, as the Remote Access page and Switch Tunnel… list it.
public struct RemoteCloudAgent: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let hasRemoteToken: Bool
    /// Its OAuth-connected cloud apps, by name.
    public let apps: [String]

    public init(id: String, name: String, hasRemoteToken: Bool, apps: [String]) {
        self.id = id
        self.name = name
        self.hasRemoteToken = hasRemoteToken
        self.apps = apps
    }
}

/// The app's side of Remote Access.
@MainActor
public struct RemoteAccessHost {
    public var start: (RemoteConfiguration) -> Void
    /// New settings without a restart; returns how many OAuth connections the new MCP URL ended.
    public var update: (RemoteConfiguration) -> Int
    /// Closes the port and ends pairing.
    public var stop: () -> Void
    public var test: (RemoteConfiguration, @escaping @MainActor @Sendable (Result<RemoteProbeResult, RemoteProbeFailure>) -> Void) -> Void
    public var portIsFree: (Int) -> Bool
    public var setKeepAwake: (Bool) -> Void
    public var onACPower: () -> Bool
    public var tunnels: TunnelChecks
    public var cloudAgents: () -> [RemoteCloudAgent]
    /// The local MCP port, which the remote one must not use.
    public var mcpPort: () -> Int
    /// The tunnel in use stopped while Remote Access is on (the optional notification).
    public var tunnelDown: (TunnelProvider) -> Void
    /// Something the menu bar or sidebar shows changed.
    public var changed: () -> Void

    public init(start: @escaping (RemoteConfiguration) -> Void, update: @escaping (RemoteConfiguration) -> Int,
                stop: @escaping () -> Void,
                test: @escaping (RemoteConfiguration, @escaping @MainActor @Sendable (Result<RemoteProbeResult, RemoteProbeFailure>) -> Void) -> Void,
                portIsFree: @escaping (Int) -> Bool, setKeepAwake: @escaping (Bool) -> Void,
                onACPower: @escaping () -> Bool, tunnels: TunnelChecks, cloudAgents: @escaping () -> [RemoteCloudAgent],
                mcpPort: @escaping () -> Int, tunnelDown: @escaping (TunnelProvider) -> Void,
                changed: @escaping () -> Void) {
        self.start = start
        self.update = update
        self.stop = stop
        self.test = test
        self.portIsFree = portIsFree
        self.setKeepAwake = setKeepAwake
        self.onACPower = onACPower
        self.tunnels = tunnels
        self.cloudAgents = cloudAgents
        self.mcpPort = mcpPort
        self.tunnelDown = tunnelDown
        self.changed = changed
    }

    /// Does nothing: for previews and the UI-review build's defaults.
    public static var inert: RemoteAccessHost {
        RemoteAccessHost(start: { _ in }, update: { _ in 0 }, stop: {}, test: { _, done in done(.failure(.noAnswer)) },
                         portIsFree: { _ in true }, setKeepAwake: { _ in }, onACPower: { true }, tunnels: .unavailable,
                         cloudAgents: { [] }, mcpPort: { 47_625 }, tunnelDown: { _ in }, changed: {})
    }
}

/// Remote Access's state and actions, for the page, the menu bar and the sidebar. Settings live
/// in user defaults (storage §1); the secret path is defense in depth, not a credential.
@MainActor @Observable
public final class RemoteAccessController {
    public enum Key {
        public static let enabled = "RemoteAccessEnabled"
        public static let port = "RemoteAccessPort"
        public static let secret = "RemoteAccessSecretPath"
        public static let origin = "RemoteAccessPublicAddress"
        public static let autoOff = "RemoteAccessAutoOff"
        public static let offAt = "RemoteAccessOffAt"
        public static let keepAwake = "RemoteAccessKeepAwake"
        public static let tunnelChoice = "RemoteTunnelChoice"
        public static let notifyTunnelDown = "NotifyTunnelDown"
    }

    /// The choices for Turn off automatically.
    public static let autoOffChoices: [TimeInterval] = [0, 3_600, 8 * 3_600, 24 * 3_600]
    public static let validPorts = 1024...65_535

    @ObservationIgnored public var host: RemoteAccessHost
    @ObservationIgnored private let defaults: UserDefaults
    public let appName: String
    public let names: RemoteNames

    public private(set) var enabled = false
    public private(set) var port: Int
    public private(set) var secret = ""
    public private(set) var origin: String?
    /// The address Switch Tunnel… or Edit… is testing, accepted for the health check only.
    public private(set) var candidate: String?
    public private(set) var status: RemoteMCPService.Status = .off
    public private(set) var test = RemoteTestState.notTested
    public private(set) var autoOff: TimeInterval = 0
    public private(set) var offAt: Date?
    public private(set) var keepAwake = false
    /// The last thing that happened, said once at the top of the page ("New secret path.").
    public var notice: String?

    public var tunnelChoice = TunnelProvider.tailscaleFunnel {
        didSet {
            defaults.set(tunnelChoice.rawValue, forKey: Key.tunnelChoice)
            tunnelChosen = true
        }
    }
    public private(set) var tunnelChosen = false
    /// The guide is in progress (shown even once Remote Access is on).
    public var guideActive = false
    public var tunnelStarted = false
    public var editingAddress = false
    public private(set) var tunnelSwitch: TunnelSwitch?
    public private(set) var rememberedAddresses = [TunnelProvider: String]()
    /// Guide step 2's hostname for Cloudflare Tunnel and ngrok.
    public var guideHostname = ""
    /// Step 3's address, filled in from the running tunnel.
    public private(set) var guideAddress: String?
    @ObservationIgnored private var guideAdvancedThisEntry = false
    public private(set) var tunnelHealth: TunnelHealth?
    /// What Tailscale serves on this Mac's public ports, from the same check (Funnel only).
    public private(set) var tunnelFunnel: FunnelPorts?
    public private(set) var tunnelHealthProvider: TunnelProvider?
    public private(set) var tunnelHealthCheckedAt: Date?
    public private(set) var inUseTunnelHealth: TunnelHealth?
    /// What Tailscale serves, at the last check of the tunnel in use (for its off commands).
    @ObservationIgnored private var inUseFunnel: FunnelPorts?
    /// After Reset Path… with Funnel: the commands that move it from the old secret's paths to the
    /// new ones, shown until a check finds the new paths, or the user dismisses them.
    public private(set) var funnelResetCommands: [String]?
    public private(set) var inUseTunnelProvider: TunnelProvider?
    /// Bumped when the agents' cloud credentials may have changed, so the page re-reads them.
    public private(set) var agentsGeneration = 0
    @ObservationIgnored private var lastTunnelDown: Bool?
    @ObservationIgnored private var lastTunnelDownNotice: Date?
    @ObservationIgnored private var tunnelCheckRunning = false
    @ObservationIgnored private var tunnelCheckAgain = false
    @ObservationIgnored private var tunnelCheckStarted: Date?
    @ObservationIgnored private var timer: Timer?

    public init(defaults: UserDefaults, appName: String, names: RemoteNames, defaultPort: Int, host: RemoteAccessHost) {
        self.defaults = defaults
        self.appName = appName
        self.names = names
        self.host = host
        enabled = defaults.bool(forKey: Key.enabled)
        let saved = defaults.integer(forKey: Key.port)
        port = Self.validPorts.contains(saved) ? saved : defaultPort
        secret = defaults.string(forKey: Key.secret).flatMap { RemoteConfiguration.validSecret($0) ? $0 : nil } ?? ""
        origin = defaults.string(forKey: Key.origin).flatMap(RemoteConfiguration.normalizedOrigin)
        autoOff = max(0, defaults.double(forKey: Key.autoOff))
        let off = defaults.double(forKey: Key.offAt)
        offAt = off > 0 ? Date(timeIntervalSinceReferenceDate: off) : nil
        keepAwake = defaults.bool(forKey: Key.keepAwake)
        if let tunnel = defaults.string(forKey: Key.tunnelChoice).flatMap(TunnelProvider.init(rawValue:)) {
            tunnelChoice = tunnel
        }
        tunnelChosen = defaults.string(forKey: Key.tunnelChoice) != nil
        rememberedAddresses = TunnelAddressMemory.load(defaults)
    }

    /// At launch, whatever the app's server state: on again if it was on (unless its automatic
    /// turn-off passed; the host decides whether the listener can start), and the clock that
    /// enforces the turn-off and runs the tunnel checks.
    public func launch() {
        if enabled {
            if let offAt, offAt <= Date() {
                apply(false)
            } else {
                if secret.isEmpty { newSecret() }
                host.start(configuration)
            }
        }
        updateKeepAwake()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: State

    public var configuration: RemoteConfiguration {
        RemoteConfiguration(secret: secret, publicOrigin: origin, port: port, candidateOrigin: candidate)
    }

    public var isListening: Bool {
        if case .listening = status { return true }
        return false
    }

    /// The URL cloud agents use, once the tunnel's address is known.
    public var mcpURL: String? { origin == nil || secret.isEmpty ? nil : configuration.mcpURL }

    /// The paths a tunnel shared by path forwards here (`RemoteConfiguration.publicPaths`).
    public var publicPaths: [String] { configuration.publicPaths }

    /// On and set up with a tunnel address. Until then nothing outside this Mac can reach it.
    public var active: Bool { enabled && origin != nil }

    public var failureText: String? {
        guard enabled, case .failed(let failure) = status else { return nil }
        switch failure {
        case .portInUse(let port): return String(localized: "Port \(String(port)) is in use by another app.")
        case .other(let reason): return reason
        }
    }

    public var cloudAgents: [RemoteCloudAgent] {
        _ = agentsGeneration
        return host.cloudAgents()
    }

    /// The sidebar's label: On, or Down while the tunnel in use isn't running.
    public var sidebarBadge: String? {
        guard enabled else { return nil }
        return tunnelDown ? String(localized: "Down") : String(localized: "On")
    }

    /// "Remote Access on · 2 cloud agents", for the menu; "· tunnel down" when it stopped.
    public var menuLine: String {
        if tunnelDown { return String(localized: "Remote Access on · tunnel down") }
        let count = cloudAgents.count
        return count == 1 ? String(localized: "Remote Access on · 1 cloud agent")
                          : String(localized: "Remote Access on · \(count) cloud agents")
    }

    public func statusDidChange(_ status: RemoteMCPService.Status) {
        if self.status != status {
            self.status = status
            host.changed()
        }
    }

    /// The agents' cloud access, tokens or apps changed.
    public func agentsChanged() { agentsGeneration += 1 }

    // MARK: On and off

    /// Turning on asks first: it opens a port a tunnel can expose to the internet.
    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        guard on else { return apply(false) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Turn on Remote Access?")
        alert.informativeText = String(localized: "Cloud agents you allow will be able to reach \(appName) through a public address from a tunnel you run. What you share with them goes to their servers. Nothing is reachable until you set up a tunnel and allow an agent cloud access.")
        alert.addButton(withTitle: String(localized: "Turn On"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        apply(true)
    }

    /// The app's server came back on (Let agents connect): the listener starts again, unless the
    /// automatic turn-off passed meanwhile, which turns Remote Access off instead.
    public func resumeListening() {
        guard enabled else { return }
        if let offAt, offAt <= Date() {
            apply(false)
            notice = String(localized: "Remote Access turned off, as scheduled.")
            return
        }
        host.start(configuration)
    }

    /// Without asking: the menu's Turn Off Remote Access, the automatic turn-off, tests.
    public func apply(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Key.enabled)
        if on {
            if secret.isEmpty { newSecret() }
            scheduleOff()
            host.start(configuration)
        } else {
            host.stop()
            status = .off
            test = .notTested
            setOffAt(nil)
            candidate = nil
            tunnelHealth = nil
            tunnelFunnel = nil
            tunnelHealthProvider = nil
            inUseTunnelHealth = nil
            lastTunnelDown = nil
            if tunnelSwitch != nil {
                tunnelSwitch?.test = .notTested
                tunnelSwitch?.confirming = false
            }
        }
        updateKeepAwake()
        host.changed()
    }

    private func newSecret() {
        secret = RemoteConfiguration.newSecret()
        defaults.set(secret, forKey: Key.secret)
    }

    public func setAutoOff(_ interval: TimeInterval) {
        autoOff = interval
        defaults.set(interval, forKey: Key.autoOff)
        if enabled { scheduleOff() }
    }

    private func scheduleOff() { setOffAt(autoOff > 0 ? Date().addingTimeInterval(autoOff) : nil) }

    private func setOffAt(_ date: Date?) {
        offAt = date
        defaults.set(date?.timeIntervalSinceReferenceDate ?? 0, forKey: Key.offAt)
    }

    public func setKeepAwake(_ on: Bool) {
        keepAwake = on
        defaults.set(on, forKey: Key.keepAwake)
        updateKeepAwake()
    }

    /// Only while Remote Access is on and the Mac is on power.
    public func updateKeepAwake() { host.setKeepAwake(enabled && keepAwake && host.onACPower()) }

    // MARK: Address, port and secret path

    public func addressIssue(_ text: String) -> String? {
        RemoteConfiguration.normalizedOrigin(text) == nil
            ? String(localized: "Enter the tunnel's https address, like https://my-mac.tail1234.ts.net, without a path.")
            : nil
    }

    /// Saves the address. Connected cloud apps are bound to the old URL, so they're disconnected.
    @discardableResult
    public func setAddress(_ text: String, switchedTo: TunnelProvider? = nil) -> String? {
        if let issue = addressIssue(text) { return issue }
        editingAddress = false
        let previous = origin
        origin = RemoteConfiguration.normalizedOrigin(text)
        defaults.set(origin, forKey: Key.origin)
        test = .notTested
        let dropped = host.update(configuration)
        agentsChanged()
        let changed = previous != nil && previous != origin
        let message = dropped > 0
            ? String(localized: "Update the URL in each cloud agent. Connected cloud apps were disconnected; connect them again.")
            : String(localized: "Update the URL in each cloud agent.")
        if let switchedTo {
            notice = String(localized: "Switched to \(switchedTo.inSentence).") + (changed ? " " + message : "")
        } else if changed {
            notice = String(localized: "The Remote Access address changed.") + " " + message
        }
        if let origin { remember(tunnelLabel, origin) }
        host.changed()
        return nil
    }

    private func remember(_ provider: TunnelProvider, _ origin: String) {
        guard rememberedAddresses[provider] != origin else { return }
        rememberedAddresses[provider] = origin
        TunnelAddressMemory.save(rememberedAddresses, defaults)
    }

    public func portIssue(_ text: String) -> String? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), Self.validPorts.contains(value) else {
            return String(localized: "Use a number from 1024 to 65535.")
        }
        if value == host.mcpPort() { return String(localized: "That's the local MCP server's port. Use a different one.") }
        if value == port && isListening { return nil }
        return host.portIsFree(value) ? nil : String(localized: "Port \(String(value)) is in use by another app.")
    }

    @discardableResult
    public func setPort(_ text: String) -> String? {
        if let issue = portIssue(text) { return issue }
        port = Int(text.trimmingCharacters(in: .whitespaces))!
        defaults.set(port, forKey: Key.port)
        test = .notTested
        if enabled { host.start(configuration) }
        notice = String(localized: "Remote Access now uses port \(String(port)). Point your tunnel at the new port.")
        return nil
    }

    /// Reset Path…: asks first, naming the agents that need the new URL and the apps it disconnects.
    public func resetSecret() {
        let agents = cloudAgents
        let alert = NSAlert()
        alert.messageText = String(localized: "Reset the secret path?")
        var lines = [String(localized: "Every cloud agent setup uses the current URL and stops working until you give it the new one.")]
        let tokens = agents.filter(\.hasRemoteToken).map(\.name)
        if !tokens.isEmpty {
            lines.append(String(localized: "Update the URL in: \(tokens.formatted(.list(type: .and)))."))
        }
        let apps = Array(Set(agents.flatMap(\.apps))).sorted()
        if !apps.isEmpty {
            lines.append(String(localized: "These cloud apps are disconnected and have to connect again: \(apps.formatted(.list(type: .and)))."))
        }
        let funnel = tunnelLabel == .tailscaleFunnel
        if funnel {
            lines.append(String(localized: "Tailscale Funnel forwards the secret path too: this page then shows the commands that move it to the new one."))
        }
        alert.informativeText = lines.joined(separator: " ")
        alert.addButton(withTitle: String(localized: "Reset Path"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let oldPaths = publicPaths
        newSecret()
        if funnel {
            let commands = TailscaleFunnelCommand.resetPath(inUseFunnel, address: origin, port: port, oldPaths: oldPaths,
                                                            newPaths: publicPaths)
            funnelResetCommands = commands.isEmpty ? nil : commands
        }
        test = .notTested
        _ = host.update(configuration)
        agentsChanged()
        notice = String(localized: "New secret path. Update the URL in each cloud agent.")
    }

    // MARK: Test

    /// One request through the tunnel to this app's own health URL, with a nonce only it issued.
    public func runTest() {
        guard enabled, origin != nil, test != .testing else { return }
        checkTunnel()
        test = .testing
        let port = self.port
        let appName = self.appName
        host.test(configuration) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value): self.test = .reachable(rtt: value.rtt, tunnel: value.tunnel, at: Date())
            case .failure(let failure): self.test = .notReachable(reason: failure.reason(appName: appName, port: port), at: Date())
            }
        }
    }

    /// The tunnel the last test went through.
    public var lastTestedTunnel: TunnelProvider? {
        if case .reachable(_, let tunnel, _) = test { return tunnel }
        return nil
    }

    /// The Tunnel row's name: the tunnel that answered the last test, then what the address
    /// looks like, then the stored choice.
    public var tunnelLabel: TunnelProvider {
        TunnelLabel.resolve(lastTested: lastTestedTunnel, address: origin, stored: tunnelChoice)
    }

    /// The Status row's reason for a failed test, when the tunnel check explains it.
    public var unreachableReason: String? {
        guard case .notReachable = test else { return nil }
        return currentTunnelHealth?.unreachableReason(tunnelCheckTarget, remotePort: port)
    }

    // MARK: Guide

    public var guideStep: RemoteGuide.Step {
        let reachable: Bool = if case .reachable = test { true } else { false }
        return RemoteGuide.step(tunnelChosen: tunnelChosen, remoteOn: enabled, started: tunnelStarted || editingAddress,
                                origin: editingAddress ? nil : origin, reachable: reachable)
    }

    public func chooseTunnelAgain() {
        defaults.removeObject(forKey: Key.tunnelChoice)
        tunnelChosen = false
        tunnelStarted = false
        guideActive = true
        guideAdvancedThisEntry = false
        guideAddress = nil
    }

    public func guideChoose(_ provider: TunnelProvider) {
        tunnelChoice = provider
        guideActive = true
        tunnelStarted = false
        guideAdvancedThisEntry = false
        guideAddress = nil
        guideHostname = ""
        if enabled { checkTunnel() }
    }

    public var tunnelStartState: TunnelStartState {
        TunnelStartState.make(remoteOn: enabled, provider: tunnelCheckTarget, health: currentTunnelHealth)
    }

    public var guideCommandHostname: String? { TunnelProvider.hostname(guideHostname) }

    public func guideContinue() {
        if case .found(let address) = tunnelStartState, let address { guideAddress = address }
        tunnelStarted = true
    }

    public func guideBackToStart() {
        tunnelStarted = false
        editingAddress = false
    }

    private func advanceGuideIfFound() {
        if let change = tunnelSwitch {
            guard change.step == .start,
                  tunnelStartState.autoAdvances(advancedThisEntry: change.advancedThisEntry) else { return }
            tunnelSwitch?.advancedThisEntry = true
            switchContinue()
            return
        }
        guard waitingForTunnel, tunnelStartState.autoAdvances(advancedThisEntry: guideAdvancedThisEntry) else { return }
        guideAdvancedThisEntry = true
        guideContinue()
    }

    // MARK: Switch Tunnel… and Address ▸ Edit…

    public func beginSwitch() {
        guard let origin else { return }
        guideActive = false
        guideHostname = ""
        guideAddress = nil
        notice = nil
        tunnelSwitch = TunnelSwitch(kind: .switchTunnel, fromTunnel: tunnelLabel, fromOrigin: origin)
    }

    public func beginEditAddress() {
        guard let origin else { return }
        guideActive = false
        guideHostname = ""
        guideAddress = nil
        notice = nil
        tunnelSwitch = TunnelSwitch(kind: .editAddress, fromTunnel: tunnelLabel, fromOrigin: origin)
    }

    public func switchChoose(_ provider: TunnelProvider) {
        guard var change = tunnelSwitch, change.canChoose(provider) else { return }
        change.picked = provider
        change.started = false
        change.advancedThisEntry = false
        change.test = .notTested
        change.address = ""
        change.addressSource = .none
        tunnelSwitch = change
        setCandidate(nil)
        guideAddress = nil
        guideHostname = provider.asksForHostname ? TunnelAddressMemory.hostname(rememberedAddresses[provider]) ?? "" : ""
        if enabled { checkTunnel() }
    }

    public func switchContinue() {
        guard var change = tunnelSwitch, let picked = change.picked else { return }
        var found: String?
        if case .found(let address) = tunnelStartState { found = address }
        if change.kind == .switchTunnel {
            (change.address, change.addressSource) = TunnelSwitch.prefill(found: found, remembered: rememberedAddresses[picked])
        }
        change.started = true
        tunnelSwitch = change
    }

    public func switchBack() {
        guard var change = tunnelSwitch else { return }
        switch change.step {
        case .choose:
            return cancelSwitch()
        case .start:
            change.picked = nil
            guideHostname = ""
        case .test:
            if change.kind == .editAddress { return cancelSwitch() }
            change.started = false
            change.test = .notTested
            setCandidate(nil)
        case .confirm:
            change.confirming = false
        }
        tunnelSwitch = change
    }

    public func setSwitchAddress(_ text: String) {
        guard tunnelSwitch != nil, tunnelSwitch?.address != text else { return }
        tunnelSwitch?.address = text
    }

    public var switchAddressIssue: String? {
        guard let text = tunnelSwitch?.address, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return addressIssue(text)
    }

    public var switchNormalizedAddress: String? {
        tunnelSwitch.flatMap { RemoteConfiguration.normalizedOrigin($0.address) }
    }

    /// The health check through the new tunnel; the server accepts the candidate for that only.
    public func switchTest() {
        guard enabled, var change = tunnelSwitch, let address = switchNormalizedAddress else { return }
        if case .testing = change.test { return }
        change.test = .testing(address: address)
        tunnelSwitch = change
        checkTunnel()
        setCandidate(address)
        var settings = configuration
        settings.publicOrigin = candidate
        let port = self.port
        let appName = self.appName
        host.test(settings) { [weak self] result in
            guard let self, var change = self.tunnelSwitch, change.test == .testing(address: address) else { return }
            switch result {
            case .success(let value):
                change.test = .reachable(address: address, ms: Int((value.rtt * 1000).rounded()), tunnel: value.tunnel)
            case .failure(let failure):
                change.test = .notReachable(address: address, reason: failure.reason(appName: appName, port: port))
            }
            self.tunnelSwitch = change
        }
    }

    public func switchContinueAs(_ provider: TunnelProvider) {
        guard tunnelSwitch?.kind == .switchTunnel, provider != tunnelSwitch?.fromTunnel else { return }
        tunnelSwitch?.picked = provider
    }

    public func switchConfirm() {
        guard let change = tunnelSwitch, change.canConfirm(normalized: switchNormalizedAddress) else { return }
        tunnelSwitch?.confirming = true
    }

    public var switchSummary: TunnelSwitchSummary? {
        guard let change = tunnelSwitch, let address = switchNormalizedAddress else { return nil }
        let agents = cloudAgents
        var apps = [String]()
        for name in agents.flatMap(\.apps) where !apps.contains(name) { apps.append(name) }
        return TunnelSwitchSummary.make(change, newOrigin: address, port: port,
                                        remoteTokenClients: agents.filter(\.hasRemoteToken).map(\.name), oauthApps: apps,
                                        offCommands: { [inUseFunnel, publicPaths] provider, _, origin in
            provider == .tailscaleFunnel
                ? TailscaleFunnelCommand.off(inUseFunnel, address: origin, paths: publicPaths) : []
        })
    }

    /// Switch (Save): the only step that saves anything.
    public func switchCommit() {
        guard let change = tunnelSwitch, let picked = change.picked, let address = switchNormalizedAddress,
              change.canConfirm(normalized: address) else { return }
        tunnelSwitch = nil
        setCandidate(nil)
        guideHostname = ""
        guideAddress = nil
        tunnelChoice = picked
        setAddress(address, switchedTo: change.kind == .switchTunnel ? picked : nil)
        remember(picked, address)
        runTest()
    }

    public func cancelSwitch() {
        tunnelSwitch = nil
        setCandidate(nil)
        guideHostname = ""
        guideAddress = nil
    }

    private func setCandidate(_ origin: String?) {
        let next = origin.flatMap(RemoteConfiguration.normalizedOrigin)
        guard next != candidate else { return }
        candidate = next
        if enabled { _ = host.update(configuration) }
    }

    // MARK: Tunnel checks on this Mac

    /// The tunnel being set up, otherwise the one in use.
    public var tunnelCheckTarget: TunnelProvider {
        if let picked = tunnelSwitch?.picked { return picked }
        return guideActive ? tunnelChoice : tunnelLabel
    }

    public var currentTunnelHealth: TunnelHealth? {
        tunnelHealthProvider == tunnelCheckTarget ? tunnelHealth : nil
    }

    public var currentFunnelPorts: FunnelPorts? {
        tunnelHealthProvider == tunnelCheckTarget ? tunnelFunnel : nil
    }

    /// Funnel's public port for the guide's commands (first setup and Switch Tunnel…): where it
    /// already runs, else the first one that can take the paths, 443 first. 443 when the check
    /// couldn't tell; nil when none can (no command then).
    public var guideFunnelPort: Int? {
        guard let ports = currentFunnelPorts else { return 443 }
        return ports.publicPort
    }

    /// Step 3's example address for Tailscale Funnel, with the port the guide uses.
    public var funnelExampleAddress: String {
        "https://my-mac.tail1234.ts.net" + (guideFunnelPort.map { $0 == 443 ? "" : ":\($0)" } ?? "")
    }

    /// Funnel's public port for the tunnel in use: the one in the address. Nil when that port
    /// can't take the paths any more (a tailnet-only entry or a TCP forwarder there now).
    public var inUseFunnelPort: Int? {
        let publicPort = TailscaleFunnelCommand.publicPort(fromAddress: origin)
        guard let ports = currentFunnelPorts, let entry = ports.entry(on: publicPort) else { return publicPort }
        return ports.sharable(publicPort) || entry.targets.contains(port) ? publicPort : nil
    }

    /// The paths the Tunnel row's fix adds: the missing ones when incomplete, else all of them.
    public var inUseFunnelPaths: [String] {
        guard let ports = currentFunnelPorts, ports.incomplete != nil else { return publicPaths }
        return ports.pathsToAdd
    }

    /// The Tunnel row's move to 443, which claude.ai and ChatGPT need: Funnel in use on 8443 or
    /// 10000 (0.1.1's drafts, or a port picked by hand), and 443 can take the paths now. In place
    /// of the start commands for the old port; not while Tailscale needs a login or the policy.
    public var inUseFunnelMove: FunnelPorts.Move? {
        guard tunnelLabel == .tailscaleFunnel, let health = currentTunnelHealth else { return nil }
        switch health {
        case .running, .incomplete, .wrongPort, .notPublic: break
        case .notRunning: guard health.showsStartCommand else { return nil }
        case .notInstalled, .unknown: return nil
        }
        return TailscaleFunnelCommand.moveTo443(currentFunnelPorts, address: origin)
    }

    public func dismissFunnelResetCommands() { funnelResetCommands = nil }

    public var waitingForTunnel: Bool {
        if let tunnelSwitch { return tunnelSwitch.step == .start }
        return guideActive && guideStep == .startTunnel
    }

    /// Remote Access is on with an address, but the tunnel in use isn't running.
    public var tunnelDown: Bool {
        TunnelHealth.isDown(remoteActive: active, health: inUseTunnelProvider == tunnelLabel ? inUseTunnelHealth : nil)
    }

    /// One check at a time; a result for a tunnel the page no longer shows runs again.
    public func checkTunnel() {
        guard !tunnelCheckRunning else { tunnelCheckAgain = true; return }
        let provider = tunnelCheckTarget
        let port = self.port
        tunnelCheckRunning = true
        tunnelCheckStarted = Date()
        host.tunnels.check(provider, port, publicPaths) { [weak self] result in
            guard let self else { return }
            self.tunnelCheckRunning = false
            let health = result.health
            let current = provider == self.tunnelCheckTarget && port == self.port
            if current {
                if self.tunnelHealth != health || self.tunnelFunnel != result.funnel || self.tunnelHealthProvider != provider {
                    self.tunnelHealth = health
                    self.tunnelFunnel = result.funnel
                    self.tunnelHealthProvider = provider
                }
                self.tunnelHealthCheckedAt = Date()
                if provider == self.tunnelLabel {
                    self.inUseFunnel = result.funnel
                    if result.funnel?.running != nil { self.funnelResetCommands = nil }
                    self.inUseChecked(provider, health)
                }
                self.advanceGuideIfFound()
            }
            if self.tunnelCheckAgain || !current {
                self.tunnelCheckAgain = false
                self.checkTunnel()
            }
        }
    }

    private func inUseChecked(_ provider: TunnelProvider, _ health: TunnelHealth) {
        let wasDown = tunnelDown
        if inUseTunnelHealth != health || inUseTunnelProvider != provider {
            inUseTunnelHealth = health
            inUseTunnelProvider = provider
        }
        let down = tunnelDown
        if down != wasDown { host.changed() }
        let now = Date()
        // Once per stop, at most hourly: a tunnel that flaps doesn't spam.
        if active, down, lastTunnelDown == false,
           lastTunnelDownNotice.map({ now.timeIntervalSince($0) >= 3_600 }) ?? true,
           defaults.bool(forKey: Key.notifyTunnelDown) {
            lastTunnelDownNotice = now
            host.tunnelDown(provider)
        }
        lastTunnelDown = active ? down : nil
    }

    /// Opening the page, or the Mac waking up.
    public func checkTunnelNow() {
        if enabled { checkTunnel() }
    }

    private func tick() {
        if enabled, let offAt, offAt <= Date() {
            apply(false)
            notice = String(localized: "Remote Access turned off, as scheduled.")
            return
        }
        let interval = TunnelCheckSchedule.interval(remoteOn: enabled, waitingForTunnel: waitingForTunnel)
        guard !tunnelCheckRunning,
              TunnelCheckSchedule.isDue(lastCheck: tunnelCheckStarted, now: Date(), interval: interval) else { return }
        checkTunnel()
    }

    #if DEBUG
    /// The UI-review build: a state without the alert.
    public func reviewSet(enabled: Bool, origin: String?, tunnel: TunnelProvider?, test: RemoteTestState = .notTested,
                          health: TunnelHealth? = nil, funnel: FunnelPorts? = nil) {
        self.enabled = enabled
        if secret.isEmpty { secret = "q7Zk2vN4bXwP9sL1mT6hYa" }
        self.origin = origin
        if let tunnel { tunnelChoice = tunnel } else { tunnelChosen = false }
        self.test = test
        status = enabled ? .listening(port: port) : .off
        if let health {
            tunnelHealth = health
            tunnelFunnel = funnel
            tunnelHealthProvider = tunnelCheckTarget
            inUseTunnelHealth = health
            inUseTunnelProvider = tunnelLabel
        }
    }
    #endif
}
