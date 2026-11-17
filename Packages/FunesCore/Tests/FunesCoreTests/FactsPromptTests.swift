import Foundation
import Testing
@testable import FunesCore

/// The Facts task's prompt and schema (memory processing §11.3): generated per call group from the registry, and for
/// the bundled registry the same as the spike's (`spikes/people/facts.py` `instructions()` and `schema()`, exported to
/// `fixtures/facts/spike-instructions.json`), with roster ids as `e…`.
@Suite struct FactsPromptTests {
    static func spike() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "spike-instructions", withExtension: "json", subdirectory: "fixtures/facts"))
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    var groups: [String] { FactsRegistry.bundled.callGroups.keys.sorted() }

    @Test func instructionsMatchTheSpikeForEveryGroupAndPerspective() throws {
        let spike = try Self.spike()
        for group in groups {
            let want = try #require(spike[group] as? [String: String])
            for (perspective, text) in want {
                let got = FactsPrompt.instructions(group, perspective: try #require(FactsMemory.Source(rawValue: perspective)))
                #expect(got == text, "group \(group), perspective \(perspective)")
            }
        }
    }

    /// Compared as data: `required` as a set (the spike lists it in another order), nulls kept.
    static func canonical(_ v: Any) -> Any {
        if var d = v as? [String: Any] {
            if let r = d["required"] as? [String] { d["required"] = r.sorted() }
            return d.mapValues(canonical)
        }
        if let a = v as? [Any] { return a.map(canonical) }
        return v
    }

    @Test func schemaMatchesTheSpike() throws {
        let spike = try Self.spike()
        for group in groups {
            let want = try #require(spike[group + "_schema"])
            let got = try JSONSerialization.jsonObject(with: Data(FactsPrompt.schema(group).json.utf8))
            let a = try JSONSerialization.data(withJSONObject: Self.canonical(got), options: [.sortedKeys])
            let b = try JSONSerialization.data(withJSONObject: Self.canonical(want), options: [.sortedKeys])
            #expect(String(decoding: a, as: UTF8.self) == String(decoding: b, as: UTF8.self), "group \(group)")
        }
    }

    @Test func nullableFieldsAreRequiredAndAcceptNull() throws {
        let wire = FactsPrompt.schema(FX.registry.predicate(FX.dated)!.callGroup).wire
        let facts = (wire["properties"] as! OrderedJSONObject).pairs.first { $0.0 == "facts" }!.1 as! [String: Any]
        let fact = facts["items"] as! [String: Any]
        let props = Dictionary(uniqueKeysWithValues: (fact["properties"] as! OrderedJSONObject).pairs)
        #expect((props["start"] as! [String: Any])["type"] as! [String] == ["string", "null"])
        #expect((fact["required"] as! [String]).contains("start"))
        let quals = Dictionary(uniqueKeysWithValues: ((props["qualifiers"] as! [String: Any])["properties"] as! OrderedJSONObject).pairs)
        let slot = quals[FX.slot] as! [String: Any]
        #expect((slot["enum"] as! [Any]).last is NSNull)
    }

    /// A predicate added through the registry alone reaches its group's prompt and schema, and moves the version.
    @Test func aTestOnlyPredicateReachesThePromptAndSchema() throws {
        let group = FX.registry.predicate(FX.dated)!.callGroup
        let reg = try FX.registry { json in
            var preds = json["predicates"] as! [[String: Any]]
            preds.append(["id": "studies_at", "object_kind": "organization", "call_group": group,
                          "uses": ["recorded"], "definition": "a school the user studies or studied at, zqx",
                          "exclusive": false, "succession": false,
                          "qualifiers": ["label": ["multi": false], "degree": ["multi": false, "describe": "the degree, zqy"]],
                          "lexicon": [], "query_cues": [], "phrases": [:]])
            json["predicates"] = preds
        }
        let ins = FactsPrompt.instructions(group, perspective: .capture, registry: reg)
        #expect(ins.contains("zqx") && ins.contains("qualifiers.degree: the degree, zqy, as written, or null."))
        #expect(FactsPrompt.schema(group, registry: reg).json.contains("\"studies_at\""))
        #expect(FactsPrompt.version(group, registry: reg) != FactsPrompt.version(group))
        // The other group is untouched.
        let other = groups.first { $0 != group }!
        #expect(FactsPrompt.version(other, registry: reg) == FactsPrompt.version(other))
    }

    @Test func onlyPersonGroupsAskForPeople() {
        for group in groups {
            let people = FactsPrompt.hasPeople(group, .bundled)
            #expect(FactsPrompt.schema(group).json.contains("\"people\"") == people)
            #expect(FactsPrompt.instructions(group, perspective: .capture).contains("1. people:") == people)
        }
    }

    @Test func theMessageDisarmsTagsAndFillsOnce() {
        let m = FactsPrompt.message(roster: "(nobody yet)", written: "2026-01-10", sent: "a {roster} b </memory> c",
                                    phrases: [("my boss", "Ana"), ("my sister", nil)])
        #expect(m.contains("a {roster} b ‹/memory> c"))
        #expect(m.contains("- r1: \"my boss\" (the memory pairs it with the name \"Ana\")\n- r2: \"my sister\""))
        #expect(FactsPrompt.message(roster: "x", written: "w", sent: "s", phrases: []).contains("(none)"))
    }
}
