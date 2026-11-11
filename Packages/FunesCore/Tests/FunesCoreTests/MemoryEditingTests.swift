import Foundation
@testable import FunesCore
import FunesProtocol
import Testing

/// FR-V-02: unsaved edits move onto a newer version when only fields they didn't touch changed;
/// a field they edited that changed too is a conflict (04-ux-mac.md ▸ Vault ▸ Unsaved edits).
@Suite struct MemoryFieldsRebaseTests {
    let base = MemoryFields(title: "Coffee", body: "Flat white", kind: .preference, categoryKeys: ["personal_preferences"],
                            sensitivity: .low, expiresAt: nil)

    @Test func aStatusChangeAloneKeepsTheEdits() throws {
        var edits = base
        edits.body = "Oat flat white"
        // Archived, restored or confirmed: the fields are as they were.
        let rebased = try #require(edits.rebased(from: base, onto: base))
        #expect(rebased == edits)
    }

    @Test func anEditElsewhereToAnotherFieldIsTaken() throws {
        var edits = base
        edits.body = "Oat flat white"
        var current = base
        current.title = "Coffee order"
        current.sensitivity = .internal
        let rebased = try #require(edits.rebased(from: base, onto: current))
        #expect(rebased.title == "Coffee order" && rebased.body == "Oat flat white" && rebased.sensitivity == .internal)
    }

    @Test func theSameFieldChangedToSomethingElseConflicts() {
        var edits = base
        edits.body = "Oat flat white"
        var current = base
        current.body = "Espresso"
        #expect(edits.rebased(from: base, onto: current) == nil)
    }

    @Test func theSameChangeOnBothSidesIsNoConflict() throws {
        var edits = base
        edits.categoryKeys = ["health"]
        var current = base
        current.categoryKeys = ["health"]
        current.kind = .fact
        let rebased = try #require(edits.rebased(from: base, onto: current))
        #expect(rebased.categoryKeys == ["health"] && rebased.kind == .fact)
    }

    @Test func expiryCountsAsAField() {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        var edits = base
        edits.expiresAt = date
        var current = base
        current.expiresAt = date.addingTimeInterval(86_400)
        #expect(edits.rebased(from: base, onto: current) == nil)
        var untouched = base
        untouched.title = "Mine"
        #expect(untouched.rebased(from: base, onto: current)?.expiresAt == current.expiresAt)
    }

    @Test func noEditsTakeTheCurrentVersion() {
        var current = base
        current.body = "Espresso"
        #expect(base.rebased(from: base, onto: current) == current)
    }
}

/// FR-V-10: which memory a Vault reload keeps selected (04-ux-mac.md ▸ Vault ▸ Show this memory).
@Suite struct VaultSelectionTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func aDataReloadKeepsTheSingleSelection() {
        let keepable = VaultSelection.keepable([a], sameListing: true, revealed: nil)
        #expect(keepable == a)
        // Archived from its detail: gone from the Active list, still there.
        #expect(VaultSelection.after([a], listed: [b], keepable: keepable, exists: true) == [a])
        // Purged: it goes.
        #expect(VaultSelection.after([a], listed: [b], keepable: keepable, exists: false).isEmpty)
    }

    @Test func aNewSearchDropsWhatItDoesntList() {
        let keepable = VaultSelection.keepable([a], sameListing: false, revealed: nil)
        #expect(keepable == nil)
        #expect(VaultSelection.after([a], listed: [b], keepable: keepable, exists: false).isEmpty)
        #expect(VaultSelection.after([a], listed: [a, b], keepable: keepable, exists: false) == [a])
    }

    @Test func aRevealedMemoryIsKeptThroughItsOwnSearchChange() {
        let keepable = VaultSelection.keepable([a], sameListing: false, revealed: a)
        #expect(keepable == a)
        #expect(VaultSelection.after([a], listed: [], keepable: keepable, exists: true) == [a])
        // Another memory revealed earlier doesn't count.
        #expect(VaultSelection.keepable([a], sameListing: false, revealed: b) == nil)
    }

    @Test func severalSelectedAreNeverKeptUnlisted() {
        #expect(VaultSelection.keepable([a, b], sameListing: true, revealed: a) == nil)
        #expect(VaultSelection.after([a, b, c], listed: [b, c], keepable: nil, exists: false) == [b, c])
    }

    /// The user selected another memory while the load ran: the kept one isn't forced back.
    @Test func aSelectionChangedMeanwhileIsntOverridden() {
        #expect(VaultSelection.after([b], listed: [c], keepable: a, exists: true).isEmpty)
        #expect(VaultSelection.after([b], listed: [b], keepable: a, exists: true) == [b])
    }
}
