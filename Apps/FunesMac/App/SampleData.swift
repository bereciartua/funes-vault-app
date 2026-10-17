#if DEBUG || FUNES_UI_REVIEW
import Foundation
import FunesCore
import FunesProtocol

/// Made-up vault contents for development (`--dev-seed`) and the UI-review build: memories in
/// every state, agents in every status, suggestions from every source, and some Activity.
/// Never used in Release builds.
@MainActor
enum SampleData {
    struct Agents {
        var claudeCode: Agent
        var cursor: Agent?
        var codex: Agent?
    }

    /// Fills an empty vault. Returns the agents it made.
    @discardableResult
    static func fill(_ environment: VaultEnvironment, now: Date = Date(), rich: Bool = true) async throws -> Agents {
        let store = environment.store
        let memories: [(String, String, String, Sensitivity, MemoryKind, Int)] = [
            ("Prefers pnpm and Vitest", "Use pnpm for packages and Vitest for tests in TypeScript projects.",
             "software_development", .low, .preference, 40),
            ("Writes Swift 6", "New Mac code is Swift 6 with strict concurrency and Swift Testing.",
             "software_development", .low, .instruction, 12),
            ("Commit messages", "Short imperative subject, details in the body, task ids in the subject.",
             "software_development", .low, .instruction, 30),
            ("Coffee order", "Flat white with oat milk, no sugar.", "personal_preferences", .public, .preference, 90),
            ("Vegetarian", "Doesn't eat meat or fish; eggs and dairy are fine.", "personal_preferences", .low, .fact, 120),
            ("Funes launch", "Funes Vault v0.1 ships as a Mac preview first.", "project_context", .internal, .projectContext, 3),
            ("Penicillin allergy", "Allergic to penicillin since childhood.", "health", .sensitive, .fact, 200),
            ("Plain answers", "Prefers short, direct answers with the reasoning after the result.", "communication_style",
             .low, .preference, 7),
        ]
        var made: [Memory] = []
        for (index, (title, body, category, sensitivity, kind, days)) in memories.enumerated() {
            let memory = try store.createMemory(MemoryDraft(title: title, body: body, kind: kind, categoryKeys: [category],
                                                            sensitivity: sensitivity),
                                                now: now.addingTimeInterval(-Double(days) * 86_400 - Double(index) * 60))
            made.append(memory)
        }
        let readAndSuggest = Access(operations: [.read, .suggest], maxSensitivity: .internal,
                                    deniedCategoryKeys: ["health", "finance", "legal"], askBeforeSharing: true,
                                    askBeforeSaving: true)
        let (claude, _) = try await environment.agents.create(name: "Claude Code", kind: .claudeCode, access: readAndSuggest,
                                                              declaredRetention: .session, now: now.addingTimeInterval(-9 * 86_400))
        guard rich else { return Agents(claudeCode: claude) }

        if let trip = try? store.createMemory(MemoryDraft(title: "Lisbon trip", body: "In Lisbon for a conference in the first week of June.",
                                                          kind: .event, categoryKeys: ["personal_preferences"],
                                                          expiresAt: now.addingTimeInterval(3 * 86_400)), now: now.addingTimeInterval(-86_400)) {
            made.append(trip)
        }
        if let old = try? store.createMemory(MemoryDraft(title: "Old desk setup", body: "Uses a 27-inch display on the left.",
                                                         categoryKeys: ["personal_preferences"]), now: now.addingTimeInterval(-300 * 86_400)) {
            try? store.archiveMemory(id: old.id, now: now.addingTimeInterval(-20 * 86_400))
        }
        if let gone = try? store.createMemory(MemoryDraft(title: "Gym schedule", body: "Mondays and Thursdays at 7.",
                                                          categoryKeys: ["personal_preferences"]), now: now.addingTimeInterval(-60 * 86_400)) {
            try? store.deleteMemory(id: gone.id, now: now.addingTimeInterval(-4 * 86_400))
        }

        let (cursor, _) = try await environment.agents.create(
            name: "Cursor", kind: .cursor,
            access: Access(operations: [.read], maxSensitivity: .low, allowedCategoryKeys: ["software_development"]),
            asksForAccess: true, now: now.addingTimeInterval(-2 * 86_400))
        let (codex, _) = try await environment.agents.create(name: "Codex", kind: .codex, access: readAndSuggest,
                                                             now: now.addingTimeInterval(-30 * 86_400))
        try await environment.agents.pause(agentID: codex.id, now: now.addingTimeInterval(-86_400))

        // Claude Code has been talking to Funes: a request shared without asking, a suggestion and a
        // correction in the Inbox.
        let suggestions = environment.suggestions
        _ = try await suggestions.suggest(agentID: claude.id, SuggestInput(
            title: "Prefers Vitest over Jest", body: "Use Vitest for unit tests; Jest only in legacy repos.",
            kind: .preference, categories: ["software_development"], sensitivity: .low,
            evidence: "The user said \"we moved everything to Vitest last year\".", purpose: "Remember testing preferences"),
            now: now.addingTimeInterval(-25 * 60))
        _ = try await suggestions.suggest(agentID: claude.id, SuggestInput(
            title: "Commit messages", body: "Conventional commits: type(scope): subject, with task ids in the body.",
            kind: .instruction, categories: ["software_development"], sensitivity: .low,
            evidence: "Asked to switch to conventional commits.", targetMemoryID: made[2].id),
            now: now.addingTimeInterval(-12 * 60))
        _ = try await environment.captures.capture("Book the dentist before the end of the month", now: now.addingTimeInterval(-3_600))
        let preview = try await environment.imports.preview(ImportParser.claude("- Likes long walks\n- Reads science fiction"),
                                                             source: .claude)
        _ = try await environment.imports.commit(preview, now: now.addingTimeInterval(-2 * 86_400))
        return Agents(claudeCode: claude, cursor: cursor, codex: codex)
    }
}
#endif
