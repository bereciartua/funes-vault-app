import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 2 (Fable 5.2): every counterexample, as a test.
@Suite struct ReviewRound2TimeModelTests {
    let d = FX.dated

    // T1: an untrusted "rejoined" row makes its own episode, and the next trusted row (an end) is placed in it:
    // the trusted episode loses its end and Acme is "current" at `ordered`.
    @Test func t1_anUntrustedEpisodeNeverCapturesATrustedEnd() {
        let trusted: [FactRowConvertible] = [fact(d, "Acme", "2010", status: .current).at("2011-01-01"),
                                             fact(d, "Acme", nil, "2018", status: .former).at("2019-01-01")]
        let base = stateWith(trusted)
        let with = stateWith(trusted + [fact(d, "Acme", "2014", quote: "rejoined Acme in 2014").untrusted(at: "2014-06-01")])
        let it = TimelineIntent(predicate: d, op: .current, anchor: nil)
        #expect(base.answer(it).isAmbiguous)
        #expect(with.answer(it).basis != .ordered)
        #expect(!with.episodes(of: "Acme").contains { $0.trusted && $0.ongoing })
    }

    // T2: the same capture hides a trusted conflict: two trusted ends (2012, 2018) conflict; with an untrusted start
    // in between they land in two episodes and "before Initech" is answered at `ordered`.
    @Test func t2_anUntrustedEpisodeNeverHidesATrustedConflict() {
        let trusted: [FactRowConvertible] = [fact(d, "Acme", "2010", "2012", status: .former),
                                             fact(d, "Acme", nil, "2018", status: .former),
                                             fact(d, "Initech", "2019", status: .current).at("2019-06-01")]
        let base = stateWith(trusted)
        let with = stateWith(trusted + [fact(d, "Acme", "2014").untrusted(at: "2014-06-01")])
        #expect(with.beforeName("Initech") == base.beforeName("Initech"))
    }

    // T3: the user's "current" loses to a memory's dated end (round 1's R9 fix covers only undated "no longer").
    @Test func t3_aUsersCurrentWinsOverAMemorysDatedEnd() {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former).at("2020-01-01")])
        var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-11-15", status: .current, qualifiers: [:], states: true,
                              quote: "", handover: false)
        a.fromUser = true
        s.facts[0].assertions.append(a)
        #expect(s.status(of: s.facts[0]) == .current)
    }

    // T4: an untrusted memory's "only" (a group count of 1, or `only` on the fact) lifts a trusted link to stated_unique.
    @Test func t4_anUntrustedOnlyNeverMakesATrustedLinkStatedUnique() throws {
        let p = try #require(FX.registry.predicates.first { p in
            p.objectKind == "person" && !p.exclusive && !p.succession
                && p.lexicon.contains { $0.cls != nil && $0.exclusive != true && $0.generic != true && $0.plural != true }
        })
        let word = p.lexicon.first { $0.cls != nil && $0.exclusive != true && $0.generic != true && $0.plural != true }!.words[0]
        func build(_ extra: (inout FactsGraph, String) -> Void) -> LinkBasis {
            var s = FactsGraph(registry: FX.registry)
            s.apply(FactsMemory(id: "m0", text: "my \(word) Maria", written: "2020-01-01"), people: [ExtractedPerson(name: "Maria")],
                    facts: [fact(p.id, "Maria", label: word, quote: "my \(word) Maria")])
            extra(&s, s.entities.values.first { $0.name == "Maria" }!.id)
            return s.resolveText("My \(word) called.", "2021-01-01").1
        }
        let base = build { _, _ in }
        let group = build { s, _ in
            s.apply(FactsMemory(id: "a1", text: "only one \(word)", written: "2020-06-01", source: .agent),
                    facts: [ExtractedFact(predicate: p.id, name: "", entity: "group", label: word, only: true)])
        }
        let only = build { s, maria in
            s.apply(FactsMemory(id: "a2", text: "Maria is the user's only \(word)", written: "2020-06-01", source: .agent),
                    people: [ExtractedPerson(name: "Maria", person: maria)],
                    facts: [ExtractedFact(predicate: p.id, name: "Maria", label: word, quote: "Maria is the user's only \(word)", only: true)],
                    roster: [maria])
        }
        #expect(base == .soleKnown)
        #expect(group == base)
        #expect(only == base)
    }

    // T5: untrusted dates give a `gap` answer (the gap check runs before the trust check).
    @Test func t5_untrustedDatesNeverGiveAGapAnswer() {
        let s = stateWith([fact(d, "Acme", "2015", "2017", status: .former).untrusted,
                           fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
        let got = s.beforeName("Initech")
        #expect(got.0 == nil || got.1 == .inferred)
    }
}

@Suite struct ReviewRound2StoreTests {
    let v: TestVault
    let d = FX.dated
    let pp = FX.personSuccession
    var work: String { FX.registry.predicate(d)!.callGroup }
    var people: String { FX.registry.predicate(pp)!.callGroup }
    init() throws { v = try TestVault() }

    func memory(_ body: String, at days: Double = 0, untrusted: Bool = false) throws -> Memory {
        let m = try v.memory("Note", body, now: t0.plus(days: days))
        if untrusted { try v.store.writer.write { db in try db.execute(sql: "UPDATE memory SET trust = 'untrusted' WHERE id = ?", arguments: [m.id.db]) } }
        return m
    }
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
    func load() throws -> FactsGraph { try v.store.writer.read { db in try FactStore.load(db) }.graph }
    func purge(_ m: Memory, at days: Double) throws {
        _ = try v.store.deleteMemory(id: m.id, now: t0.plus(days: days))
        try v.store.purgeMemory(id: m.id, now: t0.plus(days: days + 1))
    }

    // U1: "deceased" is recorded only for the first memory that says it: purge that one and the second's "late" is lost.
    @Test func u1_deceasedStaysWhileAMemoryStillSaysIt() throws {
        let a = try memory("My late boss Rosa approved it.")
        try apply(a, FactsExtraction(people: [ExtractedPerson(name: "Rosa")],
                                     facts: [fact(pp, "Rosa", label: FX.word(pp), quote: "My late boss Rosa", deceased: true)]), group: people)
        let rosa = try #require(try entityID("Rosa"))
        let at = try #require(try str("SELECT updated_at FROM entity WHERE id = ?", [rosa]))
        let b = try memory("My late boss Rosa was kind.", at: 1)
        try apply(b, FactsExtraction(people: [ExtractedPerson(name: "Rosa", person: rosa)],
                                     facts: [fact(pp, "Rosa", label: FX.word(pp), quote: "My late boss Rosa", deceased: true)],
                                     roster: [rosa: at]), group: people, at: 1)
        #expect(try load().entities[rosa]?.deceased == true)
        try purge(a, at: 2)
        #expect(try load().entities[rosa]?.deceased == true)
    }

    // U2: a memory that only refers to a group gets a count row it never stated, so the count outlives the memory that did.
    @Test func u2_aGroupCountGoesWithTheMemoryThatStatedIt() throws {
        let a = try memory("I have three bosses.")
        try apply(a, FactsExtraction(facts: [ExtractedFact(predicate: pp, name: "", entity: "group", label: FX.word(pp),
                                                           quote: "three bosses", count: 3)]), group: people)
        let gid = try #require(try str("SELECT id FROM entity WHERE group_predicate IS NOT NULL"))
        let at = try #require(try str("SELECT updated_at FROM entity WHERE id = ?", [gid]))
        let b = try memory("My bosses met today.", at: 1)
        try apply(b, FactsExtraction(facts: [ExtractedFact(predicate: pp, name: "", entity: gid, label: FX.word(pp), quote: "My bosses")],
                                     roster: [gid: at]), group: people, at: 1)
        try purge(a, at: 2)
        #expect(try load().entities[gid]?.count == nil)
    }

    // U3: an untrusted memory's "also called" gives a trusted entity a new alias; a later trusted memory about that
    // name is then attached to the wrong entity, and stays there after the untrusted memory is purged.
    @Test func u3_anUntrustedAliasNeverReroutesTrustedEvidence() throws {
        let a = try memory("I worked at Acme from 2015 to 2018.")
        try apply(a, FactsExtraction(facts: [fact(d, "Acme", "2015", "2018", status: .former, quote: "I worked at Acme from 2015 to 2018")]))
        let acme = try #require(try entityID("Acme"))
        let u = try memory("Acme, also called Hooli, was fun.", at: 1, untrusted: true)
        try apply(u, FactsExtraction(facts: [ExtractedFact(predicate: d, name: "Acme", quote: "Acme, also called Hooli", alsoCalled: "Hooli")]), at: 1)
        let b = try memory("I joined Hooli in 2020.", at: 2)
        try apply(b, FactsExtraction(facts: [fact(d, "Hooli", "2020", status: .current, quote: "I joined Hooli in 2020")]), at: 2)
        try purge(u, at: 3)
        let g = try load()
        let hooli = g.entityMatches(d, "Hooli")
        #expect(hooli != [acme])
    }

    // U4: an untrusted memory's group count is loaded as the count (latest counting memory, whatever its trust).
    @Test func u4_anUntrustedCountNeverSetsAGroupsCount() throws {
        let u = try memory("The user has one boss.", untrusted: true)
        try apply(u, FactsExtraction(facts: [ExtractedFact(predicate: pp, name: "", entity: "group", label: FX.word(pp),
                                                           quote: "one boss", count: 1)]), group: people)
        let gid = try #require(try str("SELECT id FROM entity WHERE group_predicate IS NOT NULL"))
        #expect(try load().entities[gid]?.count == nil)
    }
}

/// Adversarial review, round 2 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound2AstraTests {
    let d = FX.dated

    @Test func b1_aDecisionNeverLiftsAnUntrustedCandidate() {
        let pp = FX.personSuccession
        var s = FactsGraph(registry: FX.registry)
        s.apply(FactsMemory(id: "m0", text: "Ana", written: "2020-01-01"), people: [ExtractedPerson(name: "Ana")],
                facts: [fact(pp, "Ana", status: .current)])
        s.apply(FactsMemory(id: "m1", text: "Bo", written: "2020-01-02", source: .agent), people: [ExtractedPerson(name: "Bo")],
                facts: [fact(pp, "Bo", status: .current)])
        let bo = s.entities.values.first { $0.name == "Bo" }!.id
        let text = "My \(FX.word(pp)) approved it."
        let mem = FactsMemory(id: "q", text: text, written: "2021-01-01")
        s.apply(mem, phrases: s.rolePhrases(text), roles: [ExtractedRole(phrase: 0, refersTo: bo)], roster: [bo])
        let got = s.resolve(mem, s.rolePhrases(text)[0])
        #expect(got.entity == nil || got.basis == .untrusted)
    }

    @Test func b2_anUntrustedHandoverNeverRulesOutATrustedCandidate() {
        var s = stateWith([fact(d, "Acme", "2015", status: .current).at("2016-01-01"),
                           fact(d, "Initech", status: .current).untrusted(at: "2022-01-01"),
                           fact(d, "Initech", time: "2019").at("2023-01-01")])
        let got = s.resolveText("At my \(FX.word(d)) I use Emacs.", "2020-06-01")
        #expect(got.0 == nil && got.1 == .candidates)
    }

    @Test func b3_previousNeedsAnUnambiguousCurrentAnchor() {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former),
                           fact(d, "Initech", "2019", status: .current).at("2019-06-01"),
                           fact(d, "Globex", status: .current).at("2020-01-01")])
        let got = s.resolveText("At my \(FX.registry.language.dateCueWords[0]) \(FX.word(d)) I used Emacs.", "2020-06-01")
        #expect(got.0 == nil && got.1 == .candidates)
    }

    @Test func b5_anUntrustedOnlyOnTheSameFactNeverMakesItUnique() {
        var s = stateWith([fact(d, "Acme", "2015", status: .current).at("2016-01-01")])
        var only = fact(d, "Acme")
        only.only = true
        s.apply(FactsMemory(id: "u", text: "Acme", written: "2016-02-01", source: .agent), facts: [only])
        #expect(s.resolveText("At my \(FX.word(d)) I use Emacs.", "2017-01-01").1 == .soleKnown)
    }

    @Test func b7_aUsersCurrentOverridesALearnedExplicitEnd() {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former)])
        var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-11-15", status: .current, qualifiers: [:], states: true,
                              quote: "", handover: false)
        a.fromUser = true
        s.facts[0].assertions.append(a)
        #expect(s.status(of: s.facts[0]) == .current)
    }
}

@Suite struct ReviewRound2AstraStoreTests {
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
    func load() throws -> FactsGraph { try v.store.writer.read { db in try FactStore.load(db) }.graph }

    @Test func b4_twoStatementsInOneMemoryStayTwoEpisodes() throws {
        let m = try memory("I worked at Acme from 2010 to 2012, and again from 2020 to 2022.")
        try apply(m, FactsExtraction(facts: [fact(d, "Acme", "2010", "2012", status: .former, quote: "I worked at Acme from 2010 to 2012"),
                                             fact(d, "Acme", "2020", "2022", status: .former, quote: "again from 2020 to 2022")]))
        let o = try memory("I worked at Globex from 2017 to 2019.", at: 1)
        try apply(o, FactsExtraction(facts: [fact(d, "Globex", "2017", "2019", status: .former, quote: "I worked at Globex from 2017 to 2019")]), at: 1)
        let g = try load()
        #expect(g.episodes(of: "Acme").count == 2)
        #expect(g.before(d, .entity(g.ent("Acme"))).isAmbiguous)
    }

    @Test func b6_aSoftDeleteInvalidatesDecisionsAtOnce() throws {
        let a = try memory("Ana became my boss.")
        try apply(a, FactsExtraction(people: [ExtractedPerson(name: "Ana")], facts: [fact(pp, "Ana", status: .current, quote: "Ana became my boss")]), group: people)
        let b = try memory("Bo is my boss too.")
        try apply(b, FactsExtraction(people: [ExtractedPerson(name: "Bo")], facts: [fact(pp, "Bo", status: .current, quote: "Bo is my boss")]), group: people)
        let ana = try #require(try entityID("Ana")), bo = try #require(try entityID("Bo"))
        let m = try memory("Yesterday my boss approved the budget.")
        let at = try v.store.writer.read { db in
            try Dictionary(uniqueKeysWithValues: [ana, bo].map { ($0, try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [$0])!) })
        }
        try apply(m, FactsExtraction(roles: [ExtractedRole(phrase: 0, refersTo: ana)], roster: at), group: people)
        _ = try v.store.deleteMemory(id: a.id, now: t0.plus(days: 1))
        var g = try load()
        let mem = try #require(g.memories[m.id.db])
        #expect(g.resolve(mem, g.rolePhrases(mem.text)[0]).entity != ana)
    }

    @Test func b8_aUsersLabelRowWins() throws {
        let sib = try #require(FX.registry.predicates.first { p in p.objectKind == "person" && p.lexicon.filter { $0.cls != nil }.count >= 2 })
        let words = sib.lexicon.filter { $0.cls != nil }.map { $0.words[0] }
        let m = try memory("My \(words[0]) Alex visited.")
        try apply(m, FactsExtraction(people: [ExtractedPerson(name: "Alex")], facts: [fact(sib.id, "Alex", label: words[0], quote: "My \(words[0]) Alex")]),
                  group: sib.callGroup)
        let fid = try #require(try str("SELECT id FROM fact WHERE predicate = ?", [sib.id]))
        try v.store.writer.write { db in
            _ = try FactStore.addUserEvidence(db, factID: fid, kind: "qualifier", asserted: ["value": words[1]], qualifier: "label",
                                              sensitivity: 1, now: t0)
        }
        #expect(try load().facts.first { $0.predicate == sib.id }?.label == words[1])
    }

    @Test func b9_deceasedStaysWhileASecondMemorySaysIt() throws {
        let a = try memory("My late boss Rosa approved it.")
        try apply(a, FactsExtraction(people: [ExtractedPerson(name: "Rosa")],
                                     facts: [fact(pp, "Rosa", quote: "My late boss Rosa", deceased: true)]), group: people)
        let rosa = try #require(try entityID("Rosa"))
        let at = try #require(try str("SELECT updated_at FROM entity WHERE id = ?", [rosa]))
        let b = try memory("My late boss Rosa was kind.", at: 1)
        try apply(b, FactsExtraction(people: [ExtractedPerson(name: "Rosa", person: rosa)],
                                     facts: [fact(pp, "Rosa", quote: "My late boss Rosa", deceased: true)], roster: [rosa: at]),
                  group: people, at: 1)
        _ = try v.store.deleteMemory(id: a.id, now: t0.plus(days: 2))
        try v.store.purgeMemory(id: a.id, now: t0.plus(days: 3))
        #expect(try load().entities[rosa]?.deceased == true)
    }
}
