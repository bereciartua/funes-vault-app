import FunesPhone
import FunesProtocol
import SwiftUI

/// Funes Vault for iPhone: a thin client of the vault on the Mac (spec/product/05-ux-iphone.md).
/// It opens on Capture; captures wait in the queue on this iPhone until the Mac has them.
@main
struct FunesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    // Approval notifications: a tap opens the request (task 5.6).
                    delegate.open = { [model] ref in model.open(ref) }
                    delegate.rang = { [model] in model.rang() }
                    await model.start()
                }
                .onChange(of: scenePhase) { _, phase in
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
            await model.backgroundDelivery()
        }
    }
}
