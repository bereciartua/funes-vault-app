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
    /// Edits made on cards, kept while the Inbox reloads.
    var edits: [UUID: SuggestionForm] = [:]

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

    /// Applies with the card's edits. Returns the similar memories to point out, or throws.
    func apply(_ suggestion: Suggestion, mode: ApplyMode = .keepBoth) async throws -> ApplyResult {
        let edit = edits[suggestion.id].map { $0.edit(from: suggestion) } ?? SuggestionEdit()
        let result = try await services.suggestions.apply(suggestionID: suggestion.id, edits: edit, mode: mode, now: Date())
        edits[suggestion.id] = nil
        selection.remove(suggestion.id)
        return result
    }

    func reject(_ suggestion: Suggestion) async throws {
        try await services.suggestions.reject(suggestionID: suggestion.id, now: Date())
        edits[suggestion.id] = nil
        selection.remove(suggestion.id)
    }

    /// Apply N / Reject N with per-item results (FR-I-03): "12 applied, 1 blocked by the secret scanner".
    func bulk(apply: Bool, _ items: [Suggestion]) async {
        var done = 0, secrets = 0, failed = 0
        for item in items {
            do {
                if apply { _ = try await self.apply(item) } else { try await reject(item) }
                done += 1
            } catch VaultError.secretLikeContent {
                secrets += 1
            } catch {
                failed += 1
            }
        }
        var parts = [apply ? String(localized: "\(done) applied") : String(localized: "\(done) rejected")]
        if secrets > 0 { parts.append(String(localized: "\(secrets) blocked by the secret scanner")) }
        if failed > 0 { parts.append(String(localized: "\(failed) couldn't be changed")) }
        result = parts.joined(separator: ", ")
        selection = []
    }

    func restore(_ suggestion: Suggestion) async {
        try? await services.suggestions.restore(suggestionID: suggestion.id, now: Date())
        await load()
    }
}

/// A card's editable proposal (FR-I-02 Edit & Apply).
struct SuggestionForm: Equatable {
    var title: String
    var body: String
    var kind: MemoryKind
    var categoryKeys: [String]
    var sensitivity: Sensitivity

    init(_ suggestion: Suggestion, categories: [MemoryCategory]) {
        title = suggestion.title
        body = suggestion.body
        kind = suggestion.kind ?? .fact
        categoryKeys = suggestion.categoryKeys.isEmpty ? ["personal_preferences"] : suggestion.categoryKeys
        sensitivity = suggestion.sensitivity ?? MemoryForm.defaultSensitivity(categoryKeys, categories: categories)
    }

    func edit(from suggestion: Suggestion) -> SuggestionEdit {
        SuggestionEdit(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                       body: body.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, categoryKeys: categoryKeys,
                       sensitivity: sensitivity)
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
