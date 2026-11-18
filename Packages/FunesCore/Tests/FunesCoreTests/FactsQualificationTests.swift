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

    /// Why a record can't turn anything on now, or [] when it can.
    static func problems(_ r: FactsQualification.Record, registry: FactsRegistry, versions: [String: String]) -> [String] {
        var out: [String] = []
        if versions[r.callGroup] != r.promptVersion { out.append("prompt version") }
        if registry.fingerprint != r.registryVersion { out.append("registry version") }
        if r.batching != FactsExtractor.batching { out.append("batching") }
        // The adapters' current revisions.
        for (id, rev) in [(ClaudeCodeClient.providerID.rawValue, ClaudeCodeClient.adapterRevision), (CodexClient.providerID.rawValue, CodexClient.adapterRevision)]
        where r.adapter.hasPrefix(id + "/") && !r.adapter.hasPrefix("\(id)/\(rev);") { out.append("adapter revision") }
        // And it turns on what it lists, for its own engine (its uses' prerequisites included).
        let on = FactsQualification(records: [r]).uses(engines: [r.callGroup: r.engine], registry: registry, promptVersions: versions)
        for p in r.predicates { for u in r.uses where !on.isOn(p, FactsUse(rawValue: u) ?? .recorded, basis: r.basis) { out.append("\(p) \(u) stays off") } }
        for p in r.predicates {
            guard let pred = registry.predicate(p), pred.callGroup == r.callGroup else { out.append("\(p) isn't in \(r.callGroup)"); continue }
            for u in r.uses where !pred.uses.contains(u) { out.append("\(p) doesn't declare \(u)") }
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for e in r.evidence where !FileManager.default.fileExists(atPath: repo.appending(path: e).path) { out.append("missing \(e)") }
        if r.evidence.isEmpty { out.append("no evidence") }
        return out
    }

    /// A prompt, registry or pipeline change without re-running the gates fails here, rather than silently turning Facts
    /// off in the app.
    @Test func everyShippedRecordMatchesWhatRunsNow() {
        for r in FactsQualification.bundled.records {
            #expect(Self.problems(r, registry: reg, versions: versions).isEmpty, "\(r.callGroup) \(r.uses): \(Self.problems(r, registry: reg, versions: versions))")
        }
        // The check isn't vacuous: a record from before a registry change, or without evidence, fails it.
        var stale = record(persons, [.recorded], group: people)
        stale.evidence = ["spikes/people/results-13a2/report.md"]
        #expect(Self.problems(stale, registry: reg, versions: versions).isEmpty)
        stale.registryVersion = "v1-000000000000"
        #expect(Self.problems(stale, registry: reg, versions: versions).first == "registry version")
        var linkedOnly = record(persons, [.linked], group: people)
        linkedOnly.evidence = ["spikes/people/results-13a2/report.md"]
        #expect(Self.problems(linkedOnly, registry: reg, versions: versions).contains { $0.hasSuffix("stays off") })
        var oldAdapter = record(persons, [.recorded], group: people, engine: FactsEngine(model: Self.haiku.model, adapter: "claude-code/0;effort=low"))
        oldAdapter.evidence = ["spikes/people/results-13a2/report.md"]
        #expect(Self.problems(oldAdapter, registry: reg, versions: versions) == ["adapter revision"])
        stale = record(persons, [.recorded], group: people)
        #expect(Self.problems(stale, registry: reg, versions: versions) == ["no evidence"])
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
