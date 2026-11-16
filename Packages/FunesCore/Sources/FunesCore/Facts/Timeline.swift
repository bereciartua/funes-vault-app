import Foundation

/// How a timeline answer was reached (memory processing §11.7).
public enum TimelineBasis: String, Sendable {
    case ordered      // the dates decide it
    case stated       // a memory states the order, and the dates don't contradict it
    case inferred     // succession, a same-year hand-over, or untrusted dates
    case gap          // the answer, with a gap longer than the predicate's `gap_months` told
    case ambiguous    // told, not guessed
    case unknown      // nothing known about the anchor
}

/// What a timeline question is anchored on: a fact's entity, or a date.
public enum TimelineAnchor: Sendable, Equatable {
    case entity(String)
    case date(DateRange)
}

/// A timeline answer: no entity, one, or several (a year or "current" can have several).
public struct TimelineAnswer: Sendable, Equatable {
    public var entities: [String]
    public var basis: TimelineBasis

    public var entity: String? { entities.count == 1 ? entities[0] : nil }

    static func none(_ basis: TimelineBasis) -> TimelineAnswer { TimelineAnswer(entities: [], basis: basis) }
    static func one(_ id: String?, _ basis: TimelineBasis) -> TimelineAnswer {
        TimelineAnswer(entities: id.map { [$0] } ?? [], basis: basis)
    }
}

public enum TimelineDirection: String, Sendable { case before, after }

extension FactsGraph {
    /// The episode a question means when the entity has several: "the first time", "when I returned", or none.
    func pickEpisode(_ eps: [Episode], query: String) -> Episode? {
        if eps.count == 1 { return eps[0] }
        let q = FactsText.fold(query)
        func cue(_ words: [String]) -> Bool { words.contains { FactsText.cue(q, $0) } }
        if cue(registry.language.episodeFirst) { return eps.first }
        if cue(registry.language.episodeLast) { return eps.last }
        return nil
    }

    /// Episode a could come just before episode b: nothing in their dates says a ended after b started.
    func couldNeighbour(_ a: Episode, _ b: Episode) -> Bool {
        if let end = a.end, let bs = b.tstart, end.lo > bs.hi { return false }
        if let s = a.tstart, let bs = b.tstart, s.lo > bs.hi { return false }
        // b's end bounds it too: a can't come before something that ended before a ended, or before a began.
        if let end = a.end, let be = b.end, end.lo > be.hi { return false }
        if let s = a.tstart, let be = b.end, s.lo > be.hi { return false }
        return true
    }

    private struct Edge: Hashable {
        let from: ObjectIdentifier
        let to: ObjectIdentifier
    }

    /// Whether the user rejected the edge from one episode to the next (for those episodes, if the rejection says).
    func isRejected(_ from: Episode, _ to: Episode) -> Bool {
        func covers(_ sel: DateRange?, _ e: Episode) -> Bool {
            guard let sel else { return true }
            return (e.start?.lo ?? DateRange.minDay) <= sel.hi && sel.lo <= (e.end?.hi ?? DateRange.maxDay)
        }
        return rejectedEdges.contains { r in
            r.from == from.entity && r.to == to.entity && covers(r.fromSelector, from) && covers(r.toSelector, to)
        }
    }

    /// Trusted order edges between episodes ("A preceded_by B"), resolved only to one fitting episode of the entity;
    /// edges on a cycle are dropped.
    private func statedEdges(_ predicate: String, _ eps: [Episode]) -> Set<Edge> {
        // Edges resolve to trusted episodes; an entity's untrusted-only episodes count only if it has no trusted one.
        var byEntity: [String?: [Episode]] = [:]
        let withTrusted = Set(eps.filter(\.trusted).map(\.entity))
        for e in eps where e.trusted || !withTrusted.contains(e.entity) { byEntity[e.entity, default: []].append(e) }
        var edges = Set<Edge>()
        for e in eps {
            for a in e.assertions where a.trusted {
                for (value, byID, isBefore) in [(a.precededBy, a.precededByEntity, true), (a.followedBy, a.followedByEntity, false)] {
                    let targets = byID.map { [$0] } ?? value.map { entityMatches(predicate, $0, onlyTrusted: true) } ?? []
                    // A name that could mean several entities doesn't identify the other end.
                    guard targets.filter({ $0 != e.entity }).count <= 1 else { continue }
                    for t in targets where t != e.entity {
                        let fits = (byEntity[t] ?? []).filter { o in
                            if byID != nil, let sel = a.otherSelector {     // the user picked the other episode
                                let lo = o.start?.lo ?? DateRange.minDay, hi = o.end?.hi ?? DateRange.maxDay
                                return lo <= sel.hi && sel.lo <= hi
                            }
                            return isBefore ? couldNeighbour(o, e) : couldNeighbour(e, o)
                        }
                        guard fits.count == 1 else { continue }        // which of its episodes is meant isn't decidable
                        let (from, to) = isBefore ? (fits[0], e) : (e, fits[0])
                        if isRejected(from, to) { continue }
                        let other = ObjectIdentifier(fits[0]), me = ObjectIdentifier(e)
                        edges.insert(isBefore ? Edge(from: other, to: me) : Edge(from: me, to: other))
                    }
                }
            }
        }
        var graph: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
        for edge in edges { graph[edge.from, default: []].insert(edge.to) }
        func reaches(_ u: ObjectIdentifier, _ target: ObjectIdentifier, _ seen: inout Set<ObjectIdentifier>) -> Bool {
            for v in graph[u] ?? [] {
                if v == target { return true }
                if !seen.contains(v) {
                    seen.insert(v)
                    if reaches(v, target, &seen) { return true }
                }
            }
            return false
        }
        return edges.filter { edge in
            var seen = Set<ObjectIdentifier>()
            return !reaches(edge.to, edge.from, &seen)
        }
    }

    /// The one ordering rule. For "before", the anchor's boundary is its start and each candidate's is its end; "after"
    /// mirrors it. An answer must certainly lie on the right side, and no other episode may possibly sit closer.
    func order(_ predicate: String, _ eps: [Episode], _ sx: Episode, _ direction: TimelineDirection) -> (String?, TimelineBasis) {
        let gapDays = registry.predicate(predicate)?.gapMonths.map { $0 * 30.44 }
        let before = direction == .before
        let anchor = before ? sx.tstart : sx.end
        let conflict = before ? sx.conflictStart : sx.conflictEnd
        let boundOf: (Episode) -> DateRange? = { before ? $0.end : $0.tstart }
        let ids = Dictionary(eps.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { a, _ in a })
        let edges = statedEdges(predicate, eps)

        /// Another episode certainly sits between w and the anchor.
        func between(_ w: Episode) -> Bool {
            guard let a = anchor else { return false }
            for o in eps where o !== w && o !== sx && o.trusted && o.startTrusted && o.endTrusted {
                guard let os = o.tstart, let oe = o.end else { continue }
                if before, let we = w.end, os.lo >= we.hi, oe.hi <= a.lo { return true }
                if !before, let ws = w.tstart, os.lo >= a.hi, oe.hi <= ws.lo { return true }
            }
            return false
        }
        func gapOf(_ w: Episode) -> Int? {
            guard let a = anchor, let b = boundOf(w) else { return nil }
            return before ? a.lo - b.hi : b.lo - a.hi
        }
        func isGap(_ g: Int?) -> Bool { gapDays != nil && g != nil && Double(g!) > gapDays! }

        let me = ObjectIdentifier(sx)
        let stated = before ? edges.filter { $0.to == me }.compactMap { ids[$0.from] }
                            : edges.filter { $0.from == me }.compactMap { ids[$0.to] }
        if stated.count == 1, !conflict {
            let w = stated[0]
            var clash: Bool
            if let a = anchor {
                if before {
                    clash = (w.end == nil && (w.ongoing || (w.heldAt ?? 0) >= a.lo)) || (w.end.map { $0.lo > a.hi } ?? false)
                } else {
                    clash = w.tstart.map { $0.hi < a.lo } ?? false
                }
            } else {
                clash = false
            }
            // An ongoing predecessor can't come before anything, dates or not.
            if before ? (w.ongoing && !w.inferredEnd) : (sx.ongoing && !sx.inferredEnd) { clash = true }
            // The memories disagree on the boundary the edge rests on, or the dates rule the order out.
            if before ? w.conflictEnd : w.conflictStart { clash = true }
            if !(before ? couldNeighbour(w, sx) : couldNeighbour(sx, w)) { clash = true }
            if !clash, !between(w) {
                let trustedEnds = w.trusted && sx.trusted
                if isGap(gapOf(w)) { return trustedEnds ? (w.entity, .gap) : (nil, .ambiguous) }
                return (w.entity, trustedEnds ? .stated : .inferred)   // an untrusted-only endpoint
            }
        }
        guard let a = anchor, !conflict else { return (nil, .ambiguous) }

        struct Candidate { let e: Episode; let b: DateRange?; let certain: Bool; let near: Bool }
        var cands: [Candidate] = []
        for e in eps where e !== sx {
            let b = boundOf(e)
            var certain: Bool, near: Bool
            if before {
                if let s = e.tstart, s.lo > a.hi { continue }             // it started after the anchor did
                guard let b else {
                    if let h = e.heldAt, h >= a.lo { continue }           // it still held when the anchor started
                    cands.append(Candidate(e: e, b: nil, certain: false, near: false))
                    continue
                }
                if b.lo > a.hi { continue }                               // certainly still going then
                certain = b.hi <= a.lo || e.endedBy === sx
                near = !certain && (e.tstart.map { $0.hi < a.lo } ?? false)
            } else {
                if let end = e.end, end.hi < a.lo { continue }            // it ended before the anchor did
                guard let b else {
                    cands.append(Candidate(e: e, b: nil, certain: false, near: false))
                    continue
                }
                if b.hi < a.lo { continue }                               // it certainly started before the anchor ended
                certain = b.lo >= a.hi || sx.endedBy === e
                near = !certain && (sx.tstart.map { $0.hi < b.lo } ?? false)
                    && (e.ongoing || (e.end.map { $0.lo > a.hi } ?? false))
            }
            if before ? e.conflictEnd : e.conflictStart {
                certain = false
                near = false
            }
            cands.append(Candidate(e: e, b: b, certain: certain, near: near))
        }
        let certainOnes = cands.filter(\.certain)
        let nears = cands.filter(\.near)
        let winner: Candidate, basisInferred: Bool
        if !certainOnes.isEmpty {
            winner = before ? certainOnes.firstMax { $0.b!.lo }! : certainOnes.firstMin { $0.b!.hi }!
            basisInferred = false
        } else if nears.count == 1 {
            winner = nears[0]                // a hand-over in the same year or month, with nothing else that could fit
            basisInferred = true
        } else {
            return (nil, .ambiguous)
        }
        let w = winner.e, wb = winner.b!
        // The user rejected this order: the dates don't bring it back, and nothing else is guessed in its place.
        if before ? isRejected(w, sx) : isRejected(sx, w) { return (nil, .ambiguous) }
        let contiguous = (before ? a.hi - wb.lo <= 62 : wb.hi - a.lo <= 62)
            || (before ? w.endedBy === sx : sx.endedBy === w)   // ended by the anchor's own start: nothing between
        for c in cands where c.e !== w && c.e.entity != w.entity {
            guard let b = c.b else {
                if before, let s = c.e.tstart, s.lo > wb.hi { return (nil, .ambiguous) }   // started after w ended
                if !before, let end = c.e.end, end.hi < wb.lo { return (nil, .ambiguous) } // ended before w started
                if !contiguous { return (nil, .ambiguous) }       // an undated or open-ended fact could sit between
                continue
            }
            if before ? b.hi >= wb.lo : b.lo <= wb.hi { return (nil, .ambiguous) }   // it could sit as close, or closer
        }
        let untrusted = (before ? (!w.endTrusted || !sx.startTrusted) : (!sx.endTrusted || !w.startTrusted))
            || !w.trusted || !sx.trusted
        // A gap is told only on trusted dates: untrusted ones can't say how long it was.
        if isGap(gapOf(w)) { return untrusted ? (nil, .ambiguous) : (w.entity, .gap) }
        let inferred = basisInferred || untrusted || (before ? w.inferredEnd : sx.inferredEnd)
        return (w.entity, inferred ? .inferred : .ordered)
    }

    /// The fact just before (or after) an anchor: an entity, or a date (the one held just before or after that date,
    /// else the one that ended or started nearest it).
    public func before(_ predicate: String, _ anchor: TimelineAnchor, query: String = "",
                       direction: TimelineDirection = .before) -> TimelineAnswer {
        let eps = episodes(predicate)
        switch anchor {
        case .date(let x):
            let edge = direction == .before ? DateRange.day(x.lo - 1) : DateRange.day(x.hi + 1)
            let held = inRange(predicate, edge, episodes: eps)
            if held.entities.count == 1 { return held }
            let sx = Episode(entity: nil, predicate: predicate, start: x, end: x)
            let (got, basis) = order(predicate, eps + [sx], sx, direction)
            let maybe = Set(eps.filter { $0.mayHold(edge) && !($0.end == nil && !$0.ongoing && $0.former) }.compactMap(\.entity))
            if !maybe.subtracting(got.map { [$0] } ?? []).isEmpty { return .none(.ambiguous) }   // another may have held then
            return .one(got, basis)
        case .entity(let x):
            let mine = eps.filter { $0.entity == x }.stableSorted { $0.sortKey }
            if mine.isEmpty { return .none(.unknown) }
            guard let sx = pickEpisode(mine, query: query) else { return .none(.ambiguous) }
            let (got, basis) = order(predicate, eps, sx, direction)
            return .one(got, basis)
        }
    }

    public func after(_ predicate: String, _ anchor: TimelineAnchor, query: String = "") -> TimelineAnswer {
        before(predicate, anchor, query: query, direction: .after)
    }

    /// Episodes that hold now, as far as Funes knows.
    public func current(_ predicate: String) -> [Episode] {
        episodes(predicate).filter { $0.ongoing && !$0.inferredEnd }
    }

    /// The fact before the one that held at a memory's date, by the same rule as "before X".
    public func previousAsOf(_ predicate: String, written: String) -> String? {
        previousLink(predicate, written: written)?.entity
    }

    /// The fact before the one that held at a date, and whether every step to it rests on trusted evidence.
    func previousLink(_ predicate: String, written: String) -> (entity: String, trusted: Bool)? {
        guard let d = parser.day(written) else { return nil }
        let eps = episodes(predicate)
        let day = DateRange.day(d)
        let now = eps.filter { $0.certainlyHolds(day) }
        guard now.count == 1 else { return nil }
        // Another job that may also be the current one then makes the anchor, and so "previous", unknown.
        // Judged at that date: a former job whose dates may cover it counts too.
        let rivals = eps.filter { e in
            e !== now[0] && e.entity != now[0].entity
                && !(e.start.map { $0.lo > day.hi } ?? false) && !(e.end.map { $0.hi < day.lo } ?? false)
                && !(e.uncertain && (e.uncertainFrom ?? Int.max) < day.lo)
        }
        guard rivals.isEmpty else { return nil }
        let (got, basis) = order(predicate, eps, now[0], .before)
        guard let got, [.ordered, .stated, .inferred].contains(basis) else { return nil }
        let chain = eps.filter { $0.entity == got } + [now[0]]
        return (got, chain.allSatisfy { $0.trusted && $0.startTrusted && $0.endTrusted })
    }

    /// Entities whose episodes cover a range (a year, a month, a day): every possible one must be certain.
    public func inRange(_ predicate: String, _ rng: DateRange, episodes given: [Episode]? = nil) -> TimelineAnswer {
        var certain = Set<String>(), possible = Set<String>(), untrusted = false
        for e in given ?? episodes(predicate) {
            guard let id = e.entity else { continue }
            let maybe = (e.tstart.map { $0.lo <= rng.hi } ?? true) && (e.end.map { $0.hi >= rng.lo } ?? true)
                && !(e.end == nil && !e.ongoing && (e.heldAt.map { $0 < rng.lo } ?? false) && e.former)
            let sure: Bool
            if let s = e.tstart, s.hi <= rng.lo {
                sure = (e.end.map { $0.lo >= rng.hi } ?? false) || (e.ongoing && (e.heldAt.map { $0 >= rng.hi } ?? false))
            } else {
                sure = false
            }
            if sure {
                certain.insert(id)
                // An inferred end matters only when the range reaches past the last day a memory said it held.
                untrusted = untrusted || !(e.startTrusted && e.endTrusted) || !e.trusted
                    || (e.inferredEnd && (e.heldAt.map { $0 < rng.hi } ?? true))
            } else if maybe {
                possible.insert(id)
            }
        }
        if !possible.subtracting(certain).isEmpty || certain.isEmpty { return .none(.ambiguous) }
        let ids = certain.sorted { (entities[$0]?.seq ?? 0) < (entities[$1]?.seq ?? 0) }
        return TimelineAnswer(entities: ids, basis: untrusted ? .inferred : .ordered)
    }

    /// The answer to a timeline intent.
    public func answer(_ it: TimelineIntent, query: String = "") -> TimelineAnswer {
        switch it.op {
        case .before, .after:
            guard let anchor = it.anchor else { return .none(.ambiguous) }
            return before(it.predicate, anchor, query: query, direction: it.op == .before ? .before : .after)
        case .year:
            guard case .date(let rng) = it.anchor else { return .none(.ambiguous) }
            return inRange(it.predicate, rng)
        case .current, .previous:
            let eps = episodes(it.predicate)
            let now = eps.filter { $0.ongoing && !$0.inferredEnd }
            if it.op == .previous {
                // As for "current": an episode that may have ended (or not) leaves the anchor unknown.
                guard now.count == 1, !eps.contains(where: \.uncertain) else { return .none(.ambiguous) }
                let (got, basis) = order(it.predicate, eps, now[0], .before)
                return .one(got, basis)
            }
            if now.isEmpty || eps.contains(where: \.uncertain) { return .none(.ambiguous) }
            let basis: TimelineBasis = now.allSatisfy { $0.heldAt != nil && $0.trusted && $0.startTrusted } ? .ordered : .inferred
            var ids: [String] = []
            for e in now { if let id = e.entity, !ids.contains(id) { ids.append(id) } }
            if ids.count > 1 { ids.sort { (entities[$0]?.seq ?? 0) < (entities[$1]?.seq ?? 0) } }
            return TimelineAnswer(entities: ids, basis: basis)
        }
    }
}
