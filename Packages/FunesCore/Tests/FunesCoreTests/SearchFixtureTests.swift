import Foundation
import Testing

/// The Spike 2 search benchmark fixtures (spec/plans/spike-results.md). Phase 1 task 1.4 runs
/// them as a recall regression; these tests only keep the files well-formed.
@Suite struct SearchFixtureTests {
    struct Memory: Decodable {
        let id: String
        let title: String
        let body: String
        let kind: String
        let categories: [String]
        let sensitivity: String
    }
    struct Query: Decodable {
        let id: String
        let query: String
        let relevant: [String]
    }
    struct MemoriesFile: Decodable { let memories: [Memory] }
    struct QueriesFile: Decodable { let queries: [Query] }

    static let categories: Set = [
        "communication_style", "personal_preferences", "software_development", "project_context",
        "privacy_preferences", "health", "finance", "legal",
    ]
    static let kinds: Set = [
        "fact", "preference", "instruction", "goal", "project_context", "relationship", "constraint", "event", "summary",
    ]
    static let sensitivities: Set = ["public", "low", "internal", "sensitive", "restricted", "secret"]

    func load<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "fixtures"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    @Test func memoriesAreWellFormed() throws {
        let memories = try load("memories-200", as: MemoriesFile.self).memories
        #expect(memories.count == 200)
        #expect(Set(memories.map(\.id)).count == memories.count)
        for m in memories {
            #expect((1...180).contains(m.title.count), "\(m.id)")
            #expect((1...10_000).contains(m.body.count), "\(m.id)")
            #expect(Self.kinds.contains(m.kind), "\(m.id)")
            #expect(Self.sensitivities.contains(m.sensitivity), "\(m.id)")
            #expect(!m.categories.isEmpty && Set(m.categories).isSubset(of: Self.categories), "\(m.id)")
        }
        #expect(Set(memories.flatMap(\.categories)) == Self.categories)
    }

    struct ExpandedQuery: Decodable {
        let id: String
        let query: String
        let keywords: [String]
        let categories: [String]
        let relevant: [String]
    }
    struct ExpandedFile: Decodable { let queries: [ExpandedQuery] }

    /// Spike 2b: the same 30 tasks with agent-supplied keywords and categories.
    @Test func expandedQueriesMatchTheBaseQueries() throws {
        let base = try load("queries-30", as: QueriesFile.self).queries
        let expanded = try load("queries-30-expanded", as: ExpandedFile.self).queries
        #expect(expanded.map(\.id) == base.map(\.id))
        #expect(expanded.map(\.query) == base.map(\.query))
        #expect(expanded.map(\.relevant) == base.map(\.relevant))
        for q in expanded {
            #expect((5...15).contains(q.keywords.count), "\(q.id)")
            #expect((1...3).contains(q.categories.count) && Set(q.categories).isSubset(of: Self.categories), "\(q.id)")
        }
    }

    @Test func queriesPointAtExistingMemories() throws {
        let ids = Set(try load("memories-200", as: MemoriesFile.self).memories.map(\.id))
        let queries = try load("queries-30", as: QueriesFile.self).queries
        #expect(queries.count == 30)
        #expect(Set(queries.map(\.id)).count == queries.count)
        for q in queries {
            #expect((1...3).contains(q.relevant.count), "\(q.id)")
            #expect(Set(q.relevant).isSubset(of: ids), "\(q.id)")
        }
    }
}
