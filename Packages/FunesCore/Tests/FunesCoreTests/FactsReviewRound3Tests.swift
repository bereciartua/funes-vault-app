import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 3 (Fable 5.2): every counterexample, as a test.
@Suite struct ReviewRound3TimeModelTests {
    let d = FX.dated

    // V1: the user's "current" on a fact with two ended episodes reopens the FIRST one (the undated row falls back to
    // `candidates.first`), so the latest episode stays ended and the fact stays "former".
    @Test func v1_aUsersCurrentReopensTheLatestEpisode() {
        var s = stateWith([fact(d, "Acme", "2010", "2012", status: .former), fact(d, "Acme", "2015", "2018", status: .former)])
        var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-11-15", status: .current, qualifiers: [:], states: true,
                              quote: "", handover: false)
        a.fromUser = true
        s.facts[0].assertions.append(a)
        let eps = s.episodes(of: "Acme")
        #expect(s.status(of: s.facts[0]) == .current)
        #expect(eps.last?.ongoing == true && eps.first?.ongoing == false)
    }

    // V2: an untrusted memory's label gives a trusted, unlabelled fact its class: a trusted "my <exclusive label>" then
    // resolves at stated_unique instead of sole_known.
    @Test func v2_anUntrustedLabelNeverClassifiesATrustedFact() throws {
        let p = try #require(FX.registry.predicates.first { p in
            p.objectKind == "person" && !p.exclusive && p.lexicon.contains { $0.cls != nil && $0.exclusive == true }
        })
        let word = p.lexicon.first { $0.cls != nil && $0.exclusive == true }!.words[0]
        func build(_ withUntrusted: Bool) -> (String?, LinkBasis) {
            var s = FactsGraph(registry: FX.registry)
            s.apply(FactsMemory(id: "m0", text: "Rosa", written: "2020-01-01"), people: [ExtractedPerson(name: "Rosa")],
                    facts: [fact(p.id, "Rosa", quote: "Rosa")])
            let rosa = s.entities.values.first { $0.name == "Rosa" }!.id
            if withUntrusted {
                s.apply(FactsMemory(id: "a1", text: "Rosa is the user's \(word)", written: "2020-06-01", source: .agent),
                        people: [ExtractedPerson(name: "Rosa", person: rosa)],
                        facts: [fact(p.id, "Rosa", label: word, quote: "Rosa is the user's \(word)")], roster: [rosa])
            }
            return s.resolveText("My \(word) called.", "2021-01-01")
        }
        #expect(build(true).1 == build(false).1)
    }

    // V3: an untrusted memory that links a new name to a known person adds the alias; a trusted memory about another
    // person with that name is then attached to the known one.
    @Test func v3_anUntrustedPersonAliasNeverReroutesATrustedName() {
        let pp = FX.personSuccession
        var s = FactsGraph(registry: FX.registry)
        s.apply(FactsMemory(id: "m0", text: "Maria", written: "2020-01-01"), people: [ExtractedPerson(name: "Maria")],
                facts: [fact(pp, "Maria", status: .current)])
        let maria = s.entities.values.first { $0.name == "Maria" }!.id
        s.apply(FactsMemory(id: "a1", text: "Maria, also known as Ana", written: "2020-06-01", source: .agent),
                people: [ExtractedPerson(name: "Ana", person: maria)], roster: [maria])
        s.apply(FactsMemory(id: "m1", text: "Ana", written: "2021-01-01"), people: [ExtractedPerson(name: "Ana")],
                facts: [fact(pp, "Ana", status: .current)])
        let link = s.names[FactsGraph.NameKey(memoryID: "m1", surface: "Ana")]
        #expect(link?.entity != maria)
    }
}

@Suite struct ReviewRound3StoreTests {
    let v: TestVault
    let d = FX.dated
    var work: String { FX.registry.predicate(d)!.callGroup }
    init() throws { v = try TestVault() }

    func memory(_ body: String, at days: Double = 0, untrusted: Bool = false) throws -> Memory {
        let m = try v.memory("Note", body, now: t0.plus(days: days))
        if untrusted { try v.store.writer.write { db in try db.execute(sql: "UPDATE memory SET trust = 'untrusted' WHERE id = ?", arguments: [m.id.db]) } }
        return m
    }
    @discardableResult
    func apply(_ m: Memory, _ x: FactsExtraction, at days: Double = 0) throws -> FactStore.ApplyResult {
        let current = try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
        return try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: current.version, extraction: x, callGroup: work, now: t0.plus(days: days))
        }
    }
    func str(_ sql: String, _ args: StatementArguments = []) throws -> String? {
        try v.store.writer.read { db in try String.fetchOne(db, sql: sql, arguments: args) }
    }

    // W1: round 2's U3 through the primary name: an untrusted memory's longer name ("Acme Hooli") matches Acme by the
    // kind's containment rule and becomes its alias; a trusted "Hooli" then lands on Acme, and stays after the purge.
    @Test func w1_anUntrustedNameNeverReroutesTrustedEvidence() throws {
        let a = try memory("I worked at Acme from 2015 to 2018.")
        try apply(a, FactsExtraction(facts: [fact(d, "Acme", "2015", "2018", status: .former, quote: "I worked at Acme from 2015 to 2018")]))
        let acme = try #require(try str("SELECT entity_id FROM entity_alias WHERE alias = 'Acme'"))
        let u = try memory("The user was at Acme Hooli.", at: 1, untrusted: true)
        try apply(u, FactsExtraction(facts: [fact(d, "Acme Hooli", quote: "Acme Hooli")]), at: 1)
        let b = try memory("I joined Hooli in 2020.", at: 2)
        try apply(b, FactsExtraction(facts: [fact(d, "Hooli", "2020", status: .current, quote: "I joined Hooli in 2020")]), at: 2)
        _ = try v.store.deleteMemory(id: u.id, now: t0.plus(days: 3))
        try v.store.purgeMemory(id: u.id, now: t0.plus(days: 4))
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        #expect(g.entityMatches(d, "Hooli") != [acme])
    }
}

/// Adversarial review, round 3 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound3AstraTests {
    let d = FX.dated

    @Test func c1_aReversedUntrustedAliasNeverRedirectsTrustedEvidence() {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former)])
        let acme = s.ent("Acme")
        s.apply(FactsMemory(id: "u", text: "Hooli, also called Acme", written: "2019-01-01", source: .agent),
                facts: [ExtractedFact(predicate: d, name: "Hooli", quote: "Hooli, also called Acme", alsoCalled: "Acme")])
        s.apply(FactsMemory(id: "t", text: "I joined Hooli in 2020.", written: "2021-01-01"),
                facts: [fact(d, "Hooli", "2020", status: .current)])
        #expect(s.entityMatches(d, "Hooli").contains { $0 != acme })
        #expect(s.episodes(d).filter { $0.entity == acme }.count == 1)
    }

    @Test func c2_previousChecksFormerEpisodesAtTheMemoryDate() {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former),
                           fact(d, "Initech", "2019", status: .current).at("2019-06-01"),
                           fact(d, "Globex", nil, "2021", status: .former).at("2022-01-01")])
        let got = s.resolveText("At my \(FX.registry.language.dateCueWords[0]) \(FX.word(d)) I used Emacs.", "2020-06-01")
        #expect(got.0 == nil && got.1 == .candidates)
    }

    @Test func c3_anUntrustedLabelNeverEliminatesATrustedCandidate() throws {
        let p = try #require(FX.registry.predicates.first { p in p.objectKind == "person" && p.lexicon.filter { $0.cls != nil && $0.exclusive != true }.count >= 2 })
        let words = p.lexicon.filter { $0.cls != nil && $0.exclusive != true }.map { $0.words[0] }
        var s = peopleState(p.id, [("Alex", nil, nil, .current, "2020-01-01"), ("Bo", nil, nil, .current, "2020-01-01")])
        #expect(s.resolveText("My \(words[0]) called.", "2021-01-01").1 == .candidates)
        let alex = s.byName("Alex")[0].id
        s.apply(FactsMemory(id: "u", text: "Alex is the user's \(words[1]).", written: "2020-06-01", source: .agent),
                people: [ExtractedPerson(name: "Alex", person: alex)], facts: [fact(p.id, "Alex", label: words[1])], roster: [alex])
        let got = s.resolveText("My \(words[0]) called.", "2021-01-01")
        #expect(got.0 == nil && got.1 == .candidates)
    }

    @Test func c4_aContextDecisionUsesTheChosenEpisodesTrust() {
        let p = FX.personSuccession
        var s = peopleState(p, [("Ana", "2010", "2012", .former, "2013-01-01"), ("Bo", "2015", nil, .current, "2021-01-01")])
        let ana = s.byName("Ana")[0].id
        s.apply(FactsMemory(id: "u", text: "Ana became my boss again in 2020.", written: "2020-06-01", source: .agent),
                people: [ExtractedPerson(name: "Ana", person: ana)], facts: [fact(p, "Ana", "2020", status: .current)], roster: [ana])
        let text = "My \(FX.word(p)) approved it."
        let mem = FactsMemory(id: "q", text: text, written: "2021-06-01")
        let phrases = s.rolePhrases(text)
        s.apply(mem, phrases: phrases, roles: [ExtractedRole(phrase: 0, refersTo: ana)], roster: [ana])
        let got = s.resolve(mem, phrases[0])
        #expect(got.entity == nil || got.basis == .untrusted)
    }
}

@Suite struct ReviewRound3AstraStoreTests {
    let v: TestVault
    let d = FX.dated
    var work: String { FX.registry.predicate(d)!.callGroup }
    init() throws { v = try TestVault() }

    func memory(_ body: String, at days: Double = 0) throws -> Memory { try v.memory("Note", body, now: t0.plus(days: days)) }
    func apply(_ m: Memory, _ x: FactsExtraction, at days: Double = 0) throws {
        let current = try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
        _ = try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: current.version, extraction: x, callGroup: work, now: t0.plus(days: days))
        }
    }

    @Test func c5_aDenialAndALaterAffirmationKeepSeparateOrdinals() throws {
        let a = try memory("I joined Acme in 2010.")
        try apply(a, FactsExtraction(facts: [fact(d, "Acme", "2010", status: .current, quote: "I joined Acme in 2010")]))
        let b = try memory("The earlier Acme employment claim was wrong. I first joined Acme in 2020.", at: 1)
        try apply(b, FactsExtraction(facts: [fact(d, "Acme", quote: "The earlier Acme employment claim was wrong", positive: false),
                                             fact(d, "Acme", "2020", status: .current, quote: "I first joined Acme in 2020")]), at: 1)
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        #expect(g.name(g.answer(TimelineIntent(predicate: d, op: .current, anchor: nil)).entity) == "Acme")
    }
}
