import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// Search answers on the iPhone (FR-iOS-13, UX: iPhone ▸ Search): the Ask pill, the card's states,
/// what clears it, and the words.
@MainActor @Suite struct SearchAnswerTests {
    static let claude = SearchAnswersStatus(engine: "Claude (Claude Code)", locality: .cloud)

    static func loaded(_ vault: FakeVault, query: String = "coffee", log: FailureLog? = nil) async -> SearchModel {
        let search = log.map { SearchModel(caller: vault, onFailure: $0.record) } ?? SearchModel(caller: vault)
        search.macAnswers = claude
        search.query = query
        await search.search()
        return search
    }

    @Test func askSendsTheFirstTenResultsShownAndShowsTheAnswer() async throws {
        let vault = FakeVault()
        for i in 0..<12 { vault.add("Coffee \(i)", body: "Oat milk flat white number \(i).", updated: TimeInterval(-i)) }
        let search = await Self.loaded(vault, query: "  coffee ")
        #expect(search.canAsk)
        await search.ask()
        let ask = try #require(vault.asks.last)
        #expect(ask.query == "coffee" && ask.ids == Array(search.results.prefix(10).map(\.id)) && ask.filters == nil)
        guard case let .answered(result, total) = search.answer else { Issue.record("\(search.answer)"); return }
        #expect(total == 12 && result.claims.first?.citations.first?.id == search.results[0].id)
        // The pill hides while the card shows.
        #expect(!search.canAsk)
    }

    @Test func thePillShowsOnlyWhenTheMacAnswersAndInTheActiveScope() async throws {
        let vault = FakeVault()
        vault.add("Coffee")
        vault.add("Old coffee", status: .archived)
        let search = await Self.loaded(vault)
        #expect(search.canAsk)
        search.showAsk = false
        #expect(!search.canAsk)
        search.showAsk = true
        search.macAnswers = nil
        #expect(!search.canAsk)
        search.macAnswers = Self.claude
        search.scope = .archived
        await search.search()
        #expect(!search.canAsk)
        // An empty search lists memories: nothing to ask.
        search.scope = .active
        search.query = ""
        await search.search()
        #expect(!search.canAsk)
    }

    @Test func aNewSearchCancelAndAnswersOffClearTheCard() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        vault.add("Tea", body: "Green tea in the afternoon.")
        let search = await Self.loaded(vault)
        await search.ask()
        #expect(search.answer != .idle)
        search.query = "tea"
        #expect(search.answer == .idle)
        await search.search()
        await search.ask()
        search.clearAnswer()
        #expect(search.answer == .idle)
        await search.ask()
        search.macAnswers = nil
        #expect(search.answer == .idle)
    }

    /// Opening a memory (or another tab) and coming back: Search reloads, and the card is still
    /// there, with no second call.
    @Test func theAnswerStaysAfterOpeningAMemory() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        let search = await Self.loaded(vault)
        search.visible = true
        await search.ask()
        let shown = search.answer
        search.visible = false
        search.visible = true
        await search.search()
        #expect(search.answer == shown && !search.canAsk && vault.asks.count == 1)
        guard case .answered = search.answer else { Issue.record("\(search.answer)"); return }
    }

    /// An answer still on its way when a memory opens lands when Search comes back.
    @Test func anAnswerOnItsWayLandsAfterComingBack() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        vault.answerDelay = .milliseconds(300)
        let search = await Self.loaded(vault)
        let asking = Task { await search.ask() }
        try await Task.sleep(for: .milliseconds(50))
        search.visible = false
        search.visible = true
        await search.search()
        #expect(search.answer == .reading(count: 1))
        await asking.value
        guard case .answered = search.answer else { Issue.record("\(search.answer)"); return }
        #expect(vault.asks.count == 1)
    }

    /// Another search clears the card; back to the answered one, its answer comes back. Clear
    /// means it doesn't.
    @Test func theLastAnswerComesBackWithItsSearch() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        vault.add("Tea", body: "Green tea in the afternoon.")
        let search = await Self.loaded(vault)
        await search.ask()
        let shown = search.answer
        search.query = "tea"
        await search.search()
        #expect(search.answer == .idle && search.canAsk && search.sourceNumber(search.results[0].id) == nil)
        search.query = "coffee"
        await search.search()
        #expect(search.answer == shown && vault.asks.count == 1 && search.sourceNumber(search.results[0].id) == 1)
        search.clearAnswer()
        search.query = "tea"
        await search.search()
        search.query = "coffee"
        await search.search()
        #expect(search.answer == .idle && search.canAsk)
    }

    /// Only the last answer is kept, and only for the same memories, unedited, while the Mac
    /// answers and Ask shows; nothing stays once the phone leaves the Mac.
    @Test func theKeptAnswerIsDroppedWhenItNoLongerFits() async throws {
        let vault = FakeVault()
        let coffee = vault.add("Coffee", body: "Oat milk flat white.")
        vault.add("Tea", body: "Green tea in the afternoon.")
        let search = await Self.loaded(vault)
        await search.ask()
        // Edited on the Mac: the answer may be out of date.
        vault.macEdit(coffee.id, body: "Cortado now.", updated: 60)
        await search.search()
        #expect(search.answer == .idle && search.canAsk)

        await search.ask()
        // A new result among those read.
        vault.add("Coffee beans", updated: 120)
        await search.search()
        #expect(search.answer == .idle)

        // A newer answer replaces the older one.
        await search.ask()
        search.query = "tea"
        await search.search()
        await search.ask()
        search.query = "coffee"
        await search.search()
        #expect(search.answer == .idle)

        await search.ask()
        search.query = "tea"
        search.showAsk = false
        search.query = "coffee"
        await search.search()
        #expect(search.answer == .idle)
        search.showAsk = true

        search.macAnswers = nil
        search.macAnswers = Self.claude
        await search.search()
        #expect(search.answer == .idle && search.canAsk)

        // The Mac answers with another model now.
        await search.ask()
        search.query = "tea"
        search.macAnswers = SearchAnswersStatus(engine: "GPT-6-Luna (Codex)", locality: .cloud)
        search.query = "coffee"
        await search.search()
        #expect(search.answer == .idle)

        await search.ask()
        search.clear()
        search.query = "coffee"
        await search.search()
        #expect(search.answer == .idle && vault.asks.count == 7)
    }

    /// The Mac changes model: the card goes, an answer on its way from the previous model is
    /// dropped, and nothing comes back with the search.
    @Test func anotherModelDropsTheCardAndAnAnswerOnItsWay() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        let search = await Self.loaded(vault)
        await search.ask()
        search.macAnswers = SearchAnswersStatus(engine: "GPT-6-Luna (Codex)", locality: .cloud)
        #expect(search.answer == .idle && search.canAsk)

        vault.answerDelay = .milliseconds(300)
        let asking = Task { await search.ask() }
        try await Task.sleep(for: .milliseconds(50))
        search.macAnswers = Self.claude
        await asking.value
        #expect(search.answer == .idle)
        await search.search()
        #expect(search.answer == .idle && search.canAsk)
    }

    /// A memory the answer read, edited, archived or deleted from its detail: the card goes at
    /// once and doesn't come back; an unrelated change leaves it.
    @Test func editingAMemoryItReadDropsTheCard() async throws {
        let vault = FakeVault()
        let coffee = vault.add("Coffee", body: "Oat milk flat white.")
        let tea = vault.add("Tea", body: "Green tea in the afternoon.")
        let search = await Self.loaded(vault)
        await search.ask()
        search.changed(tea)
        search.changed(coffee)
        #expect(search.answer != .idle)
        var edited = coffee
        edited.body = "Cortado now."
        edited.updatedAt = coffee.updatedAt.addingTimeInterval(60)
        search.changed(edited)
        #expect(search.answer == .idle)
        await search.search()
        #expect(search.answer == .idle && search.canAsk)

        await search.ask()
        search.removed(coffee.id)
        #expect(search.answer == .idle)
    }

    /// A refresh of the answered search that comes back after the field changed brings nothing
    /// back under the new search.
    @Test func aLateRefreshOfThePreviousSearchRestoresNothing() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        vault.add("Tea", body: "Green tea in the afternoon.")
        let search = await Self.loaded(vault)
        await search.ask()
        vault.delay("coffee", .milliseconds(200))
        let refreshing = Task { await search.search() }
        try await Task.sleep(for: .milliseconds(50))
        search.query = "tea"
        await refreshing.value
        #expect(search.answer == .idle && search.sourceNumber(search.results[0].id) == nil)
    }

    /// A slow answer overtaken by a new search never lands on the new results.
    @Test func aSlowAnswerOvertakenByANewSearchIsDropped() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        vault.add("Tea", body: "Green tea in the afternoon.")
        vault.answerDelay = .milliseconds(300)
        let search = await Self.loaded(vault)
        let asking = Task { await search.ask() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(search.answer == .reading(count: 1))
        search.query = "tea"
        await search.search()
        await asking.value
        #expect(search.answer == .idle && search.results.map(\.title) == ["Tea"])
    }

    @Test func failuresAreTypedAndOnlyUnreachableReachesTheBanner() async throws {
        let vault = FakeVault()
        vault.add("Coffee")
        let log = FailureLog()
        let search = await Self.loaded(vault, log: log)
        let cases: [(CompanionClientError, SearchModel.AnswerFailure)] = [
            (.method(CompanionError(.capReached)), .capReached),
            (.method(CompanionError(.modelTimeout)), .timeout), (.answerTimedOut, .timeout),
            (.method(CompanionError(.modelUnavailable, reason: "not_signed_in")), .modelUnavailable(reason: "not_signed_in")),
        ]
        for (error, expected) in cases {
            search.clearAnswer()
            vault.fail(.memoriesAnswer, with: error)
            await search.ask()
            #expect(search.answer == .failed(expected), "\(error)")
        }
        #expect(log.errors.isEmpty)
        search.clearAnswer()
        vault.fail(.memoriesAnswer, with: .unreachable(localNetworkDenied: false))
        await search.ask()
        #expect(search.answer == .failed(.client(.unreachable(localNetworkDenied: false))))
        #expect(log.errors == [.unreachable(localNetworkDenied: false)])

        // answers_off: the card says so, and Ask stays hidden until the Mac's status changes.
        search.clearAnswer()
        vault.fail(.memoriesAnswer, with: .method(CompanionError(.answersOff)))
        await search.ask()
        #expect(search.answer == .failed(.answersOff))
        search.clearAnswer()
        #expect(!search.canAsk)
        // A fresh status.get that says the same as before lifts it.
        search.statusChecked(Self.claude)
        #expect(search.canAsk)
    }

    @Test func onDeviceReadsAtMostFive() async throws {
        let vault = FakeVault()
        for i in 0..<10 { vault.add("Coffee \(i)", updated: TimeInterval(-i)) }
        vault.answerDelay = .milliseconds(200)
        let search = await Self.loaded(vault)
        search.macAnswers = SearchAnswersStatus(engine: "Apple on-device", locality: .onDevice)
        let asking = Task { await search.ask() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(search.answer == .reading(count: 5))
        await asking.value
    }

    /// Typing clears the card at once, and Ask waits for the new search's results.
    @Test func typingClearsTheCardAndAskWaitsForTheNewResults() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        let search = await Self.loaded(vault)
        await search.ask()
        #expect(search.answer != .idle)
        search.query = "coffee order"
        #expect(search.answer == .idle && !search.canAsk)
        await search.search()
        #expect(search.canAsk == false || search.results.isEmpty == false)
    }

    @Test func theCardsWords() {
        let result = MemoryAnswerResult(outcome: .answered, claims: [], read: 8, withheld: 1, dropped: 2, engine: "Claude",
                                        locality: .cloud, durationMs: 5_600)
        #expect(AnswerWording.footer(result, results: 30) == "Read 8 of 30 results · 6 s")
        #expect(AnswerWording.notes(result) == ["1 memory wasn't read: it's above your Mac's cloud limit",
                                                "2 claims left out: they didn't quote a memory"])
        #expect(AnswerWording.badge("Claude", .cloud) == "Claude · Cloud" && AnswerWording.badge("Apple", .onDevice) == "On your Mac")
        let words = { (failure: SearchModel.AnswerFailure) in AnswerWording.failure(failure, engine: "Claude Code") { _ in "unreachable" } }
        #expect(words(.answersOff) == ("Search answers are off on your Mac.", false))
        #expect(words(.modelUnavailable(reason: "not_signed_in")).text == "Claude Code isn't signed in on your Mac.")
        #expect(words(.modelUnavailable(reason: "secret_in_search")).retry == false)
        #expect(words(.modelUnavailable(reason: "something_new")) == ("Your Mac's model couldn't answer. Try again.", true))
        #expect(words(.client(.unreachable(localNetworkDenied: false))) == ("unreachable", true))
    }

    @Test func memoriesAnswerWaitsLongerAndIsNeverResent() {
        #expect(CompanionClient.timeout(for: .memoriesAnswer) == 55 && CompanionClient.timeout(for: .memoriesSearch) == 15)
        #expect(!CompanionClient.repeatable.contains(.memoriesAnswer))
    }

    /// Demo mode, end to end: a sample question finds its memories, Ask answers quoting them, and
    /// the cited memory opens with its quote found by QuoteLocator. Any other search gets the hint.
    @Test func demoAnswersItsSampleQuestions() async throws {
        let demo = DemoVault()
        let status = try await demo.call(StatusGet.self, EmptyParams())
        let search = SearchModel(caller: demo)
        search.macAnswers = status.searchAnswers
        search.query = "When does my lease renew?"
        await search.search()
        #expect(search.results.map(\.title) == ["Flat lease renews in March"] && search.canAsk)
        await search.ask()
        guard case let .answered(result, _) = search.answer else { Issue.record("\(search.answer)"); return }
        let citation = try #require(result.claims.first?.citations.first)
        let memory = try await demo.call(MemoriesGet.self, MemoryID(id: citation.id)).memory
        let range = try #require(QuoteLocator.range(of: citation.quote, in: memory.body))
        #expect(memory.body[range] == "The flat's lease renews on 1 March; notice is due two months before.")

        for question in DemoVault.sampleQuestions.map(\.question) {
            search.query = question
            await search.search()
            await search.ask()
            guard case let .answered(answer, _) = search.answer else { Issue.record("\(question)"); continue }
            for citation in answer.claims.flatMap(\.citations) {
                let body = try await demo.call(MemoriesGet.self, MemoryID(id: citation.id)).memory.body
                #expect(QuoteLocator.contains(citation.quote, in: body), "\(question)")
            }
        }

        search.query = "Garden"
        await search.search()
        await search.ask()
        #expect(search.answer == .failed(.modelUnavailable(reason: AnswerWording.demoHintReason)))
    }
}
