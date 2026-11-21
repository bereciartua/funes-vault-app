import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// The facts fixture harness (Phase 13a.2). The full run is opt-in:
///
///     FUNES_FACTS_HARNESS='set=mixed;replay=<export.jsonl>;out=<dir>' swift test --filter FactsHarnessTests/fullRun
///
/// `replay=` takes `spikes/people/export_replay.py`'s output (the spike's recorded Haiku calls); `live=claude:<model>` or
/// `live=codex:<model>` calls a real model through the subscription CLIs and also needs `FUNES_FACTS_HARNESS_LIVE=1`,
/// set only with the author's go-ahead (Phase 13 plan: cloud runs on fixtures need it). `orders=natural` plays each
/// story once; `only=x01,x02` plays those stories; `schedule=1` with `replay=` plays Swift's own schedule (the facts lane,
/// reconciling after each memory) answered from the recording, to count calls. Lines go to `<out>/<label>/<set>.jsonl`, which `RESULTS_DIR=<out> python3 spikes/people/score.py --set
/// <set>` and `score_facts.py stories` read. `scripts/facts_harness.sh` does all three.
@Suite(.serialized) struct FactsHarnessTests {
    static var options: [String: String]? {
        guard let raw = ProcessInfo.processInfo.environment["FUNES_FACTS_HARNESS"], !raw.isEmpty else { return nil }
        var out: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    /// The spike's own result for a play (`results-h3b`), whose recorded calls the sample replays.
    static func spikeResult(_ set: String, _ story: String, _ orderIndex: Int) throws -> [String: Any]? {
        let file = set == "mixed" ? "claude-haiku-separate/mixed.jsonl" : "claude-haiku-people/\(set).jsonl"
        let url = FactsHarness.repo.appending(path: "spikes/people/results-h3b/\(file)")
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            if r["story"] as? String == story, r["orderIndex"] as? Int == orderIndex { return r }
        }
        return nil
    }

    /// Every link as (memory, role start or name surface) → basis and whom, by name or role group, not by id.
    static func links(_ line: [String: Any]) -> [String: String] {
        var who: [String: String] = [:]
        for p in line["people"] as? [[String: Any]] ?? [] {
            let g = (p["group"] as? [Any]).map { "group:" + $0.map { "\($0)" }.joined(separator: ":") }
            who[p["id"] as! String] = (p["name"] as? String) ?? g ?? "?"
        }
        var out: [String: String] = [:]
        for l in line["links"] as? [[String: Any]] ?? [] {
            let at = l["kind"] as! String == "role" ? "\(l["start"]!)" : (l["surface"] as! String)
            let person = (l["person"] as? String).map { who[$0] ?? $0 } ?? "-"
            out["\(l["memory"]!) \(l["kind"]!) \(at)"] = "\(l["basis"]!) \(person)"
        }
        return out
    }

    /// The recorded Haiku calls of a few stories (pairs, denials, a shared first name, injected text, untrusted and
    /// work memories, timeline questions) replayed through the Swift pipeline: every link as the spike's, except where
    /// 13a.1 decided differently on purpose; every call applied; no wrong timeline answer from the Swift time model.
    @Test func replayedStoriesLinkAsTheSpikeDid() async throws {
        let url = try #require(Bundle.module.url(forResource: "replay-sample", withExtension: "jsonl", subdirectory: "fixtures/facts"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        // Where 13a.1 decided differently on purpose: a stale decision is replaced by the re-read's answer (the spike
        // kept "group" when its re-ask said unknown); a role phrase that may be quoted speech is skipped (an agent's
        // memory quoting an injection), where the spike linked it to someone else.
        let decidedDifferently: Set<String> = ["main s16#0 m3 role 0", "astra a19#0 m2 role 57", "astra a19#1 m2 role 57"]
        // Phrases with a registry word 13a.2's fix round added ("my former client contact"): the recording predates it, so
        // the spike never found them; Swift resolves them in code, never to someone wrong.
        let newWord: [String: String] = ["mixed x03#0 m3 role 94": "named Lina Moss", "mixed x03#1 m3 role 94": "named Lina Moss",
                                         "mixed x03#0 m4 role 101": "candidates -", "mixed x03#1 m4 role 101": "candidates -"]
        // Plays where the spike offered a trusted memory someone known only from an agent's memory, which a trusted
        // memory's roster leaves out (§11.4): the recorded answer's id for them has nothing to map to.
        let hiddenByTrust: Set<String> = ["mixed x01#1"]
        var plays = 0
        for set in ["main", "astra", "mixed"] {
            let fixture = try FactsHarness.fixture(set)
            let mine = lines.filter { $0["set"] as? String == set }.map(FactsHarness.Recorded.init)
            for story in fixture.stories {
                let orders = [story.memories.map(\.id)] + (story.orders ?? [])
                for (i, order) in orders.enumerated() {
                    let rec = mine.filter { $0.story == story.id && $0.orderIndex == i }
                    guard !rec.isEmpty, let spike = try Self.spikeResult(set, story.id, i) else { continue }
                    let replay = FactsHarness.Replay()
                    let play = try await FactsHarness.play(story, order: order, orderIndex: i, user: fixture.user.aliases,
                                                           provider: replay, replay: rec,
                                                           groups: FactsRegistry.bundled.callGroups.keys.sorted(), label: "test")
                    plays += 1
                    let at = "\(set) \(story.id)#\(i)"
                    #expect(play.unmapped == 0 || hiddenByTrust.contains(at), "\(at): roster ids the replay couldn't map")
                    let calls = play.line["calls"] as! [[String: Any]]
                    #expect(calls.allSatisfy { $0["ok"] as? Bool == true }, "\(at): a call wasn't applied")
                    #expect(play.unsettled == 0, "\(at): reconciliation still found something due after the lane drained")
                    for key in ["links", "people", "relations", "decisions", "things", "calls", "state"] {
                        #expect(play.line[key] != nil, "\(at): \(key) missing")
                    }
                    let got = Self.links(play.line), want = Self.links(spike)
                    for k in Set(got.keys).union(want.keys).sorted() where !decidedDifferently.contains("\(at) \(k)") {
                        if let w = newWord["\(at) \(k)"] {
                            #expect(want[k] == nil && got[k] == w, "\(at) \(k)")
                            continue
                        }
                        #expect(got[k] == want[k], "\(at) \(k)")
                    }
                    if decidedDifferently.contains("\(at) m3 role 0") { #expect(got["m3 role 0"]?.hasPrefix("candidates") == true) }
                    #expect(!play.judged.contains { ["wrong", "triggered"].contains($0.outcome) }, "\(at): \(play.judged)")
                }
            }
        }
        #expect(plays >= 12)
    }

    @Test(.enabled(if: options != nil)) func fullRun() async throws {
        let o = try #require(Self.options)
        let set = o["set"] ?? "mixed"
        var fixture = try FactsHarness.fixture(set)
        // Development only: other wordings of the questions (`queries=<file>`, {story id: [query]}); never a gate run.
        if let path = o["queries"] {
            try #require(o["live"] == nil, "queries= is for development replays, never a live run")
            let other = try JSONDecoder().decode([String: [FactsHarness.Fixture.Query]].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            for i in fixture.stories.indices { fixture.stories[i].queries = other[fixture.stories[i].id] ?? [] }
        }
        let out = URL(fileURLWithPath: try #require(o["out"]))
        // The canary set brings its own registry (a data-only change); `registry=` overrides.
        let registry = try FactsHarness.registry(o["registry"] ?? FactsHarness.defaultRegistry(set))
        let limit = FactsHarness.cloudLimit(o["limit"])
        let groups = o["groups"] == "people" ? [registry.callGroups.keys.sorted().first { FactsPrompt.hasPeople($0, registry) }!]
            : registry.callGroups.keys.sorted()
        var provider: any GenerationProvider
        var recorded: [FactsHarness.Recorded] = []
        let label: String
        let schedule = o["schedule"] == "1"
        if let path = o["replay"] {
            recorded = try FactsHarness.recorded(URL(fileURLWithPath: path))
            provider = FactsHarness.Replay(reader: o["reader"] == "1")
            label = (schedule ? "swift-schedule-" : "swift-replay-") + (o["tag"] ?? set)
        } else if let live = o["live"] {
            try #require(ProcessInfo.processInfo.environment["FUNES_FACTS_HARNESS_LIVE"] == "1",
                         "a live run on fixtures needs the author's go-ahead: set FUNES_FACTS_HARNESS_LIVE=1")
            let parts = live.split(separator: ":", maxSplits: 1).map(String.init)
            // A full model id: a qualification record never matches an alias.
            let model = parts.count > 1 ? parts[1] : "claude-haiku-5-5"
            provider = FactsHarness.ModelsSeen(parts[0] == "codex"
                ? CodexClient(executable: o["executable"] ?? "codex", model: model)
                : ClaudeCodeClient(executable: o["executable"] ?? "claude", model: model))
            label = "swift-\(parts[0])-\(model)" + (o["tag"].map { "-" + $0 } ?? "")
        } else {
            Issue.record("FUNES_FACTS_HARNESS needs replay= or live=")
            return
        }
        let payloadGuard = FactsHarness.PayloadGuard(provider)
        provider = payloadGuard
        let dir = out.appending(path: label)
        // A gate run's output is evidence: never overwritten (a read can't be picked by running it again).
        if label.range(of: "-gates-r\\d+$", options: .regularExpression) != nil,
           FileManager.default.fileExists(atPath: dir.appending(path: "\(set).jsonl").path) {
            Issue.record("\(dir.path)/\(set).jsonl exists: a gate run's output is never overwritten (use the next read's tag)")
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = [], judged: [String: Int] = [:], unmapped = 0, unsettled = 0, reasks = 0, plays = 0, calls = 0, failed = 0
        var substituted = 0, unexplained = 0, leaks = 0
        var inventory: [String] = []
        let only = Set((o["only"] ?? "").split(separator: ",").map(String.init))
        for story in fixture.stories where only.isEmpty || only.contains(story.id) {
            let orders = [story.memories.map(\.id)] + (o["orders"] == "natural" ? [] : story.orders ?? [])
            for (i, order) in orders.enumerated() {
                let rec = recorded.filter { $0.story == story.id && $0.orderIndex == i }
                if o["replay"] != nil, rec.isEmpty { continue }
                if payloadGuard.inner is FactsHarness.Replay {
                    let r = FactsHarness.Replay(reader: o["reader"] == "1")
                    if schedule { r.preload(rec) }
                    provider = FactsHarness.PayloadGuard(r)
                    (provider as! FactsHarness.PayloadGuard).leaks.withLock { $0 = 0 }
                }
                let guarded = provider as! FactsHarness.PayloadGuard
                guarded.forbidden.withLock { list in
                    list = story.memories.filter { !limit.allows(FactsHarness.sensitivity($0.sensitivity)) }
                        .map { FactsSentText(FactsHarness.stored($0.text), userAliases: fixture.user.aliases, registry: registry).sent }
                }
                let play = try await FactsHarness.play(story, order: order, orderIndex: i, user: fixture.user.aliases, provider: provider,
                                                       replay: o["replay"] != nil && !schedule ? rec : nil, groups: groups, label: label,
                                                       registry: registry, limit: limit)
                leaks += guarded.leaks.withLock { v in defer { v = 0 }; return v }
                inventory.append("\(story.id)#\(i)")
                let data = try JSONSerialization.data(withJSONObject: play.line, options: [.sortedKeys])
                lines.append(String(decoding: data, as: UTF8.self))
                for (_, outcome) in play.judged { judged[outcome, default: 0] += 1 }
                unmapped += play.unmapped
                unsettled += play.unsettled
                reasks += play.reasks
                substituted += play.substituted
                unexplained += play.unexplained
                plays += 1
                let c = play.line["calls"] as? [[String: Any]] ?? []
                calls += c.count
                failed += c.filter { ($0["ok"] as? Bool) != true }.count
            }
        }
        let jsonl = dir.appending(path: "\(set).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: jsonl, atomically: true, encoding: .utf8)
        let summary = "plays \(plays); calls \(calls) (not applied \(failed)); unmapped roster ids \(unmapped)"
            + (o["reader"] == "1" ? " (alias-trust substitutions \(substituted), unexplained \(unexplained))" : "")
            + "; Swift-only re-asks \(reasks); unsettled \(unsettled); "
            + "Swift timeline: " + judged.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        try summary.write(to: dir.appending(path: "\(set)-summary.txt"), atomically: true, encoding: .utf8)
        // What a qualification record's key needs (memory processing §11.10): the engine, each group's prompt version,
        // the registry version, the models the provider said answered, and the commit and fixture measured.
        let reg = registry
        let inner = (provider as? FactsHarness.PayloadGuard)?.inner ?? provider
        let seen = inner as? FactsHarness.ModelsSeen
        let measured = seen.map { $0.inner } ?? inner
        var manifest: [String: Any] = [
            "set": set, "label": label, "mode": o["live"] != nil ? "live" : (schedule ? "schedule" : "replay"),
            "groups": groups, "plays": plays, "calls": calls, "not_applied": failed,
            "engine": ["model": ModelRouter.engine(measured), "adapter": measured.factsAdapter, "batching": FactsExtractor.batching],
            "prompt_versions": FactsQualification.promptVersions(reg), "registry_version": reg.fingerprint,
            "fixture_sha256": try FactsHarness.sha256(FactsHarness.fixtureURL(set)),
            "commit": FactsHarness.commit(), "date": ISO8601DateFormatter().string(from: Date()),
            // What makes a run complete and comparable (the Gates step's record writer checks each).
            "run_id": UUID().uuidString.lowercased(),
            "options": o.filter { !["out", "replay", "executable"].contains($0.key) },
            "limit": o["limit"] ?? "secret",
            "registry_file": o["registry"] ?? FactsHarness.defaultRegistry(set) ?? "bundled",
            "plays_list": inventory,
            "plays_expected": fixture.stories.reduce(0) { $0 + 1 + (o["orders"] == "natural" ? 0 : ($1.orders ?? []).count) },
            "unsettled": unsettled, "unmapped": unmapped, "reasks": reasks,
            "above_limit_in_payload": leaks,
            "lines_sha256": try FactsHarness.sha256(jsonl),
        ]
        if o["reader"] == "1" { manifest["substituted"] = substituted; manifest["unexplained"] = unexplained }
        if let seen {
            manifest["models_reported"] = seen.models.withLock { $0.sorted() }
            let r = seen.responses.withLock { $0 }
            manifest["responses"] = r.all
            manifest["responses_without_model"] = r.unidentified
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appending(path: "\(set)-manifest.json"))
        print("facts harness: " + summary)
    }
}
