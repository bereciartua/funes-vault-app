import CryptoKit
import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// 13e.2's *timeline* gate (ADR-0032 decision 9, amended 2026-11-21; the Phase 13 plan's 13e.2 step 4), opt-in:
///
///     FUNES_TIMELINE_GATE='phase=read;set=gate-13e2;live=claude:claude-haiku-5-5;executable=<claude>;tag=r1;out=<dir>'
///     FUNES_TIMELINE_GATE='phase=read;set=gate-13e2;calls=<dir>/read-r1/calls.jsonl;expect=<dir>/read-r1/manifest.json;out=<dir>'
///     FUNES_TIMELINE_GATE='phase=answers;set=gate-13e2;calls=<…/calls.jsonl>;engine=haiku|terra;reps=1;out=<dir>'
///
/// - **read**: one recorded live read through the Swift extractor. Stories play serially in the fixture's order, each in
///   a fresh vault: the shared fillers first (`fillers.json`), then the story's memories (its own fillers among them) in
///   written order, through `FactsHarness.play` (the neutral title, whole bodies, fixed memory ids). `SharedCalls` pays
///   the fillers' calls once: from the second story on, none of them may be live, and an error on one stops the read.
///   Writes `read-<tag>/stories.jsonl` (each story's dump, for `qualify.timeline_measures`), `calls.jsonl` and a
///   manifest with each story's (key, occurrence, source) list and state digest. With `calls=` it replays: 0 misses,
///   and with `expect=` every story's digest equal to the live read's.
/// - **answers**: replays the read, embeds with bge-small, then every question through the app's search and the real
///   `SearchAnswerer`, arm P (plain: `facts: false`) and arm R (rows and checks: the shipped uses, the persons'
///   *attributes* and works at's *timeline* answer use), `reps` samples of R. The app's own clients (Claude Code with
///   Haiku, Codex with GPT-5.6-Terra); responses cached in `results-13e2/cache-<engine>/` (not committed). Writes
///   `answers-<engine>/answers.jsonl` and a manifest. `dry=1` sends nothing and counts what a live run would send; a dry
///   run whose every request is cached, at a clean commit, is the replay `qualify.py` checks.
///
/// A live run also needs `FUNES_TIMELINE_GATE_LIVE=1`, set only with the author's go-ahead.
@Suite(.serialized) struct FactsTimelineGateTests {
    static var options: [String: String]? {
        guard let raw = ProcessInfo.processInfo.environment["FUNES_TIMELINE_GATE"], !raw.isEmpty else { return nil }
        var out: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    struct GateSet {
        var fixture: FactsHarness.Fixture
        var fillers: [FactsHarness.Fixture.Memory]
        var dir: URL
    }

    struct FillerFile: Decodable { let memories: [FactsHarness.Fixture.Memory] }

    /// `spikes/people/fixtures/<name>/`: `stories.json` (work13's format, questions with their labels) and `fillers.json`.
    static func load(_ name: String) throws -> GateSet {
        let dir = FactsHarness.repo.appending(path: "spikes/people/fixtures/\(name)")
        let fixture = try JSONDecoder().decode(FactsHarness.Fixture.self, from: Data(contentsOf: dir.appending(path: "stories.json")))
        let fillers = try JSONDecoder().decode(FillerFile.self, from: Data(contentsOf: dir.appending(path: "fillers.json"))).memories
        return GateSet(fixture: fixture, fillers: fillers.map { var m = $0; m.filler = true; return m }, dir: dir)
    }

    /// A fixed id for a fixture memory in a story's vault (search breaks ties by id, so a replay ranks as the run did).
    static func memoryID(_ story: String, _ memory: String) -> UUID {
        let d = Array(SHA256.hash(data: Data("13e2|\(story)|\(memory)".utf8)))
        var b = (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15])
        b.6 = (b.6 & 0x0F) | 0x40
        b.8 = (b.8 & 0x3F) | 0x80
        return UUID(uuid: b)
    }

    /// A story's memories in written order (its own fillers among them), stable for equal dates.
    static func order(_ story: FactsHarness.Fixture.Story) -> [String] {
        story.memories.enumerated().sorted { ($0.element.written, $0.offset) < ($1.element.written, $1.offset) }.map(\.element.id)
    }

    static func digest(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Every shared filler is sent as written whatever the story (the user's names never in it), so its calls are the
    /// same in every story vault. Empty when that holds.
    static func fillerProblems(_ set: GateSet) -> [String] {
        set.fillers.compactMap { m in
            let stored = FactsHarness.stored(m.text)
            let with = FactsSentText(stored, userAliases: set.fixture.user.aliases, registry: .bundled).sent
            let without = FactsSentText(stored, userAliases: [], registry: .bundled).sent
            return with == without ? nil : "\(m.id): the user's name changes what's sent"
        }
    }

    // MARK: Always: the shared-calls rule on a scripted model

    /// The fillers' calls are paid once across two stories and replay from the record, with equal states.
    @Test func sharedFillersArePaidOnceAndTheReadReplays() async throws {
        let set = try Self.devSet()
        let dir = FileManager.default.temporaryDirectory.appending(path: "funes-13e2-\(UUID().uuidString)")
        let file = dir.appending(path: "calls.jsonl")
        let scripted = FactsExtractorTests.Scripted { _ in ["facts": [] as [Any], "people": [] as [Any], "roles": [] as [Any], "things": [] as [Any]] }
        let live = try FactsHarness.SharedCalls(scripted, file: file)
        let a = try await Self.read(set, shared: live, keep: false)
        let c = live.counts
        #expect(c.live > 0 && c.liveErrors == 0)
        #expect(c.reused >= set.fillers.count * FactsRegistry.bundled.callGroups.count, "the second story didn't reuse the fillers' calls")
        #expect(a.problems.isEmpty, "\(a.problems)")
        let again = try FactsHarness.SharedCalls(nil, file: file)
        let b = try await Self.read(set, shared: again, keep: false)
        #expect(again.counts.misses == 0 && again.counts.live == 0)
        #expect(a.digests == b.digests)
    }

    /// Two stories and three fillers, hand-written (no model): the rule's own test.
    static func devSet() throws -> GateSet {
        let json = #"""
        {"user": {"name": "Ari Fen", "aliases": ["Ari", "Ari Fen"]}, "stories": [
          {"id": "d1", "memories": [
            {"id": "m1", "text": "I joined Birch Labs in 2018 as a designer.", "written": "2018-03-01", "source": "capture"},
            {"id": "m2", "text": "I left Birch Labs in May 2021 and started at Cedar Systems in June 2021.", "written": "2021-06-10", "source": "capture"}],
           "queries": [{"id": "q1", "kind": "before", "query": "Where did I work before Cedar Systems?", "answer_org": "Birch Labs"}],
           "timeline": [{"org": "Birch Labs", "kind": "employee"}, {"org": "Cedar Systems", "kind": "employee"}]},
          {"id": "d2", "memories": [
            {"id": "m1", "text": "Since 2019 I work at Dune Analytics.", "written": "2020-01-05", "source": "capture"}],
           "queries": [{"id": "q1", "kind": "current", "query": "Where do I work now?", "answer_org": "Dune Analytics"}],
           "timeline": [{"org": "Dune Analytics", "kind": "employee"}]}]}
        """#
        let fillers = [
            FactsHarness.Fixture.Memory(id: "f1", text: "Bought oat milk and coffee filters.", written: "2019-02-02", source: "capture",
                                        trust: nil, names: nil, sensitivity: nil),
            FactsHarness.Fixture.Memory(id: "f2", text: "The Harbor Maps app crashed again on the train.", written: "2020-05-05",
                                        source: "capture", trust: nil, names: nil, sensitivity: nil),
            FactsHarness.Fixture.Memory(id: "f3", text: "Dentist on Thursday at 9.", written: "2021-09-09", source: "capture",
                                        trust: nil, names: nil, sensitivity: nil),
        ]
        return GateSet(fixture: try JSONDecoder().decode(FactsHarness.Fixture.self, from: Data(json.utf8)),
                       fillers: fillers.map { var m = $0; m.filler = true; return m }, dir: FileManager.default.temporaryDirectory)
    }

    // MARK: The read

    struct Read {
        var lines: [[String: Any]] = []
        var logs: [String: [[String: Any]]] = [:]
        var digests: [String: String] = [:]
        var vaults: [String: (TestVault, [String: String])] = [:]
        var problems: [String] = []
        var unsettled = 0
    }

    /// Every story, serially, through `shared`. Stops (throws) when a shared filler's call fails or, from the second
    /// story on, is asked live.
    static func read(_ set: GateSet, shared: FactsHarness.SharedCalls, keep: Bool, only: Set<String> = []) async throws -> Read {
        var r = Read()
        r.problems = fillerProblems(set)
        guard r.problems.isEmpty else { return r }
        let reg = FactsRegistry.bundled
        let groups = reg.callGroups.keys.sorted()
        let models = FactsHarness.ModelsSeen(shared)
        let fillerIDs = Set(set.fillers.map(\.id))
        for story in set.fixture.stories where !fillerIDs.isDisjoint(with: story.memories.map(\.id)) {
            r.problems.append("story \(story.id): a memory id is also a shared filler's")
        }
        guard r.problems.isEmpty else { return r }
        for (k, story) in set.fixture.stories.enumerated() where only.isEmpty || only.contains(story.id) {
            shared.begin()
            let before = shared.counts
            let play = try await FactsHarness.play(
                story, order: order(story), orderIndex: 0, user: set.fixture.user.aliases, provider: models, replay: nil, groups: groups,
                label: "timeline-gate", registry: reg, limit: .upTo(.internal), prelude: set.fillers,
                memoryID: { [id = story.id] in memoryID(id, $0) },
                afterPrelude: {
                    // This story's shared-filler phase only: an error, live or recorded, stops the read; from the second
                    // story on, none of their calls may be live.
                    let c = shared.counts
                    if c.liveErrors > before.liveErrors || c.servedErrors > before.servedErrors {
                        throw GateError.stop("a shared filler's call failed: read again under a new tag")
                    }
                    if k > 0, c.live != before.live {
                        throw GateError.stop("story \(story.id): shared fillers asked live (\(c.live - before.live)): their calls differ by story")
                    }
                }, keep: keep)
            var line = play.line
            line["fillers"] = set.fillers.map(\.id)
            let state = line["state"] ?? [:]
            r.digests[story.id] = try digest(state)
            r.logs[story.id] = shared.begin()
            r.unsettled += play.unsettled
            r.lines.append(line)
            if keep, let v = play.vault { r.vaults[story.id] = (v, play.vaultIDs) }
        }
        return r
    }

    enum GateError: Error, CustomStringConvertible {
        case stop(String)
        var description: String { if case let .stop(s) = self { return s }; return "" }
    }

    @Test(.enabled(if: options != nil, "FUNES_TIMELINE_GATE"))
    func run() async throws {
        let o = try #require(Self.options)
        let set = try Self.load(o["set"] ?? "gate-13e2")
        let out = URL(fileURLWithPath: try #require(o["out"]))
        switch o["phase"] ?? "read" {
        case "read": try await readPhase(o, set: set, out: out)
        case "answers": try await answersPhase(o, set: set, out: out)
        default: Issue.record("phase= read or answers")
        }
    }

    func manifestBase(_ o: [String: String], set: GateSet) throws -> [String: Any] {
        [
            "set": o["set"] ?? "gate-13e2", "commit": FactsHarness.commit(), "dirty": Self.dirty(),
            "registryVersion": FactsRegistry.bundled.fingerprint, "promptVersions": FactsQualification.promptVersions(.bundled),
            "batching": FactsExtractor.batching, "answerPromptVersion": SearchAnswerer.promptVersion,
            "storiesSha256": try FactsHarness.sha256(set.dir.appending(path: "stories.json")),
            "fillersSha256": try FactsHarness.sha256(set.dir.appending(path: "fillers.json")),
            "stories": set.fixture.stories.map(\.id), "date": ISO8601DateFormatter().string(from: Date()),
            "options": o.filter { !["out", "executable"].contains($0.key) },
        ]
    }

    static func dirty() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Changed or untracked code (what the freeze covers), not fixtures or results.
        p.arguments = ["-C", FactsHarness.repo.path, "status", "--porcelain", "--", "Packages", "Apps", "scripts",
                       "spikes/people/*.py", "spikes/people/swift"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return !pipe.fileHandleForReading.readDataToEndOfFile().isEmpty
    }

    func readPhase(_ o: [String: String], set: GateSet, out: URL) async throws {
        let shared: FactsHarness.SharedCalls
        let dir: URL
        if let live = o["live"] {
            try #require(ProcessInfo.processInfo.environment["FUNES_TIMELINE_GATE_LIVE"] == "1",
                         "a live read calls a real model and needs the author's go-ahead: set FUNES_TIMELINE_GATE_LIVE=1")
            let parts = live.split(separator: ":", maxSplits: 1).map(String.init)
            let model = parts.count > 1 ? parts[1] : "claude-haiku-5-5"
            let client: any GenerationProvider = parts[0] == "codex"
                ? CodexClient(executable: o["executable"] ?? "codex", model: model)
                : ClaudeCodeClient(executable: o["executable"] ?? "claude", model: model)
            dir = out.appending(path: "read-\(try #require(o["tag"], "a live read needs tag="))")
            // Evidence is never overwritten; an interrupted read resumes on its own record (same order, same rule).
            if FileManager.default.fileExists(atPath: dir.appending(path: "stories.jsonl").path) {
                Issue.record("\(dir.path) holds a finished read: use the next tag")
                return
            }
            shared = try FactsHarness.SharedCalls(client, file: dir.appending(path: "calls.jsonl"))
        } else {
            let calls = URL(fileURLWithPath: try #require(o["calls"], "phase=read needs live= or calls="))
            shared = try FactsHarness.SharedCalls(nil, file: calls)
            dir = out.appending(path: "replay-" + (o["tag"] ?? calls.deletingLastPathComponent().lastPathComponent))
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = try await Self.read(set, shared: shared, keep: false)
        try #require(r.problems.isEmpty, "\(r.problems)")
        let text = try r.lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
        try (text.joined(separator: "\n") + "\n").write(to: dir.appending(path: "stories.jsonl"), atomically: true, encoding: .utf8)
        let c = shared.counts
        var m = try manifestBase(o, set: set)
        m["mode"] = o["live"] != nil ? "live" : "replay"
        m["engine"] = ["provider": shared.id.rawValue, "model": shared.modelID, "adapter": shared.factsAdapter]
        m["calls"] = ["live": c.live, "reused": c.reused, "misses": c.misses, "liveErrors": c.liveErrors]
        m["callsSha256"] = try FactsHarness.sha256(shared.file)
        m["linesSha256"] = try FactsHarness.sha256(dir.appending(path: "stories.jsonl"))
        m["digests"] = r.digests
        m["occurrences"] = r.logs
        m["unsettled"] = r.unsettled
        var problems: [String] = []
        if c.misses > 0 { problems.append("\(c.misses) calls missing from the record") }
        if let e = o["expect"] {
            let want = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: e))) as? [String: Any] ?? [:]
            let digests = want["digests"] as? [String: String] ?? [:]
            for (s, d) in r.digests where digests[s] != d { problems.append("story \(s): its state differs from the live read's") }
        }
        m["problems"] = problems
        try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appending(path: "manifest.json"))
        print("timeline gate read: \(r.lines.count) stories; calls live \(c.live), reused \(c.reused), misses \(c.misses); "
              + (problems.isEmpty ? "ok" : problems.joined(separator: "; ")))
        #expect(problems.isEmpty, "\(problems)")
    }

    // MARK: The answers

    /// R's uses: the search uses the records turn on (every predicate's recorded and linked), and for answers the
    /// persons' *attributes* (both bases) and works at's *timeline* too.
    static func uses() -> (search: FactsUses, answer: FactsUses) {
        let reg = FactsRegistry.bundled
        var search = Set<FactsUses.Key>()
        for p in reg.predicates {
            for u in [FactsUse.recorded, .linked] where p.uses.contains(u.rawValue) { search.insert(.init(predicate: p.id, use: u, basis: "")) }
        }
        var answer = search
        for p in reg.predicates where p.uses.contains(FactsUse.attributes.rawValue) && p.uses.contains(FactsUse.linked.rawValue) {
            answer.insert(.init(predicate: p.id, use: .attributes, basis: ""))
            answer.insert(.init(predicate: p.id, use: .attributes, basis: LinkBasis.soleKnown.rawValue))
        }
        if let t = reg.timelinePredicates.first { answer.insert(.init(predicate: t, use: .timeline, basis: "")) }
        return (FactsUses(registry: reg, on: search), FactsUses(registry: reg, on: answer))
    }

    static func config(_ arm: String, user: [String]) -> FactsSearchConfig {
        var c = FactsSearchConfig(engines: [:], userAliases: user, cloudLimit: .upTo(.internal))
        let u = uses()
        c.measuredUses = u.search
        if arm == "R" { c.measuredAnswerUses = u.answer }
        return c
    }

    /// The `<job name="…">` rows a prompt carried (none: no rows).
    static func rows(_ prompt: String?) -> [String]? {
        guard let prompt, prompt.contains("<work_history") else { return nil }
        let re = try! NSRegularExpression(pattern: #"<job [^>]*?name="([^"]*)""#)
        return re.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)).compactMap {
            Range($0.range(at: 1), in: prompt).map { String(prompt[$0]).replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&amp;", with: "&") }
        }
    }

    func answersPhase(_ o: [String: String], set: GateSet, out: URL) async throws {
        let dry = o["dry"] == "1"
        if !dry {
            try #require(ProcessInfo.processInfo.environment["FUNES_TIMELINE_GATE_LIVE"] == "1",
                         "live answers call a real model and need the author's go-ahead: set FUNES_TIMELINE_GATE_LIVE=1")
        }
        let engine = o["engine"] ?? "haiku"
        let reps = Int(o["reps"] ?? "1") ?? 1
        let calls = URL(fileURLWithPath: try #require(o["calls"], "phase=answers replays a read: calls="))
        let shared = try FactsHarness.SharedCalls(nil, file: calls)
        let only = Set((o["only"] ?? "").split(separator: ",").map(String.init))
        let r = try await Self.read(set, shared: shared, keep: true, only: only)
        try #require(shared.counts.misses == 0, "the read doesn't replay: \(shared.counts.misses) misses")
        let base: (any GenerationProvider)? = dry ? nil : try await FactsAnswerLiveTests.client(engine)
        let cache = SearchGate.spike("results-13e2").appending(path: "cache-\(engine)")
        let model = GateModel(base: base, id: base?.id ?? (engine == "terra" ? "codex" : "claude-code"),
                              modelID: base?.modelID ?? (engine == "terra" ? "gpt-5.6-terra" : "haiku"), cache: cache)
        model.cacheErrors = true
        model.liveAlways = true
        let embeddings = o["index"] != "keyword"
        if embeddings { try #require(Fixtures.modelAvailable, Fixtures.modelMissing) }
        let dir = out.appending(path: "answers-\(engine)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: only.isEmpty ? "answers.jsonl" : "answers-only.jsonl")
        // A directory is one run's: a mode marker, written first, keeps a dry run off a live run's evidence (finished
        // or not) and a live run off a dry run's echo records.
        let marker = dir.appending(path: "mode")
        let mode = dry ? "dry" : "live"
        if let was = try? String(contentsOf: marker, encoding: .utf8), was != mode {
            Issue.record("\(dir.path) holds a \(was) run: this \(mode) run needs another out=")
            return
        }
        if (try? String(contentsOf: marker, encoding: .utf8)) == nil, FileManager.default.fileExists(atPath: file.path) {
            Issue.record("\(dir.path) holds answers from an unknown run: use another out=")
            return
        }
        try mode.write(to: marker, atomically: true, encoding: .utf8)
        let stamp: [String: Any] = ["commit": FactsHarness.commit(), "dirty": Self.dirty()]
        // A live run appends each answer as it ends and, resumed, keeps what it has: an answer is asked once (a failed
        // one stays failed), and its timing is the live one. A dry run writes its file whole.
        var records: [[String: Any]] = []
        if !dry, let text = try? String(contentsOf: file, encoding: .utf8) {
            records = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        let have = Set(records.map { "\($0["story"]!)|\($0["id"]!)|\($0["arm"]!)|\($0["rep"]!)" })
        if dry { try? FileManager.default.removeItem(at: file) }
        for story in set.fixture.stories where only.isEmpty || only.contains(story.id) {
            let (vault, vaultIDs) = try #require(r.vaults[story.id])
            let ids = vaultIDs.compactMapValues { UUID(uuidString: $0) }
            let fixtureOf = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
            var indexer: EmbeddingIndexer?
            if embeddings, let d = Fixtures.modelDirectory {
                let bge = try BundledBGEEmbedder(compiledModelURL: d.appending(path: BundledBGEEmbedder.compiledModelName),
                                                 vocabURL: d.appending(path: "vocab.txt"))
                let i = EmbeddingIndexer(store: vault.store, provider: bge)
                _ = try await i.embedPending()
                indexer = i
            }
            for q in story.queries ?? [] {
                for arm in ["P", "R"] {
                    for rep in 1...(arm == "R" ? reps : 1) {
                        if have.contains("\(story.id)|\(q.id)|\(arm)|\(rep)") { continue }
                        let search = SearchService(store: vault.store, indexer: indexer)
                        search.facts = Self.config(arm, user: set.fixture.user.aliases)
                        var rec = try await Self.answer(q.query, arm: arm, search: search, vault: vault, model: model, rep: rep,
                                                        fixtureOf: fixtureOf)
                        rec["story"] = story.id
                        rec["id"] = q.id
                        rec["engine"] = engine
                        rec.merge(stamp) { $1 }
                        records.append(rec)
                        if !dry {
                            let line = try JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]) + Data("\n".utf8)
                            if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(line); try? h.close() }
                            else { try line.write(to: file) }
                            FileHandle.standardError.write(Data("\(story.id) \(q.id) \(arm)\(rep): \(rec["outcome"]!)\(rec["cached"] as? Bool == true ? " (cached)" : "")\n".utf8))
                        }
                    }
                }
            }
        }
        if dry { try AnswerGate.jsonl(records).write(to: file, atomically: true, encoding: .utf8) }
        let c = model.counts
        var m = try manifestBase(o, set: set)
        m["mode"] = dry ? (c.wouldCall == 0 ? "replay" : "dry") : "live"
        m["engine"] = ["provider": model.id.rawValue, "model": model.modelID]
        m["calls"] = ["live": c.calls, "cached": c.reused, "uncached": c.wouldCall]
        m["readCallsSha256"] = try FactsHarness.sha256(calls)
        m["readDigests"] = r.digests
        m["reps"] = reps
        m["unsettled"] = r.unsettled
        m["records"] = [file.lastPathComponent: FactsGateEvidence.sha256(file) ?? ""]
        m["modelsReported"] = Array(Set(records.compactMap { $0["model"] as? String })).sorted()
        try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appending(path: "manifest.json"))
        print("timeline gate answers (\(engine)): \(records.count) answers; " + (dry ? "dry: \(c.wouldCall) calls a live run would send, \(c.reused) cached"
                                                                              : "live \(c.calls), cached \(c.reused)"))
    }

    /// One answer as the gate records it; one retry for a transport error, any other error is the answer's.
    static func answer(_ query: String, arm: String, search: SearchService, vault: TestVault, model: GateModel, rep: Int,
                       fixtureOf: [UUID: String]) async throws -> [String: Any] {
        // End to end, as the user waits: the search, the answer and any retry.
        let clock = ContinuousClock()
        let start = clock.now
        let hits = try await search.vaultSearch(query, filter: MemoryFilter(status: .active), now: AnswerGate.now)
        let answerer = SearchAnswerer(store: vault.store, search: search, activity: InMemoryActivityLog())
        let fid = { (u: UUID) in fixtureOf[u] ?? u.uuidString }
        var r: [String: Any] = ["arm": arm, "rep": rep, "shown": hits.map { fid($0.memoryID) }]
        var tries = 0
        while true {
            tries += 1
            // R's requests never share P's cache entries, so every R answer is its own live, timed call.
            model.next(rep: arm == "R" ? 100 + rep : rep)
            do {
                let a = try await answerer.answer(query, ids: hits.map(\.memoryID), facts: arm == "R",
                                                  router: ModelRouter(classifier: model, onDevice: nil), now: AnswerGate.now)
                let l = model.last
                r["outcome"] = a.outcome.rawValue
                r["claims"] = a.claims.map { c -> [String: Any] in
                    var out: [String: Any] = ["text": c.text, "inferred": c.inference != nil,
                                              "citations": c.citations.map { ["memory": fid($0.memoryID), "quote": $0.quote] }]
                    if let i = c.inference { out["basis"] = i.basis }
                    if let made = c.comparisonMade { out["comparisonMade"] = made }
                    if c.comparisonAboutSomeoneElse { out["comparisonSomeoneElse"] = true }
                    if let k = c.check {
                        out["check"] = ["verdict": k.verdict.rawValue, "reason": k.reason?.rawValue ?? NSNull(),
                                        "basis": k.basis?.rawValue ?? NSNull()]
                    }
                    return out
                }
                r["dropped"] = a.dropped
                r["checks"] = ["checked": a.checks.checked, "agreed": a.checks.agreed, "markedTrusted": a.checks.markedTrusted,
                               "notSure": a.checks.notSure, "checkDropped": a.checks.checkDropped]
                r["read"] = a.readIDs.map(fid)
                r["cited"] = a.bridgeIDs.map(fid)
                r["rows"] = rows(l.prompt) ?? NSNull()
                r["factsRevision"] = a.factsRevision ?? NSNull()
                r["durationMs"] = Int((clock.now - start) / .milliseconds(1))
                r["answerMs"] = Int(a.duration / .milliseconds(1))
                r["providerMs"] = l.ms ?? 0
                r["cached"] = l.cached
                r["hash"] = l.hash ?? ""
                r["model"] = l.model ?? NSNull()
                break
            } catch let e as SearchAnswerError {
                if let code = model.servedAnswerError {
                    // A replay of a live answer's final failure.
                    let l = model.last
                    r.merge(["outcome": "failed", "error": code, "claims": [] as [Any], "rows": rows(l.prompt) ?? NSNull(),
                             "hash": l.hash ?? "", "cached": true, "model": NSNull(),
                             "durationMs": Int((clock.now - start) / .milliseconds(1))]) { $1 }
                    break
                }
                switch e {
                case .provider(.rateLimited), .provider(.unauthorized), .needsUpdate, .toolBlocked: throw e
                case .provider(.transport) where tries == 1:
                    // Live: the failure isn't kept, the retry asks again. A replay serves the run's final outcome twice.
                    if !model.isDry { model.forgetLast() }
                    continue
                default:
                    model.recordAnswerFailure(e.code)
                    let l = model.last
                    r.merge(["outcome": "failed", "error": e.code, "claims": [] as [Any], "rows": rows(l.prompt) ?? NSNull(),
                             "hash": l.hash ?? "", "cached": l.cached, "model": l.model ?? NSNull(),
                             "durationMs": Int((clock.now - start) / .milliseconds(1))]) { $1 }
                }
                break
            }
        }
        r["tries"] = tries
        return r
    }
}
