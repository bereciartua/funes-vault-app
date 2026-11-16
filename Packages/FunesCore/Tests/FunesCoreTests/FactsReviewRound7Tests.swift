import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 7 (Fable 5.2).
@Suite struct ReviewRound7Tests {
    let d = FX.dated

    // N1: an undated "rejoined" written after every stint ended makes a new episode even when it only looks back
    // (no "current"): with no dates and no end it is ongoing, so a job the user left is current again.
    @Test func n1_aRetrospectiveReturnNeverReopensAnEndedJob() {
        let rows: [FactRowConvertible] = [fact(d, "Acme", "2010", "2012", status: .former).at("2012-06-01"),
                                          fact(d, "Acme", "2014", "2015", status: .former, quote: "rejoined Acme in 2014").at("2015-06-01")]
        let base = stateWith(rows)
        let with = stateWith(rows + [fact(d, "Acme", quote: "When I rejoined Acme the team had doubled").at("2016-06-01")])
        let it = TimelineIntent(predicate: d, op: .current, anchor: nil)
        #expect(with.episodes(of: "Acme").count == 2)
        #expect(with.answer(it).entities.isEmpty)
        #expect(with.status(of: with.facts[0]) == .former)
    }

    static func date(_ s: String) -> Date {
        let p = s.split(separator: "-").map { Int($0)! }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }

    /// A vault with one memory per spec, read (applied) in the given order.
    static func vault(_ specs: [R6Spec]) throws -> (TestVault, [UUID]) {
        let v = try TestVault()
        var ids: [UUID] = []
        for (i, s) in specs.enumerated() {
            let m = try v.memory("Note", s.text, now: date(s.written).addingTimeInterval(Double(i)))
            ids.append(m.id)
            try v.store.writer.write { db in
                if !s.trusted { try db.execute(sql: "UPDATE memory SET trust = 'untrusted' WHERE id = ?", arguments: [m.id.db]) }
                let before = try FactStore.load(db).graph
                let (ppl, roster) = R6.people(before, s)
                var tokens: [String: String] = [:]
                for id in roster { tokens[id] = try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [id]) }
                try FactStore.apply(db, memoryID: m.id.db, version: m.version, extraction: FactsExtraction(people: ppl, facts: [s.fact], roster: tokens),
                                    callGroup: FX.registry.predicate(s.fact.predicate)!.callGroup, now: t0.plus(minutes: Double(i)))
            }
        }
        return (v, ids)
    }

    static func answers(_ v: TestVault) throws -> [String: (String, Bool)] {
        R6.answers(try v.store.writer.read { db in try FactStore.load(db) }.graph)
    }

    // P1: memories read in any order (a backfill), untrusted ones among them. After the untrusted memories are purged,
    // the vault answers as one that never had them (same trusted memories, same reading order).
    @Test func p1_aPurgeLeavesNoTraceWhateverTheReadingOrder() throws {
        var g = R6RNG(s: 31)
        var failures: [String] = []
        for iter in 0..<30 where failures.count < 8 {
            var specs = (0..<(2 + g.next(4))).map { _ in R6.spec(&g, trusted: true) }
            for _ in 0..<(1 + g.next(2)) { specs.insert(R6.spec(&g, trusted: false, extra: ["Hooli"]), at: g.next(specs.count + 1)) }
            let (v, ids) = try Self.vault(specs)
            for (n, (s, id)) in zip(specs, ids).enumerated() where !s.trusted {
                _ = try v.store.deleteMemory(id: id, now: t0.plus(days: 1 + Double(n)))
                try v.store.purgeMemory(id: id, now: t0.plus(days: 2 + Double(n)))
            }
            let (clean, _) = try Self.vault(specs.filter(\.trusted))
            let (got, want) = (try Self.answers(v), try Self.answers(clean))
            for (k, w) in want.sorted(by: { $0.key < $1.key }) where got[k]?.0 != w.0 {
                failures.append("#\(iter) \(k): never-there \(w.0) ≠ purged \(got[k]?.0 ?? "n/a") :: " + specs.map(\.line).joined(separator: " | "))
                break
            }
        }
        for f in failures.prefix(3) { Issue.record("\(f)") }
        #expect(failures.isEmpty)
    }

    // P2: the loaded graph doesn't depend on the order memories were read in (hand-overs, labels, statuses are derived
    // from written order): two vaults with the same trusted memories, read in different orders, answer the same.
    @Test func p2_theReadingOrderDoesNotChangeTheAnswers() throws {
        var g = R6RNG(s: 37)
        var failures: [String] = []
        for iter in 0..<30 where failures.count < 8 {
            // distinct written days, so written order is total
            var specs: [R6Spec] = []
            for i in 0..<(2 + g.next(4)) {
                var s = R6.spec(&g, trusted: true)
                s.written = String(format: "%04d-%02d-%02d", 2013 + g.next(8), 1 + g.next(12), 1 + i)
                specs.append(s)
            }
            let sorted = specs.sorted { $0.written < $1.written }
            var shuffled = sorted
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) { shuffled.swapAt(i, g.next(i + 1)) }
            let (a, _) = try Self.vault(sorted), (b, _) = try Self.vault(shuffled)
            let (want, got) = (try Self.answers(a), try Self.answers(b))
            for (k, w) in want.sorted(by: { $0.key < $1.key }) where got[k]?.0 != w.0 {
                failures.append("#\(iter) \(k): written order \(w.0) ≠ shuffled \(got[k]?.0 ?? "n/a") :: " + shuffled.map(\.line).joined(separator: " | "))
                break
            }
        }
        for f in failures.prefix(3) { Issue.record("\(f)") }
        #expect(failures.isEmpty)
    }
}

/// Adversarial review, round 7 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound7AstraTests {
    let d = FX.dated

    @Test func h2_anIntermediateUndatedReturnRemainsACandidate() {
        var s = stateWith([fact(d, "Acme", "2010", "2012", status: .former).at("2013-01-01"),
                           fact(d, "Acme", status: .current, quote: "I rejoined Acme.").at("2020-01-01"),
                           fact(d, "Acme", "2024", "2025", status: .former).at("2025-06-01"),
                           fact(d, "Initech", "2019", "2021", status: .former).at("2022-01-01")])
        let got = s.resolveText("At my \(FX.word(d)) I use Emacs.", "2020-06-01")
        #expect(got.0 == nil && got.1 == .candidates)
    }

    @Test func h3_aRejectedOrderCannotReturnThroughDates() {
        var s = stateWith([fact(d, "Acme", "2015", "2018", status: .former), fact(d, "Initech", "2019", status: .current)])
        s.rejectedEdges = [FactsGraph.EdgeRejection(from: s.ent("Acme"), to: s.ent("Initech"))]
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
        #expect(s.after(d, .entity(s.ent("Acme"))).isAmbiguous)
    }

    @Test func h5_aStatedEdgeNeverCrossesAConflictingEnd() {
        let s = stateWith([fact(d, "Acme", "2010", "2018", status: .former), fact(d, "Acme", "2010", "2022", status: .former),
                           fact(d, "Initech", "2020", precededBy: "Acme")])
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
    }

    @Test func h6_aContextDecisionOnAnInferredEndIsInferred() {
        let p = FX.personExclusive
        var s = peopleState(p, [("Cora", "2010", "2013", .former, "2014-01-01"), ("Ana", "2015", nil, .current, "2016-01-01"),
                                ("Bo", "2019", nil, .current, "2020-01-01")])
        let ana = s.byName("Ana")[0].id
        let text = "My former \(FX.word(p)) called."
        let mem = FactsMemory(id: "q", text: text, written: "2021-01-01")
        let phrases = s.rolePhrases(text)
        s.apply(mem, phrases: phrases, roles: [ExtractedRole(phrase: 0, refersTo: ana)], roster: [ana])
        let got = s.resolve(mem, phrases[0])
        #expect(got.entity != ana || got.basis == .inferred)
    }

    @Test func h4_anExactNameBeatsAContainedOne() {
        var s = stateWith([fact(d, "Acme", "2010", "2012", status: .former), fact(d, "Acme Labs", "2013", "2015", status: .former)])
        s.notSame.insert([s.ent("Acme"), s.ent("Acme Labs")])
        s.apply(FactsMemory(id: "t", text: "I rejoined Acme Labs in 2019.", written: "2019-06-01"),
                facts: [fact(d, "Acme Labs", "2019", status: .current)])
        #expect(s.episodes(d).filter { $0.entity == s.ent("Acme Labs") }.count == 2)
        #expect(s.episodes(of: "Acme").count == 1)
    }
}

@Suite struct ReviewRound7AstraStoreTests {
    let d = FX.dated
    var work: String { FX.registry.predicate(d)!.callGroup }

    @Test func h1_anOlderUntrustedRowNeverTakesATrustedHandOver() throws {
        let v = try TestVault()
        func mem(_ text: String, _ year: Int, untrusted: Bool = false) throws -> Memory {
            let m = try v.memory("Note", text, now: Date(timeIntervalSince1970: TimeInterval((year - 1970) * 31_557_600)))
            if untrusted { try v.store.writer.write { db in try db.execute(sql: "UPDATE memory SET trust = 'untrusted' WHERE id = ?", arguments: [m.id.db]) } }
            return try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
        }
        func apply(_ m: Memory, _ f: ExtractedFact) throws {
            _ = try v.store.writer.write { db in
                try FactStore.apply(db, memoryID: m.id.db, version: m.version, extraction: FactsExtraction(facts: [f]), callGroup: work, now: t0)
            }
        }
        try apply(try mem("I worked at Acme from 2010 to 2015.", 2016), fact(d, "Acme", "2010", "2015", status: .former, quote: "I worked at Acme from 2010 to 2015"))
        try apply(try mem("I work at Initech.", 2020), fact(d, "Initech", status: .current, quote: "I work at Initech"))
        try apply(try mem("The user is at Initech.", 2017, untrusted: true), fact(d, "Initech", quote: "The user is at Initech"))
        var g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        #expect(g.resolveText("At my \(FX.word(d)) I use Emacs.", "2018-06-01").1 != .soleKnown)
    }
}
