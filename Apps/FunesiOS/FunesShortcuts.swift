import AppIntents

/// Siri phrases and the Shortcuts app's ready-made actions.
struct FunesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RememberInFunesIntent(),
                    phrases: ["Remember in \(.applicationName)", "Save to \(.applicationName)"],
                    shortTitle: "Remember in Funes",
                    systemImageName: "text.badge.plus")
    }
}
