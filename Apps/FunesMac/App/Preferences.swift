import Foundation
import FunesProtocol

/// The app's settings in user defaults (storage §1): UI preferences, the hotkey, the setup
/// checklist and the pause. Never memory text, keys or anything an agent sent.
@MainActor
final class Preferences {
    enum Key {
        static let showInDock = "ShowInDock"
        static let launchAtLoginAsked = "LaunchAtLoginAsked"
        static let pausedUntil = "PausedUntil"
        static let notifyExpired = "NotifyRequestExpired"
        static let notifySuggestion = "NotifySuggestionWaiting"
        static let notifyRefused = "NotifyAgentRefused"
        static let hotKey = "CaptureHotKey"
        static let captureSensitivity = "CaptureDefaultSensitivity"
        static let classifyCaptures = "ClassifyCaptures"
        static let checklistDismissed = "SetupChecklistDismissed"
        static let checklistSeeded = "SetupChecklistSeeded"
        static let checklistReviewed = "SetupChecklistReviewed"
        static let mcpEnabled = "MCPServerEnabled"
        static let importantRetentionDays = "ActivityImportantDays"
        static let routineRetentionDays = "ActivityRoutineDays"
        static let automaticBackups = "AutomaticBackups"
        static let lastBackup = "LastBackup"
        static let lastIntegrityCheck = "LastIntegrityCheck"
    }

    let defaults: UserDefaults

    /// Debug builds with FUNES_DATA_DIR keep their settings apart too, so a development vault
    /// never changes the installed app's settings.
    static var defaultStore: UserDefaults {
        if isDevelopmentVault, let dev = UserDefaults(suiteName: "com.funesvault.dev") { return dev }
        return .standard
    }

    /// A Debug build on a FUNES_DATA_DIR vault.
    nonisolated static var isDevelopmentVault: Bool {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["FUNES_DATA_DIR"], !override.isEmpty { return true }
        #endif
        return false
    }

    init(defaults: UserDefaults = Preferences.defaultStore) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showInDock: false,
            Key.classifyCaptures: true,
            Key.captureSensitivity: -1,
            Key.mcpEnabled: true,
            Key.importantRetentionDays: 400,
            Key.routineRetentionDays: 30,
            Key.automaticBackups: true,
        ])
    }

    var showInDock: Bool {
        get { defaults.bool(forKey: Key.showInDock) }
        set { defaults.set(newValue, forKey: Key.showInDock) }
    }

    /// "Pause Funes Vault" survives a relaunch; `.distantFuture` is "until I resume".
    var pausedUntil: Date? {
        get { defaults.object(forKey: Key.pausedUntil) as? Date }
        set { defaults.set(newValue, forKey: Key.pausedUntil) }
    }

    var notifyExpired: Bool {
        get { defaults.bool(forKey: Key.notifyExpired) }
        set { defaults.set(newValue, forKey: Key.notifyExpired) }
    }

    var notifySuggestion: Bool {
        get { defaults.bool(forKey: Key.notifySuggestion) }
        set { defaults.set(newValue, forKey: Key.notifySuggestion) }
    }

    var notifyRefused: Bool {
        get { defaults.bool(forKey: Key.notifyRefused) }
        set { defaults.set(newValue, forKey: Key.notifyRefused) }
    }

    /// The default sensitivity offered for captures; nil lets classification decide.
    var captureSensitivity: Sensitivity? {
        get { Sensitivity(rawValue: defaults.integer(forKey: Key.captureSensitivity)) }
        set { defaults.set(newValue?.rawValue ?? -1, forKey: Key.captureSensitivity) }
    }

    var classifyCaptures: Bool {
        get { defaults.bool(forKey: Key.classifyCaptures) }
        set { defaults.set(newValue, forKey: Key.classifyCaptures) }
    }

    var mcpEnabled: Bool {
        get { defaults.bool(forKey: Key.mcpEnabled) }
        set { defaults.set(newValue, forKey: Key.mcpEnabled) }
    }

    func flag(_ key: String) -> Bool { defaults.bool(forKey: key) }
    func set(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }
}
