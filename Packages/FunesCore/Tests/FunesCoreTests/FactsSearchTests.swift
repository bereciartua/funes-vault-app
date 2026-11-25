import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 13b: learned facts in Vault search (memory processing §4, FR-F-05): matching with no model call, admission
/// without a boost, the −0.10, why lines and corrections, the gates (off or unqualified: search is unchanged), and the
/// owner side only. Keyword-only search, so scores are exact.
@Suite struct FactsSearchTests {
    let v: TestVault
    let activity = InMemoryActivityLog()
    static let sib = FX.personPredicate { $0.lexicon.contains { $0.words.contains("sister") } }
    static let friend = FX.personPredicate { $0.lexicon.contains { $0.words.contains("friend") } }
    var people: String { FX.registry.predicate(Self.sib)!.callGroup }

    init() throws { v = try TestVault() }

    // MARK: Fixture

    @discardableResult
    func memory(_ title: String, _ body: String, sensitivity: Sensitivity = .low, at days: Double = 0) throws -> Memory {
        try v.memory(title, body, sensitivity: sensitivity, now: t0.plus(days: days))
    }

    func apply(_ m: Memory, _ x: FactsExtraction = FactsExtraction(), group: String? = nil, at days: Double = 0) throws {
        let current = try v.store.writer.read { db in try MemoryStore.fetch(db, id: m.id)! }
        try v.store.writer.write { db in
            try FactStore.apply(db, memoryID: m.id.db, version: current.version, extraction: x, callGroup: group ?? people,
                                now: t0.plus(days: days))
        }
    }

    func person(_ name: String, _ pred: String, label: String? = nil, quote: String) -> FactsExtraction {
        FactsExtraction(people: [ExtractedPerson(name: name, quote: quote)],
                        facts: [ExtractedFact(predicate: pred, name: name, label: label, quote: quote)])
    }

    static func config(_ uses: FactsUses? = .everyDeclared(.bundled), aliases: [String] = []) -> FactsSearchConfig {
        var c = FactsSearchConfig(engines: [:], userAliases: aliases, cloudLimit: .upTo(.internal))
        c.measuredUses = uses
        return c
    }

    /// Maria, the only sister known, named in m1; m2 says "my sister"; Ana, a friend, in m3.
    struct Sisters { var m1: Memory; var m2: Memory; var m3: Memory; var m4: Memory }

    func sisters() throws -> Sisters {
        let m1 = try memory("Maria is my sister", "We grew up in Porto together.")
        let m2 = try memory("My sister drinks her mate bitter", "Every morning, with no sugar.")
        let m3 = try memory("Ana drinks matcha", "Ana is my friend from the climbing gym.")
        let m4 = try memory("Coffee order", "A flat white with oat milk.")
        try apply(m1, person("Maria", Self.sib, label: "sister", quote: "Maria is my sister"))
        try apply(m2)
        try apply(m3, person("Ana", Self.friend, label: "friend", quote: "Ana is my friend"))
        try apply(m4)
        // Filler, so BM25 has a corpus (a term in half of four memories scores nothing).
        for (t, b) in [("Weekly status", "Shipped the export fix."), ("Dentist", "Cleaning on Tuesday at nine."),
                       ("Bike repair", "The rear brake squeaks."), ("Garden", "Plant the tomatoes in May."),
                       ("Taxes", "File the return by April."), ("Books", "Finish the novel on the train."),
                       ("Wine", "A dry white for the fish dinner."), ("Running", "Five kilometres before work.")] {
            try memory(t, b)
        }
        return Sisters(m1: m1, m2: m2, m3: m3, m4: m4)
    }

    func search(_ q: String, facts: FactsSearchConfig?, filter: MemoryFilter = MemoryFilter(status: .active)) async throws -> [SearchHit] {
        let s = SearchService(store: v.store, indexer: nil)
        s.facts = facts
        return try await s.vaultSearch(q, filter: filter, now: t0.plus(days: 1))
    }

    func ids(_ hits: [SearchHit]) -> [UUID] { hits.map(\.memoryID) }

    // MARK: Admission without a boost

    @Test func aNameAdmitsTheMemoriesThatOnlySayTheRole() async throws {
        let s = try sisters()
        let plain = try await search("What does Maria drink?", facts: nil)
        let hits = try await search("What does Maria drink?", facts: Self.config())
        let m2 = try #require(hits.first { $0.memoryID == s.m2.id })
        #expect(m2.admission?.way == .link && m2.admission?.link?.kind == .role)
        // Kept anyway by "drink", so no why line, but it scores by the rest of the query ("What does drink").
        #expect(plain.contains { $0.memoryID == s.m2.id } && m2.admission?.whyLine == nil)
        // Ana's matcha: linked only to someone the query doesn't name: −0.10.
        let m3 = try #require(hits.first { $0.memoryID == s.m3.id })
        let m3plain = try #require(plain.first { $0.memoryID == s.m3.id })
        #expect(m3.demoted && abs(m3.score - (m3plain.score - 0.10)) < 1e-6)
        #expect(ids(hits).firstIndex(of: s.m2.id)! < ids(hits).firstIndex(of: s.m3.id)!)
        #expect(!hits.contains { $0.memoryID == s.m4.id })
    }

    @Test func aRoleAdmitsTheMemoriesThatName() async throws {
        let s = try sisters()
        let hits = try await search("Porto", facts: Self.config())       // names no one: unchanged
        #expect(hits == (try await search("Porto", facts: nil)))
        let q = try await search("where did my sister grow up", facts: Self.config())
        #expect(q.contains { $0.memoryID == s.m1.id && $0.admission != nil })
    }

    @Test func aResultOnlyALinkAdmitsCarriesAWhyLine() async throws {
        let s = try sisters()
        let hits = try await search("Maria", facts: Self.config())
        let m2 = try #require(hits.first { $0.memoryID == s.m2.id })
        #expect(m2.plainRank == nil)
        let line = try #require(m2.admission?.whyLine)
        #expect(line.form == .role(surface: "My sister", name: "Maria"))
        #expect(line.basis == .link(.soleKnown) && line.label == "sister" && !line.untrusted)
        #expect(line.notName?.name == "Maria" && line.notThis != nil)
        // Plain search keeps m1 on its own: no why line.
        #expect(hits.first { $0.memoryID == s.m1.id }?.admission?.whyLine == nil)
    }

    @Test func severalHoldersAdmitForTheCandidateTheQueryNamesWithoutNames() async throws {
        let s = try sisters()
        let m5 = try memory("Elena is my sister too", "She lives in Lyon.")
        try apply(m5, person("Elena", Self.sib, label: "sister", quote: "Elena is my sister"))
        let hits = try await search("Elena", facts: Self.config())
        let m2 = try #require(hits.first { $0.memoryID == s.m2.id })
        let line = try #require(m2.admission?.whyLine)
        #expect(line.form == .candidates(attribute: "your sister") && line.notName == nil && line.notThis == nil)
    }

    @Test func aFilterStillApplies() async throws {
        let s = try sisters()
        let hits = try await search("Maria", facts: Self.config(), filter: MemoryFilter(status: .active, sensitivities: [.internal]))
        #expect(hits.isEmpty && !hits.contains { $0.memoryID == s.m2.id })
    }

    // MARK: Unchanged when off

    @Test func searchIsExactlyTodaysWhenOffUnqualifiedOrNamingNoOne() async throws {
        _ = try sisters()
        for q in ["What does Maria drink?", "my sister", "Ana", "coffee", "Maria's mate"] {
            let off = try await search(q, facts: nil)
            #expect(try await search(q, facts: Self.config(.none(.bundled))) == off, "no use on: \(q)")
            // The shipped records for no engine: no model, nothing on.
            #expect(try await search(q, facts: FactsSearchConfig(engines: [:], userAliases: [], cloudLimit: .upTo(.internal))) == off)
        }
        #expect(try await search("flat white", facts: Self.config()) == (try await search("flat white", facts: nil)))
    }

    @Test func linkedSwitchedOffAdmitsNothing() async throws {
        _ = try sisters()
        // Recorded but not linked: every predicate's *linked* switched off locally (whatever the model).
        let reg = FactsRegistry.bundled
        let engine = FactsQualificationTests.haiku
        var q = FactsQualification(records: [])
        for p in reg.predicates {
            q.off.insert(.init(predicate: p.id, use: .linked, engine: engine, promptVersion: FactsPrompt.version(p.callGroup, registry: reg),
                               registryVersion: reg.fingerprint))
        }
        let c = FactsSearchConfig(qualification: q,
                                  engines: Dictionary(uniqueKeysWithValues: reg.callGroups.keys.map { ($0, engine) }),
                                  userAliases: [], cloudLimit: .upTo(.internal))
        #expect(try await search("What does Maria drink?", facts: c) == (try await search("What does Maria drink?", facts: nil)))
    }

    // MARK: Corrections

    @Test func notNameDropsTheLinkForThisMemoryAtOnce() async throws {
        let s = try sisters()
        let before = try await search("Maria", facts: Self.config())
        let line = try #require(before.first { $0.memoryID == s.m2.id }?.admission?.whyLine?.notName)
        let n = try v.store.rejectLink(memoryID: line.memoryID, entity: line.entity, config: Self.config(), activity: activity, now: t0.plus(days: 1))
        #expect(n == 1)
        let after = try await search("Maria", facts: Self.config())
        #expect(!after.contains { $0.memoryID == s.m2.id })
        #expect(after.contains { $0.memoryID == s.m1.id })
        let row = try #require(activity.events.last)
        #expect(row.event == "facts_corrected" && row.counts == ["links": 1])
    }

    @Test func notNameOnANameLinkHoldsForEveryReader() async throws {
        let s = try sisters()
        let mate = try memory("Maria's mate gourd", "Maria left her gourd here.")
        try apply(mate, FactsExtraction(people: [ExtractedPerson(name: "Maria", quote: "Maria left her gourd")], roster: [:]))
        let maria = try #require(try await v.store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT entity_id FROM entity_alias WHERE alias = 'Maria'")
        })
        _ = try v.store.rejectLink(memoryID: mate.id, entity: maria, config: Self.config(), activity: activity, now: t0.plus(days: 1))
        let g = try await v.store.writer.read { db in try FactStore.load(db).graph }
        #expect(!g.names.contains { $0.key.memoryID == mate.id.db && $0.value.entity == maria })
        #expect(g.names.contains { $0.key.memoryID == s.m1.id.db && $0.value.entity == maria })
        let hits = try await search("my sister", facts: Self.config())
        #expect(hits.first { $0.memoryID == mate.id }?.admission == nil)
    }

    @Test func notThisRejectsTheFactEverywhere() async throws {
        let s = try sisters()
        let before = try await search("Maria", facts: Self.config())
        let fid = try #require(before.first { $0.memoryID == s.m2.id }?.admission?.whyLine?.notThis)
        try v.store.rejectFact(factID: fid, activity: activity, now: t0.plus(days: 1))
        let after = try await search("Maria", facts: Self.config())
        #expect(!after.contains { $0.memoryID == s.m2.id })      // "my sister" has no holder now
        #expect(activity.events.last?.counts == ["facts": 1])
    }

    // MARK: Owner side only

    @Test func agentRetrievalAndTheDuplicateHintNeverUseLinks() async throws {
        _ = try sisters()
        let plain = SearchService(store: v.store, indexer: nil)
        let withFacts = SearchService(store: v.store, indexer: nil)
        withFacts.facts = Self.config()
        for task in ["What does Maria drink?", "my sister", "Ana matcha"] {
            #expect(try await plain.retrieve(task: task) == (try await withFacts.retrieve(task: task)))
            #expect(try await plain.retrieveAll(task: task, keywords: ["Maria"]) == (try await withFacts.retrieveAll(task: task, keywords: ["Maria"])))
        }
        #expect(try await plain.nearDuplicates(title: "Maria", body: "my sister", kind: .fact, categoryNames: [])
                == (try await withFacts.nearDuplicates(title: "Maria", body: "my sister", kind: .fact, categoryNames: [])))
    }

    // MARK: Answers until 13d

    @Test func anAnswerReadsOnlyWhatPlainSearchWouldPutInItsTop() async throws {
        let s = try sisters()
        let service = SearchService(store: v.store, indexer: nil)
        service.facts = Self.config()
        let hits = try await service.vaultSearch("Maria", filter: MemoryFilter(status: .active), now: t0.plus(days: 1))
        let shown = hits.map(\.memoryID)
        #expect(shown.contains(s.m2.id))
        let read = try await service.answerSelection("Maria", ids: shown, filter: MemoryFilter(status: .active), count: 10, now: t0.plus(days: 1))
        #expect(!read.contains(s.m2.id) && read.contains(s.m1.id))
        // Without learned facts the list is plain search's own order: its top results are read as they are.
        service.facts = nil
        let plainShown = try await service.vaultSearch("Maria", filter: MemoryFilter(status: .active), now: t0.plus(days: 1)).map(\.memoryID)
        #expect(try await service.answerSelection("Maria", ids: plainShown, filter: MemoryFilter(status: .active), count: 10,
                                                  now: t0.plus(days: 1)) == Array(plainShown.prefix(10)))
    }

    // MARK: Matching (memory processing §11.4's cases)

    func index(aliases: [String] = []) throws -> FactsSearchIndex {
        try v.store.writer.read { db in
            try FactsSearchIndex.build(db, registry: .bundled, userAliases: aliases, uses: .everyDeclared(.bundled))
        }
    }

    @Test func matchingCases() async throws {
        _ = try sisters()
        let mayM = try memory("May runs the book club", "May is my friend.")
        try apply(mayM, person("May", Self.friend, label: "friend", quote: "May is my friend"))
        let ms = try memory("Maria Silva sent the deck", "Maria Silva is my friend from work.")
        try apply(ms, person("Maria Silva", Self.friend, label: "friend", quote: "Maria Silva is my friend"))
        let ix = try index(aliases: ["Ana"])
        func names(_ q: String) -> Set<String> {
            Set(ix.plan(q, today: "2026-11-19").matches.compactMap { ix.graph.entities[$0.entity]?.name })
        }
        #expect(names("What does Maria drink?") == ["Maria", "Maria Silva"])   // a first name matches everyone who has it
        #expect(names("Maria Silva's deck") == ["Maria Silva"])                 // longest first; a possessive
        #expect(names("in may we travel") == [])                                // a stop name in lower case
        #expect(names("May I see the deck") == [])                              // first word, not alone, not possessive
        #expect(names("What does May order?") == ["May"])
        #expect(names("May's book club") == ["May"])
        #expect(names("What does Will drink?") == [] || ix.eligible.allSatisfy { ix.graph.entities[$0]?.name != "Will" })
        #expect(names("Ana matcha") == [])                                      // your own name never matches
        #expect(names("my sister's husband") == [])                             // a possessive chain is someone else
        #expect(names("my sister") == ["Maria"])
        let plan = ix.plan("What does my sister drink?", today: "2026-11-19")
        #expect(plan.rest == "What does drink")
        #expect(ix.plan("my sister?", today: "2026-11-19").rest == "")
        #expect(ix.plan("de mi hermana", today: "2026-11-19").rest == "")     // the registry's function words go too
    }

    // MARK: Timeline

    @Test func aTimelineQueryAdmitsTheAnswersStatementsAndDemotesTheAnchor() async throws {
        let d = FX.dated
        let work = FX.registry.predicate(d)!.callGroup
        let a = try memory("Acme", "I worked at Acme from 2015 to 2018.")
        let i = try memory("Initech", "I joined Initech in 2019.")
        let i2 = try memory("Initech offsite", "The Initech offsite was in Lisbon.")
        try apply(a, FactsExtraction(facts: [fact(d, "Acme", "2015", "2018", status: .former, slot: FX.emp,
                                                  quote: "I worked at Acme from 2015 to 2018")]), group: work)
        try apply(i, FactsExtraction(facts: [fact(d, "Initech", "2019", status: .current, slot: FX.emp, quote: "I joined Initech in 2019")]),
                  group: work)
        try apply(i2, FactsExtraction(facts: [fact(d, "Initech", status: .current, slot: FX.emp, quote: "The Initech offsite")]), group: work)
        for (t, b) in [("Weekly status", "Shipped the export fix."), ("Dentist", "Cleaning on Tuesday at nine."),
                       ("Bike repair", "The rear brake squeaks."), ("Garden", "Plant the tomatoes."), ("Taxes", "File by April."),
                       ("Books", "Finish the novel."), ("Wine", "A dry white."), ("Running", "Five kilometres.")] { try memory(t, b) }
        let q = "Where did I work before Initech?"
        let plain = try await search(q, facts: nil)
        let hits = try await search(q, facts: Self.config())
        // Acme, the answer: admitted by the timeline, scored by the better of the query and its rest.
        let acme = try #require(hits.first { $0.memoryID == a.id })
        #expect(acme.admission?.way == .timeline && !acme.demoted)
        // Initech, the anchor: its memories aren't admitted by its name; they drop 0.10, once.
        for m in [i, i2] {
            guard let hit = hits.first(where: { $0.memoryID == m.id }) else { continue }
            let before = try #require(plain.first { $0.memoryID == m.id })
            #expect(hit.admission == nil && hit.demoted && abs(hit.score - (before.score - 0.10)) < 1e-6)
        }
        #expect(hits.contains { $0.memoryID == i.id })
        // Asked without naming Acme's words, the answer's memory isn't kept by plain search: its why line.
        let told = try await search("What was my job before Initech?", facts: Self.config())
        if let line = told.first(where: { $0.memoryID == a.id })?.admission?.whyLine {
            #expect(line.form == .timeline(noun: "job", op: "before", anchor: "Initech", answer: "Acme"))
            #expect(line.basis == .timeline(.ordered))
        }
        // The shipped uses (works at isn't linked): unchanged.
        let shipped = FactsSearchConfig(engines: [:], userAliases: [], cloudLimit: .upTo(.internal))
        #expect(try await search(q, facts: shipped) == (try await search(q, facts: nil)))
    }

    // MARK: Will, a stop name that's someone's name

    @Test func willMatchesOnlyWhenWrittenAsAName() async throws {
        _ = try sisters()
        let w = try memory("Will's bike", "Will is my friend; he fixes bikes.")
        try apply(w, person("Will", Self.friend, label: "friend", quote: "Will is my friend"))
        let ix = try index()
        func names(_ q: String) -> Set<String> {
            Set(ix.plan(q, today: "2026-11-19").matches.compactMap { ix.graph.entities[$0.entity]?.name })
        }
        #expect(names("What does Will drink?") == ["Will"])
        #expect(names("Will's birthday") == ["Will"])
        #expect(names("Will") == ["Will"])
        #expect(names("Will you remind me") == [])
        #expect(names("I will call") == [])
    }

    // MARK: Answers stay facts-free even when the list was made with them

    @Test func anAnswerFromAListMadeWithLearnedFactsReadsFactsFreeAfterTheyGoOff() async throws {
        let s = try sisters()
        let service = SearchService(store: v.store, indexer: nil)
        service.facts = Self.config()
        let shown = try await service.vaultSearch("Maria", filter: MemoryFilter(status: .active), now: t0.plus(days: 1)).map(\.memoryID)
        #expect(shown.contains(s.m2.id))
        service.facts = nil                      // turned off before the Ask; the list wasn't reloaded
        let read = try await service.answerSelection("Maria", ids: shown, filter: MemoryFilter(status: .active), count: 10, now: t0.plus(days: 1))
        #expect(!read.contains(s.m2.id))
        // After a relaunch with them off (a phone kept its results): still checked, from the vault's own record.
        let relaunched = SearchService(store: v.store, indexer: nil)
        let again = try await relaunched.answerSelection("Maria", ids: shown, filter: MemoryFilter(status: .active), count: 10,
                                                         now: t0.plus(days: 1))
        #expect(!again.contains(s.m2.id))
    }

    @Test func aNamesRangeKeepsItsLastCharacterWhole() {
        let text = "Jose\u{301} and 😀Ana came"      // an accent written apart; a surrogate pair before a name
        let r = FactsText.wholeWordRanges("José", in: text)
        #expect(r.count == 1 && (text as NSString).substring(with: r[0]) == "Jose\u{301}")
        let a = FactsText.wholeWordRanges("Ana", in: text)
        #expect(a.count == 1 && (text as NSString).substring(with: a[0]) == "Ana")
    }

    // MARK: Not <name> on a phrase that leaves them among its candidates

    @Test func notNameAlsoRejectsThemAsACandidate() async throws {
        let s = try sisters()
        let m5 = try memory("Elena is my sister too", "She lives in Lyon.")
        try apply(m5, person("Elena", Self.sib, label: "sister", quote: "Elena is my sister"))
        let service = SearchService(store: v.store, indexer: nil)
        service.facts = Self.config()
        let before = try await service.vaultSearch("Elena", filter: MemoryFilter(status: .active), now: t0.plus(days: 1))
        #expect(before.contains { $0.memoryID == s.m2.id })      // "my sister": Maria or Elena
        let elena = try #require(before.first { $0.memoryID == m5.id }?.admission?.entity
                                 ?? before.compactMap { $0.admission?.link?.candidates.first { _ in true } }.first)
        _ = try v.store.rejectLink(memoryID: s.m2.id, entity: elena, config: Self.config(), activity: activity, now: t0.plus(days: 1))
        let after = try await service.vaultSearch("Elena", filter: MemoryFilter(status: .active), now: t0.plus(days: 1))
        #expect(!after.contains { $0.memoryID == s.m2.id && $0.admission != nil })
    }

    // MARK: The rest of the query and the second index (memory processing §11.9)

    /// A second-index model that records every text it's asked to embed.
    final class Recording: EmbeddingProvider, @unchecked Sendable {
        let id: ProviderID = "test.recording"
        let locality: Locality
        let model = EmbeddingModelInfo(id: "test/recording", dimensions: 16, vaultThreshold: 0.99, retrievalThreshold: 0.99)
        private let lock = NSLock()
        private var log: [String] = []
        init(locality: Locality) { self.locality = locality }
        var texts: [String] { lock.withLock { log } }
        func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] {
            if role == .query { lock.withLock { log += texts } }
            return try await FakeEmbedder(dimensions: 16).embed(texts, as: role)
        }
    }

    func service(_ provider: Recording) async throws -> SearchService {
        let second = ProviderEmbeddingIndexer(store: v.store, provider: provider, cloudLimit: .upTo(.internal))
        _ = try await second.embedPending()
        #expect(second.isComplete)
        let s = SearchService(store: v.store, indexer: nil)
        s.secondIndex = SecondIndex(indexer: second)
        s.facts = Self.config()
        return s
    }

    @Test func theRestGoesToACloudIndexOnlyWhenEveryMatchIsSendable() async throws {
        _ = try sisters()
        let cloud = Recording(locality: .cloud)
        let s = try await service(cloud)
        _ = try await s.vaultSearch("Maria drink", filter: MemoryFilter(status: .active), now: t0.plus(days: 1))
        #expect(cloud.texts.contains("Maria drink") && cloud.texts.contains("drink"))
    }

    @Test func aMatchOnlyAboveTheLimitKeepsTheRestOnThisMac() async throws {
        let secret = try memory("Nadia is my sister", "We grew up in Porto together.", sensitivity: .sensitive)
        let m2 = try memory("My sister drinks her mate bitter", "Every morning, with no sugar.")
        try apply(secret, person("Nadia", Self.sib, label: "sister", quote: "Nadia is my sister"))
        try apply(m2)
        for (t, b) in [("Weekly status", "Shipped the export fix."), ("Dentist", "Cleaning on Tuesday at nine."),
                       ("Bike repair", "The rear brake squeaks."), ("Garden", "Plant the tomatoes.")] { try memory(t, b) }
        let cloud = Recording(locality: .cloud)
        let s = try await service(cloud)
        let hits = try await s.vaultSearch("Nadia drink", filter: MemoryFilter(status: .active), now: t0.plus(days: 1))
        #expect(hits.contains { $0.memoryID == m2.id && $0.admission != nil })    // the link still admits, on this Mac
        #expect(cloud.texts.contains("Nadia drink") && !cloud.texts.contains("drink"))
        // A local second index embeds the rest as it does the query.
        let local = Recording(locality: .localServer)
        let l = try await service(local)
        _ = try await l.vaultSearch("Nadia drink", filter: MemoryFilter(status: .active), now: t0.plus(days: 1))
        #expect(local.texts.contains("drink"))
    }
}
