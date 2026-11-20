import Foundation
import Testing
@testable import FunesCore

/// Activity's words for the facts rows (FR-L-02): titles, detail lines and results from counts only. The writers' own
/// rows are checked in their tests (`FactsExtractorTests`, `FactsBackfillTests`, `FactsStoreTests`, `AnswerFactsTests`).
struct FactsActivityWordsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func row(_ event: String, actor: Actor = .system, via: ActivityEvent.Via = .app, outcome: String? = nil,
             ids: [UUID] = [], counts: [String: Int] = [:], engine: String? = nil) -> ActivityEvent {
        ActivityEvent(time: t0, phase: .event, actor: actor, via: via, event: event, outcome: outcome, ids: ids, counts: counts,
                      engine: engine)
    }

    func words(_ e: ActivityEvent) throws -> FactsActivityWords { try #require(FactsActivityWords(e)) }

    @Test func otherEventsHaveNoFactsWords() {
        #expect(FactsActivityWords(row("search_answered", counts: ["read": 3])) == nil)
        #expect(FactsActivityWords(row("processing_job")) == nil)
    }

    // MARK: facts_learned

    @Test func learnedCountsTheMemoriesAndNamesTheModel() throws {
        let w = try words(row("facts_learned", ids: [UUID()],
                              counts: ["memories": 3, "calls": 2, "applied": 2, "code_only": 1, "failed": 0, "input_tokens": 900],
                              engine: "anthropic/claude-haiku-5-5"))
        #expect(w.title == "Learned facts from 3 memories")
        #expect(w.detail == "anthropic/claude-haiku-5-5 · 1 by rules only")
        #expect(w.result == "Done" && w.tone == .neutral)
    }

    @Test func learnedFromOneMemoryByRulesOnly() throws {
        let w = try words(row("facts_learned", counts: ["memories": 1, "calls": 0, "code_only": 1], engine: "code"))
        #expect(w.title == "Learned facts from 1 memory")
        #expect(w.detail == "Rules only")
    }

    @Test func learnedWithFailuresIsAWarning() throws {
        let w = try words(row("facts_learned", counts: ["memories": 4, "calls": 4, "applied": 2, "failed": 2],
                              engine: "openai/gpt-6-luna"))
        #expect(w.title == "Learned facts from 2 memories" && w.detail == "openai/gpt-6-luna")
        #expect(w.result == "2 failed" && w.tone == .warning)
        let none = try words(row("facts_learned", counts: ["memories": 1, "calls": 1, "failed": 1], engine: "openai/gpt-6-luna"))
        #expect(none.title == "Learned no facts" && none.detail == "openai/gpt-6-luna" && none.result == "1 failed")
    }

    /// The cap reached or the model unavailable: every memory by rules, so the model isn't named.
    @Test func learnedWithAModelThatReadNothingIsRulesOnly() throws {
        let w = try words(row("facts_learned", counts: ["memories": 3, "calls": 0, "code_only": 3], engine: "anthropic/claude-haiku-5-5"))
        #expect(w.title == "Learned facts from 3 memories" && w.detail == "Rules only" && w.result == "Done")
    }

    /// Learning stopped before the request, or the memory changed: nothing kept, read again later.
    @Test func learnedNothingYetIsReadLater() throws {
        let w = try words(row("facts_learned", counts: ["memories": 1, "calls": 1, "changed": 1], engine: "anthropic/claude-haiku-5-5"))
        #expect(w.title == "Learned no facts" && w.detail == "1 to read later")
        #expect(w.result == "Read later" && w.tone == .neutral)
    }

    /// Every memory skipped (deleted meanwhile): no claim of learning.
    @Test func learnedFromNoMemory() throws {
        let w = try words(row("facts_learned", counts: ["memories": 0, "calls": 0], engine: "code"))
        #expect(w.title == "Learned no facts" && w.detail.isEmpty && w.result == "Nothing to read")
    }

    /// A learned row's id is its run's: the words never treat it as a memory's (no title, no "(deleted memory)"), and
    /// Activity's title lookup skips these events.
    @Test func learnedDetailIsCountsOnlyWhateverTheIds() throws {
        let a = try words(row("facts_learned", ids: [UUID()], counts: ["memories": 2, "code_only": 2], engine: "code"))
        let b = try words(row("facts_learned", ids: [], counts: ["memories": 2, "code_only": 2], engine: "code"))
        #expect(a == b)
        #expect(FactsActivityWords.events == ["facts_learned", "facts_backfill", "facts_removed", "facts_corrected"])
    }

    // MARK: facts_backfill

    @Test func backfillStartSaysWhatItWillRead() throws {
        let w = try words(FactsBackfill.activity("started", time: t0, counts: ["memories": 365, "calls": 730]))
        #expect(w.title == "Started reading existing memories")
        #expect(w.detail == "365 memories · about 730 model calls")
        #expect(w.result == "Started" && w.tone == .neutral)
        // Every model on this Mac: the sheet may count no calls.
        let one = try words(FactsBackfill.activity("started", time: t0, counts: ["memories": 1, "calls": 0]))
        #expect(one.detail == "1 memory")
        // Nothing to send: the end row follows at once.
        let none = try words(FactsBackfill.activity("started", time: t0, counts: ["memories": 0, "calls": 0]))
        #expect(none.detail == "Nothing to read")
    }

    @Test func backfillEndSaysWhatItRead() throws {
        let w = try words(FactsBackfill.activity("finished", time: t0,
                                                 counts: ["memories": 365, "calls": 720, "code_only": 10, "failed": 0]))
        #expect(w.title == "Finished reading existing memories")
        #expect(w.detail == "365 memories · 720 cloud requests outside the daily count · 10 by rules only")
        #expect(w.result == "Finished" && w.tone == .good)
        let failed = try words(FactsBackfill.activity("finished", time: t0,
                                                      counts: ["memories": 2, "calls": 1, "code_only": 0, "failed": 1]))
        #expect(failed.detail == "2 memories · 1 cloud request outside the daily count")
        #expect(failed.result == "1 failed" && failed.tone == .warning)
        // Every model on this Mac: nothing counted, so no requests to tell.
        let local = try words(FactsBackfill.activity("finished", time: t0,
                                                     counts: ["memories": 3, "calls": 0, "code_only": 0, "failed": 0]))
        #expect(local.detail == "3 memories")
    }

    @Test func backfillWithAnotherOutcome() throws {
        let w = try words(row("facts_backfill", outcome: "paused_by_change"))
        #expect(w.title == "Read existing memories" && w.detail.isEmpty && w.result == "Paused By Change")
    }

    /// Started with nothing to send: the end row follows at once with zero counts.
    @Test func backfillEndWithNothingToRead() throws {
        let w = try words(FactsBackfill.activity("finished", time: t0, counts: ["memories": 0, "calls": 0, "code_only": 0, "failed": 0]))
        #expect(w.detail == "Nothing to read" && w.result == "Finished")
    }

    // MARK: facts_removed

    @Test func removedCountsNamesAndFacts() throws {
        let w = try words(row("facts_removed", actor: .user, counts: ["entities": 23, "facts": 41, "evidence": 120, "decisions": 7]))
        #expect(w.title == "Removed learned facts")
        #expect(w.detail == "23 names, 41 facts")
        #expect(w.result == "Removed")
        let one = try words(row("facts_removed", actor: .user, counts: ["entities": 1, "facts": 1]))
        #expect(one.detail == "1 name, 1 fact")
    }

    // MARK: facts_corrected

    @Test func correctionsFromTheMac() throws {
        let fact = try words(row("facts_corrected", actor: .user, counts: ["facts": 1]))
        #expect(fact.title == "Corrected a fact" && fact.detail == "1 fact" && fact.result == "Done")
        #expect(try words(row("facts_corrected", actor: .user, counts: ["entities": 2])).detail == "2 names")
        #expect(try words(row("facts_corrected", actor: .user, counts: ["entities": 1, "facts": 1])).detail == "1 name, 1 fact")
        #expect(try words(row("facts_corrected", actor: .user, counts: ["entities": 1, "facts": 0])).detail == "1 name")
        #expect(try words(row("facts_corrected", actor: .user, counts: ["orders": 1])).detail == "1 timeline order")
        #expect(try words(row("facts_corrected", actor: .user, counts: ["links": 3])).detail == "3 mentions")
    }

    /// `facts.reject` from a paired iPhone: actor `device:<id>` via companion (Activity's From names the device), the
    /// same words as the Mac's own correction.
    @Test func correctionFromADevice() throws {
        let phone = row("facts_corrected", actor: .device(UUID()), via: .companion, counts: ["links": 1])
        #expect(phone.actor.hasPrefix("device:"))
        let w = try words(phone)
        #expect(w.title == "Corrected a fact" && w.detail == "1 mention" && w.result == "Done")
        #expect(w == (try words(row("facts_corrected", actor: .user, counts: ["links": 1]))))
    }

    @Test func undoIsOneCorrectionTakenBack() throws {
        let w = try words(row("facts_corrected", actor: .user, counts: ["undone": 4]))
        #expect(w.title == "Undid a correction" && w.detail.isEmpty)
    }
}
