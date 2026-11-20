import Foundation

/// Activity's words for the facts rows (`facts_learned`, `facts_backfill`, `facts_removed`, `facts_corrected`; FR-L-02,
/// memory processing §11.9): a title, a detail line and a result, from the row's outcome, counts and engine only. The
/// rows hold ids and counts, never names, labels or quotes, and nothing here looks anything up to add them (a learned
/// row's id is its run's, not a memory's). The Mac's Activity shows them. `String(localized:)` resolves in the main
/// bundle on purpose (the app's String Catalog, as BridgeUI's words do), not FunesCore's resources.
public struct FactsActivityWords: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case neutral, good, warning }

    /// The events these words cover: Activity looks up no memory title for their ids.
    public static let events: Set<String> = ["facts_learned", "facts_backfill", "facts_removed", "facts_corrected"]

    /// "Learned facts from 3 memories".
    public let title: String
    /// "claude/haiku · 1 by rules only"; empty when there's nothing to add.
    public let detail: String
    /// The Result column: "Done", "Finished", "2 failed".
    public let result: String
    public let tone: Tone

    /// Nil for any other event.
    public init?(_ event: ActivityEvent) {
        let c = event.counts
        func n(_ key: String) -> Int { c[key] ?? 0 }
        let done = String(localized: "Done")
        switch event.event {
        case "facts_learned":
            // One row per call group's run. Each memory it took is `applied` (the model's reading), `code_only` (rules
            // only: no model, the cap, a refusal), `changed` (nothing kept: the memory or roster changed, or learning
            // stopped, so it's read again later) or `failed`.
            let learned = n("applied") + n("code_only")
            title = learned == 0 ? String(localized: "Learned no facts")
                : learned == 1 ? String(localized: "Learned facts from 1 memory")
                : String(localized: "Learned facts from \(learned) memories")
            // The model only where it read something; rules alone otherwise.
            let model = event.engine.flatMap { $0 == "code" || n("applied") + n("failed") == 0 ? nil : $0 }
            let rules = n("code_only") == 0 ? nil : model == nil ? String(localized: "Rules only") : Self.rulesOnly(n("code_only"))
            detail = Self.joined([model, rules, Self.later(n("changed"))])
            if let failed = Self.failed(n("failed")) {
                (result, tone) = failed
            } else if learned > 0 {
                (result, tone) = (done, .neutral)
            } else if n("changed") > 0 {
                (result, tone) = (String(localized: "Read later"), .neutral)
            } else {
                (result, tone) = (String(localized: "Nothing to read"), .neutral)
            }
        case "facts_backfill":
            switch event.outcome {
            case "started":
                // The memories marked and the model calls the sheet counted.
                title = String(localized: "Started reading existing memories")
                detail = n("memories") == 0 ? String(localized: "Nothing to read")
                    : Self.joined([Self.memories(n("memories")), Self.aboutCalls(n("calls"))])
                (result, tone) = (String(localized: "Started"), .neutral)
            case "finished":
                // `memories`: those marked at the start; `calls`: the requests sent under the exemption (a retry, or a
                // read after it was spent, counts toward the day's cloud requests instead).
                title = String(localized: "Finished reading existing memories")
                detail = n("memories") == 0 && n("calls") == 0
                    ? String(localized: "Nothing to read")
                    : Self.joined([Self.memories(n("memories")), Self.uncounted(n("calls")), Self.rulesOnly(n("code_only"))])
                (result, tone) = Self.failed(n("failed")) ?? (String(localized: "Finished"), .good)
            default:
                title = String(localized: "Read existing memories")
                detail = ""
                (result, tone) = (event.outcome.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? done, .neutral)
            }
        case "facts_removed":
            title = String(localized: "Removed learned facts")
            detail = [Self.names(n("entities")), Self.facts(n("facts"))].joined(separator: ", ")
            (result, tone) = (String(localized: "Removed"), .neutral)
        case "facts_corrected":
            if n("undone") > 0 {
                // One Undo takes a whole action back; the count is the rows it removed.
                title = String(localized: "Undid a correction")
                detail = ""
            } else {
                title = String(localized: "Corrected a fact")
                detail = [n("entities") > 0 ? Self.names(n("entities")) : nil,
                          n("facts") > 0 ? Self.facts(n("facts")) : nil,
                          n("links") > 0 ? Self.mentions(n("links")) : nil,
                          n("orders") > 0 ? Self.orders(n("orders")) : nil]
                    .compactMap { $0 }.joined(separator: ", ")
            }
            (result, tone) = (done, .neutral)
        default:
            return nil
        }
    }

    // MARK: Counts

    static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func failed(_ count: Int) -> (String, Tone)? {
        count > 0 ? (String(localized: "\(count) failed"), .warning) : nil
    }

    static func rulesOnly(_ count: Int) -> String? {
        count > 0 ? String(localized: "\(count) by rules only") : nil
    }

    static func memories(_ count: Int) -> String {
        count == 1 ? String(localized: "1 memory") : String(localized: "\(count) memories")
    }

    /// Requests the first backfill's exemption kept out of the day's count.
    static func uncounted(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? String(localized: "1 cloud request outside the daily count")
                          : String(localized: "\(count) cloud requests outside the daily count")
    }

    /// Memories left for a later read.
    static func later(_ count: Int) -> String? {
        count > 0 ? String(localized: "\(count) to read later") : nil
    }

    static func aboutCalls(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? String(localized: "about 1 model call") : String(localized: "about \(count) model calls")
    }

    /// Entities: People & history's "People & names".
    static func names(_ count: Int) -> String {
        count == 1 ? String(localized: "1 name") : String(localized: "\(count) names")
    }

    static func facts(_ count: Int) -> String {
        count == 1 ? String(localized: "1 fact") : String(localized: "\(count) facts")
    }

    /// Links: who a phrase in a memory means.
    static func mentions(_ count: Int) -> String {
        count == 1 ? String(localized: "1 mention") : String(localized: "\(count) mentions")
    }

    /// Orders on your timeline ("came just before").
    static func orders(_ count: Int) -> String {
        count == 1 ? String(localized: "1 timeline order") : String(localized: "\(count) timeline orders")
    }
}
