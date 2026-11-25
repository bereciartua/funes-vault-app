import Foundation
import GRDB

/// One of ADR-0032 decision 9's five paths. What each needs on first is registry data (`FactsRegistry.useRules`), so
/// turning one off turns off everything downstream of it with no code change.
public enum FactsUse: String, CaseIterable, Sendable {
    case recorded, linked, timeline, attributes, bridges
}

/// What a qualification record was measured with, besides the prompt and the registry (memory processing §11.10).
public struct FactsEngine: Hashable, Sendable {
    /// `<provider id>/<model id>`, as `facts_run.engine` records it. A record names a full model id: an alias ("haiku")
    /// never matches one, so an alias that moves to a newer model can't inherit its record.
    public var model: String
    /// The provider adapter and what changes its behaviour (`GenerationProvider.factsAdapter`).
    public var adapter: String
    /// How memories are batched into calls, and the pipeline revision (`FactsExtractor.batching`).
    public var batching: String

    public init(model: String, adapter: String, batching: String = FactsExtractor.batching) {
        self.model = model
        self.adapter = adapter
        self.batching = batching
    }

    public init(_ provider: any GenerationProvider, batching: String = FactsExtractor.batching) {
        self.init(model: ModelRouter.engine(provider), adapter: provider.factsAdapter, batching: batching)
    }
}

/// The qualification records (memory processing §11.10, ADR-0032 as amended on 2026-11-24): each says an engine passed
/// Funes's tests for some uses of some predicates, at one call group's prompt version and one registry version. They
/// ship with the app (`Resources/facts-qualification.json`), come only from gate runs (the Phase 13 plan's acceptance
/// table), and make a model *Recommended*; they never turn a use on or off. With any model, every use the registry
/// declares is on, but for what a use needs and the local off-switches (`fact_qualification`, `passed = 0`, the two-week
/// review's). An off-switch holds for every model, until the call group's prompt, the registry or the pipeline revision
/// changes (the fix). A local row never turns anything on.
public struct FactsQualification: Sendable {
    public struct Record: Sendable, Decodable, Equatable {
        /// A pool gated as one (the person predicates, decision 9), all in `callGroup`.
        public var predicates: [String]
        public var uses: [String]
        /// "" for every record but a basis-scoped one ("sole_known" for that attribute gate).
        public var basis: String
        public var callGroup: String
        public var model: String
        public var adapter: String
        public var batching: String
        public var promptVersion: String
        public var registryVersion: String
        /// The gate measured and its result, in words.
        public var gate: String
        /// The run manifests and reports it rests on, repo-relative.
        public var evidence: [String]
        public var recordedAt: String
        /// For an answer-side record (13d's and 13e.2's answer gates): the answer models it was measured with, as
        /// `ModelRouter.engine` names them, and the answer prompt's version (`SearchAnswerer.promptVersion`). What it was
        /// measured with, kept as evidence; it doesn't decide what an answer uses.
        public var answerModels: [String]
        public var answerPromptVersion: String

        enum CodingKeys: String, CodingKey {
            case predicates, uses, basis, callGroup, model, adapter, batching, promptVersion, registryVersion, gate, evidence, recordedAt
            case answerModels, answerPromptVersion
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            predicates = try c.decode([String].self, forKey: .predicates)
            uses = try c.decode([String].self, forKey: .uses)
            basis = try c.decodeIfPresent(String.self, forKey: .basis) ?? ""
            callGroup = try c.decode(String.self, forKey: .callGroup)
            model = try c.decode(String.self, forKey: .model)
            adapter = try c.decode(String.self, forKey: .adapter)
            batching = try c.decode(String.self, forKey: .batching)
            promptVersion = try c.decode(String.self, forKey: .promptVersion)
            registryVersion = try c.decode(String.self, forKey: .registryVersion)
            gate = try c.decode(String.self, forKey: .gate)
            evidence = try c.decode([String].self, forKey: .evidence)
            recordedAt = try c.decode(String.self, forKey: .recordedAt)
            answerModels = try c.decodeIfPresent([String].self, forKey: .answerModels) ?? []
            answerPromptVersion = try c.decodeIfPresent(String.self, forKey: .answerPromptVersion) ?? ""
        }

        public init(predicates: [String], uses: [String], basis: String = "", callGroup: String, engine: FactsEngine,
                    promptVersion: String, registryVersion: String, gate: String, evidence: [String] = [], recordedAt: String,
                    answerModels: [String] = [], answerPromptVersion: String = "") {
            self.predicates = predicates
            self.uses = uses
            self.basis = basis
            self.callGroup = callGroup
            model = engine.model
            adapter = engine.adapter
            batching = engine.batching
            self.promptVersion = promptVersion
            self.registryVersion = registryVersion
            self.gate = gate
            self.evidence = evidence
            self.recordedAt = recordedAt
            self.answerModels = answerModels
            self.answerPromptVersion = answerPromptVersion
        }

        public var engine: FactsEngine { FactsEngine(model: model, adapter: adapter, batching: batching) }

        func key(_ predicate: String, _ use: String) -> Key {
            Key(predicate: predicate, use: use, basis: basis, model: model, adapter: adapter, batching: batching,
                promptVersion: promptVersion, registryVersion: registryVersion)
        }
    }

    /// One use of one predicate under one engine's key: the engine, the call group's prompt version and the registry
    /// version (`fact_qualification`'s primary key). A record's uses have it. An off-switch is matched without the
    /// engine's model and adapter (they say which engine it was turned off under), so another model doesn't lift it;
    /// `batching` (the pipeline revision, the same for every model) is matched, so a fix in code lapses it too.
    public struct Key: Hashable, Sendable {
        public var predicate, use, basis, model, adapter, batching, promptVersion, registryVersion: String

        public init(predicate: String, use: String, basis: String, model: String, adapter: String, batching: String,
                    promptVersion: String, registryVersion: String) {
            self.predicate = predicate
            self.use = use
            self.basis = basis
            self.model = model
            self.adapter = adapter
            self.batching = batching
            self.promptVersion = promptVersion
            self.registryVersion = registryVersion
        }

        public init(predicate: String, use: FactsUse, basis: String = "", engine: FactsEngine, promptVersion: String,
                    registryVersion: String) {
            self.init(predicate: predicate, use: use.rawValue, basis: basis, model: engine.model, adapter: engine.adapter,
                      batching: engine.batching, promptVersion: promptVersion, registryVersion: registryVersion)
        }
    }

    public let records: [Record]
    /// Turned off locally (the two-week review, or a failed gate found after shipping).
    public var off: Set<Key>
    /// Measurement only (the fixture harness, tests): every declared use on for any engine, off-switches ignored.
    let unchecked: Bool

    /// Internal: the app only ever has the shipped records (`bundled`).
    init(records: [Record], off: Set<Key> = []) {
        self.records = records
        self.off = off
        unchecked = false
    }

    /// The UI review build only (`FUNES_UI_REVIEW`): records that were never measured, to show the Facts page with
    /// other models recommended. The runner and the extractor use `bundled`.
    @_spi(FactsReview) public init(reviewRecords: [Record]) {
        self.init(records: reviewRecords)
    }

    private init(unchecked: Bool) {
        records = []
        off = []
        self.unchecked = unchecked
    }

    /// Every declared use on, whatever the engine and the off-switches: for measuring a model (the harness) and tests,
    /// never for the app.
    static let unchecked = FactsQualification(unchecked: true)

    /// The records shipped with the app.
    public static let bundled: FactsQualification = {
        guard let url = Bundle.module.url(forResource: "facts-qualification", withExtension: "json"),
              let data = try? Data(contentsOf: url), let q = try? decode(data) else {
            fatalError("facts-qualification.json is missing or invalid")
        }
        return q
    }()

    static func decode(_ data: Data) throws -> FactsQualification {
        struct File: Decodable { var records: [Record] }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return FactsQualification(records: try d.decode(File.self, from: data).records)
    }

    /// With the local off-switches, read now (so a use turned off stops at the next call).
    public func withOffSwitches(_ db: Database) throws -> FactsQualification {
        guard !unchecked else { return self }
        var q = self
        for r in try Row.fetchAll(db, sql: "SELECT * FROM fact_qualification WHERE passed = 0") {
            q.off.insert(Key(predicate: r["predicate"], use: r["use"], basis: r["basis"], model: r["model"], adapter: r["adapter"],
                             batching: r["batching"], promptVersion: r["prompt_version"], registryVersion: r["registry_version"]))
        }
        return q
    }

    /// Turns one use of one predicate off (the two-week review: "any wrong one turns that predicate's use, and everything
    /// downstream of it, off until fixed"), at the group's current prompt version, the registry version and the pipeline
    /// revision, for every model (the model and adapter are kept as a note of which one was in use). Everything that
    /// needs it goes with it at the next read. A new prompt, registry or pipeline revision (the fix) lapses it.
    public static func turnOff(_ db: Database, _ key: Key, gate: String, now: Date) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO fact_qualification (predicate, use, basis, model, prompt_version, registry_version, adapter,
              batching, gate, passed, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """, arguments: [key.predicate, key.use, key.basis, key.model, key.promptVersion, key.registryVersion,
                             key.adapter, key.batching, gate, now])
    }

    /// `turnOff` under a record's own key (its engine, prompt and registry version).
    public static func turnOff(_ db: Database, predicate: String, use: FactsUse, under record: Record, gate: String, now: Date) throws {
        try turnOff(db, record.key(predicate, use.rawValue), gate: gate, now: now)
    }

    /// Every group's prompt version (what a record's `prompt_version` is compared with).
    public static func promptVersions(_ registry: FactsRegistry) -> [String: String] {
        Dictionary(uniqueKeysWithValues: registry.callGroups.keys.map { ($0, FactsPrompt.version($0, registry: registry)) })
    }

    /// What's on for a configuration: each call group's engine (none: nothing of that group is on). Every use the
    /// registry declares for a group's predicates is on with any engine, and *attributes* also at the `sole_known`
    /// basis; the records don't matter (ADR-0032, amended 2026-11-24). Off: what's switched off locally at the group's
    /// prompt version, the registry version and the engine's pipeline revision, whatever the model, and what needs a use
    /// that's off (the registry's
    /// `uses`, transitively; a basis-scoped use also needs the unscoped one). Search, People & history, answers and the
    /// Facts task all read this.
    public func uses(engines: [String: FactsEngine], registry: FactsRegistry, promptVersions: [String: String]) -> FactsUses {
        if unchecked { return .everyDeclared(registry) }
        struct Switch: Hashable { var predicate, use, basis, promptVersion, registryVersion, batching: String }
        let switches = Set(off.map { Switch(predicate: $0.predicate, use: $0.use, basis: $0.basis, promptVersion: $0.promptVersion,
                                            registryVersion: $0.registryVersion, batching: $0.batching) })
        var candidates = Set<FactsUses.Key>()
        for p in registry.predicates {
            guard let engine = engines[p.callGroup], let version = promptVersions[p.callGroup] else { continue }
            for u in p.uses {
                guard let use = FactsUse(rawValue: u) else { continue }
                for basis in use == .attributes ? ["", LinkBasis.soleKnown.rawValue] : [""]
                where !switches.contains(Switch(predicate: p.id, use: u, basis: basis, promptVersion: version,
                                                registryVersion: registry.fingerprint, batching: engine.batching)) {
                    candidates.insert(.init(predicate: p.id, use: use, basis: basis))
                }
            }
        }
        // On only with everything it needs on (the registry's `uses`, transitively); a basis-scoped use also needs the
        // unscoped one.
        let on = candidates.filter { k in
            (k.basis.isEmpty || candidates.contains(.init(predicate: k.predicate, use: k.use, basis: "")))
                && registry.prerequisites(k.use.rawValue).allSatisfy { p in
                    FactsUse(rawValue: p).map { candidates.contains(.init(predicate: k.predicate, use: $0, basis: "")) } ?? false
                }
        }
        return FactsUses(registry: registry, on: on)
    }

    /// Whether Funes tested an engine for a call group (the picker's *Recommended*): some record of that group names
    /// exactly this engine (full model id, adapter, batching), the group's current prompt version and the registry version.
    public func tested(_ engine: FactsEngine, group: String, registry: FactsRegistry, promptVersions: [String: String]) -> Bool {
        records.contains {
            $0.callGroup == group && $0.engine == engine && promptVersions[group] == $0.promptVersion
                && registry.fingerprint == $0.registryVersion
        }
    }

    /// Whether Funes tested an engine for every call group.
    public func tested(_ engine: FactsEngine, registry: FactsRegistry, promptVersions: [String: String]) -> Bool {
        registry.callGroups.keys.allSatisfy { tested(engine, group: $0, registry: registry, promptVersions: promptVersions) }
    }

    /// The model each call group uses (model providers §Facts): the chosen one, for every group, tested or not. None:
    /// no group has a model, and memories get code-only links.
    public static func resolve(chosen: (any GenerationProvider)?, registry: FactsRegistry) -> [String: any GenerationProvider] {
        guard let chosen else { return [:] }
        return Dictionary(uniqueKeysWithValues: registry.callGroups.keys.map { ($0, chosen) })
    }
}

/// What's on for one configuration (memory processing §11.10). Every path reads through one: extraction stores only
/// facts of predicates whose `recorded` is on, and hides earlier ones of the others; the timeline answers only for
/// predicates whose `timeline` is on; search and answers (13b, 13d) check `linked`, `attributes` (and its `sole_known`
/// basis) and `bridges`.
public struct FactsUses: Sendable {
    struct Key: Hashable, Sendable {
        var predicate: String
        var use: FactsUse
        var basis: String
    }

    /// Predicates in registry order, with their call group.
    private let order: [(id: String, group: String)]
    private let on: Set<Key>
    private let declared: [String: Set<String>]
    private let all: Bool

    init(registry: FactsRegistry, on: Set<Key>, all: Bool = false) {
        order = registry.predicates.map { ($0.id, $0.callGroup) }
        declared = Dictionary(uniqueKeysWithValues: registry.predicates.map { ($0.id, Set($0.uses)) })
        self.on = on
        self.all = all
    }

    /// Every use the registry declares, on: what a measurement (the fixture harness) and the time model's tests run with.
    /// Never what the app runs with: that's `FactsQualification.uses`.
    static func everyDeclared(_ registry: FactsRegistry) -> FactsUses { FactsUses(registry: registry, on: [], all: true) }

    /// Nothing on.
    public static func none(_ registry: FactsRegistry) -> FactsUses { FactsUses(registry: registry, on: []) }

    public func isOn(_ predicate: String, _ use: FactsUse, basis: String = "") -> Bool {
        if all { return declared[predicate]?.contains(use.rawValue) ?? false }
        return on.contains(Key(predicate: predicate, use: use, basis: basis))
    }

    /// The predicates with a use on, in registry order, optionally of one call group.
    public func predicates(_ use: FactsUse, group: String? = nil) -> [String] {
        order.filter { group == nil || $0.group == group }.map(\.id).filter { isOn($0, use) }
    }

    /// Whether some declared predicate isn't recorded: the graph then hides its learned facts.
    var hidesRecorded: Bool { order.contains { !isOn($0.id, .recorded) } }
}

extension FactsGraph {
    /// Leaves out what was learned for predicates whose `recorded` is off (memory processing §11.10): their facts, but
    /// for the user's own entries, and their role groups. The rows stay stored; turning the use back on shows them.
    mutating func hideUnrecorded() {
        let uses = self.uses
        facts = facts.compactMap { f in
            if uses.isOn(f.predicate, .recorded) { return f }
            var mine = f
            mine.assertions = f.assertions.filter(\.fromUser)
            guard !mine.assertions.isEmpty else { return nil }
            // Only what you gave: no learned label, class or "only" survives with your rows.
            mine.only = mine.assertions.contains(where: \.only)
            let label = userLabels[FactStore.Loaded.key(f.predicate, f.entity)] ?? effectiveLabel(mine)
            mine.label = label
            mine.cls = labelClass(f.predicate, label)
            return mine
        }
        groups = groups.filter { uses.isOn($0.key.predicate, .recorded) }
        // Its role groups ("my sisters", a count) go too: they're learned for that predicate alone.
        entities = entities.filter { $0.value.name != nil || $0.value.group.map { uses.isOn($0.predicate, .recorded) } ?? true }
    }
}
