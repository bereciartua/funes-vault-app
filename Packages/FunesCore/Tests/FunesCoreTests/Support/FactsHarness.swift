import Foundation
import FunesProtocol
import GRDB
import Synchronization
@testable import FunesCore

/// The facts fixture harness (Phase 13a.2): plays the spike's story fixtures (`spikes/people/fixtures/stories*.json`)
/// through a fresh vault, `FactsExtractor` and `ModelRouter`, and writes what the spike's scorers read:
/// `run_facts.py`'s `dump_people` lines with a `state` (`dump_state`), so `score.py` and `score_facts.py stories` score
/// them unchanged. Timeline questions are also answered by the Swift `TimelineIntent` and `Timeline` and judged as
/// `score_facts.judge` does, so the time model measured is Swift's, not Python's.
///
/// Providers: `replay` (the spike's recorded outputs, exported by `spikes/people/export_replay.py`, in their recorded
/// order and modes), and `live` (a real model, only with the author's go-ahead).
enum FactsHarness {
    // MARK: Fixtures

    struct Fixture: Decodable {
        struct User: Decodable { let name: String; let aliases: [String] }
        struct Memory: Decodable {
            let id: String
            let text: String
            let written: String
            let source: String
            let trust: String?
        }
        struct Query: Decodable {
            let id: String
            let kind: String
            let query: String
            let answer_org: String?
        }
        struct TimelineEntry: Decodable { let org: String?; let kind: String? }
        struct Story: Decodable {
            let id: String
            let memories: [Memory]
            let orders: [[String]]?
            let queries: [Query]?
            let timeline: [TimelineEntry]?
        }
        let user: User
        let stories: [Story]
    }

    static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func fixture(_ set: String) throws -> Fixture {
        let name = set == "main" ? "stories" : "stories-\(set)"
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: repo.appending(path: "spikes/people/fixtures/\(name).json")))
    }

    // MARK: Recorded calls (export_replay.py)

    struct Recorded: @unchecked Sendable {
        let story: String
        let orderIndex: Int
        let memory: String
        let group: String
        let mode: String
        let raw: [String: Any]
        /// The Python roster then: id → (name, aliases, group, kind).
        let roster: [String: [String: Any]]
        let line: [String: Any]

        init(_ d: [String: Any]) {
            story = d["story"] as! String
            orderIndex = d["orderIndex"] as! Int
            memory = d["memory"] as! String
            group = d["group"] as! String
            mode = d["mode"] as! String
            raw = d["raw"] as! [String: Any]
            roster = d["roster"] as? [String: [String: Any]] ?? [:]
            line = d
        }
    }

    static func recorded(_ url: URL) throws -> [Recorded] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            Recorded(try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])
        }
    }

    /// Replays recorded outputs. The harness sets which recorded call is next; a call the recording doesn't have (a
    /// Swift-only re-ask) gets that memory and group's latest output. Python roster ids become the Swift roster's by
    /// the entity's exact alias set, or its role group.
    final class Replay: GenerationProvider, @unchecked Sendable {
        let id: ProviderID = "anthropic"
        let locality: Locality = .cloud
        let modelID = "claude-haiku-replay"

        struct Part { var raw: [String: Any]; var roster: [String: [String: Any]] }
        struct Sources { var people, facts, roles, things: Part }
        private let state = Mutex<(next: Recorded?, reask: String?, sources: [String: Sources], unmapped: Int, served: Int, reasks: Int)>(
            (nil, nil, [:], 0, 0, 0))

        var unmapped: Int { state.withLock { $0.unmapped } }
        var reasks: Int { state.withLock { $0.reasks } }

        func expect(_ r: Recorded) { state.withLock { $0.next = r; $0.reask = nil } }
        /// A Swift-only re-ask of a fixture memory in a group: served with its latest recorded output.
        func reask(_ memory: String, _ group: String) { state.withLock { $0.next = nil; $0.reask = memory + "\u{1F}" + group } }

        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let swift = Self.parseRoster(request.prompt)
            let data: Data = try state.withLock { s in
                let key: String
                if let r = s.next {
                    key = r.memory + "\u{1F}" + r.group
                    let part = Part(raw: r.raw, roster: r.roster)
                    var src = s.sources[key] ?? Sources(people: part, facts: part, roles: part, things: part)
                    switch r.mode {
                    case "roles": src.roles = part              // the spike applied only the roles of a roles re-ask
                    case "names": src.people = part             // and only the names of a names re-ask
                    default: src = Sources(people: part, facts: part, roles: part, things: part)
                    }
                    s.sources[key] = src
                    s.next = nil
                    s.served += 1
                } else {
                    guard let k = s.reask, s.sources[k] != nil else { throw ProviderError.invalidOutput }
                    key = k
                    s.reasks += 1
                }
                let src = s.sources[key]!
                var unmapped = 0
                func tr(_ v: Any?, _ part: Part) -> Any? {
                    guard let id = v as? String, id.range(of: "^p\\d+$", options: .regularExpression) != nil else { return v }
                    guard let e = part.roster[id] else { return id }     // not in the spike's roster either: dropped by both
                    if let mapped = Self.translate(e, swift) { return mapped }
                    unmapped += 1
                    return id
                }
                func list(_ k: String, _ part: Part, _ field: String) -> [[String: Any]] {
                    (part.raw[k] as? [[String: Any]] ?? []).map { item in
                        var item = item
                        item[field] = tr(item[field], part)
                        return item
                    }
                }
                var out: [String: Any] = [
                    "facts": list("facts", src.facts, "entity"), "roles": list("roles", src.roles, "refers_to"),
                    "things": src.things.raw["things"] ?? [],
                ]
                if request.schema.json.contains("\"people\"") { out["people"] = list("people", src.people, "person") }
                s.unmapped += unmapped
                return try JSONSerialization.data(withJSONObject: out)
            }
            return (try HTTPClient.decode(String(decoding: data, as: UTF8.self), as: T.self), ProviderUsage(requests: 1))
        }

        /// The Swift roster's lines: `e…` → (aliases, or a role group's label and predicate).
        static func parseRoster(_ prompt: String) -> [(id: String, aliases: Set<String>?, group: (String, String)?)] {
            var out: [(String, Set<String>?, (String, String)?)] = []
            for line in prompt.split(separator: "\n").map(String.init) where line.hasPrefix("- e") {
                let body = line.dropFirst(2)
                guard let colon = body.range(of: ": ") else { continue }
                let id = String(body[..<colon.lowerBound]), rest = String(body[colon.upperBound...])
                if let m = rest.range(of: "^unnamed (.+) \\(([a-z_]+)(, count \\d+)?\\)$", options: .regularExpression) {
                    let s = String(rest[m])
                    let label = s.dropFirst("unnamed ".count).components(separatedBy: " (")[0]
                    let pred = s.components(separatedBy: " (").last!.components(separatedBy: CharacterSet(charactersIn: ",)"))[0]
                    out.append((id, nil, (pred, label)))
                } else if let dash = rest.range(of: " — ") {
                    out.append((id, Set(rest[..<dash.lowerBound].components(separatedBy: ", ")), nil))
                }
            }
            return out
        }

        static func translate(_ e: [String: Any], _ swift: [(id: String, aliases: Set<String>?, group: (String, String)?)]) -> String? {
            if let g = e["group"] as? [Any], e["name"] is NSNull || e["name"] == nil, let pred = g.first as? String {
                let label = (g.count > 1 ? g[1] as? String : nil) ?? pred
                let hits = swift.filter { $0.group.map { $0.0 == pred && $0.1 == label } ?? false }
                return hits.count == 1 ? hits[0].id : nil
            }
            let aliases = Set(e["aliases"] as? [String] ?? [])
            let exact = swift.filter { $0.aliases == aliases }
            if exact.count == 1 { return exact[0].id }
            guard let name = e["name"] as? String else { return nil }
            let loose = swift.filter { $0.aliases?.contains(name) ?? false }
            return loose.count == 1 ? loose[0].id : nil
        }
    }

    // MARK: Playing a story

    struct Play {
        var line: [String: Any]
        var judged: [(id: String, outcome: String)]
        var unmapped: Int
        var reasks: Int
    }

    /// A monotonic clock: roster tokens are `updated_at` values compared as text.
    final class Clock: @unchecked Sendable {
        private let t = Mutex<Date>(t0)
        func now() -> Date { t.withLock { $0 = $0.addingTimeInterval(1); return $0 } }
    }

    /// A story's text as a memory's title and body: split at its last space, so the stored text (`title\nbody`) is the
    /// story's text with that space as the newline, and every offset is the same.
    /// The space chosen is the last one before a lowercase word, so no name (or name pair) straddles the newline.
    static func split(_ text: String) -> (String, String) {
        let spaces = text.indices.filter { text[$0] == " " && text.index(after: $0) < text.endIndex }
        guard let at = spaces.last(where: { text[text.index(after: $0)].isLowercase }) ?? spaces.last else { return (text, "-") }
        return (String(text[..<at]), String(text[text.index(after: at)...]))
    }

    /// The stored text of a story memory.
    static func stored(_ text: String) -> String { let (t, b) = split(text); return t + "\n" + b }

    static func day(_ written: String) -> Date {
        let p = written.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }

    /// Plays one story in one order. With `replay`, the recorded calls drive the schedule (as `replay.py`); then
    /// memories whose model decisions went stale are asked again, served from the recording. Otherwise each memory
    /// is read in every group, then reconciled.
    static func play(_ story: Fixture.Story, order: [String], orderIndex: Int, user: [String], provider: any GenerationProvider,
                     replay: [Recorded]?, groups: [String], label: String) async throws -> Play {
        let v = try TestVault()
        let clock = Clock()
        let router = ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.secret), factsModel: provider)
        var x = FactsExtractor(store: v.store, router: router, activity: InMemoryActivityLog(), userAliases: user)
        x.unfilteredRostersAllowed = true
        x.clock = { clock.now() }
        let mems = Dictionary(uniqueKeysWithValues: story.memories.map { ($0.id, $0) })
        var vaultID: [String: String] = [:], fixtureID: [String: String] = [:]
        func add(_ mid: String) throws -> String {
            if let id = vaultID[mid] { return id }
            let m = mems[mid]!
            let (title, body) = split(m.text)
            let mem = try v.memory(title, body, sensitivity: .low, now: day(m.written))
            let source = ["agent": MemorySource.agentWrite, "import": .importMarkdown][m.source] ?? .captureMac
            let trust = m.trust ?? (m.source == "agent" ? "untrusted" : "trusted")
            try v.store.writer.write { db in
                try db.execute(sql: "UPDATE memory SET source = ?, trust = ? WHERE id = ?", arguments: [source.rawValue, trust, mem.id.db])
            }
            vaultID[mid] = mem.id.db
            fixtureID[mem.id.db] = mid
            return mem.id.db
        }
        var calls: [[String: Any]] = []
        func record(_ r: FactsLearnReport, mode: String) {
            for c in r.calls {
                calls.append(["memory": fixtureID[c.memoryID] ?? c.memoryID, "group": c.group, "mode": mode, "reconcile": mode != "full",
                              "ok": c.outcome == .applied, "ms": c.milliseconds, "promptTokens": c.usage.inputTokens,
                              "outputTokens": c.usage.outputTokens, "dropped": c.dropped])
            }
        }
        let rp = provider as? Replay
        if let replay {
            for r in replay {
                let id = try add(r.memory)
                rp?.expect(r)
                record(try await x.learn([id], groups: [r.group], kind: r.mode == "full" ? "incremental" : "reconciliation"), mode: r.mode)
            }
            // Order memories the recording never read (none expected) are added so their role links resolve.
            for mid in order where vaultID[mid] == nil { _ = try add(mid) }
            for _ in 0..<3 {
                let stale = try await v.store.writer.read { db in try FactStore.staleDecisions(db) }
                if stale.isEmpty { break }
                for s in stale {
                    rp?.reask(fixtureID[s.memoryID] ?? s.memoryID, s.callGroup)
                    record(try await x.learn([s.memoryID], groups: [s.callGroup], kind: "reconciliation"), mode: "stale")
                }
            }
        } else {
            var reconcile = Reconciler()
            for mid in order {
                let id = try add(mid)
                record(try await x.learn([id], groups: groups), mode: "full")
                for _ in 0..<3 {
                    let due = try reconcile.due(v.store, user: user, asking: id)
                    if due.isEmpty { break }
                    for (m, g) in due { record(try await x.learn([m], groups: [g], kind: "reconciliation"), mode: "reconcile") }
                }
            }
        }
        // The final state, as the spike dumps it.
        var g = try await v.store.writer.read { db in try FactStore.load(db, userAliases: user).graph }
        for mid in order {
            guard let id = vaultID[mid], g.memories[id] == nil else { continue }
            let m = mems[mid]!
            let source: FactsMemory.Source = ["agent": .agent, "import": .import][m.source] ?? .capture
            g.memories[id] = FactsMemory(id: id, text: stored(m.text), written: m.written, source: source,
                                         trusted: (m.trust ?? (m.source == "agent" ? "untrusted" : "trusted")) == "trusted")
        }
        let dump = Dump(graph: g, fixtureID: fixtureID, texts: Dictionary(uniqueKeysWithValues: story.memories.map { ($0.id, $0.text) }),
                        order: order.compactMap { vaultID[$0] })
        var line = dump.people(calls: calls)
        line["story"] = story.id
        line["orderIndex"] = orderIndex
        line["order"] = order
        line["provider"] = label
        line["run"] = 1
        line["groups"] = groups.count > 1 ? "separate" : groups.first ?? ""
        line["registry"] = FactsRegistry.bundled.version
        line["state"] = dump.state(user: user)
        var judged: [(String, String)] = []
        for q in story.queries ?? [] { judged.append((q.id, judge(g, q, timeline: story.timeline ?? []))) }
        line["swift_judged"] = Dictionary(judged, uniquingKeysWith: { a, _ in a })
        return Play(line: line, judged: judged, unmapped: rp?.unmapped ?? 0, reasks: rp?.reasks ?? 0)
    }

    // MARK: Reconciliation (the spike's `needs_reconcile`, until the queue persists it)

    /// Names whose sharing set changed since the memory was read, role phrases whose holders changed since they were
    /// asked, and memories whose model decisions went stale.
    struct Reconciler {
        var askedNames: [String: Set<String>] = [:]      // memory + surface → the entities sharing it when read
        var askedRoles: [String: [String]] = [:]         // memory + phrase start → holders (and extra) when asked

        mutating func due(_ store: VaultStore, user: [String], asking: String) throws -> [(String, String)] {
            let (g, stale) = try store.writer.read { db in
                (try FactStore.load(db, userAliases: user).graph, try FactStore.staleDecisions(db))
            }
            let people = FactsRegistry.bundled.groupPredicates(FactsRegistry.bundled.callGroups.keys.sorted().first {
                FactsPrompt.hasPeople($0, .bundled)
            }!)
            let peopleGroup = FactsRegistry.bundled.predicate(people[0])!.callGroup
            var out: [(String, String)] = []
            func add(_ m: String, _ grp: String) { if !out.contains(where: { $0 == (m, grp) }) { out.append((m, grp)) } }
            for s in stale { add(s.memoryID, s.callGroup) }
            // The memory just read sets its own baseline: what it was read knowing.
            for (key, link) in g.names where FactsText.fold(key.surface).split(separator: " ").count == 1 {
                let k = key.memoryID + "\u{1F}" + key.surface
                let now = Set(g.byName(key.surface).map(\.id))
                if key.memoryID != asking, let was = askedNames[k], was != now, now.count > 1 || link.basis == .ambiguous {
                    add(key.memoryID, peopleGroup)
                }
                askedNames[k] = now
            }
            for mem in g.memories.values {
                for ph in g.rolePhrases(mem.text) {
                    let key = FactsGraph.DecisionKey(memoryID: mem.id, start: ph.start)
                    if let d = g.decisions[key], d.basis != .group { continue }
                    let (d, w) = g.asOf(mem, ph)
                    let h = g.holders(ph, asOf: d, written: w)
                    let now = h.holders.map(\.entity.id).sorted() + (h.extra > 0 ? ["+\(h.extra)"] : [])
                    let k = mem.id + "\u{1F}\(ph.start)"
                    if mem.id != asking, h.holders.count + h.extra > 1, askedRoles[k] != now {
                        add(mem.id, FactsRegistry.bundled.predicate(ph.predicate)!.callGroup)
                    }
                    askedRoles[k] = now
                }
            }
            return out
        }
    }

    // MARK: Judging timeline questions in Swift (score_facts.judge)

    static let timelineKinds = ["before", "after", "year", "current", "previous", "no_answer"]
    static let modelledKinds: Set<String> = ["employee", "self_employed", "partner"]

    static func judge(_ g: FactsGraph, _ q: Fixture.Query, timeline: [Fixture.TimelineEntry]) -> String {
        guard timelineKinds.contains(q.kind) || ["negative", "role_in_stint"].contains(q.kind) else { return "not_timeline" }
        let it = g.intent(q.query)
        if ["negative", "role_in_stint"].contains(q.kind) { return it == nil ? "quiet" : "triggered" }
        let decidable = !(q.answer_org ?? "").isEmpty
        guard let it else { return decidable ? "miss" : "told_no_intent" }
        let ans = g.answer(it, query: q.query)
        let want = decidable ? Set(g.entityMatches(it.predicate, q.answer_org!)) : []
        var got: String?
        if ans.entities.count > 1 {
            got = Set(ans.entities) == want && want.count == 1 ? want.first : "several"
        } else {
            got = ans.entities.first
        }
        guard let got else { return decidable ? "told_decidable" : "told" }
        let kinds = Set(timeline.filter { FactsText.fold($0.org) == FactsText.fold(q.answer_org) }.compactMap(\.kind))
        if decidable, want.isEmpty, ans.basis == .gap, !kinds.isEmpty, kinds.isDisjoint(with: modelledKinds) { return "told_gap" }
        if !decidable { return ans.basis == .gap ? "told_gap" : "wrong" }
        if want.contains(got) { return ans.basis == .gap ? "right_gap" : "right" }
        return "wrong"
    }
}

// MARK: - Dumps in the spike's shapes

extension FactsHarness {
    struct Dump {
        let graph: FactsGraph
        let fixtureID: [String: String]
        let texts: [String: String]
        let order: [String]
        let pid: [String: String]

        init(graph: FactsGraph, fixtureID: [String: String], texts: [String: String], order: [String]) {
            self.graph = graph
            self.fixtureID = fixtureID
            self.texts = texts
            self.order = order
            var pid: [String: String] = [:]
            for (i, e) in graph.orderedEntities.enumerated() { pid[e.id] = "p\(i + 1)" }
            self.pid = pid
        }

        func mid(_ id: String) -> String { fixtureID[id] ?? id }
        /// A surface as the story writes it (the stored text has a newline where the story has a space).
        func flat(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }
        func p(_ id: String?) -> Any { id.flatMap { pid[$0] } ?? NSNull() }

        /// UTF-16 offset in the stored text → code-point offset in the story's text (Python's `str.find`).
        func codePoint(_ memoryID: String, _ utf16: Int) -> Int {
            let t = graph.memories[memoryID]?.text ?? ""
            return FactStore.scalarOffset(t, utf16: utf16)
        }

        func people(calls: [[String: Any]]) -> [String: Any] {
            var g = graph
            var links: [[String: Any]] = []
            for id in order {
                guard let mem = g.memories[id] else { continue }
                for ph in g.rolePhrases(mem.text) where g.registry.kindOf(ph.predicate) == FactsValidator.personKind {
                    let (e, basis) = g.resolve(mem, ph)
                    var link: [String: Any] = ["memory": mid(id), "kind": "role", "start": codePoint(id, ph.start), "surface": flat(ph.surface),
                                               "person": basis == .someoneElse ? NSNull() : p(e), "basis": basis.rawValue,
                                               "predicate": ph.predicate]
                    if basis == .candidates {
                        let (d, w) = g.asOf(mem, ph)
                        link["candidates"] = g.holders(ph, asOf: d, written: w).holders.map { p($0.entity.id) }
                    }
                    links.append(link)
                }
                for (key, n) in g.names where key.memoryID == id {
                    links.append(["memory": mid(id), "kind": "name", "surface": flat(key.surface), "person": p(n.entity),
                                  "basis": n.basis.rawValue, "candidates": n.candidates.map { p($0) }])
                }
            }
            let persons = g.orderedEntities.filter { $0.kind == FactsValidator.personKind }
            return [
                "links": links,
                "people": persons.map { e in
                    ["id": p(e.id), "name": e.name ?? NSNull(), "aliases": e.aliases.sorted(),
                     "group": e.group.map { [$0.predicate, $0.cls ?? NSNull()] as [Any] } ?? NSNull(), "count": e.count ?? NSNull()] as [String: Any]
                },
                "relations": g.facts.filter { g.entities[$0.entity]?.kind == FactsValidator.personKind }.map { f in
                    ["person": p(f.entity), "type": f.predicate, "label": f.label ?? NSNull(), "cls": f.cls ?? NSNull(),
                     "status": g.status(of: f).rawValue, "valid_from": NSNull(), "valid_to": NSNull(),
                     "deceased": g.entities[f.entity]?.deceased ?? false, "only": f.only, "negated": f.negated, "trusted": f.trusted,
                     "evidence": f.assertions.filter { !$0.fromUser }.map { mid($0.memoryID) }] as [String: Any]
                },
                "decisions": g.decisions.sorted { ($0.key.memoryID, $0.key.start) < ($1.key.memoryID, $1.key.start) }.map { k, d in
                    ["memory": mid(k.memoryID), "start": codePoint(k.memoryID, k.start),
                     "person": d.basis == .someoneElse ? "someone_else" : p(d.entity), "basis": d.basis.rawValue] as [String: Any]
                },
                "things": things.map { ["name": $0.0, "kind": $0.1] },
                "calls": calls,
            ]
        }

        var things: [(String, String)] {
            graph.orderedEntities.filter { $0.kind != FactsValidator.personKind && $0.name != nil }.map { ($0.name!, $0.kind) }
        }

        func state(user: [String]) -> [String: Any] {
            let g = graph
            return [
                "registry": g.registry.version,
                "entities": g.orderedEntities.map { e in
                    ["id": p(e.id), "kind": e.kind, "name": e.name ?? NSNull(), "aliases": e.aliases.sorted(),
                     "group": e.group.map { [$0.predicate, $0.cls ?? NSNull()] as [Any] } ?? NSNull(),
                     "count": e.count ?? NSNull(), "deceased": e.deceased] as [String: Any]
                },
                "facts": g.facts.map { f in
                    let rows = f.assertions.filter { !$0.fromUser }
                    return ["entity": p(f.entity), "type": f.predicate, "label": f.label ?? NSNull(), "cls": f.cls ?? NSNull(),
                            "status": g.status(of: f).rawValue, "valid_from": NSNull(), "valid_to": NSNull(), "only": f.only,
                            "negated": f.negated,
                            "evidence": rows.map { [mid($0.memoryID), $0.trusted ? "trusted" : "untrusted"] },
                            "stating": rows.filter(\.states).map { mid($0.memoryID) },
                            "assertions": rows.map { a in
                                ["memory": mid(a.memoryID), "trust": a.trusted ? "trusted" : "untrusted", "written": a.written,
                                 "start": a.start ?? NSNull(), "end": a.end ?? NSNull(), "status": a.status.rawValue,
                                 "time": a.time ?? NSNull(), "preceded_by": a.precededBy ?? NSNull(),
                                 "followed_by": a.followedBy ?? NSNull(), "qualifiers": a.qualifiers, "states": a.states,
                                 "label": a.label ?? NSNull(), "quote": a.quote, "handover": a.handover] as [String: Any]
                            }] as [String: Any]
                },
                "names": g.names.sorted { ($0.key.memoryID, $0.key.surface) < ($1.key.memoryID, $1.key.surface) }.map { k, n in
                    [mid(k.memoryID), flat(k.surface), p(n.entity), n.basis.rawValue, n.candidates.map { p($0) }] as [Any]
                },
                "decisions": g.decisions.map { k, d in
                    [mid(k.memoryID), codePoint(k.memoryID, k.start), d.basis == .someoneElse ? "someone_else" : p(d.entity),
                     d.basis.rawValue] as [Any]
                },
                "things": things.map { [$0.0, $0.1] },
                "user_aliases": user,
                "memories": Dictionary(uniqueKeysWithValues: order.compactMap { id -> (String, Any)? in
                    guard let m = g.memories[id] else { return nil }
                    return (mid(id), ["id": mid(id), "text": texts[mid(id)] ?? m.text, "written": m.written,
                                      "source": m.source == .agent ? "agent" : m.source == .import ? "import" : "capture",
                                      "trust": m.trusted ? "trusted" : "untrusted"] as [String: Any])
                }),
                "calls": [] as [Any],
            ]
        }
    }
}
