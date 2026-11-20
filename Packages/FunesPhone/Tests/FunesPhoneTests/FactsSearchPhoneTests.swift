import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// Learned facts on the iPhone (v0.10; companion protocol §4, memory processing §10.5): the facts revision drops a held
/// or in-flight answer, `facts_changed`, and corrections.
@MainActor @Suite struct FactsSearchPhoneTests {
    /// Asks on its own for every search, at once, while Search shows: so "not asked again" means something.
    static let eager = SearchAnswersStatus(engine: "Claude (Claude Code)", locality: .cloud, trigger: .everySearch)

    static func eagerSearch(_ vault: FakeVault) async -> SearchModel {
        let search = SearchModel(caller: vault)
        search.pause = { _ in }
        search.query = "coffee"
        await search.search()
        search.visible = true
        return search
    }

    @Test func aNewRevisionDropsTheHeldAnswerAndSearchesAgainWithoutAsking() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        vault.revision = "e.1"
        let search = await SearchAnswerTests.loaded(vault)
        search.statusChecked(SearchAnswerTests.claude, factsRevision: .some("e.1"))
        await search.ask()
        #expect(search.answer != .idle)
        let searches = vault.searches.count, asks = vault.asks.count
        // The same revision: nothing happens.
        search.statusChecked(SearchAnswerTests.claude, factsRevision: .some("e.1"))
        #expect(search.answer != .idle)
        // A check that didn't reach the Mac says nothing about its learned facts.
        search.statusChecked(SearchAnswerTests.claude)
        #expect(search.answer != .idle)
        vault.revision = "e.2"
        search.statusChecked(SearchAnswerTests.claude, factsRevision: .some("e.2"))
        #expect(search.answer == .idle)
        try await Task.sleep(for: .milliseconds(50))
        #expect(vault.searches.count == searches + 1 && vault.asks.count == asks)
        // Coming back to the search doesn't bring the old answer back.
        await search.search()
        #expect(search.answer == .idle)
    }

    @Test func absentToPresentIsAChangeToo() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        let search = await SearchAnswerTests.loaded(vault)
        search.statusChecked(SearchAnswerTests.claude, factsRevision: .some(nil))
        await search.ask()
        #expect(search.answer != .idle)
        search.statusChecked(SearchAnswerTests.claude, factsRevision: .some("e.1"))
        #expect(search.answer == .idle)
    }

    /// The Mac checked the answer against what it rested on: a newer counter (readings during a backfill) keeps it.
    @Test func anAnswerMadeAtANewerRevisionIsKept() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        vault.revision = "e.1"
        let search = await SearchAnswerTests.loaded(vault)
        search.statusChecked(SearchAnswerTests.claude, factsRevision: .some("e.1"))
        vault.answerRevision = "e.2"
        await search.ask()
        guard case .answered = search.answer else { Issue.record("\(search.answer)"); return }
        #expect(search.factsRevision == "e.2")
    }

    @Test func aStatusDuringAnAnswerOnItsWayLeavesIt() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        vault.revision = "e.1"
        vault.answerDelay = .milliseconds(200)
        let search = await SearchAnswerTests.loaded(vault)
        search.statusChecked(SearchAnswerTests.claude, factsRevision: .some("e.1"))
        let asking = Task { await search.ask() }
        try await Task.sleep(for: .milliseconds(50))
        search.statusChecked(SearchAnswerTests.claude, factsRevision: .some("e.2"))
        await asking.value
        guard case .answered = search.answer else { Issue.record("\(search.answer)"); return }
    }

    @Test func aNewRevisionIsntFollowedByAnAskOnItsOwn() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        vault.revision = "e.1"
        let search = await Self.eagerSearch(vault)
        search.statusChecked(Self.eager, factsRevision: .some("e.1"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vault.asks.count == 1)
        vault.revision = "e.2"
        search.statusChecked(Self.eager, factsRevision: .some("e.2"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(vault.asks.count == 1 && search.answer == .idle)
    }

    @Test func factsChangedClearsTheCardChecksTheMacAndSearchesAgain() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        let search = await SearchAnswerTests.loaded(vault)
        var checked = 0
        search.onFactsChanged = { checked += 1 }
        vault.fail(.memoriesAnswer, with: .method(CompanionError(.modelUnavailable, reason: "facts_changed")))
        let searches = vault.searches.count
        await search.ask()
        try await Task.sleep(for: .milliseconds(50))
        #expect(search.answer == .idle && checked == 1 && vault.searches.count == searches + 1)
        // Not asked again on its own for this search, even where every search is answered on its own.
        let eager = await Self.eagerSearch(vault)
        vault.fail(.memoriesAnswer, with: .method(CompanionError(.modelUnavailable, reason: "facts_changed")))
        eager.statusChecked(Self.eager, factsRevision: .some(nil))
        try await Task.sleep(for: .milliseconds(150))
        // Two asks reached the Mac (each refused before it answered); none followed on its own.
        #expect(vault.calls.filter { $0 == .memoriesAnswer }.count == 2 && vault.asks.isEmpty && eager.answer == .idle)
    }

    @Test func aCorrectionGoesToTheMacAndTheListReloads() async throws {
        let vault = FakeVault()
        vault.add("Coffee", body: "Oat milk flat white.")
        vault.revision = "e.1"
        let search = await SearchAnswerTests.loaded(vault)
        let target = FactsCorrectionTarget(what: .fact, factID: "f1", token: "t", label: "Not this")
        let searches = vault.searches.count
        await search.correct(target)
        #expect(vault.corrections == [target] && vault.searches.count == searches + 1 && search.factsRevision == "e.1+")
        // Refused (it changed on the Mac): the list again, with current buttons.
        vault.fail(.factsReject, with: .method(CompanionError(.targetChanged)))
        await search.correct(target)
        #expect(vault.searches.count == searches + 2)
        if case .method = search.correctionFailure {} else { Issue.record("\(String(describing: search.correctionFailure))") }
        // Unreachable: nothing queued, and the alert says so.
        let log = FailureLog()
        let offline = SearchModel(caller: vault, onFailure: log.record)
        vault.fail(.factsReject, with: .unreachable(localNetworkDenied: false))
        await offline.correct(target)
        #expect(offline.correctionFailure == .unreachable(localNetworkDenied: false) && vault.corrections.count == 1 && log.errors == [.unreachable(localNetworkDenied: false)])
    }
}
