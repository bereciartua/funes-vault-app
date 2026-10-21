import FunesPhone
import SwiftUI

/// Funes Vault for iPhone: a thin client of the vault on the Mac (spec/product/05-ux-iphone.md).
/// Task 5.3 is the foundation: pairing, the connection to the Mac, and its status.
@main
struct FunesApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    // `status.get` on every foreground (companion protocol §4).
                    if phase == .active { Task { await model.refresh() } }
                }
        }
    }
}
