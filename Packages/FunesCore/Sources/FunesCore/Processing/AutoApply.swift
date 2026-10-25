import Foundation
import FunesProtocol
import Synchronization

/// Settings ▸ AI Models ▸ Apply changes automatically (memory processing §5.7, §9.5), shared by
/// New memories and the tidy-up.
public enum AutoApplyLevel: Int, Sendable, Hashable, Comparable, Codable, CaseIterable {
    case off = 0
    case duplicatesOnly
    case exceptConflicts

    public static func < (a: AutoApplyLevel, b: AutoApplyLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Auto-apply for New memories (memory processing §5.7). A level applies only for an engine that
/// reached it: at least 95% of what the level applies right, on at least 20 applied items, on
/// both of Spike E's fixture sets pooled, against the user's compound-claim labels. No engine
/// did (best: GPT-5.6-Terra 92% at Everything except conflicts, Claude Opus 5.5 85% at Duplicates
/// only), so `measured` is empty and every piece goes to the Inbox. The levels are built behind
/// it, to be enabled per engine once a re-measurement passes. `confidence` gates nothing; the
/// gate is `atomic`, the support check and the trust rule.
public struct NewMemoryAutoApply: Sendable, Hashable {
    /// The level each model id reached for New memories. Empty in 6a.
    public static let measured: [String: AutoApplyLevel] = [:]

    /// The user's setting.
    public var level: AutoApplyLevel
    /// Model id → the highest level it reached.
    public var qualified: [String: AutoApplyLevel]

    public init(level: AutoApplyLevel = .off, qualified: [String: AutoApplyLevel] = NewMemoryAutoApply.measured) {
        self.level = level
        self.qualified = qualified
    }

    /// The level that applies for output from `engine` (`<provider>/<model>`): the user's
    /// setting, capped at what that model reached. Only the chosen engine's output reaches here.
    public func effective(engine: String) -> AutoApplyLevel {
        let model = engine.split(separator: "/", maxSplits: 1).last.map(String.init) ?? engine
        return min(level, qualified[model] ?? .off)
    }

    /// The highest level any engine may be set to (Settings disables the others).
    public static var highestAvailable: AutoApplyLevel { measured.values.max() ?? .off }

    /// Whether a piece of the user's input is applied without review at `level`.
    /// - `typed`: the user typed or dictated the input; only then may updates and retractions
    ///   apply (shared text, Services captures and imports can at most create pieces).
    /// - `baseline`: the level the piece was expected at (the user's hint or its categories'
    ///   default); a piece raised above it is possibly sensitive, so it's reviewed.
    static func applies(_ piece: SplitPiece, level: AutoApplyLevel, typed: Bool, baseline: Sensitivity) -> Bool {
        switch level {
        case .off:
            return false
        case .duplicatesOnly:
            return piece.decision.action == .duplicate
        case .exceptConflicts:
            guard piece.piece.atomic, piece.piece.supported, piece.piece.sensitivity <= baseline else { return false }
            switch piece.decision.action {
            case .create, .duplicate: return true
            case .update, .retract: return typed
            }
        }
    }
}

/// Suggestions the user has open closely: a card being edited in the Inbox, a Save panel on the
/// Mac, an approval on the iPhone. The tidy-up never withdraws one of its proposals from under
/// them (§9.5). New memories don't need it: a card can't be edited or saved while it's processing.
public final class SuggestionHolds: Sendable {
    public enum Reason: String, Sendable, Hashable {
        case editing, savePanel, phoneApproval
    }

    private let holds = Mutex<[UUID: Set<Reason>]>([:])

    public init() {}

    public func hold(_ id: UUID, _ reason: Reason) { holds.withLock { $0[id, default: []].insert(reason) } }

    public func release(_ id: UUID, _ reason: Reason) {
        holds.withLock { h in
            h[id]?.remove(reason)
            if h[id]?.isEmpty == true { h[id] = nil }
        }
    }

    public func isHeld(_ id: UUID) -> Bool { holds.withLock { $0[id] != nil } }
}
