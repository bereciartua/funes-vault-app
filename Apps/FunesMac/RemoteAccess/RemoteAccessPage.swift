import BridgeKitRemote
import BridgeUI
import FunesCore
import SwiftUI

// Adapted from EK Bridge's RemoteAccessView (BridgeUI/Upstream/RemoteAccessView.swift, e753b22):
// the Remote Access page (04-ux-mac.md "Remote Access (experimental)"): an introduction until
// it's set up, the four-step guide, then status and settings, and Switch Tunnel…. The state is
// BridgeUI's RemoteAccessController; Funes's agents come from the app model.

struct RemoteAccessPage: View {
    @Bindable var model: AppModel
    var remote: RemoteAccessController { model.remoteAccess }
    @State private var portSheet = false

    private enum Mode { case intro, guide, setUp, switching(TunnelSwitch) }

    private var mode: Mode {
        if let change = remote.tunnelSwitch { return .switching(change) }
        if remote.guideActive { return .guide }
        if remote.origin != nil { return .setUp }
        return remote.enabled ? .guide : .intro
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch mode {
                case .intro:
                    header
                    intro
                case .guide:
                    header
                    RemoteGuideView(model: model)
                case .setUp:
                    header
                    notice
                    RemoteSetUpView(model: model, portSheet: $portSheet)
                case .switching(let change):
                    PaneHeader(title: change.kind == .editAddress ? String(localized: "Change address")
                                                                  : String(localized: "Switch tunnel")) { EmptyView() }
                    TunnelSwitchView(model: model, change: change)
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.pane)
        .onChange(of: remote.guideStep) { _, step in
            if step == .done { remote.guideActive = false }
        }
        .onAppear { remote.checkTunnelNow() }
        .sheet(isPresented: $portSheet) { RemotePortSheet(remote: remote, shown: $portSheet) }
        .sheet(isPresented: Binding(get: { remote.tunnelSwitch?.confirming == true },
                                    set: { if !$0, remote.tunnelSwitch?.confirming == true { remote.switchBack() } })) {
            TunnelSwitchSheet(remote: remote)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(localized: "Remote Access")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Pill(label: String(localized: "Experimental"), tone: .warning)
                    .help(String(localized: "New in this version: it may change."))
                Spacer()
                if case .setUp = mode {
                    Toggle(String(localized: "Remote Access"),
                           isOn: Binding(get: { remote.enabled }, set: { remote.setEnabled($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            Text(String(localized: "While Remote Access is on, cloud agents reach Funes Vault through a public address. What you share with them goes to their servers."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var notice: some View {
        if let text = remote.notice {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                Text(text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { remote.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Dismiss"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "Cloud agents can't reach this Mac directly. A tunnel you run (Tailscale Funnel, Cloudflare or ngrok) forwards them to a second port on it. Funes Vault never starts a tunnel."),
                          systemImage: "network")
                    Label(String(localized: "Only agents you give cloud access can be used from the internet, each with its own remote token or signed-in app, and only with the access you set for that agent. Panels still ask on this Mac."),
                          systemImage: "lock")
                    Label(String(localized: "Agents on this Mac don't need it: they connect locally."),
                          systemImage: "desktopcomputer")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button(String(localized: "Set Up Remote Access…")) { remote.guideActive = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    static func autoOffTitle(_ interval: TimeInterval) -> String {
        switch interval {
        case 0: String(localized: "Never")
        case 3_600: String(localized: "After 1 hour")
        case 28_800: String(localized: "After 8 hours")
        default: String(localized: "After 1 day")
        }
    }
}

/// The guide's four steps.
struct RemoteGuideView: View {
    let model: AppModel
    var remote: RemoteAccessController { model.remoteAccess }
    @State private var address = ""
    @State private var addressIssue: String?

    var body: some View {
        let step = remote.guideStep
        VStack(alignment: .leading, spacing: 14) {
            GuideStepsHeader(titles: [String(localized: "Choose a tunnel"), String(localized: "Start it"),
                                      String(localized: "Paste its address"), String(localized: "Test")],
                             current: step.rawValue - 1,
                             highlighted: min(step.rawValue, RemoteGuide.Step.test.rawValue) - 1)
            switch step {
            case .chooseTunnel: chooseTunnel
            case .startTunnel: startTunnel
            case .pasteAddress: pasteAddress
            case .test, .done: test
            }
        }
    }

    private var chooseTunnel: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(TunnelProvider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { RowDivider() }
                    Button {
                        remote.guideChoose(provider)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: provider == remote.tunnelChoice && remote.tunnelChosen ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Color.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                Text(provider.summary).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityLabel("\(provider.displayName). \(provider.summary)")
                }
            }
        }
    }

    private var startTunnel: some View {
        let state = remote.tunnelStartState
        return VStack(alignment: .leading, spacing: 12) {
            TunnelStartCard(model: model, provider: remote.tunnelChoice, changeTunnel: { remote.chooseTunnelAgain() })
            HStack {
                Spacer()
                Button(String(localized: "Back")) { remote.chooseTunnelAgain() }
                if state.offersContinue {
                    Button(String(localized: "Continue")) { remote.guideContinue() }.buttonStyle(.borderedProminent)
                } else if state.offersStarted {
                    Button(String(localized: "I've Started It")) { remote.guideContinue() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var pasteAddress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Text(remote.guideAddress != nil && remote.guideAddress == address
                     ? String(localized: "Filled in from the running tunnel. Check it, then save.")
                     : String(localized: "The tunnel's public https address, without a path. For Tailscale Funnel it looks like \(remote.funnelExampleAddress)."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(String(localized: "Address"), text: $address, prompt: Text(verbatim: remote.funnelExampleAddress))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityLabel(String(localized: "Tunnel address"))
                if let addressIssue { Text(addressIssue).font(.callout).foregroundStyle(.red) }
            }
            HStack {
                Spacer()
                Button(String(localized: "Back")) { remote.guideBackToStart() }
                Button(String(localized: "Save Address"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { address = remote.guideAddress ?? remote.origin ?? "" }
    }

    private func save() {
        addressIssue = remote.setAddress(address)
        if addressIssue == nil { remote.runTest() }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                HStack(spacing: 10) {
                    switch remote.test {
                    case .notTested, .testing:
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Testing \(remote.origin ?? "")…")).foregroundStyle(.secondary)
                    case .reachable:
                        Pill(label: String(localized: "Reachable"), tone: .good)
                    case .notReachable(let reason, _):
                        Pill(label: String(localized: "Not reachable"), tone: .warning)
                        Text(remote.unreachableReason ?? reason).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
            if case .notReachable = remote.test {
                HStack {
                    Spacer()
                    Button(String(localized: "Back")) { remote.editingAddress = true }
                    Button(String(localized: "Try Again")) { remote.runTest() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear { if remote.test == .notTested { remote.runTest() } }
    }
}

/// Step 2 (first setup and Switch Tunnel…): the hostname for Cloudflare Tunnel and ngrok, the
/// commands to run, and whether the tunnel runs on this Mac yet.
struct TunnelStartCard: View {
    let model: AppModel
    let provider: TunnelProvider
    var changeTunnel: (() -> Void)? = nil
    var note: String? = nil
    var remote: RemoteAccessController { model.remoteAccess }

    var body: some View {
        let hostname = remote.guideCommandHostname
        let names = remote.names
        let funnelPort = remote.guideFunnelPort
        let commands = provider.commands(port: remote.port, hostname: hostname, names: names, publicPort: funnelPort,
                                         paths: remote.publicPaths)
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(.headline)
                    HStack(spacing: 4) {
                        Text(provider.summary).foregroundStyle(.secondary)
                        if let changeTunnel {
                            Button(String(localized: "Change tunnel"), action: changeTunnel).buttonStyle(.link)
                        }
                    }
                    .font(.callout)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                RowDivider()
                if !remote.enabled {
                    HStack(spacing: 12) {
                        Text(String(localized: "First, turn on Remote Access. Port \(String(remote.port)) opens on this Mac for the tunnel; nothing is reachable until the tunnel runs."))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Button(String(localized: "Turn On Remote Access")) { remote.setEnabled(true) }
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                    }
                    .padding(16)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if provider.asksForHostname {
                            HStack(spacing: 10) {
                                Text(String(localized: "Hostname")).foregroundStyle(.secondary)
                                TextField(String(localized: "Hostname"), text: Binding(
                                    get: { remote.guideHostname }, set: { remote.guideHostname = $0 }),
                                          prompt: Text(verbatim: provider.hostnamePlaceholder))
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel(String(localized: "Hostname for \(provider.name)"))
                            }
                            Text(provider == .ngrok
                                 ? String(localized: "Your ngrok dev domain, from the ngrok dashboard. The commands below use it.")
                                 : String(localized: "A hostname on your Cloudflare domain for this Mac. The commands below use it."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if provider == .tailscaleFunnel, let line = funnelLine {
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !commands.isEmpty {
                            CodeBox(text: commands.joined(separator: "\n"), copy: true)
                        }
                        if provider == .tailscaleFunnel, let funnelPort, !commands.isEmpty {
                            Text(String(localized: "To turn it off later:")).font(.callout).foregroundStyle(.secondary)
                            CodeBox(text: provider.offCommands(port: remote.port, publicPort: funnelPort,
                                                               paths: remote.publicPaths).joined(separator: "\n"), copy: true)
                        }
                        if let config = provider.configFile(port: remote.port, hostname: hostname, names: names) {
                            Text(verbatim: "~/.cloudflared/config.yml").font(.callout.monospaced()).foregroundStyle(.secondary)
                            CodeBox(text: config, copy: true)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text([String(localized: "Run it in Terminal. It prints the tunnel's https address; you paste it next."),
                                  note].compactMap { $0 }.joined(separator: " "))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            InfoButton(text: (provider.steps + provider.notes).joined(separator: "\n\n"))
                        }
                        .font(.callout)
                    }
                    .padding(16)
                    if provider != .other {
                        RowDivider()
                        TunnelStartStatus(model: model, provider: provider)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }
}

extension TunnelStartCard {
    /// Why Funnel uses another public port, what's on all three, or that the check couldn't tell.
    var funnelLine: String? {
        guard let health = remote.currentTunnelHealth else { return nil }
        if let ports = remote.currentFunnelPorts { return ports.reason(names: remote.names) }
        return health == .unknown ? FunnelPorts.unknownWarning(names: remote.names) : nil
    }
}

/// "Waiting for Tailscale Funnel…", then "Running · on this Mac · forwards to 47627", or what's wrong.
struct TunnelStartStatus: View {
    let model: AppModel
    let provider: TunnelProvider
    var remote: RemoteAccessController { model.remoteAccess }

    var body: some View {
        let state = TunnelStartState.make(remoteOn: remote.enabled, provider: provider, health: remote.currentTunnelHealth)
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .turnOn, .cantCheck(nil):
                EmptyView()
            case .waiting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Waiting for \(provider.name)…")).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .found(let address):
                TunnelHealthLine(health: remote.currentTunnelHealth ?? .running(address: address, port: remote.port),
                                 provider: provider, remotePort: remote.port, mcpPort: model.mcpPort, address: address)
                    .accessibilityElement(children: .combine)
            case .problem(let health), .cantCheck(.some(let health)):
                TunnelHealthLine(health: health, provider: provider, remotePort: remote.port, mcpPort: model.mcpPort)
                    .accessibilityElement(children: .combine)
                TunnelFix(health: health, provider: provider, remotePort: remote.port,
                          hostname: remote.guideCommandHostname, names: remote.names,
                          funnelPort: remote.guideFunnelPort, paths: remote.publicPaths)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Set up: status, tunnel, address, URL, port, turn-off timer, keep awake, then the agents with
/// cloud access.
struct RemoteSetUpView: View {
    let model: AppModel
    @Binding var portSheet: Bool
    var remote: RemoteAccessController { model.remoteAccess }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    statusRow
                    RowDivider()
                    tunnelRow
                    RowDivider()
                    ValueRow(label: String(localized: "Address")) {
                        if let origin = remote.origin { MonoText(text: origin) } else { Text(verbatim: "—").foregroundStyle(.tertiary) }
                    } actions: {
                        Button(String(localized: "Edit…")) { remote.beginEditAddress() }
                    }
                    RowDivider()
                    ValueRow(label: String(localized: "MCP URL")) {
                        if let url = remote.mcpURL { MonoText(text: url) } else { Text(verbatim: "—").foregroundStyle(.tertiary) }
                    } actions: {
                        Button(String(localized: "Reset Path…")) { remote.resetSecret() }
                    }
                    RowDivider()
                    ValueRow(label: String(localized: "Port")) {
                        Text(verbatim: String(remote.port)).font(.system(.callout, design: .monospaced))
                    } actions: {
                        Button(String(localized: "Change…")) { portSheet = true }
                    }
                    RowDivider()
                    ValueRow(label: String(localized: "Turn off")) {
                        HStack(spacing: 16) {
                            Picker(String(localized: "Turn off automatically"), selection: Binding(
                                get: { remote.autoOff }, set: { remote.setAutoOff($0) })) {
                                ForEach(RemoteAccessController.autoOffChoices, id: \.self) { interval in
                                    Text(RemoteAccessPage.autoOffTitle(interval)).tag(interval)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            if let offAt = remote.offAt {
                                Text(String(localized: "at \(offAt.formatted(date: .omitted, time: .shortened))"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } actions: { EmptyView() }
                    RowDivider()
                    ValueRow(label: "") {
                        Toggle(String(localized: "Keep this Mac awake while on power"),
                               isOn: Binding(get: { remote.keepAwake }, set: { remote.setKeepAwake($0) }))
                            .toggleStyle(.checkbox)
                    } actions: { EmptyView() }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Agents with cloud access")).font(.headline)
                let agents = model.agents.filter(\.cloudAccess)
                if agents.isEmpty {
                    Text(String(localized: "No agent can be used from the cloud yet. Turn on Allow cloud access in an agent's Cloud tab, or add a cloud agent with Add Agent…."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                                if index > 0 { RowDivider() }
                                Button {
                                    model.agentTab = .cloud
                                    model.showAgent(agent.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        AgentIcon(kind: agent.agentKind, size: 24)
                                        Text(agent.name)
                                        Spacer()
                                        Text(model.cloudCredentialsLine(agent)).foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(RowButtonStyle())
                            }
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(localized: "Use one agent per cloud app, with only the access it needs."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                InfoButton(text: String(localized: "Port \(String(remote.port)) is open only while Remote Access is on. Cloud agents reach Funes Vault only while this Mac is awake, logged in and running it.\n\nRemote tokens and cloud apps never work on the local MCP port, and local keys never work remotely. Turning off Remote Access cuts off every cloud agent at once."))
            }
            .font(.callout)
        }
    }

    private var statusRow: some View {
        ValueRow(label: String(localized: "Status")) {
            HStack(spacing: 10) {
                if !remote.enabled {
                    Pill(label: String(localized: "Off"), tone: .neutral)
                } else if let failure = remote.failureText {
                    Pill(label: String(localized: "Couldn't start"), tone: .bad)
                    Text(failure).fixedSize(horizontal: false, vertical: true)
                } else if remote.origin == nil {
                    Pill(label: String(localized: "Waiting for tunnel"), tone: .neutral)
                } else {
                    switch remote.test {
                    case .notTested:
                        Pill(label: String(localized: "Not tested"), tone: .neutral)
                    case .testing:
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Testing…")).foregroundStyle(.secondary)
                    case .reachable(let rtt, let tunnel, let at):
                        Pill(label: String(localized: "Reachable"), tone: .good)
                        Text(([String(localized: "tested \(RelativeTime.short(at, now: model.now))"),
                               "\(Int((rtt * 1000).rounded())) ms"] + (tunnel.map { [$0.name] } ?? []))
                            .joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    case .notReachable(let reason, _):
                        Pill(label: String(localized: "Not reachable"), tone: .warning)
                        Text(remote.unreachableReason ?? reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } actions: {
            if remote.failureText != nil {
                Button(String(localized: "Choose Another Port…")) { portSheet = true }
            } else if remote.enabled {
                Button(String(localized: "Test")) { remote.runTest() }
                    .disabled(remote.origin == nil || remote.test == .testing)
                    .help(String(localized: "Fetch Funes Vault's health URL through the tunnel"))
            }
        }
    }

    @ViewBuilder private var tunnelRow: some View {
        let provider = remote.tunnelLabel
        let health = remote.enabled ? remote.currentTunnelHealth : nil
        ValueRow(label: String(localized: "Tunnel")) {
            HStack(spacing: 10) {
                Text(provider.name).fontWeight(.medium).fixedSize()
                if let health {
                    TunnelHealthLine(health: health, provider: provider, remotePort: remote.port, mcpPort: model.mcpPort)
                        .layoutPriority(1)
                }
            }
            .accessibilityElement(children: .combine)
        } actions: {
            Button(String(localized: "Switch Tunnel…")) { remote.beginSwitch() }
        }
        if let health {
            TunnelFix(health: health, provider: provider, remotePort: remote.port,
                      hostname: remote.origin.flatMap(URL.init(string:))?.host, names: remote.names,
                      funnelPort: remote.inUseFunnelPort, paths: remote.inUseFunnelPaths, inUse: true)
                .padding(.leading, 116)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
        }
        if let commands = remote.funnelResetCommands {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(localized: "The secret path changed. Move Tailscale Funnel to the new one in Terminal:"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(String(localized: "Done")) { remote.dismissFunnelResetCommands() }
                }
                CodeBox(text: commands.joined(separator: "\n"), copy: true)
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.bottom, 12)
        }
    }
}

/// "Running · on this Mac · forwards to 47627": the pill and its text.
struct TunnelHealthLine: View {
    let health: TunnelHealth
    let provider: TunnelProvider
    let remotePort: Int
    let mcpPort: Int
    var address: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Pill(label: health.label, tone: health.tone == .ok ? .good : health.tone == .warn ? .warning : .neutral)
            let detail = [health.detail(provider, remotePort: remotePort, mcpPort: mcpPort), address]
                .compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What to do about a tunnel that isn't running or is set up wrong: the command to run, or
/// where to get the tool. Funes Vault never runs it.
struct TunnelFix: View {
    let health: TunnelHealth
    let provider: TunnelProvider
    let remotePort: Int
    let hostname: String?
    let names: RemoteNames
    /// Funnel's public port for the command; nil when no port can take the paths (no command then).
    var funnelPort: Int? = 443
    /// Funnel's paths to add: all of them, or the missing ones when incomplete.
    var paths: [String] = []
    /// The Tunnel row: the port comes from the address in use.
    var inUse = false

    var body: some View {
        if let fix {
            VStack(alignment: .leading, spacing: 6) {
                Text(fix.intro).font(.callout).foregroundStyle(.secondary)
                CodeBox(text: fix.command, copy: true)
            }
        } else if inUse, provider == .tailscaleFunnel, funnelPort == nil, startsFunnel {
            Text(String(localized: "Funnel's port in your address now has a tailnet-only entry or a TCP forwarder from another app, which adding these paths would make public or replace. Use Switch Tunnel… to set it up again."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .notInstalled = health, let link = provider.installLink.flatMap(URL.init(string:)) {
            Link(String(localized: "Download \(provider == .ngrok ? "ngrok" : "Tailscale")…"), destination: link).font(.callout)
        }
    }

    /// The states whose fix is Funnel's start command.
    private var startsFunnel: Bool {
        switch health {
        case .notRunning: health.showsStartCommand
        case .wrongPort, .incomplete, .notPublic: true
        default: false
        }
    }

    private var fix: (intro: String, command: String)? {
        switch health {
        case .incomplete where provider == .tailscaleFunnel:
            return provider.runCommand(port: remotePort, hostname: hostname, names: names, publicPort: funnelPort, paths: paths)
                .map { (String(localized: "Add the missing paths in Terminal:"), $0) }
        case .notRunning where health.showsStartCommand:
            return provider.runCommand(port: remotePort, hostname: hostname, names: names, publicPort: funnelPort, paths: paths)
                .map { (String(localized: "Start it in Terminal:"), $0) }
        case .wrongPort:
            return provider.runCommand(port: remotePort, hostname: hostname, names: names, publicPort: funnelPort, paths: paths)
                .map { (String(localized: "Start it on port \(String(remotePort)) in Terminal:"), $0) }
        case .notPublic where provider == .tailscaleFunnel:
            return provider.runCommand(port: remotePort, hostname: hostname, names: names, publicPort: funnelPort, paths: paths)
                .map { (String(localized: "Turn on Funnel in Terminal:"), $0) }
        case .notInstalled where provider == .cloudflareTunnel || provider == .cloudflareQuick:
            return (String(localized: "Install it in Terminal:"), "brew install cloudflared")
        default:
            return nil
        }
    }
}

/// The Remote Access page ▸ Port ▸ Change….
struct RemotePortSheet: View {
    let remote: RemoteAccessController
    @Binding var shown: Bool
    @State private var text = ""
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Remote Access Port")).font(.headline)
            TextField(String(localized: "Port"), text: $text).textFieldStyle(.roundedBorder).frame(width: 120).onSubmit(save)
            if let issue { Text(issue).font(.callout).foregroundStyle(.red) }
            Text(String(localized: "Point your tunnel at the new port afterwards. It must differ from the MCP server's port."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { shown = false }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Use This Port"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { text = String(remote.port) }
    }

    private func save() {
        issue = remote.setPort(text)
        if issue == nil { shown = false }
    }
}
