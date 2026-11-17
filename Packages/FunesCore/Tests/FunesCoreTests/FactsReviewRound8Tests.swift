import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 8 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound8AstraTests {
    let d = FX.dated

    @Test func i1_aStatedOrderCannotContradictTheSuccessorsEnd() {
        let s = stateWith([fact(d, "Acme", "2010", "2020", status: .former),
                           fact(d, "Initech", nil, "2015", status: .former, precededBy: "Acme")])
        #expect(s.after(d, .entity(s.ent("Acme"))).isAmbiguous)
        let m = stateWith([fact(d, "Acme", "2018", "2019", status: .former),
                           fact(d, "Initech", nil, "2015", status: .former, precededBy: "Acme")])
        #expect(m.before(d, .entity(m.ent("Initech"))).isAmbiguous)
    }

    @Test func i2_anUntrustedWrittenDateNeverReordersTrustedEpisodes() {
        let rows: [FactRowConvertible] = [fact(d, "Acme", "2010", "2012", status: .former).at("2013-01-01"),
                                          fact(d, "Acme", status: .current, quote: "I rejoined Acme.").at("2020-01-01"),
                                          fact(d, "Acme", "2024", "2025", status: .former).at("2025-06-01")]
        let base = stateWith(rows)
        let with = stateWith(rows + [fact(d, "Acme").untrusted(at: "2026-01-01")])
        #expect(base.status(of: base.facts[0]) == .former)
        #expect(with.status(of: with.facts[0]) == .former)
    }

    @Test func i3_aTrustedHeldDateConflictsWithAnEarlierEnd() {
        let s = stateWith([fact(d, "Acme", "2015", "2018", status: .former).at("2019-01-01"),
                           fact(d, "Acme", status: .current, quote: "I still work at Acme.").at("2020-06-01"),
                           fact(d, "Initech", "2019", status: .current).at("2020-06-01")])
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
    }
}

@Suite struct ReviewRound8AstraStoreTests {
    let d = FX.dated
    var work: String { FX.registry.predicate(d)!.callGroup }

    @Test func i4_aCorrectionFollowsAMerge() throws {
        let v = try TestVault()
        for text in ["I work at Acme since 2015.", "I work at AC since 2015."] {
            let m = try v.memory("Note", text)
            let name = text.contains("AC ") ? "AC" : "Acme"
            _ = try v.store.writer.write { db in
                try FactStore.apply(db, memoryID: m.id.db, version: m.version,
                                    extraction: FactsExtraction(facts: [fact(d, name, "2015", status: .current, quote: text)]),
                                    callGroup: work, now: t0)
            }
        }
        let q = try v.memory("Note", "At my \(FX.word(d)) I use Emacs.", now: t0.plus(days: 1))
        let ids = try v.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT entity_id, alias FROM entity_alias").map { ($0["alias"] as String, $0["entity_id"] as String) }
        }
        let acme = ids.first { $0.0 == "Acme" }!.1, ac = ids.first { $0.0 == "AC" }!.1
        try v.store.writer.write { db in
            _ = try FactStore.decideMention(db, memoryID: q.id.db, quote: "my \(FX.word(d))", entityID: acme, outcome: "rejected", now: t0)
            _ = try FactStore.override(db, targetKind: "entity", targetID: acme, field: "merged_into", value: ac, sensitivity: 1, now: t0)
        }
        var g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        let mem = try #require(g.memories[q.id.db])
        #expect(g.resolve(mem, g.rolePhrases(mem.text)[0]).entity != ac)
    }
}

/// Adversarial review, round 8 (Fable 5.2): the containment change.
@Suite struct ReviewRound8FableTests {
    let d = FX.dated

    func twoOrgs() -> FactsGraph {
        stateWith([fact(d, "Acme", "2010", "2012", status: .former), fact(d, "Acme Labs", "2013", "2015", status: .former),
                   fact(d, "Initech", "2016", status: .current).at("2016-06-01")])
    }

    // E1: "Acme" and "Acme Labs" are now two entities. A question naming either exactly finds both (exact, then
    // containment), and a name with two hits has no anchor: neither can be asked about.
    @Test func e1_anExactNameAnchorsItsOwnEntity() {
        let s = twoOrgs()
        #expect(s.entities.values.filter { $0.kind == "organization" }.count == 3)
        for (q, want) in [("Where did I work before Acme Labs?", "Acme Labs"), ("Where did I work after Acme?", "Acme"),
                          ("Where did I work before Initech?", "Initech")] {
            let it = s.intent(q)
            var got: String?
            if case .entity(let id)? = it?.anchor { got = s.name(id) }
            #expect(got == want)
        }
    }

    // E2: a trusted order edge that names "Acme" also resolves to "Acme Labs" (containment). When Acme itself is
    // undecidable (two stints), the edge lands on Acme Labs alone and answers for it.
    @Test func e2_anOrderEdgeResolvesToTheExactNameOnly() {
        func build(_ edge: Bool) -> (String?, TimelineBasis) {
            let s = stateWith([fact(d, "Acme", "2010", "2012", status: .former).at("2012-06-01"),
                               fact(d, "Acme Labs", "2011", "2013", status: .former).at("2013-06-01"),
                               fact(d, "Acme", status: .current, quote: "rejoined Acme").at("2016-06-01"),
                               fact(d, "Acme", status: .former).at("2018-12-20"),
                               fact(d, "Initech", "2019", status: .current, precededBy: edge ? "Acme" : nil).at("2019-06-01")])
            return s.beforeName("Initech")
        }
        #expect(build(true).0 != "Acme Labs")
    }

    // E3: the trust fuzz again with a contained name in play ("Acme Labs" beside "Acme").
    @Test func e3_twoUntrustedRowsNeverFirmUpAnAnswerWithContainedNames() {
        var g = R6RNG(s: 41)
        var failures: [String] = []
        func labs(_ s: R6Spec, _ g: inout R6RNG) -> R6Spec {
            guard !s.person, s.fact.name == "Globex" || (s.fact.name == "Hooli" && g.next(2) == 0) else { return s }
            var s = s
            let old = s.fact.name
            s.fact.name = "Acme Labs"
            s.fact.quote = s.fact.quote.replacingOccurrences(of: old, with: "Acme Labs")
            return s
        }
        for iter in 0..<200 where failures.count < 8 {
            let trusted = (0..<(2 + g.next(4))).map { _ in labs(R6.spec(&g, trusted: true), &g) }
            var all = trusted
            for _ in 0..<2 { all.insert(labs(R6.spec(&g, trusted: false, extra: ["Hooli"]), &g), at: g.next(all.count + 1)) }
            let base = R6.answers(R6.graph(trusted)), with = R6.answers(R6.graph(all))
            for (k, w) in with.sorted(by: { $0.key < $1.key }) where w.1 {
                if let b = base[k], b.1, b.0 == w.0 { continue }
                failures.append("#\(iter) \(k): base \(base[k]?.0 ?? "n/a") → with \(w.0) :: " + all.map(\.line).joined(separator: " | "))
            }
        }
        for f in failures.prefix(3) { Issue.record("\(f)") }
        #expect(failures.isEmpty)
    }
}
