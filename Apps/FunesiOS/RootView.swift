import FunesPhone
import FunesProtocol
import SwiftUI

/// The foundation's one screen: pair, then the Mac's connection and status. The tabs (Capture,
/// Search, Inbox, Settings) come in tasks 5.4 and 5.5.
struct RootView: View {
    let model: PhoneModel
    @State private var pairing = false
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                if let record = model.record {
                    macSection(record)
                    deviceSection(record)
                    #if DEBUG
                    SpikeSection(model: model)
                    #endif
                    Section {
                        Button("Unpair This iPhone…", role: .destructive) { confirmingUnpair = true }
                    }
                } else {
                    notPairedSection
                }
            }
            .navigationTitle("Funes Vault")
            .refreshable { await model.refresh(fresh: true) }
            .sheet(isPresented: $pairing) { PairingSheet(model: model) }
            .confirmationDialog("Unpair this iPhone?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { Task { await model.unpair() } }
            } message: {
                Text("Your Mac forgets this iPhone, and this iPhone forgets its keys. You can pair again with a new code.")
            }
        }
    }

    private var notPairedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pair with your Mac to start")
                    .font(.headline)
                Text("Your vault lives on your Mac. On the Mac, open Funes Settings ▸ iPhone ▸ Pair iPhone…, then scan the code it shows.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button("Pair with Mac") { pairing = true }
                .bold()
        }
    }

    private func macSection(_ record: PairingRecord) -> some View {
        Section {
            LabeledContent("Mac", value: record.macName)
            ReachabilityRow(reachability: model.reachability, path: model.path)
            if case let .connected(connection) = model.reachability {
                LabeledContent("Funes", value: connection.status.appVersion)
                LabeledContent("Waiting in Inbox", value: connection.status.inboxPending.formatted())
                LabeledContent("Round trip", value: "\(connection.roundTrip.milliseconds) ms")
            }
            if let checked = model.lastChecked {
                LabeledContent("Last check") { Text(checked, style: .time) }
            }
            Button("Check Connection") { Task { await model.refresh(fresh: true) } }
        } header: {
            Text("Mac")
        } footer: {
            if case .unreachable = model.reachability {
                Text("Your vault lives on your Mac. Search and review need the Mac to be awake and reachable on the same Wi-Fi, or through Tailscale.")
            }
        }
    }

    private func deviceSection(_ record: PairingRecord) -> some View {
        Section("This iPhone") {
            LabeledContent("Name", value: record.deviceName)
            LabeledContent("Paired") { Text(record.pairedAt, format: .dateTime.day().month().year().hour().minute()) }
            if let secureEnclave = model.usesSecureEnclave {
                LabeledContent("Signing key", value: secureEnclave ? String(localized: "Secure Enclave") : String(localized: "Keychain"))
            }
        }
    }
}

/// "Connected to Maya's MacBook Pro · Wi-Fi" and the other states (UX: iPhone, States).
struct ReachabilityRow: View {
    let reachability: PhoneModel.Reachability
    let path: NetworkPath?

    var body: some View {
        switch reachability {
        case .notPaired:
            Label("Not paired", systemImage: "iphone.slash")
        case .checking:
            Label { Text("Checking…") } icon: { ProgressView() }
        case let .connected(connection):
            Label(Self.connected(connection.address.connectionKind, path: path), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unreachable(localNetworkDenied: true):
            Label("Local Network access is off for Funes", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unreachable:
            Label("Mac not reachable", systemImage: "wifi.slash")
                .foregroundStyle(.orange)
        case .revoked:
            Label("This iPhone was removed from Funes on your Mac", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    static func connected(_ kind: ConnectionKind, path: NetworkPath?) -> String {
        switch kind {
        // A LAN address reached off Wi-Fi, such as through a Tailscale subnet router (Spike 1e).
        case .wifi where path.map({ !$0.isLocal }) ?? false: String(localized: "Connected · VPN")
        case .wifi: String(localized: "Connected · Wi-Fi")
        case .tailscale: String(localized: "Connected · Tailscale")
        case .tunnel: String(localized: "Connected · Tunnel")
        }
    }
}

#if DEBUG
/// Spike 1's on-device rows: send a capture and resend it (1b, 1c), and the protocol refusals (1f).
struct SpikeSection: View {
    let model: PhoneModel

    var body: some View {
        Section("Spike 1") {
            Button("Send a Test Capture") { Task { await model.sendTestCapture(again: false) } }
            Button("Send It Again") { Task { await model.sendTestCapture(again: true) } }
            Button("Run Protocol Checks") { Task { await model.runProtocolChecks() } }
            if let message = model.spikeMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.protocolChecks) { check in
                HStack {
                    Text(check.name)
                    Spacer()
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.passed ? .green : .red)
                    Text(check.got).foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
    }
}
#endif
