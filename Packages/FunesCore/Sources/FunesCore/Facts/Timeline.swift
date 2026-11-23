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
    /// The episode a question means when the entity has several: "the first time", "the second time", "when I
    /// returned", or none. Cues that disagree, or an ordinal past the episodes known, pick none. Words of the entity's
    /// own names aren't cues ("First National Bank").
    func pickEpisode(_ eps: [Episode], query: String) -> Episode? { episodeCue(eps, query: query).pick }

    /// The episode cues of a question: whether it has any, and the episode they pick (nil: none, or they can't).
    func episodeCue(_ eps: [Episode], query: String) -> (cued: Bool, pick: Episode?) {
        guard let first = eps.first else { return (false, nil) }
        var q = FactsText.fold(query)
        if let id = first.entity, let e = entities[id] {
            for a in e.aliases.map(FactsText.fold).sorted(by: { $0.count > $1.count }) where !a.isEmpty {
                q = FactsText.regex("(?<!\\w)" + FactsText.escape(a) + "(?!\\w)")
                    .stringByReplacingMatches(in: q, range: NSRange(location: 0, length: FactsText.length(q)), withTemplate: " ")
            }
        }
        let lang = registry.language
        func cue(_ words: [String]) -> Bool { words.contains { FactsText.cue(q, $0) } }
        var picks = Set<Int>()
        if cue(lang.episodeFirst) { picks.insert(1) }
        for (w, n) in lang.episodeOrdinals where FactsText.cue(q, w) { picks.insert(n) }
        if cue(lang.episodeLast) { picks.insert(eps.count) }
        if picks.isEmpty { return (false, eps.count == 1 ? first : nil) }
        guard picks.count == 1, let n = picks.first, n >= 1, n <= eps.count else { return (true, nil) }
        return (true, eps[n - 1])
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
    func order(_ predicate: String, _ eps: [Episode], _ sx: Episode, _ direction: TimelineDirection,
               strictTrust: Bool = false) -> (String?, TimelineBasis) {
        let (w, basis) = orderCore(predicate, eps, sx, direction)
        // An answer: told when the episode answering, or the anchor's, has only untrusted evidence (13e.1).
        if strictTrust, let w, !w.trusted || !sx.trusted { return (nil, .ambiguous) }
        return (w?.entity, basis)
    }

    private func orderCore(_ predicate: String, _ eps: [Episode], _ sx: Episode, _ direction: TimelineDirection) -> (Episode?, TimelineBasis) {
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
                if isGap(gapOf(w)) { return trustedEnds ? (w, .gap) : (nil, .ambiguous) }
                return (w, trustedEnds ? .stated : .inferred)   // an untrusted-only endpoint
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
                // A same-year (or month) hand-over: a stated end of that precision, not a wide "ended by" bound.
                near = !certain && (e.tstart.map { $0.hi < a.lo } ?? false) && Self.handoverPrecision(b) && Self.handoverPrecision(a)
            } else {
                if let end = e.end, end.hi < a.lo { continue }            // it ended before the anchor did
                guard let b else {
                    cands.append(Candidate(e: e, b: nil, certain: false, near: false))
                    continue
                }
                if b.hi < a.lo { continue }                               // it certainly started before the anchor ended
                certain = b.lo >= a.hi || sx.endedBy === e
                near = !certain && (sx.tstart.map { $0.hi < b.lo } ?? false)
                    && (e.ongoing || (e.end.map { $0.lo > a.hi } ?? false)) && Self.handoverPrecision(b) && Self.handoverPrecision(a)
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
        if isGap(gapOf(w)) { return untrusted ? (nil, .ambiguous) : (w, .gap) }
        let inferred = basisInferred || untrusted || (before ? w.inferredEnd : sx.inferredEnd)
        return (w, inferred ? .inferred : .ordered)
    }

    /// A boundary precise enough for a same-year hand-over: stated at year, month or day precision, within a year.
    static func handoverPrecision(_ b: DateRange) -> Bool {
        [.year, .month, .day].contains(b.precision) && b.hi - b.lo <= 366
    }

    /// The fact just before (or after) an anchor: an entity, or a date (the one held just before or after that date,
    /// else the one that ended or started nearest it).
    public func before(_ predicate: String, _ anchor: TimelineAnchor, query: String = "",
                       direction: TimelineDirection = .before, episodes given: [Episode]? = nil,
                       anchorDate: DateRange? = nil, boundary: String? = nil, slot: String? = nil,
                       strictTrust: Bool = false, stint: Int? = nil) -> TimelineAnswer {
        guard uses.isOn(predicate, .timeline) else { return .none(.unknown) }      // §11.10
        let eps = given ?? episodes(predicate)
        switch anchor {
        case .date(let x):
            let edge = direction == .before ? DateRange.day(x.lo - 1) : DateRange.day(x.hi + 1)
            let held = inRange(predicate, edge, episodes: eps, strictTrust: strictTrust)
            if held.entities.count == 1 { return held }
            let sx = Episode(entity: nil, predicate: predicate, start: x, end: x)
            let (got, basis) = order(predicate, eps + [sx], sx, direction, strictTrust: strictTrust)
            let maybe = Set(eps.filter { $0.mayHold(edge) && !($0.end == nil && !$0.ongoing && $0.former) }.compactMap(\.entity))
            if !maybe.subtracting(got.map { [$0] } ?? []).isEmpty { return .none(.ambiguous) }   // another may have held then
            return .one(got, basis)
        case .entity(let x):
            // The entity's trusted episodes, when it has any: an untrusted one can't renumber them ("the second time").
            let all = eps.filter { $0.entity == x }.stableSorted { $0.sortKey }
            let trustedOnes = all.filter(\.trusted)
            let mine = trustedOnes.isEmpty ? all : trustedOnes
            if mine.isEmpty { return .none(.unknown) }
            var cue = episodeCue(mine, query: query)
            // A stint by number (13e.2's check) stands for the phrase's cues: one past those known can't be met.
            if let n = stint { cue = (true, (1...mine.count).contains(n) ? mine[n - 1] : nil) }
            if cue.cued, cue.pick == nil { return .none(.ambiguous) }    // a cue that can't be met: never overridden
            let picked = cue.pick
            var chosen = picked
            if let d = anchorDate {
                // The date picks the episode whose stated boundary it overlaps; none, several, or another than an episode
                // cue picked: told.
                func stated(_ r: DateRange?) -> DateRange? { r.flatMap { [.year, .month, .day].contains($0.precision) ? $0 : nil } }
                func overlaps(_ r: DateRange?) -> Bool { r.map { $0.lo <= d.hi && d.lo <= $0.hi } ?? false }
                let fits = mine.filter { e in
                    switch boundary {
                    case "start": return overlaps(stated(e.tstart))
                    case "end": return overlaps(stated(e.end))
                    default:
                        let lo = e.tstart?.lo ?? DateRange.minDay, hi = e.end?.hi ?? (e.ongoing ? DateRange.maxDay : (e.heldAt ?? DateRange.minDay))
                        return lo <= d.hi && d.lo <= hi
                    }
                }
                guard fits.count == 1 else { return .none(.ambiguous) }
                if mine.count > 1, let p = picked, p !== fits[0] { return .none(.ambiguous) }
                chosen = fits[0]
            }
            guard let sx = chosen else { return .none(.ambiguous) }
            // Within a slot, the anchor's own episodes of another kind are no candidates.
            let pool = slot.map { s in eps.filter { $0 === sx || $0.slot == s } } ?? eps
            let (got, basis) = order(predicate, pool, sx, direction, strictTrust: strictTrust)
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
        guard uses.isOn(predicate, .timeline), let d = parser.day(written) else { return nil }
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
        // Either end may be one organization with another holder under another name: unknown, as for "previous".
        let split = maybeSplit(predicate)
        if split.contains(got) || now[0].entity.map(split.contains) == true { return nil }
        let chain = eps.filter { $0.entity == got } + [now[0]]
        return (got, chain.allSatisfy { $0.trusted && $0.startTrusted && $0.endTrusted })
    }

    /// Entities whose episodes cover a range (a year, a month, a day): every possible one must be certain.
    public func inRange(_ predicate: String, _ rng: DateRange, episodes given: [Episode]? = nil, strictTrust: Bool = false) -> TimelineAnswer {
        guard uses.isOn(predicate, .timeline) else { return .none(.unknown) }      // §11.10
        var certain = Set<String>(), possible = Set<String>(), untrusted = false, held: [Episode] = []
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
                held.append(e)
                // An inferred end matters only when the range reaches past the last day a memory said it held.
                untrusted = untrusted || !(e.startTrusted && e.endTrusted) || !e.trusted
                    || (e.inferredEnd && (e.heldAt.map { $0 < rng.hi } ?? true))
            } else if maybe {
                possible.insert(id)
            }
        }
        if !possible.subtracting(certain).isEmpty || certain.isEmpty { return .none(.ambiguous) }
        if refusesTogether(predicate, held) { return .none(.ambiguous) }
        // An answer: told when an episode answering has only untrusted evidence (13e.1).
        if strictTrust, held.contains(where: { !$0.trusted }) { return .none(.ambiguous) }
        let ids = certain.sorted { (entities[$0]?.seq ?? 0) < (entities[$1]?.seq ?? 0) }
        return TimelineAnswer(entities: ids, basis: untrusted ? .inferred : .ordered)
    }

    /// Episodes that can't be one answer, so the question is told rather than answered (memory processing §11.7):
    /// - an untrusted-only episode beside trusted ones: it may be a change an agent's note claims and the trusted
    ///   memories don't make (untrusted evidence never triggers succession, so it can't end the trusted one either);
    /// - episodes of different kinds at once (an employee job and self-employment, the predicate's slot): the question
    ///   may mean one kind ("my employer", "my day job");
    /// - an entity that may be another holder under another name (`maybeSplit`).
    func refusesTogether(_ predicate: String, _ eps: [Episode]) -> Bool {
        let named = eps.filter { $0.entity != nil }
        if named.contains(where: \.trusted), named.contains(where: { !$0.trusted }) { return true }
        if Set(named.map(\.slot)).count > 1 { return true }
        let split = maybeSplit(predicate)
        return named.contains { split.contains($0.entity!) }
    }

    /// Holders the user's own memories say are one organization under two names (13e.1, an ADR-0032 amendment): a
    /// trusted statement of one gives, as its other name, exactly the trusted name of one other holder ("Renamed Lattice
    /// Harbor Labs in 2020"). Read as one entity for episodes and timeline answers; links and search keep both. Never
    /// when the statement is a return ("volví cuando pasó a llamarse…"), when a trusted order edge joins the two, when a
    /// trusted episode of another holder in the same slot sits between them, or when the user said Not the Same of
    /// any two in the group. Only for a predicate with the timeline use declared. Loose matches stay `splitGroups`'.
    func statedGroups(_ predicate: String) -> [Set<String>] {
        guard registry.predicate(predicate)?.uses.contains(FactsUse.timeline.rawValue) == true else { return [] }
        let kind = registry.kindOf(predicate)
        let holderFacts = facts.filter { $0.predicate == predicate && !$0.negated && $0.trusted }
        let holders = Set(holderFacts.map(\.entity))
        func norm(_ n: String) -> String { FactsText.normName(n, kind: kind, registry: registry) }
        var parent: [String: String] = [:]
        func root(_ x: String) -> String {
            var x = x
            while let p = parent[x], p != x { x = p }
            return x
        }
        for f in holderFacts {
            for a in f.assertions where a.trusted && !a.fromUser {
                guard let also = a.alsoCalled, !norm(also).isEmpty, !isRejoin(a) else { continue }
                let targets = holders.filter { $0 != f.entity && (entities[$0]?.trustedAliases.contains { norm($0) == norm(also) } ?? false) }
                guard targets.count == 1, let b = targets.first, !separated(predicate, f.entity, b) else { continue }
                for x in [f.entity, b] where parent[x] == nil { parent[x] = x }
                let (ra, rb) = (root(f.entity), root(b))
                if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
            }
        }
        var groups: [String: Set<String>] = [:]
        for x in parent.keys { groups[root(x), default: []].insert(x) }
        // The whole group, not just the pairs that joined it: any two kept apart (Not the Same, an order edge, a job
        // between) and it isn't one entity.
        return groups.keys.sorted().compactMap { k in
            let g = groups[k]!
            if notSame.contains(where: { $0.isSubset(of: g) }) { return nil }
            let ids = g.sorted()
            for (i, a) in ids.enumerated() { for b in ids[(i + 1)...] where separated(predicate, a, b) { return nil } }
            return g
        }
    }

    /// Two holders kept apart whatever a statement calls them: a trusted order edge between them, or a trusted episode
    /// of another holder in the same slot lying between theirs.
    private func separated(_ predicate: String, _ a: String, _ b: String) -> Bool {
        let fa = facts.filter { $0.predicate == predicate && !$0.negated && ($0.entity == a || $0.entity == b) }
        let names = { (id: String) in Set((self.entities[id]?.trustedAliases ?? []).map { FactsText.fold($0) }) }
        let (na, nb) = (names(a), names(b))
        for f in fa {
            let other = f.entity == a ? nb : na, otherID = f.entity == a ? b : a
            for x in f.assertions where x.trusted {
                for (v, id) in [(x.precededBy, x.precededByEntity), (x.followedBy, x.followedByEntity)] {
                    if id == otherID || v.map({ other.contains(FactsText.fold($0)) }) == true { return true }
                }
            }
        }
        let epsA = fa.filter { $0.entity == a }.flatMap { factEpisodes($0) }.filter(\.trusted)
        let epsB = fa.filter { $0.entity == b }.flatMap { factEpisodes($0) }.filter(\.trusted)
        let others = facts.filter { $0.predicate == predicate && !$0.negated && $0.entity != a && $0.entity != b && $0.trusted }
            .flatMap { factEpisodes($0) }.filter { $0.trusted }
        for x in epsA {
            for y in epsB {
                let (early, late) = (x.tstart?.lo ?? x.end?.lo ?? 0) <= (y.tstart?.lo ?? y.end?.lo ?? 0) ? (x, y) : (y, x)
                guard let after = early.end?.hi ?? early.tstart?.hi, let before = late.tstart?.lo else { continue }
                if others.contains(where: { o in
                    o.slot == early.slot && (o.tstart.map { $0.lo >= after } ?? false) && (o.end.map { $0.hi <= before } ?? false)
                }) { return true }
            }
        }
        return false
    }

    /// The names a holder shows under on the timeline: its own, then those of the rest of its stated group.
    public func timelineNames(_ predicate: String, _ id: String) -> [String] {
        let group = statedGroups(predicate).first(where: { $0.contains(id) }) ?? [id]
        let others = group.subtracting([id]).sorted { (entities[$0]?.seq ?? 0) < (entities[$1]?.seq ?? 0) }
        return ([id] + others).compactMap { entities[$0]?.name }
    }

    /// The entity a holder is read as on the timeline: its stated group's stand-in (the earliest made), else itself.
    public func timelineEntity(_ predicate: String, _ id: String) -> String {
        guard let g = statedGroups(predicate).first(where: { $0.contains(id) }) else { return id }
        return g.min(by: { (entities[$0]?.seq ?? 0, $0) < (entities[$1]?.seq ?? 0, $1) }) ?? id
    }

    /// Holders of a predicate that may be one entity with another holder: a trusted statement gave one another name
    /// that is the other's ("Fenwick Lab, also called Fenwick Laboratories" when both exist: a merge suggestion, never a
    /// merge, §11.4), or their names match loosely by the kind's rule ("Fenwick Lab" in "Fenwick Laboratories"). Only
    /// holders with trusted evidence count: one name kept apart by alias trust (an agent's note named it first) is
    /// §11.4's separation, not a second name, and the untrusted-only episode rule covers it. The user's "not the same"
    /// settles a pair.
    func maybeSplit(_ predicate: String) -> Set<String> { Set(splitGroups(predicate).flatMap { $0 }) }

    /// `maybeSplit`'s holders in groups: each group may be one entity.
    func splitGroups(_ predicate: String) -> [Set<String>] {
        let kind = registry.kindOf(predicate)
        let holderFacts = facts.filter { $0.predicate == predicate && !$0.negated && $0.trusted }
        let holders = Set(holderFacts.map(\.entity))
        var parent: [String: String] = [:]
        func root(_ x: String) -> String {
            var x = x
            while let p = parent[x], p != x { x = p }
            return x
        }
        func pair(_ a: String, _ b: String) {
            guard a != b, !notSame.contains([a, b]) else { return }
            for x in [a, b] where parent[x] == nil { parent[x] = x }
            let (ra, rb) = (root(a), root(b))
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        // Loosely: one name's words begin a run of the other's words ("Fenwick Lab" and "Fenwick Laboratories", "Acme"
        // and "Acme Labs", a person's first name); never a piece inside a word ("Ola" isn't "Solano Datos").
        func words(_ n: String) -> [String] { FactsText.normName(n, kind: kind, registry: registry).split(separator: " ").map(String.init) }
        func inside(_ a: [String], _ b: [String]) -> Bool {
            guard !a.isEmpty, a.count <= b.count else { return false }
            return (0...(b.count - a.count)).contains { i in a.indices.allSatisfy { b[i + $0].hasPrefix(a[$0]) } }
        }
        let names = Dictionary(uniqueKeysWithValues: holders.map { id in (id, (entities[id]?.trustedAliases ?? []).map(words)) })
        let ids = holders.sorted()
        for (i, a) in ids.enumerated() {
            for b in ids[(i + 1)...] {
                let na = names[a] ?? [], nb = names[b] ?? []
                if na.contains(where: { x in nb.contains { y in inside(x, y) || inside(y, x) } }) { pair(a, b) }
            }
        }
        for f in holderFacts {
            for also in Set(f.assertions.filter(\.trusted).compactMap(\.alsoCalled)) {
                for o in byName(also, kind: kind, onlyTrusted: true) where holders.contains(o.id) { pair(f.entity, o.id) }
            }
        }
        var groups: [String: Set<String>] = [:]
        for x in parent.keys { groups[root(x), default: []].insert(x) }
        return groups.keys.sorted().map { groups[$0]! }
    }

    /// This graph with each group's facts of the predicate read as one entity's (the earliest made stands for it), and
    /// the stand-in for each merged entity. Only to check an answer holds either way; never stored.
    func merging(_ predicate: String, _ groups: [Set<String>]) -> (FactsGraph, [String: String]) {
        var g = self
        var rep: [String: String] = [:]
        for grp in groups {
            guard let r = grp.min(by: { (entities[$0]?.seq ?? 0, $0) < (entities[$1]?.seq ?? 0, $1) }) else { continue }
            for e in grp { rep[e] = r }
            for e in grp where e != r {
                g.entities[r]?.aliases.formUnion(entities[e]?.aliases ?? [])
                g.entities[r]?.trustedAliases.formUnion(entities[e]?.trustedAliases ?? [])
            }
        }
        var out: [LearnedFact] = [], at: [String: Int] = [:]
        // Order edges by id, and the user's rejected orders, point at the stand-in too.
        let facts = facts.map { f -> LearnedFact in
            var f = f
            for i in f.assertions.indices {
                f.assertions[i].precededByEntity = f.assertions[i].precededByEntity.map { rep[$0] ?? $0 }
                f.assertions[i].followedByEntity = f.assertions[i].followedByEntity.map { rep[$0] ?? $0 }
            }
            return f
        }
        g.rejectedEdges = rejectedEdges.map { r in
            var r = r
            r.from = rep[r.from] ?? r.from
            r.to = rep[r.to] ?? r.to
            return r
        }
        for f in facts {
            guard f.predicate == predicate, !f.negated, let r = rep[f.entity] else { out.append(f); continue }
            if let i = at[r] {
                out[i].assertions = (out[i].assertions + f.assertions).stableSorted { $0.readOrder }
            } else {
                var m = f
                m.entity = r
                at[r] = out.count
                out.append(m)
            }
        }
        g.facts = out
        return (g, rep)
    }

    /// The answer to a timeline intent. A stated rename (`statedGroups`) is read as one entity first, and an answer
    /// resting on that reading is at most `inferred`.
    public func answer(_ it: TimelineIntent, query: String = "") -> TimelineAnswer {
        let groups = statedGroups(it.predicate)
        guard !groups.isEmpty else { return answerUnmerged(it, query: query) }
        let (m, rep) = merging(it.predicate, groups)
        var mit = it
        if case .entity(let x) = it.anchor { mit.anchor = .entity(rep[x] ?? x) }
        var got = m.answerUnmerged(mit, query: query)
        let merged = Set(rep.values)
        var touches = got.entities.contains(where: merged.contains)
        if case .entity(let x) = mit.anchor, merged.contains(x) { touches = true }
        if touches, [.ordered, .stated].contains(got.basis) { got.basis = .inferred }
        return got
    }

    func answerUnmerged(_ it: TimelineIntent, query: String) -> TimelineAnswer {
        let got = answerCore(it, query: query)
        // An answer resting on an episode only untrusted text states (the answer's, or the anchor's) is told: the user's
        // own memories may say otherwise and not have been read, above the cloud limit (13e.1; the canary's c07q1).
        if !got.entities.isEmpty {
            let eps = episodes(it.predicate)
            func untrustedOnly(_ id: String) -> Bool {
                let mine = eps.filter { $0.entity == id }
                return !mine.isEmpty && mine.allSatisfy { !$0.trusted }
            }
            if got.entities.contains(where: untrustedOnly) { return .none(.ambiguous) }
            if case .entity(let x) = it.anchor, untrustedOnly(x) { return .none(.ambiguous) }
        }
        // Before, after and previous: an agent's note never reorders the user's own jobs. When the trusted memories
        // alone answer someone else, an untrusted-only episode changed the answer, so it's told (memory processing §11.6).
        guard [.before, .after, .previous, .atStart, .endedBefore, .first].contains(it.op), !got.entities.isEmpty,
              facts.contains(where: { $0.predicate == it.predicate && !$0.negated && $0.assertions.contains { !$0.trusted } }) else { return got }
        let alt = trustedOnly(it.predicate).answerCore(it, query: query)
        return alt.entities.isEmpty || alt.entities == got.entities ? got : .none(.ambiguous)
    }

    /// This graph with only trusted evidence for the predicate (the user's rows included).
    func trustedOnly(_ predicate: String) -> FactsGraph {
        var g = self
        g.facts = facts.compactMap { f in
            guard f.predicate == predicate else { return f }
            var f = f
            f.assertions = f.assertions.filter(\.trusted)
            return f.assertions.isEmpty ? nil : f
        }
        return g
    }

    /// The episodes a question reads: within the slot its words ask about ("my day job"), the anchor's own kept. With a
    /// slot, every trusted episode must have one: an unknown one may be what's asked about, so nil (told).
    func slotted(_ it: TimelineIntent) -> [Episode]? {
        let eps = episodes(it.predicate)
        guard let slot = it.slot else { return eps }
        var keep: String?
        if case .entity(let x) = it.anchor { keep = x }
        // The anchor's own kind doesn't matter ("my day job before my business Acme").
        if eps.contains(where: { $0.trusted && $0.slot == "_" && ($0.entity == nil || $0.entity != keep) }) { return nil }
        return eps.filter { $0.slot == slot || ($0.entity != nil && $0.entity == keep) }
    }

    func answerCore(_ it: TimelineIntent, query: String) -> TimelineAnswer {
        guard uses.isOn(it.predicate, .timeline) else { return .none(.unknown) }   // §11.10
        guard let eps = slotted(it) else { return .none(.ambiguous) }
        switch it.op {
        case .before, .after:
            guard let anchor = it.anchor else { return .none(.ambiguous) }
            // Episode cues come from the operator phrase alone ("before Acme the second time").
            let direction: TimelineDirection = it.op == .before ? .before : .after
            let got = before(it.predicate, anchor, query: it.phrase ?? query, direction: direction, episodes: eps,
                             anchorDate: it.anchorDate, boundary: it.anchorBoundary, slot: it.slot, strictTrust: true, stint: it.stint)
            // Holders that may be one entity under two names: an answer naming one of them is told (it would name half
            // of it); otherwise the answer stands only if it's the same with each group read as one entity.
            let groups = splitGroups(it.predicate)
            if groups.isEmpty || got.entities.isEmpty { return got }
            let split = Set(groups.flatMap { $0 })
            if got.entities.contains(where: split.contains) { return .none(.ambiguous) }
            let (m, rep) = merging(it.predicate, groups)
            var mAnchor = anchor
            if case .entity(let x) = anchor { mAnchor = .entity(rep[x] ?? x) }
            var mit = it
            mit.anchor = mAnchor
            guard let meps = m.slotted(mit) else { return .none(.ambiguous) }
            let alt = m.before(it.predicate, mAnchor, query: it.phrase ?? query, direction: direction, episodes: meps,
                               anchorDate: it.anchorDate, boundary: it.anchorBoundary, slot: it.slot, strictTrust: true, stint: it.stint)
            // The same entity on the same basis (a gap or an inference the merged reading tells is a different answer).
            return alt.entities == got.entities.map { rep[$0] ?? $0 } && alt.basis == got.basis ? got : .none(.ambiguous)
        case .year:
            guard case .date(let rng) = it.anchor else { return .none(.ambiguous) }
            return inRange(it.predicate, rng, episodes: eps, strictTrust: true)
        case .atStart, .endedBefore:
            return atStart(it, episodes: eps)
        case .first:
            return firstHeld(it, episodes: eps)
        case .current, .previous:
            let now = eps.filter { $0.ongoing && !$0.inferredEnd }
            if it.op == .previous {
                // As for "current": an episode that may have ended (or not) leaves the anchor unknown.
                guard now.count == 1, !eps.contains(where: \.mayBeOpen) else { return .none(.ambiguous) }
                let (got, basis) = order(it.predicate, eps, now[0], .before, strictTrust: true)
                let split = maybeSplit(it.predicate)
                if [now[0].entity, got].contains(where: { $0.map(split.contains) ?? false }) { return .none(.ambiguous) }
                return .one(got, basis)
            }
            if now.isEmpty || eps.contains(where: \.mayBeOpen) { return .none(.ambiguous) }
            if refusesTogether(it.predicate, now) { return .none(.ambiguous) }
            if now.contains(where: { !$0.trusted }) { return .none(.ambiguous) }   // resting on untrusted text (13e.1)
            let basis: TimelineBasis = now.allSatisfy { $0.heldAt != nil && $0.trusted && $0.startTrusted } ? .ordered : .inferred
            var ids: [String] = []
            for e in now { if let id = e.entity, !ids.contains(id) { ids.append(id) } }
            if ids.count > 1 { ids.sort { (entities[$0]?.seq ?? 0) < (entities[$1]?.seq ?? 0) } }
            return TimelineAnswer(entities: ids, basis: basis)
        }
    }

    /// The anchor's episode a comparison means: its stint by number, else its only one (trusted ones first).
    private func anchorEpisode(_ it: TimelineIntent, _ eps: [Episode]) -> Episode? {
        guard case .entity(let x) = it.anchor else { return nil }
        let all = eps.filter { $0.entity == x }.stableSorted { $0.sortKey }
        let mine = all.contains(where: \.trusted) ? all.filter(\.trusted) : all
        if let n = it.stint { return (1...max(1, mine.count)).contains(n) && n <= mine.count ? mine[n - 1] : nil }
        return mine.count == 1 ? mine[0] : nil
    }

    /// `atStart`: who the user was still with just before the anchor began (the day before its start, at the start's
    /// precision), the anchor excluded; every holder that may have held then must certainly have. `endedBefore`: the
    /// job that had certainly ended before the anchor began, the latest such; told when another job's end may fall on
    /// either side of that start, or may be later than the answer's (13e.2's fix round).
    func atStart(_ it: TimelineIntent, episodes eps: [Episode]) -> TimelineAnswer {
        guard case .entity(let x) = it.anchor, let sx = anchorEpisode(it, eps), let s = sx.tstart, sx.startTrusted else {
            return .none(.ambiguous)
        }
        let others = eps.filter { $0.entity != nil && $0.entity != x }
        if it.op == .atStart {
            let rng = DateRange(lo: s.lo - 1, hi: max(s.lo - 1, s.hi - 1), precision: .day)
            return inRange(it.predicate, rng, episodes: others, strictTrust: true)
        }
        var ended: [(e: Episode, end: DateRange)] = []
        for e in others {
            if let st = e.tstart, st.lo >= s.hi { continue }          // began with or after the anchor: never left before
            if e.mayBeOpen { return .none(.ambiguous) }
            guard let end = e.end else {
                if e.ongoing { continue }                             // still held: not left
                return .none(.ambiguous)                              // ended, but nobody knows when
            }
            if end.hi < s.lo { ended.append((e, end)) } else if end.lo < s.hi { return .none(.ambiguous) }
        }
        guard let w = ended.firstMax(by: { $0.end.hi }) else { return .none(.ambiguous) }
        if ended.contains(where: { $0.e.entity != w.e.entity && $0.end.hi >= w.end.lo }) { return .none(.ambiguous) }
        let inferred = !w.e.endTrusted || w.e.inferredEnd || !w.e.trusted || !sx.trusted
        return .one(w.e.entity, inferred ? .inferred : .ordered)
    }

    /// `first`: the earliest job recorded; told when another may have begun as early (an unknown start included).
    func firstHeld(_ it: TimelineIntent, episodes eps: [Episode]) -> TimelineAnswer {
        let named = eps.filter { $0.entity != nil }
        guard let w = named.filter({ $0.tstart != nil }).firstMin(by: { $0.tstart!.lo }), let ws = w.tstart else { return .none(.ambiguous) }
        for c in named where c.entity != w.entity {
            guard let cs = c.tstart, cs.lo > ws.hi else { return .none(.ambiguous) }
        }
        return .one(w.entity, w.startTrusted && w.trusted ? .ordered : .inferred)
    }
}
