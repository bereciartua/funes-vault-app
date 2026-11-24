import Foundation
import FunesProtocol
import GRDB

extension SearchService {
    /// `status.get`'s factsRevision (companion protocol §4), and what a search's or an answer's results were made at:
    /// "<epoch>.<counter>.<uses>", where the last part is a digest of the uses on, so turning one off (an off-switch, a
    /// record lapsing) changes it too. Nil while learned facts aren't in use.
    public func factsRevision() async -> String? {
        guard let config = facts else { return nil }
        return try? store.factsRevision(config: config)
    }

    /// The graph an answer model may see (memory processing §11.9): the whole graph for a model on this Mac (Apple
    /// on-device, a local server), the sendable graph under the router's cloud limit for a cloud one.
    enum AnswerView: Sendable, Hashable {
        case full
        case sendable(CloudLimit)
    }

    /// An answer's learned facts (memory processing §10.3, §11.9; 13d), or nil when facts in answers is off for this
    /// call: learned facts aren't in use in search, no predicate is linked, no *attributes* record covers `answerModel`,
    /// the view's limit isn't the one search was configured with, or anything failed (the answer then reads 13b's plain
    /// selection, `answerSelection`, never the ids as given).
    ///
    /// What it reads: the view's own re-ranking of the search (admission, the −0.1 demotions, the rest-of-query score and
    /// the timeline's choice, all on the view's facts), its top `count`, each kept only if it's in the whole result list
    /// the user sees now (any position; no refill past the view's top). Admission is recomputed from the query; the
    /// phone's ids are never trusted alone.
    func answerPlan(_ query: String, filter: MemoryFilter, count: Int, view: AnswerView, answerModel: String, onDevice: Bool,
                    checked: Bool = true, now: Date) async -> AnswerFactsPlan? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let config = facts else { return nil }
        if case let .sendable(limit) = view, limit != config.cloudLimit { return nil }
        do {
            let state: (FactsUses, FactsUses)? = try await store.writer.read { db in
                let uses = try config.uses(db)
                let answerUses = try config.answerUses(db, answerModel: answerModel)
                // 13e.2: an answer reads learned facts with an *attributes* record for its model, or a *timeline* one that
                // gives it rows (a cloud engine, a screen that shows checked claims).
                let rowsAllowed = checked && !onDevice && view != .full && !answerUses.predicates(.timeline).isEmpty
                guard !uses.predicates(.linked).isEmpty, !answerUses.predicates(.attributes).isEmpty || rowsAllowed else { return nil }
                return (uses, answerUses)
            }
            guard let (_, answerUses) = state else { return nil }
            // The whole list as the user sees it now, ranked with every learned fact (what the search shows).
            let whole = try await vaultSearch(query, filter: filter, now: now)
            guard let (fullIndex, uses, key) = try await factsIndex(config), facts.map({ Self.same($0, config) }) == true else { return nil }
            let today = FactStore.writtenDay(now)

            let index: FactsSearchIndex, ranked: [SearchHit]
            switch view {
            case .full:
                index = fullIndex
                ranked = whole
            case let .sendable(limit):
                index = try await sendableIndex(config, uses: uses, key: key, limit: limit)
                let plan = index.plan(query, today: today)
                let pool = try await store.writer.read { db in
                    try MemoryStore.listed(db, filter: filter, now: now).map { (id: $0.id, updatedAt: $0.updatedAt) }
                }
                if plan.isEmpty {
                    ranked = try await rank(text: query, pool: pool, prefix: true, threshold: \.vaultThreshold, agentTask: false, limit: nil)
                } else {
                    // Every match of the sendable graph is sendable, so the rest of the query may go to the second index
                    // whenever it's complete (§4's rule, met by construction).
                    let second = secondIndex
                    let may = !plan.rest.isEmpty && second?.indexer.isComplete == true
                    ranked = try await rankWithFacts(query, pool: pool, planned: PlannedFacts(index: index, plan: plan, restMayUseProvider: may),
                                                     second: second)
                }
            }
            let plan = index.plan(query, today: today)
            let wholeIDs = Set(whole.map(\.memoryID))
            let read = ranked.prefix(count).map(\.memoryID).filter(wholeIDs.contains)
            let readSet = Set(read)
            var unread: [UUID] = []
            // Only results a link or the timeline admitted can be "not read for what links them" (a plain result that a
            // different rest-of-query score moved isn't).
            if case .sendable = view {
                unread = whole.prefix(count).filter { $0.admission != nil && !readSet.contains($0.memoryID) }.map(\.memoryID)
            }
            var admissions: [UUID: SearchAdmission] = [:]
            for hit in ranked where readSet.contains(hit.memoryID) { if let a = hit.admission { admissions[hit.memoryID] = a } }

            // The note (§10.3, §11.6): a timeline the view's grammar can't decide. Bridges are retired (13e.2): the rows
            // and the memories they cite replaced them.
            let bridges: [AnswerFactsPlan.Bridge] = []
            var note: TimelineNote?
            let g = index.graph
            if let t = plan.timeline, !t.decided {
                let noun = g.registry.predicate(t.predicate)?.phrases["note_noun"] ?? t.predicate
                note = TimelineNote(noun: noun, op: t.opWords, anchor: t.anchor.flatMap { g.entities[$0]?.name })
            }

            // 13e.2's rows (§10.3): for a cloud answer shown where checked claims are, a *timeline* predicate the search
            // touches loosely (one of its holders matched, a word of the predicate, or an operator or time cue).
            var rows: TimelineRows?, check: TimelineCheck?, cited: [UUID] = []
            if checked, !onDevice, case .sendable = view,
               let p = answerUses.predicates(.timeline).first(where: { Self.touches(query, predicate: $0, plan: plan, graph: g)
                   || Self.readsHolders(Set(read.map(\.db)), predicate: $0, graph: g) }) {
                var rg = g
                rg.uses = answerUses
                let built = TimelineRows.build(rg, predicate: p, first: plan.matches.map(\.entity))
                // Scanned for secrets like attributes (§10.3): a match sends no rows.
                if !built.isEmpty, SecretScanner.scan([built.block()]).isEmpty {
                    var local = fullIndex.graph
                    local.uses = answerUses
                    rows = built
                    check = TimelineCheck(graph: rg, local: local, rows: built)
                    let listed = try await store.writer.read { db in try MemoryStore.listed(db, filter: filter, now: now) }
                    let active = Set(listed.map(\.id.db))
                    // Every candidate, in the rows' order: the answer leaves out those it reads as results (its own
                    // selection, which a rows-only plan takes from 13b) and keeps the first 6 within the budget.
                    cited = built.citedMemoryIDs.filter { active.contains($0) }.compactMap(UUID.init(uuidString:))
                }
            }

            // Attributes, each with the highest sensitivity behind it (and the rows', 13e.2).
            var behind = Set(read.map(\.db))
            // The rows' holders and every holder a stated rename joins them to: their memories, and their fact ids (for the
            // user's own entries and corrections, which the send boundary reads again).
            let rowHolders: Set<String> = rows.map { r in
                let ids = Set(r.entities.values)
                return ids.union(g.statedGroups(r.predicate).filter { !$0.isDisjoint(with: ids) }.flatMap { $0 })
            } ?? []
            let rowFactsList = rows.map { r in g.facts.filter { $0.predicate == r.predicate && rowHolders.contains($0.entity) } } ?? []
            let rowsBehind = Set(rowFactsList.flatMap { $0.assertions.filter { !$0.fromUser }.map(\.memoryID) })
            let rowsFacts = Set(rowFactsList.compactMap { index.factIDs[FactStore.Loaded.key($0.predicate, $0.entity)] })
            behind.formUnion(rowsBehind)
            for f in g.facts { for a in f.assertions where !a.fromUser { behind.insert(a.memoryID) } }
            let ids = Array(behind)
            let levels: [String: Sensitivity] = try await store.writer.read { db in
                var out: [String: Sensitivity] = [:]
                for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                    for r in try Row.fetchAll(db, sql: "SELECT id, sensitivity FROM memory WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))",
                                              arguments: StatementArguments(chunk)) {
                        out[r["id"]] = Sensitivity(rawValue: r["sensitivity"] as Int) ?? .secret
                    }
                }
                return out
            }
            var attributes: [UUID: AnswerFactsPlan.Attribute] = [:]
            for id in read {
                guard let adm = admissions[id],
                      let a = AnswerAttributes.attribute(adm, memory: id, plan: plan, index: index, uses: answerUses, levels: levels) else { continue }
                attributes[id] = a
            }
            let revision = await factsRevision() ?? ""
            // Rows alone (a *timeline* record, no *attributes* one, 13e.2): 13b's selection with the rows on top, nothing
            // else inferred; with neither, no plan.
            let factsSelection = !answerUses.predicates(.attributes).isEmpty
            if !factsSelection, rows == nil { return nil }
            var out = AnswerFactsPlan(read: read, unreadLinked: factsSelection ? unread : [], admissions: factsSelection ? admissions : [:],
                                      attributes: factsSelection ? attributes : [:], bridges: bridges, note: factsSelection ? note : nil,
                                      revision: revision, view: index, plan: plan)
            out.factsSelection = factsSelection
            out.rowsFacts = rowsFacts
            out.rowsHolders = rowHolders
            out.rows = rows
            out.check = check
            out.cited = cited
            out.rowsBehind = rowsBehind
            out.rowsSensitivity = rowsBehind.map { levels[$0] ?? .secret }.max() ?? .public
            return out
        } catch {
            return nil
        }
    }

    /// Whether a search touches a *timeline* predicate, loosely (§10.3: a wrong include costs tokens, not an answer): one
    /// of its holders matched, a word of the predicate's lexicon, or an operator or time cue of the registry.
    /// Whether the memories the answer reads state a fact of the predicate (any trust): the answer may then speak of
    /// those jobs, so it gets the rows and its claims the check (13e.2's fix round: lists, "my own business these
    /// days", a client's years).
    static func readsHolders(_ read: Set<String>, predicate: String, graph: FactsGraph) -> Bool {
        graph.facts.contains { f in
            f.predicate == predicate && !f.negated && f.assertions.contains { !$0.fromUser && read.contains($0.memoryID) }
        }
    }

    static func touches(_ query: String, predicate: String, plan: FactsQueryPlan, graph: FactsGraph) -> Bool {
        let holders = Set(graph.facts.filter { $0.predicate == predicate && !$0.negated }.map(\.entity))
        if plan.matches.contains(where: { holders.contains($0.entity) }) { return true }
        let q = FactsText.fold(query)
        let words = (graph.registry.predicate(predicate)?.lexicon.flatMap(\.words) ?? []) + AnswerTimeCues.words(graph.registry)
        return words.contains { FactsText.cue(q, $0) } || AnswerTimeCues.hasDate(query, registry: graph.registry)
    }
}

extension SearchService {
    /// A why line's corrections as targets with their tokens (**Not <name>** for its memory, **Not this** for its fact),
    /// for a phone with the `facts` capability (companion protocol §4 `memories.search`).
    public func corrections(for line: WhyLine) async throws -> [FactsCorrection] {
        var out: [FactsCorrection] = []
        let attribute: String? = if case let .name(_, a) = line.form { a } else { nil }
        if let n = line.notName {
            out.append(FactsCorrection(target: FactsCorrectionTarget(what: .name, linkID: FactsCorrections.linkID(memory: n.memoryID, entity: n.entity),
                                                                     memoryID: n.memoryID, token: ""), name: n.name, attribute: attribute))
        }
        if let fid = line.notThis {
            out.append(FactsCorrection(target: FactsCorrectionTarget(what: .fact, factID: fid, token: ""), name: line.notName?.name,
                                       attribute: attribute))
        }
        guard !out.isEmpty else { return [] }
        let pending = out
        return try await store.writer.read { db in try FactsCorrections.minted(db, pending) }
    }
}

/// How the app words learned facts for a phone (companion protocol §4): the Mac's String Catalog, so the phone shows the
/// Mac's words. The companion has an English fallback for tests.
public protocol FactsWording: Sendable {
    /// A result's why line ("my sister → Maria (only sister Funes knows)").
    func whyLine(_ line: WhyLine) -> String
    /// What an inferred claim rests on ("Maria is your sister: the only sister Funes knows").
    func claimWhy(_ line: WhyLine) -> String
    /// A correction's button ("Not Maria", "Not this").
    func label(_ correction: FactsCorrection) -> String
    /// The undecidable-timeline note ("Funes can't tell which job came before Acme").
    func note(_ note: TimelineNote) -> String
}
