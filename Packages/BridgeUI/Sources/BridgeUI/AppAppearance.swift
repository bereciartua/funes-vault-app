import AppKit

// Written for Funes; EK Bridge has the same setting with the same words (Settings ▸ General ▸
// Appearance), so it belongs with the shared UI pieces.

/// Settings ▸ General ▸ Appearance: follow macOS, or keep the app light or dark whatever macOS
/// uses. Applied app-wide through `NSApp.appearance`, so every window, panel, sheet and alert
/// follows it, and so do colors that resolve against the view's appearance. Menus take the menu
/// bar's appearance instead: a status item's menu sets `NSMenu.appearance` when it opens, while
/// the main menu's menus (File, Edit…) always follow the menu bar, as in every app.
public enum AppAppearance: String, CaseIterable, Sendable {
    /// Follows macOS: the default, and the app's behaviour before the setting existed.
    case automatic
    case light
    case dark

    /// The stored value; nothing, or anything unknown, is Automatic.
    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .automatic
    }

    /// The appearance to force; nil follows macOS.
    public var appearanceName: NSAppearance.Name? {
        switch self {
        case .automatic: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    public var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    /// Sets it for the whole app. Call it at launch before any window or panel shows, and on change.
    @MainActor public func apply() {
        NSApp.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}
