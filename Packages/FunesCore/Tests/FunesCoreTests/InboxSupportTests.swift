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

    /// Six: "What should Funes be careful not to share?" became the never-share step, which sets
    /// rules instead of saving a memory agents could read (UX review F4).
    @Test func sixSeedQuestionsWithTheirPresets() {
        #expect(SeedQuestion.all.count == 6)
        #expect(Set(SeedQuestion.all.map(\.id)).count == 6)
        #expect(!SeedQuestion.all.contains { $0.categoryKey == "privacy_preferences" })
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

/// PR #3 review 4304175704: an Inbox card follows background classification until the user edits
/// it, and Apply stores exactly what the card showed.
@Suite struct SuggestionDraftTests {
    @Test func untouchedDraftsFollowClassificationAndApplyWhatTheyShow() async throws {
        let vault = try TestVault()
        let activity = InMemoryActivityLog()
        let captures = CaptureService(store: vault.store, activity: activity)
        let suggestions = SuggestionService(store: vault.store, activity: activity, pause: FunesPause())
        let categories = try vault.store.categories()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = try await captures.capture("Book the dentist before the end of the month", now: now).suggestionID
        let shown = SuggestionDraft(try #require(try await suggestions.suggestion(id: id)), categories: categories)

        // Classification finishes while the card is on screen.
        try await captures.reclassify(suggestionID: id, record: ClassificationRecord(
            engine: "apple.foundation",
            proposal: CaptureProposal(title: "Dentist appointment", kind: .event, categoryKeys: ["health"],
                                      sensitivity: .sensitive, timeLimited: true),
            keptOnDevice: false))
        let current = try #require(try await suggestions.suggestion(id: id))
        #expect(current.title == "Dentist appointment" && current.sensitivity == .sensitive)

        // Untouched, the card refreshes to the new proposal.
        let refreshed = shown.refreshed(from: current, categories: categories)
        #expect(refreshed.title == "Dentist appointment" && refreshed.categoryKeys == ["health"] && refreshed.sensitivity == .sensitive)

        // Applying a card that still shows the old proposal stores exactly that, not the newer values.
        let result = try await suggestions.apply(suggestionID: id, edits: shown.edit, now: now)
        let memory = try #require(try vault.store.memory(id: result.memoryID))
        #expect(memory.title == shown.title && memory.sensitivity == shown.sensitivity && memory.categoryKeys == shown.categoryKeys)
    }

    @Test func editedDraftsKeepTheUsersValues() throws {
        let categories = MemoryCategory.builtins
        let base = Suggestion(id: UUID(), origin: .captureMac, action: .create, title: "Old", body: "Note", kind: .fact,
                              categoryKeys: ["personal_preferences"], sensitivity: .low, status: .pending,
                              createdAt: Date(), expiresAfter: Date())
        var draft = SuggestionDraft(base, categories: categories)
        #expect(!draft.touched)
        draft.title = "Mine"
        var newer = base
        newer.title = "Classified"
        newer.sensitivity = .internal
        let kept = draft.refreshed(from: newer, categories: categories)
        #expect(kept.title == "Mine" && kept.sensitivity == .low && kept.touched)
        // No categories means Personal preferences, at its default sensitivity, as Apply decides.
        var bare = base
        bare.categoryKeys = []
        bare.sensitivity = nil
        let fallback = SuggestionDraft(bare, categories: categories)
        #expect(fallback.categoryKeys == ["personal_preferences"] && fallback.sensitivity == .low)
    }
}
