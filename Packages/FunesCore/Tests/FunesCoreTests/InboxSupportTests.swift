import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Tasks 3.3 and 3.8: seed questions (FR-O-02), import sources on Inbox cards and restorable
/// expired suggestions (FR-I-05).
@Suite struct InboxSupportTests {
    static func make() throws -> (ServiceFixture, SuggestionService) {
        let fx = try ServiceFixture()
        return (fx, SuggestionService(store: fx.store, activity: fx.activity, pause: fx.pause, disclosures: fx.disclosures))
    }

    @Test func sevenSeedQuestionsWithTheirPresets() {
        #expect(SeedQuestion.all.count == 7)
        #expect(Set(SeedQuestion.all.map(\.id)).count == 7)
        let projects = SeedQuestion.all.first { $0.id == "current_projects" }!
        #expect(projects.kind == .projectContext && projects.categoryKey == "project_context" && projects.sensitivity == .internal)
        let builtins = Set(MemoryCategory.builtins.map(\.key))
        #expect(SeedQuestion.all.allSatisfy { builtins.contains($0.categoryKey) })
    }

    @Test func anAnswerBecomesASuggestion() async throws {
        let (fx, s) = try Self.make()
        let question = SeedQuestion.all[2]
        let id = try await s.seed(question, answer: "  Swift 6, Swift Testing, small commits.  ", now: fx.now)
        let suggestion = try #require(try await s.suggestion(id: id))
        #expect(suggestion.origin == .seedQuestion && suggestion.status == .pending)
        #expect(suggestion.body == "Swift 6, Swift Testing, small commits.")
        #expect(suggestion.title == question.title && suggestion.kind == .instruction)
        #expect(suggestion.categoryKeys == ["software_development"] && suggestion.sensitivity == .low)
        let applied = try await s.apply(suggestionID: id, now: fx.now)
        #expect(try fx.store.memory(id: applied.memoryID)?.source == .seedQuestion)
        #expect(fx.activity.events.contains { $0.event == "seed_question" && $0.ids == [id] })
    }

    @Test func answersAreScannedAndChecked() async throws {
        let (fx, s) = try Self.make()
        await #expect(throws: VaultError.secretLikeContent([.openAIStyleKey])) {
            try await s.seed(SeedQuestion.all[0], answer: "use sk-" + String(repeating: "a", count: 30), now: fx.now)
        }
        await #expect(throws: VaultError.invalidInput(field: "body")) {
            try await s.seed(SeedQuestion.all[0], answer: "   ", now: fx.now)
        }
        #expect(try fx.vault.count("SELECT count(*) FROM suggestion") == 0)
    }

    @Test func importSourcesAndRestorableSuggestions() async throws {
        let (fx, s) = try Self.make()
        let imports = ImportService(store: fx.store, activity: fx.activity)
        let preview = try await imports.preview(ImportParser.claude("- Likes tea\n- Walks daily"), source: .claude)
        let result = try await imports.commit(preview, now: fx.now)
        #expect(try await s.importSources()[result.importRunID] == .claude)

        // Expired after 30 days; restorable for 7 more.
        _ = try await s.expire(now: fx.now.plus(days: 31))
        #expect(try await s.restorable(now: fx.now.plus(days: 31)).count == 2)
        #expect(try await s.restorable(now: fx.now.plus(days: 38)).isEmpty)
        try await s.restore(suggestionID: result.suggestionIDs[0], now: fx.now.plus(days: 32))
        #expect(try await s.pending().map(\.id) == [result.suggestionIDs[0]])
    }
}

extension InboxSupportTests {
    @Test func suggestionsByID() async throws {
        let (fx, s) = try Self.make()
        let a = try await s.seed(SeedQuestion.all[0], answer: "Pair with me", now: fx.now)
        let b = try await s.seed(SeedQuestion.all[1], answer: "Short answers", now: fx.now)
        try await s.reject(suggestionID: b, now: fx.now)
        let found = try await s.suggestions(ids: [a, b, UUID()])
        #expect(Set(found.map(\.id)) == [a, b])
        #expect(try await s.suggestions(ids: []).isEmpty)
    }
}
