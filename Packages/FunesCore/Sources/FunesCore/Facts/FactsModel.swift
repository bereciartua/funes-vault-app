import Foundation

/// A memory as learned facts see it: its text, when it was written, where it came from and whether it's trusted.
public struct FactsMemory: Sendable, Equatable {
    public enum Source: String, Sendable { case capture, agent, `import`, rewritten, manual }

    public var id: String
    public var text: String
    public var written: String          // ISO date
    public var source: Source
    public var trusted: Bool

    /// Agent-written memories are untrusted unless stated otherwise (memory processing §11.8).
    public init(id: String, text: String, written: String, source: Source = .capture, trusted: Bool? = nil) {
        self.id = id
        self.text = text
        self.written = written
        self.source = source
        self.trusted = trusted ?? (source != .agent)
    }
}

/// What a memory asserts about one fact (memory processing §11.1): the values as written, never resolved dates.
public struct FactAssertion: Sendable, Equatable {
    public enum Status: String, Sendable { case current, former, unknown }

    public var memoryID: String
    public var trusted: Bool
    public var written: String
    public var start: String?
    public var end: String?
    public var time: String?
    public var status: Status
    public var precededBy: String?
    public var followedBy: String?
    public var qualifiers: [String: String]
    public var states: Bool
    public var label: String?
    public var quote: String
    public var handover: Bool
    /// Entered by the user (`source` = user): its dates win over inference (memory processing §11.8).
    public var fromUser = false
    /// For a user row: the date range of the episode the user acted on; it applies to the episode overlapping it.
    public var selector: DateRange?
    /// Order edges to a fact's entity by id (the user's), rather than by a name as written.
    public var precededByEntity: String?
    public var followedByEntity: String?
    /// For a user's order edge: the date range of the other endpoint's episode when the user acted.
    public var otherSelector: DateRange?
    /// Where it sits in the order facts are read (memories by written date, then the user's rows by entry): kept so a
    /// merge can restore it.
    public var readOrder = ""
    /// What this statement itself said: "only" one, and that the entity has died (kept per statement, so each goes
    /// with its own memory).
    public var only = false
    public var deceased = false
}

/// Someone or something memories mention. *You* is never in the graph.
public struct FactsEntity: Sendable, Equatable {
    public struct RoleGroup: Sendable, Hashable {
        public var predicate: String
        public var cls: String?
    }

    public var id: String
    public var seq: Int                  // creation order
    public var kind: String
    public var name: String?
    public var aliases: Set<String>
    public var group: RoleGroup?
    public var count: Int?
    public var deceased: Bool
    /// Aliases a trusted memory (or the user) gave: the only ones a trusted memory's names match, so an untrusted
    /// memory can never re-route trusted evidence (memory processing §11.8).
    public var trustedAliases: Set<String> = []

    /// Every alias and every alias's first word.
    var nameForms: Set<String> {
        aliases.union(aliases.compactMap { $0.split(separator: " ").first.map(String.init) })
    }
}

/// You → predicate → entity. Its dates and status live in its assertions; episodes are derived (`Episodes.swift`).
public struct LearnedFact: Sendable, Equatable {
    public var entity: String
    public var predicate: String
    public var label: String?
    public var cls: String?
    public var only: Bool
    public var negated: Bool
    public var assertions: [FactAssertion]

    public var trusted: Bool { assertions.contains { $0.trusted } }
}

/// How a link was decided (memory processing §11.6).
public enum LinkBasis: String, Sendable {
    case confirmed, named, context, candidates, ambiguous, untrusted, rejected, group, inferred
    case statedUnique = "stated_unique"
    case soleKnown = "sole_known"
    case someoneElse = "someone_else"
}

/// A stored decision for one role phrase: the entity it refers to (nil for someone else) and why.
public struct MentionDecision: Sendable, Equatable {
    public var entity: String?
    public var basis: LinkBasis
}

/// A name a memory uses, and who it was linked to.
public struct NameLink: Sendable, Equatable {
    public var entity: String?
    public var basis: LinkBasis
    public var candidates: [String]
}

// MARK: - A validated extraction (13a.2 produces these from the model's output)

public struct ExtractedPerson: Sendable {
    public var name: String
    public var quote: String
    public var person: String           // an entity id from the roster, "new" or "ambiguous"

    public init(name: String, quote: String? = nil, person: String = "new") {
        self.name = name
        self.quote = quote ?? name
        self.person = person
    }
}

public struct ExtractedFact: Sendable {
    public var quote: String
    public var predicate: String
    public var entity: String           // "name", "none", "group" or an entity id from the roster
    public var name: String
    public var label: String?
    public var positive: Bool
    public var status: FactAssertion.Status
    public var deceased: Bool
    public var only: Bool
    public var count: Int?
    public var time: String?
    public var start: String?
    public var end: String?
    public var precededBy: String?
    public var followedBy: String?
    public var alsoCalled: String?
    public var qualifiers: [String: String]

    public init(predicate: String, name: String, entity: String = "name", label: String? = nil, quote: String? = nil,
                positive: Bool = true, status: FactAssertion.Status = .unknown, deceased: Bool = false,
                only: Bool = false, count: Int? = nil, time: String? = nil, start: String? = nil,
                end: String? = nil, precededBy: String? = nil, followedBy: String? = nil, alsoCalled: String? = nil,
                qualifiers: [String: String] = [:]) {
        self.quote = quote ?? name
        self.predicate = predicate
        self.entity = entity
        self.name = name
        self.label = label
        self.positive = positive
        self.status = status
        self.deceased = deceased
        self.only = only
        self.count = count
        self.time = time
        self.start = start
        self.end = end
        self.precededBy = precededBy
        self.followedBy = followedBy
        self.alsoCalled = alsoCalled
        self.qualifiers = qualifiers
    }
}

public struct ExtractedRole: Sendable {
    public var phrase: Int              // index into the memory's role phrases
    public var refersTo: String         // an entity id, "name:<name>", "group" or "someone_else"

    public init(phrase: Int, refersTo: String) {
        self.phrase = phrase
        self.refersTo = refersTo
    }
}

// MARK: - The graph

/// The learned facts in memory, as resolution and the timeline read them (memory processing §11.4–§11.7). Every rule
/// takes its vocabulary and predicate behaviour from `registry`, so a test can swap registries.
public struct FactsGraph: Sendable {
    public let registry: FactsRegistry
    public var userAliases: [String]
    public var entities: [String: FactsEntity] = [:]
    public var facts: [LearnedFact] = []
    public var groups: [FactsEntity.RoleGroup: String] = [:]
    public var decisions: [DecisionKey: MentionDecision] = [:]
    public var names: [NameKey: NameLink] = [:]
    public var memories: [String: FactsMemory] = [:]
    /// Order edges the user rejected ("Not this" on an order): before → after, by entity.
    public var rejectedEdges: [EdgeRejection] = []
    /// A rejected edge, optionally for one episode of each endpoint (its date range when the user acted).
    public struct EdgeRejection: Sendable, Hashable {
        public var from: String
        public var to: String
        public var fromSelector: DateRange?
        public var toSelector: DateRange?
        public init(from: String, to: String, fromSelector: DateRange? = nil, toSelector: DateRange? = nil) {
            self.from = from; self.to = to; self.fromSelector = fromSelector; self.toSelector = toSelector
        }
    }
    /// The entity each fact of the last `apply` landed on (by its index), so the store records aliases against it.
    public var landed: [Int: String] = [:]
    /// Pairs the user said aren't the same entity (Not the Same): never matched to each other, never suggested.
    public var notSame: Set<Set<String>> = []
    /// Two entities a memory says are the same ("also called"): for To check, never merged automatically.
    public var mergeSuggestions: [MergeSuggestion] = []
    public struct MergeSuggestion: Sendable, Equatable { public var entity: String; public var other: String }
    /// "Not <name>" on a mention: entities a role phrase in a memory doesn't refer to.
    public var rejections: [DecisionKey: Set<String>] = [:]
    /// Ids for new entities: counters ("p1") in tests and spikes, UUIDs in the vault.
    public var idStyle: IDStyle = .counter
    private var counter = 0

    public enum IDStyle: Sendable { case counter, uuid }

    public struct DecisionKey: Hashable, Sendable {
        public var memoryID: String
        public var start: Int
    }

    public struct NameKey: Hashable, Sendable {
        public var memoryID: String
        public var surface: String
    }

    public init(registry: FactsRegistry = .bundled, userAliases: [String] = []) {
        self.registry = registry
        self.userAliases = userAliases
    }

    var parser: DateParser { DateParser(registry: registry) }

    /// Entities in creation order.
    var orderedEntities: [FactsEntity] { entities.values.sorted { $0.seq < $1.seq } }

    public func entity(_ id: String?) -> FactsEntity? { id.flatMap { entities[$0] } }

    // MARK: Entities

    @discardableResult
    public mutating func newEntity(name: String? = nil, group: FactsEntity.RoleGroup? = nil, kind: String = "person",
                                   trusted: Bool = true) -> String {
        counter += 1
        let id = idStyle == .uuid ? UUID().uuidString.lowercased() : "p\(counter)"
        entities[id] = FactsEntity(id: id, seq: counter, kind: kind, name: name, aliases: name.map { [$0] } ?? [],
                                   group: group, count: nil, deceased: false,
                                   trustedAliases: trusted ? (name.map { [$0] } ?? []) : [])
        return id
    }

    /// Gives an entity an alias; a trusted memory's alias is also matchable by trusted memories.
    mutating func addAlias(_ id: String, _ alias: String, trusted: Bool) {
        entities[id]?.aliases.insert(alias)
        if trusted { entities[id]?.trustedAliases.insert(alias) }
    }

    /// Adds an entity loaded from storage, keeping its id; creation order follows load order.
    public mutating func insert(_ e: FactsEntity) {
        counter += 1
        var e = e
        e.seq = counter
        entities[e.id] = e
        if let g = e.group, e.name == nil { groups[g] = e.id }
    }

    @discardableResult
    public mutating func groupFor(_ predicate: String, _ cls: String?) -> String {
        let key = FactsEntity.RoleGroup(predicate: predicate, cls: cls)
        if let id = groups[key] { return id }
        let id = newEntity(group: key, kind: registry.kindOf(predicate))
        groups[key] = id
        return id
    }

    /// Entities a name could mean, by the kind's match rule (exact, first name, or containment), in creation order.
    /// `onlyTrusted`: match only the aliases trusted memories gave (when a trusted memory names someone).
    public func byName(_ name: String, kind: String = "person", onlyTrusted: Bool = false) -> [FactsEntity] {
        let f = FactsText.normName(name, kind: kind, registry: registry)
        let rule = registry.kinds[kind]?.match ?? "exact"
        func exact(_ e: FactsEntity) -> Bool {
            (onlyTrusted ? e.trustedAliases : e.aliases).contains { FactsText.normName($0, kind: kind, registry: registry) == f }
        }
        // An exact (normalised) match comes before a looser one ("Acme Labs" is Acme Labs, not Acme).
        let all = orderedEntities.filter { $0.name != nil && $0.kind == kind }
        return (all.filter(exact) + all.filter { !exact($0) }).filter { e in
            let al = (onlyTrusted ? e.trustedAliases : e.aliases).map { FactsText.normName($0, kind: kind, registry: registry) }
            if al.contains(f) { return true }
            if rule == "first_name", f.count >= 3,
               al.contains(where: { $0.split(separator: " ").first.map(String.init) == f }) {
                return true
            }
            if rule == "contains", !f.isEmpty, al.contains(where: { !$0.isEmpty && ($0.contains(f) || f.contains($0)) }) {
                return true
            }
            return false
        }
    }

    /// A non-person entity by its kind's rule. "Also called" adds the other name as an alias only when no other
    /// entity has it; two entities it would join become a merge suggestion in To check, never a merge
    /// (memory processing §11.4).
    public mutating func entityFor(_ name: String, kind: String, also: String? = nil, trusted: Bool = true) -> String {
        // Attached only by a normalised match (case, accents, legal suffixes); a looser one (one name inside the other)
        // is a merge suggestion, never a merge (memory processing §11.4).
        func exactly(_ n: String) -> [FactsEntity] {
            let f = FactsText.normName(n, kind: kind, registry: registry)
            return byName(n, kind: kind, onlyTrusted: trusted).filter { e in
                (trusted ? e.trustedAliases : e.aliases).contains { FactsText.normName($0, kind: kind, registry: registry) == f }
            }
        }
        let loose = byName(name, kind: kind, onlyTrusted: trusted)
        let id = exactly(name).first?.id ?? also.flatMap { exactly($0).first?.id }
            ?? newEntity(name: name, kind: kind, trusted: trusted)
        for o in loose where o.id != id && !notSame.contains([id, o.id])
            && !mergeSuggestions.contains(where: { $0.entity == id && $0.other == o.id }) {
            mergeSuggestions.append(MergeSuggestion(entity: id, other: o.id))
        }
        addAlias(id, name, trusted: trusted)          // an untrusted memory's names never match a trusted memory's
        if let also {
            let others = byName(also, kind: kind).filter { $0.id != id }
            if others.isEmpty {
                addAlias(id, also, trusted: trusted)
            } else {
                for o in others where !mergeSuggestions.contains(where: { $0.entity == id && $0.other == o.id })
                    && !notSame.contains([id, o.id]) {
                    mergeSuggestions.append(MergeSuggestion(entity: id, other: o.id))
                }
            }
        }
        return id
    }

    /// The placeholder an object name stands for ("freelance" → "Self-employed"), if any.
    public func placeholder(_ predicate: String, _ name: String) -> String? {
        let n = FactsText.fold(name)
        for (ph, syn) in (registry.predicate(predicate)?.placeholders ?? [:]).sorted(by: { $0.key < $1.key }) {
            if n == FactsText.fold(ph) || syn.contains(where: { FactsText.has(n, $0) }) { return ph }
        }
        return nil
    }

    /// Entities holding a fact of this predicate that a name could mean.
    /// `onlyTrusted`: through aliases trusted memories gave (a trusted memory's order edge, the user's question).
    /// When a normalised-exact match exists, only exact matches count ("Acme" isn't also "Acme Labs").
    public func entityMatches(_ predicate: String, _ name: String, onlyTrusted: Bool = false) -> [String] {
        let kind = registry.kindOf(predicate)
        let holders = Set(facts.filter { $0.predicate == predicate && !$0.negated }.map(\.entity))
        let n = placeholder(predicate, name) ?? name
        let f = FactsText.normName(n, kind: kind, registry: registry)
        let hits = byName(n, kind: kind, onlyTrusted: onlyTrusted).filter { holders.contains($0.id) }
        let exact = hits.filter { e in
            (onlyTrusted ? e.trustedAliases : e.aliases).contains { FactsText.normName($0, kind: kind, registry: registry) == f }
        }
        // Only where names match by containment: a shared first name still matches everyone who has it (§11.4).
        let containment = registry.kinds[kind]?.match == "contains"
        return (exact.isEmpty || !containment ? hits : exact).map(\.id)
    }

    /// A fact's label: the user's, else the first trusted statement's; an untrusted label only for a fact with no
    /// trusted evidence (it could otherwise classify, or drop, a trusted holder).
    func effectiveLabel(_ f: LearnedFact) -> String? {
        f.assertions.last(where: { $0.fromUser && $0.label != nil })?.label
            ?? f.assertions.last(where: { $0.trusted && $0.label != nil })?.label     // a later trusted correction wins
            ?? (f.trusted ? nil : f.assertions.first(where: { $0.label != nil })?.label)
    }

    mutating func refreshLabel(_ i: Int) {
        let l = effectiveLabel(facts[i])
        facts[i].label = l
        facts[i].cls = labelClass(facts[i].predicate, l)
    }

    func labelClass(_ predicate: String, _ label: String?) -> String? {
        guard let label else { return nil }
        let lex = registry.lexicon
        let w = label.lowercased().trimmingCharacters(in: .whitespaces)
        var parts = [w] + w.split(separator: " ").map(String.init)
        parts += parts.filter { $0.hasSuffix("s") && lex[String($0.dropLast())] != nil }.map { String($0.dropLast()) }
        for part in parts {
            if let word = lex[part], word.predicate == predicate { return word.cls }
        }
        return w
    }

    var formerWords: Set<String> {
        var w = Set(registry.language.formerWords).union(registry.formerCues)
        for (word, meaning) in registry.lexicon where meaning.status == "former" { w.insert(word) }
        return w
    }

    /// Whether a fact's quote states it: it names the entity and, for a person, uses a word of the predicate (or the
    /// text pairs the name with a role phrase of the predicate).
    func statesFact(_ r: ExtractedFact, aliases: Set<String>, phrases: [RolePhrase]) -> Bool {
        let folded = Set(aliases.map { FactsText.fold($0) })
        if phrases.contains(where: { $0.paired.map { folded.contains(FactsText.fold($0)) } ?? false && $0.predicate == r.predicate }) {
            return true
        }
        let q = FactsText.fold(r.quote)
        let named = aliases.contains { FactsText.has(q, $0) }
        if registry.kindOf(r.predicate) != "person" { return named }
        var words = Set(registry.lexicon.filter { $0.value.predicate == r.predicate }.map(\.key))
        if let label = r.label { words.insert(FactsText.fold(label)) }
        return named && words.contains { FactsText.has(q, $0) }
    }

    // MARK: Apply (memory processing §11.3): one memory's validated extraction changes the graph

    public mutating func apply(_ mem: FactsMemory, phrases: [RolePhrase] = [], people: [ExtractedPerson] = [],
                               facts newFacts: [ExtractedFact] = [], roles: [ExtractedRole] = [],
                               roster: Set<String> = []) {
        memories[mem.id] = mem
        let mid = mem.id, trusted = mem.trusted
        landed = [:]
        var here: [String: String] = [:], regroup: [String: String] = [:]
        for p in people {
            let f = FactsText.fold(p.name)
            let pid: String
            if roster.contains(p.person), let e = entities[p.person], e.group != nil, e.name == nil,
               e.group?.cls == nil || (e.count ?? 1) > 1 {
                pid = byName(p.name, onlyTrusted: trusted).first?.id ?? newEntity(name: p.name, trusted: trusted)
                regroup[p.person] = pid
            } else if roster.contains(p.person), entities[p.person] != nil {
                pid = p.person
                addAlias(pid, p.name, trusted: trusted)
                if entities[pid]?.name == nil { entities[pid]?.name = p.name }
            } else if p.person == "ambiguous" {
                names[NameKey(memoryID: mid, surface: p.name)] =
                    NameLink(entity: nil, basis: .ambiguous, candidates: byName(p.name, onlyTrusted: trusted).map(\.id))
                continue
            } else {
                let same = p.person == "new" ? byName(p.name, onlyTrusted: trusted) : []
                pid = same.count == 1 ? same[0].id : newEntity(name: p.name, trusted: trusted)
            }
            here[f] = pid
            names[NameKey(memoryID: mid, surface: p.name)] = NameLink(entity: pid, basis: trusted ? .named : .untrusted,
                                                                      candidates: [])
        }
        for (ri, r) in newFacts.enumerated() {
            let pred = r.predicate
            let kind = registry.kindOf(pred)
            let cls = labelClass(pred, r.label)
            // Counts and "only" come from trusted memories alone: an untrusted one could otherwise make a trusted
            // link stated_unique, or ambiguous.
            if r.entity == "none" {
                let g = groupFor(pred, cls)
                if trusted { entities[g]?.count = 0 }
                continue
            }
            if r.entity == "group" {
                let g = groupFor(pred, cls)
                if trusted, let c = r.count { entities[g]?.count = c }
                if trusted, r.only { entities[g]?.count = 1 }
                continue
            }
            let pid: String?
            if kind == "person" {
                pid = r.entity == "name" ? here[FactsText.fold(r.name)] : (regroup[r.entity] ?? r.entity)
            } else {
                pid = entityFor(r.name, kind: kind, also: r.alsoCalled, trusted: trusted)
            }
            guard let pid, let ent = entities[pid] else { continue }
            landed[ri] = pid
            let states = statesFact(r, aliases: ent.aliases, phrases: phrases)
            if ent.group != nil, ent.name == nil {
                if trusted, let c = r.count { entities[pid]?.count = c }
                if trusted, r.only { entities[pid]?.count = 1 }
                continue
            }
            if r.deceased, trusted { entities[pid]?.deceased = true }
            var status = r.status
            if status == .former, r.deceased, !formerWords.contains(where: { FactsText.has(FactsText.fold(r.quote), $0) }) {
                status = .unknown        // "my late father": a death isn't an end, unless the memory says it ended
            }
            let existing = facts.indices.filter { facts[$0].entity == pid && facts[$0].predicate == pred && !facts[$0].negated }
            if !r.positive, status == .current, !existing.isEmpty {
                status = .former         // "not back together", "no longer": it isn't current now, not that it never was
            } else if !r.positive {
                for i in existing where trusted || !facts[i].trusted { facts[i].negated = true }
                continue
            }
            let p = registry.predicate(pred)
            let handover = existing.isEmpty && r.start == nil && r.end == nil && r.time == nil && status != .former
                && ((p?.exclusive ?? false) || (p?.succession ?? false))
                && facts.contains { $0.predicate == pred && $0.entity != pid && !$0.negated && ($0.trusted || !trusted) }
            var a = FactAssertion(memoryID: mid, trusted: trusted, written: mem.written, start: r.start, end: r.end,
                                  time: r.time, status: status, precededBy: r.precededBy, followedBy: r.followedBy,
                                  qualifiers: r.qualifiers.filter { !$0.value.isEmpty }, states: states, label: r.label,
                                  quote: r.quote, handover: handover)
            a.only = r.only
            a.deceased = r.deceased
            if let i = existing.first {
                facts[i].only = facts[i].only || (r.only && trusted)
                facts[i].assertions.append(a)
                refreshLabel(i)
            } else {
                facts.append(LearnedFact(entity: pid, predicate: pred, label: r.label, cls: cls, only: r.only && trusted,
                                         negated: false, assertions: [a]))
                refreshLabel(facts.count - 1)
            }
            if trusted, let c = r.count { entities[groupFor(pred, cls)]?.count = c }
            if trusted, r.only { entities[groupFor(pred, cls)]?.count = 1 }
        }
        for x in roles where phrases.indices.contains(x.phrase) {
            let ph = phrases[x.phrase]
            let key = DecisionKey(memoryID: mid, start: ph.start)
            let (d, written) = asOf(mem, ph)
            let held = holders(ph, asOf: d, written: written)
            let several = held.holders.count + held.extra > 1
            let ref = x.refersTo
            let named: LinkBasis = trusted ? .named : .untrusted
            if ref == "someone_else" {
                decisions[key] = MentionDecision(entity: nil, basis: .someoneElse)
            } else if ref.hasPrefix("name:") {
                if let pid = here[FactsText.fold(String(ref.dropFirst(5)))] {
                    decisions[key] = MentionDecision(entity: pid, basis: named)
                }
            } else if roster.contains(ref), let e = entities[ref], let paired = ph.paired, e.name != nil,
                      (trusted ? e.trustedAliases : e.aliases).map({ FactsText.fold($0) }).contains(FactsText.fold(paired)) {
                decisions[key] = MentionDecision(entity: ref, basis: named)   // the text pairs them, the model agrees
            } else if roster.contains(ref), let e = entities[ref], e.group != nil, e.name == nil, several {
                decisions[key] = MentionDecision(entity: ref, basis: .group)
            } else if roster.contains(ref), entities[ref] != nil, several {
                decisions[key] = MentionDecision(entity: ref, basis: trusted ? .context : .untrusted)
            } else if ref == "group", several {
                decisions[key] = MentionDecision(entity: groupFor(ph.predicate, ph.generic ? nil : ph.cls), basis: .group)
            }
        }
        if trusted { reopenSharedNames(except: mid) }
    }

    /// A second trusted entity sharing a bare name makes earlier `named` mentions of it `ambiguous` (memory processing
    /// §11.4), for reconciliation to ask again. An untrusted memory's names never reopen a trusted link.
    mutating func reopenSharedNames(except mid: String) {
        var sharing: [String: [String]] = [:]
        for (key, link) in names where key.memoryID != mid && link.basis == .named {
            guard let e = link.entity, FactsText.fold(key.surface).split(separator: " ").count == 1 else { continue }
            let kind = entities[e]?.kind ?? "person"
            let ids = sharing[key.surface] ?? byName(key.surface, kind: kind, onlyTrusted: true).map(\.id)
            sharing[key.surface] = ids
            if ids.count > 1, ids.contains(e) { names[key] = NameLink(entity: nil, basis: .ambiguous, candidates: ids) }
        }
    }
}
