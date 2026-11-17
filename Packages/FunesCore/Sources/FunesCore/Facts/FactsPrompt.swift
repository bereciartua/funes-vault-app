import CryptoKit
import Foundation

/// The Facts task's prompt and schema per call group (memory processing §11.3), generated from the registry and the
/// prompt wording in `Resources/facts-prompt.json`. Nothing here names a predicate or carries its words.
public enum FactsPrompt {
    /// The wording, as the resource gives it.
    struct Text: Decodable, Sendable {
        struct Sections: Decodable, Sendable { let people, facts, roles, things: String }
        struct Fragments: Decodable, Sendable {
            let entityPerson, entityOther, dead, personFields, qualifier, qualifierValues, qualifierAsWritten: String
            let listSeparator, exampleSeparator: String
        }
        struct Roster: Decodable, Sendable {
            let group, groupCount, entity, fact, factLabel, deceased, untrusted, noFacts, known, knownSeparator: String
            let things, thing, empty: String
            let knownMax: Int
        }

        let version: String
        let perspectives: [String: String]
        let header: String
        let sections: Sections
        let fragments: Fragments
        let message, phrase, phrasePaired, noPhrases: String
        let roster: Roster
        let thingKinds: [String: String]
    }

    static let resourceData: Data = {
        guard let url = Bundle.module.url(forResource: "facts-prompt", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { fatalError("facts-prompt.json is missing") }
        return data
    }()

    static let text: Text = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        guard let t = try? d.decode(Text.self, from: resourceData) else { fatalError("facts-prompt.json is invalid") }
        return t
    }()

    /// Fills `{slot}`s in one pass, so a value that itself holds braces (a memory's text) is never filled again.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest.index(after: open)
            if let close = rest[after...].firstIndex(of: "}"), let v = values[String(rest[after..<close])] {
                out += v
                rest = rest[rest.index(after: close)...]
            } else {
                out += "{"
                rest = rest[after...]
            }
        }
        return out + rest
    }

    /// A group's predicates: those it records.
    static func predicates(_ group: String, _ registry: FactsRegistry) -> [FactsRegistry.Predicate] {
        registry.groupPredicates(group).compactMap { registry.predicate($0) }
    }

    /// The group's qualifiers other than the label, first definition wins, in registry order.
    static func qualifiers(_ group: String, _ registry: FactsRegistry) -> [(String, FactsRegistry.Qualifier)] {
        var out: [(String, FactsRegistry.Qualifier)] = []
        for p in predicates(group, registry) {
            for k in registry.qualifierKeys(p.id) where k != labelKey && !out.contains(where: { $0.0 == k }) {
                if let q = p.qualifiers[k] { out.append((k, q)) }
            }
        }
        return out
    }

    /// The qualifier that is the user's own word (memory processing §11.1); it has its own field.
    static let labelKey = "label"

    static func hasPeople(_ group: String, _ registry: FactsRegistry) -> Bool {
        predicates(group, registry).contains { $0.objectKind == personKind }
    }

    static let personKind = "person"

    /// The system instructions for a group, from the memory's perspective (who wrote it).
    public static func instructions(_ group: String, perspective: FactsMemory.Source, registry: FactsRegistry = .bundled) -> String {
        let t = text, f = t.fragments
        let preds = predicates(group, registry)
        let people = preds.contains { $0.objectKind == personKind }
        let other = preds.contains { $0.objectKind != personKind }
        let px = registry.language.promptExamples
        let examples = registry.callGroups[group]?.examples ?? [:]
        var parts = [fill(t.header, ["intro": registry.callGroups[group]?.intro ?? "",
                                     "perspective": t.perspectives[perspective.rawValue] ?? t.perspectives["capture"] ?? ""])]
        var n = 1
        if people {
            parts.append(fill(t.sections.people, ["n": String(n)]))
            n += 1
        }
        var entities: [String] = []
        if people { entities.append(fill(f.entityPerson, px)) }
        if other { entities.append(f.entityOther) }
        var quals = ""
        for (k, q) in qualifiers(group, registry) {
            let values = q.values.map { fill(f.qualifierValues, ["values": $0.joined(separator: f.exampleSeparator)]) }
                ?? f.qualifierAsWritten
            quals += fill(f.qualifier, ["key": k, "describe": q.describe ?? k, "values": values])
        }
        parts.append(fill(t.sections.facts, [
            "n": String(n),
            "definitions": preds.map(\.definition).joined(separator: f.listSeparator),
            "entities": entities.joined(separator: f.listSeparator),
            "labels": (examples["label"] ?? []).joined(separator: f.exampleSeparator),
            "former": (examples["former"] ?? []).joined(separator: f.exampleSeparator),
            "dead": people ? f.dead : "",
            "person_fields": people ? fill(f.personFields, px) : "",
            "start": px["start"] ?? "",
            "qualifiers": quals,
        ]))
        n += 1
        parts.append(fill(t.sections.roles, ["n": String(n)].merging(px) { a, _ in a }))
        n += 1
        parts.append(fill(t.sections.things, ["n": String(n)]))
        return parts.joined(separator: "\n")
    }

    /// The model's answer as the schema asks for it: fields a memory may not state are required but nullable.
    public static func schema(_ group: String, registry: FactsRegistry = .bundled) -> JSONSchema {
        let preds = predicates(group, registry)
        let people = preds.contains { $0.objectKind == personKind }
        let nullString = JSONSchema.nullable(.string())
        let quals: [(String, JSONSchema)] = qualifiers(group, registry).map { k, q in
            (k, .nullable(.string(oneOf: q.values)))
        }
        var fact: [(String, JSONSchema)] = [
            ("quote", .string()), ("predicate", .string(oneOf: preds.map(\.id))), ("entity", .string()),
            ("name", nullString), ("label", nullString),
            ("polarity", .string(oneOf: Polarity.allCases.map(\.rawValue))),
            ("status", .string(oneOf: [FactAssertion.Status.current, .former, .unknown].map(\.rawValue))),
        ]
        if people { fact += [("deceased", .boolean()), ("only", .boolean()), ("count", .nullable(.integer()))] }
        fact += ["time", "start", "end", "preceded_by", "followed_by", "also_called"].map { ($0, nullString) }
        fact.append(("qualifiers", .object(name: "Qualifiers", properties: quals)))
        var props: [(String, JSONSchema)] = [
            ("facts", .array(of: .object(name: "Fact", properties: fact))),
            ("roles", .array(of: .object(name: "Mention", properties: [("id", .string()), ("refers_to", .string())]))),
            ("things", .array(of: .object(name: "Thing", properties: [
                ("name", .string()), ("quote", .string()), ("kind", .string(oneOf: thingKinds)),
            ]))),
        ]
        if people {
            props.append(("people", .array(of: .object(name: "Person", properties: [
                ("name", .string()), ("quote", .string()), ("person", .string()),
            ]))))
        }
        return .object(name: schemaName, properties: props)
    }

    public static let schemaName = "Facts"

    public enum Polarity: String, CaseIterable, Sendable { case positive, negative }

    /// The kinds the model gives things, in the resource's order.
    static var thingKinds: [String] {
        let keys = OrderedJSON.objectKeys(resourceData, at: "thing_kinds")
        return keys.isEmpty ? text.thingKinds.keys.sorted() : keys
    }

    /// The prompt version of a group (recorded with each run and in qualification records): the wording resource,
    /// every perspective's instructions and the schema. A registry change that alters the group's prompt moves it.
    public static func version(_ group: String, registry: FactsRegistry = .bundled) -> String {
        var h = SHA256()
        h.update(data: resourceData)
        for p in [FactsMemory.Source.capture, .agent, .import, .rewritten, .manual] {
            h.update(data: Data(instructions(group, perspective: p, registry: registry).utf8))
        }
        h.update(data: Data(schema(group, registry: registry).json.utf8))
        return h.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The user message: the roster, the memory as sent (its `<` disarmed), and the role phrases as `r1…`.
    static func message(roster: String, written: String, sent: String, phrases: [(surface: String, paired: String?)]) -> String {
        let t = text
        let lines = phrases.enumerated().map { i, ph in
            fill(t.phrase, ["n": String(i + 1), "surface": ph.surface])
                + (ph.paired.map { fill(t.phrasePaired, ["name": $0]) } ?? "")
        }
        return fill(t.message, [
            "roster": roster, "written": written, "memory": disarm(sent),
            "phrases": lines.isEmpty ? t.noPhrases : lines.joined(separator: "\n"),
        ])
    }

    /// The memory text can't open or close the prompt's tags.
    static func disarm(_ s: String) -> String { s.replacingOccurrences(of: "<", with: "‹") }
}
