import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// People & history on the iPhone (05-ux-iphone.md, companion protocol §4.3, 13d.2): the model reads the Mac live, keeps
/// nothing past the screen, follows the revision without looping, and corrects only through `facts.reject`.
@MainActor @Suite struct PeoplePhoneTests {
    static func entry(_ id: String, _ name: String, kind: String = "person", aliases: [String] = [], mentions: Int = 1) -> PeopleEntry {
        PeopleEntry(id: id, kind: kind, name: name, fact: .init(attribute: "your sister", status: .current), mentions: mentions, aliases: aliases)
    }

    static func directory(_ revision: String = "r1") -> PeopleDirectoryResult {
        PeopleDirectoryResult(entries: [entry("e1", "Maria", aliases: ["my sister"], mentions: 2), entry("e2", "Acme", kind: "organization"),
                                        entry("e3", "María José")],
                              kinds: ["organization", "person", "place", "thing"],
                              timeline: [.init(predicate: "works_at", noun: "job", on: false, episodes: [])],
                              toCheck: [PeopleToCheckItem(id: "t1", merge: .init(names: ["Maria", "Mari"])), PeopleToCheckItem(id: "t2")],
                              learning: true, factsRevision: revision)
    }

    static func page(_ revision: String = "r1") -> PeopleEntityResult {
        let memory = UUID()
        return PeopleEntityResult(entry: entry("e1", "Maria"), aliases: [.init(alias: "my sister", memories: 1)],
                                  facts: [PeopleFact(factID: "f1", predicate: "sibling", attribute: "your sister", status: .current, basis: .named,
                                                     notThis: FactsCorrectionTarget(what: .fact, factID: "f1", token: "t", label: "Not this"))],
                                  memories: [PeopleMemoryRow(memoryID: memory, title: "Mate", updatedAt: t0, why: "my sister → Maria",
                                                             notName: FactsCorrectionTarget(what: .name, linkID: "\(memory)/e1", memoryID: memory,
                                                                                            token: "t", label: "Not Maria"))],
                                  factsRevision: revision)
    }

    func model(_ vault: FakeVault) -> PeopleModel {
        vault.people = Self.directory()
        vault.pages = ["e1": Self.page()]
        return PeopleModel(caller: vault)
    }

    @Test func anOlderMacHidesTheEntryAndANewOneShowsIt() async {
        let vault = FakeVault()
        let m = model(vault)
        m.statusChecked(nil)
        #expect(!m.available)
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r1"))
        #expect(m.available)
    }

    @Test func theListIsFilteredHereWithTheMacsRules() async {
        let vault = FakeVault()
        let m = model(vault)
        await m.appeared()
        #expect(m.entries.count == 3 && m.toCheckCount == 1)
        m.query = "maria"
        #expect(m.entries.map(\.id) == ["e1", "e3"])       // accents ignored
        m.query = "SISTER"
        #expect(m.entries.map(\.id) == ["e1"])             // aliases count
        m.query = ""
        m.kinds = ["organization"]
        #expect(m.entries.map(\.id) == ["e2"])
        #expect(vault.calls.filter { $0 == .peopleDirectory }.count == 1)
    }

    @Test func aStatusRevisionReloadsWhatsOpenAndARepliesOnlyMarksTheOtherViewStale() async throws {
        let vault = FakeVault()
        let m = model(vault)
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r1"))
        await m.appeared()
        await m.openPage("e1")
        // A reply at another revision (a backfill moved it): the list is marked stale, not reloaded on the spot.
        vault.pages = ["e1": Self.page("r2")]
        await m.loadPage("e1")
        #expect(vault.calls.filter { $0 == .peopleDirectory }.count == 1)
        vault.people = Self.directory("r2")
        m.closePage("e1")
        await m.appeared()                       // the list shows again
        #expect(vault.calls.filter { $0 == .peopleDirectory }.count == 2 && m.directory?.factsRevision == "r2")
        // A status with a new revision reloads the open list once.
        vault.people = Self.directory("r3")
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r3"))
        await eventually { m.directory?.factsRevision == "r3" }
        #expect(m.directory?.factsRevision == "r3" && vault.calls.filter { $0 == .peopleDirectory }.count == 3)
        // The same revision again reads nothing.
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r3"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vault.calls.filter { $0 == .peopleDirectory }.count == 3)
    }

    @Test func factsOffClearsEverythingAndALateReplyStaysCleared() async throws {
        let vault = FakeVault()
        let m = model(vault)
        await m.appeared()
        await m.openPage("e1")
        // A slow reload is on its way when the Mac says Facts is off.
        vault.peopleDelay = .milliseconds(200)
        let late = Task { await m.load() }
        while !vault.peopleDelayTaken { await Task.yield() }
        m.statusChecked(PeopleStatus(shown: false))
        #expect(m.directory == nil && m.page == nil && m.phase == .closed(reason: PeopleUnavailable.factsOff))
        await late.value
        #expect(m.directory == nil && m.phase == .closed(reason: PeopleUnavailable.factsOff))
    }

    @Test func aStatusWhileTheFirstReadIsOnItsWayDropsItsOlderReply() async throws {
        let vault = FakeVault()
        let m = model(vault)
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r1"))
        vault.peopleDelay = .milliseconds(200)
        let first = Task { await m.appeared() }
        while !vault.peopleDelayTaken { await Task.yield() }
        vault.people = Self.directory("r2")
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r2"))
        await first.value
        await eventually { m.directory?.factsRevision == "r2" }
        #expect(m.directory?.factsRevision == "r2")
    }

    @Test func aPageClosedByFactsOffComesBackWhenFactsDoes() async throws {
        let vault = FakeVault()
        let m = model(vault)
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r1"))
        await m.appeared()
        await m.openPage("e1")
        m.statusChecked(PeopleStatus(shown: false))
        #expect(m.page == nil && m.pagePhase == .closed(reason: PeopleUnavailable.factsOff))
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r1"))
        await eventually { m.page != nil && m.directory != nil }
        #expect(m.page != nil && m.directory != nil && m.phase == .loaded)
    }

    @Test func aMemoryEditedFromAPageReloadsItWhenItShowsAgain() async {
        let vault = FakeVault()
        let m = model(vault)
        await m.appeared()
        await m.openPage("e1")
        m.memoryChanged()
        await m.openPage("e1")
        #expect(vault.calls.filter { $0 == .peopleGet }.count == 2)
    }

    @Test func clearedWhileOnScreenItReadsAgainOnTheNextStatus() async throws {
        let vault = FakeVault()
        let m = model(vault)
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r1"))
        await m.appeared()
        m.statusChecked(nil)                 // removed, or another Mac
        #expect(m.directory == nil && !m.available)
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r1"))
        await eventually { m.directory != nil }
        #expect(m.directory != nil && m.phase == .loaded)
    }

    @Test func aCorrectionAnsweredAfterTheScreenWentReadsNothingAndSaysNothing() async throws {
        let vault = FakeVault()
        let m = model(vault)
        var corrected = 0
        m.onCorrected = { corrected += 1 }
        await m.appeared()
        await m.openPage("e1")
        let target = m.page!.facts[0].notThis!
        let reads = vault.calls.count
        m.disappeared()
        await m.correct(target)
        #expect(corrected == 1 && vault.calls.count == reads + 1 && m.correctionFailure == nil && m.phase == .idle)
    }

    @Test func poppingAPageAfterACorrectionReadsTheListOnce() async throws {
        let vault = FakeVault()
        let m = model(vault)
        await m.appeared()
        await m.openPage("e1")
        await m.correct(m.page!.memories[0].notName!)
        m.closePage("e1")
        await m.appeared()
        try await Task.sleep(for: .milliseconds(50))
        #expect(vault.calls.filter { $0 == .peopleDirectory }.count == 2)
    }

    @Test func aGoneTargetReloadsWithoutAnAlert() async {
        let vault = FakeVault()
        let m = model(vault)
        await m.appeared()
        await m.openPage("e1")
        vault.fail(.factsReject, with: .method(CompanionError(.notFound)))
        await m.correct(m.page!.facts[0].notThis!)
        #expect(m.correctionFailure == nil && vault.calls.filter { $0 == .peopleGet }.count == 2)
    }

    @Test func namesBackAtTheSameRevisionReopensIt() async throws {
        let vault = FakeVault()
        let m = model(vault)
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r1"))
        await m.appeared()
        await m.openPage("e1")
        vault.fail(.peopleGet, with: .method(CompanionError(.notFound, reason: PeopleUnavailable.namesUnavailable)))
        await m.loadPage("e1")
        #expect(m.phase == .closed(reason: PeopleUnavailable.namesUnavailable) && m.page == nil)
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r1"))
        await eventually { m.phase == .loaded && m.page != nil }
        #expect(m.phase == .loaded && m.page != nil)
    }

    @Test func aStatusWithNoRevisionDropsAReplyOnItsWay() async throws {
        let vault = FakeVault()
        let m = model(vault)
        vault.peopleDelay = .milliseconds(200)
        let first = Task { await m.appeared() }
        while !vault.peopleDelayTaken { await Task.yield() }
        vault.peopleClosed = PeopleUnavailable.namesUnavailable
        m.statusChecked(PeopleStatus(shown: true))
        await first.value
        await eventually { m.phase == .closed(reason: PeopleUnavailable.namesUnavailable) }
        #expect(m.directory == nil && m.phase == .closed(reason: PeopleUnavailable.namesUnavailable))
    }

    @Test func namesStillUnreadableAreNotReadAgainAtEachStatus() async throws {
        let vault = FakeVault()
        let m = model(vault)
        vault.fail(.peopleDirectory, with: .method(CompanionError(.notFound, reason: PeopleUnavailable.namesUnavailable)))
        await m.appeared()
        #expect(m.phase == .closed(reason: PeopleUnavailable.namesUnavailable))
        let reads = vault.calls.count
        m.statusChecked(PeopleStatus(shown: true))
        m.statusChecked(PeopleStatus(shown: true))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vault.calls.count == reads)
        // Readable again (any revision, the same one included): read at once.
        m.statusChecked(PeopleStatus(shown: true, factsRevision: "r1"))
        await eventually { m.phase == .loaded }
        #expect(m.phase == .loaded)
    }

    @Test func aFactsOffReplyClosesIt() async {
        let vault = FakeVault()
        let m = model(vault)
        vault.people = nil
        await m.appeared()
        #expect(m.phase == .closed(reason: PeopleUnavailable.factsOff) && m.directory == nil)
    }

    @Test func leavingTheScreenDropsEverything() async {
        let vault = FakeVault()
        let m = model(vault)
        await m.appeared()
        await m.openPage("e1")
        m.query = "ma"
        m.disappeared()
        #expect(m.directory == nil && m.page == nil && m.query.isEmpty)
    }

    @Test func unreachableKeepsWhatsShownAndTellsTheBanner() async {
        let vault = FakeVault()
        let m = model(vault)
        var failures: [CompanionClientError] = []
        m.onFailure = { failures.append($0) }
        await m.appeared()
        vault.fail(.peopleDirectory, with: .unreachable(localNetworkDenied: false))
        await m.load()
        #expect(m.directory != nil && failures.count == 1)
    }

    @Test func aCorrectionReloadsThePageAndTellsSearch() async {
        let vault = FakeVault()
        let m = model(vault)
        var corrected = 0
        m.onCorrected = { corrected += 1 }
        await m.appeared()
        await m.openPage("e1")
        let target = try! #require(m.page?.memories.first?.notName)
        await m.correct(target)
        #expect(vault.corrections == [target] && corrected == 1 && m.correctionFailure == nil)
        #expect(m.page?.factsRevision == "r1+")
        #expect(vault.calls.filter { $0 == .peopleGet }.count == 2)
    }

    @Test func aRefusedCorrectionReloadsWithCurrentButtons() async {
        let vault = FakeVault()
        let m = model(vault)
        var corrected = 0
        m.onCorrected = { corrected += 1 }
        await m.appeared()
        await m.openPage("e1")
        vault.fail(.factsReject, with: .method(CompanionError(.targetChanged)))
        await m.correct(m.page!.facts[0].notThis!)
        #expect(corrected == 0 && vault.calls.filter { $0 == .peopleGet }.count == 2)
        if case .method = m.correctionFailure {} else { Issue.record("expected the Mac's refusal") }
        // Unreachable: nothing queued, nothing reloaded.
        vault.fail(.factsReject, with: .unreachable(localNetworkDenied: false))
        await m.correct(m.page!.facts[0].notThis!)
        #expect(vault.calls.filter { $0 == .peopleGet }.count == 2 && vault.corrections.isEmpty)
    }

    @Test func aCorrectionFromPeopleDropsSearchsHeldAnswer() async throws {
        let vault = FakeVault()
        vault.add("My sister drinks mate")
        vault.revision = "s1"
        let search = SearchModel(caller: vault)
        search.macAnswers = SearchAnswersStatus(engine: "Claude", locality: .cloud)
        search.query = "mate"
        await search.search()
        await search.ask()
        guard case .answered = search.answer else { Issue.record("no answer"); return }
        let m = model(vault)
        m.onCorrected = { search.factsCorrectedElsewhere() }
        await m.appeared()
        await m.openPage("e1")
        // Dropped as soon as the Mac accepts it, even while the page's reload is slow.
        vault.peopleDelay = .milliseconds(300)
        let correcting = Task { await m.correct(m.page!.facts[0].notThis!) }
        while !vault.peopleDelayTaken { await Task.yield() }
        #expect(search.answer == .idle)
        await correcting.value
        try await Task.sleep(for: .milliseconds(50))
        // Coming back to the same search doesn't bring the old answer back, and nothing is asked on its own.
        let asks = vault.asks.count
        await search.search()
        #expect(search.answer == .idle && vault.asks.count == asks)
    }

    @Test func wordsFollowTheMacs() {
        let r = PeopleDateRange(lo: PeopleDay.number(year: 2019, month: 1, day: 1), hi: PeopleDay.number(year: 2019, month: 12, day: 31), precision: .year)
        #expect(PeopleWording.date(r) == "2019")
        #expect(PeopleDay.civil(PeopleDay.number(year: 2021, month: 3, day: 15)).month == 3)
        #expect(PeopleDay.number(year: 1, month: 1, day: 1) == 1)
        let group = PeopleEntry(id: "g", kind: "person", group: .init(attribute: "your sisters", count: 2), mentions: 3)
        #expect(PeopleWording.name(group) == "Your sisters (2)")
        #expect(PeopleWording.name(PeopleEntry(id: "t", kind: "person", mentions: 0, tombstone: true)) == "Unnamed (Person)")
        #expect(PeopleWording.accessibility(Self.entry("e1", "Maria", mentions: 14)) == "Maria, Person, your sister, 14 memories")
        let recorded = PeopleFact(factID: "f", predicate: "client", attribute: "your client", status: .current, basis: .named, recordedOnly: true)
        #expect(PeopleWording.basisLine(recorded) == "Named in the memory · recorded only, not used in search")
        #expect(PeopleWording.question(PeopleToCheckItem(id: "x")) == nil)
    }

    @Test func theDemoShowsEachState() async throws {
        let on = DemoVault(people: .on)
        let d = try await on.call(PeopleDirectoryGet.self, EmptyParams())
        #expect(d.timeline.first?.on == true && !d.toCheck.isEmpty && d.entries.contains { $0.fact?.recordedOnly == true })
        let sam = try await on.call(PeopleGet.self, PeopleGetParams(entityID: "e-sam"))
        let target = try #require(sam.memories.first?.notName)
        _ = try await on.call(FactsReject.self, target)
        #expect(try await on.call(PeopleGet.self, PeopleGetParams(entityID: "e-sam")).memories.count == sam.memories.count - 1)
        let off = DemoVault(people: .timelineOff)
        let t = try await off.call(PeopleDirectoryGet.self, EmptyParams()).timeline[0]
        #expect(!t.on && t.episodes.allSatisfy(\.yours))
        let none = DemoVault(people: .factsOff)
        #expect(try await none.call(StatusGet.self, EmptyParams()).people == PeopleStatus(shown: false))
        await #expect(throws: CompanionClientError.self) { _ = try await none.call(PeopleDirectoryGet.self, EmptyParams()) }
    }

    /// Waits for what a status's own task does (it runs on its own), up to a few seconds on a loaded Mac.
    func eventually(_ condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
