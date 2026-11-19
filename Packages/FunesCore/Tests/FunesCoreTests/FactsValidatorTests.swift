import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// The Facts task's validation (memory processing §11.3) against the spike's `facts.validate` on recorded Haiku outputs
/// (`fixtures/facts/replay-sample.jsonl`, exported by `spikes/people/export_replay.py`, with each call's roster, pairs and
/// denials), and the rules the spike didn't have: types, enums per predicate, the secret scanner, spans.
@Suite struct FactsValidatorTests {
    static func sampleURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["FUNES_FACTS_VALIDATE_EXPORT"] { return URL(fileURLWithPath: path) }
        return try #require(Bundle.module.url(forResource: "replay-sample", withExtension: "jsonl", subdirectory: "fixtures/facts"))
    }

    static func stories() throws -> [String: (text: [String: String], user: [String])] {
        var out: [String: (text: [String: String], user: [String])] = [:]
        for set in ["main", "astra", "mixed"] {
            let f = try FactsHarness.fixture(set)
            for s in f.stories {
                out[set + ":" + s.id] = (Dictionary(uniqueKeysWithValues: s.memories.map { ($0.id, $0.text) }), f.user.aliases)
            }
        }
        return out
    }

    /// The graph a recorded call's roster describes, with the spike's ids as entity and roster ids.
    static func graph(_ roster: [String: [String: Any]], user: [String]) -> FactsGraph {
        var g = FactsGraph(userAliases: user)
        for (id, e) in roster.sorted(by: { Int($0.key.dropFirst())! < Int($1.key.dropFirst())! }) {
            let name = e["name"] as? String
            let aliases = Set(e["aliases"] as? [String] ?? [])
            let group = (e["group"] as? [Any]).flatMap { a in (a.first as? String).map { FactsEntity.RoleGroup(predicate: $0, cls: a.count > 1 ? a[1] as? String : nil) } }
            g.insert(FactsEntity(id: id, seq: 0, kind: e["kind"] as? String ?? "person", name: name, aliases: aliases, group: group,
                                 count: nil, deceased: false, trustedAliases: aliases))
        }
        return g
    }

    static func s(_ v: Any?) -> String? { v as? String }

    /// Registry words 13a.2's fix round added (mixed's references outside the lexicon); the spike's recorded calls
    /// predate them, so a phrase with one of them is Swift's only.
    static let wordsAddedAfterTheRecording = ["client contact", "supervisor", "supervisora", "parent"]

    @Test func swiftValidationMatchesTheSpikeOnRecordedCalls() throws {
        let stories = try Self.stories()
        var checked = 0, phraseMismatch = 0
        for line in try String(contentsOf: Self.sampleURL(), encoding: .utf8).split(separator: "\n") {
            let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let set = r["set"] as? String ?? "mixed"
            guard let story = stories[set + ":" + (r["story"] as! String)], let text = story.text[r["memory"] as! String] else {
                Issue.record("unknown story \(r["story"]!)"); continue
            }
            let roster = r["roster"] as? [String: [String: Any]] ?? [:]
            let g = Self.graph(roster, user: story.user)
            let group = r["group"] as! String
            let phrases = g.rolePhrases(text, predicates: Set(FactsRegistry.bundled.groupPredicates(group)))
            let want = r["validated"] as! [String: Any]
            let pyPhrases = (r["phrases"] as! [[String: Any]]).map { ($0["start"] as! Int, $0["surface"] as! String) }
            let swPhrases = phrases.map { (FactStore.scalarOffset(text, utf16: $0.start), $0.surface) }
            // 13a.1's language layer skips a phrase that may be quoted speech, which the spike read (memory processing
            // §11.3), and 13a.2's fix round added registry words the recording predates (a phrase only Swift finds): those
            // calls are compared without their roles. Any other difference is a failure.
            var compareRoles = true
            if pyPhrases.map(\.0) != swPhrases.map(\.0) || pyPhrases.map(\.1) != swPhrases.map(\.1) {
                let missing = pyPhrases.filter { p in !swPhrases.contains { $0 == p } }
                let quoted = missing.allSatisfy { p in FactsGraph.mayBeQuoted(text, at: FactStore.utf16Offset(text, scalar: p.0)) }
                let added = swPhrases.filter { s in !pyPhrases.contains { $0 == s } }
                let newWords = added.allSatisfy { s in Self.wordsAddedAfterTheRecording.contains { FactsText.cue(FactsText.fold(s.1), $0) } }
                if quoted, newWords {
                    compareRoles = false
                } else {
                    phraseMismatch += 1
                    Issue.record("\(r["story"]!) \(r["memory"]!): role phrases differ: \(pyPhrases) vs \(swPhrases)")
                    continue
                }
            }
            let things = Set((r["things"] as? [String] ?? []).filter { $0.contains { $0.isUppercase } }.map { FactsText.fold($0) })
            let v = FactsValidator(graph: g, sent: FactsSentText(text, userAliases: story.user, registry: .bundled),
                                   roster: Dictionary(uniqueKeysWithValues: roster.keys.map { ($0, $0) }), phrases: phrases,
                                   predicates: FactsRegistry.bundled.groupPredicates(group), knownThings: things)
                .validate(FactsJSON(r["raw"]))
            let at = "\(set) \(r["story"]!)#\(r["orderIndex"]!) call \(r["call"]!) \(r["memory"]!) \(group)"
            // People: name and whom.
            let wantPeople = (want["people"] as! [[String: Any]]).map { "\($0["name"]!)→\($0["person"]!)" }.sorted()
            #expect(v.people.map { "\($0.name)→\($0.person)" }.sorted() == wantPeople, "\(at): people")
            // Facts: every field the apply reads.
            func key(_ predicate: String, _ entity: String, _ name: String?, _ label: String?, _ positive: Bool, _ status: String,
                     _ fields: [String?], _ quals: [String: String], _ count: Int?, _ only: Bool, _ deceased: Bool) -> String {
                [predicate, entity, entity == "name" ? (name ?? "") : "", label ?? "", positive ? "+" : "-", status]
                    .joined(separator: "|") + "|" + fields.map { $0 ?? "" }.joined(separator: "|")
                    + "|" + quals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                    + "|\(count.map(String.init) ?? "")|\(only)|\(deceased)"
            }
            let wantFacts = (want["facts"] as! [[String: Any]]).map { f in
                key(f["predicate"] as! String, f["entity"] as! String, Self.s(f["name"]), Self.s(f["label"]),
                    (f["polarity"] as? String) != "negative", f["status"] as? String ?? "unknown",
                    ["time", "start", "end", "preceded_by", "followed_by", "also_called"].map { Self.s(f[$0]) },
                    ((f["qualifiers"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }.filter { !$0.value.isEmpty },
                    f["count"] as? Int, f["only"] as? Bool ?? false, f["deceased"] as? Bool ?? false)
            }.sorted()
            let gotFacts = v.facts.map { f in
                key(f.predicate, f.entity, f.name, f.label, f.positive, f.status.rawValue,
                    [f.time, f.start, f.end, f.precededBy, f.followedBy, f.alsoCalled], f.qualifiers, f.count, f.only, f.deceased)
            }.sorted()
            #expect(gotFacts == wantFacts, "\(at): facts")
            // Roles: phrase → reference (the spike can list a phrase twice; the last one wins in its apply).
            var wantRoles: [String: String] = [:]
            for x in want["roles"] as! [[String: Any]] { wantRoles[x["id"] as! String] = x["refers_to"] as? String }
            var gotRoles: [String: String] = [:]
            for x in v.roles { gotRoles["r\(x.phrase + 1)"] = x.refersTo }
            if compareRoles { #expect(gotRoles == wantRoles, "\(at): roles") }
            #expect(v.things.map(\.name).sorted() == (want["things"] as! [[String: Any]]).map { $0["name"] as! String }.sorted(),
                    "\(at): things")
            checked += 1
        }
        #expect(checked > 0 && phraseMismatch == 0)
    }
}
