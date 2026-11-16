import Foundation

/// One stretch of time a fact held (memory processing §11.5). Derived from assertions on every read, never stored.
/// A class, because succession and the ordering rule compare episodes by identity.
public final class Episode {
    public let entity: String?          // nil for a date anchor
    public let predicate: String
    public internal(set) var start: DateRange?
    public internal(set) var end: DateRange?      // stated, a bound ("ended by the memory that says so"), or inferred
    public internal(set) var conflictStart = false
    public internal(set) var conflictEnd = false
    public internal(set) var startTrusted = true
    public internal(set) var endTrusted = true
    public internal(set) var trusted = true
    public internal(set) var heldAt: Int?         // the latest day a memory says it holds
    public internal(set) var former = false       // stated as ended
    public internal(set) var slot = "_"
    public internal(set) var inferredEnd = false
    public internal(set) var assertions: [FactAssertion] = []
    public internal(set) var endedBy: Episode?    // the episode whose start ended this one by succession
    public internal(set) var uncertain = false    // an undated "no longer" may have ended it
    public internal(set) var uncertainFrom: Int?

    init(entity: String?, predicate: String, start: DateRange? = nil, end: DateRange? = nil) {
        self.entity = entity
        self.predicate = predicate
        self.start = start
        self.end = end
    }

    /// The latest day its memories were written: orders an undated episode (an undated return) among the others.
    var writtenKey: Int?

    var sortKey: Int { start?.lo ?? end?.lo ?? writtenKey ?? DateRange.maxDay }

    public var handover: Bool { start?.precision == .handover }

    public var statedStart: Bool { [.year, .month, .day].contains(start?.precision) }

    /// The start the timeline may use: a hand-over's assumed start is for role resolution only.
    public var tstart: DateRange? { handover ? nil : start }

    /// No end known and not stated as ended: as far as Funes knows, it holds.
    public var ongoing: Bool { end == nil && !former && !uncertain }

    /// Whether it may hold at some day of `d`.
    func mayHold(_ d: DateRange) -> Bool {
        !(end.map { $0.hi < d.lo } ?? false) && !(tstart.map { $0.lo > d.hi } ?? false)
    }

    /// Whether it certainly holds through all of `d`.
    func certainlyHolds(_ d: DateRange) -> Bool {
        guard let s = tstart, s.hi <= d.lo else { return false }
        return ongoing || (end.map { $0.lo >= d.hi } ?? false)
    }
}

extension FactsGraph {
    typealias Dated = (range: DateRange, assertion: FactAssertion)

    /// Ranges memories assert for one boundary → (range, conflict, trusted). Untrusted ranges count only when no
    /// trusted memory states that boundary.
    static func combine(_ pairs: [Dated]) -> (DateRange?, Bool, Bool) {
        let user = pairs.filter { $0.assertion.fromUser }
        if !user.isEmpty, user.count < pairs.count { return combine(user) }   // the user's own dates win
        let tr = pairs.filter { $0.assertion.trusted }.map(\.range)
        let use = tr.isEmpty ? pairs.map(\.range) : tr
        guard !use.isEmpty else { return (nil, false, true) }
        let lo = use.map(\.lo).max()!, hi = use.map(\.hi).min()!
        if lo > hi {
            return (DateRange(lo: use.map(\.lo).min()!, hi: use.map(\.hi).max()!, precision: .conflict), true, !tr.isEmpty)
        }
        let narrow = use.firstMin { $0.hi - $0.lo }!
        return (DateRange(lo: lo, hi: hi, precision: narrow.precision), false, !tr.isEmpty)
    }

    func isRejoin(_ a: FactAssertion) -> Bool {
        let q = FactsText.fold(a.quote)
        return registry.language.episodeLast.contains { FactsText.cue(q, $0) }
    }

    private final class Building {
        var starts: [Dated] = []
        var ends: [Dated] = []
        var rows: [Row] = []
        var uncertain: Int?
        var startRange: DateRange? { FactsGraph.combine(starts).0 }
        var endRange: DateRange? { FactsGraph.combine(ends).0 }
        /// The boundaries a row may be placed by: a trusted row sees only trusted boundaries, so untrusted text can
        /// never split a trusted episode or make one disjoint.
        func startRange(for trusted: Bool) -> DateRange? { FactsGraph.combine(trusted ? starts.filter(\.assertion.trusted) : starts).0 }
        func endRange(for trusted: Bool) -> DateRange? { FactsGraph.combine(trusted ? ends.filter(\.assertion.trusted) : ends).0 }
    }

    private struct Row {
        var order: Int            // position among the fact's assertions: their chronology
        var a: FactAssertion
        var s: DateRange?
        var e: DateRange?
        var bound: Int?
        var held: Int?
        var w: Int?
        var hand: DateRange?
    }

    /// A fact's episodes from what its memories assert, interval by interval. A new episode starts only when the dates
    /// are disjoint, or a memory says it's a return.
    func factEpisodes(_ f: LearnedFact) -> [Episode] {
        let p = parser
        let rows: [Row] = f.assertions.enumerated().map { order, a in
            let s = p.parse(a.start), e = p.parse(a.end), w = p.day(a.written)
            let hand = a.handover && s == nil && w != nil ? DateRange(lo: w!, hi: w!, precision: .handover) : nil
            let bound = a.status == .former && e == nil ? w : nil   // "time" (held in 2019) is never an end
            let held = a.status == .current ? w : nil
            return Row(order: order, a: a, s: s, e: e, bound: bound, held: held, w: w, hand: hand)
        }
        var eps: [Building] = []
        // Trusted (and the user's) rows are placed first, dated then undated; untrusted rows only afterwards. An
        // untrusted row may join an episode or start one of its own, but no trusted row lands in one it started.
        var untrustedOnly: [ObjectIdentifier] = []
        for pass in [true, false] {
            let mine = rows.filter { $0.a.selector == nil && $0.a.trusted == pass }
            for r in mine.filter({ $0.s != nil || $0.e != nil }).stableSorted(by: { ($0.s ?? $0.e)!.lo }) {
                var target: Building?
                for ep in eps.reversed() where !(r.a.trusted && untrustedOnly.contains(ObjectIdentifier(ep))) {
                    let es = ep.startRange(for: r.a.trusted), ee = ep.endRange(for: r.a.trusted)
                    var disjoint = false
                    if let ee, let s = r.s, ee.hi < s.lo { disjoint = true }
                    if let e = r.e, let es, e.hi < es.lo { disjoint = true }
                    if disjoint { continue }
                    if isRejoin(r.a), let s = r.s, let es, s.lo > es.hi { continue }
                    target = ep
                    break
                }
                let t = target ?? {
                    let b = Building()
                    eps.append(b)
                    if !pass { untrustedOnly.append(ObjectIdentifier(b)) }
                    return b
                }()
                if let s = r.s { t.starts.append((s, r.a)) }
                if let e = r.e { t.ends.append((e, r.a)) }
                t.rows.append(r)
            }
            // Undated rows in the order they were written: a "no longer" ends the stint that came before it.
            for var r in mine.filter({ $0.s == nil && $0.e == nil }).stableSorted(by: { $0.w ?? DateRange.maxDay }) {
                var target: Building?
                let candidates = eps.filter { !(r.a.trusted && untrustedOnly.contains(ObjectIdentifier($0))) }
                // The user's status with no dates and no selector is about the latest episode.
                if r.a.fromUser, r.a.status != .unknown, !candidates.isEmpty {
                    // latest by its dates, else by when its memories were written (an undated return)
                    target = candidates.firstMax { ep in
                        let tr = ep.rows.contains { $0.a.trusted }
                        return (ep.startRange ?? ep.endRange)?.lo
                            ?? ep.rows.filter { $0.a.trusted || !tr }.compactMap(\.w).max() ?? DateRange.minDay
                    }
                }
                // An undated return ("I rejoined Acme") is a new episode when every one so far has ended.
                // Only a return that says it holds now; a look back at one ("when I rejoined…") joins the latest stint.
                // Stints that hadn't begun by then don't count.
                let begun = candidates.filter { ep in (ep.startRange(for: r.a.trusted)?.lo).map { lo in r.w.map { lo <= $0 } ?? true } ?? true }
                if target == nil, isRejoin(r.a), r.bound == nil, r.held != nil, let w = r.w, !begun.isEmpty,
                   begun.allSatisfy({ ep in
                       let end = ep.endRange(for: r.a.trusted)?.hi ?? ep.rows.compactMap(\.bound).min()
                       return end.map { $0 <= w } ?? false            // every stint so far had ended by then
                   }) {
                    let b = Building()
                    eps.append(b)
                    if !pass { untrustedOnly.append(ObjectIdentifier(b)) }
                    target = b
                }
                if target == nil, let w = r.w {
                    if r.bound != nil {      // "no longer there": which episode it ended is decided only if just one fits
                        let ended = candidates.filter { ep in ep.endRange(for: r.a.trusted).map { $0.hi <= w } ?? false }
                        let open = candidates.filter { ep in
                            ep.endRange(for: r.a.trusted) == nil && (ep.startRange(for: r.a.trusted).map { $0.lo <= w } ?? true)
                        }
                        if !open.isEmpty, !ended.isEmpty, r.a.trusted {
                            for ep in open { ep.uncertain = min(ep.uncertain ?? w, w) }   // it may have ended by then
                            target = ended.last
                            r.bound = nil
                        } else if !ended.isEmpty {
                            target = ended.last
                        }
                    }
                    if target == nil {
                        for ep in candidates.reversed() {
                            let es = ep.startRange(for: r.a.trusted), ee = ep.endRange(for: r.a.trusted)
                            if (es.map { $0.lo <= w } ?? true), r.held == nil || ee == nil || ee!.hi >= w {
                                target = ep
                                break
                            }
                        }
                    }
                }
                if target == nil { target = candidates.first }
                let t = target ?? {
                    let b = Building()
                    eps.append(b)
                    if !pass { untrustedOnly.append(ObjectIdentifier(b)) }
                    return b
                }()
                t.rows.append(r)
            }
        }
        // A user's row with an episode selector goes to the one episode overlapping it, by the same boundaries the
        // episodes end up with (a bound counts as an end); the store sends the others to To check before they get here.
        for r in rows.filter({ $0.a.selector != nil }) {
            let sel = r.a.selector!
            // Matched against the boundaries the episode ends up with: trusted-only when it has a trusted row, a bound
            // as an end, a hand-over as a start.
            let hits = eps.filter { ep in
                let tr = ep.rows.contains { $0.a.trusted }
                let counts: (Row) -> Bool = { $0.a.trusted || !tr }
                let lo = FactsGraph.combine(ep.starts.filter { counts(Row(order: 0, a: $0.assertion)) }).0?.lo
                    ?? ep.rows.filter(counts).compactMap(\.hand).map(\.lo).min() ?? DateRange.minDay
                let hi = FactsGraph.combine(ep.ends.filter { counts(Row(order: 0, a: $0.assertion)) }).0?.hi
                    ?? ep.rows.filter(counts).compactMap(\.bound).min() ?? DateRange.maxDay
                return lo <= sel.hi && sel.lo <= hi
            }
            let t = hits.count == 1 ? hits[0] : { let b = Building(); eps.append(b); return b }()
            if let s = r.s { t.starts.append((s, r.a)) }
            if let e = r.e { t.ends.append((e, r.a)) }
            t.rows.append(r)
        }
        let slotKey = registry.predicate(f.predicate)?.slot
        var out: [Episode] = []
        for ep in eps {
            let trusted = ep.rows.contains { $0.a.trusted }
            // The user's own status wins: with one, only the user's rows say whether and when it held or ended.
            // The user's latest status (in the order the user entered them) wins, over memories and the user's own
            // earlier ones.
            let lastUserOrder = ep.rows.filter { $0.a.fromUser && $0.a.status != .unknown }.map(\.order).max()
            let lastUserStatus = lastUserOrder.flatMap { o in ep.rows.firstIndex { $0.order == o } }
            let userStatus = lastUserStatus != nil
            let userCurrent = lastUserStatus.map { ep.rows[$0].a.status == .current } ?? false
            let counts: (Row) -> Bool = { r in
                (r.a.trusted || !trusted) && (!userStatus || r.a.fromUser)
            }
            // Inside an episode with trusted evidence, untrusted boundaries never count: an untrusted start could
            // otherwise rule out a rival or narrow a bound (memory processing §11.5).
            var (start, cs, stTr) = Self.combine(ep.starts.filter { $0.assertion.trusted || !trusted })
            if start == nil {            // only a hand-over's assumed start (role resolution; the timeline ignores it)
                start = ep.rows.filter { $0.a.trusted || !trusted }.compactMap(\.hand).firstMin { $0.lo }
            }
            // When the user says it's current, only an end the user gave with that status, or after it, counts.
            let lastOrder = lastUserOrder ?? 0
            var (end, ce, enTr) = Self.combine(ep.ends.filter { pair in
                guard pair.assertion.trusted || !trusted else { return false }
                guard userCurrent else { return true }
                return ep.rows.contains { $0.a.fromUser && $0.order >= lastOrder && $0.e != nil && $0.a == pair.assertion }
            })
            // With a user status, only that latest row says whether and when it held or ended.
            let statusRows = ep.rows.indices.filter { i in counts(ep.rows[i]) && (lastUserStatus == nil || i == lastUserStatus) }
                .map { ep.rows[$0] }
            let boundRows = statusRows.filter { $0.bound != nil }
            let bounds = boundRows.compactMap(\.bound)
            let former = end != nil || !bounds.isEmpty
            let held = statusRows.compactMap(\.held)
            if end == nil, let minBound = bounds.min() {
                let stated = start?.precision != .handover ? start : nil
                let lo = ([stated?.lo ?? DateRange.minDay] + held.filter { $0 <= minBound }).max()!
                if lo > minBound {         // "no longer" written before the stated start: the memories disagree
                    end = DateRange(lo: minBound, hi: lo, precision: .conflict)
                    ce = true
                } else {
                    end = DateRange(lo: lo, hi: minBound, precision: .bound)   // ended after the last day it held
                    ce = false
                }
                enTr = boundRows.contains { $0.a.trusted }
            }
            // A trusted memory saying it still held after that end: the memories disagree (no return was stated).
            if let e = end, !userStatus, let late = held.max(), late > e.hi {
                end = DateRange(lo: e.lo, hi: late, precision: .conflict)
                ce = true
            }
            // The slot: the user's values first; in a trusted episode untrusted values never count (they could start
            // succession across slots).
            func values(_ rs: [Row]) -> [String] { slotKey.map { k in rs.compactMap { $0.a.qualifiers[k] } } ?? [] }
            var vals = values(ep.rows.filter(\.a.fromUser))
            if vals.isEmpty { vals = values(ep.rows.filter { $0.a.trusted || !trusted }) }
            let e = Episode(entity: f.entity, predicate: f.predicate, start: start, end: end)
            e.conflictStart = cs
            e.conflictEnd = ce
            e.startTrusted = stTr
            e.endTrusted = enTr
            e.trusted = trusted
            e.heldAt = held.max()
            e.former = former
            e.slot = vals.mostCommon() ?? "_"
            e.assertions = ep.rows.map(\.a)
            e.writtenKey = ep.rows.filter { $0.a.trusted || !trusted }.compactMap(\.w).max()   // trusted chronology only
            e.uncertain = ep.uncertain != nil && end == nil && !userStatus
            e.uncertainFrom = e.uncertain ? ep.uncertain : nil
            out.append(e)
        }
        if out.isEmpty {
            let e = Episode(entity: f.entity, predicate: f.predicate)
            e.trusted = f.trusted
            out.append(e)
        }
        return out.stableSorted { $0.sortKey }
    }

    /// Every episode of a predicate, with succession applied: within a slot, a stale current that was the only open
    /// one when the next started ends at the next one's start (`inferred`). Never on untrusted evidence, never for an
    /// episode stated as ended, never when a memory says it still held once the next had started.
    public func episodes(_ predicate: String) -> [Episode] {
        let eps = facts.filter { $0.predicate == predicate && !$0.negated }.flatMap { factEpisodes($0) }
        guard registry.predicate(predicate)?.succession == true else { return eps }
        // Succession runs over trusted episodes only: an untrusted one neither triggers nor blocks it.
        let trustedEps = eps.filter { $0.trusted && $0.startTrusted }
        for e in eps.stableSorted(by: { $0.sortKey }) {
            guard e.ongoing, let heldAt = e.heldAt, let es = e.tstart, e.trusted, e.startTrusted, !e.conflictStart else {
                continue                 // only a stale current: otherwise its end is just unknown
            }
            let later = trustedEps.filter { y in y.entity != e.entity && y.slot == e.slot && (y.tstart.map { $0.lo > es.hi } ?? false) }
            guard let y = later.firstMin(by: { $0.tstart!.lo }), let ys = y.tstart else { continue }
            if later.contains(where: { $0 !== y && $0.tstart!.overlaps(ys) }) { continue }
            if heldAt >= ys.lo { continue }
            // Concurrent: another trusted episode in the slot that may still have been open when y started (judged at
            // that date; an unknown start may be before it).
            let concurrent = trustedEps.contains { o in
                o !== e && o !== y && o.slot == e.slot && (o.tstart.map { $0.lo < ys.lo } ?? true)
                    && (o.end.map { $0.hi >= ys.lo } ?? true)
            }
            if concurrent { continue }
            e.end = DateRange(lo: ys.lo, hi: ys.hi, precision: .inferred)
            e.inferredEnd = true
            e.endedBy = y
        }
        return eps
    }

    /// "former" if the fact's latest episode ended, else "current".
    public func status(of f: LearnedFact) -> FactAssertion.Status {
        let eps = factEpisodes(f)
        return (eps.last(where: \.trusted) ?? eps.last)?.former == true ? .former : .current   // trusted evidence first
    }
}

extension Array {
    /// The first element with the smallest key (Python's `min(key=)`).
    func firstMin<K: Comparable>(by key: (Element) -> K) -> Element? {
        var best: Element?, bk: K?
        for x in self {
            let k = key(x)
            if bk == nil || k < bk! { best = x; bk = k }
        }
        return best
    }

    /// The first element with the largest key (Python's `max(key=)`).
    func firstMax<K: Comparable>(by key: (Element) -> K) -> Element? {
        var best: Element?, bk: K?
        for x in self {
            let k = key(x)
            if bk == nil || k > bk! { best = x; bk = k }
        }
        return best
    }

    /// Sorted by a key, keeping the original order among equal keys.
    func stableSorted<K: Comparable>(by key: (Element) -> K) -> [Element] {
        enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }
}

extension Array where Element: Hashable {
    /// The most common value, the earliest among ties (Python's `Counter.most_common(1)`).
    func mostCommon() -> Element? {
        var counts: [Element: Int] = [:]
        for x in self { counts[x, default: 0] += 1 }
        return firstMax { counts[$0]! }
    }
}
