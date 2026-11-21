import Foundation
import Testing
@testable import FunesProtocol

/// People & history's wire types (companion protocol §4.3, 13d.2): round trips, unknown codes from a newer Mac, an older
/// Mac's status, the shared filter and the day arithmetic.
@Suite struct CompanionPeopleTests {
    func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try CompanionJSON.decoder().decode(T.self, from: CompanionJSON.encoder().encode(value))
    }

    static let year2019 = PeopleDateRange(lo: PeopleDay.number(year: 2019, month: 1, day: 1),
                                          hi: PeopleDay.number(year: 2019, month: 12, day: 31), precision: .year)

    @Test func eachTypeRoundTrips() throws {
        let target = FactsCorrectionTarget(what: .fact, factID: "f1", token: "tok", label: "Not this")
        let episode = PeopleEpisode(id: "ep", factID: "f2", entityID: "e2", name: "Acme", start: Self.year2019, ongoing: true, kind: "employee",
                                    titles: [.init(title: "Engineer", from: Self.year2019)], stating: 2, previous: .init(gapMonths: 8))
        let entry = PeopleEntry(id: "e1", kind: "person", name: "Maria", fact: .init(attribute: "your sister", status: .current), mentions: 3,
                                aliases: ["my sister"], manual: true, hidden: false)
        let directory = PeopleDirectoryResult(entries: [entry], kinds: ["person"],
                                              timeline: [.init(predicate: "works_at", noun: "job", on: true, episodes: [episode])],
                                              toCheck: [PeopleToCheckItem(id: "t", link: .init(memoryID: UUID(), memoryTitle: "Budget", surface: "my boss",
                                                                                               role: true, candidates: ["Alex"]))],
                                              learning: true, reading: .init(done: 3, total: 9), factsRevision: "r")
        #expect(try roundTrip(directory) == directory)
        let page = PeopleEntityResult(entry: entry, aliases: [.init(alias: "Mari", memories: 2, yours: true)],
                                      facts: [PeopleFact(factID: "f1", predicate: "sibling", attribute: "your sister", label: "sister", status: .current,
                                                         basis: .named, episodes: [episode], notThis: target)],
                                      memories: [PeopleMemoryRow(memoryID: UUID(), title: "Mate", updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                                 why: "my sister → Maria", notName: target)],
                                      factsRevision: "r")
        #expect(try roundTrip(page) == page)
        #expect(try roundTrip(PeopleGetParams(entityID: "e1")) == PeopleGetParams(entityID: "e1"))
        let json = String(decoding: try CompanionJSON.encoder().encode(PeopleGetParams(entityID: "e1")), as: UTF8.self)
        #expect(json == #"{"entityId":"e1"}"#)
        #expect(try roundTrip(FactsRejectResult(factsRevision: "a", peopleRevision: "b")).peopleRevision == "b")
    }

    @Test func unknownCodesFromANewerMacDecode() throws {
        let json = #"""
        {"factId":"f","predicate":"p","attribute":"a","status":"engaged","basis":"oracle","recordedOnly":false,"dated":true,
         "episodes":[{"id":"x","factId":"f","entityId":"e","name":"N","start":{"lo":1,"hi":2,"precision":"fuzzy"},"ongoing":false,
         "former":false,"inferredEnd":false,"conflictStart":false,"conflictEnd":false,"untrusted":false,"titles":[],"stating":0,
         "yours":false,"yourDates":false}]}
        """#
        let f = try CompanionJSON.decoder().decode(PeopleFact.self, from: Data(json.utf8))
        #expect(f.status == .unknown && f.basis == .other && f.episodes[0].start?.precision == .unknown)
        let item = try CompanionJSON.decoder().decode(PeopleToCheckItem.self, from: Data(#"{"id":"q","hologram":{"x":1}}"#.utf8))
        #expect(item.link == nil && item.merge == nil && item.episode == nil)
    }

    @Test func anOlderMacsStatusHasNoPeopleAndAnOlderPhoneIgnoresIt() throws {
        let old = #"{"macName":"M","appVersion":"0.9","serverTime":1800000000000,"inboxPending":0,"vaultActive":true}"#
        #expect(try CompanionJSON.decoder().decode(CompanionStatus.self, from: Data(old.utf8)).people == nil)
        var status = CompanionStatus(macName: "M", appVersion: "0.10", serverTime: Date(), inboxPending: 0, vaultActive: true)
        status.people = PeopleStatus(shown: true, factsRevision: "r")
        #expect(try roundTrip(status).people == PeopleStatus(shown: true, factsRevision: "r"))
    }

    @Test func theCapabilityIsSentAndTheMacReadsIt() throws {
        #expect(CompanionCapability.current.contains(CompanionCapability.people))
        let plaintext = try CompanionRequest(PeopleDirectoryGet.self, params: EmptyParams(), caps: CompanionCapability.current).encoded()
        let head = try CompanionRequestHead(plaintext: plaintext)
        #expect(head.method == .peopleDirectory && head.showsPeople && head.showsFacts)
        #expect(CompanionMethod(rawValue: "people.get") == .peopleGet)
    }

    @Test func paramsAreChecked() {
        #expect(throws: CompanionError.self) { try PeopleGetParams(entityID: "").validate() }
        #expect(throws: CompanionError.self) { try PeopleGetParams(entityID: String(repeating: "x", count: 201)).validate() }
    }

    @Test func theFilterIsTheMacs() {
        func m(_ name: String, _ aliases: [String] = [], kind: String = "person", hidden: Bool = false, q: String, kinds: Set<String> = []) -> Bool {
            PeopleFilter.matches(name: name, aliases: aliases, kind: kind, hidden: hidden, query: q, kinds: kinds, showHidden: false)
        }
        #expect(m("María", q: " maria "))
        #expect(m("Maria", ["my sister"], q: "SIST"))
        #expect(!m("Maria", q: "", kinds: ["organization"]))
        #expect(!m("Maria", hidden: true, q: ""))
        #expect(PeopleFilter.matches(name: "Maria", aliases: [], kind: "person", hidden: true, query: "", kinds: [], showHidden: true))
    }

    @Test func daysAreOrdinals() {
        #expect(PeopleDay.number(year: 1, month: 1, day: 1) == 1)
        #expect(PeopleDay.number(year: 2019, month: 1, day: 1) == 737_060)        // Python's date(2019, 1, 1).toordinal()
        for day in [1, 59, 60, 737_060, 738_000, PeopleDateRange.maxDay] {
            let c = PeopleDay.civil(day)
            #expect(PeopleDay.number(year: c.year!, month: c.month!, day: c.day!) == day)
        }
    }
}
