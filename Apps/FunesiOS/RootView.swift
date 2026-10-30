import FunesPhone
import FunesProtocol
import SwiftUI

/// The tabs (UX: iPhone): Home, where the app opens, Search, Inbox and Settings, and the status
/// bar above them, only when something needs you.
struct RootView: View {
    enum Tab: Hashable {
        case home, search, inbox, settings
    }

    let model: PhoneModel

    var body: some View {
        TabView(selection: Bindable(model).tab) {
            HomeView(model: model)
                .ownStatusBar(model)
                .tabItem { Label("Home", systemImage: "house") }
                // Requests waiting for an answer are listed near the top of Home.
                .badge(model.approvals.waiting.count)
                .tag(Tab.home)
            SearchView(model: model)
                .ownStatusBar(model)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            InboxView(model: model)
                .ownStatusBar(model)
                .tabItem { Label("Inbox", systemImage: "tray") }
                .badge(model.inboxBadge)
                .tag(Tab.inbox)
            SettingsView(model: model)
                .ownStatusBar(model)
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(Tab.settings)
        }
        .statusBarAccessory(model)
        .onChange(of: model.banner, initial: true) { _, banner in model.statusBar.update(banner, isDemo: model.isDemo) }
        // VoiceOver hears each new state once, not every new count.
        .onChange(of: model.statusBar.item) { old, new in
            guard let new, !new.isSameState(as: old) else { return }
            AccessibilityNotification.Announcement(StatusBarContent.text(new)).post()
        }
        // The Control opens Home's composer.
        .onChange(of: model.captureRequests) { model.tab = .home }
        .sheet(isPresented: Bindable(model).presentingPairing) { PairingSheet(model: model) }
        .sheet(isPresented: Bindable(model).presentingStatus) { StatusSheet(model: model) }
        // A tapped approval notification, or a row of the list.
        .sheet(item: Bindable(model).openApproval) { open in ApprovalPanelView(model: model, panel: open.panel) }
    }
}

/// Settings: pair, the Mac's connection and status, this iPhone, the queue, and this app's version.
struct SettingsView: View {
    let model: PhoneModel
    @State private var confirmingUnpair = false
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            List {
                if model.isDemo {
                    demoSection
                } else if let record = model.record {
                    macSection(record)
                    SearchAnswersSection(model: model)
                    ApprovalSettingsSection(model: model)
                    deviceSection(record)
                } else {
                    notPairedSection
                }
                queueSection
                if model.record != nil {
                    #if DEBUG
                    SpikeSection(model: model)
                    #endif
                    Section {
                        Button("Unpair This iPhone…", role: .destructive) { confirmingUnpair = true }
                    }
                }
                Section("Funes for iPhone") {
                    LabeledContent("Version", value: Self.versionText)
                }
            }
            .navigationTitle("Settings")
            .refreshable { await model.refresh(fresh: true) }
            .confirmationDialog("Unpair this iPhone?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                if model.capture.queuedCount > 0 {
                    Button("Unpair and Keep Captures", role: .destructive) { Task { await model.unpair(deletingQueue: false) } }
                    Button("Unpair and Delete Captures", role: .destructive) { Task { await model.unpair(deletingQueue: true) } }
                } else {
                    Button("Unpair", role: .destructive) { Task { await model.unpair(deletingQueue: true) } }
                }
            } message: {
                if model.capture.queuedCount > 0 {
                    Text("Your Mac forgets this iPhone, and this iPhone forgets its keys. \(model.capture.queuedCount) captures haven't reached your Mac yet: keep them to send after pairing again, or delete them.")
                } else {
                    Text("Your Mac forgets this iPhone, and this iPhone forgets its keys. You can pair again with a new code.")
                }
            }
            .confirmationDialog("Delete queued captures?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete \(model.capture.storedCount) Captures", role: .destructive) {
                    model.capture.deleteAll()
                }
            } message: {
                Text("They haven't reached your Mac and can't be recovered.")
            }
        }
    }

    /// This app's "0.5.0 (11)": the Mac section's version is the Mac's.
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Queue: N waiting, "Send now", "Delete queued captures…" (UX: iPhone, Settings tab).
    private var queueSection: some View {
        Section {
            LabeledContent("Waiting", value: model.capture.queuedCount.formatted())
            if let outcome = model.capture.lastOutcome, let line = Self.describe(outcome) {
                Text(line).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Send Now") { Task { await model.capture.deliver(.manual) } }
                .disabled((model.record == nil && !model.isDemo) || model.capture.queuedCount == 0 || model.capture.delivering)
            Button("Delete Queued Captures…", role: .destructive) { confirmingDelete = true }
                .disabled(model.capture.storedCount == 0)
        } header: {
            Text("Queue")
        } footer: {
            if model.isDemo {
                Text("Demo captures go to the demo Inbox, and are deleted when you leave the demo.")
            } else {
                Text("Captures wait on this iPhone until your Mac has them, then they're deleted here.")
            }
        }
    }

    private static func describe(_ outcome: DeliveryOutcome) -> String? {
        switch outcome {
        case .drained(0, 0): nil
        case let .drained(sent, 0): String(localized: "Sent \(sent) to your Mac.")
        case let .drained(sent, rejected): String(localized: "Sent \(sent) to your Mac; it didn't accept \(rejected).")
        case let .failed(error, retryAt, _):
            String(localized: "\(PhoneModel.message(for: error)) Trying again \(retryAt.formatted(.relative(presentation: .named))).")
        case .waiting(let until): String(localized: "Trying again \(until.formatted(.relative(presentation: .named))).")
        case .storage: String(localized: "Couldn't read the queue on this iPhone.")
        case .notPaired, .revoked, .busy: nil
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
            Button("Pair with Mac") { model.presentingPairing = true }
                .bold()
            Button("Try the Demo") { model.switchDemo(true) }
        } footer: {
            Text("The demo shows every screen with a sample vault on this iPhone. Nothing is sent anywhere, and it never mixes with your own data.")
        }
    }

    /// Demo mode (FR-iOS-10): what it is, and the way out.
    private var demoSection: some View {
        Section {
            Toggle("Demo Vault", isOn: Binding(get: { model.isDemo }, set: { model.switchDemo($0) }))
            Text("Sample memories, suggestions and requests, on this iPhone only. Nothing reaches a Mac, the network or iCloud. Changes and captures are discarded when you leave.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Demo")
        } footer: {
            Text("To use your own vault, install Funes Vault on your Mac, leave the demo, and pair.")
        }
    }

    private func macSection(_ record: PairingRecord) -> some View {
        Section {
            LabeledContent("Mac", value: record.macName)
            ReachabilityRow(reachability: model.reachability, path: model.path)
            if case let .connected(connection) = model.reachability {
                LabeledContent("Funes on the Mac", value: connection.status.appVersion)
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

/// "Connected · Wi-Fi" and the other states (UX: iPhone, States), in Settings' Mac section.
struct ReachabilityRow: View {
    let reachability: Reachability
    let path: NetworkPath?

    var body: some View {
        switch reachability {
        case .notPaired:
            Label("Not paired", systemImage: "iphone.slash")
        case .connecting:
            Label { Text("Checking…") } icon: { ProgressView() }
        case let .connected(connection):
            Label(Self.connected(ConnectionRoute(connection.address.connectionKind, path: path)), systemImage: "checkmark.circle.fill")
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
        case let .failed(error):
            Label(PhoneModel.message(for: error), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    static func connected(_ route: ConnectionRoute) -> String {
        switch route {
        // A LAN address reached off Wi-Fi, such as through a Tailscale subnet router (Spike 1e).
        case .vpn: String(localized: "Connected · VPN")
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
            Button("Queue 1,000 Test Captures and Send") { Task { await model.queueAndDrain(1_000) } }
            ForEach(model.probes) { probe in
                HStack {
                    Text(probe.address.description).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(probe.outcome).foregroundStyle(probe.outcome == "ok" ? .green : .secondary)
                }
                .font(.caption.monospaced())
            }
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

/// Settings ▸ Search answers (UX: iPhone ▸ Settings, FR-iOS-13): Show Ask in Search (this iPhone
/// only) and the engine the Mac answers with. The model is chosen on the Mac.
struct SearchAnswersSection: View {
    let model: PhoneModel
    @AppStorage(SearchAnswersSettings.showAskKey) private var showAsk = true

    var body: some View {
        Section {
            if let answers = model.macAnswers {
                Toggle("Show Ask in Search", isOn: $showAsk)
                LabeledContent("Answered by", value: answers.engine)
                LabeledContent("Answers", value: Self.trigger(answers.trigger))
            } else if model.reachability.isConnected {
                Text("Search answers are off on your Mac.").foregroundStyle(.secondary)
            } else {
                Toggle("Show Ask in Search", isOn: $showAsk)
            }
        } header: {
            Text("Search answers")
        } footer: {
            if let answers = model.macAnswers {
                Text("Your Mac reads the top results and asks \(answers.engine). Change the model, and when searches are answered, on your Mac in Settings ▸ AI Models. With Show Ask off, nothing is asked from this iPhone.")
            }
        }
    }

    /// When the Mac answers a search (memory processing §10.6).
    static func trigger(_ trigger: AnswerTrigger) -> String {
        switch trigger {
        case .ask: String(localized: "When you ask")
        case .questions: String(localized: "Automatically for questions")
        case .everySearch: String(localized: "Automatically for every search")
        }
    }
}
