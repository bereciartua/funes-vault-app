import Foundation
import FunesCore
import FunesProtocol
import Observation

/// The Inbox's state beyond the pending list AppModel keeps: Later, selection, results, import
/// sources and expired suggestions (FR-I-01..05).
@MainActor @Observable
final class InboxModel {
    private let services: VaultEnvironment
    /// Put aside with Later for this session: shown last, collapsed.
    var later = Set<UUID>()
    var selection = Set<UUID>()
    /// The card ⌘⏎ and ⌫ act on.
    var focused: UUID?
    var result: String?
    private(set) var importSources: [UUID: ImportSource] = [:]
    private(set) var restorable: [Suggestion] = []
    /// What each card shows, kept while the Inbox reloads (edited ones keep the user's values).
    var drafts: [UUID: SuggestionDraft] = [:]
    @ObservationIgnored var categories: () -> [MemoryCategory] = { [] }

    init(services: VaultEnvironment) {
        self.services = services
    }

    func load() async {
        importSources = (try? await services.suggestions.importSources()) ?? [:]
        restorable = (try? await services.suggestions.restorable(now: Date())) ?? []
    }

    enum Group: String, CaseIterable, Identifiable {
        case agents, captures, imports, answers
        var id: String { rawValue }

        var title: String {
            switch self {
            case .agents: String(localized: "From agents")
            case .captures: String(localized: "Captures")
            case .imports: String(localized: "Imports")
            case .answers: String(localized: "Your answers")
            }
        }

        static func of(_ suggestion: Suggestion) -> Group {
            switch suggestion.origin {
            case .agent: .agents
            case .captureMac, .captureIPhone: .captures
            case .import: .imports
            case .seedQuestion, .consolidation: .answers
            }
        }
    }

    /// Pending suggestions by section, Later ones last within each.
    func grouped(_ inbox: [Suggestion]) -> [(Group, [Suggestion])] {
        Group.allCases.compactMap { group in
            let items = inbox.filter { Group.of($0) == group }
            guard !items.isEmpty else { return nil }
            return (group, items.filter { !later.contains($0.id) } + items.filter { later.contains($0.id) })
        }
    }

    // MARK: Actions

    /// The card's draft for a suggestion as it is now: an untouched one follows classification.
    func draft(for suggestion: Suggestion) -> SuggestionDraft {
        let draft = drafts[suggestion.id]?.refreshed(from: suggestion, categories: categories())
            ?? SuggestionDraft(suggestion, categories: categories())
        if drafts[suggestion.id] != draft { drafts[suggestion.id] = draft }
        return draft
    }

    /// Applies the suggestion as its own action, with exactly what the card shows (every field,
    /// so a change underneath can't slip in), or `edits` for a conflict's Edit…. `mode` nil is
    /// the action's own way: Replace for an update. Returns the similar memories to point out,
    /// or throws.
    func apply(_ suggestion: Suggestion, mode: ApplyMode? = nil, edits: SuggestionEdit? = nil) async throws -> ApplyResult {
        let edit = edits ?? draft(for: suggestion).edit
        let result = try await services.suggestions.apply(suggestionID: suggestion.id, edits: edit, mode: mode, now: Date())
        drafts[suggestion.id] = nil
        selection.remove(suggestion.id)
        return result
    }

    func reject(_ suggestion: Suggestion) async throws {
        try await services.suggestions.reject(suggestionID: suggestion.id, now: Date())
        drafts[suggestion.id] = nil
        selection.remove(suggestion.id)
    }

    /// Apply N / Reject N with per-item results (FR-I-03): "12 applied, 1 blocked by the secret
    /// scanner". Each row applies as its own action; conflicts (which need an answer) and rows
    /// outside an agent's scope are left for the user.
    func bulk(apply: Bool, _ items: [Suggestion]) async {
        var done = 0, secrets = 0, changed = 0, left = 0, failed = 0
        for item in items {
            do {
                if apply {
                    guard item.action != .conflict, !item.outsideScope else {
                        left += 1
                        continue
                    }
                    _ = try await self.apply(item)
                } else {
                    try await reject(item)
                }
                done += 1
            } catch VaultError.secretLikeContent {
                secrets += 1
            } catch VaultError.targetChanged {
                changed += 1
            } catch {
                failed += 1
            }
        }
        var parts = [apply ? String(localized: "\(done) applied") : String(localized: "\(done) rejected")]
        if secrets > 0 { parts.append(String(localized: "\(secrets) blocked by the secret scanner")) }
        if changed > 0 { parts.append(String(localized: "\(changed) changed since suggested")) }
        if left > 0 { parts.append(String(localized: "\(left) need your answer")) }
        if failed > 0 { parts.append(String(localized: "\(failed) couldn't be changed")) }
        result = parts.joined(separator: ", ")
        selection = []
    }

    func restore(_ suggestion: Suggestion) async {
        try? await services.suggestions.restore(suggestionID: suggestion.id, now: Date())
        await load()
    }
}

/// Who proposed a card's fields (FR-AI-08): "Proposed on this Mac", "Proposed by Claude via
/// Anthropic", "Kept on this Mac: looked sensitive".
enum EngineText {
    static func text(_ suggestion: Suggestion, agentName: String?, providerName: (String) -> String?) -> String? {
        guard let json = suggestion.classification, let data = json.data(using: .utf8),
              let record = try? JSONDecoder().decode(ClassificationRecord.self, from: data) else {
            if let agentName { return String(localized: "Proposed by \(agentName)") }
            return nil
        }
        if record.keptOnDevice { return String(localized: "Kept on this Mac: looked sensitive") }
        if record.engine == RulesClassifier.engine || record.engine == "apple.foundation" {
            return String(localized: "Proposed on this Mac")
        }
        let parts = record.engine.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return String(localized: "Proposed by \(record.engine)") }
        let model = parts[1].split(separator: "/").last.map(String.init) ?? parts[1]
        return String(localized: "Proposed by \(model) via \(providerName(parts[0]) ?? parts[0])")
    }
}
