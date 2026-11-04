import FunesPhone
import FunesProtocol
import Observation
import SwiftUI

/// Funes Vault for iPhone: a thin client of the vault on the Mac (spec/product/05-ux-iphone.md).
/// It opens on Home; captures wait in the queue on this iPhone until the Mac has them.
@main
struct FunesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: state.model)
                // Demo mode on or off is a new model: nothing carries over.
                .id(ObjectIdentifier(state.model))
                .task(id: ObjectIdentifier(state.model)) {
                    let model = state.model
                    // Approval notifications: a tap opens the request (task 5.6).
                    delegate.open = { [model] ref in model.open(ref) }
                    delegate.rang = { [model] in model.rang() }
                    await model.start()
                }
                // A tap on the Pulse or Rhythm widget.
                .onOpenURL { url in
                    if url == FunesWidgets.homeURL { state.model.tab = .home }
                }
                .onChange(of: scenePhase) { _, phase in
                    let model = state.model
                    switch phase {
                    // `status.get` and the queue on every foreground (companion protocol §4, §6).
                    case .active: Task { await model.foreground() }
                    // Captures from the share sheet or the Control may come while the app is away.
                    case .background: Task { await model.capture.scheduleBackgroundDelivery() }
                    default: break
                    }
                }
        }
        .backgroundTask(.appRefresh(Identifiers.iOSDeliveryTaskID)) {
            await state.backgroundDelivery()
        }
    }
}

/// The app's model, rebuilt when demo mode (FR-iOS-10) is turned on or off. Demo mode isn't
/// remembered: the app always launches on the real pairing, and a demo's captures and edits are
/// gone once it's left.
@MainActor @Observable
final class AppState {
    /// The demo's capture queue lives here, never in the App Group.
    static let demoDirectory = URL.temporaryDirectory.appending(path: "Demo", directoryHint: .isDirectory)

    private(set) var model: PhoneModel

    init() {
        PhoneServices.discardDemo(in: Self.demoDirectory)
        model = PhoneModel(services: Self.services(demo: false))
        model.switchDemo = { [weak self] on in self?.setDemo(on) }
        #if DEBUG
        if ScreenshotScene.current != nil { setDemo(true) }
        #endif
    }

    func setDemo(_ on: Bool) {
        guard on != model.isDemo else { return }
        if !on { PhoneServices.discardDemo(in: Self.demoDirectory) }
        // The cached counts are the demo's or the Mac's, never both (ADR-0025): leaving the demo
        // deletes its own, and the paired Mac's come back on the next refresh.
        OverviewCache.appGroup()?.delete()
        FunesWidgets.reload()
        model = PhoneModel(services: Self.services(demo: on))
        model.switchDemo = { [weak self] on in self?.setDemo(on) }
    }

    func backgroundDelivery() async {
        await model.backgroundDelivery()
    }

    private static func services(demo: Bool) -> PhoneServices {
        PhoneServices(demo: demo,
                      live: PhoneServices.Live(store: KeychainSecretStore(), transport: CompanionHTTPTransport(),
                                               discovery: BonjourDiscovery(), subscriptions: CloudKitSubscriptions()),
                      demoDirectory: demoDirectory)
    }
}
