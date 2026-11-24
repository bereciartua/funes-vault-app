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
                    now: Date) async -> AnswerFactsPlan? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let config = facts else { return nil }
        if case let .sendable(limit) = view, limit != config.cloudLimit { return nil }
        do {
            let state: (FactsUses, FactsUses)? = try await store.writer.read { db in
                let uses = try config.uses(db)
                let answerUses = try config.answerUses(db, answerModel: answerModel)
                guard !uses.predicates(.linked).isEmpty, !answerUses.predicates(.attributes).isEmpty else { return nil }
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

            // Bridges and the note (§10.3, §11.6): a timeline the view decides, or can't.
            var bridges: [AnswerFactsPlan.Bridge] = []
            var note: TimelineNote?
            let g = index.graph
            if let t = plan.timeline {
                if t.decided {
                    if answerUses.isOn(t.predicate, .bridges), !onDevice {
                        bridges = try await self.bridges(t, index: index, ranked: ranked, read: readSet, filter: filter, view: view, now: now)
                    }
                } else {
                    let noun = g.registry.predicate(t.predicate)?.phrases["note_noun"] ?? t.predicate
                    note = TimelineNote(noun: noun, op: t.opWords, anchor: t.anchor.flatMap { g.entities[$0]?.name })
                }
            }

            // Attributes, each with the highest sensitivity behind it.
            var behind = Set(read.map(\.db))
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
            return AnswerFactsPlan(read: read, unreadLinked: unread, admissions: admissions, attributes: attributes, bridges: bridges,
                                   note: note, revision: revision, view: index, plan: plan)
        } catch {
            return nil
        }
    }

    /// Up to 2 memories that state a decided timeline answer's fact (§10.3): trusted, within the view (and so the limit),
    /// active under the search's filter, not already read, best ranked first (then the most recently written).
    private func bridges(_ t: FactsQueryPlan.Timeline, index: FactsSearchIndex, ranked: [SearchHit], read: Set<UUID>,
                         filter: MemoryFilter, view: AnswerView, now: Date) async throws -> [AnswerFactsPlan.Bridge] {
        let g = index.graph
        let answer = t.answerGroup.isEmpty ? Set(t.answer) : t.answerGroup   // a stated rename's names too
        var stating: [String: (entity: String, factID: String?, written: String)] = [:]
        for f in g.facts where f.predicate == t.predicate && answer.contains(f.entity) && !f.negated {
            let fid = index.factIDs[FactStore.Loaded.key(f.predicate, f.entity)]
            for a in f.assertions where a.states && !a.fromUser && a.trusted {
                stating[a.memoryID] = (f.entity, fid, max(stating[a.memoryID]?.written ?? "", a.written))
            }
        }
        guard !stating.isEmpty else { return [] }
        // Above the limit, a bridge is left out by the answer like any memory (the sendable view's stating memories are
        // within it anyway).
        let listed = try await store.writer.read { db in try MemoryStore.listed(db, filter: filter, now: now) }
        var allowed = Set<String>()
        for m in listed where stating[m.id.db] != nil && !read.contains(m.id) { allowed.insert(m.id.db) }
        let rank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1.memoryID.db, $0) })
        let order = allowed.sorted { a, b in
            switch (rank[a], rank[b]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (stating[a]!.written, a) > (stating[b]!.written, b)
            }
        }
        let others = g.facts.filter { $0.predicate == t.predicate && $0.entity == t.anchor }
            .compactMap { index.factIDs[FactStore.Loaded.key($0.predicate, $0.entity)] }
        return order.prefix(SearchAnswerer.bridgeCount).compactMap { id in
            guard let s = stating[id], let uuid = UUID(uuidString: id) else { return nil }
            return AnswerFactsPlan.Bridge(memoryID: uuid, entity: s.entity, factIDs: [s.factID].compactMap { $0 } + others, basis: t.basis)
        }
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
