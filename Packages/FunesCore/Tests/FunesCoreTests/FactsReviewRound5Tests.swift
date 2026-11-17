import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

struct LCG { var s: UInt64
    mutating func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[next(a.count)] }
}

/// Adversarial review, round 5 (Fable 5.2): a differential fuzz. Adding one untrusted row to trusted rows must never
/// make a timeline answer or a link firmer, or change it at a firm basis.
@Suite struct ReviewRound5Tests {
    let d = FX.dated
    static let names = ["Acme", "Globex", "Initech"]

    func row(_ g: inout LCG, _ name: String) -> (ExtractedFact, String) {
        let years = ["2012", "2014", "2015", "2016", "2018", "2019", "March 2019", "2020"]
        let s: String? = g.next(3) > 0 ? g.pick(years) : nil
        var e: String? = g.next(3) == 0 ? g.pick(years) : nil
        if let ss = s, let ee = e, ee < ss { e = nil }
        let status = g.pick([FactAssertion.Status.current, .former, .unknown, .unknown])
        let other = g.next(6) == 0 ? g.pick(Self.names.filter { $0 != name }) : nil
        let quote: String? = g.next(6) == 0 ? "rejoined \(name)" : nil
        let slot: String? = g.next(4) == 0 ? g.pick([FX.emp, FX.own]) : nil
        let f = fact(d, name, s, e, status: e != nil ? .former : status, slot: slot, precededBy: other, quote: quote)
        return (f, g.pick(["2013-06-01", "2016-06-01", "2018-12-15", "2019-06-01", "2021-01-01"]))
    }

    @Test func z1_oneUntrustedRowNeverFirmsUpAnAnswer() {
        var g = LCG(s: 42)
        var failures: [String] = []
        let firmT: Set<TimelineBasis> = [.ordered, .stated, .gap]
        let firmL: Set<LinkBasis> = [.soleKnown, .statedUnique, .inferred, .named, .context]
        let cue = FX.registry.language.dateCueWords[0]
        let texts = ["At my \(cue) \(FX.word(d)) I used Emacs.", "At my \(FX.word(d)) I use Emacs."]
        for iter in 0..<400 where failures.count < 60 {
            var trusted: [FactRow] = []
            for _ in 0..<(2 + g.next(4)) { let (f, w) = row(&g, g.pick(Self.names)); trusted.append(f.at(w)) }
            let (uf, uw) = row(&g, g.pick(Self.names + ["Hooli"]))
            var base = stateWith(trusted), with = stateWith(trusted + [uf.untrusted(at: uw)])
            func desc() -> String {
                (trusted + [uf.untrusted(at: uw)]).map { r in
                    "\(r.trusted ? "T" : "U") \(r.fact.name) s=\(r.fact.start ?? "-") e=\(r.fact.end ?? "-") \(r.fact.status.rawValue) w=\(r.written) pb=\(r.fact.precededBy ?? "-") q=\(r.fact.quote) slot=\(r.fact.qualifiers)"
                }.joined(separator: " | ")
            }
            func check(_ what: String, _ b: TimelineAnswer, _ w: TimelineAnswer) {
                let bn = b.entities.map { base.name($0) ?? "?" }, wn = w.entities.map { with.name($0) ?? "?" }
                if firmT.contains(w.basis), !(bn == wn && firmT.contains(b.basis)) {
                    failures.append("#\(iter) \(what): base \(bn) \(b.basis) → with \(wn) \(w.basis) :: \(desc())")
                }
            }
            for n in Self.names where !base.entityMatches(d, n).isEmpty && !with.entityMatches(d, n).isEmpty {
                check("before \(n)", base.before(d, .entity(base.ent(n))), with.before(d, .entity(with.ent(n))))
                check("after \(n)", base.after(d, .entity(base.ent(n))), with.after(d, .entity(with.ent(n))))
            }
            for op in [TimelineIntent.Operator.current, .previous] {
                let it = TimelineIntent(predicate: d, op: op, anchor: nil)
                check("\(op)", base.answer(it), with.answer(it))
            }
            for y in [2013, 2017, 2019] {
                let r = DateRange(lo: DayNumber.from(year: y, month: 1, day: 1)!, hi: DayNumber.from(year: y, month: 12, day: 31)!, precision: .year)
                check("in \(y)", base.inRange(d, r), with.inRange(d, r))
                check("before \(y)", base.before(d, .date(r)), with.before(d, .date(r)))
                check("after \(y)", base.after(d, .date(r)), with.after(d, .date(r)))
            }
            for t in texts { for w in ["2017-06-01", "2020-06-01"] {
                let b = base.resolveText(t, w), x = with.resolveText(t, w)
                if firmL.contains(x.1), !(b.0 == x.0 && firmL.contains(b.1)) {
                    failures.append("#\(iter) link '\(t)' @\(w): base \(b) → with \(x) :: \(desc())")
                }
            } }
        }
        for f in failures.prefix(5) { Issue.record("\(f)") }
        #expect(failures.isEmpty)
    }
}

/// Round 5, minimal cases found by the fuzz above.
@Suite struct ReviewRound5MinimalTests {
    let d = FX.dated
    let current = TimelineIntent(predicate: FX.dated, op: .current, anchor: nil)

    // Y1: an untrusted episode that starts between two trusted jobs is the "next one", and aborts succession: the
    // stale trusted job stays current at `ordered`.
    @Test func y1_anUntrustedNextEpisodeNeverBlocksSuccession() {
        let trusted: [FactRowConvertible] = [fact(d, "Acme", "2012", status: .current).at("2013-06-01"),
                                             fact(d, "Initech", "2020", status: .current).at("2020-06-01")]
        let base = stateWith(trusted)
        let with = stateWith(trusted + [fact(d, "Hooli", "2018", "2019", status: .former).untrusted(at: "2019-06-01")])
        let (b, w) = (base.answer(current), with.answer(current))
        #expect(w.entities.map { with.name($0)! } == b.entities.map { base.name($0)! } || w.basis != .ordered)
    }

    // Y2: an untrusted episode counts as "concurrent" and blocks succession the same way.
    @Test func y2_anUntrustedConcurrentEpisodeNeverBlocksSuccession() {
        let trusted: [FactRowConvertible] = [fact(d, "Acme", "2012", status: .current).at("2013-06-01"),
                                             fact(d, "Initech", "2020", status: .current).at("2020-06-01")]
        let base = stateWith(trusted)
        let with = stateWith(trusted + [fact(d, "Hooli", "2010", status: .former).untrusted(at: "2021-01-01")])
        let (b, w) = (base.answer(current), with.answer(current))
        #expect(w.entities.map { with.name($0)! } == b.entities.map { base.name($0)! } || w.basis != .ordered)
    }

    // Y3: two trusted order edges contradict each other (a cycle: both dropped). An untrusted-only second episode of
    // one entity makes one edge undecidable ("which episode?"), so the cycle is gone and the other edge answers `stated`.
    @Test func y3_anUntrustedEpisodeNeverBreaksAnEdgeCycle() {
        let trusted: [FactRowConvertible] = [fact(d, "Globex", "2012", "2019", status: .former, precededBy: "Initech"),
                                             fact(d, "Initech", status: .current, precededBy: "Globex").at("2021-01-01")]
        let base = stateWith(trusted)
        let with = stateWith(trusted + [fact(d, "Globex", "2020").untrusted(at: "2020-06-01")])
        #expect(with.afterName("Initech") == base.afterName("Initech"))
    }
}

/// Adversarial review, round 5 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound5AstraTests {
    let d = FX.dated

    @Test func f1_anUndatedConcurrentEpisodeBlocksSuccession() {
        let s = stateWith([fact(d, "Globex", status: .current, slot: FX.emp).at("2018-01-01"),
                           fact(d, "Acme", "2015", status: .current, slot: FX.emp).at("2018-01-01"),
                           fact(d, "Initech", "2020", status: .current, slot: FX.emp).at("2021-01-01")])
        #expect(!s.episodes(of: "Acme")[0].inferredEnd)
        #expect(s.before(d, .entity(s.ent("Initech"))).isAmbiguous)
    }

    @Test func f2_aSharedAnchorNameIsNotGuessed() {
        var s = stateWith([fact(d, "Acme", "2010", "2012", status: .former), fact(d, "Northstar", "2013", "2014", status: .former),
                           fact(d, "Globex", "2015", "2018", status: .former), fact(d, "Weststar", "2019", status: .current)])
        s.addAlias(s.ent("Northstar"), "Star", trusted: true)
        s.addAlias(s.ent("Weststar"), "Star", trusted: true)
        let q = "What was my job before Star?"
        if let it = s.intent(q) { #expect(s.answer(it, query: q).isAmbiguous) }
    }

    @Test func f3_anUncertainCurrentAlsoBlocksPrevious() {
        let s = stateWith([fact(d, "Acme", "2010", "2018", status: .former, slot: FX.emp),
                           fact(d, "Initech", "2019", status: .current, slot: FX.emp).at("2019-06-01"),
                           fact(d, "Globex", "2000", "2002", status: .former, slot: FX.own),
                           fact(d, "Globex", "2020", status: .current, slot: FX.own).at("2020-06-01"),
                           fact(d, "Globex", status: .former, slot: FX.own).at("2021-01-01")])
        #expect(s.answer(TimelineIntent(predicate: d, op: .current, anchor: nil)).isAmbiguous)
        #expect(s.answer(TimelineIntent(predicate: d, op: .previous, anchor: nil)).isAmbiguous)
    }

    @Test func f6_aLaterUserStatusSupersedesAnEarlierOne() {
        var s = stateWith([fact(d, "Acme", "2015", status: .current).at("2016-01-01")])
        for status in [FactAssertion.Status.former, .current] {
            var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-11-15", status: status, qualifiers: [:], states: true,
                                  quote: "", handover: false)
            a.fromUser = true
            s.facts[0].assertions.append(a)
        }
        #expect(s.status(of: s.facts[0]) == .current)
    }
}

@Suite struct ReviewRound5AstraStoreTests {
    let d = FX.dated
    var work: String { FX.registry.predicate(d)!.callGroup }

    func apply(_ v: TestVault, _ m: Memory, _ x: FactsExtraction) throws {
        _ = try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: m.version, extraction: x, callGroup: work, now: t0)
        }
    }

    @Test func f4_aRestoreKeepsTheAnswers() async throws {
        let v = try TestVault()
        let a = try v.memory("Note", "I joined Acme in 2015 and work there.", now: Date(timeIntervalSince1970: 1_452_000_000))  // 2016
        try apply(v, a, FactsExtraction(facts: [fact(d, "Acme", "2015", status: .current, slot: FX.emp, quote: "I joined Acme in 2015")]))
        let b = try v.memory("Note", "I joined Initech in 2019 and work there.", now: Date(timeIntervalSince1970: 1_580_000_000))  // 2020
        try apply(v, b, FactsExtraction(facts: [fact(d, "Initech", "2019", status: .current, slot: FX.emp, quote: "I joined Initech in 2019")]))
        let it = TimelineIntent(predicate: d, op: .current, anchor: nil)
        let before = try await v.store.writer.read { db in try FactStore.load(db).graph }
        let export = try ImportParser.funesExport(try await ImportService(store: v.store, activity: InMemoryActivityLog()).export(now: t0))
        let fresh = try TestVault()
        let importer = ImportService(store: fresh.store, activity: InMemoryActivityLog())
        _ = try await importer.commit(try await importer.preview(funesExport: export), asMemories: true, now: t0.plus(days: 400))
        let after = try await fresh.store.writer.read { db in try FactStore.load(db).graph }
        #expect(before.answer(it).entities.map { before.name($0) } == after.answer(it).entities.map { after.name($0) })
        #expect(after.answer(it).entities.count == 1)
    }

    @Test func f5_aRejectedOrderEdgeIsGone() async throws {
        let v = try TestVault()
        for (text, f) in [("I worked at Acme from 2015 to 2018.", fact(d, "Acme", "2015", "2018", status: .former, quote: "I worked at Acme from 2015 to 2018")),
                          ("I worked at Globex from 2016 to 2018.", fact(d, "Globex", "2016", "2018", status: .former, quote: "I worked at Globex from 2016 to 2018")),
                          ("After Acme I joined Initech in 2019.", fact(d, "Initech", "2019", precededBy: "Acme", quote: "After Acme I joined Initech in 2019"))] {
            try apply(v, try v.memory("Note", text), FactsExtraction(facts: [f]))
        }
        var g = try await v.store.writer.read { db in try FactStore.load(db).graph }
        #expect(g.beforeName("Initech") == ("Acme", .stated))
        let ids = try await v.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT f.id, a.alias FROM fact f JOIN entity_alias a ON a.entity_id = f.entity_id")
                .map { ($0["alias"] as String, $0["id"] as String) }
        }
        let acme = ids.first { $0.0 == "Acme" }!.1
        let initech = ids.first { $0.0 == "Initech" }!.1
        try await v.store.writer.write { db in
            _ = try FactStore.override(db, targetKind: "order", targetID: initech, field: "rejected", value: ["before": acme, "after": initech],
                                       sensitivity: 1, now: t0)
        }
        g = try await v.store.writer.read { db in try FactStore.load(db).graph }
        #expect(g.before(d, .entity(g.ent("Initech"))).isAmbiguous)
    }
}
