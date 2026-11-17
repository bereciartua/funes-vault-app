import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 4 (Fable 5.2): every counterexample, as a test.
@Suite struct ReviewRound4Tests {
    let d = FX.dated

    // X1: an untrusted start on a trusted, undated episode rules it OUT (it "started after"), so an answer that was
    // ambiguous becomes `ordered`: before X, a year, and the "previous" link.
    @Test func x1_anUntrustedStartNeverRulesATrustedEpisodeOut() {
        let trusted: [FactRowConvertible] = [fact(d, "Acme", "2015", "2018", status: .former),
                                             fact(d, "Globex").at("2019-06-01"),
                                             fact(d, "Initech", "2019", status: .current).at("2019-06-01")]
        var base = stateWith(trusted)
        var with = stateWith(trusted + [fact(d, "Globex", "2022").untrusted(at: "2022-06-01")])
        let y2016 = DateRange(lo: DayNumber.from(year: 2016, month: 1, day: 1)!, hi: DayNumber.from(year: 2016, month: 12, day: 31)!, precision: .year)
        let cue = FX.registry.language.dateCueWords[0]
        let text = "At my \(cue) \(FX.word(d)) I used Emacs."
        let (bp, wp) = (base.resolveText(text, "2020-06-01"), with.resolveText(text, "2020-06-01"))
        #expect(with.beforeName("Initech") == base.beforeName("Initech"))
        #expect(with.inRange(d, y2016).basis == base.inRange(d, y2016).basis)
        #expect(wp == bp)
    }

    // X2: an untrusted start becomes the lower limit of a trusted bound end ("no longer there"), which decides the
    // winner between two undated former jobs at `ordered`.
    @Test func x2_anUntrustedStartNeverNarrowsATrustedBound() {
        let trusted: [FactRowConvertible] = [fact(d, "Acme", status: .former).at("2018-10-01"),
                                             fact(d, "Globex", status: .former).at("2018-12-15"),
                                             fact(d, "Initech", "2019", status: .current).at("2019-06-01")]
        let base = stateWith(trusted)
        let with = stateWith(trusted + [fact(d, "Globex", "November 2018").untrusted(at: "2018-11-20")])
        #expect(with.beforeName("Initech").0 == nil || with.beforeName("Initech").1 == .inferred)
    }

    // X3: a trusted memory's order edge ("preceded by Hooli") resolves through an alias only an untrusted memory gave,
    // and answers at `stated`.
    @Test func x3_aTrustedOrderEdgeNeverResolvesThroughAnUntrustedAlias() {
        func build(_ withAlias: Bool) -> (String?, TimelineBasis) {
            var s = FactsGraph(registry: FX.registry)
            s.apply(FactsMemory(id: "m0", text: "Acme", written: "2026-01-01"), facts: [fact(d, "Acme", "2015", "2018", status: .former)])
            s.apply(FactsMemory(id: "m1", text: "Globex", written: "2026-01-01"), facts: [fact(d, "Globex", "2016", "2018", status: .former)])
            if withAlias {
                s.apply(FactsMemory(id: "a1", text: "Acme, also called Hooli", written: "2026-01-02", source: .agent),
                        facts: [ExtractedFact(predicate: d, name: "Acme", alsoCalled: "Hooli")])
            }
            s.apply(FactsMemory(id: "m2", text: "Initech", written: "2026-01-03"),
                    facts: [fact(d, "Initech", "2019", status: .current, precededBy: "Hooli")])
            return s.beforeName("Initech")
        }
        #expect(build(true) == build(false))
    }
}

/// Adversarial review, round 4 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound4AstraTests {
    let d = FX.dated

    @Test func e2_aFutureTrustedEpisodeNeverVouchesForAnUntrustedOne() {
        let p = FX.personSuccession
        var s = peopleState(p, [("Ana", "2025", nil, .current, "2025-06-01"), ("Bo", "2015", nil, .current, "2021-01-01")])
        let ana = s.byName("Ana")[0].id
        s.apply(FactsMemory(id: "u", text: "Ana", written: "2023-01-01", source: .agent),
                people: [ExtractedPerson(name: "Ana", person: ana)], facts: [fact(p, "Ana", "2020", "2022", status: .former)], roster: [ana])
        let mem = FactsMemory(id: "q", text: "My \(FX.word(p)) approved it.", written: "2021-06-01")
        let ph = s.rolePhrases(mem.text)[0]
        s.apply(mem, phrases: [ph], roles: [ExtractedRole(phrase: 0, refersTo: ana)], roster: [ana])
        let got = s.resolve(mem, ph)
        #expect(got.entity == nil || got.basis == .untrusted)
    }

    @Test func e3_successionChecksConcurrencyAtTheSuccessorsStart() {
        let s = stateWith([fact(d, "Globex", "2010", "2025", status: .former, slot: FX.emp),
                           fact(d, "Acme", "2015", status: .current, slot: FX.emp).at("2018-01-01"),
                           fact(d, "Initech", "2020", status: .current, slot: FX.emp).at("2021-01-01")])
        #expect(s.episodes(of: "Acme")[0].end == nil)
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
    }

    @Test func e1_aTrustedNameNeverPairsThroughAnUntrustedAlias() {
        let pp = FX.personSuccession
        var s = FactsGraph(registry: FX.registry)
        s.apply(FactsMemory(id: "m0", text: "Maria", written: "2020-01-01"), people: [ExtractedPerson(name: "Maria")],
                facts: [fact(pp, "Maria", status: .current)])
        s.apply(FactsMemory(id: "m1", text: "Bo", written: "2020-01-02"), people: [ExtractedPerson(name: "Bo")],
                facts: [fact(pp, "Bo", status: .current)])
        let maria = s.byName("Maria")[0].id
        s.apply(FactsMemory(id: "a1", text: "Maria, aka Ana", written: "2020-06-01", source: .agent),
                people: [ExtractedPerson(name: "Ana", person: maria)], roster: [maria])
        let text = "My \(FX.word(pp)) Ana approved it."
        let mem = FactsMemory(id: "q", text: text, written: "2021-01-01")
        let phrases = s.rolePhrases(text)
        s.apply(mem, phrases: phrases, roles: [ExtractedRole(phrase: 0, refersTo: maria)], roster: [maria])
        let got = s.resolve(mem, phrases[0])
        #expect(!(got.entity == maria && got.basis == .named))
    }
}

@Suite struct ReviewRound4AstraStoreTests {
    let v: TestVault
    let d = FX.dated
    var work: String { FX.registry.predicate(d)!.callGroup }
    init() throws { v = try TestVault() }

    func memory(_ body: String, at days: Double = 0, untrusted: Bool = false) throws -> Memory {
        let m = try v.memory("Note", body, now: t0.plus(days: days))
        if untrusted { try v.store.writer.write { db in try db.execute(sql: "UPDATE memory SET trust = 'untrusted' WHERE id = ?", arguments: [m.id.db]) } }
        return m
    }
    func apply(_ m: Memory, _ x: FactsExtraction, group: String? = nil, at days: Double = 0) throws {
        let current = try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
        _ = try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: current.version, extraction: x, callGroup: group ?? work, now: t0.plus(days: days))
        }
    }
    func str(_ sql: String, _ args: StatementArguments = []) throws -> String? {
        try v.store.writer.read { db in try String.fetchOne(db, sql: sql, arguments: args) }
    }
    func load() throws -> FactsGraph { try v.store.writer.read { db in try FactStore.load(db) }.graph }

    @Test func e1_aliasesGoToTheEntityEachStatementLandedOn() throws {
        let a = try memory("I worked at Acme from 2015 to 2018.")
        try apply(a, FactsExtraction(facts: [fact(d, "Acme", "2015", "2018", status: .former, quote: "I worked at Acme from 2015 to 2018")]))
        let acme = try #require(try str("SELECT entity_id FROM entity_alias WHERE alias = 'Acme'"))
        let u = try memory("Acme, also called Hooli.", at: 1, untrusted: true)
        try apply(u, FactsExtraction(facts: [ExtractedFact(predicate: d, name: "Acme", quote: "Acme, also called Hooli", alsoCalled: "Hooli")]), at: 1)
        let b = try memory("I was at Acme in 2015 and joined Hooli in 2020.", at: 2)
        try apply(b, FactsExtraction(facts: [fact(d, "Acme", "2015", status: .former, quote: "I was at Acme in 2015"),
                                             fact(d, "Hooli", "2020", status: .current, quote: "joined Hooli in 2020")]), at: 2)
        _ = try v.store.deleteMemory(id: u.id, now: t0.plus(days: 3))
        try v.store.purgeMemory(id: u.id, now: t0.plus(days: 4))
        #expect(try v.count("SELECT COUNT(*) FROM entity_alias WHERE entity_id = ? AND alias = 'Hooli'", [acme]) == 0)
        #expect(try load().entityMatches(d, "Hooli", onlyTrusted: true).allSatisfy { $0 != acme })
    }

    @Test func e4_aFactCreatedAndDeniedInOneApplyStaysDenied() throws {
        let m = try memory("I joined Acme in 2010. Actually, I never worked at Acme.")
        try apply(m, FactsExtraction(facts: [fact(d, "Acme", "2010", status: .current, quote: "I joined Acme in 2010"),
                                             fact(d, "Acme", quote: "I never worked at Acme", positive: false)]))
        #expect(try load().answer(TimelineIntent(predicate: d, op: .current, anchor: nil)).entities.isEmpty)
    }

    @Test func e5_aScopedLabelOverrideGoesWithItsSpan() throws {
        let sib = try #require(FX.registry.predicates.first { p in p.objectKind == "person" && p.lexicon.filter { $0.cls != nil }.count >= 2 })
        let words = sib.lexicon.filter { $0.cls != nil }.map { $0.words[0] }
        let a = try memory("My \(words[0]) Alex visited.")
        try apply(a, FactsExtraction(people: [ExtractedPerson(name: "Alex")], facts: [fact(sib.id, "Alex", label: words[0], quote: "My \(words[0]) Alex")]),
                  group: sib.callGroup)
        let alex = try #require(try str("SELECT entity_id FROM entity_alias WHERE alias = 'Alex'"))
        let at = try #require(try str("SELECT updated_at FROM entity WHERE id = ?", [alex]))
        let b = try memory("Alex and I cooked.", at: 1)
        try apply(b, FactsExtraction(people: [ExtractedPerson(name: "Alex", person: alex)], facts: [fact(sib.id, "Alex", quote: "Alex")], roster: [alex: at]),
                  group: sib.callGroup, at: 1)
        let fid = try #require(try str("SELECT id FROM fact WHERE predicate = ?", [sib.id]))
        try v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "qualifier", targetID: fid, field: "label", value: words[1], sensitivity: 1,
                                       memoryID: a.id.db, quote: "My \(words[0]) Alex", now: t0.plus(days: 2))
        }
        #expect(try load().facts.first { $0.predicate == sib.id }?.label == words[1])
        _ = try v.store.updateMemory(id: a.id, MemoryEdit(body: "Alex visited."), now: t0.plus(days: 3))
        #expect(try load().facts.first { $0.predicate == sib.id }?.label != words[1])
    }

    @Test func e6_aFactChangeMovesItsEntitysRosterToken() throws {
        let a = try memory("I joined Acme in 2018.")
        try apply(a, FactsExtraction(facts: [fact(d, "Acme", "2018", quote: "I joined Acme in 2018")]))
        let acme = try #require(try str("SELECT entity_id FROM entity_alias WHERE alias = 'Acme'"))
        let token = try #require(try str("SELECT updated_at FROM entity WHERE id = ?", [acme]))
        let fid = try #require(try str("SELECT id FROM fact WHERE entity_id = ?", [acme]))
        try v.store.writer.write { db in
            _ = try FactStore.addUserEvidence(db, factID: fid, asserted: ["start": "2017"], sensitivity: 1, now: t0.plus(days: 1))
        }
        let m = try memory("Acme was fun.", at: 2)
        #expect(throws: FactStore.ApplyError.rosterChanged) { try apply(m, FactsExtraction(roster: [acme: token]), at: 2) }
    }
}
