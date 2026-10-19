import BridgeKitRemote
import BridgeUI
import SwiftUI

// Adapted from EK Bridge's TunnelSwitchView (BridgeUI/Upstream/TunnelSwitchView.swift, e753b22):
// Switch Tunnel… and Address ▸ Edit…: Choose · Start it · Paste and test · Switch, with the
// address in use working until Switch.

struct TunnelSwitchView: View {
    let model: AppModel
    let change: TunnelSwitch
    var remote: RemoteAccessController { model.remoteAccess }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            keepUsingBanner
            GuideStepsHeader(titles: change.steps.map(change.title), current: change.steps.firstIndex(of: change.step) ?? 0)
            switch change.step {
            case .choose: choose
            case .start: start
            case .test, .confirm: test
            }
        }
    }

    private var keepUsingBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Color.accentColor).font(.body.weight(.semibold))
            Text(change.kind == .editAddress ? String(localized: "Cloud agents keep using \(change.fromOrigin) until you save.")
                                             : String(localized: "Cloud agents keep using \(change.fromOrigin) until you switch."))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(String(localized: "Cancel")) { remote.cancelSwitch() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var choose: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(TunnelProvider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { RowDivider() }
                    let inUse = !change.canChoose(provider)
                    let remembered = inUse ? nil : remote.rememberedAddresses[provider]
                    Button {
                        remote.switchChoose(provider)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "circle").foregroundStyle(Color.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                Text(provider.summary).font(.callout).foregroundStyle(.secondary)
                                if let remembered {
                                    Text(String(localized: "Last used: \(remembered)")).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if inUse {
                                Pill(label: String(localized: "In use"), tone: .neutral)
                            } else {
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                        }
                        .opacity(inUse ? 0.55 : 1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .disabled(inUse)
                }
            }
        }
    }

    private var start: some View {
        let provider = change.picked ?? .other
        let state = remote.tunnelStartState
        return VStack(alignment: .leading, spacing: 12) {
            TunnelStartCard(model: model, provider: provider, note: String(localized: "Both tunnels can run at the same time."))
            HStack {
                Spacer()
                Button(String(localized: "Back")) { remote.switchBack() }
                if state.offersContinue {
                    Button(String(localized: "Continue")) { remote.switchContinue() }.buttonStyle(.borderedProminent)
                } else if state.offersStarted {
                    Button(String(localized: "I've Started It")) { remote.switchContinue() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var test: some View {
        let provider = change.picked ?? change.fromTunnel
        let normalized = remote.switchNormalizedAddress
        let result = change.result(for: normalized)
        return VStack(alignment: .leading, spacing: 12) {
            Card {
                Text(caption(provider)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField(String(localized: "Address"), text: Binding(
                    get: { remote.tunnelSwitch?.address ?? "" }, set: { remote.setSwitchAddress($0) }),
                          prompt: Text(verbatim: remote.funnelExampleAddress))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { remote.switchTest() }
                    .accessibilityLabel(String(localized: "New address for \(provider.name)"))
                if let issue = remote.switchAddressIssue { Text(issue).font(.callout).foregroundStyle(.red) }
                if result != .notTested {
                    Divider()
                    testResult(result, provider: provider)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Back")) { remote.switchBack() }
                Button(result == .notTested ? String(localized: "Test") : String(localized: "Test Again")) { remote.switchTest() }
                    .disabled(normalized == nil || !remote.enabled || isTesting(result))
                    .modifier(Prominent(on: !change.canConfirm(normalized: normalized)))
                Button(change.kind == .editAddress ? String(localized: "Save…") : String(localized: "Switch…")) {
                    remote.switchConfirm()
                }
                .disabled(!change.canConfirm(normalized: normalized))
                .modifier(Prominent(on: change.canConfirm(normalized: normalized)))
            }
            if !remote.enabled {
                Text(String(localized: "Turn on Remote Access to test the address.")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func caption(_ provider: TunnelProvider) -> String {
        switch change.addressSource {
        case .runningTunnel: String(localized: "Filled in from the running tunnel. Check it, then test.")
        case .remembered: String(localized: "The address \(provider.name) had last time. Check it, then test.")
        case .inUse: String(localized: "The new address for \(provider.name), without a path. Test it, then save.")
        case .none: String(localized: "The tunnel's public https address, without a path. Test it before you switch.")
        }
    }

    private func isTesting(_ result: TunnelSwitch.Test) -> Bool {
        if case .testing = result { return true }
        return false
    }

    @ViewBuilder
    private func testResult(_ result: TunnelSwitch.Test, provider: TunnelProvider) -> some View {
        switch result {
        case .notTested:
            EmptyView()
        case .testing(let address):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Testing \(address)…")).foregroundStyle(.secondary)
            }
        case .reachable(_, let ms, let tunnel):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Pill(label: String(localized: "Reachable"), tone: .good)
                    Text(([tunnel.map { String(localized: "through \($0.name)") }, "\(ms) ms"].compactMap { $0 }).joined(separator: " · "))
                    Spacer(minLength: 8)
                    Text(String(localized: "Nothing is saved yet")).font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                if let other = change.otherTunnel {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label(String(localized: "This address goes through \(other.name), not \(provider.name)."),
                              systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if change.kind == .switchTunnel && other != change.fromTunnel {
                            Button(String(localized: "Continue as \(other.name)")) { remote.switchContinueAs(other) }
                        }
                    }
                    .font(.callout)
                }
            }
        case .notReachable(_, let reason):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Pill(label: String(localized: "Not reachable"), tone: .warning)
                Text(remote.currentTunnelHealth?.unreachableReason(provider, remotePort: remote.port) ?? reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(String(localized: "The tunnel in use keeps working")).font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Step 4: what switching changes, by name, before anything is saved.
struct TunnelSwitchSheet: View {
    let remote: RemoteAccessController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let change = remote.tunnelSwitch, let summary = remote.switchSummary {
                Text(change.kind == .editAddress ? String(localized: "Save the new address?")
                                                 : String(localized: "Switch to \(summary.tunnel.inSentence)?"))
                    .font(.headline)
                Text(String(localized: "The MCP URL becomes \(summary.mcpURL)."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Card {
                    if summary.noCloudAgents {
                        section(String(localized: "No cloud agents use the current URL yet."), detail: nil)
                    }
                    if !summary.updateURLIn.isEmpty {
                        section(String(localized: "Update the URL in"),
                                detail: summary.updateURLIn.map { String(localized: "\($0) (remote token)") }.joined(separator: ", "))
                    }
                    if !summary.disconnected.isEmpty {
                        section(String(localized: "Disconnected; connect again"),
                                detail: summary.disconnected.map { String(localized: "\($0) (connected cloud app)") }.joined(separator: ", "))
                    }
                    if let old = summary.stopTunnel {
                        Text(String(localized: "Then you can stop \(old.name)"))
                        CodeBox(text: summary.stopCommands.joined(separator: "\n"), copy: true)
                    }
                }
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) { remote.switchBack() }.keyboardShortcut(.cancelAction)
                    Button(change.kind == .editAddress ? String(localized: "Save") : String(localized: "Switch")) {
                        remote.switchCommit()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(String(localized: "This switch is no longer open.")).font(.headline)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func section(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if let detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
