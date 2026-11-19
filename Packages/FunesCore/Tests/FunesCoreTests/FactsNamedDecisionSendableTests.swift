import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// The fix round's privacy rule and its review (GPT-6-Astra, follow-up): a model's `named` decision is shown to a cloud
/// call despite a holder or a relation above the limit only when the memory's own text pairs the phrase with that name.
/// A name merely elsewhere in the memory isn't enough: which of its people the reader picked may rest on what's above it.
@Suite struct FactsNamedDecisionSendableTests {
    let reg = FactsRegistry.bundled
    var sibling: String { FX.personPredicate { $0.lexicon.contains { $0.words.contains("sister") } } }
    var people: String { reg.predicate(sibling)!.callGroup }

    /// Alice and Beth known from a low note; "Alice Chen is my sister" only in a restricted one; then the low memory, whose
    /// "My sister" a local reader resolves to Alice. Returns whether the sendable graph shows that decision.
    func shown(_ text: String) throws -> (sendable: Bool, whole: Bool) {
        let v = try TestVault()
        func read(_ text: String, _ s: Sensitivity, day: Double, _ x: (FactsGraph) -> FactsExtraction) throws -> String {
            let now = t0.plus(days: day)
            let mem = try v.memory("Note \(Int(day))", text, sensitivity: s, now: now)
            try v.store.writer.write { db in
                let g = try FactStore.load(db, registry: reg, userAliases: [], uses: .everyDeclared(reg)).graph
                try FactStore.apply(db, memoryID: mem.id.db, version: mem.version, extraction: x(g), callGroup: people, registry: reg,
                                    userAliases: [], now: now)
            }
            return mem.id.db
        }
        // Readers name known people by name ("new" links to the one person of that name), as the gold reader does.
        func id(_ g: FactsGraph, _ n: String) -> String { "new" }
        _ = try read("Alice Chen and Beth Jones came to dinner.", .low, day: 0) { _ in
            var x = FactsExtraction()
            x.people = [ExtractedPerson(name: "Alice Chen", person: "new"), ExtractedPerson(name: "Beth Jones", person: "new")]
            return x
        }
        _ = try read("Alice Chen is my sister.", .restricted, day: 1) { g in
            var x = FactsExtraction()
            x.people = [ExtractedPerson(name: "Alice Chen", person: id(g, "Alice Chen"))]
            x.facts = [ExtractedFact(predicate: sibling, name: "Alice Chen", entity: "name", label: "sister",
                                     quote: "Alice Chen is my sister", status: .current)]
            return x
        }
        let mid = try read(text, .low, day: 2) { g in
            var x = FactsExtraction()
            x.people = ["Alice Chen", "Beth Jones"].filter(text.contains).map { ExtractedPerson(name: $0, person: id(g, $0)) }
            x.roles = [ExtractedRole(phrase: 0, refersTo: "name:Alice Chen")]
            return x
        }
        return try v.store.writer.read { db in
            let send = try FactStore.load(db, registry: reg, userAliases: [], uses: .everyDeclared(reg), sendable: .upTo(.low)).graph
            let whole = try FactStore.load(db, registry: reg, userAliases: [], uses: .everyDeclared(reg)).graph
            func has(_ g: FactsGraph) -> Bool { g.decisions.contains { $0.key.memoryID == mid && $0.value.basis == .named } }
            return (has(send), has(whole))
        }
    }

    @Test func aNameElsewhereInTheMemoryDoesntShowIt() throws {
        let r = try shown("Alice Chen and Beth Jones visited. My sister brought cake.")
        #expect(r.whole)                // the owner's own graph has it
        #expect(!r.sendable)            // a cloud call doesn't: the pick may rest on the restricted note
    }

    @Test func aPhraseTheTextPairsWithTheNameShowsIt() throws {
        let r = try shown("My sister Alice Chen brought cake.")
        #expect(r.whole && r.sendable)
    }

    // Review (GPT-6-Astra, second follow-up): a paired name two people share ("My sister Maria" with Maria Chen and Maria
    // Diaz known) doesn't say which one; the reader's pick may rest on a restricted note, so the decision stays withheld.
    @Test func aPairedNameTwoPeopleShareDoesntShowIt() throws {
        let v = try TestVault()
        func read(_ text: String, _ s: Sensitivity, day: Double, _ x: (Database) throws -> FactsExtraction) throws -> String {
            let now = t0.plus(days: day)
            let mem = try v.memory("Note \(Int(day))", text, sensitivity: s, now: now)
            try v.store.writer.write { db in
                try FactStore.apply(db, memoryID: mem.id.db, version: mem.version, extraction: try x(db), callGroup: people, registry: reg,
                                    userAliases: [], now: now)
            }
            return mem.id.db
        }
        _ = try read("Maria Chen wore red and Maria Diaz wore blue. My sister Beth Jones joined us.", .low, day: 0) { _ in
            var x = FactsExtraction()
            x.people = ["Maria Chen", "Maria Diaz", "Beth Jones"].map { ExtractedPerson(name: $0, person: "new") }
            x.facts = [ExtractedFact(predicate: sibling, name: "Beth Jones", entity: "name", label: "sister",
                                     quote: "My sister Beth Jones", status: .current)]
            return x
        }
        // Only about Beth: neither Maria is touched, so the namesake rule keeps the name link.
        _ = try read("Beth Jones says my other sister always wears red.", .restricted, day: 1) { _ in
            var x = FactsExtraction()
            x.people = [ExtractedPerson(name: "Beth Jones", person: "new")]
            x.facts = [ExtractedFact(predicate: sibling, name: "Beth Jones", entity: "name", label: "sister",
                                     quote: "Beth Jones says my other sister", status: .current)]
            return x
        }
        let mid = try read("My sister Maria called.", .low, day: 2) { db in
            let chen = try #require(try String.fetchOne(db, sql: "SELECT entity_id FROM entity_alias WHERE alias = 'Maria Chen'"))
            let token = try #require(try String.fetchOne(db, sql: "SELECT updated_at FROM entity WHERE id = ?", arguments: [chen]))
            var x = FactsExtraction()
            x.people = [ExtractedPerson(name: "Maria", person: chen)]
            x.roles = [ExtractedRole(phrase: 0, refersTo: chen)]
            x.roster = [chen: token]
            return x
        }
        let (send, whole) = try v.store.writer.read { db in
            (try FactStore.load(db, registry: reg, userAliases: [], uses: .everyDeclared(reg), sendable: .upTo(.low)).graph,
             try FactStore.load(db, registry: reg, userAliases: [], uses: .everyDeclared(reg)).graph)
        }
        func named(_ g: FactsGraph) -> Bool { g.decisions.contains { $0.key.memoryID == mid && $0.value.basis == .named } }
        #expect(named(whole))
        #expect(!named(send))
    }
}

