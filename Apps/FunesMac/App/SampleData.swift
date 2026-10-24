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
            _ = try? store.archiveMemory(id: old.id, now: now.addingTimeInterval(-20 * 86_400))
        }
        if let gone = try? store.createMemory(MemoryDraft(title: "Gym schedule", body: "Mondays and Thursdays at 7.",
                                                          categoryKeys: ["personal_preferences"]), now: now.addingTimeInterval(-60 * 86_400)) {
            _ = try? store.deleteMemory(id: gone.id, now: now.addingTimeInterval(-4 * 86_400))
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
        try await split(environment, claude: claude, now: now)
        return Agents(claudeCode: claude, cursor: cursor, codex: codex)
    }

    /// Phase 6a's Inbox: an agent's dump split into a group (new pieces, an update, one already
    /// saved, one outside its scope), a capture whose split arrived while its card was open (an
    /// offer), and a seed answer applied automatically, all through the real pipeline with a
    /// canned model.
    private static func split(_ environment: VaultEnvironment, claude: Agent, now: Date) async throws {
        let dump = "The user is vegetarian and switched their coffee order to a cortado. They run 30 km a week and are "
            + "recovering from runner's knee. They prefer short, direct answers."
        _ = try await environment.suggestions.suggest(agentID: claude.id, SuggestInput(
            title: "What I know about you", body: dump, kind: .summary, categories: ["personal_preferences"], sensitivity: .low),
            now: now.addingTimeInterval(-40 * 60))
        let offer = try await environment.captures.capture("Learning Portuguese on Duolingo, and I read before bed", now: now.addingTimeInterval(-5 * 60))
        _ = try await environment.suggestions.seed(SeedQuestion.all[1], answer: "Bullet points for lists. No emojis.", now: now)
        let router = ModelRouter(classifier: SampleSplitter(), onDevice: nil)
        let holds = SuggestionHolds()
        holds.hold(offer.suggestionID, .editing)
        let processor = NewMemoryProcessor(
            store: environment.store, captures: environment.captures, holds: holds, now: { now },
            configuration: { .init(router: router, split: true,
                                   autoApply: NewMemoryAutoApply(level: .exceptConflicts, qualified: ["sample": .exceptConflicts])) })
        let queue = ProcessingQueue(store: environment.store, activity: environment.activity)
        try await queue.drain(now: { now }, processor.process)
    }
}

/// The canned model behind SampleData's splits: fixed pieces for the sample inputs, and decisions
/// that update the coffee memory and recognise the vegetarian one.
private struct SampleSplitter: GenerationProvider {
    let id: ProviderID = "sample"
    let locality = Locality.localServer
    let modelID = "sample"

    func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        func piece(_ body: String, _ quote: String, _ title: String, _ category: String = "personal_preferences",
                   sensitivity: String = "low", atomic: Bool = true) -> [String: Any] {
            ["evidence": [quote], "body": body, "title": title, "kind": "preference", "categoryKeys": [category],
             "sensitivity": sensitivity, "timeLimited": false, "intent": "assertion", "atomic": atomic, "confidence": 0.9]
        }
        let object: [String: Any]
        if request.schemaName == "Decisions" {
            var decisions: [[String: Any]] = []
            for line in request.prompt.split(separator: "\n") where line.hasPrefix("<piece index=") {
                let index = Int(line.split(separator: "\"")[1]) ?? 0
                guard let alias = request.prompt.split(separator: "\n").first(where: {
                    $0.hasPrefix("- m") && (line.contains("cortado") ? $0.contains("Coffee order") : line.contains("vegetarian") && $0.contains("Vegetarian"))
                })?.split(separator: " ")[1] else { continue }
                decisions.append(line.contains("cortado")
                    ? ["piece": index, "action": "update", "target": String(alias), "body": "Cortado, no sugar.", "reason": "", "confidence": 0.9]
                    : ["piece": index, "action": "duplicate", "target": String(alias), "body": "", "reason": "", "confidence": 0.9])
            }
            object = ["decisions": decisions]
        } else if request.prompt.contains("The user is vegetarian") {
            object = ["pieces": [
                piece("I'm vegetarian.", "The user is vegetarian", "Vegetarian"),
                piece("My coffee order is a cortado.", "switched their coffee order to a cortado", "Coffee order: cortado"),
                piece("I run 30 km a week.", "They run 30 km a week", "Runs 30 km a week"),
                piece("I'm recovering from runner's knee.", "are recovering from runner's knee", "Recovering from runner's knee",
                      "health", sensitivity: "sensitive"),
                piece("I prefer short, direct answers.", "They prefer short, direct answers", "Short, direct answers",
                      "communication_style"),
            ]]
        } else if request.prompt.contains("Learning Portuguese") {
            object = ["pieces": [piece("I'm learning Portuguese on Duolingo.", "Learning Portuguese on Duolingo", "Learning Portuguese"),
                                 piece("I read before bed.", "I read before bed", "Reads before bed")]]
        } else if request.prompt.contains("Bullet points") {
            object = ["pieces": [piece("I like bullet points for lists.", "Bullet points for lists", "Bullet points for lists",
                                       "communication_style"),
                                 piece("I don't want emojis.", "No emojis", "No emojis", "communication_style")]]
        } else {
            object = ["pieces": []]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return (try JSONDecoder().decode(T.self, from: Data(json.utf8)), ProviderUsage(requests: 1))
    }
}
#endif
