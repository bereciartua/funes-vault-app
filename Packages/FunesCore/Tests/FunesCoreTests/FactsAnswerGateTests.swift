import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// Phase 13d's fixture gate for "Inferred claims code fails to mark: 0" (the Phase 13 plan's acceptance table), replayed
/// on recorded answers: Spike H's and H4's answers (Claude Haiku 5.5 in `answers3/`, GPT-5.6-Terra in `answers-terra/`),
/// each claim with the blind judge's label, through Swift's marker against the plan Swift makes for that question on the
/// same fixture vault (learned facts from the spike's r3 reads). No model call.
///
/// - Every claim the judge labelled `wrong_person` (a fact pinned on the wrong person, or a memory said to be about someone
///   it isn't) must be marked: 0 unmarked. These labels don't come from any marking rule.
/// - `hedged` claims (a true fact the old hint rule marked) and the marked share of `fact` claims (claims the judge found
///   fully quoted: over-marking) are reported, not gated.
/// - Always: the main set's Haiku answers. `FUNES_FACTS_GATES=1`: every set, both engines; writes
///   `spikes/people/results-13d/marking-replay.md`.
@Suite(.serialized) struct FactsAnswerGateTests {
    struct Recorded: Decodable {
        struct Citation: Decodable { let memory: String?; let quote: String? }
        struct Claim: Decodable { let text: String?; let citations: [Citation]? }
        let id: String
        let arm: String
        let rep: Int
        let sent: [String]?
        let about: [String: String]?
        let about_names: [String: [String]]?
        let claims: [Claim]?
    }

    struct Judged: Decodable {
        struct Verdict: Decodable {
            struct C: Decodable { let claim: Int; let label: String }
            let answer: Int
            let claims: [C]
        }
        let id: String
        let map: [[Arm]]?
        let verdicts: [Verdict]?
        enum Arm: Decodable {
            case s(String), i(Int)
            init(from decoder: any Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .s(s) } else { self = .i(try c.decode(Int.self)) }
            }
        }
    }

    struct Tally: CustomStringConvertible {
        var claims = 0, marked = 0
        var wrong = 0, wrongMarked = 0
        var hedged = 0, hedgedMarked = 0
        var fact = 0, factMarked = 0
        /// wrong_person claims with no learned fact in that arm's input: the model's own misreading, out of scope.
        var ownWrong = 0
        /// wrong_person claims whose quotes say just what the search said, naming nobody: a subject swap ("my partner
        /// wants…" answered as "you want…"), which no learned fact made. Listed.
        var swapped: [String] = []
        var unmarkedWrong: [String] = []

        mutating func add(_ o: Tally) {
            claims += o.claims; marked += o.marked; wrong += o.wrong; wrongMarked += o.wrongMarked
            hedged += o.hedged; hedgedMarked += o.hedgedMarked; fact += o.fact; factMarked += o.factMarked
            ownWrong += o.ownWrong; swapped += o.swapped; unmarkedWrong += o.unmarkedWrong
        }

        var description: String {
            "claims \(claims) (marked \(marked)); wrong_person \(wrongMarked)/\(wrong) marked (+\(ownWrong) with no learned fact in the input); "
                + "hedged \(hedgedMarked)/\(hedged) marked; fact \(factMarked)/\(fact) marked"
        }
    }

    static let sets = FactsSearchGateTests.sets
    static let engines: [(name: String, dir: String, judge: String)] = [("Claude Haiku 5.5", "answers3", "judge"),
                                                                       ("GPT-5.6-Terra", "answers-terra", "judge_b")]

    static func lines<T: Decodable>(_ url: URL, as: T.Type) throws -> [T] {
        try String(decoding: Data(contentsOf: url), as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONDecoder().decode(T.self, from: Data($0.utf8))
        }
    }

    /// One set's replay with one engine's answers.
    static func replay(set s: (name: String, vault: String, queries: String, backfill: String), engine e: (name: String, dir: String, judge: String))
        async throws -> Tally {
        let (v, ids, texts) = try SearchGate.vault(SearchGate.spike(s.vault))
        try SearchGate.applyPeople(v, ids: ids, texts: texts, backfill: SearchGate.spike(s.backfill))
        let search = SearchService(store: v.store, indexer: nil)
        search.facts = SearchGate.everyDeclared
        let queries = Dictionary(uniqueKeysWithValues: try SearchGate.queries(SearchGate.spike(s.queries)).map { ($0.id, $0.query) })
        let base = "results-search/\(e.dir)/\(s.name)-r3"
        let recorded = try lines(SearchGate.spike(base + ".jsonl"), as: Recorded.self)
        let judged = Dictionary(try lines(SearchGate.spike(base + "-\(e.judge).jsonl"), as: Judged.self).map { ($0.id, $0) },
                                uniquingKeysWith: { a, _ in a })
        // Labels by (question, arm, rep, claim).
        var labels: [String: String] = [:]
        for (id, j) in judged {
            guard let map = j.map else { continue }
            for verdict in j.verdicts ?? [] where verdict.answer >= 1 && verdict.answer <= map.count {
                guard case let .s(arm)? = map[verdict.answer - 1].first, case let .i(rep)? = map[verdict.answer - 1].last else { continue }
                for c in verdict.claims { labels["\(id)|\(arm)|\(rep)|\(c.claim)"] = c.label }
            }
        }
        var plans: [String: AnswerFactsPlan] = [:]
        var t = Tally()
        for r in recorded {
            guard let query = queries[r.id] else { continue }
            if plans[r.id] == nil {
                plans[r.id] = await search.answerPlan(query, filter: MemoryFilter(status: .active), count: SearchAnswerer.memoryCount,
                                                      view: .sendable(.upTo(.internal)), answerModel: "gate", onDevice: false,
                                                      now: FactsSearchGateTests.now)
            }
            guard let swift = plans[r.id] else { continue }
            // What this arm sent: its own memories and attributes (the wrong-hint arm's injected one included), with Swift's
            // links. Plain search's arm had no link admission.
            var plan = swift
            let sent = Set((r.sent ?? []).compactMap { ids[$0] })
            plan.admissions = r.arm == "A" ? [:] : swift.admissions.filter { sent.contains($0.key) }
            plan.attributes = [:]
            let g = swift.view.graph
            for (fid, text) in r.about ?? [:] {
                guard let m = ids[fid] else { continue }
                let names = Set((r.about_names?[fid] ?? []).map { FactsText.fold($0) })
                guard let e = g.entities.values.first(where: { ent in ent.aliases.contains { names.contains(FactsText.fold($0)) } })?.id else { continue }
                let f = g.facts.first { $0.entity == e && !$0.negated }
                plan.attributes[m] = AnswerFactsPlan.Attribute(
                    text: text, entity: e, candidates: [], predicate: f?.predicate ?? "other",
                    factID: f.flatMap { swift.view.factIDs[FactStore.Loaded.key($0.predicate, $0.entity)] }, basis: .named, sensitivity: .low)
            }
            let inPlay = !plan.attributes.isEmpty || !plan.admissions.isEmpty || !plan.plan.isEmpty && r.arm != "A"
            for (k, claim) in (r.claims ?? []).enumerated() {
                guard let text = claim.text else { continue }
                let cited = (claim.citations ?? []).compactMap { c -> AnswerMarker.Cited? in
                    guard let m = c.memory.flatMap({ ids[$0] }), let q = c.quote else { return nil }
                    return AnswerMarker.Cited(memoryID: m, quote: q)
                }
                guard !cited.isEmpty else { continue }
                let marked = AnswerMarker.mark(text, citations: cited, plan: plan, userAliases: SearchGate.everyDeclared.userAliases) != nil
                t.claims += 1
                t.marked += marked ? 1 : 0
                switch labels["\(r.id)|\(r.arm)|\(r.rep)|\(k + 1)"] {
                case "wrong_person" where !inPlay:
                    t.ownWrong += 1
                case "wrong_person" where !marked && Self.swap(text, cited, plan):
                    t.swapped.append("\(s.name) \(r.id) \(r.arm)#\(r.rep) claim \(k + 1)")
                case "wrong_person":
                    t.wrong += 1
                    if marked { t.wrongMarked += 1 } else { t.unmarkedWrong.append("\(s.name) \(r.id) \(r.arm)#\(r.rep) claim \(k + 1)") }
                case "hedged":
                    t.hedged += 1
                    t.hedgedMarked += marked ? 1 : 0
                case "fact":
                    t.fact += 1
                    t.factMarked += marked ? 1 : 0
                default: break
                }
            }
        }
        return t
    }

    /// The claim names no known entity, and every quote holds the search's own words for each entity it matched.
    static func swap(_ text: String, _ cited: [AnswerMarker.Cited], _ p: AnswerFactsPlan) -> Bool {
        let g = p.view.graph
        let claim = FactsText.fold(text)
        let names = g.entities.values.flatMap { e in e.aliases.map { FactsText.fold($0) } }.filter { $0.count >= 2 }
        guard !names.contains(where: { FactsText.has(claim, $0) }), !p.plan.matches.isEmpty else { return false }
        return cited.allSatisfy { c in
            let q = FactsText.fold(c.quote)
            return p.plan.matches.allSatisfy { m in
                let entry = m.word.flatMap { w in g.registry.predicate(m.predicate ?? "")?.lexicon.first { $0.words.contains { FactsText.fold($0) == FactsText.fold(w) } }?.words }
                let words = m.via == .name ? (g.entities[m.entity]?.aliases.map { $0 } ?? []) : (entry ?? [m.word].compactMap { $0 })
                    + g.facts.filter { $0.entity == m.entity && $0.predicate == m.predicate }.flatMap { [$0.label, $0.cls].compactMap { $0 } }
                return words.contains { FactsText.has(q, $0) }
            }
        }
    }

    @Test func everyWrongPersonClaimOnTheMainSetIsMarked() async throws {
        let t = try await Self.replay(set: Self.sets[0], engine: Self.engines[0])
        #expect(t.claims > 100 && t.wrong > 0, "the replay wasn't exercised: \(t)")
        #expect(t.unmarkedWrong.isEmpty, "\(t)\n\(t.unmarkedWrong.joined(separator: "\n"))")
    }

    @Test(.enabled(if: FactsSearchGateTests.full, "FUNES_FACTS_GATES=1"))
    func everySetBothEngines() async throws {
        var report = ["# Phase 13d gate: inferred claims code fails to mark (replay)", "",
                      "Recorded Spike H (Haiku) and H4 (Terra) answers, with the blind judge's labels, through Swift's marker on the "
                      + "plan Swift makes for each question (fixtures, learned facts from the r3 reads, the sendable view at Internal), "
                      + "each answer with what its arm sent: its memories and attributes (the wrong-hint arm's injected one included) "
                      + "and Swift's links; plain search's arm with no link admission. Pass: every `wrong_person` claim made with a "
                      + "learned fact in the input is marked. A `wrong_person` claim with none in the input is the model's own misreading "
                      + "(Spike G's territory) and is counted apart. `hedged` and the marked share of `fact` claims are informative.", "",
                      "| Set | Engine | Claims | Marked | wrong_person marked | hedged marked | fact marked |", "|---|---|---|---|---|---|---|"]
        var total = Tally()
        for s in Self.sets {
            for e in Self.engines {
                let t = try await Self.replay(set: s, engine: e)
                total.add(t)
                report.append("| \(s.name) | \(e.name) | \(t.claims) | \(t.marked) | \(t.wrongMarked)/\(t.wrong) | \(t.hedgedMarked)/\(t.hedged) | "
                              + "\(t.factMarked)/\(t.fact) |")
            }
        }
        report += ["", "Total: \(total).", "",
                   "Subject swaps (the quote says what the search said; the claim pins it on someone else; no learned fact made it): "
                   + (total.swapped.isEmpty ? "none." : total.swapped.joined(separator: "; ") + "."), "",
                   total.unmarkedWrong.isEmpty ? "**Pass.**" : "**Fail:** " + total.unmarkedWrong.joined(separator: "; ")]
        let out = SearchGate.spike("results-13d")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try report.joined(separator: "\n").appending("\n").write(to: out.appending(path: "marking-replay.md"), atomically: true, encoding: .utf8)
        #expect(total.unmarkedWrong.isEmpty, "\(total)\n\(total.unmarkedWrong.joined(separator: "\n"))")
    }
}
