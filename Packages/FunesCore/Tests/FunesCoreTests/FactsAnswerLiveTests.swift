import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// Phase 13d's live answer gates (the Phase 13 plan's acceptance table), run through the real `SearchAnswerer`,
/// selection, attributes and marking, with the app's own subscription clients:
///
/// - **Answers on linked questions** (`gate=answers`): Spike H's people sets (main, astra, busy) with the r3 Haiku read,
///   every people question and every other one whose request learned facts change; arms P (13b), F (facts), W (a wrong
///   link on a trap), `reps` samples each. Writes `spikes/people/results-13d/answers-<engine>/<set>-r3.jsonl`, which
///   `ANS_DIR=../results-13d/answers-<engine> python3 search_answers.py judge --set <set> --engine r3` judges blind and
///   `python3 score_13d.py answers --engine <engine>` scores against the gate.
/// - **Spike G with the feature on** (`gate=spikeg`): Spike G's two sets, P and F, one sample, with the same r3 read:
///   every memory of Spike G's main vault, and 208 of the held-out vault's 211, are Spike H's main vault's, word for word
///   (the other 3, b01–b03, stay unread by the Facts task). Writes `results-13d/spike-g-<engine>/<set>-<arm>.jsonl` for
///   `score_13d.py spikeg`.
///
///     FUNES_ANSWER_GATE='gate=answers;engine=haiku;dry=1' swift test --package-path Packages/FunesCore --filter FactsAnswerLiveTests/run
///
/// Bridges stay as the shipped records have them (off: no timeline record yet), so this gate measures *attributes* only;
/// a bridges record needs its own run once a timeline record exists.
///
/// Options: `engine=haiku|terra`, `sets=main,astra,busy`, `arms=P,F,W`, `reps=3` (Spike G: 1), `only=s01,wq02`,
/// `index=keyword` (default bge-small, as Spike H measured), `dry=1`. A dry run sends nothing: it counts the calls a live
/// run would make. A live run also needs `FUNES_ANSWER_GATE_LIVE=1`, set only with the author's go-ahead. Responses are
/// cached in `results-13d/cache-<engine>/` (not committed), so a stopped run resumes and identical requests are asked once.
@Suite(.serialized) struct FactsAnswerLiveTests {
    static var options: [String: String]? {
        guard let raw = ProcessInfo.processInfo.environment["FUNES_ANSWER_GATE"], !raw.isEmpty else { return nil }
        var out: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    static let out = SearchGate.spike("results-13d")
    /// Where records go: `out=<dir>` (a dry run writes them only there, to check the scorers), else `results-13d`.
    static var records: URL? {
        if let d = options?["out"] { return URL(fileURLWithPath: d) }
        return options?["dry"] == "1" ? nil : out
    }

    // MARK: Always: the W arm's mechanism on fixtures

    /// The injected wrong link, keyword-only on the main set with a scripted model: the trap is admitted with the
    /// searched person's attribute, and a claim that pins its text on that person is marked inferred.
    @Test func aWrongLinkIsAdmittedAndItsClaimMarked() async throws {
        let s = FactsSearchGateTests.sets[0]
        let env = try await AnswerGate.env(vault: SearchGate.spike(s.vault), backfill: SearchGate.spike(s.backfill), embeddings: false)
        let uses = try AnswerGate.answerUses(env)
        let model = GateModel(base: nil, id: "claude-code", modelID: "fixture", cache: FileManager.default.temporaryDirectory
            .appending(path: "funes-gate-\(UUID().uuidString)"))
        let search = SearchService(store: env.vault.store, indexer: nil)
        let bodies = try JSONDecoder().decode(SearchGate.VaultFile.self, from: Data(contentsOf: SearchGate.spike(s.vault))).memories
        let body = Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, $0.body) })
        var exercised = 0
        for q in try AnswerGate.questions(SearchGate.spike(s.queries)) where !(q.decoys ?? []).isEmpty {
            let base = AnswerGate.config(.wrong, uses: uses)
            search.facts = base
            guard let w = try await AnswerGate.wrongLink(q, env: env, search: search, config: base) else { continue }
            search.facts = AnswerGate.config(.wrong, uses: uses, links: [env.ids[w.memory]!.db: [w.link]])
            let title = env.titles[w.memory]!, quote = String(body[w.memory]!.prefix(60))
            let name = w.name
            model.fake { prompt in
                guard let ref = AnswerProvider.ref(of: title, in: prompt) else { return ["found": "no", "claims": [] as [Any]] }
                return ["found": "yes", "claims": [["text": "\(name): \(quote)", "citations": [["ref": ref, "quote": quote]]]]]
            }
            let o = try await AnswerGate.answer(q.query, arm: .wrong, search: search, env: env, model: model, rep: 1)
            let a = try #require(o.answer, "\(q.id): \(String(describing: o.error))")
            guard let i = a.readIDs.firstIndex(of: env.ids[w.memory]!) else { continue }     // ranked out of the ten read
            exercised += 1
            #expect(AnswerGate.abouts(o.prompt)[i]?.contains(name) == true, "\(q.id): the trap carries no attribute naming \(name)")
            #expect(a.claims.count == 1 && a.claims.allSatisfy { $0.inference != nil }, "\(q.id): \(a.claims)")
        }
        #expect(exercised >= 3, "only \(exercised) trap questions exercised")
    }

    // MARK: The live gates (opt-in)

    @Test(.enabled(if: options != nil, "FUNES_ANSWER_GATE"))
    func run() async throws {
        let o = try #require(Self.options)
        let dry = o["dry"] == "1"
        if !dry {
            try #require(ProcessInfo.processInfo.environment["FUNES_ANSWER_GATE_LIVE"] == "1",
                         "a live run calls a real model on fixtures and needs the author's go-ahead: set FUNES_ANSWER_GATE_LIVE=1")
        }
        let engine = o["engine"] ?? "haiku"
        let base: (any GenerationProvider)? = dry ? nil : try await Self.client(engine)
        let cache = Self.out.appending(path: "cache-\(engine)")
        let model = GateModel(base: base, id: base?.id ?? (engine == "terra" ? "codex" : "claude-code"),
                              modelID: base?.modelID ?? (engine == "terra" ? "gpt-5.6-terra" : "haiku"), cache: cache)
        let embeddings = o["index"] != "keyword"
        if embeddings { try #require(Fixtures.modelAvailable, Fixtures.modelMissing) }
        let only = Set((o["only"] ?? "").split(separator: ",").map(String.init))
        var summary: [String], written: [URL]
        switch o["gate"] ?? "answers" {
        case "answers":
            (summary, written) = try await answers(engine: engine, model: model, sets: o["sets"]?.split(separator: ",").map(String.init),
                                        arms: Self.arms(o["arms"], default: [.plain, .facts, .wrong]), reps: Int(o["reps"] ?? "3") ?? 3,
                                        only: only, embeddings: embeddings, dry: dry)
        case "spikeg":
            (summary, written) = try await spikeG(engine: engine, model: model, sets: o["sets"]?.split(separator: ",").map(String.init),
                                       arms: Self.arms(o["arms"], default: [.plain, .facts]), reps: Int(o["reps"] ?? "1") ?? 1, only: only,
                                       embeddings: embeddings, dry: dry)
        default:
            Issue.record("gate= answers or spikeg")
            return
        }
        let c = model.counts
        summary.append("")
        summary.append(dry ? "Dry run: \(c.wouldCall) calls a live run would send (\(c.reused) answers already cached)."
                           : "Live: \(c.calls) calls sent, \(c.reused) answers from the cache.")
        let text = summary.joined(separator: "\n")
        FileHandle.standardError.write(Data((text + "\n").utf8))
        // Beside the records (a dry run without `out=` writes none, and no summary either).
        if let root = Self.records {
            let dir = root.appending(path: "answers-\(engine)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appending(path: "calls-\(o["gate"] ?? "answers")\(dry ? "-dry" : "").md"), atomically: true, encoding: .utf8)
        }
        if let first = written.first {
            try Self.manifest(gate: o["gate"] ?? "answers", options: o, model: model, dry: dry, written: written)
                .write(to: first.deletingLastPathComponent().appending(path: "manifest-\(o["gate"] ?? "answers").json"), options: .atomic)
        }
    }

    /// What a run ran with, beside its records (qualify.py and FactsGateEvidence check it): the answer prompt's version,
    /// the registry and Facts prompt versions, the commit and whether the tree was clean, the model every response named,
    /// the calls sent and the answers from the cache, and each record file's digest. A dry run whose every request was
    /// cached is a replay: the code at that commit sends exactly the requests the cached answers were given for.
    static func manifest(gate: String, options: [String: String], model: GateModel, dry: Bool, written: [URL]) throws -> Data {
        func git(_ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", SearchGate.repo.path] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var reported = Set<String>(), without = 0, records = [String: String]()
        for url in written {
            records[url.lastPathComponent] = FactsGateEvidence.sha256(url) ?? ""
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
                // Every answer the model gave (one with nothing to send made no call).
                guard r["outcome"] as? String != "failed", (r["hash"] as? String ?? "").isEmpty == false else { continue }
                if let m = r["model"] as? String { reported.insert(m) } else { without += 1 }
            }
        }
        let c = model.counts
        let mode = dry ? (c.wouldCall == 0 ? "replay" : "dry") : "live"
        let m: [String: Any] = [
            "gate": gate, "mode": mode, "options": options.filter { $0.key != "out" },
            "engine": ["provider": model.id.rawValue, "model": model.modelID],
            "modelsReported": reported.sorted(), "responsesWithoutModel": without,
            "answerPromptVersion": SearchAnswerer.promptVersion, "registryVersion": FactsRegistry.bundled.fingerprint,
            "factsPromptVersions": FactsQualification.promptVersions(.bundled),
            "commit": git(["rev-parse", "HEAD"]), "dirty": !git(["status", "--porcelain", "--untracked-files=no"]).isEmpty,
            "calls": c.calls, "cached": c.reused, "uncached": c.wouldCall, "records": records,
            "date": ISO8601DateFormatter().string(from: Date()),
        ]
        return try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
    }

    static func arms(_ s: String?, default d: [AnswerGate.Arm]) -> [AnswerGate.Arm] {
        guard let s, !s.isEmpty else { return d }
        return s.split(separator: ",").compactMap { AnswerGate.Arm(rawValue: String($0)) }
    }

    /// The app's own client for `engine`, signed in and ready (model providers §5.8): Claude Code with Haiku, or Codex
    /// with GPT-5.6-Terra, both at low effort.
    static func client(_ engine: String) async throws -> any GenerationProvider {
        let name = engine == "terra" ? "codex" : "claude"
        let home = NSHomeDirectory()
        let path = try #require([home + "/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            .first(where: FileManager.default.isExecutableFile(atPath:)), "\(name) isn't installed")
        let client: any SubscriptionClient = engine == "terra"
            ? CodexClient(executable: path, model: "gpt-5.6-terra", allowsFileReads: true)
            : ClaudeCodeClient(executable: path, model: "haiku")
        CLIRunner.unblock(client.id)
        let status = await client.status()
        guard case .ready = status else { throw GateError.notReady("\(name): \(status)") }
        return client
    }

    enum GateError: Error { case notReady(String) }

    // MARK: Answers on linked questions

    func answers(engine: String, model: GateModel, sets: [String]?, arms: [AnswerGate.Arm], reps: Int, only: Set<String>,
                 embeddings: Bool, dry: Bool) async throws -> ([String], [URL]) {
        var written: [URL] = []
        var summary = ["# 13d answer gate: answers on linked questions (\(engine))", ""]
        let probe = GateModel(base: nil, id: model.id, modelID: model.modelID, cache: model.cache)
        for s in FactsSearchGateTests.sets where sets?.contains(s.name) ?? true {
            let env = try await AnswerGate.env(vault: SearchGate.spike(s.vault), backfill: SearchGate.spike(s.backfill), embeddings: embeddings)
            let uses = try AnswerGate.answerUses(env)
            let services = Dictionary(uniqueKeysWithValues: AnswerGate.Arm.allCases.map { arm in
                let svc = SearchService(store: env.vault.store, indexer: env.indexer)
                svc.facts = AnswerGate.config(arm, uses: uses)
                return (arm, svc)
            })
            var records: [[String: Any]] = []
            var included = 0, withW = 0, skipped = 0, trapOut = 0
            for q in try AnswerGate.questions(SearchGate.spike(s.queries)) where q.noAnswerCall != true {
                if !only.isEmpty, !only.contains(q.id) { continue }
                // Which questions: every people question, and any other whose request learned facts change.
                let pP = try await AnswerGate.answer(q.query, arm: .plain, search: services[.plain]!, env: env, model: probe, rep: 1).prompt
                let pF = try await AnswerGate.answer(q.query, arm: .facts, search: services[.facts]!, env: env, model: probe, rep: 1).prompt
                guard q.set == "people" || pP != pF else { skipped += 1; continue }
                included += 1
                let w: (memory: String, entity: String, name: String, link: MemoryLink)?
                if arms.contains(.wrong) {
                    let cfg = AnswerGate.config(.wrong, uses: uses)
                    services[.wrong]!.facts = cfg
                    var found = try await AnswerGate.wrongLink(q, env: env, search: services[.wrong]!, config: cfg)
                    if let l = found {
                        services[.wrong]!.facts = AnswerGate.config(.wrong, uses: uses, links: [env.ids[l.memory]!.db: [l.link]])
                        // Only where the trap reaches the prompt with its wrong attribute (it can rank out of the ten read).
                        let probed = try await AnswerGate.answer(q.query, arm: .wrong, search: services[.wrong]!, env: env, model: probe, rep: 1)
                        let at = probed.answer?.readIDs.firstIndex(of: env.ids[l.memory]!)
                        if at.flatMap({ AnswerGate.abouts(probed.prompt)[$0] })?.contains(l.name) != true {
                            found = nil
                            trapOut += 1
                        }
                    }
                    w = found
                } else {
                    w = nil
                }
                if w != nil { withW += 1 }
                for arm in arms {
                    if arm == .wrong, w == nil { continue }
                    for rep in 1...reps {
                        let o = try await AnswerGate.answer(q.query, arm: arm, search: services[arm]!, env: env, model: model, rep: rep)
                        records.append(AnswerGate.record(o, id: q.id, arm: arm, rep: rep, env: env,
                                                         injected: arm == .wrong ? w.map { ($0.memory, $0.name) } : nil))
                        if !dry {
                            let r = records.last!
                            FileHandle.standardError.write(Data("\(s.name) \(q.id) \(arm.rawValue)\(rep): \(r["outcome"]!), \((r["claims"] as! [Any]).count) claims\(o.cached ? " (cached)" : "")\n".utf8))
                        }
                    }
                }
            }
            let failed = records.filter { $0["outcome"] as? String == "failed" }.count
            let fellBack = records.filter { $0["arm"] as? String != "P" && $0["outcome"] as? String != "failed" && $0["factsRevision"] is NSNull }.count
            let trapUnsent = records.filter { $0["arm"] as? String == "W" && $0["trapSent"] as? Bool != true }.count
            summary.append("- \(s.name) (\(env.index)): \(included) questions (\(skipped) others unchanged by learned facts), "
                           + "\(withW) with a wrong link; \(records.count) answers, \(failed) failed, \(fellBack) F/W without learned facts, "
                           + "\(trapUnsent) W with the trap not sent (\(trapOut) traps ranked out of the read, no W)")
            if let root = Self.records {
                let dir = root.appending(path: "answers-\(engine)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // A partial run (`only=`) never replaces a set's records.
                let file = dir.appending(path: "\(s.name)-r3\(only.isEmpty ? "" : "-only").jsonl")
                try AnswerGate.jsonl(records).write(to: file, atomically: true, encoding: .utf8)
                written.append(file)
            }
        }
        return (summary, written)
    }

    // MARK: Spike G with the feature on

    static let spikeGSets: [(name: String, vault: String, questions: String, backfill: String)] = [
        ("main", "spikes/search-answers/fixtures/vault.json", "spikes/search-answers/fixtures/questions.json",
         "spikes/people/results-search/backfill-r3.json"),
        ("astra", "spikes/search-answers/fixtures/vault-astra.json", "spikes/search-answers/fixtures/questions-astra.json",
         "spikes/people/results-search/backfill-r3.json"),
    ]

    func spikeG(engine: String, model: GateModel, sets: [String]?, arms: [AnswerGate.Arm], reps: Int, only: Set<String>,
                embeddings: Bool, dry: Bool) async throws -> ([String], [URL]) {
        var written: [URL] = []
        var summary = ["# 13d answer gate: Spike G with the feature on (\(engine))", ""]
        for s in Self.spikeGSets where sets?.contains(s.name) ?? true {
            let backfill = SearchGate.repo.appending(path: s.backfill)
            guard FileManager.default.fileExists(atPath: backfill.path) else {
                summary.append("- \(s.name): skipped, no learned facts yet (\(s.backfill))")
                continue
            }
            let env = try await AnswerGate.env(vault: SearchGate.repo.appending(path: s.vault), backfill: backfill, embeddings: embeddings)
            let uses = try AnswerGate.answerUses(env)
            var lines = 0
            for arm in arms where arm != .wrong {
                let svc = SearchService(store: env.vault.store, indexer: env.indexer)
                svc.facts = AnswerGate.config(arm, uses: uses)
                var records: [[String: Any]] = []
                for q in try AnswerGate.questions(SearchGate.repo.appending(path: s.questions)) {
                    if !only.isEmpty, !only.contains(q.id) { continue }
                    for rep in 1...reps {
                        let o = try await AnswerGate.answer(q.query, arm: arm, search: svc, env: env, model: model, rep: rep)
                        var r = AnswerGate.record(o, id: q.id, arm: arm, rep: rep, env: env, injected: nil)
                        // Spike G's record (spikes/search-answers/run.py) for its scorer.
                        r["provider"] = "\(engine)-13d-\(arm.rawValue)"
                        r["called"] = o.answer?.engine != nil || o.error != nil
                        r["ok"] = o.answer != nil
                        records.append(r)
                    }
                }
                lines += records.count
                if let root = Self.records {
                    let dir = root.appending(path: "spike-g-\(engine)")
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let file = dir.appending(path: "\(s.name)-\(arm.rawValue)\(only.isEmpty ? "" : "-only").jsonl")
                    try AnswerGate.jsonl(records).write(to: file, atomically: true, encoding: .utf8)
                    written.append(file)
                }
            }
            summary.append("- \(s.name) (\(env.index)): \(lines) answers")
        }
        return (summary, written)
    }
}
