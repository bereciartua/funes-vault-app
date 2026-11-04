import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 6a.5: auto-apply for New memories (memory processing §5.7). It ships disabled: no engine
/// reached 95% on Spike E's fixtures. The levels are built behind a per-engine qualification and
/// tested with one injected.
@Suite struct NewMemoryAutoApplyTests {
    typealias P = ScriptedSplitter
    typealias Env = NewMemoryPipelineTests.Env

    static let text = "I'm vegetarian. I run on Tuesdays. My coffee order is now a cortado. I like jazz."

    /// Piece 0 new, 1 a duplicate, 2 an update, 3 flagged by the support check, 4 not atomic.
    static func provider(_ env: Env) throws -> P {
        try env.v.memory("Running", "I run on Tuesdays", now: t0.plus(days: -10))
        try env.v.memory("Coffee order", "Oat milk flat white", now: t0.plus(days: -10))
        return P(extract: { _, _ in
            [P.piece("I'm vegetarian.", quote: "I'm vegetarian"),
             P.piece("I run on Tuesdays.", quote: "I run on Tuesdays"),
             P.piece("My coffee order is a cortado.", quote: "My coffee order is now a cortado", intent: "correction"),
             P.piece("I like jazz and blues.", quote: "I like jazz"),
             P.piece("I like jazz, I'm vegetarian.", quote: "I like jazz", atomic: false)]
        }, decide: { _, memories, _ in
            if let running = memories.first(where: { $0.1.hasPrefix("Running") })?.0 { return ["action": "duplicate", "target": running] }
            if let coffee = memories.first(where: { $0.1.hasPrefix("Coffee order") })?.0 {
                return ["action": "update", "target": coffee, "body": "Cortado"]
            }
            return nil
        })
    }

    static func qualified(_ level: AutoApplyLevel) -> NewMemoryAutoApply {
        NewMemoryAutoApply(level: level, qualified: ["claude-test": level])
    }

    @Test func noEngineIsQualifiedSoNothingIsApplied() async throws {
        #expect(NewMemoryAutoApply.measured.isEmpty && NewMemoryAutoApply.highestAvailable == .off)
        #expect(NewMemoryAutoApply(level: .exceptConflicts).effective(engine: "anthropic/claude-opus-5-5") == .off)
        let env = try Env()
        let provider = try Self.provider(env)
        _ = try await env.captures.capture(Self.text, now: t0)
        _ = try await env.run(splittingProcessor(env.v, provider, autoApply: NewMemoryAutoApply(level: .exceptConflicts)))
        #expect(try await env.suggestions.pending().count == 5)
        #expect(try env.v.count("SELECT COUNT(*) FROM undo_entry") == 0)
    }

    @Test func duplicatesOnlySettlesDuplicates() async throws {
        let env = try Env()
        let provider = try Self.provider(env)
        _ = try await env.captures.capture(Self.text, now: t0)
        _ = try await env.run(splittingProcessor(env.v, provider, log: env.log, autoApply: Self.qualified(.duplicatesOnly)))
        let pending = try await env.suggestions.pending()
        #expect(pending.count == 4 && !pending.contains { $0.action == .duplicate })
        #expect(try env.v.count("SELECT COUNT(*) FROM undo_entry WHERE action = 'duplicate'") == 1)
        #expect(try env.v.count("SELECT COUNT(*) FROM memory") == 2)  // a duplicate changes nothing
        #expect(env.log.events.filter { $0.event == "auto_applied" }.count == 1)
    }

    @Test func everythingExceptConflictsAppliesOnlyCertainPieces() async throws {
        let env = try Env()
        let provider = try Self.provider(env)
        _ = try await env.captures.capture(Self.text, now: t0)
        _ = try await env.run(splittingProcessor(env.v, provider, autoApply: Self.qualified(.exceptConflicts)))
        // Applied: the new piece and the duplicate. Kept for review: the update (a capture may be
        // shared text), the flagged piece and the one that isn't atomic.
        let pending = try await env.suggestions.pending()
        #expect(pending.map(\.action).sorted { $0.rawValue < $1.rawValue } == [.create, .create, .update])
        let saved = try #require(try env.v.store.memories(MemoryFilter(), now: t0).first { $0.title == "I'm vegetarian." })
        #expect(try env.v.store.trust(memoryID: saved.id) == .untrusted)
        #expect(try env.v.store.provenance(memoryID: saved.id).contains { $0.event == .autoApplied && $0.engine == "anthropic/claude-test" })
        // Undo puts it in Recently Deleted.
        let undo = UndoLog(store: env.v.store, activity: env.log)
        let entry = try #require(try await undo.entries(now: t0).first { $0.memoryIDs == [saved.id] })
        _ = try await undo.undo(entryID: entry.id, now: t0)
        #expect(try env.v.store.memory(id: saved.id)?.status == .deleted)
    }

    @Test func typedTextMayUpdate() async throws {
        let env = try Env()
        let provider = try Self.provider(env)
        _ = try await env.suggestions.seed(SeedQuestion.all[0], answer: Self.text, now: t0)
        _ = try await env.run(splittingProcessor(env.v, provider, autoApply: Self.qualified(.exceptConflicts)))
        let coffee = try #require(try env.v.store.memories(MemoryFilter(), now: t0).first { $0.title == "Coffee order" })
        #expect(coffee.body == "Cortado")
        #expect(try await env.suggestions.pending().count == 2)
    }

    @Test func theGate() {
        func piece(_ action: LinkAction, atomic: Bool = true, unsupported: [String] = [], sensitivity: Sensitivity = .low) -> SplitPiece {
            SplitPiece(piece: ExtractedPiece(title: "T", body: "B", kind: .fact, categoryKeys: ["personal_preferences"],
                                             sensitivity: sensitivity, timeLimited: false, intent: .assertion, evidence: ["B"],
                                             atomic: atomic, unsupportedWords: unsupported, chunk: 0),
                       decision: LinkDecision(action: action), related: [])
        }
        let gate = NewMemoryAutoApply.applies
        #expect(!gate(piece(.duplicate), .off, true, .low))
        #expect(gate(piece(.duplicate), .duplicatesOnly, false, .low) && !gate(piece(.create), .duplicatesOnly, true, .low))
        #expect(gate(piece(.create), .exceptConflicts, false, .low))
        #expect(!gate(piece(.update), .exceptConflicts, false, .low) && gate(piece(.update), .exceptConflicts, true, .low))
        #expect(!gate(piece(.retract), .exceptConflicts, false, .low) && gate(piece(.retract), .exceptConflicts, true, .low))
        #expect(!gate(piece(.create, atomic: false), .exceptConflicts, true, .low))
        #expect(!gate(piece(.create, unsupported: ["best"]), .exceptConflicts, true, .low))
        // Possibly sensitive above what the user said: reviewed.
        #expect(!gate(piece(.create, sensitivity: .sensitive), .exceptConflicts, true, .low))
        #expect(gate(piece(.create, sensitivity: .sensitive), .exceptConflicts, true, .sensitive))
    }
}
