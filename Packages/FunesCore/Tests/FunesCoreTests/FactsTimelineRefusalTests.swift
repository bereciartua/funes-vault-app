import Foundation
import GRDB
import Testing
@testable import FunesCore

/// The Gates step's fix round (memory processing §11.7): three kinds of wrong answer the first blind sets found on their
/// own labels, each now told rather than answered. Each test shows the answer without the rival evidence, then the
/// refusal with it.
@Suite struct FactsTimelineRefusalTests {
    var d: String { FX.dated }

    // (a) The user's notes say one job is current; an agent's note claims a move to another. Untrusted evidence never
    // triggers succession, so it can't end the trusted job; and it can't share the answer with it either.
    @Test func anUntrustedClaimedChangeNeverSharesACurrentAnswer() throws {
        let trusted: [FactRowConvertible] = [fact(d, "Alder Systems", "2018", status: .current).at("2024-12-31")]
        let base = stateWith(trusted)
        #expect(base.ask("Where do I work now?")?.entity == base.ent("Alder Systems"))
        #expect(base.ask("Where did I work in 2024?")?.entity == base.ent("Alder Systems"))
        let s = stateWith(trusted + [fact(d, "Alder Systems", nil, "2023", status: .former).untrusted(at: "2025-01-01"),
                                     fact(d, "Vela Metrics", "2023", status: .current).untrusted(at: "2025-01-01")])
        #expect(s.ask("Where do I work now?")?.isAmbiguous == true)
        #expect(s.ask("Where did I work in 2024?")?.isAmbiguous == true)
        #expect(s.ask("What was my previous job?")?.isAmbiguous == true)
        // Only untrusted episodes: answered as before, on an inferred basis.
        let only = stateWith([fact(d, "Vela Metrics", "2023", status: .current).untrusted(at: "2024-05-01")])
        #expect(only.ask("Where do I work now?").map { ($0.entity, $0.basis) }! == (only.ent("Vela Metrics"), .inferred))
    }

    // (b) A day job and self-employment at the same time: "my employer" may mean one of them, so the answer is told.
    @Test func concurrentKindsAreNeverOneAnswer() throws {
        let job = fact(d, "Solano Datos", "2018", status: .current, slot: FX.emp).at("2023-01-01")
        let base = stateWith([job])
        #expect(base.ask("Who was my employer in June 2022?")?.entity == base.ent("Solano Datos"))
        let s = stateWith([job, fact(d, "Tinta Norte", "2020", status: .current, slot: FX.own).at("2023-01-01")])
        #expect(s.ask("Who was my employer in June 2022?")?.isAmbiguous == true)
        #expect(s.ask("Where do I work now?")?.isAmbiguous == true)
        // Two jobs of the same kind at once are still both told, as before.
        let two = stateWith([job, fact(d, "Faro Labs", "2020", status: .current, slot: FX.emp).at("2023-01-01")])
        #expect(Set(two.ask("Where did I work in June 2022?")?.entities ?? []) == [two.ent("Solano Datos"), two.ent("Faro Labs")])
    }

    // (c) One organization under two names that stayed two entities (a merge suggestion, never a merge, §11.4): any
    // answer resting on either is told.
    @Test func anEntityThatMayBeAnotherUnderAnAliasIsTold() throws {
        var also = fact(d, "NWT", status: .current)
        also.alsoCalled = "Northwind Traders"
        let rows: [FactRowConvertible] = [fact(d, "Northwind Traders", "2014", "2016", status: .former).at("2017-01-01"),
                                          fact(d, "Kelp Analytics", "2017", "2018", status: .former).at("2019-01-01"),
                                          fact(d, "NWT", "2019", status: .current).at("2020-01-01")]
        let base = stateWith(rows)
        #expect(base.ask("Where did I work in 2015?")?.entity == base.ent("Northwind Traders"))
        #expect(base.ask("Where did I work before NWT?")?.entity == base.ent("Kelp Analytics"))
        var s = stateWith(rows + [also.at("2021-01-01")])
        #expect(s.entityMatches(d, "NWT").count == 1 && s.entityMatches(d, "Northwind Traders").count == 1)   // still two
        #expect(s.ask("Where did I work in 2015?")?.isAmbiguous == true)
        #expect(s.ask("Where do I work now?")?.isAmbiguous == true)
        #expect(s.ask("Where did I work before NWT?")?.isAmbiguous == true)
        #expect(s.ask("Where did I work after Kelp Analytics?")?.isAmbiguous == true)
        #expect(s.ask("Where did I work after Northwind Traders?")?.isAmbiguous == true)
        // The user's "not the same" settles the pair.
        s.notSame.insert([s.ent("NWT"), s.ent("Northwind Traders")])
        #expect(s.ask("Where did I work in 2015?")?.entity == s.ent("Northwind Traders"))
        #expect(s.ask("Where did I work before NWT?")?.entity == s.ent("Kelp Analytics"))
        // Names that match loosely by the kind's rule ("Fenwick Lab" in "Fenwick Laboratories") are told too.
        let loose = stateWith([fact(d, "Fenwick Lab", "2014", "2016", status: .former).at("2017-01-01"),
                               fact(d, "Fenwick Laboratories", "2019", status: .current).at("2020-01-01")])
        #expect(loose.ask("Where did I work in 2015?")?.isAmbiguous == true)
    }

    // When only the anchor (or another candidate) may be split, the answer stands if reading the pair as one entity gives
    // the same one; an answer naming one of the pair is still told.
    @Test func aSplitAnchorStillAnswersWhenTheMergedReadingAgrees() throws {
        let s = stateWith([fact(d, "Pampa Digital", "2014", "2016", status: .former).at("2017-01-01"),
                           fact(d, "Bracken Systems", "2017", "2018", status: .former).at("2019-01-01"),
                           fact(d, "Bracken", nil, "2018", status: .former).at("2019-02-01"),
                           fact(d, "Initech", "2019", status: .current).at("2020-01-01")])
        #expect(s.maybeSplit(d) == Set([s.ent("Bracken Systems"), s.ent("Bracken")]))
        #expect(s.ask("Where did I work before Bracken Systems?")?.entity == s.ent("Pampa Digital"))
        #expect(s.ask("Where did I work after Pampa Digital?")?.isAmbiguous == true)       // names half of the pair
        #expect(s.ask("Where did I work before Initech?")?.isAmbiguous == true)
        // Merged, the anchor has two episodes and no cue: the readings disagree, so it's told.
        let twice = stateWith([fact(d, "Pampa Digital", "2014", "2016", status: .former).at("2017-01-01"),
                               fact(d, "Bracken Systems", "2017", "2018", status: .former).at("2019-01-01"),
                               fact(d, "Kelp", "2019", "2020", status: .former).at("2021-01-01"),
                               fact(d, "Bracken", "2021", status: .current).at("2022-01-01")])
        #expect(twice.ask("Where did I work before Bracken Systems?")?.isAmbiguous == true)
    }

    // The other name a statement gives survives the store, so the refusal holds after a reload.
    @Test func anAlsoCalledNameIsKeptInTheStore() throws {
        let v = try TestVault()
        let reg = FactsRegistry.bundled
        let group = reg.predicate(d)!.callGroup
        let texts = ["I worked at Northwind Traders from 2014 to 2016.", "I joined NWT in 2019.",
                     "NWT, also called Northwind Traders, is where I work."]
        let facts: [ExtractedFact] = [fact(d, "Northwind Traders", "2014", "2016", status: .former, quote: "Northwind Traders"),
                                      fact(d, "NWT", "2019", status: .current, quote: "NWT"),
                                      { var f = fact(d, "NWT", status: .current, quote: "NWT"); f.alsoCalled = "Northwind Traders"; return f }()]
        for (i, (t, f)) in zip(texts, facts).enumerated() {
            let now = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400)
            let mem = try v.memory("Work note \(i)", t, now: now)
            try v.store.writer.write { db in
                var x = FactsExtraction()
                x.facts = [f]
                try FactStore.apply(db, memoryID: mem.id.db, version: mem.version, extraction: x, callGroup: group, registry: reg,
                                    userAliases: [], now: now)
            }
        }
        let g = try v.store.writer.read { db in try FactStore.load(db, registry: reg, userAliases: []).graph }
        #expect(g.facts.flatMap(\.assertions).compactMap(\.alsoCalled) == ["Northwind Traders"])
        #expect(g.maybeSplit(d) == Set([g.ent("NWT"), g.ent("Northwind Traders")]))
    }
    // Review (GPT-6-Astra): the merged reading keeps the user's rejected orders, pointed at the stand-in.
    @Test func theMergedReadingKeepsARejectedOrder() throws {
        var s = stateWith([fact(d, "Pampa Digital", "2014", "2016", status: .former).at("2017-01-01"),
                           fact(d, "Bracken Systems", "2017", "2018", status: .former).at("2019-01-01"),
                           fact(d, "Bracken", "2017", "2018", status: .former).at("2019-02-01")])
        #expect(s.ask("Where did I work before Bracken Systems?")?.entity == s.ent("Pampa Digital"))
        s.rejectedEdges.append(FactsGraph.EdgeRejection(from: s.ent("Pampa Digital"), to: s.ent("Bracken")))
        #expect(s.ask("Where did I work before Bracken Systems?")?.isAmbiguous == true)
    }

    // Review (GPT-6-Astra): the same entity on another basis (a gap the merged reading tells) is a different answer.
    @Test func theMergedReadingMustAgreeOnTheBasis() throws {
        let s = stateWith([fact(d, "Pampa Digital", "2018", "2019-12-01", status: .former).at("2020-01-01"),
                           fact(d, "Bracken Systems", "2020", "2021", status: .former).at("2022-01-01"),
                           fact(d, "Bracken", "October 2020", "2021", status: .former).at("2022-02-01")])
        #expect(s.ask("Where did I work before Bracken Systems?")?.isAmbiguous == true)
    }

    // Review (Fable 5.2): an agent's note that slots a job between two of the user's own changes "before" and "previous".
    @Test func anUntrustedJobNeverReordersTheUsersOwn() throws {
        let rows: [FactRowConvertible] = [fact(d, "Pampa Digital", "2014", "2016", status: .former).at("2017-01-01"),
                                          fact(d, "Alder Systems", "2018", status: .current).at("2019-01-01")]
        let base = stateWith(rows)
        #expect(base.ask("Where did I work before Alder Systems?")?.entity == base.ent("Pampa Digital"))
        let s = stateWith(rows + [fact(d, "Vela Metrics", "July 2017", "December 2017", status: .former).untrusted(at: "2019-02-01")])
        #expect(s.ask("Where did I work before Alder Systems?")?.isAmbiguous == true)
        #expect(s.ask("What was my previous job?")?.isAmbiguous == true)
        // Only an agent's notes about the anchor's neighbours: still answered, inferred.
        let only = stateWith([fact(d, "Alder Systems", "2018", status: .current).at("2019-01-01"),
                              fact(d, "Vela Metrics", "July 2017", "December 2017", status: .former).untrusted(at: "2019-02-01")])
        #expect(only.ask("Where did I work before Alder Systems?")?.entity == only.ent("Vela Metrics"))
    }

    // Review (Fable 5.2): loose names match by word starts, never inside a word.
    @Test func looseNamesMatchByWordStarts() throws {
        let s = stateWith([fact(d, "Ola", "2014", "2016", status: .former).at("2017-01-01"),
                           fact(d, "Solano Datos", "2017", status: .current).at("2018-01-01")])
        #expect(s.maybeSplit(d).isEmpty)
        #expect(s.ask("Where did I work before Solano Datos?")?.entity == s.ent("Ola"))
    }
}

/// The fix round's lexicon: a compound isn't a role, and a multi-word class is found inside a modified label.
@Suite struct FactsLexiconFixRoundTests {
    @Test func aCompoundIsntARole() {
        let g = FactsGraph(registry: .bundled)
        #expect(g.rolePhrases("My parent company sent a memo.").isEmpty)
        #expect(g.rolePhrases("My sister company in Lyon called.").isEmpty)
        #expect(g.rolePhrases("My parent called.").map(\.word) == ["parent"])
        // After a plural role word the head is a verb (review, GPT-6-Astra follow-up).
        #expect(g.rolePhrases("My parents group the photos by year.").map(\.word) == ["parents"])
        #expect(g.rolePhrases("My parents process the paperwork.").map(\.word) == ["parents"])
        #expect(g.rolePhrases("My supervisor approved it.").map(\.word) == ["supervisor"])
        #expect(g.rolePhrases("My former client contact signed off.").first?.cls == "client contact")
    }

    @Test func aMultiWordClassIsFoundInsideALabel() {
        let g = FactsGraph(registry: .bundled)
        let other = FactsRegistry.bundled.lexicon["client contact"]!.predicate
        #expect(g.labelClass(other, "main client contact") == "client contact")
        #expect(g.labelClass(other, "client contact") == "client contact")
    }
}
