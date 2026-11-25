import Foundation
import FunesProtocol
import GRDB

/// One read of what People & history shows (`PeopleDirectory`, `PeopleEntityPage`): the graph for what's on, every
/// memory's links to every entity (not just those search may use), and what you changed.
struct PeopleRead {
    var graph: FactsGraph
    let loaded: FactStore.Loaded
    let uses: FactsUses
    /// Memory id → its links: names, role phrases of linked predicates, statements of recorded ones.
    let links: [String: [MemoryLink]]
    /// Entity → the memories linked to it (resolved links only).
    let mentions: [String: Set<String>]
    let columns: [String: Columns]
    let titles: [String: (title: String, updatedAt: Date)]
    /// Entity id → the one it was merged into (Merge With…).
    let merged: [String: String]
    /// Memories each alias was seen in, by entity and alias text.
    let aliasMemories: [String: [String: Set<String>]]
    /// Unsettled links you skipped (memory id + UTF-16 start).
    let skipped: Set<FactsGraph.DecisionKey>

    struct Columns {
        var hidden: Bool
        var manual: Bool
        var tombstone: Bool
        /// The column's name (a merged-away or nameless entity's, for Corrections).
        var name: String?
        /// Something of yours: an override on it, a user row on one of its facts, a decision you made about it.
        var yours: Bool
    }

    var registry: FactsRegistry { graph.registry }

    func canonical(_ id: String) -> String { FactStore.canonical(id, merged) }

    static func read(_ db: Database, config: FactsSearchConfig, phrases: RolePhraseCache? = nil) throws -> PeopleRead {
        let uses = try config.uses(db)
        let loaded = try FactStore.load(db, registry: config.registry, userAliases: config.userAliases, uses: uses)
        var g = loaded.graph
        g.episodeMemo = EpisodeMemo()
        let linked = Set(uses.predicates(.linked))
        let recorded = Set(uses.predicates(.recorded))
        let phrasePredicates = linked.intersection(recorded)
        let merged = try FactStore.mergedInto(db)
        func canonical(_ id: String) -> String { FactStore.canonical(id, merged) }

        // Your marks on entities: Hide (an override, so it follows merges and stays with tombstones), and whether
        // anything of yours is on them.
        var hidden: [String: Bool] = [:], yours = Set<String>()
        for r in try Row.fetchAll(db, sql: """
            SELECT target_kind, target_id, field, value FROM manual_override ORDER BY created_at, rowid
            """) {
            let kind: String = r["target_kind"], target: String = r["target_id"], field: String = r["field"]
            if kind == "entity" {
                if field == "hidden" { hidden[canonical(target)] = (r["value"] as String?) == "true" }
                else { yours.insert(canonical(target)) }
            }
        }
        for r in try Row.fetchAll(db, sql: """
            SELECT f.entity_id FROM fact f WHERE f.manual = 1
              OR EXISTS (SELECT 1 FROM fact_evidence ev WHERE ev.fact_id = f.id AND ev.source = 'user')
              OR EXISTS (SELECT 1 FROM manual_override o WHERE o.target_kind IN ('fact','qualifier','date','status','order') AND o.target_id = f.id)
            UNION SELECT entity_id FROM mention_decision WHERE source = 'user' AND entity_id IS NOT NULL
            """) { yours.insert(canonical(r["entity_id"])) }
        var columns: [String: Columns] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT id, name, manual, tombstone FROM entity WHERE is_you = 0") {
            let id: String = r["id"]
            columns[id] = Columns(hidden: hidden[canonical(id)] ?? false, manual: (r["manual"] as Int) == 1,
                                  tombstone: (r["tombstone"] as Int) == 1, name: r["name"],
                                  yours: yours.contains(id) || (r["manual"] as Int) == 1)
        }

        // Memories as learned facts see them (as `FactsSearchIndex.build`): counted ones, and the others the Facts task
        // has dealt with at their current version, whose role phrases resolve through known facts.
        var memories = g.memories
        var titles: [String: (String, Date)] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT m.id, m.title, m.body, m.created_at, m.updated_at, COALESCE(m.original_source, m.source) AS source, m.trust,
              (EXISTS (SELECT 1 FROM facts_asked a WHERE a.memory_id = m.id AND a.memory_version = m.version)
                OR EXISTS (SELECT 1 FROM processing_job j WHERE j.kind = 'facts' AND j.subject = m.id
                             AND j.memory_version = m.version AND j.state IN ('done','failed'))) AS dealt
            FROM memory m WHERE m.status IN ('active','archived')
            """) {
            let id: String = r["id"]
            titles[id] = (r["title"], r["updated_at"])
            guard memories[id] == nil, (r["dealt"] as Bool) else { continue }
            let created: Date = r["created_at"]
            memories[id] = FactsMemory(id: id, text: FactStore.text(title: r["title"], body: r["body"]),
                                       written: FactStore.writtenDay(created), source: FactStore.source(r["source"]),
                                       trusted: (r["trust"] as String) == "trusted")
        }

        // Names of entities that aren't people (the graph's name links are people's): their alias evidence at the
        // memory's current version, merges followed, Not <name> applied. And each alias's memories, for the page.
        let counted = try FactStore.countedMemories(db)
        var otherNames: [String: [(surface: String, entity: String, start: Int)]] = [:]
        var aliasMemories: [String: [String: Set<String>]] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT ev.memory_id, ev.memory_version, ev.span_start, ev.span_end, a.entity_id, a.alias, e.kind
            FROM alias_evidence ev JOIN entity_alias a ON a.id = ev.alias_id JOIN entity e ON e.id = a.entity_id
            WHERE e.is_you = 0 ORDER BY ev.rowid
            """) {
            guard let c = counted[r["memory_id"]], c.version == (r["memory_version"] as Int) else { continue }
            let entity = canonical(r["entity_id"])
            guard g.entities[entity] != nil else { continue }
            let text = c.memory.text
            let a = FactStore.utf16Offset(text, scalar: r["span_start"]), b = FactStore.utf16Offset(text, scalar: r["span_end"])
            guard b > a else { continue }
            if g.rejections.contains(where: { $0.key.memoryID == c.memory.id && $0.key.start == a && $0.value.contains(entity) }) { continue }
            if let alias: String = r["alias"] { aliasMemories[entity, default: [:]][alias, default: []].insert(c.memory.id) }
            if (r["kind"] as String) != FactsValidator.personKind {
                otherNames[c.memory.id, default: []].append((FactsText.substring(text, a, b), entity, a))
            }
        }

        var namesBy: [String: [(FactsGraph.NameKey, NameLink)]] = [:]
        for (k, l) in g.names { namesBy[k.memoryID, default: []].append((k, l)) }
        var statementsBy: [String: [(LearnedFact, FactAssertion)]] = [:]
        for f in g.facts where !f.negated && recorded.contains(f.predicate) {
            for a in f.assertions where !a.fromUser { statementsBy[a.memoryID, default: []].append((f, a)) }
        }

        var out: [String: [MemoryLink]] = [:]
        var mentions: [String: Set<String>] = [:]
        for (mid, mem) in memories.sorted(by: { $0.key < $1.key }) {
            var ls: [MemoryLink] = []
            let text = mem.text
            for (key, link) in (namesBy[mid] ?? []).sorted(by: { $0.0.surface < $1.0.surface }) {
                let start = FactsText.wholeWordStarts(key.surface, in: text).first ?? 0
                if let e = link.entity {
                    ls.append(MemoryLink(kind: .name, entity: e, candidates: [], basis: link.basis, surface: key.surface,
                                         start: start, predicate: nil, word: nil))
                } else if link.basis == .ambiguous, !link.candidates.isEmpty {
                    ls.append(MemoryLink(kind: .name, entity: nil, candidates: link.candidates, basis: .ambiguous,
                                         surface: key.surface, start: start, predicate: nil, word: nil))
                }
            }
            for n in otherNames[mid] ?? [] where !ls.contains(where: { $0.entity == n.entity && $0.kind == .name }) {
                ls.append(MemoryLink(kind: .name, entity: n.entity, candidates: [], basis: mem.trusted ? .named : .untrusted,
                                     surface: n.surface, start: n.start, predicate: nil, word: nil))
            }
            if !phrasePredicates.isEmpty {
                let found = phrases?.phrases(text, graph: g, predicates: phrasePredicates) ?? g.rolePhrases(text, predicates: phrasePredicates)
                for ph in found {
                    let r = g.resolution(mem, ph)
                    if let entity = r.entity {
                        ls.append(MemoryLink(kind: .role, entity: entity, candidates: [], basis: r.basis, surface: ph.surface,
                                             start: ph.start, predicate: ph.predicate, word: ph.word))
                    } else if r.basis == .candidates, !r.candidates.isEmpty {
                        ls.append(MemoryLink(kind: .role, entity: nil, candidates: r.candidates, basis: .candidates,
                                             surface: ph.surface, start: ph.start, predicate: ph.predicate, word: ph.word))
                    }
                }
            }
            for (f, a) in statementsBy[mid] ?? [] {
                let start = a.span?.location ?? FactStore.locate(a.quote, in: text, near: nil)?.start ?? 0
                ls.append(MemoryLink(kind: .fact, entity: f.entity, candidates: [], basis: a.trusted ? .named : .untrusted,
                                     surface: a.quote, start: start, predicate: f.predicate, word: nil))
            }
            if !ls.isEmpty { out[mid] = ls }
            for l in ls { if let e = l.entity { mentions[e, default: []].insert(mid) } }
        }

        var skipped = Set<FactsGraph.DecisionKey>()
        for d in try Row.fetchAll(db, sql: "SELECT memory_id, quote, span_start FROM mention_decision WHERE source = 'user' AND outcome = 'unknown'") {
            guard let mem = memories[d["memory_id"]], let span = FactStore.locate(d["quote"], in: mem.text, near: d["span_start"]) else { continue }
            skipped.insert(FactsGraph.DecisionKey(memoryID: d["memory_id"], start: span.start))
        }

        g.landed = [:]
        return PeopleRead(graph: g, loaded: loaded, uses: uses, links: out, mentions: mentions, columns: columns,
                          titles: titles.mapValues { (title: $0.0, updatedAt: $0.1) }, merged: merged,
                          aliasMemories: aliasMemories, skipped: skipped)
    }

    // MARK: Words from the registry

    /// "your sister", "where you worked", "your client": the registry's attribute with the fact's word.
    func attribute(_ predicate: String, label: String?) -> String {
        let p = registry.predicate(predicate)
        let word = label ?? p?.phrases["note_noun"] ?? predicate
        return (p?.phrases["attribute"] ?? "{label}").replacingOccurrences(of: "{label}", with: word)
    }

    /// The predicate's first plural lexicon word ("parents"), for a role group with no word of its own.
    func pluralWord(_ predicate: String) -> String? {
        registry.predicate(predicate)?.lexicon.first { $0.plural == true && $0.cls == nil }?.words.first
    }

    func noun(_ predicate: String) -> String { registry.predicate(predicate)?.phrases["note_noun"] ?? predicate }

    func declaresTimeline(_ predicate: String) -> Bool { registry.predicate(predicate)?.uses.contains("timeline") == true }

    func name(_ entity: String) -> String? { graph.entities[canonical(entity)]?.name ?? columns[entity]?.name }

    // MARK: Entries

    func facts(of entity: String) -> [LearnedFact] {
        graph.facts.filter { $0.entity == entity && !$0.negated }
    }

    func factID(_ f: LearnedFact) -> String? { loaded.factIDs[FactStore.Loaded.key(f.predicate, f.entity)] }

    /// A fact's status as shown: derived from its episodes while its timeline is on; otherwise only as stated (by a
    /// memory or by you, the latest), never from an end date or a successor.
    func status(_ f: LearnedFact) -> FactAssertion.Status {
        if uses.isOn(f.predicate, .timeline) { return graph.status(of: f) }
        // Trusted text and yours first: an agent's or an import's later word doesn't override them.
        let said = f.assertions.stableSorted { $0.readOrder }.filter { $0.status != .unknown }
        return (said.last { $0.trusted || $0.fromUser } ?? said.last)?.status ?? .current
    }

    /// The fact a list row shows: a linked one first, a current one first, in registry order.
    func leadingFact(_ entity: String) -> PeopleDirectory.FactLine? {
        let order = Dictionary(registry.predicates.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fs = facts(of: entity).sorted { a, b in
            let la = uses.isOn(a.predicate, .linked), lb = uses.isOn(b.predicate, .linked)
            if la != lb { return la }
            let ca = status(a) != .former, cb = status(b) != .former
            if ca != cb { return ca }
            return (order[a.predicate] ?? 0) < (order[b.predicate] ?? 0)
        }
        guard let f = fs.first else { return nil }
        var line = PeopleDirectory.FactLine(attribute: attribute(f.predicate, label: f.label ?? f.cls), status: status(f),
                                            since: nil, until: nil, recordedOnly: !uses.isOn(f.predicate, .linked))
        if declaresTimeline(f.predicate), uses.isOn(f.predicate, .timeline), let last = episodes(f).last {
            // An open end (memories disagree whether it ended; `maxDay`) is no "until".
            if last.ongoing { line.since = last.tstart } else if let end = last.end, end.hi < DateRange.maxDay { line.until = end }
        }
        return line
    }

    /// Listed: an entity with a name (or a role group), or something of yours. A nameless tombstone, or an entity whose
    /// memories are all gone, isn't.
    func entry(_ id: String) -> PeopleDirectory.Entry? {
        // Stored entities only: a group the resolver makes for a phrase nobody holds lives in this read alone.
        guard let e = graph.entities[id], columns[id] != nil else { return nil }
        let col = columns[id] ?? Columns(hidden: false, manual: false, tombstone: false, name: nil, yours: false)
        var group: PeopleDirectory.Entry.Group?
        if e.name == nil, let gr = e.group {
            group = .init(attribute: attribute(gr.predicate, label: gr.cls ?? pluralWord(gr.predicate)), count: e.count.flatMap { $0 > 1 ? $0 : nil })
        } else if e.name == nil, !col.yours {
            return nil          // nameless and nothing of yours: nothing to show or undo
        }
        let fs = facts(of: id)
        let mentioned = mentions[id]?.count ?? 0
        let yours = col.yours || fs.contains { f in f.assertions.contains(where: \.fromUser) }
        guard mentioned > 0 || !fs.isEmpty || yours || group != nil else { return nil }
        return PeopleDirectory.Entry(id: id, kind: e.kind, name: e.name, group: group, fact: leadingFact(id), mentions: mentioned,
                                     aliases: e.aliases.sorted(), hidden: col.hidden, manual: yours, deceased: e.deceased,
                                     tombstone: col.tombstone)
    }

    var entries: [PeopleDirectory.Entry] {
        graph.entities.keys.compactMap(entry).sorted { a, b in
            if a.mentions != b.mentions { return a.mentions > b.mentions }
            let na = a.name ?? a.group?.attribute ?? "", nb = b.name ?? b.group?.attribute ?? ""
            let c = na.localizedCaseInsensitiveCompare(nb)
            return c == .orderedSame ? a.id < b.id : c == .orderedAscending
        }
    }

    // MARK: Episodes

    /// A fact's episodes while its predicate's timeline is on (derived: succession, conflicts, orders).
    func episodes(_ f: LearnedFact) -> [Episode] {
        // A stated rename's episodes stand under one of its names (13e.1): each name's page shows them.
        let id = graph.timelineEntity(f.predicate, f.entity)
        return graph.episodes(f.predicate).filter { $0.entity == id }.stableSorted { $0.sortKey }
    }

    /// A fact's dated rows as the timeline shows them. Timeline on: every episode, derived. Off: only your own rows,
    /// projected as you entered them (the latest start, end and status per episode you acted on), never derived (no
    /// bound from "former", no succession, no order).
    func timelineEpisodes(_ f: LearnedFact, all: [Episode]? = nil) -> [PeopleDirectory.TimelineEpisode] {
        if uses.isOn(f.predicate, .timeline) {
            let all = all ?? graph.episodes(f.predicate)
            return episodes(f).enumerated().map { timelineEpisode($1, fact: f, index: $0, all: all) }
        }
        let p = graph.parser
        var bySelector: [String: (sel: DateRange?, start: String?, end: String?, status: FactAssertion.Status, order: String)] = [:]
        for a in f.assertions.filter(\.fromUser).stableSorted(by: { $0.readOrder }) {
            let k = a.selector.map { String($0.lo) + "-" + String($0.hi) } ?? "-"
            var v = bySelector[k] ?? (a.selector, nil, nil, .unknown, a.readOrder)
            if a.clearsDates { v.start = nil; v.end = nil }
            if let s = a.start { v.start = s }
            if let e = a.end { v.end = e }
            if a.status != .unknown {
                v.status = a.status
                if a.status == .current, a.end == nil { v.end = nil }      // marked current after an end: it holds again
            }
            bySelector[k] = v
        }
        return bySelector.values.sorted { $0.order < $1.order }.enumerated().compactMap { i, v in
            let start = p.parse(v.start), end = p.parse(v.end)
            guard start != nil || end != nil || v.status != .unknown else { return nil }
            return PeopleDirectory.TimelineEpisode(
                index: i, factID: factID(f) ?? "", entity: f.entity, name: name(f.entity) ?? "", start: start, end: end,
                ongoing: end == nil && v.status != .former, former: v.status == .former, inferredEnd: false,
                conflictStart: false, conflictEnd: false, untrusted: false, kind: nil, titles: [], stating: [], previous: nil,
                selector: v.sel, yourDates: start != nil || end != nil, yours: true, yourSelectors: [v.sel])
        }
    }

    func timelineEpisode(_ e: Episode, fact f: LearnedFact, index: Int, all: [Episode]) -> PeopleDirectory.TimelineEpisode {
        let p = graph.parser
        let slotKey = registry.predicate(f.predicate)?.slot
        // The free-text qualifiers (a title): not the slot, no fixed values, not your word for it.
        let free = Set((registry.predicate(f.predicate)?.qualifiers ?? [:]).filter { $0.key != slotKey && $0.key != "label" && $0.value.values == nil }.keys)
        var titles: [PeopleDirectory.TimelineEpisode.Title] = []
        for a in e.assertions.stableSorted(by: { $0.readOrder }) {
            for q in free.sorted() {
                guard let t = a.qualifiers[q], !titles.contains(where: { $0.title == t }) else { continue }
                titles.append(.init(title: t, from: p.parse(a.start) ?? p.parse(a.time)))
            }
        }
        let kind = slotKey.flatMap { k in e.assertions.compactMap { $0.qualifiers[k] }.last }
        let stating = e.assertions.filter { $0.states && !$0.fromUser }
            .stableSorted { $0.readOrder }.reversed().compactMap { UUID(uuidString: $0.memoryID) }
        var previous: PeopleDirectory.TimelineEpisode.Previous?
        // An undated episode can't be placed; a dated one is judged among the dated ones (an undated job would make
        // every order undecidable, and it says so itself).
        // (A hand-over's assumed start is for role resolution only: `tstart`, as the dates shown.)
        let undated = e.tstart == nil && e.end == nil
        let dated = all.filter { $0 === e || $0.tstart != nil || $0.end != nil }
        let (got, basis) = undated ? (nil, TimelineBasis.ambiguous) : graph.order(f.predicate, dated, e, .before)
        // `order` also says ambiguous when nothing came before: only an episode with an earlier one can't be placed.
        let earlier = dated.contains { o in o !== e && (o.tstart?.lo ?? o.end?.lo ?? .max) < (e.tstart?.lo ?? e.end?.lo ?? .min) }
        if basis == .ambiguous, undated || earlier {
            previous = .cantTell
        } else if basis == .gap, let got, let s = e.tstart,
                  let pe = all.filter({ $0.entity == got && $0 !== e && $0.end != nil }).max(by: { $0.end!.hi < $1.end!.hi })?.end,
                  pe.hi < DateRange.maxDay {      // an open end bounds no gap
            previous = .gap(months: max(1, Int((Double(s.lo - pe.hi) / 30.44).rounded())))
        }
        // Acting on it again targets your rows' own selector (so Clear Dates finds them and a new date supersedes
        // theirs), else the episode's dates as they are now.
        let yourRows = e.assertions.filter(\.fromUser)
        let selector: DateRange? = !yourRows.isEmpty ? yourRows.last?.selector
            : e.start == nil && e.end == nil ? nil
            : DateRange(lo: e.start?.lo ?? DateRange.minDay, hi: e.end?.hi ?? DateRange.maxDay)
        return PeopleDirectory.TimelineEpisode(
            // A stated rename shows under both names ("Lattice Harbor / Lattice Harbor Labs", 13e.1).
            index: index, factID: factID(f) ?? "", entity: f.entity,
            name: { let n = graph.timelineNames(f.predicate, f.entity).joined(separator: " / "); return n.isEmpty ? name(f.entity) ?? "" : n }(),
            start: e.tstart, end: e.end, ongoing: e.ongoing, former: e.former, inferredEnd: e.inferredEnd,
            conflictStart: e.conflictStart, conflictEnd: e.conflictEnd, untrusted: !e.trusted, kind: kind, titles: titles,
            stating: Array(stating), previous: previous, selector: selector,
            yourDates: e.assertions.contains { $0.fromUser && ($0.start != nil || $0.end != nil) },
            yours: !e.assertions.isEmpty && e.assertions.allSatisfy(\.fromUser),
            yourSelectors: Array(Set(yourRows.map(\.selector))))
    }

    var timeline: [PeopleDirectory.TimelineSection] {
        registry.predicates.filter { declaresTimeline($0.id) }.map { p in
            let on = uses.isOn(p.id, .timeline)
            let all = on ? graph.episodes(p.id) : []
            var eps: [PeopleDirectory.TimelineEpisode] = []
            // Hide is for the list only; a stated rename's rows once, under the name that stands for it.
            for f in graph.facts where f.predicate == p.id && !f.negated && (!on || graph.timelineEntity(p.id, f.entity) == f.entity) {
                eps += timelineEpisodes(f, all: all)
            }
            eps.sort { a, b in
                let ka = a.start?.lo ?? a.end?.lo ?? DateRange.maxDay, kb = b.start?.lo ?? b.end?.lo ?? DateRange.maxDay
                return ka != kb ? ka > kb : a.id < b.id
            }
            return PeopleDirectory.TimelineSection(predicate: p.id, noun: noun(p.id), on: on, episodes: eps)
        }
    }

    // MARK: To check

    var toCheck: [PeopleDirectory.ToCheckItem] {
        var items: [PeopleDirectory.ToCheckItem] = []
        let linked = Set(uses.predicates(.linked))
        // 1. Role phrases Funes couldn't settle (several hold the role), newest memory first. A name two people share
        //    isn't asked: it keeps `ambiguous`, and Not <name> corrects it.
        let ordered = links.keys.sorted { (titles[$0]?.updatedAt ?? .distantPast) > (titles[$1]?.updatedAt ?? .distantPast) }
        for mid in ordered {
            guard let uuid = UUID(uuidString: mid), let title = titles[mid]?.title else { continue }
            for l in links[mid] ?? [] where l.entity == nil && l.kind == .role && l.basis == .candidates {
                guard l.predicate.map(linked.contains) == true,
                      !skipped.contains(FactsGraph.DecisionKey(memoryID: mid, start: l.start)) else { continue }
                // The memory says who itself ("Maria is my sister"): it states that fact about a candidate.
                if (links[mid] ?? []).contains(where: { $0.kind == .fact && $0.predicate == l.predicate && $0.entity.map(l.candidates.contains) == true }) {
                    continue
                }
                let cands = l.candidates.compactMap { c in name(c).map { PeopleDirectory.UnsettledLink.Candidate(entity: c, name: $0) } }
                guard cands.count > 1 else { continue }
                items.append(.link(.init(memoryID: uuid, memoryTitle: title, surface: l.surface, start: l.start, role: true,
                                         candidates: cands)))
            }
        }
        // 2. Suggested merges: same kind, names that match loosely by the kind's rule, not one's alias, not Not the Same.
        var seen = Set<Set<String>>()
        let visible = Set(entries.filter { !$0.hidden && $0.name != nil }.map(\.id))
        for id in visible.sorted() {
            guard let e = graph.entities[id], let n = e.name else { continue }
            for o in graph.byName(n, kind: e.kind, onlyTrusted: false) where o.id != id && visible.contains(o.id) {
                let pair: Set<String> = [id, o.id]
                guard !seen.contains(pair), !graph.notSame.contains(pair) else { continue }
                let fa = Set(e.aliases.map { FactsText.normName($0, kind: e.kind, registry: registry) })
                let fb = Set(o.aliases.map { FactsText.normName($0, kind: e.kind, registry: registry) })
                guard fa.isDisjoint(with: fb) else { continue }
                seen.insert(pair)
                let (a, b) = (mentions[id]?.count ?? 0) >= (mentions[o.id]?.count ?? 0) ? (id, o.id) : (o.id, id)
                items.append(.merge(entity: a, other: b, names: [name(a) ?? "", name(b) ?? ""]))
            }
        }
        // 3. Your rows whose episode no longer matches exactly one: only for a recorded predicate; with its timeline
        //    off there's nothing derived to choose from, only Remove.
        for r in loaded.lost where uses.isOn(r.predicate, .recorded) {
            guard let key = loaded.factKeys[r.otherFactID ?? r.factID] else { continue }
            items.append(.episode(.init(rowID: r.rowID, factID: r.factID, otherEndpoint: r.otherFactID != nil,
                                        name: name(key.entity) ?? "", noun: noun(r.predicate),
                                        choices: uses.isOn(r.predicate, .timeline) ? r.choices : [])))
        }
        return items
    }

    // MARK: Summary

    var summary: PeopleDirectory.Summary {
        var s = PeopleDirectory.Summary()
        for e in entries where !e.hidden && e.name != nil {
            if e.kind == FactsValidator.personKind {
                s.people += 1
            } else if facts(of: e.id).contains(where: { declaresTimeline($0.predicate) && uses.isOn($0.predicate, .recorded) }) {
                s.employers += 1
            } else {
                s.others += 1
            }
        }
        return s
    }
}

extension VaultStore {
    /// People & history (04-ux-mac.md): the list, your timeline, To check and the summary, for what's on.
    public func peopleDirectory(config: FactsSearchConfig, phrases: RolePhraseCache? = nil) throws -> PeopleDirectory {
        try writer.read { db in
            let r = try PeopleRead.read(db, config: config, phrases: phrases)
            return PeopleDirectory(entries: r.entries, toCheck: r.toCheck, answered: try r.answered(db), timeline: r.timeline,
                                   summary: r.summary, kinds: config.registry.kinds.keys.sorted())
        }
    }

    /// An entity's page, or nil when it isn't listed any more (merged away, gone).
    public func peopleEntity(_ id: String, config: FactsSearchConfig, phrases: RolePhraseCache? = nil) throws -> PeopleEntityPage? {
        try writer.read { db in
            let r = try PeopleRead.read(db, config: config, phrases: phrases)
            return try r.page(db, id: r.canonical(id))
        }
    }

    // MARK: For a phone (companion protocol §4.3)

    /// The directory for a phone: what the Mac's section reads, and People's revision, in one read. Throws
    /// `PeopleError.closed` while People is closed (*Learn from memories* off and nothing of yours kept), checked in the
    /// same read.
    public func peoplePhoneDirectory(config: FactsSearchConfig, learning: Bool, phrases: RolePhraseCache? = nil) throws -> PeoplePhoneDirectory {
        try writer.read { db in
            guard try Self.peopleOpen(db, learning: learning) else { throw PeopleError.closed }
            let r = try PeopleRead.read(db, config: config, phrases: phrases)
            let d = PeopleDirectory(entries: r.entries, toCheck: r.toCheck, answered: [], timeline: r.timeline, summary: r.summary,
                                    kinds: config.registry.kinds.keys.sorted())
            return PeoplePhoneDirectory(directory: d, revision: try Self.peopleRevision(db, config: config, learning: learning))
        }
    }

    /// An entity's page for a phone: the page as the Mac reads it, with each memory row's **Not <name>** and each fact's
    /// **Not this** as correction targets, their tokens and People's revision from the same read, so a token stands for
    /// exactly what the page shows. Nil when the entity isn't listed any more; `PeopleError.closed` while People is closed.
    public func peoplePhonePage(_ id: String, config: FactsSearchConfig, learning: Bool, phrases: RolePhraseCache? = nil) throws -> PeoplePhonePage? {
        try writer.read { db -> PeoplePhonePage? in
            guard try Self.peopleOpen(db, learning: learning) else { throw PeopleError.closed }
            let r = try PeopleRead.read(db, config: config, phrases: phrases)
            guard let page = try r.page(db, id: r.canonical(id)) else { return nil }
            let name = page.entry.name ?? page.entry.group?.attribute
            var pending = page.memories.map { m in
                FactsCorrection(target: FactsCorrectionTarget(what: .name, linkID: FactsCorrections.linkID(memory: m.memoryID, entity: m.notName.entity),
                                                              memoryID: m.memoryID, token: ""), name: m.notName.name, attribute: nil)
            }
            pending += page.facts.filter { !$0.factID.isEmpty }.map { f in
                FactsCorrection(target: FactsCorrectionTarget(what: .fact, factID: f.factID, token: ""), name: name, attribute: f.attribute)
            }
            var out = PeoplePhonePage(page: page, revision: try Self.peopleRevision(db, config: config, learning: learning))
            for c in try FactsCorrections.minted(db, pending) {
                if c.target.what == .name, let m = c.target.memoryID { out.notName[m] = c }
                if c.target.what == .fact, let f = c.target.factID { out.notThis[f] = c }
            }
            return out
        }
    }

    /// Whether People & history is open for a phone: *Learn from memories* on, or anything of yours kept, read now.
    public func peopleOpen(learning: Bool) throws -> Bool {
        try writer.read { db in try Self.peopleOpen(db, learning: learning) }
    }

    /// People's revision (companion protocol §4.3), nil while People is closed.
    public func peopleRevision(config: FactsSearchConfig, learning: Bool) throws -> String? {
        try writer.read { db in
            try Self.peopleOpen(db, learning: learning) ? try Self.peopleRevision(db, config: config, learning: learning) : nil
        }
    }

    static func peopleOpen(_ db: Database, learning: Bool) throws -> Bool {
        try learning || userFactEntries(db)
    }

    /// Search's revision for `config`, plus what People reads that no learned-fact write counts: the vault part of the
    /// facts index key (memory versions, titles, what the Facts task has read, so a memory read with nothing found moves
    /// it) and *Learn from memories*. Search's own revision leaves these out, so a memory save never drops an answer.
    static func peopleRevision(_ db: Database, config: FactsSearchConfig, learning: Bool) throws -> String {
        let (revision, key) = try factsRevision(db, config: config)
        return revision + "." + FactsCorrections.digest([key.vault, learning ? "1" : "0"]).prefix(8)
    }

    /// The learned facts' revision as `config` reads them (companion protocol §4): `SearchService.factsRevision`'s while
    /// *Use in search and answers* is on.
    public func factsRevision(config: FactsSearchConfig) throws -> String {
        try writer.read { db in try Self.factsRevision(db, config: config).0 }
    }

    static func factsRevision(_ db: Database, config: FactsSearchConfig) throws -> (String, FactsIndexKey) {
        let uses = try config.uses(db)
        let key = try FactsIndexKey(db, config: config, uses: uses, sendable: nil)
        // Every answer-side use, a basis-scoped one included (the `sole_known` attributes record).
        let attributes = config.registry.predicates.map { p in
            p.id + ":" + [FactsUse.attributes, .bridges].filter { uses.isOn(p.id, $0) }.map(\.rawValue).joined(separator: ",")
                + (uses.isOn(p.id, .attributes, basis: LinkBasis.soleKnown.rawValue) ? ",sole_known" : "")
        }.joined(separator: ";")
        return (key.revision + "." + FactsCorrections.digest([key.uses, attributes, key.registry] + key.aliases).prefix(8), key)
    }

    /// Whether you've entered or corrected anything (People & history shows while this is true, even with Facts off).
    public func hasUserFactEntries() throws -> Bool {
        try writer.read { db in try Self.userFactEntries(db) }
    }

    static func userFactEntries(_ db: Database) throws -> Bool {
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM manual_override) OR EXISTS (SELECT 1 FROM fact_evidence WHERE source = 'user')
                  OR EXISTS (SELECT 1 FROM mention_decision WHERE source = 'user') OR EXISTS (SELECT 1 FROM fact WHERE manual = 1)
                  OR EXISTS (SELECT 1 FROM entity WHERE manual = 1 AND is_you = 0)
                """) ?? false
    }
}
