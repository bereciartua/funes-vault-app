import AppIntents
import SwiftUI
import WidgetKit

/// The App Intents and Control extension (`com.funesvault.ios.intents`). Task 5.3 sets up the
/// target; task 5.4 adds "Remember in Funes" and makes the Control open Capture.
@main
struct FunesIntentsBundle: WidgetBundle {
    var body: some Widget {
        CaptureControl()
    }
}

/// A Control Center, Lock Screen and Action button control (iOS 18).
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.funesvault.ios.capture") {
            ControlWidgetButton(action: OpenFunesIntent()) {
                Label("Funes Vault", systemImage: "eye")
            }
        }
        .displayName("Funes Vault")
        .description("Opens Funes Vault.")
    }
}
