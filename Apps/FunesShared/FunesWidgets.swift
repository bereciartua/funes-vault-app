import Foundation
import WidgetKit

/// The Home Screen widgets (FR-H-06, UX: iPhone ▸ Widgets), in the app and the Intents extension
/// both: the extension draws them from the cached overview; the app reloads them after every
/// write of that cache, and opens Home from their link.
enum FunesWidgets {
    static let pulse = "com.funesvault.ios.pulse"
    static let remember = "com.funesvault.ios.remember"
    static let rhythm = "com.funesvault.ios.rhythm"

    /// A tap on Pulse or Rhythm: Funes on Home.
    static let homeURL = URL(string: "funesvault://home")!

    /// The cache changed, or the pairing or the demo with it: every widget reads it again.
    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
