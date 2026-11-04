import Foundation
import FunesProtocol
@testable import FunesCore

/// Spike E's tidy-up fixtures (spikes/memory-processing/fixtures/clusters*.json, exported by
/// `export_tidy_recordings.py`), the engines' recorded answers to the second tidy-up prompt, and a
/// port of the spike's judge (`score.py`: `spec_match`, `judge`, `pair_updates`).
enum SpikeETidy {
    struct Spec: Decodable {
        let type: String
        let target: String?
        let survivor: String?
        let sources: [String]?
        let ids: [String]?
        let keys: [String]?
        let notkeys: [String]?
    }

    struct FixtureMemory: Decodable {
        let id: String
        let title: String
        let body: String
        let kind: String
        let categories: [String]
        let sensitivity: String
        let createdAt: String
        let updatedAt: String
        let source: String
        let trust: String
    }

    struct Cluster: Decodable {
        let id: String
        let tags: [String]
        let memories: [FixtureMemory]
        let expected: [Spec]
        let acceptable: [Spec]
        let forbidden: [Spec]
    }

    struct File: Decodable { let clusters: [Cluster] }

    /// Both sets, 140 clusters from two authors.
    static func clusters() throws -> [Cluster] {
        try ["clusters", "clusters-astra"].flatMap {
            try JSONDecoder().decode(File.self, from: Data(contentsOf: SpikeE.url($0))).clusters
        }
    }

    /// Model id → cluster id → the raw actions it returned.
    static func recordings() throws -> [String: [String: [[String: Any]]]] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: SpikeE.url("recorded-tidy"))) as! [String: Any]
        return root["engines"] as! [String: [String: [[String: Any]]]]
    }

    /// The cluster as Funes holds it: memories with their dates, sources and trust, aliased m1…
    /// in fixture order, all editable. Returns it and alias ↔ fixture id.
    static func cluster(_ c: Cluster) -> (TidyUpCluster, [String: String]) {
        var aliases: [String: String] = [:]
        let members = c.memories.enumerated().map { i, m -> TidyUpCluster.Member in
            aliases[m.id] = "m\(i + 1)"
            let memory = Memory(title: m.title, body: m.body, kind: MemoryKind(rawValue: m.kind)!, categoryKeys: m.categories,
                                sensitivity: Sensitivity(name: m.sensitivity)!, source: MemorySource(rawValue: m.source)!,
                                createdAt: SpikeE.day(m.createdAt), updatedAt: SpikeE.day(m.updatedAt))
            return TidyUpCluster.Member(alias: "m\(i + 1)", memory: memory, trust: MemoryTrust(rawValue: m.trust)!, editable: true)
        }
        return (TidyUpCluster(members: members), aliases)
    }

    /// The recorded actions with fixture ids replaced by the prompt's aliases, decoded as the
    /// provider's answer would be.
    static func output(_ actions: [[String: Any]], aliases: [String: String]) throws -> TidyUpPrompt.Output {
        func alias(_ v: Any?) -> Any? {
            if let s = v as? String { return aliases[s] ?? s }
            if let a = v as? [Any] { return a.map { alias($0) ?? "" } }
            return v
        }
        let mapped = actions.map { a -> [String: Any] in
            var out = a
            for key in ["target", "survivor", "sources", "ids"] { out[key] = alias(a[key]) }
            if let kept = a["keptPerSource"] as? [[String: Any]] {
                out["keptPerSource"] = kept.map { k in k.merging(["id": alias(k["id"]) ?? ""]) { _, b in b } }
            }
            return out
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["actions": mapped]), as: UTF8.self)
        return try HTTPClient.decode(json, as: TidyUpPrompt.Output.self)
    }

    /// An action in fixture ids, as the judge reads it.
    struct Judged {
        var type: String
        var target: String?
        var survivor: String?
        var sources: [String] = []
        var ids: [String] = []
        var title = ""
        var body = ""
    }

    static func judged(_ a: TidyUpAction, _ cluster: TidyUpCluster, _ aliases: [String: String]) -> Judged {
        let fixture = Dictionary(uniqueKeysWithValues: aliases.map { ($1, $0) })
        func f(_ id: UUID?) -> String? { id.flatMap { cluster.member(id: $0) }.flatMap { fixture[$0.alias] } }
        return Judged(type: a.type.rawValue, target: f(a.target), survivor: f(a.survivor), sources: a.sources.compactMap(f),
                      ids: a.ids.compactMap(f), title: a.title ?? "", body: a.body ?? "")
    }

    static func matches(_ spec: Spec, _ a: Judged) -> Bool {
        guard spec.type == a.type else { return false }
        if let t = spec.target, !t.split(separator: "|").map(String.init).contains(a.target ?? "") { return false }
        if let s = spec.survivor, !s.split(separator: "|").map(String.init).contains(a.survivor ?? "") { return false }
        if let s = spec.sources, Set(s) != Set(a.sources) { return false }
        if let s = spec.ids, Set(s) != Set(a.ids) { return false }
        let text = "\(a.title) \(a.body)"
        if let keys = spec.keys, !keys.allSatisfy({ SpikeE.matches($0, text) }) { return false }
        if let keys = spec.notkeys, keys.contains(where: { SpikeE.matches($0, text) }) { return false }
        return true
    }

    static func judge(_ c: Cluster, _ a: Judged) -> Bool {
        if c.forbidden.contains(where: { matches($0, a) }) { return false }
        return (c.expected + c.acceptable).contains { matches($0, a) }
    }

    static func forbidden(_ c: Cluster, _ a: Judged) -> Bool { c.forbidden.contains { matches($0, a) } }

    /// Right or wrong, as the spike judged it: an update paired with an archive is right as a
    /// merge of the two, or as an update and an archive each right on its own.
    static func correct(_ a: TidyUpAction, _ c: Cluster, _ cluster: TidyUpCluster, _ aliases: [String: String]) -> Bool {
        let j = judged(a, cluster, aliases)
        guard a.type == .update, let copy = a.alsoArchive else { return judge(c, j) }
        let archived = judged(TidyUpAction(type: .archive, target: copy, survivor: a.target, archiveReason: a.alsoArchiveReason),
                              cluster, aliases)
        var merged = j
        merged.type = "merge"
        merged.sources = [j.target, archived.target].compactMap { $0 }
        merged.target = nil
        return judge(c, merged) || (judge(c, j) && judge(c, archived))
    }
}
