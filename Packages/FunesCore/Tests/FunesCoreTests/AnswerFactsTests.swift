import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 13d: learned facts in search answers (memory processing §10.3–10.5, §11.9): facts off or unqualified leave
/// answers exactly as 13b's; with them, the view's selection, attributes, your names as "the user", inferred claims
/// marked by code, and dropping an answer only when what it rested on changed. Keyword-only search, so scores are exact.
@Suite struct AnswerFactsTests {
    let fx: FactsSearchTests
    let log = InMemoryActivityLog()
    var sib: String { FactsSearchTests.sib }

    init() throws { fx = try FactsSearchTests() }

    func service(_ facts: FactsSearchConfig?) -> SearchService {
        let s = SearchService(store: fx.v.store, indexer: nil)
        s.facts = facts
        return s
    }

    /// Answers `query` with a provider whose claims `claims` builds from the prompt (its refs), on `search`.
    func answer(_ query: String, search: SearchService, facts allowed: Bool = true, locality: Locality = .cloud,
                ids: [UUID]? = nil,
                claims: @escaping @Sendable (String) -> [[String: Any]] = { _ in [] }) async throws -> (SearchAnswer, String) {
        let provider = AnswerProvider(locality: locality) { prompt in
            let c = claims(prompt)
            return ["found": c.isEmpty ? "no" : "yes", "claims": c]
        }
        var shown = ids ?? []
        if ids == nil { shown = try await search.vaultSearch(query, filter: MemoryFilter(status: .active), now: t0.plus(days: 1)).map(\.memoryID) }
        let answerer = SearchAnswerer(store: fx.v.store, search: search, activity: log)
        let a = try await answerer.answer(query, ids: Array(shown.prefix(10)), facts: allowed,
                                          router: ModelRouter(classifier: provider, onDevice: nil), now: t0.plus(days: 1))
        return (a, provider.calls.first ?? "")
    }

    static func claim(_ text: String, _ cites: [(String?, String)]) -> [String: Any] {
        ["text": text, "citations": cites.map { ["ref": $0.0 ?? "m99", "quote": $0.1] }]
    }

    /// Uses with the person pool recorded and linked, nothing else (as shipped: no attributes record).
    static var linkedOnly: FactsUses {
        let reg = FactsRegistry.bundled
        var on = Set<FactsUses.Key>()
        for p in reg.predicates where p.objectKind == FactsValidator.personKind {
            on.insert(.init(predicate: p.id, use: .recorded, basis: ""))
            on.insert(.init(predicate: p.id, use: .linked, basis: ""))
        }
        return FactsUses(registry: reg, on: on)
    }

    // MARK: Off, or not qualified: 13b's answers, byte for byte

    @Test func withoutAnAttributesRecordAnswersAreThirteenBs() async throws {
        let s = try fx.sisters()
        let q = "What does Maria drink?"
        let claims: @Sendable (String) -> [[String: Any]] = { p in
            [Self.claim("Ana drinks matcha.", [(AnswerProvider.ref(of: "Ana drinks matcha", in: p), "Ana is my friend from the climbing gym.")])]
        }
        // Linked on, attributes off (the shipped records): the same request and answer as with learned facts off.
        let (a1, p1) = try await answer(q, search: service(FactsSearchTests.config(Self.linkedOnly)), claims: claims)
        let (a2, p2) = try await answer(q, search: service(nil), claims: claims)
        #expect(p1 == p2 && !p1.contains("about=") && a1.factsRevision == nil && a1.unreadLinked == 0)
        #expect(a1.read == a2.read && a1.withheld == a2.withheld && a1.claims == a2.claims && !a1.claims.isEmpty)
        #expect(a1.claims.allSatisfy { $0.inference == nil })
        // The real qualification (no record covers this answer model) is the same.
        let real = FactsSearchConfig(engines: [:], userAliases: [], cloudLimit: .upTo(.internal))
        let (_, p3) = try await answer(q, search: service(real))
        #expect(p3 == p2)
        _ = s
    }

    @Test func aCallThatCantShowFactsGetsThirteenBsAnswer() async throws {
        _ = try fx.sisters()
        let q = "What does Maria drink?"
        let on = service(FactsSearchTests.config())
        let (old, pOld) = try await answer(q, search: on, facts: false)
        let (_, pPlain) = try await answer(q, search: service(FactsSearchTests.config(Self.linkedOnly)))
        #expect(pOld == pPlain && old.claims.allSatisfy { $0.inference == nil } && old.factsRevision == nil)
    }

    // MARK: With learned facts in the answer

    @Test func attributesGoOnLinkedMemoriesAndTheMarkerMarksWhatTheQuoteDoesntSay() async throws {
        let s = try fx.sisters()
        let search = service(FactsSearchTests.config())
        let (a, prompt) = try await answer("What does Maria drink?", search: search) { p in
            let m2 = AnswerProvider.ref(of: "My sister drinks her mate bitter", in: p)
            let m1 = AnswerProvider.ref(of: "Maria is my sister", in: p)
            return [Self.claim("Maria drinks her mate bitter.", [(m2, "Every morning, with no sugar.")]),
                    Self.claim("Maria is your sister.", [(m1, "We grew up in Porto together.")])]
        }
        // The role phrase's only holder: sole_known, "probably", never quotable text.
        #expect(prompt.contains("about=\"probably Maria, your sister (the only one Funes knows)\">\n<title>My sister drinks her mate bitter"))
        #expect(!prompt.contains("<text>probably"))
        #expect(a.factsRevision != nil && a.claims.count == 2)
        let inferred = try #require(a.claims[0].inference)
        #expect(inferred.basis == "sole_known" && !inferred.factIDs.isEmpty)
        let targets = inferred.corrections.map(\.target)
        #expect(targets.contains { $0.what == .name && $0.memoryID == s.m2.id && $0.linkID == FactsCorrections.linkID(memory: s.m2.id, entity: inferred.corrections[0].target.linkID!.components(separatedBy: "/")[1]) })
        #expect(targets.contains { $0.what == .fact && $0.memoryID == nil && $0.factID == inferred.factIDs.first })
        #expect(targets.allSatisfy { !$0.token.isEmpty })
        #expect(inferred.corrections.first { $0.target.what == .name }?.name == "Maria")
        // The second cites m1, whose text names her and says "sister", but not in the quote: m1 links to Maria by name and
        // the search typed her name, so rule 1 doesn't fire; rule 4 does ("sister" isn't in the quote).
        #expect(a.claims[1].inference != nil)
        // Activity: counts only.
        let row = try #require(log.events.last)
        #expect(row.counts["inferred"] == 2 && row.counts["bridges"] == 0 && row.counts["unreadLinked"] == 0)
    }

    @Test func aClaimAboutSomeoneElseIsntMarked() async throws {
        _ = try fx.sisters()
        let (a, _) = try await answer("What does Maria drink?", search: service(FactsSearchTests.config())) { p in
            [Self.claim("Ana drinks matcha.", [(AnswerProvider.ref(of: "Ana drinks matcha", in: p), "Ana is my friend from the climbing gym.")])]
        }
        // Ana isn't who the search named, and the quote names her itself.
        #expect(a.claims.count == 1 && a.claims[0].inference == nil)
    }

    @Test func aRoleSearchAndAMemoryThatNamesThePersonIsMarked() async throws {
        _ = try fx.sisters()
        let m = try fx.memory("Maria's tea", "Maria drinks rooibos at night.")
        try fx.apply(m, fx.person("Maria", sib, label: "sister", quote: "Maria drinks rooibos"))
        let (a, _) = try await answer("What does my sister drink?", search: service(FactsSearchTests.config())) { p in
            [Self.claim("Maria drinks rooibos at night.", [(AnswerProvider.ref(of: "Maria's tea", in: p), "Maria drinks rooibos at night.")])]
        }
        // The quote names Maria but not "sister": that she's your sister is Funes's (Fable's finding 8).
        let inf = try #require(a.claims.first?.inference)
        #expect(inf.corrections.contains { $0.target.what == .name })
    }

    @Test func aSecondCitationNamingThePersonDoesntClearTheFirst() async throws {
        let s = try fx.sisters()
        let (a, _) = try await answer("What does Maria drink?", search: service(FactsSearchTests.config())) { p in
            let m2 = AnswerProvider.ref(of: "My sister drinks her mate bitter", in: p)
            let m1 = AnswerProvider.ref(of: "Maria is my sister", in: p)
            return [Self.claim("Maria drinks mate.", [(m2, "Every morning, with no sugar."), (m1, "We grew up in Porto together.")])]
        }
        _ = s
        #expect(a.claims.first?.inference != nil)
    }

    @Test func aNeighbouringAttributeMarksAClaimOnAPlainMemory() async throws {
        _ = try fx.sisters()
        let tea = try fx.memory("Drinks after dinner", "She prefers tea with lemon after dinner.")
        try fx.apply(tea)
        let (a, _) = try await answer("What does Maria drink after dinner?", search: service(FactsSearchTests.config())) { p in
            [Self.claim("Maria prefers tea with lemon.", [(AnswerProvider.ref(of: "Drinks after dinner", in: p), "She prefers tea with lemon after dinner.")])]
        }
        // The plain memory links to nobody; the input says something inferred about Maria elsewhere (m2's attribute).
        let inf = try #require(a.claims.first?.inference)
        #expect(!inf.corrections.isEmpty)
    }

    @Test func aSearchThatNamesNobodyMarksNothing() async throws {
        _ = try fx.sisters()
        let (a, _) = try await answer("oat milk flat white", search: service(FactsSearchTests.config())) { p in
            [Self.claim("You drink a flat white with oat milk.", [(AnswerProvider.ref(of: "Coffee order", in: p), "A flat white with oat milk.")])]
        }
        #expect(a.claims.count == 1 && a.claims[0].inference == nil)
    }

    @Test func yourNamesBecomeTheUserAndQuotesMapBack() async throws {
        _ = try fx.sisters()
        let m = try fx.memory("Seats", "Dani prefers window seats on long flights. Dani Ortiz prefers the aisle.")
        try fx.apply(m)
        let (a, prompt) = try await answer("window seats Maria", search: service(FactsSearchTests.config(aliases: ["Dani"]))) { p in
            [Self.claim("You prefer window seats.", [(AnswerProvider.ref(of: "Seats", in: p), "the user prefers window seats on long flights")])]
        }
        #expect(prompt.contains("the user prefers window seats"))
        let quote = try #require(a.claims.first?.citations.first?.quote)
        #expect(quote == "Dani prefers window seats on long flights")
        // The search text isn't rewritten.
        #expect(prompt.contains("<search>window seats Maria</search>"))
    }

    // MARK: Selection (memory processing §11.9)

    /// Vault A and B hold the same memories; only A learned, from a Sensitive note, that Ana is your sister (B read that
    /// note and learned nothing): facts stated only above the limit. A low memory names Ana.
    func drinkVault(restricted: Bool) throws {
        // Each a day apart, so ties in score order the same way in both vaults (by date, never by random id).
        var day = 0.0
        func next() -> Double { day += 1; return day }
        // More than ten that match "drink", so what the full graph admits pushes some out of its first ten.
        for (t, b) in [("Morning", "I drink green tea at seven."), ("Office", "We drink filter coffee at work."),
                       ("Gym", "After climbing I drink coconut water."), ("Dinner", "With fish we drink a dry white."),
                       ("Brunch", "On Sundays we drink fresh orange juice."), ("Flight", "On planes I drink tomato juice."),
                       ("Party", "At parties I drink sparkling wine."), ("Cold", "When I'm ill I drink ginger tea."),
                       ("Hike", "On hikes I drink from a steel bottle."), ("Night", "Late at night I drink chamomile."),
                       ("Market", "At the market we drink a quick espresso."), ("Beach", "At the beach we drink cold lemonade."),
                       ("Taxes", "File the return by April."), ("Garden", "Plant the tomatoes in May."),
                       ("Books", "Finish the novel on the train."), ("Running", "Five kilometres before work.")] {
            try fx.apply(try fx.memory(t, b, at: next()))
        }
        // Memories that say "sister" without saying "drink": plain search keeps them for the word, so they hold places in
        // its first ten in both vaults.
        for (t, b) in [("Sister act", "Tickets for the sister act revival."), ("Sister city", "Porto's sister city festival."),
                       ("Sister's bike", "Fix the sister bike's chain.")] {
            try fx.apply(try fx.memory(t, b, at: next()))
        }
        // In A the Sensitive note is read first and introduces Ana, so the sendable graph doesn't know her; in B it's read
        // with nothing learned.
        let r = try fx.memory("Family note", "Ana es mi hermana.", sensitivity: .sensitive, at: next())
        try fx.apply(r, restricted ? fx.person("Ana", sib, label: "sister", quote: "Ana es mi hermana") : FactsExtraction(), at: day)
        let ana = try fx.memory("Ana's drink", "Ana's drink: sparkling water.", at: next())
        try fx.apply(ana, FactsExtraction(people: [ExtractedPerson(name: "Ana", quote: "Ana always orders")]), at: day)
    }

    @Test func whatsAboveTheLimitDecidesNothingACloudAnswerReads() async throws {
        let b = try AnswerFactsTests()
        try fx.prepare { try drinkVault(restricted: true) }
        try b.fx.prepare { try b.drinkVault(restricted: false) }
        let q = "What does my sister drink?"
        let (aA, pA) = try await answer(q, search: service(FactsSearchTests.config()))
        let (aB, pB) = try await b.answer(q, search: b.service(FactsSearchTests.config()))
        #expect(pA == pB && aA.read == aB.read)
        // In A, the full graph did admit the low memory naming Ana (the user sees it), but it isn't read, and the
        // restricted note in the list counts as withheld.
        let wholeA = try await service(FactsSearchTests.config()).vaultSearch(q, filter: MemoryFilter(status: .active), now: t0.plus(days: 1))
        let wholeB = try await b.service(FactsSearchTests.config()).vaultSearch(q, filter: MemoryFilter(status: .active), now: t0.plus(days: 1))
        #expect(wholeA.count > wholeB.count)
        // The full graph reordered A's first ten (Ana's memory, admitted through the restricted note, moved up and pushed
        // another out), and yet the cloud request is B's.
        let topA = try wholeA.prefix(10).map { try fx.v.store.memory(id: $0.memoryID)?.title ?? "" }
        let topB = try wholeB.prefix(10).map { try b.fx.v.store.memory(id: $0.memoryID)?.title ?? "" }
        #expect(Set(topA) != Set(topB), "no displacement: \(topA) vs \(topB)")
        #expect(aA.unreadLinked >= 1 && aB.unreadLinked == 0)
        // An older phone's answer too.
        let (_, oA) = try await answer(q, search: service(FactsSearchTests.config()), facts: false)
        let (_, oB) = try await b.answer(q, search: b.service(FactsSearchTests.config()), facts: false)
        #expect(oA == oB)
    }

    @Test func aLocalModelReadsTheResultsAsShown() async throws {
        try drinkVault(restricted: true)
        let q = "What does my sister drink?"
        let (a, prompt) = try await answer(q, search: service(FactsSearchTests.config()), locality: .localServer)
        let whole = try await service(FactsSearchTests.config()).vaultSearch(q, filter: MemoryFilter(status: .active), now: t0.plus(days: 1))
        let first = try whole.prefix(10).map { try fx.v.store.memory(id: $0.memoryID)?.title ?? "" }
        // The whole graph, the results as shown, in their order: the Sensitive note's fact included.
        #expect(a.unreadLinked == 0 && a.read == first.count)
        for (i, title) in first.enumerated() { #expect(prompt.contains("<memory ref=\"m\(i + 1)\"") && prompt.contains("<title>\(title)</title>")) }
        #expect(prompt.contains("about=\"probably Ana, your sister (the only one Funes knows)\">\n<title>Ana's drink"))
    }

    @Test func thePhonesIdsAreNeverTrustedAlone() async throws {
        let s = try fx.sisters()
        // Ids the search wouldn't show for this query: the answer reads what the query admits.
        let (a, prompt) = try await answer("What does Maria drink?", search: service(FactsSearchTests.config()), ids: [s.m4.id])
        #expect(a.read > 1 && prompt.contains("My sister drinks her mate bitter") && !prompt.contains("Coffee order"))
    }

    // MARK: The facts revision (memory processing §10.5)

    @Test func anAnswerIsDroppedOnlyWhenWhatItRestedOnChanged() async throws {
        let s = try fx.sisters()
        let search = service(FactsSearchTests.config())
        let store = fx.v.store
        // A reading of an unrelated memory while the call is out: the revision moves, the answer stands.
        let (kept, _) = try await answer("What does Maria drink?", search: search) { _ in
            try? store.writer.write { db in try FactStore.bumpRevision(db) }
            return []
        }
        #expect(kept.outcome == .noAnswer)
        // Not this on Maria's sisterhood while the call is out: dropped.
        let factID = try #require(try await store.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM fact LIMIT 1") })
        await #expect(throws: SearchAnswerError.factsChanged) {
            _ = try await answer("What does Maria drink?", search: search) { _ in
                try? store.rejectFact(factID: factID, activity: InMemoryActivityLog())
                return []
            }
        }
        #expect(log.events.last?.code == "facts_changed")
        _ = s
    }
}

extension AnswerFactsTests {
    // MARK: More marking cases and the send boundary

    @Test func oneWordOfAPredicateDoesntSayAnother() async throws {
        _ = try fx.sisters()
        let partner = FX.personPredicate { $0.lexicon.contains { $0.words.contains("girlfriend") } }
        let m = try fx.memory("Lena is my girlfriend", "We met at the climbing gym. She loves oolong.")
        try fx.apply(m, fx.person("Lena", partner, label: "girlfriend", quote: "Lena is my girlfriend"))
        let (a, _) = try await answer("What does Lena love?", search: service(FactsSearchTests.config())) { p in
            [Self.claim("Lena, your wife, loves oolong.", [(AnswerProvider.ref(of: "Lena is my girlfriend", in: p), "We met at the climbing gym. She loves oolong.")]),
             Self.claim("Lena is your girlfriend.", [(AnswerProvider.ref(of: "Lena is my girlfriend", in: p), "We met at the climbing gym. She loves oolong.")])]
        }
        // "wife" isn't said by "girlfriend", though both are the partner's (Astra's diff finding 2); "girlfriend" isn't in
        // that quote either.
        #expect(a.claims.count == 2 && a.claims.allSatisfy { $0.inference != nil })
    }

    @Test func theSendBoundaryRefusesAnAttributeWhoseEvidenceRoseAboveTheLimit() async throws {
        let s = try fx.sisters()
        let search = service(FactsSearchTests.config())
        let plan = try #require(await search.answerPlan("What does Maria drink?", filter: MemoryFilter(status: .active), count: 10,
                                                         view: .sendable(.upTo(.internal)), answerModel: "m", onDevice: false,
                                                         now: t0.plus(days: 1)))
        let attribute = try #require(plan.attributes[s.m2.id])
        #expect(attribute.behind.contains(s.m1.id.db))
        let router = ModelRouter(classifier: AnswerProvider(), onDevice: nil)
        let check = SearchAnswerer.sendCheck(plan, sent: [], attributes: plan.attributes, router: router, config: search.facts, answerModel: "m")
        #expect(try await fx.v.store.writer.read(check))
        // "Maria is my sister" becomes Sensitive after the plan: the attribute can't go.
        _ = try fx.v.store.updateMemory(id: s.m1.id, MemoryEdit(sensitivity: .sensitive), now: t0.plus(days: 1))
        #expect(try await !fx.v.store.writer.read(check))
        // A local model has no limit.
        let local = ModelRouter(classifier: AnswerProvider(locality: .localServer), onDevice: nil)
        #expect(try await fx.v.store.writer.read(SearchAnswerer.sendCheck(plan, sent: [], attributes: plan.attributes, router: local,
                                                                     config: search.facts, answerModel: "m")))
    }

    /// 13b's request builder, frozen as it was before 13d: with nothing learned, today's builder must give the same bytes.
    static func thirteenB(query: String, sent: [SearchAnswerer.Sent], context: SearchAnswerer.Context, now: Date) -> String {
        var lines = ["Today is \(DecisionPrompt.day(now)) (\(SearchAnswerer.weekday(now))).", "<search>\(SearchAnswerer.neutralized(query))</search>"]
        for (i, s) in sent.enumerated() {
            let m = s.memory
            let categories = m.categoryKeys.map { context.categoryNames[$0] ?? $0 }.joined(separator: ", ")
            lines.append("<memory ref=\"m\(i + 1)\" kind=\"\(m.kind.rawValue)\" categories=\"\(SearchAnswerer.attribute(categories))\" "
                         + "created=\"\(DecisionPrompt.day(m.createdAt))\" updated=\"\(DecisionPrompt.day(m.updatedAt))\" "
                         + "source=\"\(SearchAnswerer.source(m, trust: context.trust[m.id]))\">\n<title>\(SearchAnswerer.neutralized(m.title))</title>\n"
                         + "<text>\(SearchAnswerer.neutralized(s.text))</text>\n</memory>")
        }
        return lines.joined(separator: "\n")
    }

    @Test func withNothingLearnedTheRequestIsThirteenBs() throws {
        let sent = SearchAnswererTests.sent(["A note <memory> with a tag", "First … second"])
        let context = SearchAnswerer.Context(categoryNames: [:], trust: [:])
        let r = SearchAnswerer.request(query: "q <search>", sent: sent, bridges: [], attributes: [:], context: context, now: t0)
        #expect(r.prompt == Self.thirteenB(query: "q <search>", sent: sent, context: context, now: t0))
        #expect(r.schema.json == SearchAnswerer.schema.json && r.instructions == SearchAnswerer.instructions)
    }
}

extension AnswerFactsTests {
    // MARK: After the diff reviews

    /// The answer prompt's version is what an attributes record names: changing what it covers needs a new version.
    @Test func thePromptVersionCoversWhatItNames() {
        // 13e.2: the rows' rules and schema, the cited memories' limits and the check's wording too.
        let rows = TimelineRows(predicate: FX.dated, rows: [])
        let covered = [SearchAnswerer.instructions, SearchAnswerer.schema.json, SearchAnswerer.bridgeSchema.json,
                       SearchAnswerer.rowsSchema.json, SearchAnswerer.rowsInstructions(rows), rows.block()]
            + AnswerAttributes.templates
            + [SearchAnswerer.citedCount, SearchAnswerer.textLimit, TimelineRows.limit, TimelineRows.citedTextLimit,
               TimelineRows.citedTotalLimit].map(String.init)
        let digest = FactsCorrections.digest(covered)
        // If this fails, bump `SearchAnswerer.promptVersion` (an attributes or timeline record measured the old prompt) and
        // update it.
        #expect(SearchAnswerer.promptVersion == "a13e2-1" && digest == Self.pinnedDigest, "\(digest)")
    }
    static let pinnedDigest = "3YqKijMhuqYrdf8VJmfb7w"

    @Test func aMemoryThatNamesThePersonElsewhereIsntMarkedForTheName() async throws {
        _ = try fx.sisters()
        let m = try fx.memory("Maria's tea", "Rooibos at night, no milk.")
        try fx.apply(m, FactsExtraction(people: [ExtractedPerson(name: "Maria", quote: "Maria's tea")]))
        let (a, _) = try await answer("What does Maria drink at night?", search: service(FactsSearchTests.config())) { p in
            [Self.claim("Maria drinks rooibos at night.", [(AnswerProvider.ref(of: "Maria's tea", in: p), "Rooibos at night, no milk.")])]
        }
        // Its title names her (a full-basis name link): the claim rests on the memory, not on Funes (Fable's finding 3).
        #expect(a.claims.first?.inference == nil)
    }

    @Test func anAttributeNeverStatesWhatOnlyUntrustedTextSays() async throws {
        let agent = try fx.memory("Imported family", "Maria is my sister.")
        try await fx.v.store.writer.write { db in
            try db.execute(sql: "UPDATE memory SET trust = 'untrusted', source = 'agent_write' WHERE id = ?", arguments: [agent.id.db])
        }
        try fx.apply(agent, fx.person("Maria", sib, label: "sister", quote: "Maria is my sister"))
        let mate = try fx.memory("Maria and mate", "Maria drinks mate every morning.")
        try fx.apply(mate, FactsExtraction(people: [ExtractedPerson(name: "Maria", quote: "Maria drinks mate")]))
        for (t, b) in [("Taxes", "File the return by April."), ("Garden", "Plant the tomatoes in May."), ("Books", "Finish the novel.")] {
            try fx.apply(try fx.memory(t, b))
        }
        let (_, prompt) = try await answer("Maria", search: service(FactsSearchTests.config()))
        #expect(prompt.contains("<title>Maria and mate</title>") && !prompt.contains("your sister"))
    }

    @Test func aWithheldSecondSisterChangesNothingACloudAnswerSees() async throws {
        let b = try AnswerFactsTests()
        for (isA, v) in [(true, self), (false, b)] {
            let maria = try v.fx.memory("Maria is my sister", "We grew up in Porto together.", at: 1)
            try v.fx.apply(maria, v.fx.person("Maria", v.sib, label: "sister", quote: "Maria is my sister"), at: 1)
            let elena = try v.fx.memory("Elena", "Elena is my sister too.", sensitivity: .sensitive, at: 2)
            // Only A learned it; B read the same note and learned nothing.
            try v.fx.apply(elena, isA ? v.fx.person("Elena", v.sib, label: "sister", quote: "Elena is my sister") : FactsExtraction(), at: 2)
            let mate = try v.fx.memory("My sister drinks her mate bitter", "Every morning, with no sugar.", at: 3)
            try v.fx.apply(mate, at: 3)
            for (i, (t, body)) in [("Taxes", "File the return by April."), ("Garden", "Plant the tomatoes in May."),
                                   ("Books", "Finish the novel."), ("Wine", "A dry white for fish.")].enumerated() {
                try v.fx.apply(try v.fx.memory(t, body, at: Double(4 + i)), at: Double(4 + i))
            }
        }
        let q = "What does Maria drink?"
        let (aA, pA) = try await answer(q, search: service(FactsSearchTests.config()))
        let (aB, pB) = try await b.answer(q, search: b.service(FactsSearchTests.config()))
        // A's full graph has two sisters (candidates); the view, as if only what's sendable existed, has one, as B does.
        let hit = try await service(FactsSearchTests.config()).vaultSearch(q, filter: MemoryFilter(status: .active), now: t0.plus(days: 1))
            .first { (try? fx.v.store.memory(id: $0.memoryID)?.title) == "My sister drinks her mate bitter" }
        #expect(hit?.admission?.link?.basis == .candidates)
        #expect(pA == pB && aA.read == aB.read && pA.contains("about=\"probably Maria, your sister (the only one Funes knows)\""))
    }

    @Test func notNameAfterAPhraseCameToMeanThemIsAppliedAgain() async throws {
        let store = fx.v.store
        let x = try fx.memory("Porto trip", "Lucía said hello. My sister was there too.", at: 1)
        try fx.apply(x, FactsExtraction(people: [ExtractedPerson(name: "Lucía", quote: "Lucía said hello")]), at: 1)
        let lucia = try #require(try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT entity_id FROM entity_alias WHERE alias = 'Lucía'")
        })
        func target() async throws -> FactsCorrectionTarget {
            let blank = FactsCorrectionTarget(what: .name, linkID: FactsCorrections.linkID(memory: x.id, entity: lucia), memoryID: x.id, token: "")
            var t = blank
            t.token = try #require(try await store.writer.read { db in try FactsCorrections.token(db, blank) })
            return t
        }
        let first = try await target()
        #expect(try store.applyCorrection(first, config: FactsSearchTests.config(), activity: log, now: t0.plus(days: 2)) == .applied)
        #expect(try store.applyCorrection(first, config: FactsSearchTests.config(), activity: log, now: t0.plus(days: 2)) == .already)
        // Later Funes learns Lucía is your sister: "My sister" in the trip note now resolves to her, a new mention.
        let y = try fx.memory("Lucía is my sister", "She lives in Montevideo.", at: 3)
        try fx.apply(y, fx.person("Lucía", sib, label: "sister", quote: "Lucía is my sister"), at: 3)
        // The old target: something still links the memory to her, and its token no longer holds.
        #expect(try store.applyCorrection(first, config: FactsSearchTests.config(), activity: log, now: t0.plus(days: 4)) == .changed)
        // The one the phone gets now: applied, not "already" (Fable's diff finding 4).
        #expect(try await store.applyCorrection(target(), config: FactsSearchTests.config(), activity: log, now: t0.plus(days: 4)) == .applied)
        #expect(try await store.applyCorrection(target(), config: FactsSearchTests.config(), activity: log, now: t0.plus(days: 4)) == .already)
    }

    @Test func aLongBodySendsYourNamesAsTheUserInEveryPassageAndKeepsANamesake() async throws {
        _ = try fx.sisters()
        let filler = (0..<40).map { "Filler sentence \($0) about the weather." }.joined(separator: " ")
        let body = filler + " Dani booked the window seat for Lisbon. " + filler + " Dani Ortiz booked the aisle for Lisbon. " + filler
        let m = try fx.memory("Lisbon flight", body)
        try fx.apply(m)
        let (a, prompt) = try await answer("Lisbon seat Maria", search: service(FactsSearchTests.config(aliases: ["Dani"]))) { p in
            [Self.claim("You booked the window seat.", [(AnswerProvider.ref(of: "Lisbon flight", in: p), "the user booked the window seat for Lisbon")])]
        }
        #expect(prompt.contains("the user booked the window seat for Lisbon") && prompt.contains("Dani Ortiz booked the aisle"))
        #expect(!prompt.contains("the user Ortiz") && prompt.contains(BodyMatches.passageJoin))
        #expect(a.claims.first?.citations.first?.quote == "Dani booked the window seat for Lisbon")
    }
}

extension AnswerFactsTests {
    // MARK: Corrections from a target (companion protocol §4 facts.reject)

    /// The targets an answer offered for "Maria drinks her mate bitter", citing m2.
    func targets() async throws -> (FactsSearchTests.Sisters, [FactsCorrectionTarget]) {
        let s = try fx.sisters()
        let (a, _) = try await answer("What does Maria drink?", search: service(FactsSearchTests.config())) { p in
            [Self.claim("Maria drinks her mate bitter.", [(AnswerProvider.ref(of: "My sister drinks her mate bitter", in: p), "Every morning, with no sugar.")])]
        }
        return (s, try #require(a.claims.first?.inference).corrections.map(\.target))
    }

    @Test func notNameFromATargetAppliesOnceAndAgainChangesNothing() async throws {
        let (_, ts) = try await targets()
        let name = try #require(ts.first { $0.what == .name })
        let store = fx.v.store
        let before = try await store.writer.read { db in try FactStore.revision(db) }
        let phone = Actor.device(UUID())
        #expect(try store.applyCorrection(name, config: FactsSearchTests.config(), activity: log, actor: phone, via: .companion,
                                     now: t0.plus(days: 2)) == .applied)
        let after = try await store.writer.read { db in try FactStore.revision(db) }
        #expect(after != before)
        let row = try #require(log.events.last)
        #expect(row.event == "facts_corrected" && row.actor == phone.description && row.via == .companion && row.counts["links"] != nil)
        #expect(FactsActivityWords(row)?.title == "Corrected a fact")
        // A repeat (a reply lost on the way): nothing more, the revision unmoved, no Activity row.
        let rows = log.events.count
        #expect(try store.applyCorrection(name, config: FactsSearchTests.config(), activity: log, now: t0.plus(days: 3)) == .already)
        #expect(try await store.writer.read { db in try FactStore.revision(db) } == after && log.events.count == rows)
    }

    @Test func aStaleTargetIsRefusedAndAGoneOneIsNotFound() async throws {
        let (s, ts) = try await targets()
        let store = fx.v.store
        let name = try #require(ts.first { $0.what == .name })
        // The memory was edited since: its token no longer holds.
        _ = try store.updateMemory(id: s.m2.id, MemoryEdit(body: "Every morning, no sugar, at seven."), now: t0.plus(days: 2))
        #expect(try store.applyCorrection(name, config: FactsSearchTests.config(), activity: log) == .changed)
        var gone = name
        gone.linkID = FactsCorrections.linkID(memory: UUID(), entity: "nobody")
        gone.memoryID = nil
        #expect(try store.applyCorrection(gone, config: FactsSearchTests.config(), activity: log) == .notFound)
        // A name target whose memory isn't its link's, and an order (until bridges ship), aren't taken.
        var other = name
        other.memoryID = s.m1.id
        #expect(try store.applyCorrection(other, config: FactsSearchTests.config(), activity: log) == .invalid)
        #expect(try store.applyCorrection(FactsCorrectionTarget(what: .order, orderID: "x", token: "t"), config: FactsSearchTests.config(),
                                          activity: log) == .invalid)
    }

    @Test func notThisFromATargetRejectsTheFactEverywhere() async throws {
        let (_, ts) = try await targets()
        let store = fx.v.store
        let fact = try #require(ts.first { $0.what == .fact })
        #expect(fact.memoryID == nil)
        #expect(try store.applyCorrection(fact, config: FactsSearchTests.config(), activity: log) == .applied)
        #expect(try store.applyCorrection(fact, config: FactsSearchTests.config(), activity: log) == .already)
        // The link it rested on goes: Maria's sisterhood no longer admits "my sister".
        let hits = try await service(FactsSearchTests.config()).vaultSearch("Maria", filter: MemoryFilter(status: .active), now: t0.plus(days: 2))
        #expect(!hits.contains { $0.admission?.link?.kind == .role })
        var wrong = fact
        wrong.token = "AAAAAAAAAAAAAAAAAAAAAA"
        wrong.memoryID = UUID()
        #expect(try store.applyCorrection(wrong, config: FactsSearchTests.config(), activity: log) == .notFound)
    }
}

extension FactsSearchTests {
    /// Runs a fixture builder (for a second vault's own instance).
    func prepare(_ build: () throws -> Void) throws { try build() }
}
