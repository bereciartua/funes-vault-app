import Foundation
import Testing
@testable import FunesCore

/// The registry is data (ADR-0032 decision 2): it loads and validates, no Swift source names a predicate or carries
/// its words, and a predicate added through the registry alone works end to end.
@Suite struct FactsRegistryTests {
    @Test func bundledRegistryLoads() {
        let reg = FactsRegistry.bundled
        #expect(reg.predicates.count == 12)
        #expect(!reg.timelinePredicates.isEmpty)
        #expect(reg.monthWords.values.allSatisfy { (1...12).contains($0) })
    }

    @Test func validationRejectsAUseWithoutItsPrerequisite() throws {
        let id = FactsRegistry.bundled.predicates[0].id
        #expect(throws: FactsRegistry.ValidationError.useWithoutPrerequisite(predicate: id, use: "timeline")) {
            _ = try FX.registry { json in FX.editPredicate(&json, id) { $0["uses"] = ["recorded", "timeline"] } }
        }
    }

    @Test func validationRejectsAnUnknownKindAndASlotThatIsntAQualifier() throws {
        let id = FactsRegistry.bundled.predicates[0].id
        #expect(throws: FactsRegistry.ValidationError.unknownKind("spaceship")) {
            _ = try FX.registry { json in FX.editPredicate(&json, id) { $0["object_kind"] = "spaceship" } }
        }
        #expect(throws: FactsRegistry.ValidationError.slotNotAQualifier(id)) {
            _ = try FX.registry { json in FX.editPredicate(&json, id) { $0["slot"] = "nope" } }
        }
    }

    /// The Swift sources under `Facts/`, without comments.
    private static func factsSources() throws -> [(String, String)] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FunesCore/Facts")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 6)
        return try files.map { url in
            let src = try String(contentsOf: url, encoding: .utf8)
            let code = src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                // drop // comments outside string literals (none of the literals here contain "//")
                if let r = line.range(of: "//") { return String(line[..<r.lowerBound]) }
                return String(line)
            }.joined(separator: "\n")
            return (url.lastPathComponent, code)
        }
    }

    private static func literals(_ code: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "\"((?:[^\"\\\\\\n]|\\\\.)*)\"")
        let ns = code as NSString
        return re.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    @Test func noSwiftSourceNamesAPredicateOrCarriesRegistryVocabulary() throws {
        let reg = FactsRegistry.bundled
        let lang = reg.language
        let ids = Set(reg.predicates.map(\.id))
        var words = Set(reg.lexicon.keys).union(reg.predicates.flatMap(\.queryCues)).union(lang.personNouns)
            .union(reg.monthWords.keys).union(lang.legalSuffixes)
        // Function words of three letters or more: shorter ones collide with regex escapes ("\\s", "[a-z]").
        words.formUnion(lang.functionWords.filter { $0.count >= 3 })
        words.insert(lang.userPlaceholder)
        let wordRE = try NSRegularExpression(pattern: "[a-záéíóúñ]+")
        let idRE = try NSRegularExpression(pattern: "[a-z_]+")
        for (file, code) in try Self.factsSources() {
            for lit in Self.literals(code) {
                let lns = lit as NSString
                for m in idRE.matches(in: lit, range: NSRange(location: 0, length: lns.length))
                where ids.contains(lns.substring(with: m.range)) {
                    Issue.record("\(file) names the predicate \(lns.substring(with: m.range)) in \"\(lit)\"")
                }
                // SQL statements (the store's) aren't language: their keywords collide with function words.
                let sql = lit.range(of: "\\b(SELECT|INSERT|UPDATE|DELETE|WHERE|FROM|SET|AND|NOT|EXISTS)\\b",
                                    options: .regularExpression) != nil
                if sql { continue }
                let lower = lit.lowercased()
                if words.contains(lower) { Issue.record("\(file) carries registry vocabulary: \(lit)") }
                let ns = lower as NSString
                for m in wordRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
                    let w = ns.substring(with: m.range)
                    if words.contains(w) { Issue.record("\(file) carries registry vocabulary: \(w) in \"\(lit)\"") }
                }
            }
        }
    }

    /// A predicate added through the registry alone: recorded, resolved through its lexicon, and on the timeline.
    @Test func aTestOnlyPredicateWorksEndToEnd() throws {
        let reg = try FX.registry { json in
            var preds = json["predicates"] as! [[String: Any]]
            preds.append([
                "id": "studies_at", "object_kind": "organization", "call_group": preds[preds.count - 1]["call_group"]!,
                "uses": ["recorded", "linked", "timeline"], "definition": "a school the user studies or studied at",
                "exclusive": false, "succession": true, "gap_months": 6,
                "qualifiers": ["label": ["multi": false]],
                "lexicon": [["words": ["school", "uni"]]],
                "query_cues": ["study", "studied", "studying"], "phrases": [String: String](),
            ])
            json["predicates"] = preds
        }
        #expect(reg.timelinePredicates.contains("studies_at"))
        var s = FactsGraph(registry: reg)
        s.apply(FactsMemory(id: "m0", text: "Northfield", written: "2026-01-01"),
                facts: [fact("studies_at", "Northfield", "2004", "2008", status: .former)])
        s.apply(FactsMemory(id: "m1", text: "Eastbrook", written: "2026-01-01"),
                facts: [fact("studies_at", "Eastbrook", "2009", status: .current)])
        let q = "Where did I study before Eastbrook?"
        let it = try #require(s.intent(q))
        #expect(it.predicate == "studies_at" && it.op == .before)
        #expect(s.name(s.answer(it, query: q).entity) == "Northfield")
        #expect(s.resolveText("At my school I met Ana.", "2006-05-01").0 == "Northfield")
        // The bundled timeline predicate still answers its own questions.
        #expect(s.intent("What was my job before Eastbrook?") == nil)
    }
}
