import Foundation
import GRDB

/// Learned facts in Vault search (memory processing §4, FR-F-05; owner side only): set on `SearchService.facts` while
/// *Use in search and answers* is on, nil otherwise. What's on is read in each search's own transaction, from the
/// shipped qualification records and the local off-switches for `engines` (each call group's current Facts engine),
/// so a use turned off stops at the next search.
public struct FactsSearchConfig: Sendable {
    public var registry: FactsRegistry
    public var qualification: FactsQualification
    /// Each call group's engine, as the Facts task would use it now (none: nothing of that group is on).
    public var engines: [String: FactsEngine]
    /// The profile's names (`Profile.factsAliases`): never matched as someone else.
    public var userAliases: [String]
    /// The cloud limit: the second index gets the rest of the query only when every match is sendable under it.
    public var cloudLimit: CloudLimit
    /// A measurement's uses (the fixture gates, tests); the app never sets it.
    var measuredUses: FactsUses?
    /// A measurement's extra links, by memory id (13d's answer gate injects a wrong one); the app never sets it. Part of
    /// the index's cache key.
    var measuredLinks: [String: [MemoryLink]] = [:]

    public init(registry: FactsRegistry = .bundled, qualification: FactsQualification = .bundled,
                engines: [String: FactsEngine], userAliases: [String], cloudLimit: CloudLimit) {
        self.registry = registry
        self.qualification = qualification
        self.engines = engines
        self.userAliases = userAliases
        self.cloudLimit = cloudLimit
    }

    /// The UI-review build's: every declared use on, whatever is qualified.
    @_spi(FactsReview) public static func review(userAliases: [String] = []) -> FactsSearchConfig {
        var c = FactsSearchConfig(engines: [:], userAliases: userAliases, cloudLimit: .upTo(.internal))
        c.measuredUses = .everyDeclared(.bundled)
        return c
    }

    /// The UI-review build's picture of what ships in v0.10: people recorded and linked, a recorded-only predicate
    /// recorded, nothing else (no timeline).
    @_spi(FactsReview) public static func reviewShipped(userAliases: [String] = []) -> FactsSearchConfig {
        let reg = FactsRegistry.bundled
        var on = Set<FactsUses.Key>()
        for p in reg.predicates {
            if p.objectKind == FactsValidator.personKind {
                on.insert(.init(predicate: p.id, use: .recorded, basis: ""))
                on.insert(.init(predicate: p.id, use: .linked, basis: ""))
            } else if p.uses == [FactsUse.recorded.rawValue] {
                on.insert(.init(predicate: p.id, use: .recorded, basis: ""))
            }
        }
        var c = FactsSearchConfig(engines: [:], userAliases: userAliases, cloudLimit: .upTo(.internal))
        c.measuredUses = FactsUses(registry: reg, on: on)
        return c
    }

    /// What's on now, read in `db` (the off-switches are local rows).
    func uses(_ db: Database) throws -> FactsUses {
        if let measuredUses { return measuredUses }
        return try qualification.withOffSwitches(db).uses(engines: engines, registry: registry,
                                                          promptVersions: FactsQualification.promptVersions(registry))
    }

    /// What's on for an answer by `answerModel` (`ModelRouter.engine`), read in `db`: *attributes* and *bridges* only where a
    /// record covers that model at the current answer prompt version (13d).
    func answerUses(_ db: Database, answerModel: String) throws -> FactsUses {
        if let measuredUses { return measuredUses }
        return try qualification.withOffSwitches(db).uses(engines: engines, registry: registry,
                                                          promptVersions: FactsQualification.promptVersions(registry),
                                                          answer: .init(model: answerModel, promptVersion: SearchAnswerer.promptVersion))
    }
}

/// How a result came to be in a search with learned facts, recorded for 13d's privacy selection.
public struct SearchAdmission: Sendable, Hashable {
    public enum Way: String, Sendable { case link, timeline }

    public var way: Way
    /// The matched entity the link reaches (a timeline answer's entity), nil for an unresolved link's candidates.
    public var entity: String?
    /// As weak as its weakest step: the query's match and the memory's link.
    public var basis: LinkBasis
    /// The memory's link that admitted it (nil for a timeline answer's stating memory).
    public var link: MemoryLink?
    /// The why line, only for a result plain search wouldn't have kept ("results that would have matched anyway have
    /// no why line").
    public var whyLine: WhyLine?
}

/// A why line (04-ux-mac.md, Vault ▸ Why lines), as data: the Mac words it from its String Catalog, with the
/// registry's own phrases (`attribute`, `note_noun`) and the user's own label where they appear.
public struct WhyLine: Sendable, Hashable {
    public enum Form: Sendable, Hashable {
        /// The memory's role phrase and who it resolved to: "my sister → Maria (only sister Funes knows)".
        case role(surface: String, name: String)
        /// The memory names (or states a fact about) the entity the query's role phrase matched: "Maria, your sister".
        case name(name: String, attribute: String)
        /// The memory's role phrase fits several, one of them the one the query names: "your sister; Funes isn't sure
        /// which", without names.
        case candidates(attribute: String)
        /// A name two known people share, one of them the one the query names.
        case ambiguous(name: String)
        /// The role group the query's phrase matched: "your sisters".
        case group(attribute: String)
        /// A timeline answer's stating memory: "your job before Initech → Acme (from the dates)".
        case timeline(noun: String, op: String, anchor: String?, answer: String)
    }

    public enum Basis: Sendable, Hashable {
        case link(LinkBasis)
        case timeline(TimelineBasis)
    }

    /// **Not <name>**: this memory isn't about them.
    public struct NotName: Sendable, Hashable {
        public var memoryID: UUID
        public var entity: String
        public var name: String

        public init(memoryID: UUID, entity: String, name: String) {
            self.memoryID = memoryID
            self.entity = entity
            self.name = name
        }
    }

    public var form: Form
    public var basis: Basis
    /// The noun the basis words use ("only sister Funes knows"): the user's own label, else the role word.
    public var label: String
    /// From text the user didn't write: "(from text you didn't write)".
    public var untrusted: Bool
    public var notName: NotName?
    /// **Not this**: the fact behind the line (its row id), rejected for every memory.
    public var notThis: String?

    public init(form: Form, basis: Basis, label: String, untrusted: Bool, notName: NotName?, notThis: String?) {
        self.form = form
        self.basis = basis
        self.label = label
        self.untrusted = untrusted
        self.notName = notName
        self.notThis = notThis
    }
}

/// One memory's scores for a text (memory processing §4), kept or not.
struct Scored: Sendable {
    var score: Float
    var keyword: Float
    var semantic: Float
    var cosine: Float?
    var kept: Bool
}

enum SearchFacts {
    /// What a memory linked only to entities the query doesn't name loses (search.py's locked OTHERS).
    static let demotion: Float = 0.10

    /// Bases whose links admit (search.py: full and weak bases; an inferred link has no weight, and an unresolved one
    /// admits only for a candidate the query names).
    static let admitting: Set<LinkBasis> = [.confirmed, .named, .statedUnique, .context, .soleKnown, .untrusted, .group]

    /// Admission without a boost (memory processing §4): every pool memory scored by `plain` (its score for the query)
    /// and `rest` (for the rest of the query, nil when there's none). An admitted memory scores the better of the two;
    /// a kept one keeps its plain score, but for the −0.10 when it's linked only to entities the query doesn't name (or
    /// to a timeline's anchor) and something was admitted. Results come back in order, each with how it was admitted.
    static func rank(pool: [(id: UUID, updatedAt: Date)], plain: [UUID: Scored], rest: [UUID: Scored]?,
                     plan: FactsQueryPlan, index: FactsSearchIndex) -> [SearchHit] {
        let g = index.graph
        let matched = plan.matched
        // The query's strongest match per entity (a name beats a role phrase's weaker basis).
        var match: [String: FactsQueryPlan.Match] = [:]
        for m in plan.matches where matched.contains(m.entity) {
            if let old = match[m.entity], FactsSearchIndex.strength(old.basis) >= FactsSearchIndex.strength(m.basis) { continue }
            match[m.entity] = m
        }
        // A decided timeline answer admits its facts' stating memories; its anchor's memories drop.
        var stating = Set<String>()
        var tl: FactsQueryPlan.Timeline?
        if let t = plan.timeline, t.decided {
            tl = t
            let answer = t.answerGroup.isEmpty ? Set(t.answer) : t.answerGroup   // a stated rename's names too
            for f in g.facts where f.predicate == t.predicate && answer.contains(f.entity) && !f.negated {
                for a in f.assertions where a.states && !a.fromUser { stating.insert(a.memoryID) }
            }
        }

        var admitted: [UUID: SearchAdmission] = [:]
        for (id, _) in pool {
            let links = index.links[id.db] ?? []
            var best: (MemoryLink, String?, LinkBasis)?
            for l in links {
                var reach: String?
                // Both steps must carry weight: an inferred match of the query's role phrase admits nothing either.
                if let e = l.entity, matched.contains(e), admitting.contains(l.basis),
                   match[e].map({ admitting.contains($0.basis) || $0.basis == .candidates }) ?? true {
                    reach = e
                } else if l.entity == nil, [.candidates, .ambiguous].contains(l.basis),
                          let c = l.candidates.first(where: { c in
                              matched.contains(c) && (match[c].map { admitting.contains($0.basis) || $0.basis == .candidates } ?? true)
                          }) {
                    reach = c
                } else {
                    continue
                }
                let m = match[reach!]
                let basis = weaker(l.entity == nil ? l.basis : l.basis, m?.basis ?? .named)
                if let b = best, preference(l, m) <= preference(b.0, match[b.1 ?? ""]) { continue }
                best = (l, reach, basis)
            }
            if let (l, e, basis) = best {
                admitted[id] = SearchAdmission(way: .link, entity: e, basis: basis, link: l, whyLine: nil)
            } else if stating.contains(id.db), let t = tl {
                admitted[id] = SearchAdmission(way: .timeline, entity: t.answer.first, basis: .named, link: nil, whyLine: nil)
            }
        }

        let anchor = tl?.anchor
        var hits: [(SearchHit, Date)] = []
        // The facts-free order, for answers until 13d (`SearchHit.plainRank`).
        let plainOrder = pool.filter { plain[$0.id]?.kept == true }.sorted { a, b in
            let sa = plain[a.id]!.score, sb = plain[b.id]!.score
            if sa != sb { return sa > sb }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.id.db < b.id.db
        }
        let plainRank = Dictionary(uniqueKeysWithValues: plainOrder.enumerated().map { ($1.id, $0) })
        for (id, updatedAt) in pool {
            guard let p = plain[id] else { continue }
            if var adm = admitted[id] {
                // search.py: its score for the query counts only if plain search kept it; else the rest's (or 0).
                let score = max(p.kept ? p.score : 0, rest?[id]?.score ?? 0)
                if !p.kept { adm.whyLine = whyLine(adm, memory: id, match: adm.entity.flatMap { match[$0] }, timeline: tl, index: index) }
                var hit = SearchHit(memoryID: id, score: score, keyword: p.keyword, semantic: p.semantic, cosine: p.cosine)
                hit.admission = adm
                hit.plainRank = plainRank[id]
                hits.append((hit, updatedAt))
                continue
            }
            guard p.kept else { continue }
            var demoted = false
            if !admitted.isEmpty {
                for l in index.links[id.db] ?? [] {
                    guard let e = l.entity else { continue }
                    if e == anchor || tl?.anchorGroup.contains(e) == true, admitting.contains(l.basis) { demoted = true; break }
                    // The answer's other names aren't another entity (a stated rename, 13e.1).
                    if tl?.answerGroup.contains(e) == true { continue }
                    if !matched.contains(e), g.entities[e]?.name != nil, FactsSearchIndex.fullBases.contains(l.basis) {
                        demoted = true
                        break
                    }
                }
            }
            var hit = SearchHit(memoryID: id, score: p.score - (demoted ? demotion : 0), keyword: p.keyword,
                                semantic: p.semantic, cosine: p.cosine)
            hit.demoted = demoted
            hit.plainRank = plainRank[id]
            hits.append((hit, updatedAt))
        }
        hits.sort { a, b in
            if a.0.score != b.0.score { return a.0.score > b.0.score }
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.memoryID.db < b.0.memoryID.db
        }
        return hits.map(\.0)
    }

    /// The weaker of two bases.
    static func weaker(_ a: LinkBasis, _ b: LinkBasis) -> LinkBasis {
        FactsSearchIndex.strength(a) <= FactsSearchIndex.strength(b) ? a : b
    }

    /// Which link explains a result best: one that says something the query didn't (a role phrase for a name the query
    /// typed, a name for a role the query used), then the stronger.
    static func preference(_ l: MemoryLink, _ m: FactsQueryPlan.Match?) -> Int {
        let other: Int
        switch (m?.via ?? .name, l.kind) {
        case (.name, .role), (.role, .name): other = 30
        case (_, .fact): other = 20
        default: other = 10
        }
        return other + FactsSearchIndex.strength(l.basis)
    }

    /// A predicate's attribute phrase from the registry ("your {label}"), with the label.
    static func attribute(_ predicate: String?, label: String, registry: FactsRegistry) -> String? {
        guard let p = predicate.flatMap(registry.predicate), let phrase = p.phrases["attribute"] else { return nil }
        return phrase.replacingOccurrences(of: "{label}", with: label)
    }

    /// The why line for an admitted result.
    static func whyLine(_ a: SearchAdmission, memory: UUID, match: FactsQueryPlan.Match?, timeline: FactsQueryPlan.Timeline?,
                        index: FactsSearchIndex) -> WhyLine? {
        let g = index.graph, reg = g.registry
        func name(_ e: String?) -> String? { e.flatMap { g.entities[$0]?.name } }
        func fact(_ predicate: String?, _ e: String?) -> LearnedFact? {
            guard let e else { return nil }
            return g.facts.first { $0.entity == e && !$0.negated && index.linked.contains($0.predicate)
                && (predicate == nil || $0.predicate == predicate) }
        }
        func factID(_ f: LearnedFact?) -> String? { f.flatMap { index.factIDs[FactStore.Loaded.key($0.predicate, $0.entity)] } }
        if a.way == .timeline, let t = timeline, let answer = name(a.entity) {
            let phrases = reg.predicate(t.predicate)?.phrases ?? [:]
            let noun = phrases["note_noun"] ?? phrases["noteNoun"] ?? t.predicate
            return WhyLine(form: .timeline(noun: noun, op: t.opWords, anchor: name(t.anchor), answer: answer),
                           basis: .timeline(t.basis), label: noun, untrusted: false, notName: nil, notThis: nil)
        }
        guard let l = a.link else { return nil }
        let untrusted = a.basis == .untrusted || l.basis == .untrusted
        switch l.kind {
        case _ where l.entity == nil:
            let predicate = l.predicate ?? match?.predicate
            let word = l.word ?? match?.word ?? ""
            if l.basis == .ambiguous { return WhyLine(form: .ambiguous(name: l.surface), basis: .link(.ambiguous), label: word,
                                                      untrusted: untrusted, notName: nil, notThis: nil) }
            guard let attr = attribute(predicate, label: word, registry: reg) else { return nil }
            return WhyLine(form: .candidates(attribute: attr), basis: .link(.candidates), label: word, untrusted: untrusted,
                           notName: nil, notThis: nil)
        case .role:
            guard let e = l.entity else { return nil }
            if let ent = g.entities[e], ent.name == nil, let group = ent.group {
                let label = group.cls ?? l.word ?? ""
                guard let attr = attribute(group.predicate, label: label, registry: reg) else { return nil }
                return WhyLine(form: .group(attribute: attr), basis: .link(.group), label: label, untrusted: untrusted,
                               notName: nil, notThis: nil)
            }
            guard let n = name(e) else { return nil }
            let f = fact(l.predicate, e)
            let label = f?.label ?? f?.cls ?? l.word ?? ""
            return WhyLine(form: .role(surface: l.surface, name: n), basis: .link(a.basis), label: label, untrusted: untrusted,
                           notName: .init(memoryID: memory, entity: e, name: n), notThis: factID(f))
        case .name, .fact:
            guard let e = l.entity, let n = name(e) else { return nil }
            let f = fact(match?.via == .role ? match?.predicate : l.predicate, e)
            guard let f else { return nil }
            let label = f.label ?? f.cls ?? match?.word ?? ""
            guard let attr = attribute(f.predicate, label: label, registry: reg) else { return nil }
            return WhyLine(form: .name(name: n, attribute: attr), basis: .link(a.basis), label: label, untrusted: untrusted,
                           notName: .init(memoryID: memory, entity: e, name: n), notThis: factID(f))
        }
    }
}
