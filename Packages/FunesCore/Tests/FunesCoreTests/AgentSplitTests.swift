import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 6a.4: agent input and the policy (memory processing §5.6, access policy §5.3). No
/// out-of-scope piece is saved for an agent, nothing auto-applied for an agent links to a memory
/// it can't read, splitting never lowers sensitivity, and the agent's answer is unchanged.
@Suite struct AgentSplitTests {
    typealias P = ScriptedSplitter
    typealias Env = NewMemoryPipelineTests.Env

    static let dump = "The user is vegetarian and has a mild peanut allergy. They write Swift. They prefer short answers."

    static func dumpPieces(_ n: Int, _ prompt: String) -> [[String: Any]] {
        [P.piece("I'm vegetarian.", quote: "The user is vegetarian"),
         P.piece("I have a mild peanut allergy.", quote: "has a mild peanut allergy", categories: ["health"], sensitivity: "sensitive"),
         P.piece("I write Swift.", quote: "They write Swift", categories: ["software_development"]),
         P.piece("I prefer short answers.", quote: "They prefer short answers", categories: ["communication_style"])]
    }

    /// The fixture's agent may suggest in Personal preferences, Software development and
    /// Communication style, up to Internal.
    static func agent(_ fx: ServiceFixture, write: Bool = false) throws {
        try fx.setAccess {
            $0.operations = write ? [.read, .suggest, .write] : [.read, .suggest]
            $0.maxSensitivity = .internal
            $0.allowedCategoryKeys = ["personal_preferences", "software_development", "communication_style"]
            $0.deniedCategoryKeys = []
            $0.askBeforeSaving = !write
        }
    }

    @Test func piecesOutsideTheAgentsScopeAreFlaggedAndTheAnswerIsUnchanged() async throws {
        let fx = try ServiceFixture()
        let env = Env(v: fx.vault)
        try Self.agent(fx)
        let outcome = try await env.suggestions.suggest(agentID: fx.agentID, SuggestInput(
            title: "About the user", body: Self.dump, categories: ["personal_preferences"], sensitivity: .low), now: t0)
        #expect(outcome.status == .queued)
        let id = try #require(outcome.suggestionID)
        let provider = P(extract: Self.dumpPieces)
        _ = try await env.run(splittingProcessor(fx.vault, provider, log: env.log, cloudLimit: .upTo(.sensitive)))

        // The suggestion id the agent got is the group's.
        let group = try #require(try await env.suggestions.group(id: id))
        #expect(group.original.status == .split && group.pieces.count == 4)
        #expect(group.pieces.map(\.outsideScope) == [false, true, false, false])
        #expect(group.pieces.allSatisfy { $0.agentID == fx.agentID && $0.origin == .agent && $0.callerMetadata == nil })
        // The about-the-user prompt, and the agent's declared level as a floor.
        #expect(provider.extractions.first?.instructions.contains("written by an AI assistant") == true)
        // The body, with the agent's title in the note tag (Spike F); never its evidence or metadata.
        #expect(provider.extractions.first?.prompt.contains("<note title=\"About the user\" written=\"") == true)
        let applied = try await env.suggestions.applyAll(groupID: id, now: t0)
        #expect(applied.skipped == [group.pieces[1].id] && applied.applied.count == 3)
        #expect(try await env.suggestions.isAwaitingReview(id: id))  // the flagged piece is still the user's to decide
    }

    @Test func directWritesAreSavedThenSplitAndNeverLoseSensitivity() async throws {
        let fx = try ServiceFixture()
        let env = Env(v: fx.vault)
        try Self.agent(fx, write: true)
        let outcome = try await env.suggestions.suggest(agentID: fx.agentID, SuggestInput(
            title: "About the user", body: Self.dump, categories: ["personal_preferences"], sensitivity: .low), now: t0)
        #expect(outcome.status == .saved)
        let memoryID = try #require(outcome.memoryID)
        _ = try await env.run(splittingProcessor(fx.vault, P(extract: Self.dumpPieces), log: env.log, cloudLimit: .upTo(.sensitive)))

        // More sensitive than the agent declared: raised at once.
        let memory = try #require(try fx.store.memory(id: memoryID))
        #expect(memory.sensitivity == .sensitive && memory.status == .active)
        #expect(env.log.events.contains { $0.event == "sensitivity_raised" && $0.ids == [memoryID] })
        // A Split this memory suggestion, since auto-apply for New memories ships disabled.
        let split = try #require(try await env.suggestions.pending().first { $0.action == .split })
        #expect(split.targetMemoryID == memoryID && split.targetMemoryVersion == memory.version && split.agentID == fx.agentID)
        let group = try #require(try await env.suggestions.group(id: split.id))
        #expect(group.pieces.count == 4 && group.sourceText == nil)
        #expect(group.pieces.allSatisfy { $0.sensitivity! >= .sensitive })  // never below the original
        #expect(group.pieces.map(\.outsideScope) == [true, true, true, true])  // the raised level is above Internal

        // The user applies it: new memories, none below the original, the original archived.
        let result = try await env.suggestions.apply(suggestionID: split.id, now: t0)
        #expect(result.memoryIDs.count == 5)
        let pieces = try fx.store.memories(ids: Array(result.memoryIDs.prefix(4)))
        #expect(pieces.allSatisfy { $0.sensitivity >= .sensitive && $0.status == .active })
        #expect(try fx.store.memory(id: memoryID)?.status == .archived)
    }

    @Test func directWritesReplaceTheOriginalOnlyAtAQualifiedLevel() async throws {
        let fx = try ServiceFixture()
        let env = Env(v: fx.vault)
        try Self.agent(fx, write: true)
        // A memory the agent can't read, which a piece would otherwise link to.
        try fx.vault.memory("Allergy app", "I build apps in Swift: an antihistamines tracker", categories: ["health"], sensitivity: .sensitive)
        try fx.vault.memory("Swift", "I build apps in Swift with strict concurrency", categories: ["software_development"])
        let text = "The user builds apps in Swift. They prefer short answers."
        let pieces: @Sendable (Int, String) -> [[String: Any]] = { _, _ in
            [P.piece("I build apps in Swift.", quote: "The user builds apps in Swift", categories: ["software_development"]),
             P.piece("I prefer short answers.", quote: "They prefer short answers", categories: ["communication_style"])]
        }
        let outcome = try await env.suggestions.suggest(agentID: fx.agentID, SuggestInput(
            title: "Profile", body: text, categories: ["software_development"], sensitivity: .low), now: t0)
        let memoryID = try #require(outcome.memoryID)
        let provider = P(extract: pieces)
        let qualified = NewMemoryAutoApply(level: .exceptConflicts, qualified: ["claude-test": .exceptConflicts])
        _ = try await env.run(splittingProcessor(fx.vault, provider, log: env.log, autoApply: qualified))

        // Pieces within the agent's write scope replaced the original, with an undo entry.
        #expect(try fx.store.memory(id: memoryID)?.status == .archived)
        let created = try fx.vault.count("SELECT COUNT(*) FROM memory WHERE source = 'agent_write' AND status = 'active'")
        #expect(created == 2)
        #expect(try fx.vault.count("SELECT COUNT(*) FROM undo_entry WHERE action = 'split'") == 1)
        #expect(try fx.vault.count("SELECT COUNT(*) FROM provenance WHERE event = 'split_into' AND memory_id = ?", [memoryID.db]) == 2)
        #expect(try await env.suggestions.pending().isEmpty)
        // Linking only considered memories the agent can read.
        for request in provider.decisions { #expect(!request.prompt.contains("antihistamines")) }
        #expect(provider.decisions.contains { $0.prompt.contains("strict concurrency") })
    }

    @Test func aCorrectionOfASplitMemoryGoesToAPieceTheAgentCanRead() async throws {
        let fx = try ServiceFixture()
        let env = Env(v: fx.vault)
        try Self.agent(fx)
        let original = try fx.vault.memory("Profile", "Writes Swift; allergic to peanuts")
        let swift = try fx.vault.memory("Swift", "I write Swift", categories: ["software_development"])
        let health = try fx.vault.memory("Allergy", "Allergic to peanuts", categories: ["health"], sensitivity: .sensitive)
        let answers = try fx.vault.memory("Answers", "Short answers", categories: ["communication_style"])
        try await fx.store.writer.write { db in
            for piece in [swift, health, answers] {
                try MemoryStore.appendProvenance(db, memoryID: original.id, event: .splitInto, actor: .user, at: t0, relatedMemoryID: piece.id)
            }
            _ = try MemoryStore.setStatus(db, id: original.id, to: .archived, actor: .user, now: t0)
        }
        let outcome = try await env.suggestions.suggest(agentID: fx.agentID, SuggestInput(
            title: "Swift version", body: "The user now writes Swift 6", targetMemoryID: original.id), now: t0)
        #expect(outcome.status == .queued)
        let s = try #require(try await env.suggestions.suggestion(id: outcome.suggestionID!))
        #expect(s.targetMemoryID == swift.id && s.action == .update)

        // No piece it can read: not_found, as for any memory it can't see.
        try fx.setAccess { $0.allowedCategoryKeys = ["legal"] }
        let refused = try await env.suggestions.suggest(agentID: fx.agentID, SuggestInput(
            title: "Allergy", body: "Allergic to peanuts and cashews", categories: ["legal"], targetMemoryID: original.id), now: t0)
        #expect(refused.reason == .notFound)
    }

    @Test func agentInputIsNeverAutoApplied() async throws {
        let fx = try ServiceFixture()
        let env = Env(v: fx.vault)
        try Self.agent(fx)
        let outcome = try await env.suggestions.suggest(agentID: fx.agentID, SuggestInput(
            title: "Prefs", body: "The user writes Swift. They prefer short answers."), now: t0)
        let pieces: @Sendable (Int, String) -> [[String: Any]] = { _, _ in
            [P.piece("I write Swift.", quote: "The user writes Swift", categories: ["software_development"]),
             P.piece("I prefer short answers.", quote: "They prefer short answers", categories: ["communication_style"])]
        }
        let qualified = NewMemoryAutoApply(level: .exceptConflicts, qualified: ["claude-test": .exceptConflicts])
        _ = try await env.run(splittingProcessor(fx.vault, P(extract: pieces), log: env.log, autoApply: qualified))
        #expect(try await env.suggestions.group(id: outcome.suggestionID!)?.pending.count == 2)
        #expect(try fx.vault.count("SELECT COUNT(*) FROM undo_entry") == 0)
    }
}
