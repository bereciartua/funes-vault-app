import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore
@testable import FunesCompanion

/// Phase 13b, older phones: with learned facts in use, `memories.search` gets link-admitted results as ordinary results
/// (no why line, nothing inferred: 13d's protocol fields add them), and `memories.answer` never reads a selection facts
/// shaped (memory processing §11.9, until 13d).
@Suite struct FactsSearchCompanionTests {
    func facts(_ h: CompanionHarness) throws -> (maria: UUID, sister: UUID) {
        let sib = FactsRegistry.bundled.predicates.first { $0.objectKind == "person" && $0.lexicon.contains { $0.words.contains("sister") } }!
        var ids: [UUID] = []
        for (title, body) in [("Maria is my sister", "We grew up in Porto together."),
                              ("My sister drinks her mate bitter", "Every morning, with no sugar."),
                              ("Weekly status", "Shipped the export fix."), ("Dentist", "Cleaning on Tuesday at nine."),
                              ("Bike repair", "The rear brake squeaks."), ("Garden", "Plant the tomatoes.")] {
            let m = try h.store.createMemory(MemoryDraft(title: title, body: body, kind: .fact, categoryKeys: ["personal_preferences"],
                                                         sensitivity: .low), now: t0)
            ids.append(m.id)
        }
        try h.store.writer.write { db in
            let x = FactsExtraction(people: [ExtractedPerson(name: "Maria", quote: "Maria is my sister")],
                                    facts: [ExtractedFact(predicate: sib.id, name: "Maria", label: "sister", quote: "Maria is my sister")])
            for (i, id) in ids.prefix(2).enumerated() {
                try FactStore.apply(db, memoryID: id.db, version: 1, extraction: i == 0 ? x : FactsExtraction(), callGroup: sib.callGroup,
                                    registry: .bundled, uses: .everyDeclared(.bundled), now: t0)
            }
        }
        var config = FactsSearchConfig(engines: [:], userAliases: [], cloudLimit: .upTo(.internal))
        config.measuredUses = .everyDeclared(.bundled)
        h.services.search.facts = config
        return (ids[0], ids[1])
    }

    @Test func aLinkAdmittedResultReachesThePhoneAsAnOrdinaryResult() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let (maria, sister) = try facts(h)
        let found = try await h.result(MemoriesSearch.self, MemorySearchParams(query: "Maria"), phone: phone)
        #expect(found.results.map(\.id).contains(maria))
        let r = try #require(found.results.first { $0.id == sister })
        // The memory's own words only: its start as the snippet, no match marks, no name it doesn't say.
        #expect(r.snippet == "Every morning, with no sugar." && r.snippetMatches == nil)
        let encoded = String(decoding: try JSONEncoder().encode(found), as: UTF8.self)
        #expect(!encoded.contains("why") && !encoded.lowercased().contains("only sister"))
    }
}
