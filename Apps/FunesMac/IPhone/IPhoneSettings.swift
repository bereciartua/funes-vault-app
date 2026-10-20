import CoreImage
import CoreImage.CIFilterBuiltins
import FunesCompanion
import FunesCore
import FunesProtocol
import SwiftUI

/// Settings ▸ iPhone (05-ux-iphone.md, pairing flow; companion protocol §5).
struct IPhoneSettings: View {
    let model: AppModel
    @State private var pairing = false
    @State private var removing: Device?
    @State private var host = ""

    private var companion: CompanionController { model.companion }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Allow iPhone access"), isOn: Binding(get: { companion.enabled },
                                                                               set: { companion.setEnabled($0) }))
                Text(String(localized: "A paired iPhone can capture, search, edit and review the Inbox while it can reach this Mac. What it sends is end-to-end encrypted, and your vault stays on this Mac."))
                    .font(.callout).foregroundStyle(.secondary)
                if companion.enabled { statusLine }
            }
            if companion.enabled {
                Section(String(localized: "Reach this Mac over")) {
                    modeToggle(String(localized: "Same Wi-Fi"), .sameWiFi)
                    modeToggle(String(localized: "Tailscale"), .tailscale)
                    if companion.modes.contains(.tailscale) {
                        if let address = NetworkAddresses.tailscale() {
                            Text(String(localized: "Tailscale detected · \(address)")).font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "Tailscale isn't running on this Mac. Install it on this Mac and your iPhone, signed in to the same account."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    modeToggle(String(localized: "Public tunnel"), .tunnel)
                    if companion.modes.contains(.tunnel) { tunnel }
                }
            }
            Section(String(localized: "Paired iPhones")) {
                if companion.activeDevices.isEmpty {
                    Text(String(localized: "No iPhone paired yet.")).foregroundStyle(.secondary)
                }
                ForEach(companion.activeDevices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(Self.detail(device)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "Remove…")) { removing = device }
                    }
                }
                Button(String(localized: "Pair iPhone…")) { pairing = true }
                    .disabled(!companion.canPair)
                if companion.enabled, companion.activeDevices.count >= CompanionProtocol.maxPairedDevices {
                    Text(String(localized: "Five iPhones are paired, the most Funes Vault allows. Remove one to pair another."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            host = companion.tunnelHost
            Task { await companion.reloadDevices() }
        }
        .sheet(isPresented: $pairing) { PairingSheet(companion: companion) }
        .confirmationDialog(String(localized: "Remove “\(removing?.name ?? "")”?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(String(localized: "Remove"), role: .destructive) {
                if let device = removing { Task { await companion.remove(device) } }
                removing = nil
            }
        } message: {
            Text(String(localized: "It can't reach your vault any more. Captures waiting on it stay there until it pairs again."))
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch companion.status {
        case let .listening(port):
            Label(String(localized: "Listening on port \(String(port))"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .starting, .off:
            if companion.keysUnavailable {
                WarningLabel(text: String(localized: "The Keychain didn't give Funes Vault its iPhone keys. Turn this off and on again."))
            } else if companion.modes.isEmpty {
                Text(String(localized: "Choose at least one way to reach this Mac.")).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(String(localized: "Starting…")).font(.callout).foregroundStyle(.secondary)
            }
        case let .failed(failure):
            switch failure {
            case .portInUse:
                WarningLabel(text: String(localized: "Another app is using port \(String(companion.port)). Quit it, then turn this off and on again."))
            case .other:
                WarningLabel(text: String(localized: "iPhone access couldn't start. Turn it off and on again."))
            }
        }
    }

    private func modeToggle(_ title: String, _ mode: CompanionModes) -> some View {
        Toggle(title, isOn: Binding(get: { companion.modes.contains(mode) }, set: { companion.setMode(mode, $0) }))
    }

    @ViewBuilder private var tunnel: some View {
        TextField(String(localized: "Public host"), text: $host, prompt: Text(verbatim: "maya-mbp.tailnet.ts.net"))
            .onSubmit { companion.setTunnelHost(host) }
        if let url = companion.tunnelURL {
            Text(String(localized: "Forward this URL to http://127.0.0.1:\(String(companion.port)):")).font(.callout)
            Text(verbatim: url).font(.callout.monospaced()).textSelection(.enabled)
            Button(String(localized: "Reset Path")) { companion.resetTunnelPath() }
            Text(String(localized: "A new path stops the old URL. Paired iPhones learn the new one when they pair again."))
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text(String(localized: "Type your tunnel's public host, then press Return."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// "iPhone17,1 · Paired 3 Nov · Last seen 2 min. ago over Wi-Fi"
    static func detail(_ device: Device) -> String {
        var parts = [device.model, String(localized: "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")]
        if let seen = device.lastSeenAt {
            let when = seen.formatted(.relative(presentation: .named))
            switch device.lastTransport {
            case .lan: parts.append(String(localized: "Last seen \(when) over Wi-Fi"))
            case .tailscale: parts.append(String(localized: "Last seen \(when) over Tailscale"))
            case .tunnel: parts.append(String(localized: "Last seen \(when) through the tunnel"))
            case nil: parts.append(String(localized: "Last seen \(when)"))
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Pair iPhone…: the QR code for 5 minutes, then "<name> wants to pair" with Allow and Deny.
struct PairingSheet: View {
    let companion: CompanionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(String(localized: "Pair iPhone")).font(.title2.bold())
            content
        }
        .padding(24)
        .frame(width: 420)
        .task { await companion.startPairing() }
        .onDisappear { companion.endPairing() }
    }

    @ViewBuilder private var content: some View {
        switch companion.pairingState {
        case .idle, .waiting:
            if let qr = companion.qr, let image = Self.qrImage(qr.qrString) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 240, height: 240)
                    .accessibilityLabel(String(localized: "Pairing code"))
                Text(String(localized: "On your iPhone, open Funes Vault, tap Pair with Mac and scan this code."))
                    .multilineTextAlignment(.center)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(TimeInterval(qr.expiresAt) - context.date.timeIntervalSince1970))
                    Text(left > 0 ? String(localized: "Valid for \(left / 60):\(String(format: "%02d", left % 60))")
                                  : String(localized: "This code expired."))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(String(localized: "Both need the same Wi-Fi, or Tailscale on both."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        case let .asking(name, deviceModel):
            Image(systemName: "iphone").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(String(localized: "“\(name)” wants to pair")).font(.headline)
            Text(deviceModel).font(.callout).foregroundStyle(.secondary)
            Text(String(localized: "Allow only if it's your iPhone and you just scanned the code. It will act as you: capture, search, edit and review."))
                .font(.callout).multilineTextAlignment(.center)
            HStack {
                Button(String(localized: "Deny")) { companion.answerPairing(allow: false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Allow")) { companion.answerPairing(allow: true) }.keyboardShortcut(.defaultAction)
            }
        case let .paired(name):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
            Text(String(localized: "Paired with “\(name)”.")).font(.headline)
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        case let .ended(error):
            Image(systemName: "xmark.circle").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(Self.message(error)).multilineTextAlignment(.center)
            HStack {
                Button(String(localized: "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Show a New Code")) { Task { await companion.startPairing() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func message(_ error: PairingError) -> String {
        switch error {
        case .denied: String(localized: "Pairing was denied. The code can't be used again.")
        case .tooManyAttempts: String(localized: "Too many tries with this code.")
        case .tooManyDevices: String(localized: "Five iPhones are already paired. Remove one first.")
        case .expired: String(localized: "This code expired.")
        case .invalidProof, .invalidRequest, .invalidConfirmation: String(localized: "Pairing didn't work. Try again with a new code.")
        }
    }

    /// The QR code, at medium error correction.
    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width / 2, height: output.extent.height / 2))
    }
}
