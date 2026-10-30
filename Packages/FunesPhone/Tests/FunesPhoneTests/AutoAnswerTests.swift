import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// Automatic search answers on the iPhone (memory processing §10.6, FR-iOS-13): the phone asks
/// on its own when the Mac says to, once for each search, after the pause.
@MainActor @Suite struct AutoAnswerTests {
    static func search(_ vault: FakeVault, trigger: AnswerTrigger, query: String) async -> SearchModel {
        let search = SearchModel(caller: vault)
        search.visible = true
        search.pause = { _ in }
        search.macAnswers = SearchAnswersStatus(engine: "GPT-6-Luna (Codex)", locality: .cloud, trigger: trigger)
        search.query = query
        await search.search()
        return search
    }

    static func vault() -> FakeVault {
        let vault = FakeVault()
        vault.add("What coffee I order", body: "Oat milk flat white.")
        vault.add("Coffee beans", body: "Ethiopian, light roast.")
        return vault
    }

    @Test func aQuestionIsAnsweredOnItsOwn() async throws {
        let vault = Self.vault()
        let search = await Self.search(vault, trigger: .questions, query: "what coffee")
        await search.autoTask?.value
        #expect(vault.asks.map(\.query) == ["what coffee"] && vault.asks.first?.automatic == true)
        // Asked by the user, the call isn't marked.
        search.clearAnswer()
        await search.ask()
        #expect(vault.asks.last?.automatic == nil)
        guard case .answered = search.answer else { Issue.record("\(search.answer)"); return }
    }

    @Test func aKeywordSearchWaitsForAskUnlessEverySearchIsOn() async throws {
        let questions = Self.vault()
        let search = await Self.search(questions, trigger: .questions, query: "coffee")
        #expect(search.autoTask == nil && search.canAsk && questions.asks.isEmpty)

        let every = Self.vault()
        let always = await Self.search(every, trigger: .everySearch, query: "coffee")
        await always.autoTask?.value
        #expect(every.asks.map(\.query) == ["coffee"])

        let ask = Self.vault()
        let onRequest = await Self.search(ask, trigger: .ask, query: "what coffee")
        #expect(onRequest.autoTask == nil && ask.asks.isEmpty)
    }

    @Test func showAskOffOrAnotherScopeNeverAsks() async throws {
        let vault = Self.vault()
        let search = SearchModel(caller: vault)
        search.visible = true
        search.pause = { _ in }
        search.macAnswers = SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .everySearch)
        search.showAsk = false
        search.query = "coffee"
        await search.search()
        #expect(search.autoTask == nil)
        search.showAsk = true
        search.scope = .archived
        await search.search()
        #expect(search.autoTask == nil && vault.asks.isEmpty)
    }

    /// Refreshing the same search, or Clear, doesn't spend another answer.
    @Test func onceForEachSearch() async throws {
        let vault = Self.vault()
        let search = await Self.search(vault, trigger: .everySearch, query: "coffee")
        await search.autoTask?.value
        search.clearAnswer()
        await search.search()
        #expect(search.autoTask == nil && search.answer == .idle && vault.asks.count == 1)
        // A different search, then back: each is a new search.
        search.query = "coffee beans"
        await search.search()
        await search.autoTask?.value
        search.query = "coffee"
        await search.search()
        await search.autoTask?.value
        #expect(vault.asks.map(\.query) == ["coffee", "coffee beans", "coffee"])
    }

    /// Typing on during the pause cancels it: nothing is asked for the earlier search.
    @Test func typingDuringThePauseCancelsIt() async throws {
        let vault = Self.vault()
        let search = SearchModel(caller: vault)
        search.visible = true
        search.macAnswers = SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .everySearch)
        search.pause = { _ in try await Task.sleep(for: .seconds(30)) }
        search.query = "coffee"
        await search.search()
        let pending = try #require(search.autoTask)
        search.query = "coffee b"
        await pending.value
        #expect(vault.asks.isEmpty && search.answer == .idle)
    }

    /// Refreshing during the pause starts it again: one answer, for the new list.
    @Test func refreshingDuringThePauseRestartsIt() async throws {
        let vault = Self.vault()
        let search = SearchModel(caller: vault)
        search.visible = true
        search.macAnswers = SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .everySearch)
        search.pause = { _ in try await Task.sleep(for: .seconds(30)) }
        search.query = "coffee"
        await search.search()
        let first = try #require(search.autoTask)
        search.pause = { _ in }
        await search.search()
        let second = try #require(search.autoTask)
        #expect(vault.asks.isEmpty)
        await first.value
        await second.value
        #expect(vault.asks.count == 1)
    }

    /// A status saying the Mac answers on its own, arriving after the results, starts the pause.
    @Test func aLateStatusStartsThePause() async throws {
        let vault = Self.vault()
        let search = SearchModel(caller: vault)
        search.visible = true
        search.pause = { _ in }
        search.query = "what coffee"
        await search.search()
        #expect(search.autoTask == nil)
        search.statusChecked(SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .questions))
        await search.autoTask?.value
        #expect(vault.asks.count == 1)
        // Further status checks saying the same don't ask again.
        search.statusChecked(SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .questions))
        #expect(search.autoTask == nil || vault.asks.count == 1)
        await search.autoTask?.value
        #expect(vault.asks.count == 1)
    }

    /// Back to a search after another one that wasn't answered: a new search, answered again.
    @Test func returningToASearchAnswersItAgain() async throws {
        let vault = Self.vault()
        let search = await Self.search(vault, trigger: .everySearch, query: "coffee")
        await search.autoTask?.value
        search.query = "coffee x"
        await search.search()
        #expect(search.results.isEmpty && search.autoTask == nil)
        search.query = "coffee"
        await search.search()
        await search.autoTask?.value
        #expect(vault.asks.map(\.query) == ["coffee", "coffee"])
    }

    /// The Mac answers only when asked now: Ask shows, and the phone stops asking on its own.
    @Test func askRequiredShowsAskAndStopsAskingOnItsOwn() async throws {
        let vault = Self.vault()
        vault.fail(.memoriesAnswer, with: .method(CompanionError(.askRequired)))
        let search = await Self.search(vault, trigger: .everySearch, query: "coffee")
        await search.autoTask?.value
        #expect(search.answer == .idle && search.canAsk && search.macAnswers?.trigger == .ask)
        search.query = "coffee beans"
        await search.search()
        #expect(search.autoTask == nil)
    }

    /// Search off screen: nothing is asked on its own, and coming back starts the pause.
    @Test func onlyWhileSearchShows() async throws {
        let vault = Self.vault()
        let search = SearchModel(caller: vault)
        search.pause = { _ in }
        search.macAnswers = SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .everySearch)
        search.query = "coffee"
        await search.search()
        search.statusChecked(search.macAnswers)
        #expect(search.autoTask == nil)
        search.visible = true
        await search.autoTask?.value
        #expect(vault.asks.count == 1)
    }

    /// Ask tapped during the pause, then Clear and a refresh: that was this search's answer.
    @Test func aManualAskCountsAsTheSearchsAnswer() async throws {
        let vault = Self.vault()
        let search = SearchModel(caller: vault)
        search.visible = true
        search.macAnswers = SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .everySearch)
        search.pause = { _ in try await Task.sleep(for: .seconds(30)) }
        search.query = "coffee"
        await search.search()
        let pending = try #require(search.autoTask)
        await search.ask()
        await pending.value
        search.clearAnswer()
        await search.search()
        #expect(search.autoTask == nil && vault.asks.count == 1 && vault.asks.first?.automatic == nil)
    }

    /// Automatic answers turned off during the pause and back on: the pause starts again, with
    /// the new trigger's length.
    @Test func turningAutomaticOffAndOnStartsThePauseAgain() async throws {
        let vault = Self.vault()
        let search = SearchModel(caller: vault)
        search.visible = true
        let pauses = Pauses()
        search.pause = { duration in
            await pauses.record(duration)
            try await Task.sleep(for: .seconds(30))
        }
        search.macAnswers = SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .questions)
        search.query = "what coffee"
        await search.search()
        let first = try #require(search.autoTask)
        search.statusChecked(SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .ask))
        await first.value
        #expect(search.autoTask == nil)
        search.pause = { duration in await pauses.record(duration) }
        search.statusChecked(SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .everySearch))
        await search.autoTask?.value
        #expect(vault.asks.count == 1)
        #expect(await pauses.all == [.milliseconds(600), .seconds(1)])
    }

    /// A Mac before 10 results takes 8 ids: the phone sends no more.
    @Test func anOlderMacGetsEightIDs() async throws {
        let vault = FakeVault()
        for i in 0..<12 { vault.add("Coffee \(i)", updated: TimeInterval(-i)) }
        let search = await Self.search(vault, trigger: .ask, query: "coffee")
        search.macAnswers = SearchAnswersStatus(engine: "Claude", locality: .cloud, maxIDs: 8)
        await search.ask()
        #expect(vault.asks.last?.ids == Array(search.results.prefix(8).map(\.id)))
    }

    /// The Mac turned automatic answers off during the pause: the phone doesn't ask.
    @Test func theMacChangingItsTriggerDuringThePauseStopsIt() async throws {
        let vault = Self.vault()
        let search = SearchModel(caller: vault)
        search.visible = true
        search.macAnswers = SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .everySearch)
        let gate = AsyncStream<Void>.makeStream()
        search.pause = { _ in for await _ in gate.stream { return } }
        search.query = "coffee"
        await search.search()
        let pending = try #require(search.autoTask)
        search.statusChecked(SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .ask))
        gate.continuation.yield()
        await pending.value
        #expect(vault.asks.isEmpty && search.canAsk)
    }
}

actor Pauses {
    private(set) var all: [Duration] = []
    func record(_ duration: Duration) { all.append(duration) }
}
