import Foundation
import FunesProtocol

/// The demo vault's People & history (13d.2), for App Review and the UI snapshots: a few made-up people, employers and a
/// place, linked to the demo's own memories, your timeline and To check. In memory only; Not <name> and Not this apply
/// to the demo alone.
public enum DemoPeople {
    /// Which of the Mac's states the demo shows (the snapshots pick one).
    public enum Mode: String, Sendable {
        /// Every use on: the full timeline, with dates and bases.
        case on
        /// What ships while no model has passed the timeline's tests: only your own entries on the timeline.
        case timelineOff = "timeline-off"
        /// Facts off on the "Mac": nothing is sent.
        case factsOff = "facts-off"
    }

    static let revision = "demo.1"
    static let token = "demo"

    struct State: Sendable {
        var mode: Mode
        /// Memory titles → ids in the demo vault.
        var memories: [String: UUID]
        var rejectedLinks: Set<String> = []
        var rejectedFacts: Set<String> = []
        var counter = 1

        var revision: String { DemoPeople.revision + "." + String(counter) }
    }

    struct Entity {
        var entry: PeopleEntry
        var aliases: [PeopleEntityResult.Alias] = []
        var facts: [PeopleFact] = []
        /// Memory titles, each with its why line.
        var memories: [(title: String, why: String?)] = []
    }

    static func day(_ y: Int, _ m: Int = 1, _ d: Int = 1) -> Int { PeopleDay.number(year: y, month: m, day: d) }
    static func year(_ y: Int) -> PeopleDateRange { PeopleDateRange(lo: day(y), hi: day(y, 12, 31), precision: .year) }
    static func month(_ y: Int, _ m: Int) -> PeopleDateRange {
        PeopleDateRange(lo: day(y, m), hi: day(y, m) + 27, precision: .month)
    }

    static func entities(_ state: State) -> [Entity] {
        let on = state.mode == .on
        func fact(_ id: String, _ predicate: String, _ attribute: String, label: String? = nil, status: PeopleFactStatus = .current,
                  basis: PeopleBasis = .named, recordedOnly: Bool = false, dated: Bool = false, episodes: [PeopleEpisode] = []) -> PeopleFact {
            PeopleFact(factID: id, predicate: predicate, attribute: attribute, label: label, status: status, basis: basis,
                       recordedOnly: recordedOnly, dated: dated, episodes: episodes,
                       notThis: FactsCorrectionTarget(what: .fact, factID: id, token: token, label: "Not this"))
        }
        let northwindEpisode = episodes(state).first { $0.entityID == "e-northwind" }
        let contosoEpisode = episodes(state).first { $0.entityID == "e-contoso" }
        var all = [
            Entity(entry: PeopleEntry(id: "e-sam", kind: "person", name: "Sam",
                                      fact: .init(attribute: "your partner", status: .current), mentions: 3, aliases: ["my partner"]),
                   aliases: [.init(alias: "Sam", memories: 1), .init(alias: "my partner", memories: 2)],
                   facts: [fact("f-sam", "partner", "your partner", label: "partner")],
                   memories: [("Prefers trains to short flights", "my partner → Sam (the only partner Funes knows)"),
                              ("Flat lease renews in March", "my partner → Sam (the only partner Funes knows)"),
                              ("Coffee and tea", nil)]),
            Entity(entry: PeopleEntry(id: "e-northwind", kind: "organization", name: "Northwind",
                                      fact: .init(attribute: "where you work", status: .current, since: on ? month(2022, 3) : nil),
                                      mentions: 4, aliases: ["my job"], manual: !on),
                   aliases: [.init(alias: "Northwind", memories: 3), .init(alias: "my job", memories: 1)],
                   facts: [fact("f-northwind", "works_at", "where you work", basis: on ? .named : .confirmed, dated: true,
                                episodes: northwindEpisode.map { [$0] } ?? [])],
                   memories: [("Team uses trunk-based development", nil), ("Mornings are for deep work", nil),
                              ("Old phone number", nil), ("Conference talk accepted", nil)]),
            Entity(entry: PeopleEntry(id: "e-parents", kind: "person", group: .init(attribute: "your parents"), mentions: 2),
                   facts: [fact("f-parents", "parent", "your parents", label: "parents")],
                   memories: [("Vegetarian, eats fish", "your parents"), ("Monthly budget review", "your parents")]),
            Entity(entry: PeopleEntry(id: "e-fabrikam", kind: "organization", name: "Fabrikam",
                                      fact: .init(attribute: "your client", status: .current, recordedOnly: true), mentions: 2),
                   aliases: [.init(alias: "Fabrikam", memories: 2)],
                   facts: [fact("f-fabrikam", "client", "your client", recordedOnly: true)],
                   memories: [("Never share client names", nil), ("Ask before sending email", nil)]),
            Entity(entry: PeopleEntry(id: "e-lisbon", kind: "place", name: "Lisbon", mentions: 1),
                   aliases: [.init(alias: "Lisbon", memories: 1)],
                   memories: [("Conference talk accepted", nil)]),
        ]
        if on {
            all.insert(Entity(entry: PeopleEntry(id: "e-contoso", kind: "organization", name: "Contoso",
                                                 fact: .init(attribute: "where you worked", status: .former, until: year(2021)), mentions: 2),
                              aliases: [.init(alias: "Contoso", memories: 2)],
                              facts: [fact("f-contoso", "works_at", "where you worked", status: .former, dated: true,
                                           episodes: contosoEpisode.map { [$0] } ?? [])],
                              memories: [("Team uses trunk-based development", nil), ("Reading list: systems design", nil)]),
                       at: 2)
        }
        // Corrections made in the demo.
        return all.map { e in
            var e = e
            e.facts.removeAll { state.rejectedFacts.contains($0.factID) }
            e.memories.removeAll { state.rejectedLinks.contains(linkID(e.entry.id, $0.title)) }
            e.entry.mentions = e.memories.count
            if e.facts.isEmpty { e.entry.fact = nil }
            return e
        }.filter { $0.entry.mentions > 0 || !$0.facts.isEmpty }
    }

    static func linkID(_ entity: String, _ title: String) -> String { entity + "/" + title }

    static func episodes(_ state: State) -> [PeopleEpisode] {
        guard state.mode == .on else {
            // Timeline off: only your own entry, as you entered it.
            return [PeopleEpisode(id: "ep-northwind", factID: "f-northwind", entityID: "e-northwind", name: "Northwind",
                                  start: year(2022), ongoing: true, yours: true, yourDates: true)]
        }
        return [
            PeopleEpisode(id: "ep-northwind", factID: "f-northwind", entityID: "e-northwind", name: "Northwind", start: month(2022, 3),
                          ongoing: true, kind: "employee",
                          titles: [.init(title: "Engineer"), .init(title: "Senior engineer", from: year(2024))], stating: 3,
                          previous: .init(gapMonths: 8)),
            PeopleEpisode(id: "ep-contoso", factID: "f-contoso", entityID: "e-contoso", name: "Contoso", start: year(2018),
                          end: month(2021, 7), former: true, kind: "employee", titles: [.init(title: "Developer")], stating: 2),
        ].filter { !state.rejectedFacts.contains($0.factID) }
    }

    static func status(_ state: State) -> PeopleStatus {
        state.mode == .factsOff ? PeopleStatus(shown: false) : PeopleStatus(shown: true, factsRevision: state.revision)
    }

    static func directory(_ state: State) throws(CompanionError) -> PeopleDirectoryResult {
        guard state.mode != .factsOff else { throw CompanionError(.notFound, reason: PeopleUnavailable.factsOff) }
        return PeopleDirectoryResult(
            entries: entities(state).map(\.entry).sorted { $0.mentions > $1.mentions },
            kinds: ["organization", "person", "place", "thing"],
            timeline: [.init(predicate: "works_at", noun: "job", on: state.mode == .on, episodes: episodes(state))],
            toCheck: state.mode == .on ? [
                PeopleToCheckItem(id: "tc-manager", link: .init(memoryID: state.memories["Team uses trunk-based development"] ?? UUID(),
                                                                memoryTitle: "Team uses trunk-based development", surface: "my manager",
                                                                role: true, candidates: ["Alex", "Priya"])),
                PeopleToCheckItem(id: "tc-merge", merge: .init(names: ["Sam", "Samantha"])),
            ] : [],
            learning: true, factsRevision: state.revision)
    }

    static func page(_ id: String, _ state: State) throws(CompanionError) -> PeopleEntityResult {
        guard state.mode != .factsOff else { throw CompanionError(.notFound, reason: PeopleUnavailable.factsOff) }
        guard let e = entities(state).first(where: { $0.entry.id == id }) else { throw CompanionError(.notFound) }
        let name = e.entry.name ?? e.entry.group?.attribute ?? ""
        let rows = e.memories.compactMap { m -> PeopleMemoryRow? in
            guard let mid = state.memories[m.title] else { return nil }
            return PeopleMemoryRow(memoryID: mid, title: m.title, updatedAt: Date(timeIntervalSince1970: 1_790_000_000), why: m.why,
                                   notName: FactsCorrectionTarget(what: .name, linkID: linkID(e.entry.id, m.title), memoryID: mid,
                                                                  token: token, label: "Not \(name)"))
        }
        return PeopleEntityResult(entry: e.entry, aliases: e.aliases, facts: e.facts, memories: rows, factsRevision: state.revision)
    }

    /// `facts.reject` on a demo target.
    static func reject(_ t: FactsCorrectionTarget, _ state: inout State) throws(CompanionError) -> FactsRejectResult {
        guard t.token == token else { throw CompanionError(.notFound) }
        switch t.what {
        case .name: if let id = t.linkID { state.rejectedLinks.insert(id) }
        case .fact: if let id = t.factID { state.rejectedFacts.insert(id) }
        default: throw CompanionError(.invalidInput)
        }
        state.counter += 1
        return FactsRejectResult(factsRevision: state.revision, peopleRevision: state.revision)
    }
}
