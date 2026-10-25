import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 6a.3: a split input in the Inbox: Keep as one, Apply all, expiry as one, and the source
/// text dropped once every piece is decided (memory processing §5.2, FR-I-05).
@Suite struct SuggestionGroupTests {
    typealias Env = NewMemoryPipelineTests.Env

    static func split(_ env: Env, _ text: String = NewMemoryPipelineTests.threeClaims, at now: Date = t0) async throws -> SuggestionGroup {
        let capture = try await env.captures.capture(text, now: now)
        _ = try await env.run(splittingProcessor(env.v, ScriptedSplitter(extract: NewMemoryPipelineTests.threePieces), log: env.log))
        return try #require(try await env.suggestions.group(id: capture.suggestionID))
    }

    @Test func keepAsOneRestoresTheOriginalWhileNothingIsDecided() async throws {
        let env = try Env()
        let group = try await Self.split(env)
        try await env.suggestions.keepAsOne(groupID: group.id, now: t0)
        #expect(try await env.suggestions.group(id: group.id) == nil)
        #expect(try await env.suggestions.pending().map(\.id) == [group.id])
        #expect(try env.v.count("SELECT COUNT(*) FROM suggestion_group") == 0)

        // Once a piece is decided, it's too late.
        let second = try await Self.split(env, "I'm vegetarian and I run on Tuesdays. My coffee order is now a cortado!")
        try await env.suggestions.reject(suggestionID: second.pieces[0].id, now: t0)
        #expect(try await env.suggestions.group(id: second.id)?.canKeepAsOne == false)
        await #expect(throws: VaultError.invalidState) { try await env.suggestions.keepAsOne(groupID: second.id, now: t0) }
    }

    @Test func applyAllAppliesEachRowAndSkipsFlaggedOnes() async throws {
        let env = try Env()
        let group = try await Self.split(env)
        try await env.v.store.writer.write { db in
            try db.execute(sql: "UPDATE suggestion SET outside_scope = 1 WHERE id = ?", arguments: [group.pieces[1].id.db])
        }
        let result = try await env.suggestions.applyAll(groupID: group.id, now: t0)
        #expect(Set(result.applied.keys) == [group.pieces[0].id, group.pieces[2].id])
        #expect(result.skipped == [group.pieces[1].id] && result.failed.isEmpty)
        #expect(try await env.suggestions.pending().map(\.id) == [group.pieces[1].id])
        #expect(try env.v.count("SELECT COUNT(*) FROM memory WHERE status = 'active'") == 2)
    }

    @Test func aGroupExpiresAndComesBackAsOne() async throws {
        let env = try Env()
        let group = try await Self.split(env)
        let later = t0 + SuggestionService.lifetime + 1
        #expect(try await env.suggestions.expire(now: later).expired == 3)
        try await env.suggestions.restore(suggestionID: group.pieces[1].id, now: later)
        let restored = try #require(try await env.suggestions.group(id: group.id))
        #expect(restored.pieces.allSatisfy { $0.status == .pending && $0.expiresAfter == later + SuggestionService.lifetime })
        #expect(restored.original.status == .split)  // the original stays replaced
    }

    @Test func theSourceTextIsDroppedOnceEveryPieceIsDecided() async throws {
        let env = try Env()
        let group = try await Self.split(env)
        #expect(try await env.suggestions.dropDecidedGroupText() == 0)
        _ = try await env.suggestions.applyAll(groupID: group.id, now: t0)
        #expect(try await env.suggestions.dropDecidedGroupText() == 1)
        let after = try #require(try await env.suggestions.group(id: group.id))
        #expect(after.sourceText == nil && after.original.body.isEmpty && after.original.title.isEmpty)
        #expect(try await env.suggestions.dropDecidedGroupText() == 0)
        #expect(try await env.suggestions.isAwaitingReview(id: group.id) == false)
    }

    @Test func purgingAMemoryDropsItsGroupsText() async throws {
        let env = try Env()
        let group = try await Self.split(env)
        let applied = try await env.suggestions.apply(suggestionID: group.pieces[0].id, now: t0)
        try await env.v.store.writer.write { db in
            _ = try MemoryStore.setStatus(db, id: applied.memoryID, to: .deleted, actor: .user, now: t0)
            try MemoryStore.purge(db, id: applied.memoryID)
        }
        let after = try #require(try await env.suggestions.group(id: group.id))
        #expect(after.sourceText == nil && after.original.body.isEmpty)
        #expect(after.pieces[0].body.isEmpty && after.pieces[0].evidence == nil)
        #expect(after.pieces[1].body == group.pieces[1].body)  // the others keep theirs until decided
    }

    @Test func rejectingASplitThisMemorySuggestionRejectsItsPieces() async throws {
        let env = try Env()
        let group = try await Self.split(env)
        // A pending original with pieces: rejecting it rejects them.
        try await env.v.store.writer.write { db in
            try db.execute(sql: "UPDATE suggestion SET status = 'pending' WHERE id = ?", arguments: [group.id.db])
        }
        try await env.suggestions.reject(suggestionID: group.id, now: t0)
        #expect(try env.v.count("SELECT COUNT(*) FROM suggestion WHERE status = 'rejected'") == 4)
    }
}
