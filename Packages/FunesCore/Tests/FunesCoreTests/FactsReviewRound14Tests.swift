import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Adversarial review, round 14 (Fable 5.2).
@Suite struct ReviewRound14Tests {
    let d = FX.dated

    func jobs() -> FactsGraph {
        stateWith([fact(d, "Globex", "2010", "2014", status: .former), fact(d, "Acme", "2015", "2018", status: .former),
                   fact(d, "Initech", "2019", status: .current).at("2019-06-01")])
    }

    // L1: ordinary ways to ask "before/after X" put an auxiliary between the operator and the anchor ("before I was
    // at Acme", "after I'd left Acme"). The new lead-word list doesn't have them, so these aren't timeline questions any more.
    @Test func l1_ordinaryQuestionsStillAnchor() {
        let s = jobs()
        var missed: [String] = []
        for q in ["Where did I work before Acme?", "Where did I work before I joined Acme?", "Where did I work before joining Acme?",
                  "Where did I work before I was at Acme?", "Where did I work after I had left Acme?",
                  "Where did I work after I'd left Acme?", "Where did I work before I came to Acme?",
                  "Where did I work before I got to Acme?", "Where did I work before I began at Acme?",
                  "Where did I work before I was hired at Acme?", "Where did I work before my time at Acme?",
                  "¿Dónde trabajé antes de entrar en Acme?", "¿Dónde trabajé antes de estar en Acme?",
                  "¿Dónde trabajé antes de unirme a Acme?", "¿Dónde trabajé después de irme de Acme?",
                  "¿Dónde trabajé después de que dejé Acme?"] {
            var anchored = false
            if case .entity(let id)? = s.intent(q)?.anchor { anchored = s.name(id) == "Acme" }
            if !anchored { missed.append(q) }
        }
        #expect(missed.isEmpty, "\(missed)")
    }

    // L2 (probe): what the rule is for stays out, with or without the new words.
    @Test func l2_questionsAboutSomethingElseStayOut() {
        let s = jobs()
        for q in ["What was my job title before the promotion at Initech?", "What did I do before the Acme demo?",
                  "Where did I work before the reorg at Acme?", "What did I eat before the meeting with Acme?"] {
            let it = s.intent(q)
            var anchored = false
            if case .entity? = it?.anchor { anchored = true }
            #expect(!anchored, "\(q)")
        }
    }

    // L3 (probe): mayBeOpen across "current", "previous" and the date-cue link.
    @Test func l3_anOpenEpisodeIsToldEverywhere() {
        var s = stateWith([fact(d, "Acme", "2010", "2012", status: .former).at("2012-06-01"),
                           fact(d, "Acme", status: .current).at("2016-06-01"),
                           fact(d, "Initech", "2019", status: .current, slot: FX.own).at("2019-06-01")])
        #expect(s.answer(TimelineIntent(predicate: d, op: .current, anchor: nil)).isAmbiguous)
        #expect(s.answer(TimelineIntent(predicate: d, op: .previous, anchor: nil)).isAmbiguous)
        let cue = FX.registry.language.dateCueWords[0]
        #expect(s.resolveText("At my \(cue) \(FX.word(d)) I used Emacs.", "2024-06-01").1 == .candidates)
    }
}

@Suite struct ReviewRound14StoreTests {
    let v: TestVault
    let d = FX.dated
    init() throws { v = try TestVault() }

    // L4: the user fixed the name of one entity, then merged it into another. The merged-away entity's name override
    // now follows the merge and renames the survivor.
    @Test func l4_aMergedAwayEntitysNameDoesNotRenameTheSurvivor() throws {
        for (i, n) in ["Kiteworks", "KW"].enumerated() {
            let m = try v.memory("Note", "I worked at \(n).", now: t0.plus(days: Double(i)))
            try v.store.writer.write { db in
                try FactStore.apply(db, memoryID: m.id.db, version: m.version, extraction: FactsExtraction(facts: [fact(d, n, quote: n)]),
                                    callGroup: FX.registry.predicate(d)!.callGroup, now: t0.plus(days: Double(i)))
            }
        }
        func eid(_ n: String) throws -> String {
            try #require(try v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT entity_id FROM entity_alias WHERE alias = ?", arguments: [n]) })
        }
        let (kite, kw) = (try eid("Kiteworks"), try eid("KW"))
        try v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "entity", targetID: kw, field: "name", value: "K.W. West", sensitivity: 1, now: t0.plus(days: 3))
            _ = try FactStore.override(db, targetKind: "entity", targetID: kw, field: "merged_into", value: kite, sensitivity: 1, now: t0.plus(days: 4))
        }
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        #expect(g.entities[kite]?.name == "Kiteworks")
        #expect(g.entities[kite]?.aliases.contains("K.W. West") == true)     // the typed name is kept, as an alias
    }
}

/// Adversarial review, round 14 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound14AstraTests {
    @Test func o2_aPromotionDateIsNotAnEmployerAnchor() {
        let s = stateWith([fact(FX.dated, "Acme", "2010", "2019-12-31", status: .former),
                           fact(FX.dated, "Initech", "2020-01-01", status: .current)])
        #expect(s.intent("What was my job title before the promotion in 2020?") == nil)
        #expect(s.intent("Where did I work before March 20, 2020?")?.op == .before)
    }

    @Test func o1_removingAScopedCorrectionInvalidatesItsDecisions() throws {
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
        _ = try v.store.updateMemory(id: note.id, MemoryEdit(body: "Nothing about family."), now: t0.plus(days: 3))
        var g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        let mem = try #require(g.memories[q.id.db])
        let got = g.resolve(mem, g.rolePhrases(mem.text)[0])
        #expect(got.entity == ids["Ana"]!.0)
    }
}
