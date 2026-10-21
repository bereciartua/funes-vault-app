import AppIntents

/// Opens Funes. The Control's action for now; task 5.4 makes it open the Capture tab, ready to
/// type or dictate, and adds "Remember in Funes". In the app and the extension both, so the
/// system can run it in the app.
struct OpenFunesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Funes Vault"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult { .result() }
}
