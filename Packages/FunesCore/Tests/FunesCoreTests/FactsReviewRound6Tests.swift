import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

struct R6RNG { var s: UInt64
    mutating func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[next(a.count)] }
}

/// One memory with one fact, about work (the dated predicate) or a person (a succession person predicate).
struct R6Spec {
    var person: Bool
    var fact: ExtractedFact
    var written: String
    var trusted: Bool
    var text: String { "\(fact.quote)." }
    var line: String {
        "\(trusted ? "T" : "U") \(person ? "P:" : "")\(fact.name) s=\(fact.start ?? "-") e=\(fact.end ?? "-") \(fact.status.rawValue) w=\(written) pb=\(fact.precededBy ?? "-") q=\(fact.quote) slot=\(fact.qualifiers.values.sorted())"
    }
}

enum R6 {
    static let d = FX.dated, pp = FX.personSuccession
    static let jobs = ["Acme", "Globex", "Initech"], people = ["Ana", "Bo"]
    static let years = ["2012", "2014", "2015", "2016", "2018", "2019", "March 2019", "2020"]
    static let dates = ["2013-06-01", "2016-06-01", "2018-12-15", "2019-06-01", "2021-01-01"]

    static func spec(_ g: inout R6RNG, trusted: Bool, extra: [String] = []) -> R6Spec {
        let person = g.next(4) == 0
        let name = person ? g.pick(people) : g.pick(jobs + extra)
        let s: String? = g.next(3) > 0 ? g.pick(years) : nil
        var e: String? = g.next(3) == 0 ? g.pick(years) : nil
        if let ss = s, let ee = e, ee < ss { e = nil }
        let status = e != nil ? FactAssertion.Status.former : g.pick([.current, .former, .unknown, .unknown])
        if person { return R6Spec(person: true, fact: fact(pp, name, s, e, status: status), written: g.pick(dates), trusted: trusted) }
        let other = g.next(6) == 0 ? g.pick(jobs.filter { $0 != name }) : nil
        let quote: String? = g.next(6) == 0 ? "rejoined \(name)" : nil
        let slot: String? = g.next(4) == 0 ? g.pick([FX.emp, FX.own]) : nil
        return R6Spec(person: false, fact: fact(d, name, s, e, status: status, slot: slot, precededBy: other, quote: quote),
                      written: g.pick(dates), trusted: trusted)
    }

    static func people(_ g: FactsGraph, _ s: R6Spec) -> ([ExtractedPerson], Set<String>) {
        guard s.person else { return ([], []) }
        let known = g.byName(s.fact.name, onlyTrusted: s.trusted).first
        return ([ExtractedPerson(name: s.fact.name, person: known?.id ?? "new")], known.map { [$0.id] } ?? [])
    }

    static func graph(_ specs: [R6Spec]) -> FactsGraph {
        var g = FactsGraph(registry: FX.registry)
        for (i, s) in specs.enumerated() {
            let (ppl, roster) = people(g, s)
            g.apply(FactsMemory(id: "m\(i)", text: s.text, written: s.written, trusted: s.trusted), people: ppl, facts: [s.fact], roster: roster)
        }
        return g
    }

    static let firmT: Set<TimelineBasis> = [.ordered, .stated, .gap]
    static let firmL: Set<LinkBasis> = [.soleKnown, .statedUnique, .inferred, .named, .context]

    /// Every answer the fuzz compares: key → (names, basis, firm).
    static func answers(_ g0: FactsGraph) -> [String: (String, Bool)] {
        var g = g0
        var out: [String: (String, Bool)] = [:]
        func put(_ k: String, _ a: TimelineAnswer) {
            out[k] = ("\(a.entities.map { g0.name($0) ?? "?" }.sorted()) \(a.basis)", firmT.contains(a.basis))
        }
        for n in jobs { for id in g0.entityMatches(d, n, onlyTrusted: true).prefix(1) {
            put("before \(n)", g0.before(d, .entity(id))); put("after \(n)", g0.after(d, .entity(id)))
        } }
        for op in [TimelineIntent.Operator.current, .previous] { put("\(op)", g0.answer(TimelineIntent(predicate: d, op: op, anchor: nil))) }
        for y in [2013, 2017, 2019] {
            let r = DateRange(lo: DayNumber.from(year: y, month: 1, day: 1)!, hi: DayNumber.from(year: y, month: 12, day: 31)!, precision: .year)
            put("in \(y)", g0.inRange(d, r)); put("before \(y)", g0.before(d, .date(r))); put("after \(y)", g0.after(d, .date(r)))
        }
        let cue = FX.registry.language.dateCueWords[0]
        for t in ["At my \(cue) \(FX.word(d)) I used Emacs.", "At my \(FX.word(d)) I use Emacs.", "My \(FX.word(pp)) approved it."] {
            for w in ["2017-06-01", "2020-06-01"] {
                let mem = FactsMemory(id: "q", text: t, written: w)
                let r = g.resolve(mem, g.rolePhrases(t)[0])
                let who = r.entity.flatMap { g.entities[$0] }.map { $0.name ?? "group" } ?? "-"
                out["link '\(t)' @\(w)"] = ("\(who) \(r.basis)", firmL.contains(r.basis))
            }
        }
        return out
    }
}

@Suite struct ReviewRound6Tests {
    // A: two untrusted rows (work or people) never firm up, or change at a firm basis, a timeline answer or a link.
    @Test(arguments: [false, true]) func a_twoUntrustedRowsNeverFirmUpAnAnswer(last: Bool) {
        var g = R6RNG(s: 7)
        var failures: [String] = []
        for iter in 0..<300 where failures.count < 8 {
            let trusted = (0..<(2 + g.next(4))).map { _ in R6.spec(&g, trusted: true) }
            let untrusted = (0..<2).map { _ in R6.spec(&g, trusted: false, extra: ["Hooli"]) }
            // untrusted rows land at random places in the reading order
            var all = trusted
            for u in untrusted { all.insert(u, at: last ? all.count : g.next(all.count + 1)) }
            let base = R6.answers(R6.graph(trusted)), with = R6.answers(R6.graph(all))
            for (k, w) in with.sorted(by: { $0.key < $1.key }) where w.1 {
                if let b = base[k], b.1, b.0 == w.0 { continue }
                failures.append("#\(iter) \(k): base \(base[k]?.0 ?? "n/a") → with \(w.0) :: " + all.map(\.line).joined(separator: " | "))
            }
        }
        for f in failures.prefix(3) { Issue.record("\(f)") }
        #expect(failures.isEmpty)
    }

    // B: the user's rows win. A status with no dates decides the fact's status; a date with a selector moves the one
    // episode it overlaps and makes no new one. Untrusted rows never change that.
    @Test(arguments: [true, false]) func b_theUsersRowsWin(untrusted: Bool) {
        var g = R6RNG(s: 11)
        var failures: [String] = []
        let p = DateParser(registry: FX.registry)
        for iter in 0..<300 where failures.count < 8 {
            var specs = (0..<(1 + g.next(4))).map { _ in R6.spec(&g, trusted: true) }.filter { !$0.person }
            if untrusted, g.next(2) == 0 { specs.append(R6.spec(&g, trusted: false)) }
            specs = specs.filter { !$0.person }
            guard !specs.isEmpty else { continue }
            var s = R6.graph(specs)
            let i = g.next(s.facts.count)
            guard s.facts[i].trusted, !s.facts[i].negated else { continue }
            let desc = specs.map(\.line).joined(separator: " | ")
            func user(_ status: FactAssertion.Status, start: String? = nil, selector: DateRange? = nil) -> FactAssertion {
                var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-11-15", status: status, qualifiers: [:], states: true,
                                      quote: "", handover: false)
                a.fromUser = true; a.start = start; a.selector = selector
                return a
            }
            if g.next(2) == 0 {
                let seq = (0..<(1 + g.next(2))).map { _ in g.pick([FactAssertion.Status.current, .former]) }
                for st in seq { s.facts[i].assertions.append(user(st)) }
                let got = s.status(of: s.facts[i])
                if got != seq.last! { failures.append("#\(iter) user status \(seq.map(\.rawValue)) on \(s.name(s.facts[i].entity)!) → \(got.rawValue) :: \(desc)") }
            } else {
                let eps = s.factEpisodes(s.facts[i])
                let ep = g.pick(eps)
                guard !eps.contains(where: { $0.conflictStart || $0.conflictEnd }) else { continue }
                let sel = DateRange(lo: ep.start?.lo ?? DateRange.minDay, hi: ep.end?.hi ?? DateRange.maxDay)
                let hits = eps.filter { ($0.start?.lo ?? DateRange.minDay) <= sel.hi && sel.lo <= ($0.end?.hi ?? DateRange.maxDay) }
                let year = g.pick(["2011", "2013", "2017"])
                guard hits.count == 1, let want = p.parse(year), ep.end.map({ want.hi < $0.lo }) ?? true,
                      !eps.contains(where: { $0 !== ep && ($0.end.map { $0.hi >= want.lo } ?? true) && ($0.start.map { $0.lo <= want.hi } ?? true) })
                else { continue }
                s.facts[i].assertions.append(user(.unknown, start: year, selector: sel))
                let after = s.factEpisodes(s.facts[i])
                if after.count != eps.count || !after.contains(where: { $0.start?.lo == want.lo && $0.start?.hi == want.hi }) {
                    failures.append("#\(iter) user start \(year) sel=\(sel.lo)…\(sel.hi) on \(s.name(s.facts[i].entity)!): \(eps.count) → \(after.count) eps, starts \(after.map { $0.start?.lo ?? 0 }) :: \(desc)")
                }
            }
        }
        for f in failures.prefix(3) { Issue.record("\(f)") }
        #expect(failures.isEmpty)
    }

    // C: the store answers as the in-memory graph does, and purging the untrusted memories returns the base answers.
    @Test func c_theStoreRoundTripsAndAPurgeReturnsToTheBase() throws {
        var g = R6RNG(s: 23)
        var failures: [String] = []
        let cal = Calendar.current
        func date(_ s: String) -> Date {
            let p = s.split(separator: "-").map { Int($0)! }
            return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
        }
        for iter in 0..<30 where failures.count < 8 {
            var specs = (0..<(2 + g.next(4))).map { _ in R6.spec(&g, trusted: true) }
            for _ in 0..<(1 + g.next(2)) { specs.append(R6.spec(&g, trusted: false, extra: ["Hooli"])) }
            specs = specs.enumerated().sorted { ($0.element.written, $0.offset) < ($1.element.written, $1.offset) }.map(\.element)
            let v = try TestVault()
            var untrustedIDs: [UUID] = []
            for (i, s) in specs.enumerated() {
                let m = try v.memory("Note", s.text, now: date(s.written).addingTimeInterval(Double(i)))
                if !s.trusted {
                    try v.store.writer.write { db in try db.execute(sql: "UPDATE memory SET trust = 'untrusted' WHERE id = ?", arguments: [m.id.db]) }
                    untrustedIDs.append(m.id)
                }
                try v.store.writer.write { db in
                    let before = try FactStore.load(db).graph
                    let (ppl, roster) = R6.people(before, s)
                    var tokens: [String: String] = [:]
                    for id in roster { tokens[id] = try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [id]) }
                    let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [m.id.db])!
                    try FactStore.apply(db, memoryID: m.id.db, version: version,
                                        extraction: FactsExtraction(people: ppl, facts: [s.fact], roster: tokens),
                                        callGroup: FX.registry.predicate(s.fact.predicate)!.callGroup, now: t0.plus(minutes: Double(i)))
                }
            }
            let desc = specs.map(\.line).joined(separator: " | ")
            func compare(_ what: String, _ want: [String: (String, Bool)], _ got: [String: (String, Bool)]) {
                for (k, w) in want.sorted(by: { $0.key < $1.key }) where got[k]?.0 != w.0 {
                    failures.append("#\(iter) \(what) \(k): graph \(w.0) ≠ store \(got[k]?.0 ?? "n/a") :: \(desc)")
                    return
                }
                for k in got.keys.sorted() where want[k] == nil {
                    failures.append("#\(iter) \(what) \(k): only in store \(got[k]!.0) :: \(desc)")
                    return
                }
            }
            compare("round trip", R6.answers(R6.graph(specs)), R6.answers(try v.store.writer.read { db in try FactStore.load(db) }.graph))
            for (n, id) in untrustedIDs.enumerated() {
                _ = try v.store.deleteMemory(id: id, now: t0.plus(days: 1 + Double(n)))
                try v.store.purgeMemory(id: id, now: t0.plus(days: 2 + Double(n)))
            }
            compare("after purge", R6.answers(R6.graph(specs.filter(\.trusted))), R6.answers(try v.store.writer.read { db in try FactStore.load(db) }.graph))
        }
        for f in failures.prefix(3) { Issue.record("\(f)") }
        #expect(failures.isEmpty)
    }
}

/// Round 6, minimal cases found by the fuzz above.
@Suite struct ReviewRound6MinimalTests {
    let d = FX.dated
    let job = "At my \(FX.word(FX.dated)) I use Emacs."

    // M1: an untrusted holder makes the next trusted holder a "hand-over" (an assumed start at its memory's date), which
    // removes it from earlier dates: a trusted link goes from candidates to sole_known.
    @Test func m1_anUntrustedHolderNeverMakesATrustedHandOver() {
        func build(_ withUntrusted: Bool) -> (String?, LinkBasis) {
            var s = FactsGraph(registry: FX.registry)
            if withUntrusted {
                s.apply(FactsMemory(id: "u", text: "Globex", written: "2016-06-01", source: .agent), facts: [fact(d, "Globex", "2014", "2015", status: .former)])
            }
            s.apply(FactsMemory(id: "m0", text: "Acme", written: "2018-12-15"), facts: [fact(d, "Acme")])
            s.apply(FactsMemory(id: "m1", text: "Initech", written: "2013-06-01"), facts: [fact(d, "Initech", status: .current)])
            return s.resolveText(job, "2017-06-01")
        }
        #expect(build(true) == build(false))
    }

    // M2: the same hand-over is stored, so it outlives the untrusted memory: after its purge the link is still not the base's.
    @Test func m2_aPurgeOfTheUntrustedMemoryReturnsTheBaseLink() throws {
        func link(_ withUntrusted: Bool) throws -> (String?, LinkBasis) {
            let v = try TestVault()
            func add(_ body: String, _ f: ExtractedFact, days: Double, untrusted: Bool = false) throws -> Memory {
                let m = try v.memory("Note", body, now: t0.plus(days: days))
                try v.store.writer.write { db in
                    if untrusted { try db.execute(sql: "UPDATE memory SET trust = 'untrusted' WHERE id = ?", arguments: [m.id.db]) }
                    try FactStore.apply(db, memoryID: m.id.db, version: m.version, extraction: FactsExtraction(facts: [f]),
                                        callGroup: FX.registry.predicate(d)!.callGroup, now: t0.plus(days: days))
                }
                return m
            }
            if withUntrusted {
                let u = try add("The user was at Initech.", fact(d, "Initech", "2016", "March 2019", status: .former, quote: "Initech"), days: 0, untrusted: true)
                _ = try add("I work with Acme.", fact(d, "Acme", quote: "Acme"), days: 1)
                _ = try v.store.deleteMemory(id: u.id, now: t0.plus(days: 2))
                try v.store.purgeMemory(id: u.id, now: t0.plus(days: 3))
            } else {
                _ = try add("I work with Acme.", fact(d, "Acme", quote: "Acme"), days: 1)
            }
            var g = try v.store.writer.read { db in try FactStore.load(db) }.graph
            return g.resolveText(job, "2020-01-01")      // before the memories were written
        }
        let (base, purged) = (try link(false), try link(true))
        #expect(purged == base)
    }

    // M3: `status(of:)` reads the fact's last episode, which may be one only an untrusted memory made: a trusted
    // "former" (and the user's own "former") reads as current.
    @Test func m3_aFactsStatusNeverComesFromAnUntrustedOnlyEpisode() {
        var s = stateWith([fact(d, "Initech", "2014", status: .former).at("2016-06-01"),
                           fact(d, "Initech", "2016", quote: "rejoined Initech").untrusted(at: "2016-07-01")])
        #expect(s.status(of: s.facts[0]) == .former)
        var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-11-15", status: .former, qualifiers: [:], states: true, quote: "", handover: false)
        a.fromUser = true
        s.facts[0].assertions.append(a)
        #expect(s.status(of: s.facts[0]) == .former)
    }

    // M4: an untrusted "no longer" in a trusted episode is counted as its end when a user's selected row looks for its
    // episode (the store's check, on derived episodes, doesn't): the user's date makes a phantom second episode.
    @Test func m4_anUntrustedBoundNeverMisplacesAUsersSelectedRow() {
        var s = stateWith([fact(d, "Globex", "2020").at("2020-06-01"), fact(d, "Globex", status: .former).untrusted(at: "2019-06-01")])
        let before = s.factEpisodes(s.facts[0])
        #expect(before.count == 1 && before[0].end == nil)
        var a = FactAssertion(memoryID: "user", trusted: true, written: "2026-11-15", status: .unknown, qualifiers: [:], states: true, quote: "", handover: false)
        a.fromUser = true; a.start = "2018"; a.selector = DateRange(lo: before[0].start!.lo, hi: DateRange.maxDay)
        s.facts[0].assertions.append(a)
        let after = s.factEpisodes(s.facts[0])
        #expect(after.count == 1 && after[0].start == DateParser(registry: FX.registry).parse("2018"))
    }
}

/// Adversarial review, round 6 (GPT-6-Astra): every counterexample, as a test.
@Suite struct ReviewRound6AstraTests {
    let d = FX.dated

    @Test func g1_anUndatedReturnIsANewEpisode() {
        var s = stateWith([fact(d, "Acme", "2010", "2018", status: .former).at("2019-01-01"),
                           fact(d, "Acme", status: .current, quote: "I rejoined Acme.").at("2020-01-01"),
                           fact(d, "Initech", "2021", status: .current).at("2021-06-01")])
        #expect(s.episodes(of: "Acme").count == 2)
        #expect(s.resolveText("At my \(FX.word(d)) I use Emacs.", "2020-06-01").0 != "Initech")
    }

    @Test func g2_aLaterUserCurrentSupersedesAnEarlierUserEnd() {
        var s = stateWith([fact(d, "Acme", "2015", status: .current).at("2016-01-01")])
        var former = FactAssertion(memoryID: "user", trusted: true, written: "2026-01-01", end: "2018", status: .former,
                                   qualifiers: [:], states: true, quote: "", handover: false)
        former.fromUser = true
        var current = FactAssertion(memoryID: "user", trusted: true, written: "2026-02-01", status: .current, qualifiers: [:],
                                    states: true, quote: "", handover: false)
        current.fromUser = true
        s.facts[0].assertions += [former, current]
        #expect(s.status(of: s.facts[0]) == .current)
        #expect(s.answer(TimelineIntent(predicate: d, op: .current, anchor: nil)).entity == s.ent("Acme"))
    }

    @Test func g3_anInferredDepartureNeverGivesAStatedUniqueLink() {
        let p = FX.personExclusive
        var s = peopleState(p, [("Ana", "2015", nil, .current, "2016-01-01"), ("Bo", "2019", nil, .current, "2020-01-01")])
        let got = s.resolveText("My former \(FX.word(p)) called.", "2021-01-01")
        #expect(got.0 == "Ana" && got.1 == .inferred)
    }

    @Test func g6_anOrderRejectionCoversOnlyItsEpisodes() {
        var s = stateWith([fact(d, "Acme", "2010", "2012", status: .former), fact(d, "Initech", "2013", "2015", status: .former),
                           fact(d, "Acme", "2020", "2022", status: .former, quote: "returned to Acme in 2020"),
                           fact(d, "Globex", "2018", "2022", status: .former),
                           fact(d, "Initech", "2023", status: .current, quote: "returned to Initech in 2023")])
        let p = DateParser(registry: FX.registry)
        let acme = s.ent("Acme"), initech = s.ent("Initech")
        // The user's own edge: recent Acme → recent Initech.
        var edge = FactAssertion(memoryID: "user", trusted: true, written: "2026-01-01", status: .unknown, qualifiers: [:],
                                 states: true, quote: "", handover: false)
        edge.fromUser = true
        edge.precededByEntity = acme
        edge.otherSelector = p.parse("2021")
        edge.selector = p.parse("2023")
        let i = s.facts.firstIndex { $0.entity == initech }!
        s.facts[i].assertions.append(edge)
        #expect(s.name(s.before(d, .entity(initech), query: "before I returned to Initech").entity) == "Acme")
        // Rejecting the old edge only leaves the recent one.
        s.rejectedEdges = [FactsGraph.EdgeRejection(from: acme, to: initech, fromSelector: p.parse("2011"), toSelector: p.parse("2014"))]
        #expect(s.name(s.before(d, .entity(initech), query: "before I returned to Initech").entity) == "Acme")
        // Rejecting the recent one removes it.
        s.rejectedEdges = [FactsGraph.EdgeRejection(from: acme, to: initech, fromSelector: p.parse("2021"), toSelector: p.parse("2023"))]
        #expect(s.before(d, .entity(initech), query: "before I returned to Initech").isAmbiguous)
    }
}

@Suite struct ReviewRound6AstraStoreTests {
    let d = FX.dated
    var work: String { FX.registry.predicate(d)!.callGroup }

    @Test func g4_aUserRowKeepsTheDayItWasEntered() throws {
        let v = try TestVault()
        let m = try v.memory("Note", "I joined Acme in 2015.")
        _ = try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: m.version,
                                extraction: FactsExtraction(facts: [fact(d, "Acme", "2015", quote: "I joined Acme in 2015")]), callGroup: work, now: t0)
        }
        let fid = try #require(try v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM fact") })
        let december2018 = Date(timeIntervalSince1970: 1_545_000_000)
        _ = try v.store.writer.write { db in
            try FactStore.addUserEvidence(db, factID: fid, asserted: ["status": "former"], sensitivity: 1, now: december2018)
        }
        let g = try v.store.writer.read { db in try FactStore.load(db) }.graph
        let end = try #require(g.episodes(of: "Acme").first?.end)
        #expect(end.hi <= DayNumber.from(year: 2018, month: 12, day: 31)!)
    }

    @Test func g5_aRestoredImportStaysUndated() async throws {
        let v = try TestVault()
        let importer = ImportService(store: v.store, activity: InMemoryActivityLog())
        let export = FunesExport(format: FunesExport.formatID, exportedAt: t0, categories: [], memories: [
            FunesExport.Memory(id: UUID(), title: "Note", body: "At my previous job I used Emacs.", kind: .fact,
                               categories: ["personal_preferences"], sensitivity: .low, status: .active, expiresAt: nil,
                               createdAt: Date(timeIntervalSince1970: 1_590_000_000), updatedAt: t0, links: nil, trust: .trusted)])
        _ = try await importer.commit(try await importer.preview(funesExport: export), asMemories: true, now: t0)
        let source = try await v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT source FROM memory") }
        #expect(FactStore.source(source ?? "") == .import)
    }
}
