import FunesPhone
import FunesProtocol
import SwiftUI
import UIKit

extension View {
    /// The status bar above the tab bar (UX: iPhone, Status bar), on the tab view: iOS 26.1's
    /// bottom accessory, which can be turned off while there's nothing to say. iOS 26.0's can't
    /// (it has no `isEnabled`), so there and on iOS 18–25 each tab draws its own (`ownStatusBar`).
    @ViewBuilder func statusBarAccessory(_ model: PhoneModel) -> some View {
        if #available(iOS 26.1, *), !StatusBarPlacement.ownBar {
            tabViewBottomAccessory(isEnabled: model.statusBar.item != nil) {
                // Its own view, which reads the item itself: the accessory's content is kept apart
                // from the tab view's body.
                StatusBarSlot(model: model)
            }
        } else {
            self
        }
    }

    /// The bar of our own, just above the tab bar, where the accessory can't be hidden. A
    /// bottom inset rather than a top one, which hid the large title and the search field.
    func ownStatusBar(_ model: PhoneModel) -> some View {
        modifier(OwnStatusBar(model: model))
    }
}

enum StatusBarPlacement {
    /// The accessory, unless it can't be hidden. Debug builds take `-FunesOwnStatusBar YES` to
    /// try the bar of our own on a newer iOS.
    static var ownBar: Bool {
        guard #available(iOS 26.1, *) else { return true }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "FunesOwnStatusBar")
        #else
        return false
        #endif
    }
}

private struct OwnStatusBar: ViewModifier {
    let model: PhoneModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if StatusBarPlacement.ownBar {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack {
                    if let item = model.statusBar.item {
                        StatusBarContent(model: model, item: item, inAccessory: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                            // It slides in and out; it fades with Reduce Motion.
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy, value: model.statusBar.item)
            }
        } else {
            content
        }
    }
}

/// The accessory's content: whatever the bar shows now.
private struct StatusBarSlot: View {
    let model: PhoneModel

    var body: some View {
        if let item = model.statusBar.item {
            StatusBarContent(model: model, item: item, inAccessory: true)
        }
    }
}

/// The bar's icon, words and button. Tapping the bar opens the status sheet (or pairing); the
/// button acts directly. VoiceOver reads it as one element, the button as a custom action.
struct StatusBarContent: View {
    let model: PhoneModel
    let item: StatusBarTimeline.Item
    /// The accessory is one line high; the bar of our own grows with the text.
    let inAccessory: Bool

    var body: some View {
        let action = Self.action(item)
        let tap = Self.tap(item)
        HStack(spacing: 10) {
            // Tapping the icon and words is a button of its own, beside the action's.
            if let tap {
                Button { perform(tap) } label: { label }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
            } else {
                label
            }
            if let action {
                Button(action.title) { perform(action) }
                    .font(.subheadline.bold())
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, inAccessory ? 16 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.text(item))
        .accessibilityAddTraits(tap == nil ? [] : .isButton)
        .modifier(StatusBarActions(action: action, tap: tap, perform: perform))
    }

    /// The icon and the words.
    private var label: some View {
        HStack(spacing: 10) {
            icon
            Text(Self.text(item))
                .font(.subheadline)
                .lineLimit(inAccessory ? 1 : 3)
                // "Demo vault: not your data" next to Leave Demo fits the accessory's one line.
                .minimumScaleFactor(inAccessory ? 0.8 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The shape below takes the tap: in the iOS 27 simulator the words didn't pass it on.
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .demo:
            Text("DEMO")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())
                .foregroundStyle(.white)
        case .backOnline:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case let .state(state):
            switch state {
            case .connecting: ProgressView().controlSize(.small)
            case .connected: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .notPaired: Image(systemName: "iphone.slash").foregroundStyle(.orange)
            case .unreachable: Image(systemName: "wifi.slash").foregroundStyle(.orange)
            case .localNetworkOff, .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .revoked: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    enum Action {
        case why, fix, pair, pairAgain, leaveDemo

        var title: String {
            switch self {
            case .why: String(localized: "Why?")
            case .fix: String(localized: "Fix")
            case .pair: String(localized: "Pair")
            case .pairAgain: String(localized: "Pair Again")
            case .leaveDemo: String(localized: "Leave Demo")
            }
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .why: model.presentingStatus = true
        case .fix:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .pair, .pairAgain: model.presentingPairing = true
        case .leaveDemo: model.switchDemo(false)
        }
    }

    /// The bar's button.
    static func action(_ item: StatusBarTimeline.Item) -> Action? {
        switch item {
        case .demo: .leaveDemo
        case .backOnline: nil
        case let .state(state):
            switch state {
            case .unreachable, .failed: .why
            case .localNetworkOff: .fix
            case .notPaired: .pair
            case .revoked: .pairAgain
            case .connecting, .connected: nil
            }
        }
    }

    /// What tapping the bar does: the status sheet (as Why? does) or pairing.
    static func tap(_ item: StatusBarTimeline.Item) -> Action? {
        switch item {
        case .demo, .backOnline: nil
        case let .state(state):
            switch state {
            case .unreachable, .failed, .localNetworkOff, .revoked: .why
            case .notPaired: .pair
            case .connecting, .connected: nil
            }
        }
    }

    static func text(_ item: StatusBarTimeline.Item) -> String {
        switch item {
        case .demo: String(localized: "Demo vault: not your data")
        case .backOnline(0): String(localized: "Back online")
        case let .backOnline(sent): String(localized: "Back online · \(sent) captures sent")
        case let .state(state):
            switch state {
            case .notPaired: String(localized: "Pair with your Mac to start")
            case let .connecting(name, _) where name.isEmpty: String(localized: "Connecting to your Mac…")
            case let .connecting(name, _): String(localized: "Connecting to \(name)…")
            case let .connected(_, route, _): ReachabilityRow.connected(route)
            case .unreachable(0): String(localized: "Mac not reachable")
            case let .unreachable(waiting): String(localized: "Mac not reachable · \(waiting) waiting")
            case .localNetworkOff: String(localized: "Local Network access is off")
            case .failed: String(localized: "Can't connect to your Mac")
            case .revoked: String(localized: "Removed from Funes on your Mac")
            }
        }
    }
}

/// The bar's VoiceOver actions: activating it does what a tap does, and the button is a named
/// custom action (so a double tap on the demo's bar doesn't leave the demo).
private struct StatusBarActions: ViewModifier {
    let action: StatusBarContent.Action?
    let tap: StatusBarContent.Action?
    let perform: (StatusBarContent.Action) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAction { if let tap { perform(tap) } }
            .accessibilityActions {
                if let action {
                    Button(action.title) { perform(action) }
                }
            }
    }
}

/// For someone without the Mac app yet, or App Review: pairing, or every screen with sample data.
/// Capture's first card while the iPhone isn't paired (later Home's).
struct PairingCard: View {
    let model: PhoneModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pair with your Mac to start")
                    .font(.headline)
                Text("Your vault lives on your Mac. On the Mac, open Funes Settings ▸ iPhone ▸ Pair iPhone…, then scan the code it shows. Captures wait here until then.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button("Pair with Mac") { model.presentingPairing = true }
                .bold()
            VStack(alignment: .leading, spacing: 4) {
                Button("Try Demo") { model.switchDemo(true) }
                Text("No Mac yet? See every screen with sample data. Nothing leaves this iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The status sheet (UX: iPhone, Status bar; from the Why sheet): which Mac, when and how it was
/// last reached, the queue, why it can't be reached and what to try, and Try Again.
struct StatusSheet: View {
    let model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        let state = model.banner
        NavigationStack {
            List {
                Section {
                    if let record = model.record {
                        LabeledContent("Mac", value: record.macName)
                    }
                    ReachabilityRow(reachability: model.reachability, path: model.path)
                    if let reached = model.lastReached {
                        LabeledContent("Last reached") {
                            Text("\(reached.at.formatted(.relative(presentation: .named))) · \(reached.route.title)")
                        }
                    } else if model.record != nil {
                        LabeledContent("Last reached", value: String(localized: "Not since Funes opened"))
                    }
                }
                switch state {
                case .unreachable, .localNetworkOff, .failed:
                    Section {
                        Text("Your vault lives on your Mac. Search and review need the Mac to be awake and reachable on the same Wi-Fi, or through Tailscale. Captures are safe on this iPhone and will be sent automatically.")
                    }
                    Section("What to Try") {
                        ForEach(Array(model.diagnosis.hints.enumerated()), id: \.offset) { _, hint in
                            Label(Self.text(hint), systemImage: Self.symbol(hint))
                        }
                        if case .localNetworkOff = state {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    }
                case .revoked:
                    Section {
                        Text("Your Mac no longer knows this iPhone. Captures waiting here are kept: pair again to send them, or delete them in Settings.")
                        Button("Pair Again") {
                            dismiss()
                            model.presentingPairing = true
                        }
                    }
                case .notPaired, .connecting, .connected:
                    EmptyView()
                }
                queueSection
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
                if model.record != nil {
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
            }
            .navigationTitle(Self.title(state))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// "3 captures waiting · Send Now".
    private var queueSection: some View {
        Section("Queue") {
            let waiting = model.capture.queuedCount
            HStack {
                Text(waiting == 0 ? String(localized: "No captures waiting") : String(localized: "\(waiting) captures waiting"))
                Spacer()
                Button("Send Now") { Task { await model.capture.deliver(.manual) } }
                    .buttonStyle(.borderless)
                    .disabled(model.record == nil || waiting == 0 || model.capture.delivering)
            }
        }
    }

    static func title(_ state: BannerState) -> String {
        switch state {
        case .unreachable, .localNetworkOff, .failed: String(localized: "Mac Not Reachable")
        case .revoked: String(localized: "Removed from Funes")
        case .notPaired, .connecting, .connected: String(localized: "Connection")
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
                Button("Why?") { model.presentingStatus = true }
            }
        }
    }
}
