import AppIntents
import FunesPhone
import FunesProtocol

/// "Remember in Funes" (UX: iPhone, Capture surfaces outside the app): Shortcuts, Siri and the
/// Action button. It only adds to the capture queue; the app or a background refresh delivers.
/// In the app and the Intents extension both, so the system can run it in either.
struct RememberInFunesIntent: AppIntent {
    static let title: LocalizedStringResource = "Remember in Funes"
    static let description = IntentDescription("Saves text to your Funes vault. It waits here until your vault has it.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Remember \(\.$text) in Funes")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            try CaptureQueue.appGroup().add(text, source: .intent)
        } catch {
            throw RememberError(error)
        }
        AppSignal.queueChanged.post()
        return .result(dialog: "Saved")
    }
}

/// Why "Remember in Funes" didn't save, as Siri and Shortcuts say it.
struct RememberError: Error, CustomLocalizedStringResourceConvertible {
    let reason: CaptureQueueError

    init(_ reason: CaptureQueueError) { self.reason = reason }

    var localizedStringResource: LocalizedStringResource {
        switch reason {
        case .empty: "There's nothing to remember."
        case .tooLong: "That's over 10,000 characters."
        case .secret: "Not saved: it looks like a password, key or card number. Funes never stores secrets."
        case .full: "Queue full: connect to your Mac."
        case .storage: "Couldn't save on this iPhone."
        }
    }
}

/// The Control's action, and the Remember widget's **Remember**: opens Funes on Home's composer,
/// ready to type or dictate. It may run here or in the app, so it leaves the request where the app
/// finds it (`CaptureLaunch`).
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture in Funes"
    static let description = IntentDescription("Opens Funes Vault on Home, ready to type or dictate.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        CaptureLaunch().request()
        return .result()
    }
}

/// The Remember widget's 🎙: opens Funes on Home's composer, dictating (the keyboard before iOS 26,
/// whose microphone dictates). Only the widget offers it.
struct OpenDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate in Funes"
    static let description = IntentDescription("Opens Funes Vault on Home, ready to dictate.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        CaptureLaunch().request(.dictate)
        return .result()
    }
}
