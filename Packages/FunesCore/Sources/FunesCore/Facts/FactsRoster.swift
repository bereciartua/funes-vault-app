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
    /// Each line with the entities it shows, so it goes to `ModelRouter.send` as a typed item with the highest
    /// sensitivity behind them (memory processing §11.9).
    public var lines: [(text: String, entities: [String])] = []
}

extension FactsGraph {
    /// The roster for a call group about `asking`. For a trusted memory it's built from trusted evidence only: the
    /// aliases trusted memories (or the user) gave, facts with trusted evidence, quotes of trusted memories, and things
    /// trusted memories named. Untrusted text never decides a trusted memory (§11.4, §11.9).
    func roster(_ group: String, asking: FactsMemory) -> FactsRoster {
        let t = FactsPrompt.text.roster
        // Every name and label as a call sends it: the user's names replaced (a label learned before a name was in
        // About you, a thing called after the user), a known person's full name kept.
        func inline(_ s: String) -> String { Self.inline(sentText(s).sent) }
        let people = Set(uses.predicates(.recorded, group: group).filter { registry.kindOf($0) == FactsValidator.personKind })
        var lines: [String] = [], ids: [String: String] = [:], quoted: [String] = []
        var shownBy: [[String]] = []
        let users = Set(userAliases.map { FactsText.fold($0) })
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
                shownBy.append([e.id])
                lines.append(FactsPrompt.fill(t.group, [
                    "id": id, "label": inline(g.cls ?? g.predicate), "predicate": g.predicate,
                    "count": e.count.map { FactsPrompt.fill(t.groupCount, ["count": String($0)]) } ?? "",
                ]))
                continue
            }
            // The user's own names are never in a roster: someone known only by one isn't listed.
            let aliases = (asking.trusted ? e.trustedAliases : e.aliases).filter { !users.contains(FactsText.fold($0)) }
            if aliases.isEmpty { continue }        // known only from text the user didn't write
            let known = facts.filter { $0.entity == e.id && !$0.negated && ($0.trusted || !asking.trusted) }.map { f in
                FactsPrompt.fill(t.fact, [
                    "predicate": f.predicate, "label": f.label.map { FactsPrompt.fill(t.factLabel, ["label": inline($0)]) } ?? "",
                    "status": status(of: f).rawValue, "deceased": e.deceased ? t.deceased : "",
                    "untrusted": f.trusted ? "" : t.untrusted,
                ])
            }
            // Other memories that name them, as sent, in the order they were written (the last few).
            var found: [(mid: String, text: String)] = []
            let naming = names.filter { $0.value.entity == e.id && !codeNames.contains($0.key) }.map(\.key.memoryID)
            for mid in Set(naming).sorted(by: { memoryRank($0) < memoryRank($1) }) where mid != asking.id {
                guard let m = memories[mid], m.trusted || !asking.trusted else { continue }
                let sent = FactsPrompt.disarm(sentText(m.text).sent)
                if !found.contains(where: { $0.text == sent }) { found.append((mid, sent)) }
            }
            found = Array(found.suffix(t.knownMax))
            let texts = found.map(\.text)
            quoted += found.map(\.mid).filter { !quoted.contains($0) }
            let id = rosterID()
            ids[id] = e.id
            shownBy.append([e.id])
            lines.append(FactsPrompt.fill(t.entity, [
                "id": id, "aliases": aliases.sorted().map(inline).joined(separator: ", "),
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
            shownBy.append(named.map(\.id))
            lines.append(FactsPrompt.fill(t.things, ["things": named.map {
                FactsPrompt.fill(t.thing, ["name": inline(shown($0) ?? ""), "kind": $0.kind])
            }.joined(separator: FactsPrompt.text.fragments.listSeparator)]))
        }
        let thingNames = named.flatMap { e in Array(asking.trusted ? e.trustedAliases : e.aliases) }
        let things = Set(thingNames.filter { $0.contains { $0.isUppercase } }.map { FactsText.fold($0) })
        return FactsRoster(text: lines.isEmpty ? t.empty : lines.joined(separator: "\n"), ids: ids, quoted: quoted, things: things,
                           lines: Array(zip(lines, shownBy)).map { ($0.0, $0.1) })
    }

    /// What the profile matcher knows about the user's namesakes: known people's names of two or more words.
    var namesakes: FactsNamesakes {
        guard !userAliases.isEmpty else { return .none }
        let users = Set(userAliases.map { FactsText.fold($0) })
        let people = orderedEntities.filter { $0.kind == FactsValidator.personKind && !($0.group != nil && $0.name == nil) }
        let things = orderedEntities.filter { $0.kind != FactsValidator.personKind && $0.group == nil }
        return FactsNamesakes(fullNames: people.flatMap { $0.aliases.filter { $0.split(separator: " ").count >= 2 && !users.contains(FactsText.fold($0)) }.sorted() },
                              thingWords: Set(things.flatMap { $0.aliases.flatMap { $0.split(whereSeparator: { !$0.isLetter }).map { FactsText.fold(String($0)) } } }))
    }

    /// A text as a call sends it, with the profile matcher's knowledge of this graph.
    func sentText(_ text: String) -> FactsSentText {
        FactsSentText(text, userAliases: userAliases, registry: registry, namesakes: namesakes)
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
