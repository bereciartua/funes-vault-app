import Foundation
import GRDB

/// One link from a memory to an entity, as search reads it (memory processing §4, §11.4): a name the memory uses, one
/// of its role phrases as code resolves it, or a fact it states or mentions.
public struct MemoryLink: Sendable, Hashable {
    public enum Kind: String, Sendable { case name, role, fact }

    public var kind: Kind
    /// Who it links to; nil when it's unresolved (`candidates`, `ambiguous`), with the candidates.
    public var entity: String?
    public var candidates: [String]
    public var basis: LinkBasis
    /// As the memory writes it ("my sister", "Maria", the fact's quote), and where (UTF-16, in title + "\n" + body).
    public var surface: String
    public var start: Int
    /// The predicate of a role phrase or a fact.
    public var predicate: String?
    /// The role phrase's own word, for an unresolved phrase's attribute ("your sister; Funes isn't sure which").
    public var word: String?
}

/// What search reads of learned facts (memory processing §4, owner side only): the graph as `FactStore.load` builds it
/// for what's on, and every memory's links to the entities search may use. Built once per facts revision, vault change
/// and uses; nothing here is stored.
///
/// **Which entities search uses** (§11.10, `linked`): one holding a fact whose predicate has `linked` on, the role
/// group of such a predicate, or a person while some predicate about people has `linked` on (a person's names come
/// from that group's readings). Every other link is left out, so a use that's off admits nothing.
struct FactsSearchIndex: Sendable {
    let graph: FactsGraph
    /// Memory id (the store's lowercase UUID) → its links, to usable entities only.
    let links: [String: [MemoryLink]]
    /// Entities search may use.
    let eligible: Set<String>
    /// The predicates whose `linked` is on.
    let linked: Set<String>
    /// Fact row id by `FactStore.Loaded.key(predicate, entity)`: what **Not this** rejects.
    let factIDs: [String: String]

    var isEmpty: Bool { eligible.isEmpty }

    /// Strongest first: which link explains a result, and which basis a memory's link to an entity has.
    static func strength(_ b: LinkBasis) -> Int {
        switch b {
        case .confirmed: 9
        case .named: 8
        case .statedUnique: 7
        case .context: 6
        case .soleKnown: 5
        case .inferred: 4
        case .untrusted: 3
        case .group: 2
        case .candidates: 1
        case .ambiguous: 0
        case .rejected, .someoneElse: -1
        }
    }

    /// The bases a link to a named entity counts as evidence that the memory is about that entity (the −0.1 for a
    /// memory linked only to entities the query doesn't name): the spike's full bases. A weak, unresolved or group link
    /// isn't evidence that the memory is about someone else.
    static let fullBases: Set<LinkBasis> = [.confirmed, .named, .statedUnique, .context]

    /// Builds the index in one read: the graph for `uses`, and every active or archived memory's links. Role phrases are
    /// resolved here for every memory, read by the Facts task or not ("resolved when read, nothing stored", §11.3).
    /// `sendable`: the graph a cloud call may see under that limit (§11.9), for the second index's rule.
    static func build(_ db: Database, registry: FactsRegistry, userAliases: [String], uses: FactsUses,
                      sendable: CloudLimit? = nil, phrases: RolePhraseCache? = nil) throws -> FactsSearchIndex {
        let loaded = try FactStore.load(db, registry: registry, userAliases: userAliases, uses: uses, sendable: sendable)
        var g = loaded.graph
        g.episodeMemo = EpisodeMemo()        // its facts don't change from here on
        let linked = Set(uses.predicates(.linked))
        let personLinked = linked.contains { registry.kindOf($0) == FactsValidator.personKind }

        var eligible = Set<String>()
        for f in g.facts where !f.negated && linked.contains(f.predicate) { eligible.insert(f.entity) }
        for (id, e) in g.entities {
            if let group = e.group, e.name == nil {
                if linked.contains(group.predicate) { eligible.insert(id) }
            } else if personLinked, e.kind == FactsValidator.personKind, e.name != nil {
                eligible.insert(id)
            }
        }

        // Memories as learned facts see them: the graph's (counted ones), and the others the Facts task has dealt with
        // at their current version (a reading that left nothing stored, a code-only pass whose job is still recorded):
        // their role phrases resolve through known facts (§11.3). A memory it hasn't read yet gets no link.
        var memories = g.memories
        if sendable == nil {
            for r in try Row.fetchAll(db, sql: """
                SELECT m.id, m.title, m.body, m.created_at, COALESCE(m.original_source, m.source) AS source, m.trust FROM memory m
                WHERE m.status IN ('active','archived')
                  AND (EXISTS (SELECT 1 FROM facts_asked a WHERE a.memory_id = m.id AND a.memory_version = m.version)
                    OR EXISTS (SELECT 1 FROM processing_job j WHERE j.kind = 'facts' AND j.subject = m.id
                                 AND j.memory_version = m.version AND j.state IN ('done','failed')))
                """) {
                let id: String = r["id"]
                guard memories[id] == nil else { continue }
                let created: Date = r["created_at"]
                memories[id] = FactsMemory(id: id, text: FactStore.text(title: r["title"], body: r["body"]),
                                           written: FactStore.writtenDay(created), source: FactStore.source(r["source"]),
                                           trusted: (r["trust"] as String) == "trusted")
            }
        }

        var out: [String: [MemoryLink]] = [:]
        // Names: the people each memory names (alias evidence), or a name the model left ambiguous.
        var namesBy: [String: [(FactsGraph.NameKey, NameLink)]] = [:]
        for (k, l) in g.names { namesBy[k.memoryID, default: []].append((k, l)) }
        // Facts: each memory's statements (the user's own rows have no memory).
        var statementsBy: [String: [(LearnedFact, FactAssertion)]] = [:]
        for f in g.facts where !f.negated && linked.contains(f.predicate) {
            for a in f.assertions where !a.fromUser { statementsBy[a.memoryID, default: []].append((f, a)) }
        }
        let phrasePredicates = linked.intersection(uses.predicates(.recorded))

        for (mid, mem) in memories.sorted(by: { $0.key < $1.key }) {
            var ls: [MemoryLink] = []
            let text = mem.text
            for (key, link) in (namesBy[mid] ?? []).sorted(by: { $0.0.surface < $1.0.surface }) {
                // A rejected name ("Not <name>") is already gone from the graph (`FactStore.load`).
                let starts = FactsText.wholeWordStarts(key.surface, in: text)
                if let e = link.entity {
                    guard eligible.contains(e) else { continue }
                    ls.append(MemoryLink(kind: .name, entity: e, candidates: [], basis: link.basis, surface: key.surface,
                                         start: starts.first ?? 0, predicate: nil, word: nil))
                } else if link.basis == .ambiguous {
                    let cands = link.candidates.filter(eligible.contains)
                    guard !cands.isEmpty else { continue }
                    ls.append(MemoryLink(kind: .name, entity: nil, candidates: cands, basis: .ambiguous, surface: key.surface,
                                         start: starts.first ?? 0, predicate: nil, word: nil))
                }
            }
            if !phrasePredicates.isEmpty {
                let found = phrases?.phrases(text, graph: g, predicates: phrasePredicates) ?? g.rolePhrases(text, predicates: phrasePredicates)
                for ph in found {
                    let r = g.resolution(mem, ph)
                    if let entity = r.entity {
                        guard eligible.contains(entity) || g.entities[entity]?.group.map({ linked.contains($0.predicate) }) == true
                        else { continue }
                        ls.append(MemoryLink(kind: .role, entity: entity, candidates: [], basis: r.basis, surface: ph.surface,
                                             start: ph.start, predicate: ph.predicate, word: ph.word))
                    } else if r.basis == .candidates {
                        let cands = r.candidates.filter(eligible.contains)
                        guard !cands.isEmpty else { continue }
                        ls.append(MemoryLink(kind: .role, entity: nil, candidates: cands, basis: .candidates, surface: ph.surface,
                                             start: ph.start, predicate: ph.predicate, word: ph.word))
                    }
                }
            }
            for (f, a) in statementsBy[mid] ?? [] where eligible.contains(f.entity) {
                let start = a.span?.location ?? FactStore.locate(a.quote, in: text, near: nil)?.start ?? 0
                ls.append(MemoryLink(kind: .fact, entity: f.entity, candidates: [], basis: a.trusted ? .named : .untrusted,
                                     surface: a.quote, start: start, predicate: f.predicate, word: nil))
            }
            if !ls.isEmpty { out[mid] = ls }
        }
        // Groups made while resolving (a phrase with no holder: "my sisters") live only in this graph, which the query
        // plan resolves against too, so a query's "my sisters" finds the same group.
        for (key, id) in g.groups where linked.contains(key.predicate) { eligible.insert(id) }
        g.landed = [:]
        return FactsSearchIndex(graph: g, links: out, eligible: eligible, linked: linked, factIDs: loaded.factIDs)
    }
}

extension FactsText {
    /// Text folded character by character (case and accents), with each folded UTF-16 offset's original offset, so a
    /// match in the folded text maps back to the original (the spike's `folded_with_map`).
    struct Folded {
        let text: String
        let map: [Int]          // folded UTF-16 index → original UTF-16 index
        let originalLength: Int

        func original(_ i: Int) -> Int { i < map.count ? map[i] : originalLength }
    }

    static func foldedWithMap(_ s: String) -> Folded {
        var out = "", map: [Int] = []
        var offset = 0
        for ch in s {
            let piece = String(ch).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            out += piece
            map += Array(repeating: offset, count: piece.utf16.count)
            offset += String(ch).utf16.count
        }
        return Folded(text: out, map: map, originalLength: offset)
    }
}

/// Role phrases by text, kept across index builds: they depend only on the text, the registry, your names and the
/// predicates read, so a facts change re-resolves them without finding them again.
public final class RolePhraseCache: @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var key = ""
    private var byText: [String: [RolePhrase]] = [:]
    private var generation = 0

    func phrases(_ text: String, graph g: FactsGraph, predicates: Set<String>) -> [RolePhrase] {
        let k = g.registry.fingerprint + "\u{1F}" + g.userAliases.joined(separator: "\u{1F}") + "\u{1F}" + predicates.sorted().joined(separator: ",")
        let (hit, started): ([RolePhrase]?, Int) = lock.withLock {
            if key != k { key = k; byText.removeAll() }
            return (byText[text], generation)
        }
        if let hit { return hit }
        let found = g.rolePhrases(text, predicates: predicates)
        lock.withLock {
            guard generation == started else { return }      // cleared meanwhile: keep nothing
            if byText.count > 20_000 { byText.removeAll() }
            byText[text] = found
        }
        return found
    }

    /// Learned facts turned off: no memory's text stays here either.
    public func clear() { lock.withLock { byText.removeAll(); generation += 1 } }
}
