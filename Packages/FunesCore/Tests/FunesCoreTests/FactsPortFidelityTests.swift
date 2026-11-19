import Foundation
import Testing
@testable import FunesCore

/// Port fidelity on Spike H2's timeline (Phase 13a.2 Gates; the acceptance row names "Spike H2's timeline"). H2's own
/// extraction of the work fixture (`spikes/people/results-search/work-extract-fixture.jsonl`) is applied as the work call
/// group would have returned it, exactly as `score_facts.convert` applies it to facts.py, and every `work-queries.json`
/// question is judged by the Swift time model and intent (`FactsHarness.judge`, which is `score_facts.judge`). Each
/// judgment must equal facts.py's (`results-13a2/h2-timeline-python.json`, written by `port_fidelity.py --h2`), unless
/// `port_fidelity_known.json` lists the difference with its rule.
@Suite struct FactsPortFidelityTests {
    struct Job: Decodable {
        let org: String
        let role: String?
        let status: String?
        let start: String?
        let end: String?
        let before: String?
        let after: String?
        let kind: String?
        let also_called: String?
        let quote: String
    }
    struct Record: Decodable { let id: String; let jobs: [Job]; let written: String; let trust: String? }
    struct VaultMemory: Decodable { let id: String; let title: String; let body: String }
    struct Vault: Decodable { let memories: [VaultMemory] }
    struct Queries: Decodable {
        let timeline: [FactsHarness.Fixture.TimelineEntry]
        let queries: [FactsHarness.Fixture.Query]
    }

    static let people = FactsHarness.repo.appending(path: "spikes/people")

    /// H2's extraction applied to a graph, as `score_facts.convert` does.
    static func h2Graph() throws -> FactsGraph {
        let reg = FactsRegistry.bundled
        let employer = try #require(reg.timelinePredicates.first)
        let client = reg.predicates.first { $0.id != employer && reg.kindOf($0.id) == reg.kindOf(employer) && !$0.uses.contains("linked") }?.id
        let qualifiers = Set(reg.predicate(employer)?.qualifiers.keys.map { $0 } ?? [])
        let vault = try JSONDecoder().decode(Vault.self, from: Data(contentsOf: people.appending(path: "fixtures/work-vault.json")))
        let text = Dictionary(uniqueKeysWithValues: vault.memories.map { ($0.id, $0.title + "\n" + $0.body) })
        var g = FactsGraph(registry: reg)
        let lines = try String(contentsOf: people.appending(path: "results-search/work-extract-fixture.jsonl"), encoding: .utf8)
        for line in lines.split(separator: "\n") {
            let r = try JSONDecoder().decode(Record.self, from: Data(line.utf8))
            var facts: [ExtractedFact] = []
            for j in r.jobs {
                guard let pred = j.kind == "client" ? client : employer else { continue }
                var q: [String: String] = [:]
                if pred == employer {
                    if qualifiers.contains("kind"), let k = j.kind, k != "client" { q["kind"] = k }
                    if qualifiers.contains("title"), let t = j.role { q["title"] = t }
                }
                facts.append(ExtractedFact(predicate: pred, name: j.org, quote: j.quote,
                                           status: FactAssertion.Status(rawValue: j.status ?? "") ?? .unknown,
                                           start: j.start, end: j.end, precededBy: j.after, followedBy: j.before,
                                           alsoCalled: j.also_called, qualifiers: q))
            }
            let mem = FactsMemory(id: r.id, text: text[r.id] ?? "", written: String(r.written.prefix(10)), source: .capture,
                                  trusted: (r.trust ?? "trusted") == "trusted")
            g.apply(mem, facts: facts)
        }
        return g
    }

    /// facts.py's intent for a question (`h2-timeline-python.json`'s `intents`) as a Swift intent on this graph.
    static func intent(_ raw: Any?, _ g: FactsGraph) -> TimelineIntent? {
        guard let a = raw as? [Any], a.count == 3, let pred = a[0] as? String, let opName = a[1] as? String,
              let op = TimelineIntent.Operator(rawValue: opName) else { return nil }
        guard let anchor = a[2] as? [String: Any] else { return TimelineIntent(predicate: pred, op: op, anchor: nil) }
        if let name = anchor["entity"] as? String {
            let hits = g.entityMatches(pred, name)
            return TimelineIntent(predicate: pred, op: op, anchor: hits.count == 1 ? .entity(hits[0]) : nil)
        }
        guard let d = anchor["date"] as? [Any], d.count == 3, let lo = d[0] as? Int, let hi = d[1] as? Int else { return nil }
        let precision = DateRange.Precision(rawValue: d[2] as? String ?? "") ?? .day
        return TimelineIntent(predicate: pred, op: op, anchor: .date(DateRange(lo: lo, hi: hi, precision: precision)))
    }

    /// Each question judged twice by Swift: as it parses it (the grammar), and with facts.py's intent supplied (the time
    /// model alone). Written to `build/facts-harness/h2-timeline-swift.json` for port_fidelity.py, which compares both with
    /// facts.py's judgments; here, the time model must agree with facts.py wherever facts.py had an intent, and no
    /// judgment is ever wrong or a triggered negative.
    @Test func spikeH2sTimelineIsJudgedAsFactsPyJudgesIt() throws {
        let g = try Self.h2Graph()
        let data = try JSONDecoder().decode(Queries.self, from: Data(contentsOf: Self.people.appending(path: "fixtures/work-queries.json")))
        let file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Self.people.appending(
            path: "results-13a2/h2-timeline-python.json"))) as? [String: Any])
        let python = file["judged"] as? [String: String] ?? [:], intents = file["intents"] as? [String: Any] ?? [:]
        let known = try FactsHarness.knownPortDifferences()
        var own: [String: String] = [:], supplied: [String: String] = [:], differ: [String] = []
        for q in data.queries where python[q.id] != nil {
            own[q.id] = FactsHarness.judge(g, q, timeline: data.timeline)
            #expect(!["wrong", "triggered"].contains(own[q.id]!), "\(q.id): \(own[q.id]!)")
            guard let raw = intents[q.id] else { continue }
            let s = FactsHarness.judge(g, q, timeline: data.timeline, intent: Self.intent(raw, g))
            supplied[q.id] = s
            let k = known["h2 time-model - \(q.id)"]
            if s != python[q.id], !(k?.python == python[q.id] && k?.swift == s) { differ.append("\(q.id): facts.py \(python[q.id]!), Swift's time model \(s)") }
        }
        #expect(own.count == python.count && own.count >= 30)
        #expect(differ.isEmpty, "\(differ)")
        let out = FactsHarness.repo.appending(path: "build/facts-harness")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["judged": own, "with_python_intent": supplied], options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appending(path: "h2-timeline-swift.json"))
    }
}

