import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 1 (Fable 5.2): every counterexample, as a test.
@Suite struct ReviewRound1TimeModelTests {
    let d = FX.dated

    // R1: an untrusted undated "no longer" gives a bound end with endTrusted = true → `ordered`.
    @Test func r1_untrustedBoundNeverOrdersAtFullBasis() {
        let s = stateWith([fact(d, "Acme", "2015", status: .former).untrusted(at: "2018-12-15"),
                           fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
        let got = s.beforeName("Initech")
        #expect(got.0 == nil || got.1 == .inferred)
    }

    // R2: "current" from an episode with only untrusted evidence is answered at `ordered`.
    @Test func r2_untrustedOnlyCurrentIsNotOrdered() {
        let s = stateWith([fact(d, "Acme", "2015", status: .current).untrusted(at: "2016-01-01")])
        let got = s.answer(TimelineIntent(predicate: d, op: .current, anchor: nil))
        #expect(got.basis != .ordered)
    }

    // R3: an untrusted end splits a trusted fact into two episodes, which un-conflicts its start and lets succession fire.
    @Test func r3_untrustedEndNeverSplitsATrustedEpisodeOrTriggersSuccession() {
        let trusted: [FactRowConvertible] = [
            fact(d, "Acme", "2010", status: .current, slot: FX.emp).at("2011-01-01"),
            fact(d, "Acme", "2016", status: .current, slot: FX.emp).at("2016-06-01"),
            fact(d, "Initech", "2015", status: .current, slot: FX.emp).at("2015-06-01")]
        let base = stateWith(trusted)
        let with = stateWith(trusted + [fact(d, "Acme", nil, "2012", status: .former).untrusted(at: "2013-01-01")])
        #expect(with.episodes(of: "Acme").count == base.episodes(of: "Acme").count)
        #expect(with.beforeName("Initech") == base.beforeName("Initech"))
        #expect(!with.episodes(of: "Acme").contains { $0.inferredEnd })
    }

    // R4: "Not Acme" on "my previous job" is ignored by the date-cue path.
    @Test func r4_aRejectionBeatsADateCue() {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Initech", "2019", status: .current)])
        let cue = FX.registry.language.dateCueWords[0]
        let text = "At my \(cue) \(FX.word(d)) I used Emacs."
        let mem = FactsMemory(id: "q", text: text, written: "2020-06-01")
        let ph = s.rolePhrases(text)[0]
        s.rejections[FactsGraph.DecisionKey(memoryID: "q", start: ph.start)] = [s.ent("Acme")]
        let got = s.resolve(mem, ph)
        #expect(s.name(got.entity) != "Acme")
    }

    // R5: a trusted memory's "my previous job" resting on an untrusted-only episode is `inferred`, not `untrusted`.
    @Test func r5_aPreviousLinkRestingOnAnUntrustedEpisodeIsUntrusted() {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former).untrusted,
                           fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
        let cue = FX.registry.language.dateCueWords[0]
        let text = "At my \(cue) \(FX.word(d)) I used Emacs."
        let got = s.resolveText(text, "2020-06-01")
        #expect(got.0 == nil || got.1 == .untrusted)
    }

    // R6: an untrusted-only holder that "certainly holds" evicts a trusted holder with a later stated start.
    @Test func r6_anUntrustedHolderNeverEvictsATrustedOne() {
        let pp = FX.personSuccession
        func build(_ withUntrusted: Bool) -> (String?, LinkBasis) {
            var s = FactsGraph(registry: FX.registry)
            s.apply(FactsMemory(id: "m0", text: "Ana", written: "2022-06-01"), people: [ExtractedPerson(name: "Ana")],
                    facts: [fact(pp, "Ana", "2022", status: .current)])
            if withUntrusted {
                s.apply(FactsMemory(id: "m1", text: "Bo", written: "2016-01-01", source: .agent), people: [ExtractedPerson(name: "Bo")],
                        facts: [fact(pp, "Bo", "2015", status: .current)])
            }
            return s.resolveText("My \(FX.word(pp)) approved it.", "2020-01-01")
        }
        let with = build(true).0
        #expect(with != "Bo" && (with == nil || with == build(false).0))   // never the untrusted one; at most less sure
    }

    // R7: a user's row with an episode selector: the store's check uses derived ends (bounds), factEpisodes uses raw ones.
    @Test func r7_aSelectedUserRowJoinsTheEpisodeTheStoreChecked() {
        var s = stateWith([fact(d, "Acme", "2010", status: .current).at("2010-06-01"),
                           fact(d, "Acme", "2016", status: .current, quote: "rejoined Acme in 2016").at("2016-06-01"),
                           fact(d, "Acme", status: .former).at("2013-01-01")])
        let before = s.factEpisodes(s.facts[0])
        #expect(before.count == 2)
        let sel = DateRange(lo: before[1].start!.lo, hi: DayNumber.from(year: 2026, month: 1, day: 1)!)
        // The store's rule (FactStore.load): exactly one derived episode overlaps the selector.
        let storeHits = before.filter { ($0.start?.lo ?? DateRange.minDay) <= sel.hi && sel.lo <= ($0.end?.hi ?? DateRange.maxDay) }
        #expect(storeHits.count == 1)
        var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-01-01", status: .unknown, qualifiers: [:], states: true,
                              quote: "", handover: false)
        a.start = "2017"; a.fromUser = true; a.selector = sel
        s.facts[0].assertions.append(a)
        let after = s.factEpisodes(s.facts[0])
        #expect(after.count == 2)
    }

    // R8: port fidelity: with no former prefixes in the registry, group 4 matches empty and every phrase is "former".
    @Test func r8_noFormerPrefixesDoesNotMakeEveryPhraseFormer() throws {
        let reg = try FX.registry { json in
            var lang = json["language"] as! [String: Any]
            lang["former_prefixes"] = [String]()
            json["language"] = lang
        }
        let s = FactsGraph(registry: reg)
        let ph = s.rolePhrases("My \(FX.word(FX.personSuccession)) approved it.")
        #expect(ph.first?.former == false)
    }

    // R9: a user's "current" loses to a memory's undated "no longer".
    @Test func r9_aUsersStatusWinsOverInference() {
        var s = stateWith([fact(d, "Acme", "2015", status: .former).at("2020-01-01")])
        var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-11-15", status: .current, qualifiers: [:], states: true,
                              quote: "", handover: false)
        a.fromUser = true
        s.facts[0].assertions.append(a)
        #expect(s.status(of: s.facts[0]) == .current)
    }
}

@Suite struct ReviewRound1StoreTests {
    let v: TestVault
    let d = FX.dated
    let pp = FX.personSuccession
    var work: String { FX.registry.predicate(d)!.callGroup }
    var people: String { FX.registry.predicate(pp)!.callGroup }
    init() throws { v = try TestVault() }

    func memory(_ body: String, at days: Double = 0) throws -> Memory { try v.memory("Note", body, now: t0.plus(days: days)) }

    @discardableResult
    func apply(_ m: Memory, _ x: FactsExtraction, group: String? = nil, at days: Double = 0) throws -> FactStore.ApplyResult {
        let current = try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
        return try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: current.version, extraction: x, callGroup: group ?? work,
                                now: t0.plus(days: days))
        }
    }
    func str(_ sql: String, _ args: StatementArguments = []) throws -> String? {
        try v.store.writer.read { db in try String.fetchOne(db, sql: sql, arguments: args) }
    }
    func entityID(_ name: String) throws -> String? { try str("SELECT entity_id FROM entity_alias WHERE alias = ?", [name]) }

    func threeEmployers() throws {
        for (i, n) in ["Initech", "Globex", "Acme"].enumerated() {
            let m = try memory("I worked at \(n).", at: Double(i))
            try apply(m, FactsExtraction(facts: [fact(d, n, quote: "I worked at \(n)")]), at: Double(i))
        }
    }

    // S1: "also called" naming two known entities never merges them (memory processing §11.4): a To check suggestion.
    @Test func s1_alsoCalledBetweenKnownEntitiesIsASuggestion() throws {
        try threeEmployers()
        let globex = try #require(try entityID("Globex"))
        let m = try memory("Acme, also called Globex, was fun.", at: 5)
        let r = try apply(m, FactsExtraction(facts: [ExtractedFact(predicate: d, name: "Acme", quote: "Acme, also called Globex",
                                                                   alsoCalled: "Globex")]), at: 5)
        #expect(try entityID("Globex") == globex && r.mergeSuggestions == 1)
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE is_you = 0") == 3)
    }

    // An unknown other name is just an alias.
    @Test func s1b_alsoCalledWithAnUnknownNameIsAnAlias() throws {
        try threeEmployers()
        let acme = try #require(try entityID("Acme"))
        let m = try memory("Acme, also called Hooli, was fun.", at: 5)
        try apply(m, FactsExtraction(facts: [ExtractedFact(predicate: d, name: "Acme", quote: "Acme, also called Hooli",
                                                           alsoCalled: "Hooli")]), at: 5)
        #expect(try entityID("Hooli") == acme)
    }

    // S2: an untrusted memory's "also called" merges two trusted entities, for good.
    @Test func s2_anUntrustedAlsoCalledNeverMergesTrustedEntities() throws {
        try threeEmployers()
        let globex = try #require(try entityID("Globex"))
        let m = try memory("Acme, also called Globex, was fun.", at: 5)
        try v.store.writer.write { db in try db.execute(sql: "UPDATE memory SET trust = 'untrusted' WHERE id = ?", arguments: [m.id.db]) }
        try apply(m, FactsExtraction(facts: [ExtractedFact(predicate: d, name: "Acme", quote: "Acme, also called Globex",
                                                           alsoCalled: "Globex")]), at: 5)
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE id = ?", [globex]) == 1)
        _ = try v.store.deleteMemory(id: m.id, now: t0.plus(days: 6))
        try v.store.purgeMemory(id: m.id, now: t0.plus(days: 7))
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE id = ?", [globex]) == 1)   // and the purge can't undo it
    }

    // S3: a role group's count and label have no evidence: they outlive the memory, and an edit that drops them.
    @Test func s3_aGroupCountGoesWithItsLastSupportingMemory() throws {
        let m = try memory("I have three bosses.")
        try apply(m, FactsExtraction(facts: [ExtractedFact(predicate: pp, name: "", entity: "group", label: FX.word(pp),
                                                           quote: "three bosses", count: 3)]), group: people)
        #expect(try v.store.writer.read { db in try FactStore.load(db) }.graph.entities.values.contains { $0.count == 3 })
        _ = try v.store.updateMemory(id: m.id, MemoryEdit(body: "Nothing about work."), now: t0.plus(days: 1))
        _ = try v.store.deleteMemory(id: m.id, now: t0.plus(days: 2))
        try v.store.purgeMemory(id: m.id, now: t0.plus(days: 3))
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE is_you = 0") == 0)
    }

    // S4: "deceased" has no evidence either: it outlives the memory that said it.
    @Test func s4_deceasedGoesWithItsLastSupportingMemory() throws {
        let a = try memory("My boss Rosa approved it.")
        try apply(a, FactsExtraction(people: [ExtractedPerson(name: "Rosa")],
                                     facts: [fact(pp, "Rosa", label: FX.word(pp), quote: "My boss Rosa")]), group: people)
        let rosa = try #require(try entityID("Rosa"))
        let at = try #require(try str("SELECT updated_at FROM entity WHERE id = ?", [rosa]))
        let b = try memory("My late boss Rosa was kind.", at: 1)
        try apply(b, FactsExtraction(people: [ExtractedPerson(name: "Rosa", person: rosa)],
                                     facts: [fact(pp, "Rosa", label: FX.word(pp), quote: "My late boss Rosa", deceased: true)],
                                     roster: [rosa: at]), group: people, at: 1)
        _ = try v.store.deleteMemory(id: b.id, now: t0.plus(days: 2))
        try v.store.purgeMemory(id: b.id, now: t0.plus(days: 3))
        #expect(try v.count("SELECT deceased FROM entity WHERE id = ?", [rosa]) == 0)
    }

    // S5: an identical re-read of one memory invalidates another memory's decision (so re-reads ping-pong).
    @Test func s5_anIdenticalRereadInvalidatesNothing() throws {
        let a = try memory("Ana became my boss.")
        let xa = FactsExtraction(people: [ExtractedPerson(name: "Ana")], facts: [fact(pp, "Ana", status: .current, quote: "Ana became my boss")])
        try apply(a, xa, group: people)
        let b = try memory("Bo is my boss too.")
        try apply(b, FactsExtraction(people: [ExtractedPerson(name: "Bo")],
                                     facts: [fact(pp, "Bo", status: .current, quote: "Bo is my boss")]), group: people)
        let ana = try #require(try entityID("Ana")), bo = try #require(try entityID("Bo"))
        let m = try memory("Yesterday my boss approved the budget.")
        let rosterAt = try v.store.writer.read { db in
            try Dictionary(uniqueKeysWithValues: [ana, bo].map { ($0, try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [$0])!) })
        }
        try apply(m, FactsExtraction(roles: [ExtractedRole(phrase: 0, refersTo: ana)], roster: rosterAt), group: people)
        #expect(try v.count("SELECT COUNT(*) FROM mention_decision WHERE source = 'model' AND invalidated_at IS NULL") == 1)
        try apply(a, xa, group: people, at: 1)     // the same extraction of the same version, read again
        #expect(try v.count("SELECT COUNT(*) FROM mention_decision WHERE source = 'model' AND invalidated_at IS NULL") == 1)
    }

    // S6: Merge With… leaves two facts for one entity: its one job becomes two episodes, and "before X" is ambiguous.
    @Test func s6_aUserMergeFusesTheFacts() throws {
        let a = try memory("I joined Kiteworks in 2015.")
        try apply(a, FactsExtraction(facts: [fact(d, "Kiteworks", "2015", quote: "I joined Kiteworks in 2015")]))
        let b = try memory("I left KW in 2018.", at: 1)
        try apply(b, FactsExtraction(facts: [fact(d, "KW", nil, "2018", status: .former, quote: "I left KW in 2018")]), at: 1)
        let c = try memory("I joined Initech in 2019.", at: 2)
        try apply(c, FactsExtraction(facts: [fact(d, "Initech", "2019", status: .current, quote: "I joined Initech in 2019")]), at: 2)
        let kite = try #require(try entityID("Kiteworks")), kw = try #require(try entityID("KW"))
        try v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "entity", targetID: kw, field: "merged_into", value: kite, sensitivity: 1, now: t0)
        }
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        let eps = g.episodes(d).filter { $0.entity == kite }
        let r = g.after(d, .entity(kite))
        #expect(eps.count == 1)
        #expect(g.name(r.entity) == "Initech")
    }

    // S7: a rejected fact comes back when a memory's "also called" merges its entity away.
    @Test func s7_aRejectionSurvivesAnAlsoCalledMerge() throws {
        let a = try memory("I worked at Globex.")
        try apply(a, FactsExtraction(facts: [fact(d, "Globex", quote: "I worked at Globex")]))
        let b = try memory("I work at Acme.", at: 1)
        try apply(b, FactsExtraction(facts: [fact(d, "Acme", quote: "I work at Acme")]), at: 1)
        let gfact = try #require(try str("SELECT f.id FROM fact f JOIN entity_alias a ON a.entity_id = f.entity_id WHERE a.alias = 'Globex'"))
        try v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "fact", targetID: gfact, field: "rejected", value: true, sensitivity: 1, now: t0)
        }
        let m = try memory("Acme, also called Globex, was fun.", at: 5)
        try apply(m, FactsExtraction(facts: [ExtractedFact(predicate: d, name: "Acme", quote: "Acme, also called Globex", alsoCalled: "Globex")]), at: 5)
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        let counting = g.facts.flatMap(\.assertions).map(\.memoryID)
        #expect(!counting.contains(a.id.db))
    }
}

/// Adversarial review, round 1 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound1AstraTests {
    let d = FX.dated

    @Test func a1_untrustedSlotValuesNeverStartSuccession() {
        let s = stateWith([fact(d, "Acme", "2015", status: .current, slot: FX.emp).at("2016-01-01"),
                           fact(d, "Initech", "2019", status: .current, slot: FX.own).at("2020-01-01"),
                           fact(d, "Initech", slot: FX.emp).untrusted, fact(d, "Initech", slot: FX.emp).untrusted])
        #expect(s.episodes(of: "Acme")[0].end == nil)
        #expect(s.episodes(of: "Initech")[0].slot == FX.own)
    }

    @Test func a2_anUntrustedStartNeverRulesOutATrustedHolder() {
        let rows: [FactRowConvertible] = [fact(d, "Acme"), fact(d, "Initech", "2015", "2019", status: .former)]
        var base = stateWith(rows)
        var with = stateWith(rows + [fact(d, "Acme", "2020").untrusted])
        let text = "At my \(FX.word(d)) I use Emacs."
        #expect(base.resolveText(text, "2016-06-01") == with.resolveText(text, "2016-06-01"))
    }

    @Test func a3_aCurrentFromUntrustedEvidenceIsAtMostInferred() throws {
        let s = stateWith([fact(d, "Acme", "2015", status: .current).untrusted(at: "2020-01-01")])
        #expect(try #require(s.ask("What is my current job?")).basis == .inferred)
    }

    @Test func a3_aPreviousLinkOnAnUntrustedEpisodeIsUntrusted() {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former).untrusted,
                           fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
        let got = s.resolveText("At my \(FX.registry.language.dateCueWords[0]) \(FX.word(d)) I used Emacs.", "2020-06-01")
        #expect(got.0 == nil || got.1 == .untrusted)
    }

    @Test func a3_aYearHeldUntilASuccessionIsInferred() throws {
        let s = stateWith([fact(d, "Acme", "2015", status: .current, slot: FX.emp).at("2016-01-01"),
                           fact(d, "Initech", "2019", status: .current, slot: FX.emp).at("2019-06-01")])
        let got = try #require(s.ask("Where was I working in 2017?"))
        #expect(got.entity == s.ent("Acme") && got.basis == .inferred)
    }

    @Test func a4_aRejectedPreviousLinkStaysRejected() throws {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Initech", "2019", status: .current)])
        let mem = FactsMemory(id: "q", text: "At my \(FX.registry.language.dateCueWords[0]) \(FX.word(d)) I used Emacs.", written: "2020-06-01")
        let ph = try #require(s.rolePhrases(mem.text).first)
        let acme = s.ent("Acme")
        s.rejections[.init(memoryID: mem.id, start: ph.start)] = [acme]
        #expect(s.resolve(mem, ph).entity != acme)
    }
}

@Suite struct ReviewRound1AstraStoreTests {
    let v: TestVault
    let d = FX.dated
    let pp = FX.personSuccession
    var work: String { FX.registry.predicate(d)!.callGroup }
    var people: String { FX.registry.predicate(pp)!.callGroup }
    init() throws { v = try TestVault() }

    func memory(_ body: String, at days: Double = 0) throws -> Memory { try v.memory("Note", body, now: t0.plus(days: days)) }

    @discardableResult
    func apply(_ m: Memory, _ x: FactsExtraction, group: String? = nil, at days: Double = 0) throws -> FactStore.ApplyResult {
        let current = try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
        return try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: current.version, extraction: x, callGroup: group ?? work,
                                now: t0.plus(days: days))
        }
    }
    func str(_ sql: String, _ args: StatementArguments = []) throws -> String? {
        try v.store.writer.read { db in try String.fetchOne(db, sql: sql, arguments: args) }
    }
    func entityID(_ name: String) throws -> String? { try str("SELECT entity_id FROM entity_alias WHERE alias = ?", [name]) }
    func load() throws -> FactStore.Loaded { try v.store.writer.read { db in try FactStore.load(db) } }

    @Test func a6_aGroupLabelGoesWithItsMemory() throws {
        let m = try memory("The Nightfall crew are my two bosses.")
        try apply(m, FactsExtraction(facts: [ExtractedFact(predicate: pp, name: "", entity: "group", label: "Nightfall crew",
                                                           quote: "my two bosses", count: 2)]), group: people)
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE group_label = 'nightfall crew'") == 1)
        #expect(try load().graph.entities.values.contains { $0.count == 2 })
        _ = try v.store.deleteMemory(id: m.id, now: t0.plus(days: 1))
        try v.store.purgeMemory(id: m.id, now: t0.plus(days: 2))
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE group_label IS NOT NULL OR group_count IS NOT NULL") == 0)
    }

    /// Two managers and a memory whose "my boss" the model decided was Ana.
    private func decided() throws -> (decision: String, ana: String, bo: String) {
        let a = try memory("Ana became my boss in 2019 and has been since.")
        try apply(a, FactsExtraction(people: [ExtractedPerson(name: "Ana")],
                                     facts: [fact(pp, "Ana", "2019", status: .current, quote: "Ana became my boss in 2019")]), group: people)
        let b = try memory("Bo is my boss too.")
        try apply(b, FactsExtraction(people: [ExtractedPerson(name: "Bo")], facts: [fact(pp, "Bo", status: .current, quote: "Bo is my boss")]),
                  group: people)
        let ana = try #require(try entityID("Ana")), bo = try #require(try entityID("Bo"))
        let m = try memory("Yesterday my boss approved the budget.")
        let at = try v.store.writer.read { db in
            try Dictionary(uniqueKeysWithValues: [ana, bo].map { ($0, try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [$0])!) })
        }
        try apply(m, FactsExtraction(roles: [ExtractedRole(phrase: 0, refersTo: ana)], roster: at), group: people)
        return (try #require(try str("SELECT id FROM mention_decision WHERE source = 'model'")), ana, bo)
    }

    @Test func a7_aDecisionGoesStaleWhenASupportingMemoryChanges() throws {
        let (decision, _, _) = try decided()
        let a = try #require(try str("SELECT memory_id FROM fact_evidence ORDER BY rowid LIMIT 1"))
        _ = try v.store.updateMemory(id: UUID(uuidString: a)!, MemoryEdit(body: "Ana is my boss."), now: t0.plus(days: 1))
        #expect(try v.count("SELECT COUNT(*) FROM mention_decision WHERE id = ? AND invalidated_at IS NOT NULL", [decision]) == 1)
    }

    @Test func a7_aDecisionGoesStaleWhenItsFactIsRejected() throws {
        let (_, ana, _) = try decided()
        let fid = try #require(try str("SELECT id FROM fact WHERE entity_id = ?", [ana]))
        try v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "fact", targetID: fid, field: "rejected", value: true, sensitivity: 1, now: t0.plus(days: 1))
        }
        var g = try load().graph
        let mem = try #require(g.memories.values.first { $0.text.contains("Yesterday") })
        #expect(g.resolve(mem, g.rolePhrases(mem.text)[0]).entity != ana)
    }

    @Test func a8_inferenceNeverNegatesAManualFact() throws {
        try v.store.writer.write { db in
            _ = try FactStore.addManualFact(db, predicate: d, name: "Acme", asserted: ["start": "2015"], sensitivity: 1, now: t0)
        }
        let m = try memory("I never worked at Acme.")
        try apply(m, FactsExtraction(facts: [fact(d, "Acme", quote: "I never worked at Acme", positive: false)]))
        #expect(try load().graph.facts.contains { !$0.negated && $0.predicate == d })
    }

    @Test func a9_aNotSameOverrideKeepsItsOtherEntity() throws {
        let a = try memory("I worked at Globex.")
        try apply(a, FactsExtraction(facts: [fact(d, "Globex", quote: "I worked at Globex")]))
        let b = try memory("I worked at Initech.", at: 1)
        try apply(b, FactsExtraction(facts: [fact(d, "Initech", quote: "I worked at Initech")]), at: 1)
        let globex = try #require(try entityID("Globex")), initech = try #require(try entityID("Initech"))
        try v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "entity", targetID: globex, field: "not_same", value: initech, sensitivity: 1, now: t0)
        }
        _ = try v.store.deleteMemory(id: b.id, now: t0.plus(days: 2))
        try v.store.purgeMemory(id: b.id, now: t0.plus(days: 3))
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE id = ? AND tombstone = 1", [initech]) == 1)
    }

    @Test func a11_aCallGroupReplacesOnlyItsOwnEvidence() throws {
        let m = try memory("I joined Acme in 2018. My boss Robin is kind.")
        try apply(m, FactsExtraction(facts: [fact(d, "Acme", "2018", quote: "I joined Acme in 2018")]))
        try apply(m, FactsExtraction(people: [ExtractedPerson(name: "Robin")], facts: [fact(pp, "Robin", quote: "My boss Robin")]), group: people)
        #expect(try v.count("SELECT COUNT(*) FROM fact_evidence WHERE call_group = ?", [people]) == 1)
        try apply(m, FactsExtraction())                     // work re-read with nothing
        #expect(try v.count("SELECT COUNT(*) FROM fact_evidence WHERE call_group = ?", [work]) == 0)
        #expect(try entityID("Acme") == nil && entityID("Robin") != nil)
    }

    @Test func a12_aUsersEdgeUsesTheOtherEndpointsSelector() throws {
        let p = DateParser(registry: FX.registry)
        let a = try memory("I worked at Acme from 2010 to 2012.")
        try apply(a, FactsExtraction(facts: [fact(d, "Acme", "2010", "2012", status: .former, quote: "I worked at Acme from 2010 to 2012")]))
        let b = try memory("I went back to Acme from 2014 to 2016.", at: 1)
        try apply(b, FactsExtraction(facts: [fact(d, "Acme", "2014", "2016", status: .former, quote: "I went back to Acme from 2014 to 2016")]), at: 1)
        let c = try memory("I joined Initech in 2019.", at: 2)
        try apply(c, FactsExtraction(facts: [fact(d, "Initech", "2019", status: .current, quote: "I joined Initech in 2019")]), at: 2)
        let e = try memory("I worked at Hooli once.", at: 3)
        try apply(e, FactsExtraction(facts: [fact(d, "Hooli", status: .former, quote: "I worked at Hooli")]), at: 3)
        let acme = try #require(try str("SELECT f.id FROM fact f JOIN entity_alias a ON a.entity_id = f.entity_id WHERE a.alias = 'Acme'"))
        let initech = try #require(try str("SELECT f.id FROM fact f JOIN entity_alias a ON a.entity_id = f.entity_id WHERE a.alias = 'Initech'"))
        try v.store.writer.write { db in
            _ = try FactStore.addUserEvidence(db, factID: initech, kind: "order", asserted: [:], otherFactID: acme, direction: "preceded_by",
                                              otherSelector: p.parse("2015"), sensitivity: 1, now: t0)
        }
        let g = try load().graph
        let got = g.before(d, .entity(g.ent("Initech")))
        #expect(g.name(got.entity) == "Acme" && [.stated, .gap].contains(got.basis))   // 2016 → 2019: the gap is told
    }

    @Test func m9_aRestoreDropsQuotesOfMemoriesThatDidntComeBack() throws {
        let facts = FunesExportFacts(entities: [], aliases: [], aliasEvidence: [], facts: [], evidence: [],
                                     decisions: [["id": .string("d1"), "memory_id": .string("gone"), "mention": .string("my boss"),
                                                  "quote": .string("my boss"), "outcome": .string("rejected"), "basis": .string("confirmed"),
                                                  "source": .string("user"), "created_at": .string("2026-01-01 00:00:00.000")]],
                                     decisionDependencies: [], manualOverrides: [], runs: [])
        _ = try v.store.writer.write { db in try FactsExport.restore(db, facts, memories: [:], now: t0) }
        #expect(try v.count("SELECT COUNT(*) FROM mention_decision WHERE quote IS NULL AND mention IS NULL") == 1)
    }
}

/// Round 1, Low items.
@Suite struct ReviewRound1LowTests {
    @Test func episodeCuesAreWholeWordsUnlessAStem() {
        let s = stateWith([fact(FX.dated, "Acme", "2014", "2016", status: .former), fact(FX.dated, "Acme", "2020", "2021", status: .former)])
        #expect(s.beforeName("Acme", "before I went against Acme").0 == nil)        // "against" isn't "again"
        let stem = FX.registry.language.episodeLast.first { $0.hasSuffix("*") }
        if let stem { #expect(FactsText.cue(FactsText.fold(String(stem.dropLast()) + "e"), stem)) }
    }

    @Test func ordinalSuffixesComeFromTheRegistry() {
        #expect(DateParser(registry: FX.registry).parse("March 15th, 2019")?.precision == .day)
    }
}
