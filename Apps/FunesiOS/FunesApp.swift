import FunesPhone
import FunesProtocol
import SwiftUI

/// Funes Vault for iPhone: a thin client of the vault on the Mac (spec/product/05-ux-iphone.md).
/// It opens on Capture; captures wait in the queue on this iPhone until the Mac has them.
@main
struct FunesApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.start() }
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
