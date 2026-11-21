import Foundation
import FunesPhone
import FunesProtocol
import GRDB
import Synchronization
import Testing
@_spi(FactsReview) @testable import FunesCore
@testable import FunesCompanion

/// What the Mac app gives the companion for People (13d.2): *Learn from memories* and the People configuration, which
/// a test changes between calls.
final class PeopleSwitch: Sendable {
    let state: Mutex<(learning: Bool, config: FactsSearchConfig?)>

    init(learning: Bool = true, config: FactsSearchConfig? = PeopleCompanionTests.everyDeclared) {
        state = Mutex((learning, config))
    }

    var people: CompanionPeople {
        CompanionPeople(learning: { self.state.withLock { $0.learning } }, config: { self.state.withLock { $0.config } })
    }

    func set(learning: Bool) { state.withLock { $0.learning = learning } }
    func set(config: FactsSearchConfig?) { state.withLock { $0.config = config } }
}

/// People & history on the iPhone (companion protocol §4.3, Phase 13 plan 13d.2): the Mac section's read, through the
/// real router and `CompanionClient`'s envelope, as data, gated, with corrections through `facts.reject`.
@Suite struct PeopleCompanionTests {
    static let reg = FactsRegistry.bundled
    static let sib = reg.predicates.first { $0.objectKind == "person" && $0.lexicon.contains { $0.words.contains("sister") } }!.id
    static let parent = reg.predicates.first { $0.objectKind == "person" && $0.lexicon.contains { $0.words.contains("parents") } }!.id
    static let client = reg.predicates.first { $0.uses == [FactsUse.recorded.rawValue] }!.id
    static let work = reg.timelinePredicates[0]
    static var everyDeclared: FactsSearchConfig {
        var c = FactsSearchConfig(engines: [:], userAliases: [], cloudLimit: .upTo(.internal))
        c.measuredUses = .everyDeclared(reg)
        return c
    }
    let caps = CompanionCapability.current

    struct Vault {
        var maria: UUID
        var sister: UUID
        var parents: UUID
        var globex: UUID
    }

    func memory(_ h: CompanionHarness, _ title: String, _ body: String) throws -> Memory {
        try h.store.createMemory(MemoryDraft(title: title, body: body, kind: .fact, categoryKeys: ["personal_preferences"], sensitivity: .low),
                                 now: t0)
    }

    func apply(_ h: CompanionHarness, _ m: UUID, _ x: FactsExtraction, predicate: String) throws {
        let version = try h.store.writer.read { db in try MemoryStore.fetch(db, id: m)!.version }
        try h.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.db, version: version, extraction: x, callGroup: Self.reg.predicate(predicate)!.callGroup,
                                registry: Self.reg, uses: .everyDeclared(Self.reg), now: t0)
        }
    }

    /// Maria (sister), a memory saying only "my sister", a role group, and a client.
    func vault(_ h: CompanionHarness) throws -> Vault {
        let m1 = try memory(h, "Maria is my sister", "We grew up in Porto together.")
        let m2 = try memory(h, "My sister drinks her mate bitter", "Every morning, with no sugar.")
        let m3 = try memory(h, "Dinner with my parents", "My parents cooked paella.")
        let m4 = try memory(h, "Globex invoice", "Globex is my client; invoice them in March.")
        try apply(h, m1.id, FactsExtraction(people: [ExtractedPerson(name: "Maria", quote: "Maria is my sister")],
                                            facts: [ExtractedFact(predicate: Self.sib, name: "Maria", label: "sister", quote: "Maria is my sister")]),
                  predicate: Self.sib)
        try apply(h, m2.id, FactsExtraction(), predicate: Self.sib)
        try apply(h, m3.id, FactsExtraction(facts: [ExtractedFact(predicate: Self.parent, name: "", entity: "group", label: "parents",
                                                                  quote: "My parents", count: 2)]), predicate: Self.parent)
        try apply(h, m4.id, FactsExtraction(facts: [ExtractedFact(predicate: Self.client, name: "Globex", quote: "Globex is my client")]),
                  predicate: Self.client)
        return Vault(maria: m1.id, sister: m2.id, parents: m3.id, globex: m4.id)
    }

    func directory(_ h: CompanionHarness, _ phone: CompanionHarness.Phone) async throws -> PeopleDirectoryResult {
        try await h.result(PeopleDirectoryGet.self, EmptyParams(), phone: phone, caps: caps)
    }

    func page(_ h: CompanionHarness, _ phone: CompanionHarness.Phone, _ id: String) async throws -> PeopleEntityResult {
        try await h.result(PeopleGet.self, PeopleGetParams(entityID: id), phone: phone, caps: caps)
    }

    // MARK: Round trips

    @Test func theDirectoryIsTheMacSectionsReadAsData() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        let d = try await directory(h, phone)
        let mac = try h.store.peopleDirectory(config: Self.everyDeclared)
        #expect(d.entries.map(\.id) == mac.filtered(query: "", kinds: [], showHidden: false).map(\.id))
        let maria = try #require(d.entries.first { $0.name == "Maria" })
        #expect(maria.fact?.attribute == "your sister" && maria.mentions == 2 && maria.kind == "person")
        let group = try #require(d.entries.first { $0.group != nil })
        #expect(group.name == nil && group.group?.count == 2)
        #expect(d.entries.first { $0.name == "Globex" }?.fact?.recordedOnly == true)
        #expect(d.learning && d.kinds == mac.kinds && !d.factsRevision.isEmpty)
        // The you entity is never sent.
        #expect(!d.entries.contains { $0.name == nil && $0.group == nil && $0.kind == "person" && !$0.tombstone })
    }

    @Test func aPageCarriesAliasesFactsAndMemoriesWithTheirCorrections() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        let v = try vault(h)
        let maria = try #require(try await directory(h, phone).entries.first { $0.name == "Maria" })
        let p = try await page(h, phone, maria.id)
        #expect(p.entry.id == maria.id && p.facts.count == 1)
        let fact = p.facts[0]
        #expect(fact.basis == .named && !fact.recordedOnly && fact.notThis?.what == .fact && fact.notThis?.memoryID == nil)
        #expect(fact.notThis?.label == "Not this" && fact.notThis?.token.isEmpty == false)
        #expect(Set(p.memories.map(\.memoryID)) == [v.maria, v.sister])
        let row = try #require(p.memories.first { $0.memoryID == v.sister })
        #expect(row.why?.lowercased().contains("my sister → maria") == true)
        #expect(row.notName?.what == .name && row.notName?.memoryID == v.sister && row.notName?.label == "Not Maria")
        // A recorded-only fact: shown, not used, its button still a fact target (the phone says Remove).
        let globex = try #require(try await directory(h, phone).entries.first { $0.name == "Globex" })
        let gp = try await page(h, phone, globex.id)
        #expect(gp.facts.first?.recordedOnly == true && gp.facts.first?.notThis != nil)
    }

    @Test func aHiddenEntityIsLeftOutOfTheListButReadableByID() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        let maria = try #require(try await directory(h, phone).entries.first { $0.name == "Maria" })
        try h.store.setHidden(maria.id, true, now: t0)
        #expect(try await directory(h, phone).entries.first { $0.id == maria.id } == nil)
        #expect(try await page(h, phone, maria.id).entry.hidden)
    }

    @Test func withTheTimelineOffOnlyYourEntriesShowWithNothingDerived() async throws {
        let switches = PeopleSwitch(config: .reviewShipped())
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        let m = try memory(h, "Acme years", "I worked at Acme from 2015 to 2017.")
        try apply(h, m.id, FactsExtraction(facts: [ExtractedFact(predicate: Self.work, name: "Acme", quote: "I worked at Acme from 2015 to 2017",
                                                                 start: "2015", end: "2017")]), predicate: Self.work)
        _ = try h.store.addManualEntry(PeopleManualEntry(kind: Self.reg.kindOf(Self.work), name: "Initech", predicate: Self.work,
                                                         start: "2019", end: "2021-06"), activity: h.activity, now: t0)
        let d = try await directory(h, phone)
        let section = try #require(d.timeline.first)
        #expect(!section.on && section.episodes.map(\.name) == ["Initech"])
        let ep = section.episodes[0]
        #expect(ep.yours && ep.yourDates && ep.previous == nil && !ep.inferredEnd)
        #expect(ep.start?.precision == .year && ep.end?.precision == .month)
        #expect(d.entries.first { $0.name == "Acme" }?.fact == nil)
    }

    // MARK: The gate

    @Test func withoutTheCapabilityItsInvalidAndStatusSaysNothing() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        await #expect { _ = try await h.result(PeopleDirectoryGet.self, EmptyParams(), phone: phone, caps: [CompanionCapability.facts]) }
            throws: { ($0 as? CompanionError)?.code == .invalidInput }
        #expect(try await h.result(StatusGet.self, EmptyParams(), phone: phone, caps: [CompanionCapability.facts]).people == nil)
        let status = try await h.result(StatusGet.self, EmptyParams(), phone: phone, caps: caps)
        #expect(status.people?.shown == true && status.people?.factsRevision != nil)
    }

    @Test func aMacWithoutPeopleSendsNoStatusAndKnowsNoMethod() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        #expect(try await h.result(StatusGet.self, EmptyParams(), phone: phone, caps: caps).people == nil)
        await #expect { _ = try await directory(h, phone) } throws: { ($0 as? CompanionError)?.code == .unknownMethod }
    }

    @Test func factsOffWithLearnedFactsStoredSendsNothingAndRefusesCorrections() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        let maria = try #require(try await directory(h, phone).entries.first { $0.name == "Maria" })
        let target = try #require(try await page(h, phone, maria.id).facts.first?.notThis)
        // Learning off with nothing of yours: the Mac shows its empty state, though every learned row is still stored.
        switches.set(learning: false)
        for call in [{ _ = try await directory(h, phone) }, { _ = try await page(h, phone, maria.id) }] as [() async throws -> Void] {
            await #expect { try await call() } throws: { e in
                let e = e as? CompanionError
                return e?.code == .notFound && e?.reason == PeopleUnavailable.factsOff
            }
        }
        let status = try await h.result(StatusGet.self, EmptyParams(), phone: phone, caps: caps)
        #expect(status.people == PeopleStatus(shown: false))
        // A stale target isn't applied with People's configuration (and search isn't using learned facts).
        await #expect { _ = try await h.result(FactsReject.self, target, phone: phone, caps: caps) }
            throws: { ($0 as? CompanionError)?.code == .notFound }
        #expect(try h.store.peopleDirectory(config: Self.everyDeclared).entries.first { $0.name == "Maria" }?.fact != nil)
        // Something of yours kept opens it again, with learning still off.
        try h.store.setHidden(maria.id, false, now: t0)
        #expect(try await directory(h, phone).learning == false)
    }

    @Test func learningTurnedOffWhileYourNamesAreReadIsNeverReadAsOn() async throws {
        let switches = PeopleSwitch()
        // The configuration's read (your names) is where the companion waits; learning goes off during it.
        let people = CompanionPeople(learning: { switches.state.withLock { $0.learning } }, config: {
            switches.set(learning: false)
            return switches.state.withLock { $0.config }
        })
        let h = try CompanionHarness(people: people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        await #expect { _ = try await directory(h, phone) } throws: { ($0 as? CompanionError)?.reason == PeopleUnavailable.factsOff }
    }

    @Test func learningTurnedOffJustAfterTheSwitchWasReadLetsNoDataOut() async throws {
        let switches = PeopleSwitch()
        // The switch reads on; by the time the read is done it's off (the main actor's answer, then a toggle).
        let reads = Mutex(0)
        let people = CompanionPeople(learning: { reads.withLock { $0 += 1; return $0 == 1 } }, config: { switches.state.withLock { $0.config } })
        let h = try CompanionHarness(people: people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        await #expect { _ = try await directory(h, phone) } throws: { ($0 as? CompanionError)?.reason == PeopleUnavailable.factsOff }
    }

    @Test func throughTheRealClientEveryCallCarriesTheCapability() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let clock = h.clock
        let client = CompanionClient(store: MemorySecretStore(), transport: PhoneClientTests.RouterTransport(harness: h),
                                     discovery: PhoneClientTests.NoBonjour(), secureEnclave: false, clock: { clock.now })
        async let paired = client.pair(await h.qr(), deviceName: "Sam's iPhone", model: "iPhone14,4")
        try await h.answerWhenAsked(true)
        _ = try await paired
        _ = try vault(h)
        #expect(try await client.status().status.people?.shown == true)
        let d = try await client.call(PeopleDirectoryGet.self, EmptyParams())
        let maria = try #require(d.entries.first { $0.name == "Maria" })
        let p = try await client.call(PeopleGet.self, PeopleGetParams(entityID: maria.id))
        let r = try await client.call(FactsReject.self, try #require(p.facts.first?.notThis))
        #expect(r.peopleRevision != d.factsRevision)
    }

    @Test func withPeopleClosedASearchCorrectionStillAppliesWithSearchsConfiguration() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        let maria = try #require(try await directory(h, phone).entries.first { $0.name == "Maria" })
        let target = try #require(try await page(h, phone, maria.id).facts.first?.notThis)
        switches.set(learning: false)
        h.services.search.facts = Self.everyDeclared       // learned facts still in search
        let r = try await h.result(FactsReject.self, target, phone: phone, caps: caps)
        let searchRevision = await h.services.search.factsRevision()
        #expect(r.peopleRevision == nil && r.factsRevision == searchRevision)
        #expect(try h.store.peopleDirectory(config: Self.everyDeclared).entries.first { $0.name == "Maria" }?.fact == nil)
    }

    @Test func unreadableNamesSendNothing() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        switches.set(config: nil)
        await #expect { _ = try await directory(h, phone) } throws: { e in
            (e as? CompanionError)?.reason == PeopleUnavailable.namesUnavailable
        }
        let status = try await h.result(StatusGet.self, EmptyParams(), phone: phone, caps: caps)
        #expect(status.people?.shown == true && status.people?.factsRevision == nil)
    }

    // MARK: Corrections from a page

    @Test func notNameFromAPageWorksWithSearchUseOffAndMovesTheRevision() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        let v = try vault(h)
        #expect(h.services.search.facts == nil)
        let before = try await directory(h, phone)
        let maria = try #require(before.entries.first { $0.name == "Maria" })
        let target = try #require(try await page(h, phone, maria.id).memories.first { $0.memoryID == v.sister }?.notName)
        let r = try await h.result(FactsReject.self, target, phone: phone, caps: caps)
        #expect(r.peopleRevision != nil && r.peopleRevision == r.factsRevision && r.peopleRevision != before.factsRevision)
        let after = try await page(h, phone, maria.id)
        #expect(!after.memories.contains { $0.memoryID == v.sister } && after.factsRevision == r.peopleRevision)
        // Listed under the Mac's Corrections, with its Undo.
        let mac = try #require(try h.store.peopleEntity(maria.id, config: Self.everyDeclared))
        #expect(mac.corrections.contains { $0.what == .linkRejected })
        #expect(h.activity.events.contains { $0.event == "facts_corrected" && $0.actor == "device:\(phone.deviceID!.db)" })
        // A repeat changes nothing more.
        #expect(try await h.result(FactsReject.self, target, phone: phone, caps: caps).peopleRevision == r.peopleRevision)
    }

    @Test func notNameOnAnOrganizationsName() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        let v = try vault(h)
        let globex = try #require(try await directory(h, phone).entries.first { $0.name == "Globex" })
        let target = try #require(try await page(h, phone, globex.id).memories.first { $0.memoryID == v.globex }?.notName)
        #expect(target.label == "Not Globex")
        _ = try await h.result(FactsReject.self, target, phone: phone, caps: caps)
        #expect(try await directory(h, phone).entries.first { $0.id == globex.id }?.mentions ?? 0 == 0)
    }

    @Test func notThisFromAPageRejectsTheFactEverywhere() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        let maria = try #require(try await directory(h, phone).entries.first { $0.name == "Maria" })
        let target = try #require(try await page(h, phone, maria.id).facts.first?.notThis)
        _ = try await h.result(FactsReject.self, target, phone: phone, caps: caps)
        #expect(try await page(h, phone, maria.id).facts.isEmpty)
        #expect(try await directory(h, phone).entries.first { $0.id == maria.id }?.fact == nil)
    }

    @Test func aStaleTokenIsRefused() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        let v = try vault(h)
        let maria = try #require(try await directory(h, phone).entries.first { $0.name == "Maria" })
        let target = try #require(try await page(h, phone, maria.id).memories.first { $0.memoryID == v.sister }?.notName)
        // The memory changed under the button (its version is in the token).
        try h.store.updateMemory(id: v.sister, MemoryEdit(body: "Every morning, with no sugar, in the blue cup."), now: t0)
        await #expect { _ = try await h.result(FactsReject.self, target, phone: phone, caps: caps) }
            throws: { ($0 as? CompanionError)?.code == .targetChanged }
    }

    @Test func aRenameOnTheMacAfterThePageWasReadRefusesItsButtons() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        let v = try vault(h)
        let maria = try #require(try await directory(h, phone).entries.first { $0.name == "Maria" })
        let p = try await page(h, phone, maria.id)
        let notName = try #require(p.memories.first { $0.memoryID == v.sister }?.notName), notThis = try #require(p.facts.first?.notThis)
        try h.store.renameEntity(maria.id, to: "María", activity: h.activity, now: t0)
        for target in [notName, notThis] {
            await #expect { _ = try await h.result(FactsReject.self, target, phone: phone, caps: caps) }
                throws: { ($0 as? CompanionError)?.code == .targetChanged }
        }
    }

    @Test func aMergeAfterThePageWasReadRefusesAnOldNotThis() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        let m = try memory(h, "Mari's birthday", "Mari is my sister; her birthday is in May.")
        try apply(h, m.id, FactsExtraction(people: [ExtractedPerson(name: "Mari", quote: "Mari is my sister")],
                                           facts: [ExtractedFact(predicate: Self.sib, name: "Mari", label: "sister", quote: "Mari is my sister")]),
                  predicate: Self.sib)
        let d = try await directory(h, phone)
        let maria = try #require(d.entries.first { $0.name == "Maria" }), mari = try #require(d.entries.first { $0.name == "Mari" })
        let target = try #require(try await page(h, phone, maria.id).facts.first?.notThis)
        try h.store.mergeEntity(mari.id, into: maria.id, activity: h.activity, now: t0)
        await #expect { _ = try await h.result(FactsReject.self, target, phone: phone, caps: caps) }
            throws: { ($0 as? CompanionError)?.code == .targetChanged }
        // A merged-away id reads as the entity it went into.
        #expect(try await page(h, phone, mari.id).entry.id == maria.id)
    }

    // MARK: Revisions

    @Test func aMemoryReadWithNothingFoundMovesPeoplesRevisionButNotSearchs() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        h.services.search.facts = Self.everyDeclared
        let people1 = try await directory(h, phone).factsRevision
        let search1 = try #require(await h.services.search.factsRevision())
        let m = try memory(h, "My sister's new flat", "She moved to Lisbon.")
        try apply(h, m.id, FactsExtraction(), predicate: Self.sib)
        let d = try await directory(h, phone)
        #expect(d.factsRevision != people1)
        #expect(await h.services.search.factsRevision() == search1)
        #expect(d.entries.first { $0.name == "Maria" }?.mentions == 3)
    }

    @Test func aMacSideChangeMovesTheRevisionInTheStatus() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        _ = try vault(h)
        let maria = try #require(try await directory(h, phone).entries.first { $0.name == "Maria" })
        let s1 = try await h.result(StatusGet.self, EmptyParams(), phone: phone, caps: caps).people?.factsRevision
        try h.store.setHidden(maria.id, true, now: t0)
        let s2 = try await h.result(StatusGet.self, EmptyParams(), phone: phone, caps: caps).people?.factsRevision
        try h.store.renameEntity(maria.id, to: "María", activity: h.activity, now: t0)
        let s3 = try await h.result(StatusGet.self, EmptyParams(), phone: phone, caps: caps).people?.factsRevision
        switches.set(learning: false)
        try h.store.setHidden(maria.id, false, now: t0)
        let s4 = try await h.result(StatusGet.self, EmptyParams(), phone: phone, caps: caps).people?.factsRevision
        #expect(Set([s1, s2, s3, s4].compactMap { $0 }).count == 4)
    }

    // MARK: Activity

    @Test func activityRowsCarryCountsOnly() async throws {
        let switches = PeopleSwitch()
        let h = try CompanionHarness(people: switches.people)
        let phone = try await h.pairedPhone()
        let v = try vault(h)
        let d = try await directory(h, phone)
        let maria = try #require(d.entries.first { $0.name == "Maria" })
        _ = try await page(h, phone, maria.id)
        let rows = h.activity.events.filter { $0.event == "people_listed" || $0.event == "people_viewed" }
        #expect(rows.map(\.event) == ["people_listed", "people_viewed"])
        #expect(rows.allSatisfy { $0.actor == "device:\(phone.deviceID!.db)" && $0.via == .companion && $0.ids.isEmpty })
        #expect(rows[0].counts["entries"] == d.entries.count && rows[1].counts["memories"] == 2)
        let encoded = String(decoding: try JSONEncoder().encode(h.activity.events), as: UTF8.self)
        for word in ["Maria", "Globex", "sister", "parents", "Porto", "mate", maria.id] { #expect(!encoded.contains(word)) }
        _ = v
    }
}
