import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Qualification and gating (memory processing §11.10, FR-F-02): each use of each predicate is on only with a
/// qualification record for the current engine, call-group prompt and registry version; what a use needs is registry
/// data, so turning one off turns off everything downstream with no code change; each call group uses a model that
/// qualified for it.
@Suite(.serialized) struct FactsQualificationTests {
    let reg = FactsRegistry.bundled
    let people: String
    let work: String
    let versions: [String: String]
    let v: TestVault
    let user = ["Dani Ortega", "Dani"]

    init() throws {
        let r = FactsRegistry.bundled
        people = r.callGroups.keys.sorted().first { FactsPrompt.hasPeople($0, r) }!
        work = r.predicate(r.timelinePredicates[0])!.callGroup
        versions = FactsQualification.promptVersions(r)
        v = try TestVault()
    }

    var dated: String { FX.dated }
    var persons: [String] { reg.groupPredicates(people) }
    var sibling: String { FX.personPredicate { $0.lexicon.contains { $0.words.contains("sister") } } }

    static let haiku = FactsEngine(model: "claude-code/claude-haiku-5-5", adapter: "claude-code/1;effort=low")
    static let opus = FactsEngine(model: "claude-code/claude-opus-5-5", adapter: "claude-code/1;effort=low")

    func record(_ predicates: [String], _ uses: [FactsUse], group: String, engine: FactsEngine = FactsQualificationTests.haiku,
                basis: String = "",
                registry: FactsRegistry? = nil) -> FactsQualification.Record {
        let r = registry ?? reg
        return .init(predicates: predicates, uses: uses.map(\.rawValue), basis: basis, callGroup: group, engine: engine,
                     promptVersion: FactsPrompt.version(group, registry: r), registryVersion: r.fingerprint,
                     gate: "test", recordedAt: "2026-11-17")
    }

    // MARK: The registry

    @Test func theUsesAndWhatEachNeedsAreRegistryData() throws {
        #expect(Set(reg.useRules.keys) == Set(FactsUse.allCases.map(\.rawValue)))
        // §11.10: linked needs recorded; timeline and attributes need linked; bridges need timeline.
        #expect(reg.useRules["recorded"]?.requires == [])
        #expect(reg.useRules["linked"]?.requires == ["recorded"])
        #expect(reg.useRules["timeline"]?.requires == ["linked"])
        #expect(reg.useRules["attributes"]?.requires == ["linked"])
        #expect(reg.useRules["bridges"]?.requires == ["timeline"])
        #expect(Set(reg.prerequisites("bridges")) == ["timeline", "linked", "recorded"])
        #expect(throws: FactsRegistry.ValidationError.unknownUse("gossip")) {
            _ = try FX.registry { json in
                var uses = json["uses"] as! [String: Any]
                uses["gossip"] = ["requires": []]
                json["uses"] = uses
            }
        }
        #expect(throws: FactsRegistry.ValidationError.self) {
            _ = try FX.registry { json in
                var uses = json["uses"] as! [String: [String: Any]]
                uses["recorded"] = ["requires": ["bridges"]]
                json["uses"] = uses
            }
        }
        let id = persons[0]
        #expect(throws: FactsRegistry.ValidationError.useWithoutPrerequisite(predicate: id, use: "attributes")) {
            _ = try FX.registry { json in FX.editPredicate(&json, id) { $0["uses"] = ["recorded", "attributes"] } }
        }
    }

    @Test func theFingerprintMovesWithEverythingButAUsesList() throws {
        let base = reg.fingerprint
        #expect(base.hasPrefix(reg.version + "-"))
        let id = persons[0]
        let usesOnly = try FX.registry { json in FX.editPredicate(&json, id) { $0["uses"] = ["recorded", "linked"] } }
        #expect(usesOnly.fingerprint == base)
        let definition = try FX.registry { json in FX.editPredicate(&json, id) { $0["definition"] = "someone else" } }
        #expect(definition.fingerprint != base)
        let language = try FX.registry { json in
            var lang = json["language"] as! [String: Any]
            lang["stop_names"] = (lang["stop_names"] as! [String]) + ["Zqx"]
            json["language"] = lang
        }
        #expect(language.fingerprint != base)
        // A new predicate in a new group: its lexicon is read by every group's validation and parsing.
        let added = try FX.registry { json in
            var groups = json["call_groups"] as! [String: Any]
            groups["study"] = ["intro": "Schools."]
            json["call_groups"] = groups
            var preds = json["predicates"] as! [[String: Any]]
            preds.append(["id": "studies_at", "object_kind": "organization", "call_group": "study", "uses": ["recorded"],
                          "definition": "a school", "exclusive": false, "succession": false, "qualifiers": [String: Any](),
                          "lexicon": [["words": ["zqxschool"]]], "query_cues": [String](), "phrases": [String: String]()])
            json["predicates"] = preds
        }
        #expect(added.fingerprint != base)
        // And the prompt version (part of a record's key) doesn't depend on a uses list either.
        #expect(FactsPrompt.version(people, registry: usesOnly) == versions[people])
    }

    // MARK: What's on

    @Test func aUseIsOnOnlyWithARecordMatchingEveryKeyField() {
        let none = FactsQualification(records: [])
        #expect(none.uses(engines: [people: Self.haiku], registry: reg, promptVersions: versions).predicates(.recorded).isEmpty)
        let r = record(persons, [.recorded, .linked], group: people)
        let q = FactsQualification(records: [r])
        let on = q.uses(engines: [people: Self.haiku], registry: reg, promptVersions: versions)
        #expect(on.predicates(.recorded) == persons && on.predicates(.linked) == persons)
        #expect(on.predicates(.attributes).isEmpty && !on.isOn(dated, .recorded))
        // Each field of the key, changed: off.
        var other = versions
        other[people] = "000000"
        for (engines, pv) in [([people: Self.opus], versions),
                              ([people: FactsEngine(model: Self.haiku.model, adapter: "anthropic")], versions),
                              ([people: FactsEngine(model: Self.haiku.model, adapter: Self.haiku.adapter, batching: "one-memory;pipeline=0")], versions),
                              ([work: Self.haiku], versions),
                              ([people: Self.haiku], other)] {
            #expect(q.uses(engines: engines, registry: reg, promptVersions: pv).predicates(.recorded).isEmpty, "\(engines) \(pv)")
        }
        var stale = r
        stale.registryVersion = reg.version + "-000000000000"
        #expect(FactsQualification(records: [stale]).uses(engines: [people: Self.haiku], registry: reg, promptVersions: versions)
            .predicates(.recorded).isEmpty)
        // A use the registry doesn't declare for the predicate stays off.
        let undeclared = record(persons, [.recorded, .linked, .timeline], group: people)
        #expect(FactsQualification(records: [undeclared]).uses(engines: [people: Self.haiku], registry: reg, promptVersions: versions)
            .predicates(.timeline).isEmpty)
        // A model alias never matches a record that names the full model.
        let alias = FactsEngine(model: "claude-code/haiku", adapter: Self.haiku.adapter)
        #expect(q.uses(engines: [people: alias], registry: reg, promptVersions: versions).predicates(.recorded).isEmpty)
    }

    @Test func aUseNeedsWhatTheRegistrySaysItNeeds() {
        // A record for linked and attributes without recorded turns nothing on.
        let q = FactsQualification(records: [record(persons, [.linked, .attributes], group: people)])
        let on = q.uses(engines: [people: Self.haiku], registry: reg, promptVersions: versions)
        #expect(on.predicates(.linked).isEmpty && on.predicates(.attributes).isEmpty)
        // A basis-scoped record needs the unscoped use.
        let scoped = record(persons, [.attributes], group: people, basis: "sole_known")
        let base = record(persons, [.recorded, .linked], group: people)
        var u = FactsQualification(records: [base, scoped]).uses(engines: [people: Self.haiku], registry: reg, promptVersions: versions)
        #expect(!u.isOn(sibling, .attributes, basis: "sole_known"))
        let full = record(persons, [.recorded, .linked, .attributes], group: people)
        u = FactsQualification(records: [full, scoped]).uses(engines: [people: Self.haiku], registry: reg, promptVersions: versions)
        #expect(u.isOn(sibling, .attributes) && u.isOn(sibling, .attributes, basis: "sole_known"))
    }

    /// FR-F-02's acceptance: turning linking off turns attributes and bridges off too, with no code change.
    @Test func turningLinkingOffTurnsAttributesAndBridgesOff() throws {
        let workRecord = record(reg.groupPredicates(work), FactsUse.allCases, group: work)
        let personRecord = record(persons, FactsUse.allCases, group: people)
        let q = FactsQualification(records: [workRecord, personRecord])
        let engines = [people: Self.haiku, work: Self.haiku]
        var on = try v.store.writer.read { db in try q.withOffSwitches(db) }.uses(engines: engines, registry: reg, promptVersions: versions)
        #expect(FactsUse.allCases.allSatisfy { on.isOn(dated, $0) })
        #expect([FactsUse.recorded, .linked, .attributes].allSatisfy { on.isOn(sibling, $0) })
        try v.store.writer.write { db in
            try FactsQualification.turnOff(db, predicate: dated, use: .linked, under: workRecord, gate: "two-week review: 1 wrong", now: t0)
            try FactsQualification.turnOff(db, predicate: sibling, use: .linked, under: personRecord, gate: "two-week review: 1 wrong", now: t0)
        }
        on = try v.store.writer.read { db in try q.withOffSwitches(db) }.uses(engines: engines, registry: reg, promptVersions: versions)
        #expect(on.isOn(dated, .recorded) && on.isOn(sibling, .recorded))
        for use in [FactsUse.linked, .timeline, .attributes, .bridges] {
            #expect(!on.isOn(dated, use), "\(use)")
            #expect(!on.isOn(sibling, use), "\(use)")
        }
        // The other predicates of the pool keep theirs.
        #expect(persons.filter { $0 != sibling }.allSatisfy { on.isOn($0, .attributes) })
        // Remove learned facts doesn't touch the off-switches, and a local row never turns anything on.
        try v.store.writer.write { db in
            _ = try FactStore.removeLearnedFacts(db, now: t0)
            try db.execute(sql: "UPDATE fact_qualification SET passed = 1 WHERE predicate = ?", arguments: [sibling])
        }
        #expect(try v.count("SELECT COUNT(*) FROM fact_qualification") == 2)
        on = try v.store.writer.read { db in try FactsQualification(records: []).withOffSwitches(db) }
            .uses(engines: engines, registry: reg, promptVersions: versions)
        #expect(!on.isOn(sibling, .recorded))
    }

    @Test func anotherDependencyGraphCascadesDifferentlyWithNoCodeChange() throws {
        // As data: attributes need the timeline. Turning the timeline off now takes attributes too.
        let edited = try FX.registry { json in
            var uses = json["uses"] as! [String: [String: Any]]
            uses["attributes"] = ["requires": ["timeline"]]
            json["uses"] = uses
            for p in json["predicates"] as! [[String: Any]] where (p["uses"] as! [String]).contains("attributes")
                && !(p["uses"] as! [String]).contains("timeline") {
                FX.editPredicate(&json, p["id"] as! String) { $0["uses"] = ["recorded", "linked"] }
            }
        }
        let versions = FactsQualification.promptVersions(edited)
        let r = record(edited.groupPredicates(work), FactsUse.allCases, group: work, registry: edited)
        var q = FactsQualification(records: [r])
        #expect(q.uses(engines: [work: Self.haiku], registry: edited, promptVersions: versions).isOn(dated, .attributes))
        q.off.insert(r.key(dated, FactsUse.timeline.rawValue))
        let on = q.uses(engines: [work: Self.haiku], registry: edited, promptVersions: versions)
        #expect(on.isOn(dated, .linked) && !on.isOn(dated, .attributes) && !on.isOn(dated, .bridges))
    }

    // MARK: The model per call group

    @Test func opusReadsPeopleOnlyWhereItQualifiedAndWorkStaysOnHaiku() {
        let providers = (haiku: Fake(model: "claude-haiku-5-5"), opus: Fake(model: "claude-opus-5-5"))
        let opusPeople = record(persons, [.recorded, .linked, .attributes], group: people, engine: FactsEngine(providers.opus))
        let haikuAll = reg.callGroups.keys.map { record(reg.groupPredicates($0), [.recorded, .linked], group: $0, engine: FactsEngine(providers.haiku)) }
        var q = FactsQualification(records: [opusPeople] + haikuAll)
        var got = q.resolve(chosen: providers.opus, fallback: providers.haiku, registry: reg, promptVersions: versions)
        #expect(got[people]?.modelID == "claude-opus-5-5" && got[work]?.modelID == "claude-haiku-5-5")
        // Without a work record for Haiku, the work group has no model: its calls stop.
        q = FactsQualification(records: [opusPeople])
        got = q.resolve(chosen: providers.opus, fallback: providers.haiku, registry: reg, promptVersions: versions)
        #expect(got[people]?.modelID == "claude-opus-5-5" && got[work] == nil)
        // Opus's people record turned off: people falls back to Haiku.
        q = FactsQualification(records: [opusPeople] + haikuAll)
        for p in persons { q.off.insert(opusPeople.key(p, FactsUse.recorded.rawValue)) }
        got = q.resolve(chosen: providers.opus, fallback: providers.haiku, registry: reg, promptVersions: versions)
        #expect(got[people]?.modelID == "claude-haiku-5-5")
        // Nothing qualified (what ships until the Gates step): no model at all.
        #expect(FactsQualification.bundled.resolve(chosen: providers.opus, fallback: providers.haiku, registry: reg,
                                                   promptVersions: versions).isEmpty)
    }

    struct Fake: GenerationProvider {
        let id: ProviderID = ClaudeCodeClient.providerID
        let locality = Locality.cloud
        let modelID: String
        var factsAdapter: String { "claude-code/1;effort=low" }
        init(model: String) { modelID = model }
        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            throw ProviderError.unavailable
        }
    }

    @Test func theClaudeCodeAdapterNamesItsRevisionAndEffort() {
        let c = ClaudeCodeClient(executable: "/usr/bin/false", model: "claude-haiku-5-5", effort: "low")
        #expect(FactsEngine(c) == FactsEngine(model: "claude-code/claude-haiku-5-5", adapter: "claude-code/1;effort=low",
                                              batching: FactsExtractor.batching))
        #expect(ClaudeCodeClient(executable: "/usr/bin/false", model: "claude-haiku-5-5", effort: "high").factsAdapter != c.factsAdapter)
    }

    // MARK: The shipped records

    /// Why a record can't turn anything on now, or [] when it can: its key against the code that runs now, what it turns
    /// on within the whole shipped bundle (a timeline record rests on the linked record beside it), and its evidence.
    static func problems(_ r: FactsQualification.Record, bundle: [FactsQualification.Record]? = nil, registry: FactsRegistry,
                         versions: [String: String]) -> [String] {
        keyProblems(r, bundle: bundle ?? [r], registry: registry, versions: versions) + FactsGateEvidence.problems(r, registry: registry)
    }

    static func keyProblems(_ r: FactsQualification.Record, bundle: [FactsQualification.Record], registry: FactsRegistry,
                            versions: [String: String]) -> [String] {
        var out: [String] = []
        if versions[r.callGroup] != r.promptVersion { out.append("prompt version") }
        if registry.fingerprint != r.registryVersion { out.append("registry version") }
        if r.batching != FactsExtractor.batching { out.append("batching") }
        // The adapters' current revisions.
        for (id, rev) in [(ClaudeCodeClient.providerID.rawValue, ClaudeCodeClient.adapterRevision), (CodexClient.providerID.rawValue, CodexClient.adapterRevision)]
        where r.adapter.hasPrefix(id + "/") && !r.adapter.hasPrefix("\(id)/\(rev);") { out.append("adapter revision") }
        // And it turns on what it lists, for its own engine, with the bundle's other records (its uses' prerequisites).
        let mine = bundle.filter { $0.engine == r.engine && $0.callGroup == r.callGroup }
        let on = FactsQualification(records: mine).uses(engines: [r.callGroup: r.engine], registry: registry, promptVersions: versions)
        for p in r.predicates { for u in r.uses where !on.isOn(p, FactsUse(rawValue: u) ?? .recorded, basis: r.basis) { out.append("\(p) \(u) stays off") } }
        for p in r.predicates {
            guard let pred = registry.predicate(p), pred.callGroup == r.callGroup else { out.append("\(p) isn't in \(r.callGroup)"); continue }
            for u in r.uses where !pred.uses.contains(u) { out.append("\(p) doesn't declare \(u)") }
        }
        return out
    }

    /// A prompt, registry or pipeline change without re-running the gates fails here, rather than silently turning Facts
    /// off in the app; so does a record whose evidence doesn't show its gate passed on live runs of exactly its key.
    @Test func everyShippedRecordMatchesWhatRunsNow() {
        let bundle = FactsQualification.bundled.records
        // An open privacy finding (a known issue in the privacy gate) blocks every record until it's fixed or accepted.
        if FactsPrivacyGateTests.openFindings > 0 { #expect(bundle.isEmpty, "a record ships with an open privacy finding") }
        for r in bundle {
            let p = Self.problems(r, bundle: bundle, registry: reg, versions: versions)
            #expect(p.isEmpty, "\(r.callGroup) \(r.uses): \(p)")
        }
        // The key check isn't vacuous: a record from before a registry change, or an old adapter, fails it.
        var stale = record(persons, [.recorded], group: people)
        #expect(Self.keyProblems(stale, bundle: [stale], registry: reg, versions: versions).isEmpty)
        stale.registryVersion = "v1-000000000000"
        #expect(Self.keyProblems(stale, bundle: [stale], registry: reg, versions: versions).first == "registry version")
        let linkedOnly = record(persons, [.linked], group: people)
        #expect(Self.keyProblems(linkedOnly, bundle: [linkedOnly], registry: reg, versions: versions).contains { $0.hasSuffix("stays off") })
        let oldAdapter = record(persons, [.recorded], group: people, engine: FactsEngine(model: Self.haiku.model, adapter: "claude-code/0;effort=low"))
        #expect(Self.keyProblems(oldAdapter, bundle: [oldAdapter], registry: reg, versions: versions) == ["adapter revision"])
        // The bundle, not the record alone: a timeline record rests on the linked record beside it.
        let wa = reg.timelinePredicates[0]
        let timeline = record([wa], [.timeline], group: work), linked = record([wa], [.recorded, .linked], group: work)
        #expect(Self.keyProblems(timeline, bundle: [timeline], registry: reg, versions: versions).contains { $0.hasSuffix("stays off") })
        #expect(Self.keyProblems(timeline, bundle: [timeline, linked], registry: reg, versions: versions).isEmpty)
        // Without evidence, nothing qualifies.
        #expect(Self.problems(record(persons, [.recorded, .linked], group: people), registry: reg, versions: versions) == ["no scores.json in the evidence"])
    }

    // MARK: Evidence (synthetic gate runs; no record ships)

    /// A synthetic gate run of the person pool: manifests of both reads for every set, scores that pass, port fidelity.
    func syntheticEvidence(_ dir: URL, change: (inout [String: Any], String, String) -> Void = { _, _, _ in },
                           scores: (inout [String: Any]) -> Void = { _ in }) throws -> FactsQualification.Record {
        let r = record(persons, [.recorded, .linked], group: people)
        let fm = FileManager.default
        var evidence: [String] = []
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let pf = dir.appending(path: "port-fidelity.json")
        let pairs = FactsGateEvidence.standardPairs.map { n -> [String: Any] in
            let p = n.split(separator: " ").map(String.init)
            return ["set": p[0], "mode": p[1], "plays": 3, "expected_plays": 3]
        }
        try JSONSerialization.data(withJSONObject: ["pass": true, "commit": String(repeating: "a", count: 40), "pairs": pairs]).write(to: pf)
        var measures: [String: Any] = [:]
        for rd in ["r1", "r2"] {
            let d = dir.appending(path: "swift-claude-claude-haiku-5-5-gates-\(rd)")
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            var sets: [String: Any] = [:]
            for set in ["main", "astra", "mixed", "persons"] {
                var m: [String: Any] = [
                    "set": set, "label": "swift-claude-claude-haiku-5-5-gates-\(rd)", "mode": "live", "commit": String(repeating: "a", count: 40),
                    "run_id": "\(set)-\(rd)", "engine": ["model": r.model, "adapter": r.adapter, "batching": r.batching],
                    "prompt_versions": versions, "registry_version": reg.fingerprint, "registry_file": "bundled",
                    "models_reported": ["claude-haiku-5-5"], "responses": 10, "responses_without_model": 0, "options": ["set": set],
                    "plays": 2, "plays_expected": 2, "plays_list": ["a#0", "a#1"],
                    "fixture_sha256": FactsGateEvidence.sha256(FactsHarness.fixtureURL(set))!,
                    "groups": set == "mixed" ? [people, work] : [people], "unsettled": 0, "above_limit_in_payload": 0,
                    "limit": "internal",
                ]
                let lines = d.appending(path: "\(set).jsonl")
                try Data("{}\n".utf8).write(to: lines)
                m["lines_sha256"] = FactsGateEvidence.sha256(lines)!
                change(&m, set, rd)
                let f = d.appending(path: "\(set)-manifest.json")
                try JSONSerialization.data(withJSONObject: m).write(to: f)
                evidence += [f.path, lines.path]
                sets[set] = ["people": ["full_right": 99, "full_wrong": 1, "recall_right": 95, "recall_truth": 100,
                                        "full_by_predicate": Dictionary(uniqueKeysWithValues: persons.map { ($0, 6) })]]
            }
            measures[rd] = sets
        }
        var sc: [String: Any] = ["measures": measures, "port_fidelity": ["pass": true, "sha256": FactsGateEvidence.sha256(pf)!]]
        scores(&sc)
        let sf = dir.appending(path: "scores.json")
        try JSONSerialization.data(withJSONObject: sc).write(to: sf)
        var out = r
        out.evidence = evidence + [sf.path, pf.path]
        return out
    }

    @Test func aRecordsEvidenceIsCheckedAgainstItsKeyItsRunsAndThePassTable() throws {
        func check(change: @escaping (inout [String: Any], String, String) -> Void = { _, _, _ in },
                   scores: @escaping (inout [String: Any]) -> Void = { _ in }) throws -> [String] {
            let dir = FileManager.default.temporaryDirectory.appending(path: "facts-gates-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let r = try syntheticEvidence(dir, change: change, scores: scores)
            return Self.problems(r, registry: reg, versions: versions)
        }
        #expect(try check() == [])
        // Each run check fails on its own.
        let runCases: [(String, (inout [String: Any], String, String) -> Void)] = [
            ("dirty", { m, _, _ in m["commit"] = String(repeating: "a", count: 40) + "+dirty" }),
            ("two commits", { m, _, rd in if rd == "r2" { m["commit"] = String(repeating: "b", count: 40) } }),
            ("replay", { m, s, _ in if s == "main" { m["mode"] = "replay" } }),
            ("alias reply", { m, s, _ in if s == "astra" { m["models_reported"] = ["claude-haiku-5-5-20261101"] } }),
            ("unidentified", { m, s, _ in if s == "astra" { m["responses_without_model"] = 3 } }),
            ("partial", { m, s, _ in if s == "persons" { m["options"] = ["only": "p01"] } }),
            ("incomplete", { m, s, _ in if s == "persons" { m["plays"] = 1 } }),
            ("fixture changed", { m, s, _ in if s == "mixed" { m["fixture_sha256"] = String(repeating: "0", count: 64) } }),
            ("prompt", { m, _, _ in m["prompt_versions"] = [self.people: "000000000000"] }),
            ("registry", { m, _, _ in m["registry_file"] = "spikes/people/fixtures/canary-13a2/registry.json" }),
            ("adapter", { m, _, _ in m["engine"] = ["model": Self.haiku.model, "adapter": "claude-code/1;effort=high", "batching": FactsExtractor.batching] }),
            ("group", { m, s, _ in if s == "main" { m["groups"] = [self.work] } }),
            ("repeated run", { m, s, _ in if s == "main" { m["run_id"] = "same" } }),
            ("one read", { m, _, rd in if rd == "r2" { m["label"] = "swift-claude-claude-haiku-5-5-gates-r1" } }),
            ("leak", { m, s, _ in if s == "persons" { m["above_limit_in_payload"] = 1 } }),
            ("secret limit", { m, _, _ in m["limit"] = "secret" }),
            ("lines changed", { m, s, _ in if s == "astra" { m["lines_sha256"] = String(repeating: "0", count: 64) } }),
        ]
        for (name, change) in runCases { #expect(try !check(change: change).isEmpty, "\(name)") }
        // And the pass table: a threshold missed, a read missing, port fidelity not the scored report.
        #expect(try !check(scores: { s in
            var m = s["measures"] as! [String: Any]; var r1 = m["r1"] as! [String: Any]
            r1["persons"] = ["people": ["full_right": 90, "full_wrong": 10, "recall_right": 95, "recall_truth": 100, "full_by_predicate": [:]]]
            m["r1"] = r1; s["measures"] = m
        }).isEmpty)
        #expect(try !check(scores: { s in var m = s["measures"] as! [String: Any]; m["r2"] = nil; s["measures"] = m }).isEmpty)
        #expect(try !check(scores: { s in s["port_fidelity"] = ["pass": true, "sha256": "x"] }).isEmpty)
    }

    @Test func aRecordWithNoThirteenATwoGateFails() {
        let wa = reg.timelinePredicates[0]
        for r in [record(persons, [.recorded, .linked, .attributes], group: people), record(persons, [.attributes], group: people, basis: "sole_known"),
                  record([wa], [.recorded, .linked, .timeline, .bridges], group: work), record(Array(persons.prefix(3)), [.recorded, .linked], group: people)] {
            #expect(FactsGateEvidence.gate(for: r, registry: reg) == nil, "\(r.uses) \(r.basis)")
            #expect(FactsGateEvidence.problems(r, registry: reg).first?.hasPrefix("no 13a.2 gate") == true)
        }
        #expect(FactsGateEvidence.gate(for: record(persons, [.recorded, .linked], group: people), registry: reg)?.id == "persons")
        #expect(FactsGateEvidence.gate(for: record([wa], [.timeline], group: work), registry: reg) == nil)   // measured only
    }

    @Test func nothingIsQualifiedYet() {
        // 13a.2's Gates step writes the first records (the plan's status note says what evidence they need).
        #expect(FactsQualification.bundled.records.isEmpty)
        let on = FactsQualification.bundled.uses(engines: [people: Self.haiku, work: Self.haiku], registry: reg, promptVersions: versions)
        #expect(FactsUse.allCases.allSatisfy { on.predicates($0).isEmpty })
    }

    // MARK: The write side

    func memory(_ text: String, days: Double = 0) throws -> String {
        let (title, body) = FactsHarness.split(text)
        return try v.memory(title, body, sensitivity: .low, now: t0.plus(days: days)).id.db
    }

    func extractor(_ provider: any GenerationProvider, _ q: FactsQualification) -> FactsExtractor {
        let clock = FactsHarness.Clock()
        var x = FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.internal), factsModel: provider),
                               activity: InMemoryActivityLog(), userAliases: user, qualification: q)
        x.clock = { clock.now() }
        return x
    }

    func records(for provider: any GenerationProvider, people preds: [String]? = nil, work workUses: [FactsUse]? = nil) -> FactsQualification {
        var out = [record(preds ?? persons, [.recorded, .linked, .attributes], group: people, engine: FactsEngine(provider))]
        if let workUses { out.append(record(reg.groupPredicates(work), workUses, group: work, engine: FactsEngine(provider))) }
        return FactsQualification(records: out)
    }

    @Test func anUnqualifiedGroupMakesNoCall() async throws {
        let id = try memory("My sister Maria lives in Lisbon. I joined Acme in 2019.")
        let scripted = FactsExtractorTests.Scripted { _ in [:] }
        // What ships: no record, so no call for either group.
        var report = try await extractor(scripted, .bundled).learn([id])
        #expect(scripted.seen.withLock { $0.count } == 0)
        #expect(report.calls.allSatisfy { $0.outcome == .codeOnly && $0.dropped == [FactsExtractor.unqualified] })
        #expect(try v.count("SELECT COUNT(*) FROM facts_run WHERE engine = 'code'") == 2)
        // The people group qualified, work not: one call, for people.
        report = try await extractor(scripted, records(for: scripted)).learn([id])
        #expect(scripted.seen.withLock { $0.map(\.instructions) }.count == 1)
        #expect(report.calls.first { $0.group == work }?.outcome == .codeOnly)
        #expect(report.calls.first { $0.group == people }?.outcome == .applied)
    }

    @Test func aPredicateThatIsntRecordedIsDroppedHiddenAndNotAsked() async throws {
        let sib = sibling
        let friend = FX.personPredicate { $0.lexicon.contains { $0.words.contains("friend") } }
        let first = try memory("My sister Maria lives in Lisbon. My friend Tom paints.")
        let answer: @Sendable (StructuredRequest<FactsJSON>) -> [String: Any] = { _ in
            ["people": [["name": "Maria", "quote": "My sister Maria", "person": "new"], ["name": "Tom", "quote": "My friend Tom", "person": "new"]],
             "facts": [FactsExtractorTests.fact("My sister Maria", sib, "Maria", label: "sister"),
                       FactsExtractorTests.fact("My friend Tom", friend, "Tom", label: "friend")]]
        }
        let scripted = FactsExtractorTests.Scripted(answer)
        // Every person predicate but the sibling one is recorded: its fact is dropped, and that's not the model's error.
        let partial = records(for: scripted, people: persons.filter { $0 != sib })
        let report = try await extractor(scripted, partial).learn([first], groups: [people])
        #expect(report.calls.first?.dropped.contains(FactsExtractor.unqualifiedPredicate) == true)
        #expect(try v.count("SELECT COUNT(*) FROM fact WHERE predicate = '\(sib)'") == 0)
        #expect(try v.count("SELECT COUNT(*) FROM fact WHERE predicate = '\(friend)'") == 1)
        // Its role phrases aren't asked about.
        let asked = try #require(try extractor(scripted, partial).prepare(first, group: people))
        #expect(asked.phrases.map(\.predicate) == [friend])

        // Read with every person predicate recorded, then the sibling one turned off: its earlier fact is hidden from the
        // graph every path reads (rosters, phrases, resolution), but stays stored; a fact the user entered stays shown.
        let everyone = records(for: scripted)
        let x = extractor(scripted, everyone)
        try await x.learn([first], groups: [people])
        #expect(try v.count("SELECT COUNT(*) FROM fact WHERE predicate = '\(sib)'") == 1)
        try await v.store.writer.write { db in
            try FactsQualification.turnOff(db, predicate: sib, use: .recorded, under: everyone.records[0], gate: "test", now: t0)
        }
        let later = try memory("My sister called.", days: 1)
        let a = try #require(try x.prepare(later, group: people))
        #expect(!a.graph.facts.contains { $0.predicate == sib })
        #expect(a.graph.facts.contains { $0.predicate == friend })
        #expect(a.phrases.isEmpty)
        #expect(!a.roster.text.contains(sib))
        #expect(try v.count("SELECT COUNT(*) FROM fact WHERE predicate = '\(sib)'") == 1)
        try await v.store.writer.write { db in
            _ = try FactStore.addManualFact(db, predicate: sib, name: "Lucía", sensitivity: Sensitivity.low.rawValue, now: t0)
        }
        let b = try #require(try x.prepare(later, group: people))
        let mine = b.graph.facts.filter { $0.predicate == sib }
        #expect(mine.count == 1 && mine[0].assertions.allSatisfy(\.fromUser))
    }

    @Test func theRosterLimitIsTheStrictestGroupModels() {
        let local = FactsExtractorTests.Scripted(locality: .localServer) { _ in [:] }
        let cloud = FactsExtractorTests.Scripted { _ in [:] }
        func x(_ models: [String: any GenerationProvider]) -> FactsExtractor {
            FactsExtractor(store: v.store, router: ModelRouter(classifier: nil, onDevice: nil, cloudLimit: .upTo(.internal), factsModels: models),
                           activity: InMemoryActivityLog(), qualification: .unchecked)
        }
        // One group on a cloud model: every group's roster, and the sweep, are built under the cloud limit.
        #expect(x([people: local, work: cloud]).rosterLimit == .upTo(.internal))
        #expect(x([people: local, work: local]).rosterLimit == nil)
        #expect(x([people: local]).modelAllowed(work, .everyDeclared(reg)) == false)
    }

    @Test func aReReadWithAPredicateHiddenKeepsItsRows() async throws {
        let sib = sibling
        let friend = FX.personPredicate { $0.lexicon.contains { $0.words.contains("friend") } }
        let id = try memory("My sister Maria lives in Lisbon. My friend Tom paints. I have three sisters.")
        let scripted = FactsExtractorTests.Scripted { _ in
            ["people": [["name": "Maria", "quote": "My sister Maria", "person": "new"], ["name": "Tom", "quote": "My friend Tom", "person": "new"]],
             "facts": [FactsExtractorTests.fact("My sister Maria", sib, "Maria", label: "sister"),
                       FactsExtractorTests.fact("My friend Tom", friend, "Tom", label: "friend")]]
        }
        let everyone = records(for: scripted)
        let x = extractor(scripted, everyone)
        try await x.learn([id], groups: [people])
        let evidence = "SELECT COUNT(*) FROM fact_evidence e JOIN fact f ON f.id = e.fact_id WHERE f.predicate = '\(sib)'"
        let before = try v.count(evidence)
        #expect(before >= 1)
        try await v.store.writer.write { db in
            try FactsQualification.turnOff(db, predicate: sib, use: .recorded, under: everyone.records[0], gate: "test", now: t0)
        }
        // The same version read again in full: the friend's rows are replaced, the sibling's stay stored, hidden.
        try await x.learn([id], groups: [people], kind: "reread")
        #expect(try v.count(evidence) == before)
        var g = try await v.store.writer.read { db in try FactStore.load(db, registry: reg, userAliases: user, uses: try x.currentUses(db)).graph }
        #expect(!g.facts.contains { $0.predicate == sib } && g.facts.contains { $0.predicate == friend })
        // Its role group ("three sisters") is hidden too, from the graph and the roster.
        #expect(!g.entities.values.contains { $0.group?.predicate == sib })
        let a = try #require(try x.prepare(id, group: people))
        #expect(!a.roster.lines.contains { $0.text.contains(sib) })
        // Turned back on: shown again, with no re-read.
        try await v.store.writer.write { db in try db.execute(sql: "DELETE FROM fact_qualification") }
        g = try await v.store.writer.read { db in try FactStore.load(db, registry: reg, userAliases: user, uses: try x.currentUses(db)).graph }
        #expect(g.facts.contains { $0.predicate == sib })
    }

    /// A provider that turns the people group's recorded uses off while its first call runs, then answers badly.
    final class TurnsOffThenFails: GenerationProvider, @unchecked Sendable {
        let id: ProviderID = "anthropic"
        let locality = Locality.cloud
        let modelID = "scripted"
        let calls = Mutex(0)
        let turnOff: @Sendable () throws -> Void
        init(_ turnOff: @escaping @Sendable () throws -> Void) { self.turnOff = turnOff }
        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            calls.withLock { $0 += 1 }
            try turnOff()
            throw ProviderError.invalidOutput
        }
    }

    @Test func aRetryAfterAUseIsTurnedOffStartsOver() async throws {
        let id = try memory("My friend Tom paints.")
        let store = v.store, persons = persons
        let provider = TurnsOffThenFails { }
        let q = records(for: provider)
        let record = q.records[0]
        let off = TurnsOffThenFails {
            try store.writer.write { db in
                for p in persons { try FactsQualification.turnOff(db, predicate: p, use: .recorded, under: record, gate: "test", now: t0) }
            }
        }
        let report = try await extractor(off, q).learn([id], groups: [people])
        #expect(off.calls.withLock { $0 } == 1)
        #expect(report.calls.first?.outcome == .changed && report.calls.first?.dropped == [FactsExtractor.qualificationChanged])
    }

    // MARK: The read side

    @Test func theTimelineAnswersOnlyWhileItsUseIsOn() {
        let rows: [FactRowConvertible] = [fact(dated, "Acme", "2015", "2018", status: .former), fact(dated, "Initech", "2019", status: .current)]
        var s = stateWith(rows)
        let q = "What was my job before Initech?"
        let it = s.intent(q)
        #expect(it != nil && s.name(s.answer(it!, query: q).entity) == "Acme")
        let words = reg.lexicon.filter { $0.value.predicate == dated }.map(\.key).sorted()
        let text = "At my \(reg.language.dateCueWords[0]) \(words[0]) I used Emacs."
        let mem = FactsMemory(id: "mx", text: text, written: "2020-06-01")
        let ph = s.rolePhrases(text)[0]
        #expect(s.resolve(mem, ph).basis == .inferred)

        // Recorded and linked, but the timeline off.
        let q2 = FactsQualification(records: [record(reg.groupPredicates(work), [.recorded, .linked], group: work)])
        s.uses = q2.uses(engines: [work: Self.haiku], registry: reg, promptVersions: versions)
        #expect(s.intent(q) == nil)
        #expect(s.answer(it!, query: q).entities.isEmpty)
        #expect(s.before(dated, .entity(s.entities.values.first { $0.name == "Initech" }!.id)).entities.isEmpty)
        let y2016 = DateRange(lo: DayNumber.from(year: 2016, month: 1, day: 1)!, hi: DayNumber.from(year: 2016, month: 12, day: 31)!,
                              precision: .year)
        #expect(s.inRange(dated, y2016).entities.isEmpty)
        #expect(s.previousAsOf(dated, written: "2020-06-01") == nil)
        // A stored decision for the time cue doesn't resolve it either.
        let acme = s.entities.values.first { $0.name == "Acme" }!.id
        s.decisions[FactsGraph.DecisionKey(memoryID: mem.id, start: ph.start)] = MentionDecision(entity: acme, basis: .context)
        let got = s.resolve(mem, ph)
        #expect(got.entity == nil && got.basis == .candidates)

        // Nothing on: no role phrase at all.
        s.uses = .none(reg)
        #expect(s.rolePhrases(text).isEmpty)
    }
}
