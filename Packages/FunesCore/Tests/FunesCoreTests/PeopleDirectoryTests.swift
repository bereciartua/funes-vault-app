import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 13c: People & history (04-ux-mac.md, FR-F-07): the list, an entity's page, your timeline, To check, the
/// actions and their Undo, and what each unqualified use hides. Predicates are picked by their registry properties.
@Suite struct PeopleDirectoryTests {
    let v: TestVault
    let activity = InMemoryActivityLog()
    static let reg = FactsRegistry.bundled
    static let sib = FX.personPredicate { $0.lexicon.contains { $0.words.contains("sister") } }
    static let friend = FX.personPredicate { $0.lexicon.contains { $0.words.contains("friend") } }
    static let parent = FX.personPredicate { $0.lexicon.contains { $0.words.contains("parents") } }
    /// The recorded-only predicate (a client).
    static let recordedOnly = reg.predicates.first { $0.uses == [FactsUse.recorded.rawValue] }!.id
    static let work = FX.dated
    var people: String { Self.reg.predicate(Self.sib)!.callGroup }
    var workGroup: String { Self.reg.predicate(Self.work)!.callGroup }

    init() throws { v = try TestVault() }

    // MARK: Fixture

    /// What ships today: the person pool recorded and linked, the recorded-only predicate recorded; nothing else.
    static var shipped: FactsUses {
        var on = Set<FactsUses.Key>()
        for p in reg.predicates where p.objectKind == FactsValidator.personKind {
            on.insert(.init(predicate: p.id, use: .recorded, basis: ""))
            on.insert(.init(predicate: p.id, use: .linked, basis: ""))
        }
        on.insert(.init(predicate: recordedOnly, use: .recorded, basis: ""))
        return FactsUses(registry: reg, on: on)
    }

    static func config(_ uses: FactsUses = .everyDeclared(reg)) -> FactsSearchConfig {
        var c = FactsSearchConfig(engines: [:], userAliases: [], cloudLimit: .upTo(.internal))
        c.measuredUses = uses
        return c
    }

    @discardableResult
    func memory(_ title: String, _ body: String, sensitivity: Sensitivity = .low, at days: Double = 0) throws -> Memory {
        try v.memory(title, body, sensitivity: sensitivity, now: t0.plus(days: days))
    }

    func apply(_ m: Memory, _ x: FactsExtraction = FactsExtraction(), group: String? = nil) throws {
        let current = try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
        try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: current.version, extraction: x, callGroup: group ?? people, now: t0)
        }
    }

    func person(_ name: String, _ pred: String, label: String? = nil, quote: String) -> FactsExtraction {
        FactsExtraction(people: [ExtractedPerson(name: name, quote: quote)],
                        facts: [ExtractedFact(predicate: pred, name: name, label: label, quote: quote)])
    }

    func job(_ name: String, start: String? = nil, end: String? = nil, quote: String) -> FactsExtraction {
        FactsExtraction(facts: [fact(Self.work, name, start, end, quote: quote)])
    }

    func directory(_ uses: FactsUses = .everyDeclared(reg)) throws -> PeopleDirectory {
        try v.store.peopleDirectory(config: Self.config(uses))
    }

    func page(_ id: String, _ uses: FactsUses = .everyDeclared(reg)) throws -> PeopleEntityPage? {
        try v.store.peopleEntity(id, config: Self.config(uses))
    }

    func entry(_ name: String, _ d: PeopleDirectory) -> PeopleDirectory.Entry? { d.entries.first { $0.name == name } }

    /// Maria (sister) named in m1; m2 says only "my sister"; Ana, a friend, in m3.
    struct Sisters { var m1: Memory; var m2: Memory; var m3: Memory }

    func sisters() throws -> Sisters {
        let m1 = try memory("Maria is my sister", "We grew up in Porto together.")
        let m2 = try memory("My sister drinks her mate bitter", "Every morning, with no sugar.", at: 1)
        let m3 = try memory("Ana and the climbing gym", "Ana is my friend from the climbing gym.", at: 2)
        try apply(m1, person("Maria", Self.sib, label: "sister", quote: "Maria is my sister"))
        try apply(m2)
        try apply(m3, person("Ana", Self.friend, label: "friend", quote: "Ana is my friend"))
        return Sisters(m1: m1, m2: m2, m3: m3)
    }

    func stamps(_ p: PeopleEntityPage?) -> [String] { p?.corrections.map(\.id) ?? [] }

    // MARK: The list

    @Test func theListIsOrderedByMentionsWithTheFactInAFewWords() throws {
        _ = try sisters()
        let d = try directory()
        #expect(d.entries.map(\.name) == ["Maria", "Ana"])
        let maria = try #require(entry("Maria", d))
        #expect(maria.mentions == 2 && maria.kind == FactsValidator.personKind)
        #expect(maria.fact?.attribute == "your sister" && maria.fact?.recordedOnly == false)
        #expect(entry("Ana", d)?.mentions == 1)
        #expect(d.toCheck.isEmpty && d.summary.people == 2)
    }

    @Test func aRoleGroupIsListedUntilItsMembersAreNamed() throws {
        let m = try memory("Dinner with my parents", "My parents cooked paella.")
        try apply(m, FactsExtraction(facts: [ExtractedFact(predicate: Self.parent, name: "", entity: "group",
                                                           label: "parents", quote: "My parents", count: 2)]))
        let d = try directory()
        let group = try #require(d.entries.first { $0.group != nil })
        #expect(group.name == nil && group.group?.count == 2 && group.mentions == 1)
    }

    @Test func withEveryUseOffNamedPeopleStayButTheirRelationsGo() throws {
        _ = try sisters()
        let d = try directory(.none(Self.reg))
        let maria = try #require(entry("Maria", d))
        #expect(maria.fact == nil)
        #expect(try page(maria.id, .none(Self.reg))?.facts.isEmpty == true)
    }

    // MARK: Gating

    @Test func aRecordedOnlyFactIsShownWithoutAWhyLine() throws {
        let m = try memory("Signed Globex", "Globex is our client now.")
        try apply(m, FactsExtraction(facts: [ExtractedFact(predicate: Self.recordedOnly, name: "Globex", quote: "Globex is our client")]),
                  group: workGroup)
        let d = try directory(Self.shipped)
        let globex = try #require(entry("Globex", d))
        #expect(globex.fact?.recordedOnly == true)
        let p = try #require(try page(globex.id, Self.shipped))
        #expect(p.facts.count == 1 && p.facts[0].recordedOnly)
        #expect(p.memories.count == 1 && p.memories[0].whyLine == nil)
    }

    @Test func anUnrecordedPredicateShowsOnlyYourEntriesWithYourDates() throws {
        let m = try memory("Acme years", "I worked at Acme from 2015 to 2017.")
        try apply(m, job("Acme", start: "2015", end: "2017", quote: "I worked at Acme from 2015 to 2017"), group: workGroup)
        let id = try v.store.addManualEntry(PeopleManualEntry(kind: Self.reg.kindOf(Self.work), name: "Initech", predicate: Self.work,
                                                              start: "2019", end: "2021-06"), activity: activity, now: t0)
        let d = try directory(Self.shipped)
        let section = try #require(d.timeline.first)
        #expect(!section.on)
        #expect(section.episodes.map(\.name) == ["Initech"])
        let ep = section.episodes[0]
        #expect(ep.yours && ep.yourDates && ep.previous == nil && !ep.inferredEnd)
        #expect(ep.start?.precision == .year && ep.end?.precision == .month)
        #expect(entry("Initech", d)?.id == id)
        #expect(try page(id, Self.shipped)?.facts.first?.episodes.count == 1)
        // Acme's learned job is hidden everywhere; its name isn't a predicate's.
        #expect(d.entries.first { $0.name == "Acme" }?.fact == nil)
    }

    @Test func withTheTimelineOnEpisodesCarryGapsAndConflicts() throws {
        let a = try memory("Acme", "I joined Acme in 2015 and left in 2017.")
        let a2 = try memory("Acme start", "I started at Acme in 2016.", at: 1)
        let b = try memory("Initech", "I joined Initech in 2019; I left in 2021.", at: 2)
        try apply(a, job("Acme", start: "2015", end: "2017", quote: "I joined Acme in 2015"), group: workGroup)
        try apply(a2, job("Acme", start: "2016", quote: "I started at Acme in 2016"), group: workGroup)
        try apply(b, job("Initech", start: "2019", end: "2021", quote: "I joined Initech in 2019"), group: workGroup)
        let section = try #require(try directory().timeline.first)
        #expect(section.on)
        #expect(section.episodes.map(\.name) == ["Initech", "Acme"])
        #expect(section.episodes[1].conflictStart)
        if case .gap = section.episodes[0].previous {} else { Issue.record("expected a gap before Initech") }
        #expect(!section.episodes[0].stating.isEmpty)
    }

    /// Your Timeline reads the uses with no answer model (`FactsSearchConfig.uses`), from the shipped records and the
    /// Facts engines as the app builds them. Before ADR-0032's amendment of 2026-11-24 it was always off: both shipped
    /// timeline records name answer models, and a record with answer models didn't count without one.
    @Test func yourTimelineShowsLearnedJobsWithTheTestedModelAndAnUntestedOne() throws {
        let a = try memory("Acme", "I joined Acme in 2015 and left in 2017.")
        let b = try memory("Initech", "I joined Initech in 2019; I left in 2021.", at: 1)
        try apply(a, job("Acme", start: "2015", end: "2017", quote: "I joined Acme in 2015"), group: workGroup)
        try apply(b, job("Initech", start: "2019", end: "2021", quote: "I joined Initech in 2019"), group: workGroup)
        let haiku = FactsEngine(ClaudeCodeClient(executable: "/usr/bin/false", model: FactsClients.defaultModel))
        let untested = FactsEngine(model: "ollama/qwen3:8b", adapter: "ollama")
        #expect(FactsQualification.bundled.tested(haiku, registry: Self.reg, promptVersions: FactsQualification.promptVersions(Self.reg)))
        for engine in [haiku, untested] {
            let config = FactsSearchConfig(engines: [people: engine, workGroup: engine], userAliases: [], cloudLimit: .upTo(.internal))
            let section = try #require(try v.store.peopleDirectory(config: config).timeline.first { $0.predicate == Self.work })
            #expect(section.on, "\(engine.model)")
            #expect(section.episodes.map(\.name) == ["Initech", "Acme"], "\(engine.model)")
            #expect(section.episodes.allSatisfy { !$0.yours }, "\(engine.model)")
        }
        // No model at all: off, and only your entries would show.
        let none = FactsSearchConfig(engines: [:], userAliases: [], cloudLimit: .upTo(.internal))
        #expect(try v.store.peopleDirectory(config: none).timeline.first { $0.predicate == Self.work }?.on == false)
    }

    @Test func anUndatedJobSaysFunesCantPlaceIt() throws {
        let a = try memory("Acme", "I joined Acme in 2015 and left in 2017.")
        let h = try memory("Hooli", "I did a contract at Hooli at some point.", at: 1)
        try apply(a, job("Acme", start: "2015", end: "2017", quote: "I joined Acme in 2015"), group: workGroup)
        try apply(h, job("Hooli", quote: "I did a contract at Hooli"), group: workGroup)
        let section = try #require(try directory().timeline.first)
        let hooli = try #require(section.episodes.first { $0.name == "Hooli" })
        #expect(hooli.start == nil && hooli.end == nil, "\(String(describing: hooli.start)) \(String(describing: hooli.end))")
        if case .cantTell = hooli.previous {} else { Issue.record("expected can't tell on the undated job: \(String(describing: hooli.previous))") }
    }

    // MARK: The page

    @Test func thePageListsEveryMemoryWithItsWhyLine() throws {
        let s = try sisters()
        let d = try directory()
        let maria = try #require(entry("Maria", d))
        let p = try #require(try page(maria.id))
        #expect(p.aliases.map(\.alias) == ["Maria"] && p.aliases[0].memories == 1)
        #expect(p.facts.count == 1 && p.facts[0].basis == .named && p.facts[0].status == .current)
        let byID = Dictionary(uniqueKeysWithValues: p.memories.map { ($0.memoryID, $0) })
        #expect(byID[s.m2.id]?.whyLine?.form == .role(surface: "My sister", name: "Maria"))
        #expect(byID[s.m2.id]?.whyLine?.basis == .link(.soleKnown))
        if case .name = byID[s.m1.id]?.whyLine?.form {} else { Issue.record("expected the statement's why line") }
        #expect(p.memories.allSatisfy { $0.notName.entity == maria.id })
    }

    // MARK: Actions and Undo

    @Test func renameIsACorrectionUndoTakesItBack() throws {
        _ = try sisters()
        let id = try #require(entry("Maria", try directory())).id
        try v.store.renameEntity(id, to: "Mari", activity: activity, now: t0.plus(days: 3))
        let p = try #require(try page(id))
        #expect(p.entry.name == "Mari")
        #expect(p.corrections.first?.what == .renamed("Mari"))
        try v.store.undoPeopleAction(p.corrections[0].id, activity: activity, now: t0.plus(days: 4))
        let back = try #require(try page(id))
        #expect(back.entry.name == "Maria" && back.corrections.isEmpty)
        #expect(activity.events.allSatisfy { $0.event == "facts_corrected" && $0.counts.values.allSatisfy { $0 >= 0 } })
    }

    @Test func kindChangesAreRefusedAgainstAFactAndUndone() throws {
        _ = try sisters()
        let maria = try #require(entry("Maria", try directory())).id
        #expect(throws: PeopleError.kindConflict) {
            try v.store.setEntityKind(maria, to: Self.reg.kindOf(Self.work), activity: activity, now: t0)
        }
        let m = try memory("Pixel", "Pixel sleeps all day.")
        try apply(m, person("Pixel", Self.friend, quote: "Pixel"))
        // Undo the fact first: a friend can't be a thing.
        let pixel = try #require(entry("Pixel", try directory()))
        let fid = try #require(try page(pixel.id)?.facts.first?.factID)
        try v.store.rejectFact(factID: fid, activity: activity, now: t0.plus(days: 1))
        try v.store.setEntityKind(pixel.id, to: "thing", activity: activity, now: t0.plus(days: 2))
        let p = try #require(try page(pixel.id))
        #expect(p.entry.kind == "thing")
        #expect(p.corrections.first?.what == .kind("thing"))
        try v.store.undoPeopleAction(p.corrections[0].id, activity: activity, now: t0.plus(days: 3))
        #expect(try page(pixel.id)?.entry.kind == FactsValidator.personKind)
    }

    @Test func mergingIsSuggestedAndNotThisRemovesTheFusedFact() throws {
        _ = try sisters()
        let m4 = try memory("Maria Lopez called", "Maria Lopez is my sister.", at: 3)
        try apply(m4, person("Maria Lopez", Self.sib, label: "sister", quote: "Maria Lopez is my sister"))
        var d = try directory()
        let suggestion = d.toCheck.compactMap { item -> (String, String)? in
            if case let .merge(a, b, _) = item { return (a, b) } else { return nil }
        }
        #expect(suggestion.count == 1)
        let (into, other) = try #require(suggestion.first)
        try v.store.mergeEntity(other, into: into, activity: activity, now: t0.plus(days: 4))
        d = try directory()
        #expect(d.entries.filter { $0.kind == FactsValidator.personKind }.count == 2)    // the merged pair, and Ana
        #expect(!d.toCheck.contains { if case .merge = $0 { true } else { false } })
        let p = try #require(try page(into))
        #expect(p.facts.count == 1 && p.corrections.contains { if case .mergedFrom = $0.what { true } else { false } })
        // Not this on the fused fact rejects both rows: it doesn't come back through the other one.
        try v.store.rejectFact(factID: p.facts[0].factID, activity: activity, now: t0.plus(days: 5))
        #expect(try page(into)?.facts.isEmpty == true)
        // Undo the merge: two entries again (the rejection stays on each).
        let merge = try #require(try page(into)?.corrections.first { if case .mergedFrom = $0.what { true } else { false } })
        try v.store.undoPeopleAction(merge.id, activity: activity, now: t0.plus(days: 6))
        let after = try directory().entries
        #expect(after.filter { $0.kind == FactsValidator.personKind }.count == 3, "\(after.map { ($0.name ?? "-", $0.mentions, $0.tombstone) })")
    }

    @Test func notTheSameStopsTheSuggestion() throws {
        _ = try sisters()
        let m4 = try memory("Maria Lopez called", "Maria Lopez is my sister.", at: 3)
        try apply(m4, person("Maria Lopez", Self.sib, label: "sister", quote: "Maria Lopez is my sister"))
        let merge = try directory().toCheck.compactMap { item -> (String, String)? in
            if case let .merge(a, b, _) = item { (a, b) } else { nil }
        }.first
        guard let (a, b) = merge else { Issue.record("no suggestion"); return }
        try v.store.markNotSame(a, b, activity: activity, now: t0.plus(days: 4))
        #expect(!(try directory().toCheck.contains { if case .merge = $0 { true } else { false } }))
    }

    @Test func hideIsListOnlyAndUndoable() throws {
        _ = try sisters()
        let id = try #require(entry("Ana", try directory())).id
        let before = try v.store.factsRevision()
        try v.store.setHidden(id, true, now: t0.plus(days: 3))
        #expect(entry("Ana", try directory())?.hidden == true)
        #expect(try v.store.factsRevision() != before)
        let p = try #require(try page(id))
        #expect(p.corrections.first?.what == .hidden(true))
        try v.store.undoPeopleAction(p.corrections[0].id, activity: activity, now: t0.plus(days: 4))
        #expect(entry("Ana", try directory())?.hidden == false)
    }

    @Test func relationToAnotherPredicateIsOneActionUndoneTogether() throws {
        _ = try sisters()
        let ana = try #require(entry("Ana", try directory())).id
        let friendFact = try #require(try page(ana)?.facts.first)
        try v.store.setRelation(entity: ana, predicate: Self.sib, label: "sister", replacing: friendFact.factID, activity: activity,
                                now: t0.plus(days: 3))
        let p = try #require(try page(ana))
        #expect(p.facts.map(\.predicate) == [Self.sib] && p.facts[0].label == "sister" && p.facts[0].basis == .confirmed)
        #expect(p.corrections.count == 1)
        try v.store.undoPeopleAction(p.corrections[0].id, activity: activity, now: t0.plus(days: 4))
        let back = try #require(try page(ana))
        #expect(back.facts.map(\.predicate) == [Self.friend] && back.corrections.isEmpty)
        #expect(try v.count("SELECT COUNT(*) FROM fact WHERE predicate = ? AND manual = 1", [Self.sib]) == 0)
    }

    @Test func yourLaterDatesReplaceYourEarlierOnesAndUndoBringsThemBack() throws {
        let id = try v.store.addManualEntry(PeopleManualEntry(kind: Self.reg.kindOf(Self.work), name: "Initech", predicate: Self.work,
                                                              start: "2019", end: "2021", status: .former),
                                            activity: activity, now: t0)
        let fid = try #require(try page(id)?.facts.first?.factID)
        try v.store.setDates(fid, start: "2020", end: nil, selector: nil, activity: activity, now: t0.plus(days: 1))
        var ep = try #require(try page(id)?.facts.first?.episodes.first)
        #expect(ep.start == DateRange(lo: DayNumber.from(year: 2020, month: 1, day: 1)!, hi: DayNumber.from(year: 2020, month: 12, day: 31)!,
                                      precision: .year))
        #expect(!ep.conflictStart)
        let dates = try #require(try page(id)?.corrections.first { if case .dates = $0.what { true } else { false } })
        try v.store.undoPeopleAction(dates.id, activity: activity, now: t0.plus(days: 2))
        ep = try #require(try page(id)?.facts.first?.episodes.first)
        #expect(ep.start?.lo == DayNumber.from(year: 2019, month: 1, day: 1))
        // Clear Dates keeps the status (a manual fact keeps its only row); with the timeline off nothing is derived.
        try v.store.clearYourDates(fid, selectors: [nil], activity: activity, now: t0.plus(days: 3))
        let f = try #require(try page(id)?.facts.first)
        #expect(f.status == .former && f.episodes.allSatisfy { !$0.yourDates })
        let off = try #require(try page(id, Self.shipped)?.facts.first)
        #expect(off.episodes.allSatisfy { $0.start == nil && $0.end == nil && $0.former })
    }

    @Test func aManualEntryUndoneLeavesNothingBehind() throws {
        let id = try v.store.addManualEntry(PeopleManualEntry(kind: FactsValidator.personKind, name: "Rosa", predicate: Self.friend,
                                                              label: "friend", sensitivity: .sensitive), activity: activity, now: t0)
        let p = try #require(try page(id))
        #expect(p.entry.manual && p.facts.first?.label == "friend")
        #expect(p.corrections.count == 1)
        if case .factAdded = p.corrections[0].what {} else { Issue.record("expected the manual entry") }
        try v.store.undoPeopleAction(p.corrections[0].id, activity: activity, now: t0.plus(days: 1))
        #expect(try v.count("SELECT COUNT(*) FROM entity WHERE is_you = 0") == 0)
        #expect(try v.count("SELECT COUNT(*) FROM fact") == 0)
        #expect(try v.store.hasUserFactEntries() == false)
    }

    // MARK: To check

    @Test func anUnsettledRolePhraseIsAskedAndYourAnswerHolds() throws {
        _ = try sisters()
        let m5 = try memory("Elena is my sister too", "She lives in Lyon.", at: 3)
        try apply(m5, person("Elena", Self.sib, label: "sister", quote: "Elena is my sister"))
        let m6 = try memory("Flowers", "Buy flowers for my sister.", at: 4)
        let m7 = try memory("Trip", "Plan the trip with my sister.", at: 5)
        try apply(m6)
        try apply(m7)
        var d = try directory()
        let links = d.toCheck.compactMap { if case let .link(l) = $0 { l } else { nil } }
        #expect(Set(links.map(\.memoryID)).isSuperset(of: [m6.id, m7.id]))
        let item = try #require(links.first { $0.memoryID == m6.id })
        #expect(Set(item.candidates.map(\.name)) == ["Maria", "Elena"])
        let maria = try #require(item.candidates.first { $0.name == "Maria" }).entity
        try v.store.answerLink(memoryID: m6.id, surface: item.surface, start: item.start, .entity(maria), activity: activity,
                               now: t0.plus(days: 6))
        #expect(try page(maria)?.memories.contains { $0.memoryID == m6.id } == true)
        #expect(!(try directory().toCheck.contains { if case let .link(l) = $0 { l.memoryID == m6.id } else { false } }))
        // A later model decision at the same span doesn't overturn yours.
        let elena = try #require(item.candidates.first { $0.name == "Elena" }).entity
        try v.store.writer.write { db in
            let mem = try MemoryStore.fetch(db, id: m6.id)!
            let text = FactStore.text(title: mem.title, body: mem.body)
            let s = FactStore.scalarOffset(text, utf16: item.start)
            try db.execute(sql: """
                INSERT INTO mention_decision (id, memory_id, memory_version, mention, quote, span_start, span_end, outcome, entity_id,
                  basis, source, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'entity', ?, 'context', 'model', ?)
                """, arguments: [UUID().db, m6.id.db, mem.version, item.surface, item.surface, s, s + item.surface.count, elena,
                                 t0.plus(days: 7)])
        }
        #expect(try page(maria)?.memories.contains { $0.memoryID == m6.id } == true)
        #expect(try page(elena)?.memories.contains { $0.memoryID == m6.id } == false)
        // Skip takes the other off To check and changes no link; Undo brings it back.
        let other = try #require(links.first { $0.memoryID == m7.id })
        try v.store.answerLink(memoryID: m7.id, surface: other.surface, start: other.start, .skip, activity: activity, now: t0.plus(days: 8))
        d = try directory()
        #expect(!d.toCheck.contains { if case let .link(l) = $0 { l.memoryID == m7.id } else { false } })
        #expect(d.answered.count == 1 && d.answered[0].skipped)
        try v.store.undoPeopleAction(d.answered[0].group, activity: activity, now: t0.plus(days: 9))
        #expect(try directory().toCheck.contains { if case let .link(l) = $0 { l.memoryID == m7.id } else { false } })
    }

    @Test func aRowOfYoursThatLostItsEpisodeIsAskedAndRetargeted() throws {
        let a = try memory("Acme first", "I worked at Acme from 2015 to 2017.")
        try apply(a, job("Acme", start: "2015", end: "2017", quote: "I worked at Acme from 2015 to 2017"), group: workGroup)
        let b = try memory("Acme again", "I rejoined Acme in 2021.", at: 2)
        try apply(b, job("Acme", start: "2021", quote: "I rejoined Acme in 2021"), group: workGroup)
        let id = try #require(entry("Acme", try directory())).id
        let fid = try #require(try page(id)?.facts.first?.factID)
        // A selector spanning both stints matches two episodes: To check asks which.
        let wide = DateRange(lo: DayNumber.from(year: 2015, month: 1, day: 1)!, hi: DayNumber.from(year: 2022, month: 12, day: 31)!)
        try v.store.setFactStatus(fid, .former, selector: wide, activity: activity, now: t0.plus(days: 3))
        let lost = try #require(try directory().toCheck.compactMap { if case let .episode(e) = $0 { e } else { nil } }.first)
        #expect(lost.choices.count == 2 && !lost.otherEndpoint)
        try v.store.retargetUserRow(lost.rowID, otherEndpoint: false, to: lost.choices[0], activity: activity, now: t0.plus(days: 4))
        #expect(!(try directory().toCheck.contains { if case .episode = $0 { true } else { false } }))
        // With the timeline off nothing is matched: your row applies as entered, and nothing is asked.
        try v.store.setFactStatus(fid, .current, selector: wide, activity: activity, now: t0.plus(days: 5))
        #expect(!(try directory(Self.shipped).toCheck.contains { if case .episode = $0 { true } else { false } }))
        let again = try #require(try directory().toCheck.compactMap { if case let .episode(e) = $0 { e } else { nil } }.first)
        try v.store.retargetUserRow(again.rowID, otherEndpoint: false, to: nil, activity: activity, now: t0.plus(days: 6))
        #expect(!(try directory().toCheck.contains { if case .episode = $0 { true } else { false } }))
        // Remove is undoable: the row, and its question, come back.
        let removed = try #require(try page(id)?.corrections.first)
        try v.store.undoPeopleAction(removed.id, activity: activity, now: t0.plus(days: 7))
        #expect(try directory().toCheck.contains { if case .episode = $0 { true } else { false } })
    }

    // MARK: Review fixes (13c diff review)

    @Test func hideChangesNothingACloudCallSees() throws {
        let m1 = try memory("Maria is my sister", "We grew up in Porto together.")
        try apply(m1, person("Maria", Self.sib, label: "sister", quote: "Maria is my sister"))
        let m2 = try memory("Maria's diagnosis", "Maria told me about her diagnosis.", sensitivity: .sensitive, at: 1)
        try apply(m2, FactsExtraction(people: [ExtractedPerson(name: "Maria", quote: "Maria told me")]))
        func sendable() throws -> Set<String> {
            try v.store.writer.read { db in
                Set(try FactStore.load(db, registry: Self.reg, uses: .everyDeclared(Self.reg), sendable: .upTo(.internal)).graph.entities.keys)
            }
        }
        let before = try sendable()
        let id = try #require(entry("Maria", try directory())).id
        try v.store.setHidden(id, true, now: t0.plus(days: 2))
        #expect(try sendable() == before)
    }

    @Test func undoingARelationThatSaidARejectedFactAgainBringsTheRejectionBack() throws {
        _ = try sisters()
        let maria = try #require(entry("Maria", try directory())).id
        let fid = try #require(try page(maria)?.facts.first?.factID)
        try v.store.rejectFact(factID: fid, activity: activity, now: t0.plus(days: 3))
        #expect(try page(maria)?.facts.isEmpty ?? true)
        try v.store.setRelation(entity: maria, predicate: Self.sib, label: nil, replacing: nil, activity: activity, now: t0.plus(days: 4))
        let back = try #require(try page(maria))
        #expect(back.facts.map(\.predicate) == [Self.sib])
        let added = try #require(back.corrections.first { if case .factAdded = $0.what { true } else { false } })
        try v.store.undoPeopleAction(added.id, activity: activity, now: t0.plus(days: 5))
        #expect(try page(maria)?.facts.isEmpty ?? true)
    }

    @Test func skipTakesOffTheOccurrenceSkipped() throws {
        _ = try sisters()
        let m5 = try memory("Elena is my sister too", "She lives in Lyon.", at: 3)
        try apply(m5, person("Elena", Self.sib, label: "sister", quote: "Elena is my sister"))
        let m6 = try memory("Calls", "My sister called at noon; later my sister called again.", at: 4)
        try apply(m6)
        let items = try directory().toCheck.compactMap { if case let .link(l) = $0, l.memoryID == m6.id { l } else { nil } }
        #expect(items.count == 2)
        let second = try #require(items.max { $0.start < $1.start })
        try v.store.answerLink(memoryID: m6.id, surface: second.surface, start: second.start, .skip, activity: activity, now: t0.plus(days: 5))
        let left = try directory().toCheck.compactMap { if case let .link(l) = $0, l.memoryID == m6.id { l } else { nil } }
        #expect(left.map(\.start) == [items.min { $0.start < $1.start }!.start])
    }

    @Test func undoKeepsKindsConsistent() throws {
        let m = try memory("Pixel", "Pixel sleeps all day.")
        try apply(m, person("Pixel", Self.friend, quote: "Pixel"))
        let id = try #require(entry("Pixel", try directory())).id
        let fid = try #require(try page(id)?.facts.first?.factID)
        try v.store.rejectFact(factID: fid, activity: activity, now: t0.plus(days: 1))
        try v.store.setEntityKind(id, to: "thing", activity: activity, now: t0.plus(days: 2))
        // Undoing the rejection would put "your friend" on a thing: refused, nothing changes.
        let rejection = try #require(try page(id)?.corrections.first { if case .factRejected = $0.what { true } else { false } })
        #expect(throws: PeopleError.kindConflict) { try v.store.undoPeopleAction(rejection.id, activity: activity, now: t0.plus(days: 3)) }
        #expect(try page(id)?.facts.isEmpty == true && (try page(id)?.entry.kind) == "thing")
        // Two kind changes undone out of order: the remaining change decides, then the original kind.
        try v.store.setEntityKind(id, to: "place", activity: activity, now: t0.plus(days: 4))
        let changes = try #require(try page(id)?.corrections.filter { if case .kind = $0.what { true } else { false } })
        let older = try #require(changes.last), newer = try #require(changes.first)
        try v.store.undoPeopleAction(older.id, activity: activity, now: t0.plus(days: 5))
        #expect(try page(id)?.entry.kind == "place")
        try v.store.undoPeopleAction(newer.id, activity: activity, now: t0.plus(days: 6))
        #expect(try page(id)?.entry.kind == FactsValidator.personKind)
    }

    @Test func anOrderOfYoursKeepsNoName() throws {
        let a = try v.store.addManualEntry(PeopleManualEntry(kind: Self.reg.kindOf(Self.work), name: "Acme", predicate: Self.work, start: "2015"),
                                           activity: activity, now: t0)
        let b = try v.store.addManualEntry(PeopleManualEntry(kind: Self.reg.kindOf(Self.work), name: "Initech", predicate: Self.work, start: "2018"),
                                           activity: activity, now: t0)
        let fa = try #require(try page(a)?.facts.first?.factID), fb = try #require(try page(b)?.facts.first?.factID)
        try v.store.addOrder(before: fa, after: fb, beforeSelector: nil, afterSelector: nil, activity: activity, now: t0.plus(days: 1))
        let asserted = try v.store.writer.read { db in try String.fetchOne(db, sql: "SELECT asserted FROM fact_evidence WHERE target_kind = 'order'") }
        #expect(asserted?.contains("Acme") == false)
        for bad in ["next spring", "2026-02-30", "2026-13", "19"] {
            #expect(throws: PeopleError.badDate) { try v.store.setDates(fa, start: bad, end: nil, selector: nil, activity: activity) }
        }
    }

    @Test func clearDatesFindsYourRowsAfterACorrectedStart() throws {
        let a = try memory("Acme", "I worked at Acme from 2015 to 2017.")
        try apply(a, job("Acme", start: "2015", end: "2017", quote: "I worked at Acme from 2015 to 2017"), group: workGroup)
        let id = try #require(entry("Acme", try directory())).id
        let ep = try #require(try page(id)?.facts.first?.episodes.first)
        try v.store.setDates(ep.factID, start: "2016", end: nil, selector: ep.selector, activity: activity, now: t0.plus(days: 1))
        let corrected = try #require(try page(id)?.facts.first?.episodes.first)
        #expect(corrected.yourDates && corrected.selector == ep.selector)
        try v.store.clearYourDates(corrected.factID, selectors: corrected.yourSelectors, activity: activity, now: t0.plus(days: 2))
        let cleared = try #require(try page(id)?.facts.first?.episodes.first)
        #expect(!cleared.yourDates && cleared.start?.lo == DayNumber.from(year: 2015, month: 1, day: 1))
        // Clear Dates is an action of its own: Undo brings your date back.
        let clear = try #require(try page(id)?.corrections.first)
        try v.store.undoPeopleAction(clear.id, activity: activity, now: t0.plus(days: 3))
        #expect(try page(id)?.facts.first?.episodes.first?.start?.lo == DayNumber.from(year: 2016, month: 1, day: 1))
    }

    @Test func yourLaterDateWinsAcrossAMerge() throws {
        let a = try v.store.addManualEntry(PeopleManualEntry(kind: Self.reg.kindOf(Self.work), name: "Initech", predicate: Self.work, start: "2019"),
                                           activity: activity, now: t0)
        let b = try v.store.addManualEntry(PeopleManualEntry(kind: Self.reg.kindOf(Self.work), name: "Initech Corp", predicate: Self.work, start: "2020"),
                                           activity: activity, now: t0.plus(days: 1))
        try v.store.mergeEntity(b, into: a, activity: activity, now: t0.plus(days: 2))
        let ep = try #require(try page(a)?.facts.first?.episodes.first)
        #expect(ep.start?.lo == DayNumber.from(year: 2020, month: 1, day: 1) && !ep.conflictStart)
    }

    @Test func yourWordForARelationStaysWhenItsUseIsOff() throws {
        _ = try sisters()
        let maria = try #require(entry("Maria", try directory())).id
        let fid = try #require(try page(maria)?.facts.first?.factID)
        try v.store.setRelation(entity: maria, predicate: Self.sib, label: "big sister", replacing: fid, activity: activity, now: t0.plus(days: 1))
        let kept = try #require(try page(maria, .none(Self.reg))?.facts.first)
        #expect(kept.label == "big sister" && kept.basis == .confirmed)
    }

    @Test func anEntityKeptOnlyForYourCorrectionIsStillListed() throws {
        let s = try sisters()
        let maria = try #require(entry("Maria", try directory())).id
        try v.store.setDeceased(maria, true, activity: activity, now: t0.plus(days: 1))
        _ = try v.store.deleteMemory(id: s.m1.id, now: t0.plus(days: 2))
        try v.store.purgeMemory(id: s.m1.id, now: t0.plus(days: 3))
        let p = try #require(try page(maria))
        #expect(p.entry.name == nil && p.entry.tombstone)
        #expect(p.corrections.contains { $0.what == .deceased(true) })
    }

    @Test func aKindCheckFollowsAMerge() throws {
        let m = try memory("Pixel", "Pixel sleeps all day.")
        try apply(m, person("Pixel", Self.friend, quote: "Pixel"))
        let pixel = try #require(entry("Pixel", try directory())).id
        let fid = try #require(try page(pixel)?.facts.first?.factID)
        try v.store.rejectFact(factID: fid, activity: activity, now: t0.plus(days: 1))
        try v.store.setEntityKind(pixel, to: "thing", activity: activity, now: t0.plus(days: 2))
        let lamp = try v.store.addManualEntry(PeopleManualEntry(kind: "thing", name: "Lamp"), activity: activity, now: t0.plus(days: 3))
        try v.store.mergeEntity(pixel, into: lamp, activity: activity, now: t0.plus(days: 4))
        let rejection = try #require(try page(lamp)?.corrections.first { if case .factRejected = $0.what { true } else { false } })
        #expect(throws: PeopleError.kindConflict) { try v.store.undoPeopleAction(rejection.id, activity: activity, now: t0.plus(days: 5)) }
    }

    @Test func aCorrectionIsAsPrivateAsTheCorrectionsBeforeIt() throws {
        _ = try sisters()
        let maria = try #require(entry("Maria", try directory())).id
        let fid = try #require(try page(maria)?.facts.first?.factID)
        try v.store.writer.write { db in
            try FactStore.override(db, targetKind: "qualifier", targetID: fid, field: "label", value: "half-sister",
                                   sensitivity: Sensitivity.sensitive.rawValue, now: t0)
        }
        try v.store.setDeceased(maria, true, activity: activity, now: t0.plus(days: 1))
        let level = try v.store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT sensitivity FROM manual_override WHERE field = 'deceased'")
        }
        #expect(level == Sensitivity.sensitive.rawValue)
    }

    @Test func anEntityKeptOnlyForARejectionIsStillListed() throws {
        let s = try sisters()
        let maria = try #require(entry("Maria", try directory())).id
        let fid = try #require(try page(maria)?.facts.first?.factID)
        try v.store.rejectFact(factID: fid, activity: activity, now: t0.plus(days: 1))
        _ = try v.store.deleteMemory(id: s.m1.id, now: t0.plus(days: 2))
        try v.store.purgeMemory(id: s.m1.id, now: t0.plus(days: 3))
        let p = try #require(try page(maria))
        #expect(p.corrections.contains { if case .factRejected = $0.what { true } else { false } })
    }

    @Test func withTheTimelineOffAStatusIsOnlyWhatWasSaid() throws {
        let id = try v.store.addManualEntry(PeopleManualEntry(kind: Self.reg.kindOf(Self.work), name: "Initech", predicate: Self.work,
                                                              start: "2019", end: "2021"), activity: activity, now: t0)
        #expect(try page(id, Self.shipped)?.facts.first?.status == .current)
        let fid = try #require(try page(id)?.facts.first?.factID)
        try v.store.setFactStatus(fid, .current, selector: nil, activity: activity, now: t0.plus(days: 1))
        let ep = try #require(try page(id, Self.shipped)?.facts.first?.episodes.first)
        #expect(ep.end == nil && !ep.former)      // marked current after an end: it holds again
    }

    // MARK: Corrections hold

    @Test func notNameOnAnOrganizationsNameTakesTheMemoryOff() throws {
        let m = try memory("Lunch at Globex", "Met the Globex team for lunch.")
        try apply(m, FactsExtraction(facts: [ExtractedFact(predicate: Self.recordedOnly, name: "Globex", quote: "Globex team")]),
                  group: workGroup)
        let id = try #require(entry("Globex", try directory())).id
        #expect(entry("Globex", try directory())?.mentions == 1)
        try v.store.rejectLink(memoryID: m.id, entity: id, config: Self.config(), activity: activity, now: t0.plus(days: 1))
        // Its only memory is off: nothing lists it any more.
        #expect(try page(id)?.memories.isEmpty ?? true)
    }

    @Test func removeLearnedFactsKeepsWhatYouChanged() throws {
        _ = try sisters()
        let id = try #require(entry("Maria", try directory())).id
        try v.store.renameEntity(id, to: "Mari", activity: activity, now: t0.plus(days: 3))
        _ = try v.store.removeLearnedFacts(activity: activity, now: t0.plus(days: 4))
        let p = try #require(try page(id))
        #expect(p.entry.name == "Mari" && p.entry.tombstone && p.memories.isEmpty)
        #expect(p.corrections.first?.what == .renamed("Mari"))
        #expect(try v.store.hasUserFactEntries())
    }

    @Test func aPurgeTakesSkipsWithIt() throws {
        let s = try sisters()
        let m5 = try memory("Elena is my sister too", "She lives in Lyon.", at: 3)
        try apply(m5, person("Elena", Self.sib, label: "sister", quote: "Elena is my sister"))
        guard case let .link(l)? = try directory().toCheck.first else { Issue.record("no item"); return }
        try v.store.answerLink(memoryID: l.memoryID, surface: l.surface, start: l.start, .skip, activity: activity, now: t0)
        _ = try v.store.deleteMemory(id: l.memoryID, now: t0.plus(days: 4))
        try v.store.purgeMemory(id: l.memoryID, now: t0.plus(days: 5))
        _ = s
        #expect(try v.count("SELECT COUNT(*) FROM mention_decision WHERE outcome = 'unknown' AND source = 'user'") == 0)
    }

    // MARK: Privacy and provenance (13a code these actions now reach)

    @Test func yourRowAboveTheLimitWithholdsItsFactWhole() throws {
        let s = try sisters()
        _ = s
        let id = try #require(entry("Maria", try directory())).id
        let fid = try #require(try page(id)?.facts.first?.factID)
        try v.store.writer.write { db in
            try FactStore.addUserEvidence(db, factID: fid, asserted: ["status": "former"], sensitivity: Sensitivity.sensitive.rawValue, now: t0)
        }
        let sendable = try v.store.writer.read { db in
            try FactStore.load(db, registry: Self.reg, uses: .everyDeclared(Self.reg), sendable: .upTo(.internal)).graph
        }
        #expect(!sendable.facts.contains { $0.predicate == Self.sib && !$0.negated })
    }

    @Test func aFactKeptForYourRowsKeepsOnlyYourLabel() throws {
        _ = try sisters()
        let id = try #require(entry("Maria", try directory())).id
        let fid = try #require(try page(id)?.facts.first?.factID)
        try v.store.setFactStatus(fid, .former, selector: nil, activity: activity, now: t0.plus(days: 1))
        // Recorded off: your status row keeps the fact, but not the learned word "sister".
        var kept = try #require(try page(id, .none(Self.reg))?.facts.first)
        #expect(kept.label == nil)
        try v.store.setRelation(entity: id, predicate: Self.sib, label: "big sister", replacing: fid, activity: activity, now: t0.plus(days: 2))
        kept = try #require(try page(id, .none(Self.reg))?.facts.first)
        #expect(kept.label == "big sister")
    }

    @Test func theSummaryCountsPeopleEmployersAndOthers() throws {
        _ = try sisters()
        let a = try memory("Acme", "I joined Acme in 2015.")
        try apply(a, job("Acme", start: "2015", quote: "I joined Acme in 2015"), group: workGroup)
        #expect(try directory().summary == PeopleDirectory.Summary(people: 2, employers: 1, others: 0))
        // Today the job isn't recorded: no employers, and Acme is one more name.
        #expect(try directory(Self.shipped).summary == PeopleDirectory.Summary(people: 2, employers: 0, others: 1))
    }
}
