import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// Search, the memory detail and the Inbox (task 5.5) against a vault that keeps versions.
@MainActor @Suite struct MemoryDetailTests {
    /// FR-iOS-08: the phone edits a memory the Mac changed meanwhile. The Mac answers `conflict`,
    /// the phone asks "Changed on your Mac, reload?", keeps the draft until it's answered, and
    /// on Reload puts the Mac's version in the editor, to change and save again (device check,
    /// 2026-10-21: the editor had kept the old text).
    @Test func editThatConflictsWithAMacEditReloads() async throws {
        let vault = FakeVault()
        let original = vault.add("Seat", body: "Prefers aisle seats")
        let detail = MemoryDetailModel(id: original.id, caller: vault)
        await detail.load()
        #expect(detail.phase == .loaded)
        #expect(detail.memory?.version == 1)

        detail.startEditing()
        detail.draft?.body = "Prefers window seats"
        vault.macEdit(original.id, body: "Prefers aisle seats, front of the plane")

        #expect(await detail.save() == false)
        #expect(detail.conflict)
        #expect(detail.error == nil)
        #expect(detail.draft?.body == "Prefers window seats")
        #expect(vault.memory(original.id)?.body == "Prefers aisle seats, front of the plane")
        #expect(vault.updates.map(\.version) == [1])

        // Reload with the editor open: it stays open, now holding the Mac's version.
        await detail.reload()
        #expect(!detail.conflict)
        #expect(detail.memory?.body == "Prefers aisle seats, front of the plane")
        #expect(detail.memory?.version == 2)
        #expect(detail.draft == MemoryEditDraft(try #require(detail.memory)))

        detail.draft?.body = "Prefers window seats"
        #expect(await detail.save())
        #expect(detail.draft == nil)
        #expect(vault.memory(original.id)?.body == "Prefers window seats")
        #expect(detail.memory?.version == 3)
    }

    @Test func archiveAndDeleteConflictToo() async throws {
        let vault = FakeVault()
        let memory = vault.add("Seat")
        let detail = MemoryDetailModel(id: memory.id, caller: vault)
        await detail.load()
        vault.macEdit(memory.id, body: "Changed")
        #expect(await detail.archive() == false)
        #expect(detail.conflict)
        #expect(vault.memory(memory.id)?.status == .active)

        await detail.reload()
        #expect(detail.draft == nil)
        #expect(await detail.archive())
        #expect(detail.memory?.status == .archived)
        #expect(await detail.restore())
        #expect(await detail.delete())
        #expect(vault.memory(memory.id)?.status == .deleted)
        #expect(vault.memory(memory.id)?.version == 5)
    }

    /// UX: iPhone, "A failed save shows an error, and the text is kept until it saves."
    @Test func failedSaveKeepsTheDraft() async throws {
        let vault = FakeVault()
        let memory = vault.add("Seat")
        let log = FailureLog()
        let detail = MemoryDetailModel(id: memory.id, caller: vault, onFailure: log.record)
        await detail.load()
        detail.startEditing()
        detail.draft?.title = "Seats"
        vault.fail(.memoriesUpdate, with: .unreachable(localNetworkDenied: false))

        #expect(await detail.save() == false)
        #expect(detail.error == .unreachable(localNetworkDenied: false))
        #expect(!detail.conflict)
        #expect(detail.draft?.title == "Seats")
        #expect(log.errors == [.unreachable(localNetworkDenied: false)])

        #expect(await detail.save())
        #expect(detail.error == nil)
        #expect(vault.memory(memory.id)?.title == "Seats")
    }

    /// Only what changed is sent, so the Mac doesn't see an edit of fields the phone didn't touch.
    @Test func sendsOnlyChangedFields() async throws {
        let vault = FakeVault()
        let memory = vault.add("Seat")
        let detail = MemoryDetailModel(id: memory.id, caller: vault)
        await detail.load()
        detail.startEditing()
        #expect(await detail.save())
        #expect(vault.updates.isEmpty)

        detail.startEditing()
        detail.draft?.sensitivity = .internal
        detail.draft?.expiresAt = t0.addingTimeInterval(86_400)
        #expect(await detail.save())
        #expect(vault.updates.first?.changes == MemoryChanges(sensitivity: .internal, expiresAt: .some(t0.addingTimeInterval(86_400))))

        detail.startEditing()
        detail.draft?.expiresAt = nil
        #expect(await detail.save())
        #expect(vault.updates.last?.changes == MemoryChanges(expiresAt: .some(nil)))
    }

    @Test func draftProblems() {
        var draft = MemoryEditDraft(title: " ", body: "b", kind: .fact, categories: ["work"], sensitivity: .low)
        #expect(draft.problem == .emptyTitle)
        draft.title = "t"
        draft.body = "\n"
        #expect(draft.problem == .emptyBody)
        draft.body = "b"
        draft.categories = []
        #expect(draft.problem == .noCategory)
        draft.categories = ["home"]
        #expect(draft.problem == nil)
    }

    @Test func goneFromTheMac() async throws {
        let vault = FakeVault()
        var changes: [MemoryDetailModel.Change] = []
        let detail = MemoryDetailModel(id: UUID(), caller: vault)
        detail.onChange = { changes.append($0) }
        await detail.load()
        #expect(detail.phase == .gone)
        #expect(changes == [.removed(detail.id)])
    }

    /// Search's list follows the detail: an archived memory leaves the Active results.
    @Test func searchFollowsTheDetail() async throws {
        let vault = FakeVault()
        let memory = vault.add("Seat")
        vault.add("Coffee", updated: -10)
        let search = SearchModel(caller: vault)
        await search.search()
        #expect(search.results.map(\.title) == ["Seat", "Coffee"])

        let detail = MemoryDetailModel(id: memory.id, caller: vault)
        detail.onChange = { change in
            switch change {
            case let .changed(memory): search.changed(memory)
            case let .removed(id): search.removed(id)
            }
        }
        await detail.load()
        detail.startEditing()
        detail.draft?.title = "Seats"
        #expect(await detail.save())
        #expect(search.results.map(\.title) == ["Seats", "Coffee"])
        #expect(await detail.archive())
        #expect(search.results.map(\.title) == ["Coffee"])
    }
}

@MainActor @Suite struct SearchModelTests {
    @Test func pagesThroughResults() async throws {
        let vault = FakeVault()
        for i in 0..<(SearchModel.pageSize + 5) { vault.add("Memory \(i)", updated: TimeInterval(-i)) }
        let search = SearchModel(caller: vault)
        await search.search()
        #expect(search.phase == .loaded)
        #expect(search.results.count == SearchModel.pageSize)
        #expect(search.nextCursor != nil)
        await search.loadMore()
        #expect(search.results.count == SearchModel.pageSize + 5)
        #expect(search.nextCursor == nil)
        #expect(search.results.first?.title == "Memory 0")
    }

    @Test func scopeAndQueryReachTheMac() async throws {
        let vault = FakeVault()
        vault.add("Old seat", status: .archived)
        vault.add("Seat")
        let search = SearchModel(caller: vault)
        search.query = "  seat "
        search.scope = .archived
        await search.search()
        #expect(search.results.map(\.title) == ["Old seat"])
        #expect(vault.searches.last?.query == "seat")
        #expect(vault.searches.last?.filters?.status == .archived)
        search.scope = .active
        await search.search()
        #expect(vault.searches.last?.filters == nil)
        #expect(search.results.map(\.title) == ["Seat"])
        // Home's Sensitivity tile: one level, in any scope.
        search.sensitivity = .internal
        await search.search()
        #expect(vault.searches.last?.filters == MemorySearchFilters(sensitivities: [.internal]))
        search.scope = .archived
        await search.search()
        #expect(vault.searches.last?.filters == MemorySearchFilters(sensitivities: [.internal], status: .archived))
    }

    /// Typing fast: the answer to an older query that arrives last is dropped.
    @Test func olderAnswerIsDropped() async throws {
        let vault = FakeVault()
        vault.add("Aisle")
        vault.add("Window")
        vault.delay("a", .milliseconds(300))
        let search = SearchModel(caller: vault)
        search.query = "a"
        let slow = Task { await search.search() }
        try await Task.sleep(for: .milliseconds(50))
        search.query = "window"
        await search.search()
        await slow.value
        #expect(search.results.map(\.title) == ["Window"])
    }

    /// Typing on cancels the search in flight: that's not the Mac failing, so neither the
    /// screen nor the reachability banner hears of it.
    @Test func cancelledSearchIsNotAFailure() async throws {
        let vault = FakeVault()
        vault.add("Aisle")
        vault.delay("a", .seconds(5))
        let log = FailureLog()
        let search = SearchModel(caller: vault, onFailure: log.record)
        search.query = "a"
        let typing = Task { await search.search() }
        try await Task.sleep(for: .milliseconds(50))
        typing.cancel()
        await typing.value
        #expect(search.phase == .searching)
        #expect(log.errors.isEmpty)
    }

    @Test func failureIsShownAndReported() async throws {
        let vault = FakeVault()
        let log = FailureLog()
        let search = SearchModel(caller: vault, onFailure: log.record)
        vault.fail(.memoriesSearch, with: .unreachable(localNetworkDenied: false))
        await search.search()
        #expect(search.phase == .failed(.unreachable(localNetworkDenied: false)))
        #expect(log.errors == [.unreachable(localNetworkDenied: false)])
        search.clear()
        #expect(search.phase == .idle && search.results.isEmpty)
    }
}

@MainActor @Suite struct InboxModelTests {
    @Test func swipeToSaveAndReject() async throws {
        let vault = FakeVault()
        let a = vault.suggest("A"), b = vault.suggest("B"), c = vault.suggest("C")
        let inbox = InboxModel(caller: vault)
        await inbox.load()
        #expect(inbox.items.map(\.title) == ["A", "B"])
        await inbox.loadMore()
        #expect(inbox.items.map(\.title) == ["A", "B", "C"])

        #expect(await inbox.save(a.id))
        #expect(await inbox.reject(c.id))
        #expect(inbox.items.map(\.id) == [b.id])
        #expect(vault.applied.map(\.suggestionId) == [a.id])
        #expect(vault.applied.first?.edits == nil)
        #expect(vault.rejected == [c.id])
        #expect(inbox.failure == nil)
    }

    /// A row the Mac is still processing can't be saved, only rejected; a failed split offers
    /// Try again and Keep as one, and the row stays (memory processing §5.2).
    @Test func processingRowsWaitAndFailedOnesOfferTryAgainAndKeepAsOne() async throws {
        let vault = FakeVault()
        let a = vault.suggest("A", processing: .processing), b = vault.suggest("B", processing: .failed)
        let inbox = InboxModel(caller: vault)
        await inbox.load()
        #expect(inbox.items.map(\.processing) == [.processing, .failed])
        #expect(await inbox.save(a.id) == false)
        #expect(vault.applied.isEmpty && inbox.items.count == 2)
        #expect(await inbox.retry(a.id) == false)  // only a failed one

        #expect(await inbox.retry(b.id))
        #expect(inbox.items.map(\.processing) == [.processing, .processing])
        // The Mac failed it again: Keep as one, then it saves like any other.
        vault.setProcessing(b.id, .failed)
        await inbox.load()
        #expect(await inbox.keepAsOne(b.id))
        #expect(inbox.items.map(\.processing) == [.processing, nil])
        #expect(await inbox.save(b.id))
        #expect(await inbox.reject(a.id))
        #expect(inbox.items.isEmpty && vault.rejected == [a.id])
    }

    /// A reject that doesn't reach the Mac: the row comes back where it was, and the failure is
    /// shown and reported.
    @Test func failedRejectPutsTheRowBack() async throws {
        let vault = FakeVault()
        vault.suggest("A")
        let b = vault.suggest("B")
        let log = FailureLog()
        let inbox = InboxModel(caller: vault, onFailure: log.record)
        await inbox.load()
        vault.fail(.inboxReject, with: .unreachable(localNetworkDenied: false))

        #expect(await inbox.reject(b.id) == false)
        #expect(inbox.items.map(\.title) == ["A", "B"])
        #expect(inbox.failure?.item.id == b.id)
        #expect(inbox.failure?.answer == .reject)
        #expect(inbox.failure?.error == .unreachable(localNetworkDenied: false))
        #expect(log.errors == [.unreachable(localNetworkDenied: false)])
        #expect(vault.inbox.count == 2)
    }

    /// A save the Mac refuses (the edited text looks like a password): the row comes back.
    @Test func refusedSavePutsTheRowBack() async throws {
        let vault = FakeVault()
        let a = vault.suggest("A")
        vault.suggest("B")
        let inbox = InboxModel(caller: vault)
        await inbox.load()
        let refusal = CompanionClientError.method(CompanionError(.secretLikeContent, findings: [.assignedSecret]))
        vault.fail(.inboxApply, with: refusal)

        #expect(await inbox.save(a.id, edits: MemoryChanges(body: "password=hunter2abc")) == false)
        #expect(inbox.items.map(\.title) == ["A", "B"])
        #expect(inbox.failure == InboxModel.Failure(item: a, answer: .save, error: refusal))
    }

    /// Answered on the Mac first: the phone's answer finds nothing, and the row stays gone.
    @Test func answeredOnTheMacFirst() async throws {
        let vault = FakeVault()
        let a = vault.suggest("A")
        let inbox = InboxModel(caller: vault)
        await inbox.load()
        vault.macAnswer(a.id)
        #expect(await inbox.save(a.id) == false)
        #expect(inbox.items.isEmpty)
        #expect(inbox.failure == nil)
        #expect(inbox.answeredElsewhere == 1)
    }

    @Test func editAndSaveSendsTheEdits() async throws {
        let vault = FakeVault()
        let a = vault.suggest("A")
        let inbox = InboxModel(caller: vault)
        await inbox.load()
        var draft = MemoryEditDraft(a)
        draft.title = "A, edited"
        #expect(await inbox.save(a.id, edits: draft.changes(from: MemoryEditDraft(a))))
        #expect(vault.applied.first?.edits == MemoryChanges(title: "A, edited"))
    }

    /// ADR-0031 §5: a swipe saves only a new memory or a duplicate; every other card opens.
    @Test func swipesOnlyWhereTheRowShowsEverything() {
        let vault = FakeVault()
        let create = vault.suggest("New")
        #expect(InboxModel.swipes(create))
        #expect(InboxModel.swipes(vault.suggest("Copy", action: .duplicate)))
        for action in [SuggestionAction.update, .archive, .split, .merge, .conflict, .unknown] {
            #expect(!InboxModel.swipes(vault.suggest("Card", action: action)), "\(action)")
        }
        #expect(!InboxModel.swipes(vault.suggest("Busy", processing: .processing)))
    }

    /// ADR-0031 §2–§4: the card in full, applied with its choice and revision; a card that changed
    /// on the Mac meanwhile is refused and stays; Review Again; a conflict needs its answer.
    @Test func cardsAreAnsweredWithTheirChoice() async throws {
        let vault = FakeVault()
        let a = vault.add("Office in Madrid"), b = vault.add("Office in Lisbon")
        let conflict = vault.suggest("Office", action: .conflict,
                                     memories: [InboxMemory(role: .target, memory: a), InboxMemory(role: .target, memory: b)])
        let archive = vault.suggest("Copy", action: .archive, memories: [InboxMemory(role: .target, memory: b)], stale: true)
        let inbox = InboxModel(caller: vault)
        await inbox.load()

        let shown = try await inbox.detail(conflict.id)
        #expect(shown.memories(.target).map(\.id) == [a.id, b.id])
        vault.macChangeCard(conflict.id)
        #expect(await inbox.save(conflict.id, mode: .keep, keep: a.id, revision: shown.revision) == false)
        #expect(inbox.items.map(\.id) == [conflict.id, archive.id])
        #expect(inbox.failure?.error == .method(CompanionError(.requestChanged)))
        inbox.failure = nil
        let fresh = try await inbox.detail(conflict.id)
        #expect(await inbox.save(conflict.id, mode: .keep, keep: a.id, edits: MemoryChanges(body: "Since May"), revision: fresh.revision))
        #expect(vault.applied.last == InboxApplyParams(suggestionId: conflict.id, edits: MemoryChanges(body: "Since May"), mode: .keep,
                                                       keepMemoryId: a.id, revision: fresh.revision))

        // Stale: refused until reviewed again; the row stays.
        #expect(try await inbox.detail(archive.id).stale)
        #expect(await inbox.save(archive.id) == false)
        #expect(inbox.failure?.error == .method(CompanionError(.targetChanged)) && inbox.items.map(\.id) == [archive.id])
        inbox.failure = nil
        #expect(await inbox.reviewAgain(archive.id))
        #expect(vault.reviewedAgain == [archive.id])
        let reviewed = try await inbox.detail(archive.id)
        #expect(!reviewed.stale)
        #expect(await inbox.save(archive.id, revision: reviewed.revision))
        #expect(inbox.items.isEmpty)
    }

    /// Answered on the Mac while open: the card's screen finds it gone, and so does Review Again.
    @Test func aCardAnsweredOnTheMacLeaves() async throws {
        let vault = FakeVault()
        let a = vault.suggest("Copy", action: .archive), b = vault.suggest("Other", action: .merge)
        let inbox = InboxModel(caller: vault)
        await inbox.load()
        vault.macAnswer(a.id)
        await #expect(throws: CompanionClientError.method(CompanionError(.notFound))) { try await inbox.detail(a.id) }
        vault.macAnswer(b.id)
        #expect(await inbox.reviewAgain(b.id) == false)
        #expect(inbox.items.isEmpty && inbox.answeredElsewhere == 2 && inbox.failure == nil)
    }

    /// `conflict` asks for the card: one still waiting stays, with the failure; one answered on the
    /// Mac leaves; a split brings in its pieces that change other memories.
    @Test func conflictRereadsTheListAndASplitRefreshesIt() async throws {
        let vault = FakeVault()
        let a = vault.suggest("A")
        let piece = InboxItem(id: UUID(), origin: .consolidation, action: .update, sourceLabel: "Tidy-up", title: "Piece", body: "Body",
                              kind: .fact, categories: ["work"], sensitivity: .low, createdAt: t0)
        let split = vault.suggest("Split", action: .split, pieces: [piece])
        let inbox = InboxModel(caller: vault)
        await inbox.load()
        vault.fail(.inboxApply, with: .method(CompanionError(.conflict)))
        #expect(await inbox.save(a.id) == false)
        #expect(inbox.items.map(\.id) == [a.id, split.id] && inbox.answeredElsewhere == 0)
        #expect(inbox.failure?.error == .method(CompanionError(.conflict)))
        #expect(await inbox.save(split.id))
        #expect(inbox.items.map(\.id) == [a.id, piece.id])
        inbox.failure = nil
        vault.fail(.inboxApply, with: .method(CompanionError(.conflict)))
        vault.macAnswer(a.id)
        #expect(await inbox.save(a.id) == false)
        #expect(inbox.items.map(\.id) == [piece.id] && inbox.answeredElsewhere == 1 && inbox.failure == nil)
    }
}
