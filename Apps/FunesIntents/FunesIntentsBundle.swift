import AppIntents
import SwiftUI
import WidgetKit

/// The App Intents and Control extension (`com.funesvault.ios.intents`): the Control, and
/// "Remember in Funes" (in `Apps/FunesShared`, with the Control's intent).
@main
struct FunesIntentsBundle: WidgetBundle {
    var body: some Widget {
        CaptureControl()
    }
}

/// A Control Center, Lock Screen and Action button control (iOS 18) that opens Home's composer,
/// ready to type or dictate.
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.funesvault.ios.capture") {
            ControlWidgetButton(action: OpenCaptureIntent()) {
                Label("Capture", systemImage: "square.and.pencil")
            }
        }
        .displayName("Capture in Funes")
        .description("Opens Funes Vault on Home, ready to type or dictate.")
    }
}
