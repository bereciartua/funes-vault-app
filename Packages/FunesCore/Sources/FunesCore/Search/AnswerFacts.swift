import CryptoKit
import Foundation
import FunesProtocol
import GRDB

/// A timeline question Funes can't decide (memory processing §10.5): the card's note, worded by the app ("Funes can't
/// tell which job came before Acme").
public struct TimelineNote: Sendable, Hashable {
    /// The predicate's note noun ("job").
    public var noun: String
    /// The operator as the search wrote it ("before").
    public var op: String
    /// The anchor's name, nil for a date anchor or none.
    public var anchor: String?

    public init(noun: String, op: String, anchor: String?) {
        self.noun = noun
        self.op = op
        self.anchor = anchor
    }
}

/// What an inferred claim rests on (memory processing §10.4): the facts and links behind it, the weakest basis, what it
/// rests on that its quote doesn't say (`why`, as data the app words), and its corrections.
public struct ClaimInference: Sendable, Hashable {
    /// `LinkBasis` or `TimelineBasis` raw value: the weakest along the chain.
    public var basis: String
    /// Fact row ids (a bridge's or a timeline answer's facts included).
    public var factIDs: [String]
    public var why: WhyLine?
    public var corrections: [FactsCorrection]

    public init(basis: String, factIDs: [String], why: WhyLine?, corrections: [FactsCorrection]) {
        self.basis = basis
        self.factIDs = factIDs
        self.why = why
        self.corrections = corrections
    }
}

/// One correction an inferred claim (or a why line on the phone) offers: the protocol's target, with the token minted,
/// and what the app needs to word its button ("Not Maria", "Not this") and Not this's question ("Maria isn't your
/// sister?").
public struct FactsCorrection: Sendable, Hashable {
    public var target: FactsCorrectionTarget
    /// The entity's name, for **Not <name>** and the question.
    public var name: String?
    /// The fact's attribute phrase ("your sister"), for Not this's question.
    public var attribute: String?

    public init(target: FactsCorrectionTarget, name: String?, attribute: String?) {
        self.target = target
        self.name = name
        self.attribute = attribute
    }
}

/// An answer's learned facts (memory processing §10.3, §11.9), all from the **view**: the graph the answer model may
/// see (the sendable graph under the router's cloud limit for a cloud model, the whole graph on this Mac).
struct AnswerFactsPlan: Sendable {
    /// What a memory's attribute says (`about="…"` on its `<memory>`), and what it rests on.
    struct Attribute: Sendable, Hashable {
        var text: String
        /// Who it names; nil for `candidates` (which names nobody).
        var entity: String?
        var candidates: [String]
        var predicate: String
        var factID: String?
        var basis: LinkBasis
        /// The highest sensitivity behind it: its memory, and every memory stating its fact. Sent as a typed item.
        var sensitivity: Sensitivity
        /// The memories behind it, checked again at the send boundary.
        var behind: Set<String> = []
    }

    /// A memory that states a decided timeline answer's fact, read on top of the results (`m11`, `m12`).
    struct Bridge: Sendable, Hashable {
        var memoryID: UUID
        var entity: String
        var factIDs: [String]
        var basis: TimelineBasis
    }

    /// The results to read, in the view's order.
    var read: [UUID]
    /// A cloud call's: the full graph's first results that aren't read. Counted on the card, never sent.
    var unreadLinked: [UUID]
    /// How the view admitted each read memory.
    var admissions: [UUID: SearchAdmission]
    var attributes: [UUID: Attribute]
    var bridges: [Bridge]
    var note: TimelineNote?
    /// The facts revision the plan was made at (`SearchService.factsRevision`'s form).
    var revision: String
    let view: FactsSearchIndex
    let plan: FactsQueryPlan

    var bridgeIDs: Set<UUID> { Set(bridges.map(\.memoryID)) }

    /// What the answer rests on, for the memories it sent, compared again after the call: an answer is dropped only if a
    /// learned fact behind it changed, never because the vault's ranking moved (a capture during the call).
    func fingerprint(_ sent: Set<UUID>) -> String {
        let p = restricted(to: sent)
        return p.dependencies(sent)
    }

    private func dependencies(_ sent: Set<UUID>) -> String {
        var parts: [String] = []
        parts.append(attributes.sorted { $0.key.uuidString < $1.key.uuidString }.map { "\($0.key):\($0.value.text):\($0.value.factID ?? "")" }
            .joined(separator: ";"))
        parts.append(note.map { "\($0.noun)|\($0.op)|\($0.anchor ?? "")" } ?? "")
        // Every inference dependency the marker reads: each read or bridged memory's links (with candidates, predicate and
        // span), how each was admitted, the query's matches, the timeline's answer and basis, and the bridges' facts.
        let linkLines = sent.sorted { $0.uuidString < $1.uuidString }.flatMap { id in (view.links[id.db] ?? []).map {
            "\(id):\($0.kind.rawValue):\($0.entity ?? "-"):\($0.candidates.joined(separator: "+")):\($0.basis.rawValue):\($0.predicate ?? ""):\($0.surface):\($0.start)"
        } }
        parts.append(linkLines.sorted().joined(separator: ";"))
        parts.append(admissions.map { "\($0.key):\($0.value.way.rawValue):\($0.value.entity ?? ""):\($0.value.basis.rawValue)" }.sorted().joined(separator: ";"))
        parts.append(plan.matches.map { "\($0.entity):\($0.via.rawValue):\($0.basis.rawValue):\($0.predicate ?? "")" }.sorted().joined(separator: ","))
        parts.append(plan.timeline.map { "\($0.predicate)|\($0.answer.joined(separator: "+"))|\($0.anchor ?? "")|\($0.basis.rawValue)" } ?? "")
        parts.append(bridges.map { "\($0.memoryID):\($0.factIDs.joined(separator: "+")):\($0.basis.rawValue)" }.joined(separator: ";"))
        let facts = Set(admissions.values.compactMap(\.entity) + attributes.values.compactMap(\.entity))
        parts.append(view.graph.facts.filter { facts.contains($0.entity) && !$0.negated }.map {
            "\($0.entity):\($0.predicate):\($0.label ?? ""):\($0.cls ?? "")"
        }.sorted().joined(separator: ";"))
        return parts.joined(separator: "\n")
    }

    /// The plan as the model got it: only the memories actually sent (the secret scanner and on-device trimming may
    /// have left some out), so nothing that wasn't in the input marks a claim.
    func restricted(to sent: Set<UUID>) -> AnswerFactsPlan {
        var p = self
        p.read = read.filter(sent.contains)
        p.admissions = admissions.filter { sent.contains($0.key) }
        p.attributes = attributes.filter { sent.contains($0.key) }
        p.bridges = bridges.filter { sent.contains($0.memoryID) }
        return p
    }
}

// MARK: - Attributes (memory processing §10.3)

enum AnswerAttributes {
    /// The full bases: an attribute names who the link resolved to.
    static let full: Set<LinkBasis> = [.confirmed, .named, .statedUnique, .context]

    /// Funes's own words around the registry's phrase ("your sister"), part of `SearchAnswerer.promptVersion`.
    static let fullTemplate = "%@, %@"
    static let soleKnownTemplate = "probably %@, %@ (the only one Funes knows)"
    static let candidatesTemplate = "%@; Funes isn't sure which"
    static var templates: [String] { [fullTemplate, soleKnownTemplate, candidatesTemplate] }

    static func fill(_ template: String, _ args: String...) -> String {
        var out = template
        for a in args { if let r = out.range(of: "%@") { out.replaceSubrange(r, with: a) } }
        return out
    }

    /// A read memory's attribute, or nil: a link the view admitted it by, of a predicate whose *attributes* use is on
    /// (its `sole_known` record for that basis), never an untrusted or inferred one. The words are Funes's own
    /// templates around the registry's attribute phrase, versioned by `SearchAnswerer.promptVersion`.
    static func attribute(_ adm: SearchAdmission, memory: UUID, plan: FactsQueryPlan, index: FactsSearchIndex, uses: FactsUses,
                          levels: [String: Sensitivity]) -> AnswerFactsPlan.Attribute? {
        func sensitivity(_ ids: Set<String>) -> Sensitivity { ids.map { levels[$0] ?? .secret }.max() ?? .secret }
        guard adm.way == .link, let link = adm.link else { return nil }
        let g = index.graph, reg = g.registry
        let match = adm.entity.flatMap { e in plan.matches.first { $0.entity == e } }
        let basis = adm.basis
        if link.entity == nil {
            // An unresolved phrase: "your sister; Funes isn't sure which", without names.
            guard basis == .candidates, let predicate = link.predicate ?? match?.predicate, uses.isOn(predicate, .attributes),
                  let phrase = SearchFacts.attribute(predicate, label: link.word ?? match?.word ?? "", registry: reg) else { return nil }
            return .init(text: fill(candidatesTemplate, phrase), entity: nil, candidates: link.candidates, predicate: predicate,
                         factID: nil, basis: basis, sensitivity: sensitivity([memory.db]), behind: [memory.db])
        }
        guard let e = link.entity, let name = g.entities[e]?.name else { return nil }
        let wanted = link.kind == .role ? link.predicate : (match?.via == .role ? match?.predicate : link.predicate)
        // Only a fact the user's own text (or the user) states: an attribute is Funes's word, outside the quotable text, so
        // it never carries what only an agent's note or an import says. Several: registry order, deterministically.
        let order = Dictionary(uniqueKeysWithValues: reg.predicates.enumerated().map { ($1.id, $0) })
        guard let fact = g.facts.filter({ $0.entity == e && !$0.negated && uses.isOn($0.predicate, .attributes)
                && (wanted == nil || $0.predicate == wanted) && ($0.trusted || $0.assertions.contains(where: \.fromUser)) })
            .min(by: { (order[$0.predicate] ?? .max, $0.label ?? "") < (order[$1.predicate] ?? .max, $1.label ?? "") }) else { return nil }
        let soleKnown = basis == .soleKnown && uses.isOn(fact.predicate, .attributes, basis: LinkBasis.soleKnown.rawValue)
        guard full.contains(basis) || soleKnown else { return nil }
        let label = fact.label ?? fact.cls ?? link.word ?? match?.word ?? ""
        guard let phrase = SearchFacts.attribute(fact.predicate, label: label, registry: reg) else { return nil }
        let text = fill(soleKnown ? soleKnownTemplate : fullTemplate, name, phrase)
        let behind = Set(fact.assertions.filter { !$0.fromUser }.map(\.memoryID)).union([memory.db])
        return .init(text: text, entity: e, candidates: [], predicate: fact.predicate,
                     factID: index.factIDs[FactStore.Loaded.key(fact.predicate, e)], basis: basis, sensitivity: sensitivity(behind),
                     behind: behind)
    }
}

// MARK: - Inferred, by code (memory processing §10.4)

/// Marks a validated claim inferred when it rests on something Funes inferred that its quote doesn't say. Each citation
/// is judged alone: a second citation naming the person never clears another. Text tests fold case and accents and
/// match whole words. A rule fires only when the view has a link, fact or timeline answer behind it, so with facts off,
/// or a plain memory nothing links, nothing is marked. The model's wording never decides it.
enum AnswerMarker {
    struct Cited: Sendable {
        var memoryID: UUID
        /// The quote as sent (your names as "the user").
        var quote: String
    }

    /// One thing a claim rests on.
    struct Reason: Hashable {
        var memory: UUID?
        var entity: String?
        var candidates: [String] = []
        var linkBasis: LinkBasis?
        var predicate: String?
        var timeline: TimelineBasis?
        var factIDs: [String] = []
    }

    static func mark(_ text: String, citations: [Cited], plan p: AnswerFactsPlan, userAliases: [String]) -> ClaimInference? {
        let index = p.view, g = index.graph, reg = g.registry
        let claim = FactsText.fold(text)
        let users = Set(userAliases.map { FactsText.fold($0) })
        // Every name and alias, and each one's first word ("Priya" for "Priya Raman"), as a search may type them.
        func names(_ e: String) -> [String] {
            guard let ent = g.entities[e] else { return [] }
            let forms = Set(ent.nameForms.union(ent.name.map { [$0] } ?? []).map { FactsText.fold($0) })
            return forms.filter { $0.count >= 2 && !users.contains($0) }.sorted { $0.count > $1.count }
        }
        func facts(_ e: String) -> [LearnedFact] { g.facts.filter { $0.entity == e && !$0.negated && index.linked.contains($0.predicate) } }
        func factID(_ f: LearnedFact) -> String? { index.factIDs[FactStore.Loaded.key(f.predicate, f.entity)] }
        func predicateWords(_ predicate: String?) -> [String] {
            guard let predicate, let pr = reg.predicate(predicate) else { return [] }
            return pr.lexicon.flatMap(\.words)
        }
        func factWords(_ f: LearnedFact) -> [String] { predicateWords(f.predicate) + [f.label, f.cls].compactMap { $0 } }
        // The words of the lexicon entry a role word belongs to ("sister": sister, hermana): the same role in other words.
        func entryWords(_ predicate: String?, _ word: String?) -> [String] {
            guard let word else { return [] }
            let w = FactsText.fold(word)
            let entry = predicate.flatMap(reg.predicate)?.lexicon.first { $0.words.contains { FactsText.fold($0) == w } }
            return entry?.words ?? [word]
        }
        // What the search said for each entity it matched: the words it typed, or for a role phrase its predicate's words.
        var surfaces: [String: [String]] = [:]
        var byName = Set<String>()
        // A name the search typed is said by the entity's names; a role phrase only by its own lexicon entry's words and
        // the fact's label (a quote naming Maria doesn't say she's your sister; "mi hermana" says "my sister"). A claim
        // that words the role differently from its quote is rule 4's.
        for m in p.plan.matches {
            if m.via == .name {
                byName.insert(m.entity)
                surfaces[m.entity, default: []] += names(m.entity)
            } else {
                var words = entryWords(m.predicate, m.word)
                for f in facts(m.entity) where f.predicate == m.predicate { words += [f.label, f.cls].compactMap { $0 } }
                surfaces[m.entity, default: []] += words
            }
        }
        let matched = Set(p.plan.matches.map(\.entity))
        // A relation the quotes themselves state ("My partner is Jordan"): a quote naming them and a word of a fact they
        // hold. Then a quote that only says "my partner" says who it is, and the claim rests on the quotes. A quote that
        // merely names them ("Jordan called") states nothing.
        let allQuotes = citations.map { FactsText.fold($0.quote) }
        func roleWords(_ e: String) -> [String] { facts(e).flatMap(factWords) }
        func stated(_ e: String) -> Bool {
            let ns = names(e), rs = roleWords(e)
            return allQuotes.contains { q in ns.contains { FactsText.has(q, $0) } && rs.contains { FactsText.has(q, $0) } }
        }
        // Entities the input says something about that its text may not: attributes, and link admissions.
        var inferredAbout: [String: [Reason]] = [:]
        for (mid, a) in p.attributes {
            for e in [a.entity].compactMap({ $0 }) + a.candidates {
                inferredAbout[e, default: []].append(Reason(memory: a.entity == nil ? nil : mid, entity: a.entity, candidates: a.candidates,
                                                            linkBasis: a.basis, predicate: a.predicate, factIDs: [a.factID].compactMap { $0 }))
            }
        }
        for (mid, adm) in p.admissions where adm.way == .link {
            guard let e = adm.entity else { continue }
            let f = facts(e).first { $0.predicate == adm.link?.predicate } ?? facts(e).first
            inferredAbout[e, default: []].append(Reason(memory: adm.link?.entity == nil ? nil : mid, entity: adm.link?.entity,
                                                        candidates: adm.link?.candidates ?? [], linkBasis: adm.basis,
                                                        predicate: f?.predicate, factIDs: [f.flatMap(factID)].compactMap { $0 }))
        }
        let attributed = Set(p.attributes.values.flatMap { [$0.entity].compactMap { $0 } + $0.candidates })

        // The claim names no known entity: its subject may be anyone the input connects it to.
        let namesNobody = !g.entities.keys.contains { e in names(e).contains { FactsText.has(claim, $0) } }
        var reasons: [Reason] = []
        for c in citations {
            let quote = FactsText.fold(c.quote)
            let links = index.links[c.memoryID.db] ?? []
            func linksTo(_ e: String) -> [MemoryLink] { links.filter { $0.entity == e || ($0.entity == nil && $0.candidates.contains(e)) } }
            func says(_ words: [String]) -> Bool { words.contains { FactsText.has(quote, $0) } }
            // This quote says who, or what they are to you, and another quote states the relation.
            func saysVia(_ e: String) -> Bool { stated(e) && (says(names(e)) || says(roleWords(e))) }
            func reason(_ e: String, _ l: MemoryLink?) -> Reason {
                let f = facts(e).first { l?.predicate == nil || $0.predicate == l?.predicate } ?? facts(e).first
                return Reason(memory: l?.entity == nil ? nil : c.memoryID, entity: l?.entity ?? e, candidates: l?.candidates ?? [],
                              linkBasis: l?.basis, predicate: f?.predicate, factIDs: [f.flatMap(factID)].compactMap { $0 })
            }
            // 5. A bridge, or a memory the timeline answer admitted.
            if p.bridgeIDs.contains(c.memoryID) || p.admissions[c.memoryID]?.way == .timeline, let t = p.plan.timeline {
                let ids = p.bridges.first { $0.memoryID == c.memoryID }?.factIDs
                    ?? g.facts.filter { $0.predicate == t.predicate && (t.answer.contains($0.entity) || $0.entity == t.anchor) }
                        .compactMap(factID)
                reasons.append(Reason(memory: nil, entity: t.answer.first, timeline: t.basis, factIDs: ids))
            }
            for e in matched {
                let ls = linksTo(e)
                if !ls.isEmpty {
                    // 1. The memory links to someone the search named, and the quote doesn't say what the search said. A
                    // full-basis name link, for a search that typed a name, is the memory naming them itself.
                    let selfNamed = byName.contains(e) && ls.contains { $0.kind == .name && $0.entity == e && AnswerAttributes.full.contains($0.basis) }
                    if !selfNamed, !says(surfaces[e] ?? []), !saysVia(e) {
                        let best = ls.max { FactsSearchIndex.strength($0.basis) < FactsSearchIndex.strength($1.basis) }
                        reasons.append(reason(e, best))
                    }
                } else if let about = inferredAbout[e], !says(surfaces[e] ?? []), !saysVia(e),
                          (surfaces[e] ?? []).contains(where: { FactsText.has(claim, $0) }) || namesNobody {
                    // 2. The input says something inferred about them elsewhere (an attribute, a link admission), this
                    // memory neither links to them nor says so, and the claim is about them: it names them or says what
                    // the search said ("Maria prefers tea", "Your sister prefers tea"), or names nobody at all ("She
                    // prefers tea").
                    reasons += about
                }
            }
            // 3. Names an entity this memory links to, or one an attribute names, that the quote doesn't, unless the memory
            // itself names them (a full-basis name link: its title or another sentence does).
            let around = Set(links.compactMap(\.entity)).union(links.flatMap(\.candidates)).union(attributed)
            let named = Set(links.filter { $0.kind == .name && AnswerAttributes.full.contains($0.basis) }.compactMap(\.entity))
            for e in around.sorted() where !named.contains(e) {
                let ns = names(e)
                if ns.contains(where: { FactsText.has(claim, $0) }), !ns.contains(where: { FactsText.has(quote, $0) }), !saysVia(e) {
                    reasons.append(reason(e, linksTo(e).first ?? nil))
                }
            }
            // 4. States a predicate word or label of a fact about them that the quote doesn't: each word on its own ("wife"
            // isn't said by "girlfriend", though both are the partner's).
            for e in around.sorted() {
                for f in facts(e) {
                    let words = factWords(f)
                    // A word the quotes' stated relation says ("partner" in "My partner is Jordan") is said.
                    let statedWords = stated(e) ? words.filter { w in allQuotes.contains { FactsText.has($0, w) } } : []
                    if words.contains(where: { FactsText.has(claim, $0) && !FactsText.has(quote, $0) && !statedWords.contains($0) }) {
                        var r = reason(e, linksTo(e).first(where: { $0.predicate == nil || $0.predicate == f.predicate }) ?? linksTo(e).first)
                        r.predicate = f.predicate
                        r.factIDs = [factID(f)].compactMap { $0 }
                        reasons.append(r)
                    }
                }
            }
        }
        guard !reasons.isEmpty else { return nil }
        var unique: [Reason] = []
        for r in reasons where !unique.contains(r) { unique.append(r) }
        return inference(unique, plan: p)
    }

    /// The marked claim's data: ids, the weakest basis, the first reason as a why line, and one correction per link and
    /// fact (tokens are minted afterwards, in one read).
    static func inference(_ reasons: [Reason], plan p: AnswerFactsPlan) -> ClaimInference {
        let g = p.view.graph, reg = g.registry
        var factIDs: [String] = []
        for id in reasons.flatMap(\.factIDs) where !factIDs.contains(id) { factIDs.append(id) }
        let linkBases = reasons.compactMap(\.linkBasis)
        let basis: String = linkBases.min { FactsSearchIndex.strength($0) < FactsSearchIndex.strength($1) }?.rawValue
            ?? reasons.compactMap(\.timeline).first?.rawValue ?? LinkBasis.inferred.rawValue
        func attribute(_ r: Reason) -> String? {
            guard let predicate = r.predicate else { return nil }
            let f = r.entity.flatMap { e in g.facts.first { $0.entity == e && $0.predicate == predicate } }
            return SearchFacts.attribute(predicate, label: f?.label ?? f?.cls ?? reg.predicate(predicate)?.phrases["note_noun"] ?? "",
                                         registry: reg)
        }
        var corrections: [FactsCorrection] = []
        func add(_ c: FactsCorrection) {
            if !corrections.contains(where: { $0.target == c.target }) { corrections.append(c) }
        }
        for r in reasons {
            if let m = r.memory, let e = r.entity, let name = g.entities[e]?.name {
                add(FactsCorrection(target: FactsCorrectionTarget(what: .name, linkID: FactsCorrections.linkID(memory: m, entity: e),
                                                                  memoryID: m, token: ""),
                                    name: name, attribute: attribute(r)))
            }
        }
        for r in reasons {
            for id in r.factIDs {
                add(FactsCorrection(target: FactsCorrectionTarget(what: .fact, factID: id, token: ""),
                                    name: r.entity.flatMap { g.entities[$0]?.name }, attribute: attribute(r)))
            }
        }
        return ClaimInference(basis: basis, factIDs: factIDs, why: why(reasons.first!, plan: p, attribute: attribute(reasons.first!)),
                              corrections: corrections)
    }

    static func why(_ r: Reason, plan p: AnswerFactsPlan, attribute: String?) -> WhyLine? {
        let g = p.view.graph
        if let t = r.timeline, let pt = p.plan.timeline {
            let phrases = g.registry.predicate(pt.predicate)?.phrases ?? [:]
            let noun = phrases["note_noun"] ?? pt.predicate
            guard let answer = pt.answer.first.flatMap({ g.entities[$0]?.name }) else { return nil }
            return WhyLine(form: .timeline(noun: noun, op: pt.opWords, anchor: pt.anchor.flatMap { g.entities[$0]?.name }, answer: answer),
                           basis: .timeline(t), label: noun, untrusted: false, notName: nil, notThis: r.factIDs.first)
        }
        let label = r.entity.flatMap { e in g.facts.first { $0.entity == e && $0.predicate == r.predicate } }.flatMap { $0.label ?? $0.cls }
            ?? r.predicate.flatMap { g.registry.predicate($0)?.phrases["note_noun"] } ?? ""
        let basis = WhyLine.Basis.link(r.linkBasis ?? .inferred)
        if let e = r.entity, let name = g.entities[e]?.name {
            let notName = r.memory.map { WhyLine.NotName(memoryID: $0, entity: e, name: name) }
            if let attribute {
                return WhyLine(form: .name(name: name, attribute: attribute), basis: basis, label: label,
                               untrusted: r.linkBasis == .untrusted, notName: notName, notThis: r.factIDs.first)
            }
            return WhyLine(form: .ambiguous(name: name), basis: basis, label: label, untrusted: r.linkBasis == .untrusted,
                           notName: notName, notThis: r.factIDs.first)
        }
        guard let attribute else { return nil }
        return WhyLine(form: .candidates(attribute: attribute), basis: .link(.candidates), label: label, untrusted: false, notName: nil,
                       notThis: nil)
    }
}

// MARK: - Correction targets and tokens (companion protocol §4 facts.reject)

/// Correction targets' ids and tokens. A token is opaque to the phone: a digest of what the target rested on (the
/// memory's version, the entity's name, the fact's evidence), so a target that changed since is refused with
/// `target_changed`. It isn't a secret: the phone is the owner.
public enum FactsCorrections {
    /// **Not <name>**'s link id: the memory and the entity (each of the memory's mentions of them is rejected, keyed to
    /// its quoted span).
    public static func linkID(memory: UUID, entity: String) -> String { "\(memory.db)/\(entity)" }

    static func parseLink(_ id: String) -> (memory: UUID, entity: String)? {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let m = UUID(uuidString: parts[0]), !parts[1].isEmpty else { return nil }
        return (m, parts[1])
    }

    /// The target's token as of now, or nil when what it names is gone.
    static func token(_ db: Database, _ t: FactsCorrectionTarget) throws -> String? {
        var fields: [String] = [t.what.rawValue]
        switch t.what {
        case .name:
            guard let id = t.linkID, let (m, e) = parseLink(id),
                  let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ? AND status != 'deleted'", arguments: [m.db]),
                  let row = try Row.fetchOne(db, sql: "SELECT name FROM entity WHERE id = ?", arguments: [e]) else { return nil }
            fields += [id, String(version), (row["name"] as String?) ?? ""]
            // What the button stood on: the entity's names, and the user's decisions on this memory's mentions.
            fields += try String.fetchAll(db, sql: "SELECT COALESCE(alias, '') FROM entity_alias WHERE entity_id = ? ORDER BY 1", arguments: [e])
            fields += try Row.fetchAll(db, sql: """
                SELECT COALESCE(quote, ''), outcome, COALESCE(entity_id, '') FROM mention_decision
                WHERE memory_id = ? AND source = 'user' AND invalidated_at IS NULL ORDER BY 1, 2, 3
                """, arguments: [m.db]).map { "\($0[0] as String)|\($0[1] as String)|\($0[2] as String)" }
        case .fact:
            guard let id = t.factID,
                  let row = try Row.fetchOne(db, sql: """
                    SELECT f.predicate, e.id AS entity, e.name FROM fact f JOIN entity e ON e.id = f.entity_id WHERE f.id = ?
                    """, arguments: [id]) else { return nil }
            fields += [id, row["predicate"], row["entity"], (row["name"] as String?) ?? ""]
            if let m = t.memoryID {
                guard let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ? AND status != 'deleted'",
                                                     arguments: [m.db]) else { return nil }
                fields += [m.db, String(version)]
            }
            for r in try Row.fetchAll(db, sql: """
                SELECT COALESCE(memory_id, ''), COALESCE(memory_version, 0), COALESCE(quote, ''), source, asserted FROM fact_evidence
                WHERE fact_id = ? AND target_kind = 'fact' ORDER BY 1, 2, 3, 4, 5
                """, arguments: [id]) {
                fields.append("\(r[0] as String)|\(r[1] as Int)|\(r[2] as String)|\(r[3] as String)|\(r[4] as String)")
            }
            // The user's own corrections of it (a label, a status), which change what "Not this" means.
            for r in try Row.fetchAll(db, sql: """
                SELECT field, COALESCE(value, ''), COALESCE(memory_id, '') FROM manual_override
                WHERE target_kind = 'fact' AND target_id = ? ORDER BY 1, 2, 3
                """, arguments: [id]) {
                fields.append("o:\(r[0] as String)|\(r[1] as String)|\(r[2] as String)")
            }
        case .order, .unknown:
            return nil
        }
        return digest(fields)
    }

    /// Length-prefixed fields, SHA-256, the first 16 bytes in base64url.
    static func digest(_ fields: [String]) -> String {
        var data = Data()
        for f in fields {
            let bytes = Data(f.utf8)
            data.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init))
            data.append(bytes)
        }
        return Base64URL.encode(Data(Array(SHA256.hash(data: data)).prefix(16)))
    }

    /// Mints each correction's token in one read; a target whose subject is gone is left out.
    static func minted(_ db: Database, _ corrections: [FactsCorrection]) throws -> [FactsCorrection] {
        try corrections.compactMap { c in
            guard let token = try token(db, c.target) else { return nil }
            var out = c
            out.target.token = token
            return out
        }
    }
}
