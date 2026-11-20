import CryptoKit
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
        struct Name: Decodable { let surface: String; let person: String }
        struct Memory: Decodable {
            let id: String
            let text: String
            let written: String
            let source: String
            let trust: String?
            let names: [Name]?
            /// The memory's sensitivity (canary and work sets may set it); `low` when absent.
            let sensitivity: String?

            var trusted: Bool { (trust ?? (source == "agent" ? "untrusted" : "trusted")) == "trusted" }
        }
        struct Query: Decodable {
            let id: String
            let kind: String
            let query: String
            let answer_org: String?
        }
        struct TimelineEntry: Decodable { let org: String?; let kind: String? }
        struct Person: Decodable { let names: [String] }
        /// The user's own operations in a story (the canary's): "reject" a role phrase's person in a memory, or give a
        /// person's "start" or "end".
        struct Correction: Decodable {
            let after: String
            let op: String
            let person: String
            let memory: String?
            let surface: String?
            let predicate: String?
            let value: String?
        }
        struct Story: Decodable {
            let id: String
            let memories: [Memory]
            let orders: [[String]]?
            let queries: [Query]?
            let timeline: [TimelineEntry]?
            let people: [String: Person]?
            let corrections: [Correction]?
        }
        let user: User
        let stories: [Story]
    }

    static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The 13a.2 canary (written blind by GPT-6-Astra after the code freeze) keeps its registry beside its stories.
    static let canaryDirectory = "spikes/people/fixtures/canary-13a2"

    static func fixtureURL(_ set: String) -> URL {
        if set == "canary13" { return repo.appending(path: canaryDirectory + "/stories.json") }
        return repo.appending(path: "spikes/people/fixtures/\(set == "main" ? "stories" : "stories-\(set)").json")
    }

    /// A set's own registry, if it has one (repo-relative).
    static func defaultRegistry(_ set: String) -> String? { set == "canary13" ? canaryDirectory + "/registry.json" : nil }

    static func fixture(_ set: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL(set)))
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// The commit measured, with "+dirty" when the tree has changes (a run's manifest records it).
    static func commit() -> String {
        func git(_ args: [String]) -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return "" }
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let head = git(["rev-parse", "HEAD"])
        return git(["status", "--porcelain"]).isEmpty ? head : head + "+dirty"
    }

    /// A live provider that remembers which models it said answered (an alias resolves to one).
    final class ModelsSeen: GenerationProvider, @unchecked Sendable {
        let inner: any GenerationProvider
        let models = Mutex<Set<String>>([])
        /// Every response, and those the provider gave no model id for (a record needs every one identified).
        let responses = Mutex<(all: Int, unidentified: Int)>((0, 0))
        init(_ inner: any GenerationProvider) { self.inner = inner }
        var id: ProviderID { inner.id }
        var locality: Locality { inner.locality }
        var modelID: String { inner.modelID }
        var factsAdapter: String { inner.factsAdapter }
        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let (out, usage) = try await inner.generate(request)
            if let m = usage.model { models.withLock { _ = $0.insert(m) } }
            responses.withLock { $0.all += 1; if usage.model == nil { $0.unidentified += 1 } }
            return (out, usage)
        }
    }

    /// Counts requests whose payload carries a fixture memory above the run's cloud limit (the sentinel is the memory's
    /// text as it would be sent). A gate run must have none: the router refuses them before any provider sees them.
    final class PayloadGuard: GenerationProvider, @unchecked Sendable {
        let inner: any GenerationProvider
        let forbidden = Mutex<[String]>([])
        let leaks = Mutex<Int>(0)
        init(_ inner: any GenerationProvider) { self.inner = inner }
        var id: ProviderID { inner.id }
        var locality: Locality { inner.locality }
        var modelID: String { inner.modelID }
        var factsAdapter: String { inner.factsAdapter }
        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let payload = request.instructions + "\n" + request.prompt
            // The memory's text as sent, and each of its sentences of 20 characters or more: part of it is a leak too.
            let bad = forbidden.withLock { $0 }.filter { text in
                guard !text.isEmpty else { return false }
                let parts = [text] + text.split(whereSeparator: { ".!?\n".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 20 }
                return parts.contains { payload.contains($0) }
            }
            if !bad.isEmpty { leaks.withLock { $0 += bad.count } }
            return try await inner.generate(request)
        }
    }

    static func sensitivity(_ name: String?) -> Sensitivity {
        Sensitivity.allCases.first { $0.name == name } ?? .low
    }

    static func cloudLimit(_ name: String?) -> CloudLimit {
        guard let name, name != "secret" else { return .upTo(.secret) }
        return name == "never" ? .never : .upTo(sensitivity(name))
    }

    /// A registry file (`registry=`, the canary's), or the bundled one.
    static func registry(_ path: String?) throws -> FactsRegistry {
        guard let path else { return .bundled }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appending(path: path)
        return try FactsRegistry.decode(Data(contentsOf: url))
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
        /// Gold answers (`gold_answers.py`) were written against the spike's roster; with `reader`, an answer about
        /// someone the Swift roster doesn't show is translated as a reader of the Swift prompt would answer.
        let reader: Bool
        init(reader: Bool = false) { self.reader = reader }

        /// What the gold reader may assume about a fixture memory: its text, and the folded names of people who, so far
        /// in the play, were named only by untrusted memories (so a trusted memory's roster leaves them out, §11.4).
        struct Context { var text: String; var trusted: Bool; var untrustedOnly: Set<String> }
        private let contexts = Mutex<[String: Context]>([:])
        private let counts = Mutex<(substituted: Int, unexplained: Int)>((0, 0))
        func context(_ memory: String, _ c: Context) { contexts.withLock { $0[memory] = c } }
        /// Answers about someone the Swift roster left out, translated by the reader (alias trust).
        var substituted: Int { counts.withLock { $0.substituted } }
        /// Unmapped roster ids the alias-trust rule doesn't explain (a gold play must have none).
        var unexplained: Int { counts.withLock { $0.unexplained } }

        struct Part { var raw: [String: Any]; var roster: [String: [String: Any]] }
        struct Sources { var people, facts, roles, things: Part }
        private let state = Mutex<(next: Recorded?, reask: String?, sources: [String: Sources], unmapped: Int, served: Int, reasks: Int)>(
            (nil, nil, [:], 0, 0, 0))

        var unmapped: Int { state.withLock { $0.unmapped } }
        var reasks: Int { state.withLock { $0.reasks } }

        func expect(_ r: Recorded) { state.withLock { $0.next = r; $0.reask = nil } }
        /// Swift's own schedule served from a recording: every call is a re-ask, answered with what the recording's
        /// calls for that memory and group add up to (the spike applied only the roles of a roles re-ask, and only the
        /// names of a names re-ask). For counting calls; the answers were made knowing other rosters.
        func preload(_ recs: [Recorded]) {
            state.withLock { s in
                for r in recs { s.sources[r.memory + "\u{1F}" + r.group] = Self.merged(s.sources[r.memory + "\u{1F}" + r.group], r) }
            }
        }

        static func merged(_ old: Sources?, _ r: Recorded) -> Sources {
            let part = Part(raw: r.raw, roster: r.roster)
            var src = old ?? Sources(people: part, facts: part, roles: part, things: part)
            switch r.mode {
            case "roles": src.roles = part
            case "names": src.people = part
            default: src = Sources(people: part, facts: part, roles: part, things: part)
            }
            return src
        }
        /// A Swift-only re-ask of a fixture memory in a group: served with its latest recorded output.
        func reask(_ memory: String, _ group: String) { state.withLock { $0.next = nil; $0.reask = memory + "\u{1F}" + group } }

        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let swift = Self.parseRoster(request.prompt)
            let data: Data = try state.withLock { s in
                let key: String
                if let r = s.next {
                    key = r.memory + "\u{1F}" + r.group
                    s.sources[key] = Self.merged(s.sources[key], r)
                    s.next = nil
                    s.served += 1
                } else {
                    guard let k = s.reask, s.sources[k] != nil else { throw ProviderError.invalidOutput }
                    key = k
                    s.reasks += 1
                }
                let src = s.sources[key]!
                var unmapped = 0
                /// The Swift roster's id for a Python roster id, or the Python entity when the Swift roster doesn't show it.
                func tr(_ v: Any?, _ part: Part) -> (value: Any?, hidden: [String: Any]?) {
                    guard let id = v as? String, id.range(of: "^p\\d+$", options: .regularExpression) != nil else { return (v, nil) }
                    guard let e = part.roster[id] else { return (id, nil) }     // not in the spike's roster either: dropped by both
                    if let mapped = Self.translate(e, swift) { return (mapped, nil) }
                    unmapped += 1
                    return (id, e)
                }
                /// A gold reader of Swift's prompt (`reader`): someone the Swift roster leaves out because, so far,
                /// only untrusted memories named them (§11.4: a trusted memory's roster doesn't show them) is answered
                /// as the gold script answers someone not yet known: by the name this memory gives them, else the group
                /// (roles) or nothing (facts). Any other unmapped id stays unmapped and counts as unexplained.
                let ctx = contexts.withLock { $0[String(key.split(separator: "\u{1F}")[0])] }
                var substituted = 0, unexplained = 0
                func explained(_ e: [String: Any]) -> Bool {
                    guard reader, let ctx, ctx.trusted else { return false }
                    let aliases = ((e["aliases"] as? [String]) ?? []).map(FactsText.fold)
                    return !aliases.isEmpty && aliases.allSatisfy { ctx.untrustedOnly.contains($0) }
                }
                func named(_ e: [String: Any]) -> String? {
                    let aliases = ((e["aliases"] as? [String]) ?? []).sorted { $0.count > $1.count }
                    return aliases.first { ctx?.text.contains($0) ?? false }
                }
                func list(_ k: String, _ part: Part, _ field: String) -> [[String: Any]] {
                    (part.raw[k] as? [[String: Any]] ?? []).compactMap { item in
                        var item = item
                        let (value, hidden) = tr(item[field], part)
                        item[field] = value
                        guard let hidden else { return item }
                        guard explained(hidden) else { unexplained += 1; return item }
                        substituted += 1
                        switch field {
                        case "person":
                            let shown = Set(swift.flatMap { $0.aliases ?? [] }.map(FactsText.fold))
                            item[field] = shown.contains(FactsText.fold(item["name"] as? String ?? "")) ? "different" : "new"
                        case "entity":
                            guard let name = named(hidden) else { return nil }
                            item[field] = "name"
                            item["name"] = name
                        default:
                            item[field] = named(hidden).map { "name:" + $0 } ?? "group"
                        }
                        return item
                    }
                }
                var out: [String: Any] = [
                    "facts": list("facts", src.facts, "entity"), "roles": list("roles", src.roles, "refers_to"),
                    "things": src.things.raw["things"] ?? [],
                ]
                if request.schema.json.contains("\"people\"") { out["people"] = list("people", src.people, "person") }
                s.unmapped += unmapped
                if reader { counts.withLock { $0.substituted += substituted; $0.unexplained += unexplained } }
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
        /// Memory versions reconciliation still found due after a drain (a loop if not 0).
        var unsettled = 0
        /// The gold reader's alias-trust substitutions, and unmapped ids it couldn't explain.
        var substituted = 0
        var unexplained = 0
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

    /// Plays one story in one order, through the facts lane: each memory's jobs are queued and the queue drained (with
    /// the reconciliation sweep and the partial re-reads it queues) before the next memory is added, as the spike's
    /// `play` reconciled after each memory. With `replay`, the recorded calls drive the schedule instead (as
    /// `replay.py`), each applied in its recorded scope; then the queue's sweep asks again whatever is still due, served
    /// from the recording.
    static func play(_ story: Fixture.Story, order: [String], orderIndex: Int, user: [String], provider: any GenerationProvider,
                     replay: [Recorded]?, groups: [String], label: String, registry: FactsRegistry = .bundled,
                     limit: CloudLimit = .upTo(.secret)) async throws -> Play {
        let v = try TestVault()
        let clock = Clock()
        let router = ModelRouter(classifier: nil, onDevice: nil, cloudLimit: limit, factsModel: provider)
        var x = FactsExtractor(store: v.store, router: router, activity: InMemoryActivityLog(), registry: registry, userAliases: user,
                               qualification: .unchecked)
        x.clock = { clock.now() }
        let queue = ProcessingQueue(store: v.store, activity: InMemoryActivityLog(), launchedAt: .distantPast, ungatedFacts: true)
        let worker = FactsQueueWorker(extractor: x)
        let mems = Dictionary(uniqueKeysWithValues: story.memories.map { ($0.id, $0) })
        var vaultID: [String: String] = [:], fixtureID: [String: String] = [:]
        func add(_ mid: String) throws -> String {
            if let id = vaultID[mid] { return id }
            let m = mems[mid]!
            let (title, body) = split(m.text)
            let mem = try v.memory(title, body, sensitivity: sensitivity(m.sensitivity), now: day(m.written))
            let source = ["agent": MemorySource.agentWrite, "import": .importMarkdown][m.source] ?? .captureMac
            let trust = m.trust ?? (m.source == "agent" ? "untrusted" : "trusted")
            try v.store.writer.write { db in
                try db.execute(sql: "UPDATE memory SET source = ?, trust = ? WHERE id = ?", arguments: [source.rawValue, trust, mem.id.db])
            }
            vaultID[mid] = mem.id.db
            fixtureID[mem.id.db] = mid
            return mem.id.db
        }
        let log = Mutex<[[String: Any]]>([])
        let fixtureIDs = Mutex<[String: String]>([:])
        @Sendable func record(_ r: FactsLearnReport, mode: String) {
            let ids = fixtureIDs.withLock { $0 }
            log.withLock { calls in
                for c in r.calls where c.outcome != .codeOnly {
                    calls.append(["memory": ids[c.memoryID] ?? c.memoryID, "group": c.group, "mode": mode, "reconcile": mode != "full",
                                  "ok": c.outcome == .applied, "ms": c.milliseconds, "promptTokens": c.usage.inputTokens,
                                  "outputTokens": c.usage.outputTokens, "dropped": c.dropped])
                }
            }
        }
        let rp = (provider as? Replay) ?? ((provider as? PayloadGuard)?.inner as? Replay)
        /// Drains the facts lane; a replayed re-ask is served the recording's answers for that memory and group.
        var unsettled = 0
        func drain() async throws {
            let ids = fixtureIDs.withLock { $0 }
            _ = try await queue.drain(now: { clock.now() }) { job in
                if let g = job.callGroup { rp?.reask(ids[job.subject.db] ?? job.subject.db, g) }
                return try await worker.process(job) { r, mode in record(r, mode: mode) }
            }
            // A fixpoint: once the lane is drained, reconciliation finds nothing left to ask.
            unsettled += try await v.store.writer.write { db in try FactsReconciler.reconcile(db, registry: registry, userAliases: user).count }
        }
        // For the gold reader: who, before each memory, was named only by untrusted memories (fixture labels).
        if let rp, rp.reader {
            var named: [String: (surfaces: Set<String>, trusted: Bool)] = [:]
            for mid in order {
                let m = mems[mid]!
                let only = Set(named.values.filter { !$0.trusted }.flatMap(\.surfaces))
                rp.context(mid, .init(text: m.text, trusted: m.trusted, untrustedOnly: only))
                for n in m.names ?? [] where !["user", "?"].contains(n.person) {
                    var e = named[n.person] ?? ([], false)
                    e.surfaces.insert(FactsText.fold(n.surface))
                    e.trusted = e.trusted || m.trusted
                    named[n.person] = e
                }
            }
        }
        if let replay {
            for r in replay {
                let id = try add(r.memory)
                fixtureIDs.withLock { $0 = fixtureID }
                rp?.expect(r)
                // The spike's re-asks were scoped: a roles re-ask applied every role answer, a names re-ask every name.
                var scope = FactsScope.full
                if r.mode != "full" {
                    scope = try await v.store.writer.read { db in
                        let g = try FactStore.load(db, registry: registry, userAliases: user).graph
                        guard let mem = try FactStore.countedMemories(db, ids: [id])[id]?.memory
                            ?? Row.fetchOne(db, sql: "SELECT title, body FROM memory WHERE id = ?", arguments: [id]).map({
                                FactsMemory(id: id, text: FactStore.text(title: $0["title"], body: $0["body"]), written: "", source: .capture, trusted: true)
                            }) else { return .full }
                        if r.mode == "roles" {
                            let starts = g.rolePhrases(mem.text, predicates: Set(registry.groupPredicates(r.group)))
                                .map { FactStore.scalarOffset(mem.text, utf16: $0.start) }
                            return .partial(roles: Set(starts), names: [])
                        }
                        let said = (r.raw["people"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                        let had = g.names.keys.filter { $0.memoryID == id }.map(\.surface)
                        return .partial(roles: [], names: Set((said + had).map { FactsText.fold($0) }))
                    }
                }
                record(try await x.learn([id], groups: [r.group], kind: r.mode == "full" ? "incremental" : "reconciliation", scope: scope),
                       mode: r.mode)
            }
            // Order memories the recording never read (none expected) are added so their role links resolve.
            for mid in order where vaultID[mid] == nil { _ = try add(mid) }
            fixtureIDs.withLock { $0 = fixtureID }
            try await drain()
        } else {
            for mid in order {
                let id = try add(mid)
                fixtureIDs.withLock { $0 = fixtureID }
                let now = clock.now()
                try await v.store.writer.write { db in
                    let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [id]) ?? 1
                    for g in groups {
                        try ProcessingQueue.enqueueFacts(db, memoryID: UUID(uuidString: id)!, version: version, group: g, reason: .version(text: true), now: now)
                    }
                }
                try await drain()
                if try applyCorrections(story, after: mid, store: v.store, registry: registry, user: user, vaultID: vaultID, now: clock.now()) {
                    try await drain()
                }
            }
        }
        let calls = log.withLock { $0 }
        // The final state, as the spike dumps it.
        var g = try await v.store.writer.read { db in try FactStore.load(db, registry: registry, userAliases: user).graph }
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
        line["registry"] = registry.version
        line["state"] = dump.state(user: user)
        var judged: [(String, String)] = []
        var answers: [String: Any] = [:]
        for q in story.queries ?? [] {
            judged.append((q.id, judge(g, q, timeline: story.timeline ?? [])))
            // What the answer named, for the gates' scorer (a gap answer that names someone on an undecidable question).
            if let it = g.intent(q.query) {
                let a = g.answer(it, query: q.query)
                answers[q.id] = ["entities": a.entities.compactMap { g.entities[$0]?.name }, "basis": "\(a.basis)"]
            }
        }
        line["swift_judged"] = Dictionary(judged, uniquingKeysWith: { a, _ in a })
        line["swift_answers"] = answers
        return Play(line: line, judged: judged, unmapped: rp?.unmapped ?? 0, reasks: rp?.reasks ?? 0, unsettled: unsettled,
                    substituted: rp?.substituted ?? 0, unexplained: rp?.unexplained ?? 0)
    }

    /// A story's corrections after a memory, as the user's own operations in the store. True if any was applied.
    static func applyCorrections(_ story: Fixture.Story, after mid: String, store: VaultStore, registry: FactsRegistry,
                                 user: [String], vaultID: [String: String], now: Date) throws -> Bool {
        var applied = false
        for c in story.corrections ?? [] where c.after == mid {
            try store.writer.write { db in
                let g = try FactStore.load(db, registry: registry, userAliases: user).graph
                let names = Set((story.people?[c.person]?.names ?? []).map(FactsText.fold))
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
                applied = true
            }
        }
        return applied
    }

    // MARK: Judging timeline questions in Swift (score_facts.judge)

    static let timelineKinds = ["before", "after", "year", "current", "previous", "no_answer"]
    static let modelledKinds: Set<String> = ["employee", "self_employed", "partner"]

    static func judge(_ g: FactsGraph, _ q: Fixture.Query, timeline: [Fixture.TimelineEntry]) -> String {
        judge(g, q, timeline: timeline, intent: g.intent(q.query))
    }

    /// The same judgment with the intent supplied (port fidelity: the time model compared with the grammar set aside).
    static func judge(_ g: FactsGraph, _ q: Fixture.Query, timeline: [Fixture.TimelineEntry], intent it: TimelineIntent?) -> String {
        guard timelineKinds.contains(q.kind) || ["negative", "role_in_stint"].contains(q.kind) else { return "not_timeline" }
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
            // Resolving can make a role group no stored fact has yet (a decision for the group); make them first, so
            // every link's person has an id in this dump.
            var graph = graph
            for id in order {
                guard let mem = graph.memories[id] else { continue }
                for ph in graph.rolePhrases(mem.text) where graph.registry.kindOf(ph.predicate) == FactsValidator.personKind {
                    _ = graph.resolve(mem, ph)
                }
            }
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

        /// Each timeline predicate's episodes as the Swift time model derives them (days are proleptic ordinals, Python's
        /// `date.toordinal`), with who ended each by succession: the timeline gate's facts and dates are scored from these.
        func episodes() -> [[String: Any]] {
            func range(_ r: DateRange?) -> Any { r.map { [$0.lo, $0.hi, "\($0.precision)"] as [Any] } ?? NSNull() }
            return graph.registry.timelinePredicates.flatMap { pred in
                graph.episodes(pred).filter { $0.entity != nil }.map { e in
                    ["entity": p(e.entity), "predicate": pred, "start": range(e.start), "end": range(e.end), "slot": e.slot,
                     "inferred_end": e.inferredEnd, "former": e.former, "uncertain": e.uncertain, "trusted": e.trusted,
                     "start_trusted": e.startTrusted, "end_trusted": e.endTrusted,
                     "memories": Array(Set(e.assertions.filter { !$0.fromUser }.map { mid($0.memoryID) })).sorted(),
                     "ended_by": e.endedBy.map { p($0.entity) } ?? NSNull()] as [String: Any]
                }
            }
        }

        /// The timeline gate's "0 succession from untrusted text or across slots", checked two ways: every inferred end's
        /// successor started on trusted evidence in the same slot; and with every untrusted assertion removed, every
        /// inferred end of an episode with trusted evidence is still inferred (so no untrusted row caused it).
        func succession() -> [String: Any] {
            var untrusted: [String] = [], crossSlot: [String] = [], unexplained: [String] = []
            var trustedOnly = graph
            for i in trustedOnly.facts.indices { trustedOnly.facts[i].assertions.removeAll { !$0.trusted } }
            for pred in graph.registry.timelinePredicates {
                let kept = trustedOnly.episodes(pred)
                for e in graph.episodes(pred) where e.inferredEnd {
                    let at = "\(p(e.entity)) \(pred) \(e.start.map { "\($0.lo)" } ?? "-")"
                    guard let by = e.endedBy else { unexplained.append(at); continue }
                    if !by.startTrusted || !by.trusted { untrusted.append(at) }
                    if by.slot != e.slot { crossSlot.append(at) }
                    if e.assertions.contains(where: { $0.trusted }),
                       !kept.contains(where: { $0.entity == e.entity && $0.inferredEnd && $0.start?.lo == e.start?.lo }) {
                        untrusted.append(at + " (gone without untrusted rows)")
                    }
                }
            }
            return ["from_untrusted": untrusted, "across_slots": crossSlot, "without_successor": unexplained]
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
                "episodes": episodes(),
                "succession": succession(),
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

extension FactsHarness {
    /// Port fidelity's investigated differences (`spikes/people/port_fidelity_known.json`): key → (rule, facts.py's value,
    /// Swift's value). An entry excuses only exactly that difference.
    static func knownPortDifferences() throws -> [String: (rule: String, python: String?, swift: String?)] {
        let url = repo.appending(path: "spikes/people/port_fidelity_known.json")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var out: [String: (rule: String, python: String?, swift: String?)] = [:]
        for e in d?["differences"] as? [[String: Any]] ?? [] {
            if let at = e["at"] as? String, let rule = e["rule"] as? String { out[at] = (rule, e["python"] as? String, e["swift"] as? String) }
        }
        return out
    }
}
