#if DEBUG
import FunesProtocol
import Foundation

/// The App Store screenshots (spec/release/app-store/screenshots.md): `-FunesScreenshot <scene>`
/// launches straight into demo mode on one screen, so `scripts/app_store_screenshots.sh` captures
/// each one without tapping through the simulator. Debug builds only.
enum ScreenshotScene: String {
    case capture, share, save, access, search, inbox

    static var current: ScreenshotScene? {
        UserDefaults.standard.string(forKey: "FunesScreenshot").flatMap(ScreenshotScene.init(rawValue:))
    }

    var tab: RootView.Tab {
        switch self {
        case .search: .search
        case .inbox: .inbox
        case .capture, .share, .save, .access: .capture
        }
    }

    /// The request whose panel is open.
    var approval: ApprovalKind? {
        switch self {
        case .share: .share
        case .save: .save
        case .access: .access
        case .capture, .search, .inbox: nil
        }
    }

    /// Capture's text field, as if just typed.
    var captureText: String { self == .capture ? "Ask the team about Friday's demo" : "" }

    /// Search's query.
    var searchQuery: String? { self == .search ? "swift" : nil }
}
#endif
