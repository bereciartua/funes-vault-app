import Foundation

/// The roster a Facts call gets (memory processing §11.3): known people as `e1…` with what's known about them, never
/// *you* and never the memory being asked about, built as the spike's `State.roster`. The wording is the prompt
/// resource's.
public struct FactsRoster: Sendable {
    /// The roster as the prompt shows it.
    public var text: String
    /// Roster ids (`e1…`) → entity ids.
    public var ids: [String: String]
    /// Memories whose text the roster quotes ("Known: …"): each goes into the call as a `ModelItem` with its own
    /// sensitivity, so `ModelRouter.send`'s guardrails cover it.
    public var quoted: [String]
    /// Folded names of named things written with a capital that this call may treat as known things.
    public var things: Set<String>
}

extension FactsGraph {
    /// The roster for a call group about `asking`. For a trusted memory it's built from trusted evidence only: the
    /// aliases trusted memories (or the user) gave, facts with trusted evidence, quotes of trusted memories, and things
    /// trusted memories named. Untrusted text never decides a trusted memory (§11.4, §11.9).
    func roster(_ group: String, asking: FactsMemory) -> FactsRoster {
        let t = FactsPrompt.text.roster
        let people = Set(registry.groupPredicates(group).filter { registry.kindOf($0) == FactsValidator.personKind })
        var lines: [String] = [], ids: [String: String] = [:], quoted: [String] = []
        func rosterID() -> String { "e\(ids.count + 1)" }
        for e in orderedEntities where e.kind == FactsValidator.personKind {
            if let g = e.group, e.name == nil {
                guard people.contains(g.predicate) else { continue }
                let members = facts.filter { f in
                    f.predicate == g.predicate && !f.negated && (g.cls == nil || f.cls == g.cls || f.cls == nil)
                        && (f.trusted || !asking.trusted)
                }
                // An unnamed group names nobody, so it's listed whoever spoke of it (a phrase resolved to it is `group`
                // at most); only trusted members can fill it for a trusted call, and its label is disarmed.
                let named = Set(members.filter { entities[$0.entity]?.name != nil }.map(\.entity))
                if let c = e.count, named.count >= c { continue }
                let id = rosterID()
                ids[id] = e.id
                lines.append(FactsPrompt.fill(t.group, [
                    "id": id, "label": Self.inline(g.cls ?? g.predicate), "predicate": g.predicate,
                    "count": e.count.map { FactsPrompt.fill(t.groupCount, ["count": String($0)]) } ?? "",
                ]))
                continue
            }
            let aliases = asking.trusted ? e.trustedAliases : e.aliases
            if aliases.isEmpty { continue }        // known only from text the user didn't write
            let known = facts.filter { $0.entity == e.id && !$0.negated && ($0.trusted || !asking.trusted) }.map { f in
                FactsPrompt.fill(t.fact, [
                    "predicate": f.predicate, "label": f.label.map { FactsPrompt.fill(t.factLabel, ["label": Self.inline($0)]) } ?? "",
                    "status": status(of: f).rawValue, "deceased": e.deceased ? t.deceased : "",
                    "untrusted": f.trusted ? "" : t.untrusted,
                ])
            }
            // Other memories that name them, as sent, in the order they were written (the last few).
            var found: [(mid: String, text: String)] = []
            let naming = names.filter { $0.value.entity == e.id && !codeNames.contains($0.key) }.map(\.key.memoryID)
            for mid in Set(naming).sorted(by: { memoryRank($0) < memoryRank($1) }) where mid != asking.id {
                guard let m = memories[mid], m.trusted || !asking.trusted else { continue }
                let sent = FactsPrompt.disarm(FactsSentText(m.text, userAliases: userAliases, registry: registry).sent)
                if !found.contains(where: { $0.text == sent }) { found.append((mid, sent)) }
            }
            found = Array(found.suffix(t.knownMax))
            let texts = found.map(\.text)
            quoted += found.map(\.mid).filter { !quoted.contains($0) }
            let id = rosterID()
            ids[id] = e.id
            lines.append(FactsPrompt.fill(t.entity, [
                "id": id, "aliases": aliases.sorted().map(Self.inline).joined(separator: ", "),
                "facts": known.isEmpty ? t.noFacts : known.joined(separator: FactsPrompt.text.fragments.listSeparator),
                "known": texts.isEmpty ? "" : FactsPrompt.fill(t.known, [
                    "texts": texts.map { "\"\($0)\"" }.joined(separator: t.knownSeparator),
                ]),
            ]))
        }
        let named = orderedEntities.filter { e in
            e.kind != FactsValidator.personKind && e.name != nil && e.group == nil
                && (!asking.trusted || !e.trustedAliases.isEmpty)
        }
        // A trusted call sees a thing by the names trusted memories gave it.
        func shown(_ e: FactsEntity) -> String? {
            guard asking.trusted else { return e.name }
            return e.name.flatMap { e.trustedAliases.contains($0) ? $0 : nil } ?? e.trustedAliases.sorted().first
        }
        if !named.isEmpty {
            lines.append(FactsPrompt.fill(t.things, ["things": named.map {
                FactsPrompt.fill(t.thing, ["name": Self.inline(shown($0) ?? ""), "kind": $0.kind])
            }.joined(separator: FactsPrompt.text.fragments.listSeparator)]))
        }
        let thingNames = named.flatMap { e in Array(asking.trusted ? e.trustedAliases : e.aliases) }
        let things = Set(thingNames.filter { $0.contains { $0.isUppercase } }.map { FactsText.fold($0) })
        return FactsRoster(text: lines.isEmpty ? t.empty : lines.joined(separator: "\n"), ids: ids, quoted: quoted, things: things)
    }

    /// A name or label on one roster line: no line breaks, no tags.
    static func inline(_ s: String) -> String {
        FactsPrompt.disarm(s.components(separatedBy: .newlines).joined(separator: " "))
    }

    /// Memories in the order they were written.
    func memoryRank(_ id: String) -> (String, Int, String) {
        (memories[id]?.written ?? "", memoryOrder[id] ?? 0, id)
    }
}
