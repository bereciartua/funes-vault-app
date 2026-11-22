import Foundation

// 13e.2, "the model answers, the time model checks" (ADR-0032 decisions 5 and 7, amended 2026-11-21; memory processing
// §10.3–§10.4): the answer model reads the question and states a comparison per claim; code decides when a claim owes a
// check, runs the time model directly on the trusted and the full graph, and words the checked line.

/// The comparison a claim states (memory processing §10.3's schema), as the model wrote it: entities are the rows'
/// aliases (`e1`…), dates are normalised to their written precision, and fields an operator doesn't use are empty.
/// Decoding is lenient: a missing or mistyped field reads as empty, which validation then refuses.
public struct TimelineComparison: Sendable, Hashable, Decodable {
    public var made: Bool
    /// "user", or "someone_else".
    public var subject: String
    public var predicate: String
    /// before, after, in, between, current or previous.
    public var op: String
    public var anchor: String
    /// first, second, any, or empty.
    public var stint: String
    public var anchorDate: String
    public var endDate: String
    public var slot: String
    public var answer: String

    public init(made: Bool = true, subject: String = "user", predicate: String, op: String, anchor: String = "", stint: String = "",
                anchorDate: String = "", endDate: String = "", slot: String = "", answer: String) {
        self.made = made
        self.subject = subject
        self.predicate = predicate
        self.op = op
        self.anchor = anchor
        self.stint = stint
        self.anchorDate = anchorDate
        self.endDate = endDate
        self.slot = slot
        self.answer = answer
    }

    enum CodingKeys: String, CodingKey { case made, subject, predicate, op = "operator", anchor, stint, anchorDate, endDate, slot, answer }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { ((try? c.decode(String.self, forKey: k)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        made = (try? c.decode(Bool.self, forKey: .made)) ?? false
        subject = s(.subject); predicate = s(.predicate); op = s(.op); anchor = s(.anchor); stint = s(.stint)
        anchorDate = s(.anchorDate); endDate = s(.endDate); slot = s(.slot); answer = s(.answer)
    }

    public static let operators = ["before", "after", "in", "between", "current", "previous"]
    public var aboutSomeoneElse: Bool { subject == "someone_else" }
}

/// The rows an answer reads for one *timeline* predicate (memory processing §10.3): its trusted episodes from the view
/// (the sendable projection for a cloud answer), at most `limit`, the search's entities first, then the most recent.
public struct TimelineRows: Sendable, Hashable {
    public static let limit = 12
    public static let citedLimit = 6
    public static let citedTextLimit = 1_000
    public static let citedTotalLimit = 6_000

    public struct Row: Sendable, Hashable {
        public var alias: String
        public var entity: String
        public var name: String
        /// Other names a trusted memory says it had ("also called"), oldest first.
        public var renames: [String]
        public var slot: String?
        /// As written to the model: a date at its precision, or "unknown" (none, or only untrusted text states it).
        public var start: String
        public var end: String
        /// The end is inferred (succession), not stated.
        public var inferredEnd: Bool
        public var ongoing: Bool
        /// Trusted memories stating it, newest first (memory ids as the store writes them).
        public var memoryIDs: [String]
    }

    public var predicate: String
    public var rows: [Row]

    public var isEmpty: Bool { rows.isEmpty }

    /// Alias → entity id.
    public var entities: [String: String] { Dictionary(rows.map { ($0.alias, $0.entity) }, uniquingKeysWith: { a, _ in a }) }

    /// Every name the rows give an entity, for "names a *timeline* entity".
    public var names: [String] { rows.flatMap { [$0.name] + $0.renames } }

    /// The trusted memories the rows cite, in the rows' order, each once.
    public var citedMemoryIDs: [String] {
        var seen = Set<String>(), out: [String] = []
        for r in rows { for m in r.memoryIDs where seen.insert(m).inserted { out.append(m) } }
        return out
    }

    /// Builds the rows from a graph whose `uses` the answer reads with. Untrusted-only episodes never appear, and a
    /// boundary only untrusted text states is "unknown" (§10.3). `first`: the search's entities, listed first.
    public static func build(_ view: FactsGraph, predicate: String, first: [String] = [], limit: Int = limit) -> TimelineRows {
        // From trusted evidence alone: an untrusted assertion never shapes a row's dates, slot, status or order.
        let graph = view.trustedOnly(predicate)
        let eps = graph.episodes(predicate).filter { $0.trusted && $0.entity != nil }
        let firstSet = Set(first)
        // Each entity's episodes stay together, in order; entities: the search's first, then by their latest episode.
        var byEntity: [String: [Episode]] = [:]
        for e in eps { byEntity[e.entity!, default: []].append(e) }
        func latest(_ id: String) -> Int { byEntity[id]!.map { $0.end?.hi ?? ($0.ongoing ? DateRange.maxDay : $0.sortKey) }.max() ?? 0 }
        let order = byEntity.keys.sorted { a, b in
            let (fa, fb) = (firstSet.contains(a), firstSet.contains(b))
            if fa != fb { return fa }
            let (la, lb) = (latest(a), latest(b))
            if la != lb { return la > lb }
            return (graph.entities[a]?.seq ?? 0, a) < (graph.entities[b]?.seq ?? 0, b)
        }
        var rows: [Row] = []
        for id in order {
            for e in byEntity[id]!.stableSorted(by: { $0.sortKey }) {
                guard rows.count < limit else { break }
                let names = graph.timelineNames(predicate, id)
                let name = graph.entities[id]?.name ?? names.first ?? id
                var seen = Set<String>()
                let mems = e.assertions.filter { $0.trusted && !$0.fromUser }.sorted { $0.written > $1.written }.map { $0.memoryID }
                    .filter { seen.insert($0).inserted }
                rows.append(Row(alias: "e\(rows.count + 1)", entity: id, name: name, renames: names.filter { $0 != name },
                                slot: e.slot == "_" ? nil : e.slot, start: written(e.startTrusted ? e.tstart : nil),
                                end: written(e.endTrusted ? e.end : nil), inferredEnd: e.inferredEnd, ongoing: e.ongoing,
                                memoryIDs: mems))
            }
        }
        // One alias per entity: an entity's second stint keeps the first's alias.
        var alias: [String: String] = [:]
        var n = 0
        for i in rows.indices {
            if let a = alias[rows[i].entity] { rows[i].alias = a } else { n += 1; alias[rows[i].entity] = "e\(n)"; rows[i].alias = "e\(n)" }
        }
        return TimelineRows(predicate: predicate, rows: rows)
    }

    /// A date at its written precision: "2019", "2019-03", "2019-03-15"; an inferred or bounded end as the latest it
    /// may be ("by 2021-06"); anything else "unknown".
    static func written(_ r: DateRange?) -> String {
        guard let r else { return "unknown" }
        switch r.precision {
        case .year: return String(format: "%04d", TimelineDates.civil(r.lo).y)
        case .month: let c = TimelineDates.civil(r.lo); return String(format: "%04d-%02d", c.y, c.m)
        case .day: let c = TimelineDates.civil(r.lo); return String(format: "%04d-%02d-%02d", c.y, c.m, c.d)
        case .inferred, .bound:
            guard r.hi < DateRange.maxDay else { return "unknown" }
            let c = TimelineDates.civil(r.hi)
            return String(format: "by %04d-%02d", c.y, c.m)
        case .handover, .conflict: return "unknown"
        }
    }

}

/// Day numbers back to dates (the inverse of `DayNumber.from`).
enum TimelineDates {
    static func civil(_ n: Int) -> (y: Int, m: Int, d: Int) {
        // Howard Hinnant's civil_from_days, on days since 1970-01-01.
        let z = n - 719_163 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

/// What the check decided for a claim (memory processing §10.4).
public struct TimelineCheckResult: Sendable, Hashable {
    public enum Verdict: String, Sendable, Hashable {
        /// The trusted and full graphs agree with the claim: it stands.
        case agrees
        /// Only the trusted graph agrees: it stands, "text you didn't write says otherwise".
        case agreesTrusted = "agrees_trusted"
        /// The trusted graph can't tell, or the comparison is missing, invalid, or several stints differ.
        case notSure = "not_sure"
        /// The trusted graph says otherwise: the claim is dropped.
        case disagrees
    }

    /// Why a claim is "not sure", for its wording.
    public enum Reason: String, Sendable, Hashable {
        case cantTell = "cant_tell"
        case noComparison = "no_comparison"
        case invalid
        case stints
        /// The local check on all of the owner's facts differs from the sendable one.
        case aboveLimit = "above_limit"
    }

    public var verdict: Verdict
    public var reason: Reason?
    /// The time model's basis on the trusted graph (`TimelineBasis` raw value), for an agreeing claim.
    public var basis: TimelineBasis?
    public var predicate: String
    public var op: String
    /// Entity ids: the anchor (nil for a date or none) and the answer.
    public var anchor: String?
    public var answer: String?
    /// The anchor's date (an "in" or "between" question), as the comparison normalised it.
    public var anchorDate: String?
    public var endDate: String?
    /// Several stints, each its answer (nil: can't tell), for a "not sure" by stints.
    public var stints: [String?] = []

    public var stands: Bool { verdict == .agrees || verdict == .agreesTrusted }
}

/// The check (memory processing §10.4), on graphs whose `uses` have the *timeline* use on for the answering model.
public struct TimelineCheck: Sendable {
    /// The view's graph: the sendable projection for a cloud answer, the whole graph on this Mac.
    public let graph: FactsGraph
    /// For a cloud answer, the owner's whole graph, for the local cross-check; nil on this Mac.
    public let local: FactsGraph?
    public let rows: TimelineRows

    public init(graph: FactsGraph, local: FactsGraph?, rows: TimelineRows) {
        self.graph = graph
        self.local = local
        self.rows = rows
    }

    /// The search's own stint cue on the anchor (the registry's episode and return cues), 1-based; nil without one, 0
    /// for cues that can't be met.
    static func searchStint(_ g: FactsGraph, predicate: String, anchor: String, search: String) -> Int?? {
        let mine = g.trustedOnly(predicate).episodes(predicate).filter { $0.entity == anchor }.stableSorted(by: { $0.sortKey })
        guard mine.count > 1 else { return .some(nil) }
        let cue = g.episodeCue(mine, query: search)
        if cue.cued { return cue.pick.flatMap { p in mine.firstIndex { $0 === p }.map { $0 + 1 } } ?? 0 }
        let q = FactsText.fold(search)
        if g.registry.language.returnCues.contains(where: { FactsText.cue(q, $0) }) { return mine.count }
        return .some(nil)
    }

    /// A normalised date, strictly: YYYY, YYYY-MM or YYYY-MM-DD with real calendar parts ("2019-02-31" isn't one).
    static func iso(_ s: String) -> DateRange? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count), parts[0].count == 4, let y = Int(parts[0]), (1900...2099).contains(y),
              parts.dropFirst().allSatisfy({ $0.count == 2 && Int($0) != nil }) else { return nil }
        if parts.count == 1 {
            guard let lo = DayNumber.from(year: y, month: 1, day: 1), let hi = DayNumber.from(year: y, month: 12, day: 31) else { return nil }
            return DateRange(lo: lo, hi: hi, precision: .year)
        }
        let m = Int(parts[1])!
        guard (1...12).contains(m), let first = DayNumber.from(year: y, month: m, day: 1) else { return nil }
        if parts.count == 2 { return DateRange(lo: first, hi: first + DayNumber.daysIn(year: y, month: m) - 1, precision: .month) }
        guard let day = DayNumber.from(year: y, month: m, day: Int(parts[2])!) else { return nil }
        return .day(day)
    }

    /// The intent a comparison states, or nil when it doesn't validate (§10.4): the user as subject, a registry
    /// operator, an anchor of this predicate's rows or a well-formed date, both endpoints for `between` (and no field an
    /// operator doesn't use), a known stint, a slot the predicate has, and an answer from the rows.
    func intent(_ c: TimelineComparison, stint: Int?) -> (TimelineIntent, answer: String)? {
        let reg = graph.registry
        guard c.made, c.subject == "user", c.predicate == rows.predicate, TimelineComparison.operators.contains(c.op),
              ["", "any", "first", "second"].contains(c.stint), let answer = rows.entities[c.answer] else { return nil }
        var slot: String?
        if !c.slot.isEmpty, c.slot != "any" {
            guard let p = reg.predicate(rows.predicate), let q = p.slot, p.qualifiers[q]?.values?.contains(c.slot) == true else { return nil }
            slot = c.slot
        }
        let pred = rows.predicate
        switch c.op {
        case "before", "after", "previous" where c.op != "previous" || !c.anchor.isEmpty:
            // "Previous" with an anchor ("my previous job before Ridge Data") is "before" it.
            let op: TimelineIntent.Operator = c.op == "after" ? .after : .before
            guard c.endDate.isEmpty else { return nil }
            if let a = rows.entities[c.anchor] {
                let date = c.anchorDate.isEmpty ? nil : Self.iso(c.anchorDate)
                if !c.anchorDate.isEmpty, date == nil { return nil }
                return (TimelineIntent(predicate: pred, op: op, anchor: .entity(a), phrase: "", slot: slot, anchorDate: date, stint: stint), answer)
            }
            guard c.anchor.isEmpty, let d = Self.iso(c.anchorDate) else { return nil }
            return (TimelineIntent(predicate: pred, op: op, anchor: .date(d), phrase: "", slot: slot), answer)
        case "in":
            guard c.anchor.isEmpty, c.endDate.isEmpty, let d = Self.iso(c.anchorDate) else { return nil }
            return (TimelineIntent(predicate: pred, op: .year, anchor: .date(d), phrase: "", slot: slot), answer)
        case "between":
            guard c.anchor.isEmpty, let a = Self.iso(c.anchorDate), let b = Self.iso(c.endDate), a.lo <= b.hi else { return nil }
            return (TimelineIntent(predicate: pred, op: .year, anchor: .date(DateRange(lo: a.lo, hi: b.hi, precision: .day)), phrase: "",
                                   slot: slot), answer)
        case "current", "previous":
            guard c.anchor.isEmpty, c.anchorDate.isEmpty, c.endDate.isEmpty else { return nil }
            return (TimelineIntent(predicate: pred, op: c.op == "current" ? .current : .previous, anchor: nil, phrase: "", slot: slot), answer)
        default:
            return nil
        }
    }

    /// Whether the time model's answer is the claim's: one entity for before, after and previous; among them for a date
    /// or "current" (several may hold). A stated rename is one entity.
    static func same(_ got: TimelineAnswer, _ answer: String, op: TimelineIntent.Operator, graph: FactsGraph, predicate: String) -> Bool {
        let want = graph.timelineEntity(predicate, answer)
        let ids = got.entities.map { graph.timelineEntity(predicate, $0) }
        switch op {
        case .before, .after, .previous: return ids.count == 1 && ids[0] == want
        case .year, .current: return ids.contains(want)
        }
    }

    enum Outcome: Equatable { case agrees(TimelineBasis), cantTell, disagrees }

    /// What one graph says about a comparison, with the whole stint procedure: an outcome, the entities it answered (as
    /// stand-ins, so two graphs compare), and per-stint answers when the stints differ.
    struct Evaluation: Equatable {
        var outcome: Outcome
        var entities: Set<String>
        var stints: [String?] = []
        /// The comparison didn't validate, or the search's stint cue can't be met / disagrees with the model's.
        var invalid = false
    }

    static func evaluate(_ g: FactsGraph, _ c: TimelineComparison, rows: TimelineRows, search: String,
                         intent: (TimelineComparison, Int?) -> (TimelineIntent, answer: String)?) -> Evaluation {
        let pred = rows.predicate
        let trusted = g.trustedOnly(pred)
        var stints: [Int?] = [nil]
        if let a = rows.entities[c.anchor], ["before", "after", "previous"].contains(c.op) {
            switch searchStint(g, predicate: pred, anchor: a, search: search) {
            case .some(.some(0)): return Evaluation(outcome: .cantTell, entities: [], invalid: true)
            case .some(.some(let n)):
                if let m = ["first": 1, "second": 2][c.stint], m != n { return Evaluation(outcome: .cantTell, entities: [], invalid: true) }
                stints = [n]
            default:
                let count = trusted.episodes(pred).filter { $0.entity == a }.count
                if count > 1 { stints = (1...count).map { $0 } }
            }
        }
        var per: [(Outcome, TimelineAnswer, TimelineIntent)] = []
        for s in stints {
            guard let (it, answer) = intent(c, s) else { return Evaluation(outcome: .cantTell, entities: [], invalid: true) }
            let got = g.answer(it, query: "")
            if got.entities.isEmpty || [.ambiguous, .unknown].contains(got.basis) { per.append((.cantTell, got, it)); continue }
            per.append((same(got, answer, op: it.op, graph: g, predicate: pred) ? .agrees(got.basis) : .disagrees, got, it))
        }
        func ids(_ a: TimelineAnswer) -> Set<String> { Set(a.entities.map { g.timelineEntity(pred, $0) }) }
        if per.count > 1 {
            let answers = per.map { $0.1.entity.map { g.timelineEntity(pred, $0) } }
            // Every stint can't tell: just "can't tell". Different answers: "not sure", naming each stint's.
            if answers.allSatisfy({ $0 == nil }) { return Evaluation(outcome: .cantTell, entities: []) }
            if Set(answers.map { $0 ?? "-" }).count > 1 || answers.contains(where: { $0 == nil }) {
                return Evaluation(outcome: .cantTell, entities: [], stints: per.map { $0.1.entity })
            }
        }
        let first = per[0]
        return Evaluation(outcome: first.0, entities: first.0 == .cantTell ? [] : ids(first.1))
    }

    /// Checks one comparison against the search it answers. The trusted graph decides; for a cloud answer the same
    /// procedure on all of the owner's trusted facts runs first, and any difference (its outcome or what it answers) is
    /// "not sure" (§10.4), whatever the sendable verdict was.
    public func check(_ c: TimelineComparison?, search: String) -> TimelineCheckResult {
        var base = TimelineCheckResult(verdict: .notSure, reason: .noComparison, basis: nil, predicate: rows.predicate,
                                       op: "", anchor: nil, answer: nil)
        guard let c, c.made else { return base }
        base.reason = .invalid
        // Only validated values go on the result (and so into the line).
        guard intent(c, stint: nil) != nil else { return base }
        base.op = c.op
        base.anchor = rows.entities[c.anchor]
        base.answer = rows.entities[c.answer]
        base.anchorDate = c.anchorDate.isEmpty ? nil : c.anchorDate
        base.endDate = c.endDate.isEmpty ? nil : c.endDate
        let pred = rows.predicate
        let mine = Self.evaluate(graph.trustedOnly(pred), c, rows: rows, search: search, intent: intent)
        if mine.invalid { return base }
        if let local {
            let theirs = Self.evaluate(local.trustedOnly(pred), c, rows: rows, search: search, intent: intent)
            if theirs != mine {
                base.reason = .aboveLimit
                return base
            }
        }
        if !mine.stints.isEmpty {
            base.reason = .stints
            base.stints = mine.stints
            return base
        }
        switch mine.outcome {
        case .cantTell:
            base.reason = .cantTell
            return base
        case .disagrees:
            base.verdict = .disagrees
            base.reason = nil
            return base
        case let .agrees(basis):
            base.basis = basis
            base.reason = nil
            // The full graph agrees when it gives the same answer; a different basis alone (an agent's date making an
            // inferred order ordered) isn't text saying otherwise.
            let full = Self.evaluate(graph, c, rows: rows, search: search, intent: intent)
            var agrees = false
            if case .agrees = full.outcome, full.entities == mine.entities { agrees = true }
            base.verdict = agrees ? .agrees : .agreesTrusted
            return base
        }
    }

    /// The fact ids a result rests on, answer first then anchor, each with its entity.
    public func facts(_ r: TimelineCheckResult, ids: [String: String]) -> [(entity: String, factID: String)] {
        [r.answer, r.anchor].compactMap { $0 }.compactMap { e in ids[FactStore.Loaded.key(rows.predicate, e)].map { (e, $0) } }
    }

    /// Every holder's names in the view (any trust, and beyond the rows' limit): a claim naming one owes a check.
    public static func holderNames(_ g: FactsGraph, predicate: String) -> [String] {
        let holders = Set(g.facts.filter { $0.predicate == predicate && !$0.negated }.map(\.entity))
        return holders.flatMap { id in (g.entities[id].map { [$0.name].compactMap { $0 } + Array($0.aliases) } ?? []) }
    }
}

/// The registry's operator and time cues (memory processing §10.4: before, after, since, until, now, previous, a return,
/// a year or a date) for when a claim owes a check. Bare prepositions ("in", "from", "de") and episode words ("first",
/// "again") aren't cues: they're in ordinary title, coworker and list answers.
enum AnswerTimeCues {
    static func words(_ reg: FactsRegistry) -> [String] {
        let l = reg.language
        let bounds = Set(l.timePrepositions).subtracting(l.yearPrepositions).subtracting(l.rangePrepositions)
        return l.operators.before + l.operators.after + l.operators.previous + l.operators.current + bounds.sorted() + l.returnCues
    }

    /// A year, or a date the registry's parser reads.
    static func hasDate(_ text: String, registry: FactsRegistry) -> Bool { DateParser(registry: registry).parse(text) != nil }

    static func has(_ text: String, registry: FactsRegistry) -> Bool {
        let q = FactsText.fold(text)
        return words(registry).contains { FactsText.cue(q, $0) } || hasDate(text, registry: registry)
    }

    /// A claim's own selection by time, for a claim whose comparison said `made: false`: before, after, since, until or a
    /// return. Not a date, "now" or "last": "your last title at Birch was…" and "from 2015 to 2018" are qualifiers.
    static func selects(_ text: String, registry: FactsRegistry) -> Bool {
        let l = registry.language
        let bounds = Set(l.timePrepositions).subtracting(l.yearPrepositions).subtracting(l.rangePrepositions)
        let q = FactsText.fold(text)
        return (l.operators.before + l.operators.after + bounds.sorted() + l.returnCues).contains { FactsText.cue(q, $0) }
    }
}
