import FunesPhone
import FunesProtocol
import SwiftUI

/// The banner at the top of a tab (UX: iPhone, States), as the list's first section. Not a
/// `safeAreaInset`: that hid the navigation bar's large title and search field on the device.
struct BannerSection: View {
    let model: PhoneModel
    /// Capture, where the app opens, offers the demo while there's no Mac (FR-iOS-10).
    var offersDemo = false

    var body: some View {
        Section {
            if model.isDemo {
                DemoBanner(model: model)
            } else {
                ReachabilityBanner(model: model)
                if offersDemo, case .notPaired = model.banner {
                    TryDemoRow(model: model)
                }
            }
        }
    }
}

/// "Demo vault: not your data" (UX: iPhone, States), with the way out.
struct DemoBanner: View {
    let model: PhoneModel

    var body: some View {
        HStack(spacing: 8) {
            Text("DEMO")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Text("Demo vault: not your data")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Leave Demo") { model.switchDemo(false) }
                .font(.footnote.bold())
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
    }
}

/// For someone without the Mac app yet, or App Review: every screen with sample data.
struct TryDemoRow: View {
    let model: PhoneModel

    var body: some View {
        HStack(spacing: 8) {
            Text("No Mac yet? See every screen with sample data. Nothing leaves this iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Demo") { model.switchDemo(true) }
                .font(.footnote.bold())
        }
        .buttonStyle(.borderless)
    }
}

/// "Connected to Maya's MacBook Pro · Wi-Fi", "Mac not reachable · 3 captures waiting" [Why?],
/// and the other states, from FunesPhone's `BannerState`.
struct ReachabilityBanner: View {
    let model: PhoneModel

    var body: some View {
        let state = model.banner
        HStack(spacing: 8) {
            icon(state)
            Text(Self.text(state))
                .font(.footnote)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state.offersWhy {
                Button("Why?") { model.presentingWhy = true }
                    .font(.footnote.bold())
            }
            if state.offersPairing {
                Button(Self.isRevoked(state) ? String(localized: "Pair Again") : String(localized: "Pair")) { model.presentingPairing = true }
                    .font(.footnote.bold())
            }
        }
        // Each button its own target in the list row.
        .buttonStyle(.borderless)
    }

    @ViewBuilder private func icon(_ state: BannerState) -> some View {
        switch state {
        case .connecting: ProgressView().controlSize(.small)
        case .connected: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .notPaired: Image(systemName: "iphone.slash").foregroundStyle(.secondary)
        case .unreachable: Image(systemName: "wifi.slash").foregroundStyle(.orange)
        case .localNetworkOff, .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .revoked: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private static func isRevoked(_ state: BannerState) -> Bool {
        if case .revoked = state { return true }
        return false
    }

    static func text(_ state: BannerState) -> String {
        switch state {
        case .notPaired(0): String(localized: "Pair with your Mac to start")
        case let .notPaired(waiting): String(localized: "Not paired · \(waiting) captures waiting")
        case let .connecting(name, _) where name.isEmpty: String(localized: "Connecting to your Mac…")
        case let .connecting(name, _): String(localized: "Connecting to \(name)…")
        case let .connected(name, route, 0): String(localized: "Connected to \(name) · \(route.title)")
        case let .connected(name, route, waiting): String(localized: "Connected to \(name) · \(route.title) · \(waiting) captures waiting")
        case .unreachable(0): String(localized: "Mac not reachable")
        case let .unreachable(waiting): String(localized: "Mac not reachable · \(waiting) captures waiting")
        case .localNetworkOff(0): String(localized: "Local Network access is off for Funes")
        case let .localNetworkOff(waiting): String(localized: "Local Network access is off for Funes · \(waiting) captures waiting")
        case .revoked: String(localized: "This iPhone was removed from Funes on your Mac")
        case .failed(_, 0): String(localized: "Can't connect to your Mac")
        case let .failed(_, waiting): String(localized: "Can't connect to your Mac · \(waiting) captures waiting")
        }
    }
}

/// The "Why?" sheet (UX: iPhone, States): why the Mac can't be reached, and what to try.
struct WhySheet: View {
    let model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your vault lives on your Mac. Search and review need the Mac to be awake and reachable on the same Wi-Fi, or through Tailscale. Captures are safe on this iPhone and will be sent automatically.")
                }
                Section("What to Try") {
                    ForEach(Array(model.diagnosis.hints.enumerated()), id: \.offset) { _, hint in
                        Label(Self.text(hint), systemImage: Self.symbol(hint))
                    }
                }
                if !model.probes.isEmpty {
                    Section {
                        ForEach(model.probes) { probe in
                            LabeledContent(Self.name(probe.address.kind), value: probe.outcome == "ok" ? String(localized: "Answered") : probe.outcome)
                        }
                    } header: {
                        Text("Last Check")
                    } footer: {
                        if let checked = model.lastChecked {
                            Text("Checked \(checked.formatted(.relative(presentation: .named))).")
                        }
                    }
                }
                Section {
                    Button {
                        Task {
                            checking = true
                            await model.refresh(fresh: true)
                            checking = false
                            if model.reachability.isConnected { dismiss() }
                        }
                    } label: {
                        HStack {
                            Text("Try Again")
                            if checking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(checking)
                }
            }
            .navigationTitle("Mac Not Reachable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    static func text(_ hint: UnreachableDiagnosis.Hint) -> String {
        switch hint {
        case .offline:
            String(localized: "This iPhone is offline. Captures wait here and go to your Mac once it's back online.")
        case .localNetworkOff:
            String(localized: "Funes isn't allowed on your local network. Turn it on in Settings ▸ Privacy & Security ▸ Local Network.")
        case .funesNotListening:
            String(localized: "Your Mac answered, but Funes Vault didn't. Open Funes Vault on the Mac, and check that iPhone access is on in its Settings ▸ iPhone.")
        case .sameWiFi:
            String(localized: "Make sure this iPhone is on the same Wi-Fi as your Mac.")
        case .checkTailscale:
            String(localized: "This iPhone isn't on Wi-Fi. Make sure Tailscale is connected on this iPhone and on your Mac.")
        case .awayWithoutTailscale:
            String(localized: "This iPhone isn't on Wi-Fi, and your Mac had no Tailscale address when you paired. Join your Mac's Wi-Fi, or set up Tailscale on both and pair again.")
        case .somethingElseAnswered:
            String(localized: "Something other than Funes Vault answered at your Mac's address. Pair again so this iPhone learns the Mac's current address.")
        case .macAsleep:
            String(localized: "Your Mac may be asleep, or Funes Vault may be closed. Wake the Mac and open Funes Vault.")
        }
    }

    static func symbol(_ hint: UnreachableDiagnosis.Hint) -> String {
        switch hint {
        case .offline: "airplane"
        case .localNetworkOff: "lock.shield"
        case .funesNotListening: "app.badge"
        case .sameWiFi: "wifi"
        case .checkTailscale, .awayWithoutTailscale: "network"
        case .somethingElseAnswered: "questionmark.circle"
        case .macAsleep: "moon.zzz"
        }
    }

    static func name(_ kind: MacAddress.Kind) -> String {
        switch kind {
        case .bonjour: String(localized: "Found on this Wi-Fi")
        case .lan: String(localized: "Wi-Fi address")
        case .tailscale: String(localized: "Tailscale")
        case .tunnel: String(localized: "Tunnel")
        }
    }
}

/// What Search and the Inbox show instead of the vault while the Mac can't be asked
/// (FR-iOS-06: disabled, with a plain explanation).
struct VaultUnavailableView: View {
    let model: PhoneModel
    /// "Search" or "The Inbox", for the explanation.
    let feature: Feature

    enum Feature { case search, inbox }

    var body: some View {
        switch model.banner {
        case .notPaired:
            ContentUnavailableView {
                Label("Pair with your Mac to start", systemImage: "iphone.slash")
            } description: {
                Text(feature == .search
                     ? String(localized: "Search reads your vault on your Mac. Pair this iPhone with it first.")
                     : String(localized: "The Inbox lives on your Mac. Pair this iPhone with it first."))
            } actions: {
                Button("Pair with Mac") { model.presentingPairing = true }
                    .buttonStyle(.borderedProminent)
                Button("Try Demo") { model.switchDemo(true) }
            }
        case let .connecting(name, _):
            ContentUnavailableView {
                Label { Text(name.isEmpty ? String(localized: "Connecting to your Mac…") : String(localized: "Connecting to \(name)…")) } icon: { ProgressView() }
            }
        case .revoked:
            ContentUnavailableView {
                Label("This iPhone was removed from Funes on your Mac", systemImage: "xmark.octagon")
            } description: {
                Text("Pair again to search and review your vault from this iPhone.")
            } actions: {
                Button("Pair Again") { model.presentingPairing = true }
                    .buttonStyle(.borderedProminent)
            }
        case .connected:
            EmptyView()
        case .unreachable, .localNetworkOff, .failed:
            ContentUnavailableView {
                Label("Mac not reachable", systemImage: "wifi.slash")
            } description: {
                Text(feature == .search
                     ? String(localized: "Search needs your Mac to be awake and reachable. Captures still work, and go to the Mac later.")
                     : String(localized: "Review needs your Mac to be awake and reachable. Captures still work, and go to the Mac later."))
            } actions: {
                Button("Try Again") { Task { await model.refresh(fresh: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Why?") { model.presentingWhy = true }
            }
        }
    }
}
