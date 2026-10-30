import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// Automatic search answers on the iPhone (memory processing §10.6, FR-iOS-13): the phone asks
/// on its own when the Mac says to, once for each search, after the pause.
@MainActor @Suite struct AutoAnswerTests {
    static func search(_ vault: FakeVault, trigger: AnswerTrigger, query: String) async -> SearchModel {
        let search = SearchModel(caller: vault)
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
        #expect(vault.asks.map(\.query) == ["what coffee"])
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
        search.macAnswers = SearchAnswersStatus(engine: "Claude", locality: .cloud, trigger: .everySearch)
        search.pause = { _ in try await Task.sleep(for: .seconds(30)) }
        search.query = "coffee"
        await search.search()
        let pending = try #require(search.autoTask)
        search.query = "coffee b"
        await pending.value
        #expect(vault.asks.isEmpty && search.answer == .idle)
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
