import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// The deterministic part of the timeline gates (ADR-0032's canary row: "canned extractions through resolution, timeline
/// and intent run in CI"), for 13a.2's blind sets. Each story's own per-memory labels (the facts and jobs each memory
/// states, with dates as written) are applied through the store in arrival order, at each memory's sensitivity and trust,
/// with the story's corrections as the user's operations; then every question is answered by the Swift intent and time
/// model and judged as `score_facts.judge` does. Fails on a wrong answer, a negative wording that triggers the timeline,
/// or a fact from a memory above the cloud limit in the sendable graph. Coverage is printed, not gated: the live runs
/// measure it.
///
/// It reads every `spikes/people/fixtures/canary-*/` (registry.json + stories.json) and `stories-work13.json` there are,
/// so the blind sets GPT-6-Astra writes after the code freeze run here with no code change, and always a hand-written
/// sample (a partner timeline as a data-only registry change) so the test isn't vacuous.
@Suite(.serialized) struct FactsCannedPlayTests {
    struct Fixture: Decodable {
        struct User: Decodable { let name: String; let aliases: [String] }
        struct Person: Decodable { let names: [String]; let group: [String]? }
        struct Name: Decodable { let surface: String; let person: String }
        struct Fact: Decodable {
            let person: String?
            let type: String
            let label: String?
            let status: String?
            let polarity: String?
            let start: String?
            let end: String?
            let time: String?
            let preceded_by: String?
            let followed_by: String?
        }
        struct Job: Decodable {
            let org: String
            let kind: String?
            let title: String?
            let status: String?
            let polarity: String?
            let start: String?
            let end: String?
            let time: String?
            let preceded_by: String?
            let followed_by: String?
            let also_called: String?
        }
        struct Memory: Decodable {
            let id: String
            let text: String
            let written: String
            let source: String
            let trust: String?
            let sensitivity: String?
            let names: [Name]?
            let facts: [Fact]?
            let jobs: [Job]?
            var trusted: Bool { (trust ?? (source == "agent" ? "untrusted" : "trusted")) == "trusted" }
        }
        struct Correction: Decodable {
            let after: String
            let op: String           // "reject" (Not <name> on a mention), "start" or "end" (the user's own date)
            let person: String
            let memory: String?
            let surface: String?
            let predicate: String?
            let value: String?
        }
        struct Story: Decodable {
            let id: String
            let people: [String: Person]
            let memories: [Memory]
            let orders: [[String]]?
            let timeline: [FactsHarness.Fixture.TimelineEntry]?
            let queries: [FactsHarness.Fixture.Query]?
            let corrections: [Correction]?
        }
        let user: User
        let stories: [Story]
    }

    struct Result {
        var judged: [String: Int] = [:]
        var hiddenInSendable: [String] = []
        var bad: [String] = []
    }

    /// One story in one order, through the store.
    static func play(_ story: Fixture.Story, order: [String], user: [String], registry: FactsRegistry) throws -> (FactsGraph, [String]) {
        let v = try TestVault()
        let mems = Dictionary(uniqueKeysWithValues: story.memories.map { ($0.id, $0) })
        var vaultID: [String: String] = [:]
        let timeline = Set(registry.timelinePredicates)
        let orgKind = registry.timelinePredicates.first.flatMap { registry.kindOf($0) }
        let client = registry.predicates.first { !timeline.contains($0.id) && registry.kindOf($0.id) == orgKind }?.id
        let employer = registry.predicates.first { timeline.contains($0.id) && registry.kindOf($0.id) == orgKind }?.id
        var hidden: [String] = []
        for (i, mid) in order.enumerated() {
            let m = mems[mid]!
            let (title, body) = FactsHarness.split(m.text)
            let now = FactsHarness.day(m.written)
            let mem = try v.memory(title, body, sensitivity: FactsHarness.sensitivity(m.sensitivity), now: now)
            let id = mem.id.db
            vaultID[mid] = id
            if !CloudLimit.upTo(.low).allows(FactsHarness.sensitivity(m.sensitivity)) { hidden.append(id) }
            let source = ["agent": MemorySource.agentWrite, "import": .importMarkdown][m.source] ?? .captureMac
            try v.store.writer.write { db in
                try db.execute(sql: "UPDATE memory SET source = ?, trust = ? WHERE id = ?",
                               arguments: [source.rawValue, m.trusted ? "trusted" : "untrusted", id])
            }
            let stored = FactsHarness.stored(m.text)
            try v.store.writer.write { db in
                let g = try FactStore.load(db, registry: registry, userAliases: user).graph
                func known(_ person: String) -> String? {
                    let names = Set((story.people[person]?.names ?? []).map(FactsText.fold))
                    return g.orderedEntities.first { e in e.kind == FactsValidator.personKind && !Set(e.aliases.map(FactsText.fold)).isDisjoint(with: names) }?.id
                }
                let namedHere = Dictionary((m.names ?? []).filter { !["user", "?"].contains($0.person) && stored.contains($0.surface) }
                    .map { ($0.person, $0.surface) }, uniquingKeysWith: { a, _ in a })
                var byGroup: [String: FactsExtraction] = [:]
                for (person, surface) in namedHere {
                    let p = registry.predicates.first { registry.kindOf($0.id) == FactsValidator.personKind }!.callGroup
                    byGroup[p, default: FactsExtraction()].people.append(ExtractedPerson(name: surface, person: known(person) ?? "new"))
                }
                for f in m.facts ?? [] {
                    guard let pred = registry.predicate(f.type) else { continue }
                    var entity = "name", name = ""
                    if let p = f.person {
                        // As gold_answers.py answers: someone known by their entity, else by the name this memory gives.
                        if let e = known(p) { entity = e } else if let s = namedHere[p] { name = s } else if story.people[p]?.group != nil { entity = "group" } else { continue }
                    } else { entity = f.polarity == "negative" ? "none" : "group" }
                    byGroup[pred.callGroup, default: FactsExtraction()].facts.append(ExtractedFact(
                        predicate: f.type, name: name, entity: entity, label: f.label.flatMap { stored.contains($0) ? $0 : nil }, quote: stored,
                        positive: f.polarity != "negative", status: FactAssertion.Status(rawValue: f.status ?? "") ?? .unknown,
                        time: f.time, start: f.start, end: f.end, precededBy: f.preceded_by, followedBy: f.followed_by))
                }
                for j in m.jobs ?? [] {
                    guard let pred = j.kind == "client" ? client : employer, let group = registry.predicate(pred)?.callGroup else { continue }
                    var q: [String: String] = [:]
                    let quals = registry.predicate(pred)?.qualifiers ?? [:]
                    if quals["kind"] != nil, let k = j.kind, k != "client" { q["kind"] = k }
                    if quals["title"] != nil, let t = j.title { q["title"] = t }
                    byGroup[group, default: FactsExtraction()].facts.append(ExtractedFact(
                        predicate: pred, name: j.org, quote: stored.contains(j.org) ? j.org : stored, positive: j.polarity != "negative",
                        status: FactAssertion.Status(rawValue: j.status ?? "") ?? .unknown, time: j.time, start: j.start, end: j.end,
                        precededBy: j.preceded_by, followedBy: j.followed_by, alsoCalled: j.also_called, qualifiers: q))
                }
                for (group, x) in byGroup.sorted(by: { $0.key < $1.key }) {
                    try FactStore.apply(db, memoryID: id, version: mem.version, extraction: x, callGroup: group, registry: registry,
                                        userAliases: user, now: now.addingTimeInterval(Double(i)))
                }
            }
            for c in story.corrections ?? [] where c.after == mid {
                try v.store.writer.write { db in
                    let g = try FactStore.load(db, registry: registry, userAliases: user).graph
                    let names = Set((story.people[c.person]?.names ?? []).map(FactsText.fold))
                    guard let e = g.orderedEntities.first(where: { !Set($0.aliases.map(FactsText.fold)).isDisjoint(with: names) })?.id else { return }
                    switch c.op {
                    case "reject":
                        guard let target = c.memory.flatMap({ vaultID[$0] }), let surface = c.surface else { return }
                        _ = try FactStore.decideMention(db, memoryID: target, quote: surface, entityID: e, outcome: "rejected", now: now)
                    default:
                        guard let pred = c.predicate ?? g.facts.first(where: { $0.entity == e })?.predicate, let value = c.value,
                              let fact = try String.fetchOne(db, sql: "SELECT id FROM fact WHERE entity_id = ? AND predicate = ? AND tombstone = 0",
                                                             arguments: [e, pred]) else { return }
                        _ = try FactStore.addUserEvidence(db, factID: fact, asserted: [c.op: value], sensitivity: Sensitivity.low.rawValue, now: now)
                    }
                }
            }
        }
        let (whole, sendable) = try v.store.writer.read { db in
            (try FactStore.load(db, registry: registry, userAliases: user).graph,
             try FactStore.load(db, registry: registry, userAliases: user, sendable: .upTo(.low)).graph)
        }
        let leaked = sendable.facts.flatMap(\.assertions).filter { hidden.contains($0.memoryID) }.map { "\(story.id): \($0.memoryID)" }
        return (whole, leaked)
    }

    static func run(_ fixture: Fixture, registry: FactsRegistry) throws -> Result {
        var r = Result()
        for story in fixture.stories {
            for (i, order) in ([story.memories.map(\.id)] + (story.orders ?? [])).enumerated() {
                let (g, leaked) = try play(story, order: order, user: fixture.user.aliases, registry: registry)
                r.hiddenInSendable += leaked
                for q in story.queries ?? [] {
                    let o = FactsHarness.judge(g, q, timeline: story.timeline ?? [])
                    r.judged[o, default: 0] += 1
                    if ["wrong", "triggered"].contains(o) { r.bad.append("\(story.id)#\(i) \(q.id) \(q.kind): \(o)") }
                }
            }
        }
        return r
    }

    /// Wrong answers the author accepted as known issues after a blind set was written (13e.1): each fails if it stops
    /// failing, so a fix shows. The canary's c04-q1: Ari partnered 2018 to some time in 2019, Blair from March 2019, and the
    /// user can't tell whether they overlapped; the same-year hand-over rule (H3b) answers "Ari" where the question is
    /// undecidable. The time model has no way to hold a stated possible overlap yet (plan, later work).
    static let knownIssues: [String: [(story: String, query: String, why: String)]] = [
        "canary-13a2": [("c04", "c04-q1", "same-year hand-over answers a stated possible overlap")],
    ]

    /// The blind sets present in the repo (none before GPT-6-Astra writes them after the freeze).
    static var blindSets: [(name: String, fixture: URL, registry: URL?)] {
        let dir = FactsHarness.repo.appending(path: "spikes/people/fixtures")
        var out: [(String, URL, URL?)] = []
        let fm = FileManager.default
        for d in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where d.hasPrefix("canary-") {
            let base = dir.appending(path: d)
            if fm.fileExists(atPath: base.appending(path: "stories.json").path) {
                out.append((d, base.appending(path: "stories.json"), base.appending(path: "registry.json")))
            }
        }
        let work = dir.appending(path: "stories-work13.json")
        if fm.fileExists(atPath: work.path) { out.append(("work13", work, nil)) }
        return out
    }

    @Test func everyBlindSetPlaysOnItsOwnLabelsWithNoWrongAnswer() throws {
        for set in Self.blindSets {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: set.fixture))
            let registry = try set.registry.map { try FactsRegistry.decode(Data(contentsOf: $0)) } ?? .bundled
            let r = try Self.run(fixture, registry: registry)
            print("canned play \(set.name): " + r.judged.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            let known = r.bad.filter { b in Self.knownIssues[set.name, default: []].contains { b.hasPrefix($0.story + "#") && b.contains(" \($0.query) ") } }
            #expect(r.bad.filter { !known.contains($0) }.isEmpty, "\(set.name): \(r.bad)")
            for k in Self.knownIssues[set.name, default: []] {
                withKnownIssue("\(set.name) \(k.query): \(k.why)") {
                    #expect(!known.contains { $0.hasPrefix(k.story + "#") && $0.contains(" \(k.query) ") }, "\(set.name): \(known)")
                }
            }
            #expect(r.hiddenInSendable.isEmpty, "\(set.name): \(r.hiddenInSendable)")
            #expect(r.judged.values.reduce(0, +) > 0, "\(set.name): no questions")
            // Not vacuous: on its own labels a blind set answers some decidable question right (coverage is the live gate's).
            #expect(r.judged["right", default: 0] + r.judged["right_gap", default: 0] > 0, "\(set.name): nothing answered right")
        }
    }

    /// The hand-written sample: the partner timeline as a data-only registry change, with successive partners, an agent's
    /// note that tries to end one, a restricted memory, a rejection, and negative wordings.
    @Test func theSampleCanaryPlaysAndIsntVacuous() throws {
        let pe = FX.personExclusive
        let registry = try FX.registry { json in
            FX.editPredicate(&json, pe) { p in
                p["uses"] = ["recorded", "linked", "timeline"]
                p["exclusive"] = false
                p["gap_months"] = 12
                p["query_cues"] = (p["query_cues"] as? [String] ?? []) + ["dating", "dated"]
            }
        }
        // The owner's own timeline counts the restricted memory (Cy, 2020); only cloud inputs leave it out.
        let sample = """
        {"user": {"name": "Ari Castell", "aliases": ["Ari Castell", "Ari"]}, "stories": [{"id": "s1", "people": {
          "ada": {"names": ["Ada"]}, "bea": {"names": ["Bea"]}, "cy": {"names": ["Cy"]}},
         "memories": [
          {"id": "m1", "text": "I started dating Ada in January 2018.", "written": "2018-05-01", "source": "capture",
           "names": [{"surface": "Ada", "person": "ada"}], "facts": [{"person": "ada", "type": "\(pe)", "status": "current", "start": "January 2018"}]},
          {"id": "m2", "text": "Ada and I broke up in 2019.", "written": "2019-09-01", "source": "capture",
           "names": [{"surface": "Ada", "person": "ada"}], "facts": [{"person": "ada", "type": "\(pe)", "status": "former", "end": "2019"}]},
          {"id": "m3", "text": "I started dating Bea in 2021.", "written": "2021-03-01", "source": "capture",
           "names": [{"surface": "Bea", "person": "bea"}], "facts": [{"person": "bea", "type": "\(pe)", "status": "current", "start": "2021"}]},
          {"id": "m4", "text": "Ari and Bea split up in 2022, says a note.", "written": "2022-01-01", "source": "agent",
           "names": [{"surface": "Bea", "person": "bea"}], "facts": [{"person": "bea", "type": "\(pe)", "status": "former", "end": "2022"}]},
          {"id": "m5", "text": "I was dating Cy in 2020, privately.", "written": "2023-01-01", "source": "capture", "sensitivity": "restricted",
           "names": [{"surface": "Cy", "person": "cy"}], "facts": [{"person": "cy", "type": "\(pe)", "status": "former", "start": "2020", "end": "2020"}]}],
         "orders": [["m3", "m1", "m2", "m5", "m4"]],
         "timeline": [{"org": "Ada", "kind": "partner"}, {"org": "Bea", "kind": "partner"}, {"org": "Cy", "kind": "partner"}],
         "queries": [
          {"id": "q1", "kind": "before", "query": "Who was I dating before Bea?", "answer_org": "Cy"},
          {"id": "q2", "kind": "after", "query": "Who was I dating after Ada?", "answer_org": "Cy"},
          {"id": "q3", "kind": "negative", "query": "What did Bea do before moving to Lisbon?", "answer_org": ""},
          {"id": "q4", "kind": "year", "query": "Who was I dating in 2018?", "answer_org": "Ada"}],
         "corrections": [{"after": "m3", "op": "reject", "person": "ada", "memory": "m3", "surface": "dating Bea"}]}]}
        """
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(sample.utf8))
        let r = try Self.run(fixture, registry: registry)
        #expect(r.bad.isEmpty, "\(r.bad)")
        #expect(r.hiddenInSendable.isEmpty, "\(r.hiddenInSendable)")
        #expect(r.judged["right", default: 0] + r.judged["right_gap", default: 0] >= 1, "\(r.judged)")
        #expect(r.judged["quiet", default: 0] == 2, "\(r.judged)")
    }
}
