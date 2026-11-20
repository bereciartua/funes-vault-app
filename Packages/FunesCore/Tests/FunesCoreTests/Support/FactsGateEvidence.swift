import CryptoKit
import Foundation
@testable import FunesCore

/// The CI check of a qualification record's evidence (memory processing §11.10, Phase 13a.2 Gates). `qualify.py` writes
/// records from gate runs; `qualify.py verify` (scripts/test.sh) recomputes each record's scores from its evidence lines.
/// This checks the rest against the code that runs now: which 13a.2 gate covers the record (one with no gate fails), that
/// its manifests are live runs of exactly its key (model, adapter, batching with the pipeline revision, the group's prompt
/// version, the registry version), of the current fixtures, complete, with every response's model identified, from one
/// clean commit, over every set the gate needs in ≥ 2 reads; that its scores meet the pass table; and that port fidelity
/// passed.
enum FactsGateEvidence {
    /// A 13a.2 gate: the record shape it allows and the sets it needs (qualify.py's SETS and RECORD_SHAPE).
    struct Gate: Equatable {
        let id: String
        let sets: [String]
    }

    static let reads = 2
    /// The comparisons port fidelity's report must have (port_fidelity.py's STANDARD).
    static let standardPairs = ["main recorded", "astra recorded", "mixed recorded", "main gold", "astra gold", "mixed gold",
                                "persons gold", "h2 convert"]

    /// The gate covering a record, or nil: the timeline (measured, not recorded, in 13a.2: works at ships linked only),
    /// attributes, bridges, a basis, the canary predicate and any other shape have no 13a.2 gate, so their records fail.
    static func gate(for r: FactsQualification.Record, registry: FactsRegistry) -> Gate? {
        guard r.basis.isEmpty else { return nil }
        let uses = Set(r.uses)
        let person = registry.predicates.filter { registry.kindOf($0.id) == FactsValidator.personKind }.map(\.id)
        let timeline = registry.timelinePredicates
        let client = registry.predicates.filter {
            !timeline.contains($0.id) && registry.kindOf($0.id) != FactsValidator.personKind && !$0.uses.contains(FactsUse.linked.rawValue)
        }.map(\.id)
        if Set(r.predicates) == Set(person), uses == ["recorded", "linked"] { return Gate(id: "persons", sets: ["main", "astra", "mixed", "persons"]) }
        if r.predicates.count == 1, client.contains(r.predicates[0]), uses == ["recorded"] { return Gate(id: "client", sets: ["mixed", "work13"]) }
        if r.predicates.count == 1, timeline.contains(r.predicates[0]), uses == ["recorded", "linked"] {
            return Gate(id: "works_at", sets: ["mixed", "work13"])
        }
        return nil
    }

    static func sha256(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    static func url(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : FactsHarness.repo.appending(path: path)
    }

    static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Why a record's evidence doesn't qualify it now ([] = it does).
    static func problems(_ r: FactsQualification.Record, registry: FactsRegistry, fixtures: (String) -> URL = FactsHarness.fixtureURL) -> [String] {
        if r.uses == [FactsUse.attributes.rawValue] { return answerProblems(r, registry: registry) }
        guard let gate = gate(for: r, registry: registry) else { return ["no 13a.2 gate for \(r.predicates) \(r.uses) \(r.basis)"] }
        var out: [String] = []
        let manifests = r.evidence.filter { $0.hasSuffix("-manifest.json") }
        guard let scoresPath = r.evidence.first(where: { $0.hasSuffix("/scores.json") }), let scores = json(url(scoresPath)) else {
            return ["no scores.json in the evidence"]
        }
        guard let pfPath = r.evidence.first(where: { $0.hasSuffix("/port-fidelity.json") }), let pf = json(url(pfPath)),
              pf["pass"] as? Bool == true else { return ["port fidelity: no passing report in the evidence"] }
        if (scores["port_fidelity"] as? [String: Any])?["sha256"] as? String != sha256(url(pfPath)) {
            out.append("port fidelity: not the report the scores were computed with")
        }
        let pairs = Dictionary((pf["pairs"] as? [[String: Any]] ?? []).map { ("\($0["set"] ?? "") \($0["mode"] ?? "")", $0) },
                               uniquingKeysWith: { a, _ in a })
        for name in standardPairs where pairs[name].map({ $0["plays"] as? Int != $0["expected_plays"] as? Int }) ?? true {
            out.append("port fidelity: \(name) missing or incomplete")
        }
        // The runs.
        var seen: [String: Set<String>] = [:], commits = Set<String>(), runIDs: [String] = []
        let modelID = String(r.model.split(separator: "/", maxSplits: 1).last ?? "")
        for path in manifests {
            guard let m = json(url(path)) else { out.append("missing \(path)"); continue }
            let set = m["set"] as? String ?? "?"
            let at = "\(path.split(separator: "/").suffix(2).joined(separator: "/"))"
            let label = m["label"] as? String ?? ""
            guard let read = label.range(of: "-gates-r\\d+$", options: .regularExpression).map({ String(label[$0].dropFirst(7)) }) else {
                out.append("\(at): not a gate run (\(label))"); continue
            }
            seen[set, default: []].insert(read)
            commits.insert(m["commit"] as? String ?? "")
            runIDs.append(m["run_id"] as? String ?? "")
            let engine = m["engine"] as? [String: Any] ?? [:]
            if m["mode"] as? String != "live" { out.append("\(at): not a live run") }
            if engine["model"] as? String != r.model || engine["adapter"] as? String != r.adapter || engine["batching"] as? String != r.batching {
                out.append("\(at): engine \(engine)")
            }
            if (m["prompt_versions"] as? [String: String])?[r.callGroup] != r.promptVersion { out.append("\(at): prompt version") }
            if m["registry_version"] as? String != r.registryVersion || m["registry_file"] as? String != "bundled" { out.append("\(at): registry") }
            if m["models_reported"] as? [String] != [modelID] { out.append("\(at): the provider reported \(m["models_reported"] ?? "nothing")") }
            if m["responses_without_model"] as? Int != 0 || (m["responses"] as? Int ?? 0) == 0 { out.append("\(at): responses without a model id") }
            let opts = m["options"] as? [String: String] ?? [:]
            if opts["only"] != nil || opts["orders"] == "natural" { out.append("\(at): a partial run") }
            if m["plays"] as? Int != m["plays_expected"] as? Int || Set(m["plays_list"] as? [String] ?? []).count != m["plays_expected"] as? Int {
                out.append("\(at): incomplete")
            }
            if m["fixture_sha256"] as? String != sha256(fixtures(set)) { out.append("\(at): the fixture changed since the run") }
            // The record's call group was read (a people-only run, as Opus reads, carries a people record).
            if !((m["groups"] as? [String]) ?? []).contains(r.callGroup) { out.append("\(at): \(r.callGroup) not played") }
            if m["unsettled"] as? Int != 0 || m["above_limit_in_payload"] as? Int != 0 { out.append("\(at): unsettled or above the limit") }
            if !["low", "internal", "sensitive"].contains(m["limit"] as? String ?? "") { out.append("\(at): not the app's cloud limit") }
            // The lines the run wrote, unchanged: each manifest's jsonl is in the evidence with the digest it recorded.
            let lines = path.replacingOccurrences(of: "-manifest.json", with: ".jsonl")
            if !r.evidence.contains(lines) || sha256(url(lines)) != m["lines_sha256"] as? String { out.append("\(at): the lines aren't the ones the run wrote") }
        }
        if commits.count != 1 || commits.contains(where: { $0.isEmpty || $0.hasSuffix("+dirty") }) { out.append("commits \(commits.sorted())") }
        if let c = commits.first, pf["commit"] as? String != c { out.append("port fidelity: computed at another commit") }
        if Set(runIDs).count != runIDs.count { out.append("repeated run ids") }
        for set in gate.sets where (seen[set]?.count ?? 0) < reads { out.append("\(set): \(seen[set]?.count ?? 0) read(s)") }
        // The scores against the pass table.
        out += scoreProblems(gate, scores["measures"] as? [String: [String: Any]] ?? [:], registry: registry)
        return out
    }

    /// An *attributes* record (13d's answer gates; `qualify.py answer-scores`, which `qualify.py verify` recomputes): the
    /// person pool, unscoped or `sole_known`; for the answer model the gates ran and the answer prompt that runs now; both
    /// gates passed (the author's waivers counted); every input and replay file unchanged; and the replay, at one clean
    /// commit, answered every request from the response cache, at this record's registry and Facts prompt version.
    static func answerProblems(_ r: FactsQualification.Record, registry: FactsRegistry) -> [String] {
        var out: [String] = []
        let person = registry.predicates.filter { registry.kindOf($0.id) == FactsValidator.personKind }.map(\.id)
        if Set(r.predicates) != Set(person) || !["", LinkBasis.soleKnown.rawValue].contains(r.basis) {
            return ["no 13d gate for \(r.predicates) \(r.uses) \(r.basis)"]
        }
        guard let path = r.evidence.first(where: { $0.hasSuffix("/scores-13d.json") }), let sc = json(url(path)) else {
            return ["no scores-13d.json in the evidence"]
        }
        let dir = url(path).deletingLastPathComponent(), results = FactsHarness.repo.appending(path: "spikes/people/results-13d")
        let replay = sc["replay"] as? [String: Any] ?? [:]
        if r.answerModels.isEmpty || r.answerModels != [sc["model"] as? String ?? ""] { out.append("answer models \(r.answerModels)") }
        if r.answerPromptVersion != SearchAnswerer.promptVersion { out.append("answer prompt version \(r.answerPromptVersion)") }
        if replay["answerPromptVersion"] as? String != r.answerPromptVersion { out.append("not the replay's answer prompt version") }
        for (gate, verdicts) in sc["gates"] as? [String: [String: Bool]] ?? [:] {
            for (k, v) in verdicts where !v { out.append("\(gate): \(k)") }
        }
        if (sc["gates"] as? [String: Any])?.keys.sorted() != ["answers", "spikeg"] { out.append("gates \((sc["gates"] as? [String: Any])?.keys.sorted() ?? [])") }
        for (p, d) in sc["inputs"] as? [String: String] ?? [:] where sha256(results.appending(path: p)) != d { out.append("\(p): changed") }
        let files = replay["files"] as? [String: String] ?? [:]
        for (p, d) in files where sha256(dir.appending(path: p)) != d { out.append("replay \(p): changed") }
        var commits = Set<String>()
        for p in files.keys where p.hasSuffix(".json") && p.contains("manifest-") {
            guard let m = json(dir.appending(path: p)) else { out.append("missing \(p)"); continue }
            commits.insert(m["commit"] as? String ?? "")
            if m["mode"] as? String != "replay" || m["uncached"] as? Int != 0 { out.append("\(p): not a full replay") }
            if m["dirty"] as? Bool != false { out.append("\(p): a dirty tree") }
            if m["registryVersion"] as? String != r.registryVersion { out.append("\(p): registry") }
            if (m["factsPromptVersions"] as? [String: String])?[r.callGroup] != r.promptVersion { out.append("\(p): Facts prompt version") }
            if m["answerPromptVersion"] as? String != r.answerPromptVersion { out.append("\(p): answer prompt version") }
            let model = String((sc["model"] as? String ?? "").split(separator: "/", maxSplits: 1).last ?? "")
            if m["modelsReported"] as? [String] != [model] || m["responsesWithoutModel"] as? Int != 0 { out.append("\(p): models reported") }
        }
        if commits.count != 1 || commits.contains("") { out.append("replay commits \(commits.sorted())") }
        if files.keys.filter({ $0.contains("manifest-") }).count != 2 { out.append("the replay of both gates") }
        let listed = Set(r.evidence)
        let want = (sc["inputs"] as? [String: String] ?? [:]).keys.map { "spikes/people/results-13d/" + $0 }
            + files.keys.map { String(path.dropLast("scores-13d.json".count)) + $0 }
        if !Set(want).isSubset(of: listed) { out.append("the record's evidence isn't what the scores were computed from") }
        return out
    }

    static func n(_ d: [String: Any]?, _ k: String) -> Int { d?[k] as? Int ?? 0 }
    static func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }

    /// The pass table (§11.10) on scores.json's measures, per read (qualify.py's judge_gate, checked again here).
    static func scoreProblems(_ gate: Gate, _ measures: [String: [String: Any]], registry: FactsRegistry) -> [String] {
        var out: [String] = []
        if measures.count < reads { out.append("\(measures.count) read(s) scored") }
        let person = registry.predicates.filter { registry.kindOf($0.id) == FactsValidator.personKind }.map(\.id)
        for (rd, sets) in measures.sorted(by: { $0.key < $1.key }) {
            func part(_ s: String, _ k: String) -> [String: Any]? { (sets[s] as? [String: Any])?[k] as? [String: Any] }
            guard gate.sets.allSatisfy({ sets[$0] != nil }) else { out.append("\(rd): a set missing"); continue }
            switch gate.id {
            case "persons":
                var right = 0, wrong = 0, rr = 0, rt = 0, perPred: [String: Int] = [:]
                for s in gate.sets {
                    let p = part(s, "people")
                    right += n(p, "full_right"); wrong += n(p, "full_wrong"); rr += n(p, "recall_right"); rt += n(p, "recall_truth")
                    for (k, v) in p?["full_by_predicate"] as? [String: Int] ?? [:] { perPred[k, default: 0] += v }
                }
                if ratio(right, right + wrong) < 0.98 { out.append("\(rd): full basis \(right)/\(right + wrong)") }
                if ratio(rr, rt) < 0.90 { out.append("\(rd): recall \(rr)/\(rt)") }
                for p in person where perPred[p, default: 0] < 20 { out.append("\(rd): \(p) has \(perPred[p, default: 0]) full-basis links") }
                let mx = part("mixed", "people")
                if ratio(n(mx, "full_right"), n(mx, "full_right") + n(mx, "full_wrong")) < 0.98 || ratio(n(mx, "recall_right"), n(mx, "recall_truth")) < 0.90 {
                    out.append("\(rd): not met on mixed")
                }
            case "client", "works_at":
                var o: [String: Int] = [:]
                for s in gate.sets { for (k, v) in part(s, "orgs") as? [String: Int] ?? [:] { o[k, default: 0] += v } }
                if o["clients_as_employer", default: 0] + o["vendors_as_employer", default: 0] > 0 { out.append("\(rd): clients or vendors as employers") }
                if gate.id == "client" {
                    if o["vendors_as_client", default: 0] > 0 { out.append("\(rd): vendors as clients") }
                    if o["clients", default: 0] < 3 || o["vendors", default: 0] < 3 || o["clients_recorded", default: 0] == 0 {
                        out.append("\(rd): too few clients or vendors to measure, or none recorded")
                    }
                } else {
                    let units = o["works_at_right", default: 0] + o["works_at_wrong", default: 0]
                    if units < 20 || ratio(o["works_at_right", default: 0], units) < 0.98 { out.append("\(rd): works at \(o["works_at_right", default: 0])/\(units)") }
                    let mo = part("mixed", "orgs")
                    if ratio(n(mo, "works_at_right"), n(mo, "works_at_right") + n(mo, "works_at_wrong")) < 0.98 { out.append("\(rd): not met on mixed") }
                }
            default:
                for s in gate.sets {
                    let t = part(s, "timeline")
                    if t == nil { out.append("\(rd) \(s): no timeline"); continue }
                    if n(t, "wrong_facts") > 0 || n(t, "wrong_dates") > 1 || n(t, "wrong_answers") > 0 || n(t, "triggered") > 0 {
                        out.append("\(rd) \(s): wrong facts, dates, answers or triggers")
                    }
                    if n(t, "succession_untrusted") + n(t, "succession_cross_slot") + n(t, "succession_unexplained") > 0 { out.append("\(rd) \(s): succession") }
                    if ratio(n(t, "right") + n(t, "right_gap"), n(t, "decidable")) < 0.90 { out.append("\(rd) \(s): decidable right under 90%") }
                    if s != "mixed", n(t, "decidable") < 30 || n(t, "negatives") < 5 { out.append("\(rd) \(s): too few questions to measure") }
                }
            }
        }
        return out
    }
}
