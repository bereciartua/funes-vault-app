import Foundation
import FunesProtocol

/// The words of the Search answer card on the iPhone (FR-iOS-13, memory processing §10.5): the
/// Mac sends data, not text, and these say it as the Mac's card does. They resolve in the app's
/// String Catalog, which `scripts/sync_strings.sh` fills from this file too.
public enum AnswerWording {
    /// The demo's hint for a search that isn't one of its sample questions.
    public static let demoHintReason = "demo_hint"

    /// "Claude · Cloud", "On your Mac".
    public static func badge(_ engine: String, _ locality: AnswerLocality) -> String {
        switch locality {
        case .onDevice: String(localized: "On your Mac")
        case .localServer: String(localized: "\(engine) · Local server")
        case .appleCloud: String(localized: "\(engine) · Apple cloud")
        case .cloud: String(localized: "\(engine) · Cloud")
        }
    }

    public static func reading(_ count: Int) -> String { String(localized: "Reading \(count) results…") }

    public static func noAnswer(_ read: Int) -> String { String(localized: "No answer in the \(read) results read.") }

    /// "Read 8 of 30 results · 6 s".
    public static func footer(_ result: MemoryAnswerResult, results: Int) -> String {
        let seconds = Int((Double(result.durationMs) / 1_000).rounded())
        return String(localized: "Read \(result.read) of \(results) results · \(seconds) s")
    }

    /// "1 memory wasn't read: it's above your Mac's cloud limit", "1 claim left out: it didn't quote a memory".
    public static func notes(_ result: MemoryAnswerResult) -> [String] {
        var lines: [String] = []
        // A local model withholds only memories that look like they hold secrets.
        let local = result.locality == .onDevice || result.locality == .localServer
        switch (result.withheld, local) {
        case (0, _): break
        case (1, false): lines.append(String(localized: "1 memory wasn't read: it's above your Mac's cloud limit"))
        case (_, false): lines.append(String(localized: "\(result.withheld) memories weren't read: they're above your Mac's cloud limit"))
        case (1, true): lines.append(String(localized: "1 memory wasn't read: it looks like it holds a secret"))
        case (_, true): lines.append(String(localized: "\(result.withheld) memories weren't read: they look like they hold secrets"))
        }
        switch result.dropped {
        case 0: break
        case 1: lines.append(String(localized: "1 claim left out: it didn't quote a memory"))
        default: lines.append(String(localized: "\(result.dropped) claims left out: they didn't quote a memory"))
        }
        return lines
    }

    /// A failure's line, and whether Try Again can help. `unreachable` words a client error (the
    /// app's usual message).
    public static func failure(_ failure: SearchModel.AnswerFailure, engine: String,
                               unreachable: (CompanionClientError) -> String) -> (text: String, retry: Bool) {
        switch failure {
        case .answersOff:
            return (String(localized: "Search answers are off on your Mac."), false)
        case .capReached:
            return (String(localized: "Today's cloud requests are used up on your Mac. Search still works; answers are back tomorrow."), false)
        case .timeout:
            return (String(localized: "Took too long. Try again."), true)
        case let .modelUnavailable(reason):
            switch reason {
            case "secret_in_search": return (String(localized: "Your search looks like it contains a secret, so it wasn't sent."), false)
            case "invalid_output": return (String(localized: "The model's answer couldn't be read. Try again."), true)
            case "not_signed_in": return (String(localized: "\(engine) isn't signed in on your Mac."), false)
            case "needs_update": return (String(localized: "\(engine) needs an update on your Mac."), false)
            case "plan_limit": return (String(localized: "\(engine) says to slow down. Try again later."), true)
            case "tool_blocked": return (String(localized: "\(engine) is paused on your Mac: test its connection in Settings ▸ AI Models."), false)
            case demoHintReason?: return (String(localized: "In the demo, try: When does my lease renew?"), false)
            default: return (String(localized: "Your Mac's model couldn't answer. Try again."), true)
            }
        case let .client(error):
            return (unreachable(error), true)
        }
    }
}
