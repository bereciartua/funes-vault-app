import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 18 (the last, with the narrowed gate: core wrong answers or links, and confident
/// language misreads; missed answers don't count). Each finding is a test.
@Suite struct FactsReviewRound18Tests {
    let d = FX.dated

    // Astra 1 (core): a restore that skips a correction's memory touches what the correction changed, so a decision
    // resting on it is re-validated.
    @Test func aRestoreThatDropsACorrectionInvalidatesItsDecisions() throws {
        let v = try TestVault()
        let sib = try #require(FX.registry.predicates.first { p in p.objectKind == "person" && p.lexicon.filter { $0.cls != nil && $0.exclusive != true }.count >= 2 })
        let words = sib.lexicon.filter { $0.cls != nil && $0.exclusive != true }.map { $0.words[0] }
        func apply(_ m: Memory, _ x: FactsExtraction) throws {
            let cur = try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
            _ = try v.store.writer.write { db in
                try FactStore.apply(db, memoryID: m.id.db, version: cur.version, extraction: x, callGroup: sib.callGroup, now: t0)
            }
        }
        for (name, word) in [("Ana", words[0]), ("Bo", words[1])] {
            let m = try v.memory("Note", "My \(word) \(name) visited.")
            try apply(m, FactsExtraction(people: [ExtractedPerson(name: name)], facts: [fact(sib.id, name, label: word, quote: "My \(word) \(name)")]))
        }
        let ids = try v.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT a.alias, f.entity_id, f.id FROM fact f JOIN entity_alias a ON a.entity_id = f.entity_id")
                .reduce(into: [String: (String, String)]()) { $0[$1["alias"] as String] = ($1["entity_id"] as String, $1["id"] as String) }
        }
        let note = try v.memory("Note", "Bo is my \(words[0]) really.", now: t0.plus(days: 1))
        try v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "qualifier", targetID: ids["Bo"]!.1, field: "label", value: words[0], sensitivity: 1,
                                       memoryID: note.id.db, quote: "Bo is my \(words[0])", now: t0.plus(days: 1))
        }
        let q = try v.memory("Note", "My \(words[0]) likes tea.", now: t0.plus(days: 2))
        let at = try v.store.writer.read { db in
            try [ids["Ana"]!.0, ids["Bo"]!.0].reduce(into: [String: String]()) { $0[$1] = try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [$1])! }
        }
        try apply(q, FactsExtraction(roles: [ExtractedRole(phrase: 0, refersTo: ids["Bo"]!.0)], roster: at))
        let section = try #require(try v.store.writer.write { db in
            try FactsExport.section(db, exporting: Set(try String.fetchAll(db, sql: "SELECT id FROM memory")), now: t0.plus(days: 3))
        })
        let fresh = try TestVault()
        var map: [String: (id: String, version: Int)] = [:]
        for row in try v.store.writer.read({ db in try Row.fetchAll(db, sql: "SELECT id, title, body FROM memory") })
        where (row["id"] as String) != note.id.db {
            let m = try fresh.memory(row["title"] as String, row["body"] as String)
            map[row["id"] as String] = (m.id.db, m.version)
        }
        _ = try fresh.store.writer.write { db in try FactsExport.restore(db, section, memories: map, now: t0.plus(days: 4)) }
        var g = try fresh.store.writer.read { db in try FactStore.load(db).graph }
        let mem = try #require(g.memories[map[q.id.db]!.id])
        let got = g.resolve(mem, g.rolePhrases(mem.text)[0])
        #expect(got.entity == ids["Ana"]!.0)
    }

    // Astra 2–4 (language): "before leaving" and "after joining" name an event the anchor can't stand for; a question
    // whose subject isn't the user's form gets no intent; a quote opened on an earlier line still counts.
    @Test func acceptedMisreadsNowFailClosed() {
        let s = stateWith([fact(d, "EarlierCo", "2010-01-01", "2014-12-31", status: .former),
                           fact(d, "Acme", "2015-01-01", "2018-12-31", status: .former),
                           fact(d, "Initech", "2019-01-01", status: .current).at("2019-06-01")])
        for q in ["Where did I work before leaving Acme?", "Where did I work after joining Acme?",
                  "¿Dónde trabajé antes de dejar Acme?", "¿Dónde trabajé después de entrar en Acme?",
                  "Where did sam work before Acme?", "Sam’s job before Acme?", "Where did sam work in 2016?"] {
            #expect(s.intent(q)?.anchor == nil, "\(q)")
        }
        for (q, want) in [("Where did I work before joining Acme?", "EarlierCo"), ("Where did I work after leaving Acme?", "Initech"),
                          ("¿Dónde trabajé después de irme de Acme?", "Initech")] {
            #expect(s.intent(q).map { s.name(s.answer($0, query: q).entity) } == want, "\(q)")
        }
        let w = FX.word(FX.personExclusive)
        #expect(s.rolePhrases("She wrote: \"Hello.\nMy \(w) loves coffee.\"").isEmpty)
    }
}

/// Adversarial review, round 18 (Fable 5.2): the language misreads, and two new core fuzzes (clean). Fuzz sizes are
/// routine here; the review ran them at 2,000 iterations per seed and 100 vaults.
@Suite struct ReviewRound18FableTests {
    let d = FX.dated
    let pp = FX.personSuccession

    func jobs() -> FactsGraph {
        stateWith([fact(d, "Globex", "2010", "2014", status: .former), fact(d, "BBC", "2015", "2018", status: .former),
                   fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
    }

    // X1: "since", "until", "from" (and "desde", "hasta") are time prepositions, so a year after one, with no operator,
    // is accepted and read as "in that year": "since 2016" answers 2016 alone.
    @Test func x1_sinceAndUntilAreNotInThatYear() {
        let s = jobs()
        for q in ["Where did I work since 2016?", "Where did I work until 2016?", "Where did I work from 2016?",
                  "¿Dónde trabajé desde 2016?", "¿Dónde trabajé hasta 2016?"] {
            let it = s.intent(q)
            let a = it.map { s.answer($0, query: q) }
            // Either refused, or not answered as the single year.
            #expect(it == nil || it?.op != .year, "\(q)")
        }
        // "in 2016" and "during 2016" are that year.
        #expect(s.intent("Where did I work in 2016?")?.op == .year)
        #expect(s.intent("Where did I work during 2016?")?.op == .year)
        for q in ["Where did I work between 2014 and 2016?", "Where did I work from 2015 to 2019?", "¿Dónde trabajé entre 2014 y 2016?"] {
            #expect(s.intent(q)?.op == .year, "\(q)")
        }
    }

    // X2: quoted speech in guillemets (the usual quotes in Spanish) and across a line break isn't seen: the phrase is kept.
    @Test func x2_guillemetsAndMultiLineQuotesAreQuoted() {
        let s = FactsGraph(registry: FX.registry)
        let w = FX.word(pp)
        for text in ["Ana said: «my \(w) is a disaster».", "Ana dijo: «my \(w) llega tarde».",
                     "She wrote: \"I think\nmy \(w) is wrong.\"", "She wrote: “I think\nmy \(w) is wrong.”",
                     "„My \(w) is late“, said Ana."] {
            let kept = s.rolePhrases(text).contains { $0.predicate == pp }
            #expect(!kept, "\(text)")
        }
        #expect(s.rolePhrases("—Mi \(FX.word(pp)) llega tarde —dijo Ana.").isEmpty)
        #expect(s.rolePhrases("My \(w) is late.").count == 1)
    }

    // X3 (core): the trust fuzz with new seeds.
    @Test(arguments: [UInt64(101), 202, 303]) func x3_trustFuzzWithNewSeeds(seed: UInt64) {
        var g = R6RNG(s: seed)
        var failures: [String] = []
        for iter in 0..<200 where failures.count < 6 {
            let trusted = (0..<(2 + g.next(5))).map { _ in R6.spec(&g, trusted: true) }
            var all = trusted
            for _ in 0..<(1 + g.next(3)) { all.insert(R6.spec(&g, trusted: false, extra: ["Hooli"]), at: g.next(all.count + 1)) }
            let base = R6.answers(R6.graph(trusted)), with = R6.answers(R6.graph(all))
            for (k, w) in with.sorted(by: { $0.key < $1.key }) where w.1 {
                if let b = base[k], b.1, b.0 == w.0 { continue }
                failures.append("seed \(seed) #\(iter) \(k): base \(base[k]?.0 ?? "n/a") → with \(w.0) :: " + all.map(\.line).joined(separator: " | "))
            }
        }
        for f in failures { print("X3", f) }
        #expect(failures.isEmpty)
    }

    // X4 (core, store): a purge leaves no trace, in any reading order, with new seeds; and an edit that removes a
    // memory's statement leaves the vault as if that statement had never been read.
    @Test func x4_purgeAndEditLeaveNoTrace() throws {
        var g = R6RNG(s: 909)
        var failures: [String] = []
        func date(_ s: String) -> Date {
            let p = s.split(separator: "-").map { Int($0)! }
            return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
        }
        func vault(_ specs: [R6Spec]) throws -> (TestVault, [Memory]) {
            let v = try TestVault()
            var ms: [Memory] = []
            for (i, s) in specs.enumerated() {
                let m = try v.memory("Note", s.text, now: date(s.written).addingTimeInterval(Double(i)))
                ms.append(m)
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
            return (v, ms)
        }
        func answers(_ v: TestVault) throws -> [String: (String, Bool)] { R6.answers(try v.store.writer.read { db in try FactStore.load(db) }.graph) }
        for iter in 0..<20 where failures.count < 6 {
            var specs = (0..<(2 + g.next(4))).map { _ in R6.spec(&g, trusted: true) }
            for _ in 0..<(1 + g.next(2)) { specs.insert(R6.spec(&g, trusted: false, extra: ["Hooli"]), at: g.next(specs.count + 1)) }
            // one trusted memory is edited away (its text no longer states anything), the untrusted ones are purged
            let editIndex = specs.indices.filter { specs[$0].trusted }.randomElementSeeded(&g)!
            let (v, ms) = try vault(specs)
            _ = try v.store.updateMemory(id: ms[editIndex].id, MemoryEdit(body: "Nothing to see here."), now: t0.plus(days: 400))
            for (n, i) in specs.indices.filter({ !specs[$0].trusted }).enumerated() {
                _ = try v.store.deleteMemory(id: ms[i].id, now: t0.plus(days: 401 + Double(n)))
                try v.store.purgeMemory(id: ms[i].id, now: t0.plus(days: 402 + Double(n)))
            }
            let kept = specs.indices.filter { specs[$0].trusted && $0 != editIndex }.map { specs[$0] }
            let (clean, _) = try vault(kept)
            let (got, want) = (try answers(v), try answers(clean))
            for (k, w) in want.sorted(by: { $0.key < $1.key }) where got[k]?.0 != w.0 {
                failures.append("#\(iter) \(k): never-there \(w.0) ≠ after edit+purge \(got[k]?.0 ?? "n/a") :: edit=\(editIndex) " + specs.map(\.line).joined(separator: " | "))
                break
            }
            let leftover = try v.count("SELECT COUNT(*) FROM entity WHERE is_you = 0") - (try clean.count("SELECT COUNT(*) FROM entity WHERE is_you = 0"))
            if leftover != 0 { failures.append("#\(iter) entities left over: \(leftover) :: edit=\(editIndex) " + specs.map(\.line).joined(separator: " | ")) }
        }
        for f in failures { print("X4", f) }
        #expect(failures.isEmpty)
    }
}

extension Array {
    func randomElementSeeded(_ g: inout R6RNG) -> Element? { isEmpty ? nil : self[g.next(count)] }
}
