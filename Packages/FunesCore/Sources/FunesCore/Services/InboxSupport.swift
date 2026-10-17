import Foundation
import FunesProtocol
import GRDB

/// The seven seed questions of onboarding (FR-O-02, memory processing §6): each answer becomes a
/// suggestion with a preset kind, category and sensitivity.
public struct SeedQuestion: Sendable, Hashable, Identifiable {
    public let id: String
    public let prompt: String
    public let kind: MemoryKind
    public let categoryKey: String
    public let sensitivity: Sensitivity

    public static let all: [SeedQuestion] = [
        SeedQuestion(id: "collaboration_style", prompt: "How do you like AI assistants to collaborate with you?",
                     kind: .preference, categoryKey: "communication_style", sensitivity: .low),
        SeedQuestion(id: "communication_preferences", prompt: "What tone, level of detail, or format do you usually prefer?",
                     kind: .preference, categoryKey: "communication_style", sensitivity: .low),
        SeedQuestion(id: "software_development_preferences",
                     prompt: "What should coding assistants know about how you build software?",
                     kind: .instruction, categoryKey: "software_development", sensitivity: .low),
        SeedQuestion(id: "current_projects", prompt: "Which current projects should your vault remember, and why do they matter?",
                     kind: .projectContext, categoryKey: "project_context", sensitivity: .internal),
        SeedQuestion(id: "privacy_preferences", prompt: "What should Funes be especially careful not to share casually?",
                     kind: .constraint, categoryKey: "privacy_preferences", sensitivity: .internal),
        SeedQuestion(id: "life_constraints",
                     prompt: "Are there practical constraints that often shape your work or availability?",
                     kind: .constraint, categoryKey: "project_context", sensitivity: .internal),
        SeedQuestion(id: "long_term_goals", prompt: "What long-term goals should assistants keep in mind when helping you?",
                     kind: .goal, categoryKey: "project_context", sensitivity: .internal),
    ]

    /// The suggestion's proposed title: the question's subject, since the answer is the body.
    public var title: String {
        switch id {
        case "collaboration_style": "How I like to collaborate"
        case "communication_preferences": "Tone, detail and format"
        case "software_development_preferences": "How I build software"
        case "current_projects": "Current projects"
        case "privacy_preferences": "Not to share casually"
        case "life_constraints": "Practical constraints"
        case "long_term_goals": "Long-term goals"
        default: "Answer"
        }
    }
}

extension SuggestionService {
    /// Stores a seed-question answer as a pending suggestion (FR-O-02), after validation and the
    /// secret scanner. Answers are never applied directly.
    @discardableResult
    public func seed(_ question: SeedQuestion, answer: String, now: Date) async throws -> UUID {
        let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard InputLimits.body.contains(InputLimits.length(of: body)) else { throw VaultError.invalidInput(field: "body") }
        let findings = SecretScanner.scan(body)
        guard findings.isEmpty else { throw VaultError.secretLikeContent(findings) }
        let id = try await store.writer.write { db in
            let categories = try MemoryStore.validateCategories(db, [question.categoryKey])
            let sensitivity = max(question.sensitivity, try MemoryStore.defaultSensitivity(db, categoryKeys: categories))
            return try Self.insertSuggestion(
                db, origin: .seedQuestion,
                input: SuggestInput(title: question.title, body: body, kind: question.kind),
                categories: categories, sensitivity: sensitivity, now: now)
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: .user, via: .app, event: "seed_question",
                                      outcome: "queued", ids: [id]))
        return id
    }

    /// Where each import run came from, for Inbox cards ("Imported from ChatGPT").
    public func importSources() async throws -> [UUID: ImportSource] {
        try await store.writer.read { db in
            var out: [UUID: ImportSource] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, source FROM import_run") {
                if let id = row.uuid("id"), let source = ImportSource(rawValue: row["source"]) { out[id] = source }
            }
            return out
        }
    }

    /// The suggestions with these ids that still exist, any status (Activity's live titles).
    public func suggestions(ids: [UUID]) async throws -> [Suggestion] {
        guard !ids.isEmpty else { return [] }
        return try await store.writer.read { db in
            var found: [Suggestion] = []
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                found += try Row.fetchAll(db, sql: "SELECT * FROM suggestion WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))",
                                          arguments: StatementArguments(chunk.map(\.db))).map(Suggestion.from(row:))
            }
            return found
        }
    }

    /// Expired suggestions that can still be restored (FR-I-05), newest first.
    public func restorable(now: Date) async throws -> [Suggestion] {
        try await store.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM suggestion WHERE status = 'expired' AND expires_after > ? ORDER BY created_at DESC
                """, arguments: [now - Self.restorable]).map(Suggestion.from(row:))
        }
    }
}
