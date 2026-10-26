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
        try await tidyUp(environment, now: now)
        try await history(environment, claude: claude, cursor: cursor, codex: codex, now: now)
        return Agents(claudeCode: claude, cursor: cursor, codex: codex)
    }

    /// Twelve weeks of comings and goings for Home's pulse (task 7.3): memories from the Mac, the
    /// iPhone, agents, an import and tidy-ups, busiest on Sundays; and the agents' requests through
    /// the real policy, Claude Code's approved and delivered, Cursor's shared without asking, some
    /// refused. Seeded, so every run draws the same chart.
    private static func history(_ environment: VaultEnvironment, claude: Agent, cursor: Agent, codex: Agent,
                                now: Date) async throws {
        let store = environment.store
        let notes: [(String, String, String, Sensitivity)] = [
            ("Standing desk", "Works standing in the mornings, sitting after lunch.", "personal_preferences", .low),
            ("Tabs over spaces", "Indents with tabs in Go, spaces everywhere else.", "software_development", .low),
            ("Reads on the train", "Reads on the commute; prefers paper books.", "personal_preferences", .public),
            ("Quarterly planning", "Plans the quarter in the first week of January, April, July and October.", "project_context", .internal),
            ("Swift Testing", "Prefers Swift Testing's #expect over XCTest assertions.", "software_development", .low),
            ("No meetings on Fridays", "Keeps Friday afternoons free of meetings.", "communication_style", .low),
            ("Espresso machine", "Has a lever espresso machine at home.", "personal_preferences", .public),
            ("Harbor design review", "Harbor's design review is with the club's board.", "project_context", .internal),
            ("Prefers SQLite", "Picks SQLite for local data before anything heavier.", "software_development", .low),
            ("Bikes to work", "Cycles to the office when it's dry.", "personal_preferences", .public),
            ("Weekly review", "Does a weekly review on Sunday evenings.", "personal_preferences", .low),
            ("Git rebase", "Rebases feature branches; never rewrites main.", "software_development", .low),
            ("Spanish at home", "Speaks Spanish at home and English at work.", "communication_style", .low),
            ("Sourdough", "Bakes sourdough at the weekend.", "personal_preferences", .public),
            ("Release notes", "Writes release notes for users, not for developers.", "communication_style", .low),
            ("Dentist", "Sees the dentist every six months.", "health", .sensitive),
            ("Mechanical keyboard", "Types on a mechanical keyboard with brown switches.", "personal_preferences", .public),
            ("Harbor budget", "Harbor's budget is reviewed monthly.", "project_context", .internal),
            ("Prefers Markdown", "Writes notes and docs in Markdown.", "software_development", .low),
            ("Early riser", "Starts the day at 6:30.", "personal_preferences", .low),
            ("Code review", "Reviews pull requests in the morning, before writing code.", "software_development", .low),
            ("Podcast", "Listens to history podcasts while cooking.", "personal_preferences", .public),
            ("Swimming", "Swims on Wednesdays.", "personal_preferences", .low),
            ("Accessible UI", "Checks every screen with VoiceOver and Increase Contrast.", "software_development", .low),
            ("Board games", "Plays board games with friends on the first Saturday of the month.", "personal_preferences", .public),
            ("Short emails", "Keeps emails to five sentences.", "communication_style", .low),
            ("Learning Rust", "Working through the Rust book in the evenings.", "software_development", .low),
            ("Harbor launch", "Harbor launches to club members in the spring.", "project_context", .internal),
            ("Running shoes", "Replaces running shoes every 800 km.", "personal_preferences", .low),
            ("Tea in the afternoon", "Switches to green tea after 3 pm.", "personal_preferences", .public),
            ("Typed errors", "Uses typed error enums in Swift.", "software_development", .low),
            ("Physio", "Sees a physio for the knee every other week.", "health", .sensitive),
            ("Photography", "Shoots film on holidays.", "personal_preferences", .public),
            ("Feature flags", "Ships behind feature flags and removes them within a month.", "software_development", .low),
            ("Garden", "Grows tomatoes and basil on the balcony.", "personal_preferences", .public),
            ("Calm notifications", "Turns off badges for everything except messages.", "personal_preferences", .low),
        ]
        var rng = SampleRandom(seed: 7)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        // Which days get a memory: more lately, more on Sundays, a quiet stretch six weeks back.
        var days: [Int] = []
        for back in stride(from: 83, through: 1, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let sunday = calendar.component(.weekday, from: day) == 1
            let chance = (back > 38 && back < 46) ? 0.05 : (sunday ? 0.85 : (back < 30 ? 0.4 : 0.25))
            if rng.chance(chance) { days.append(back) }
        }
        let sources: [MemorySource] = [.captureMac, .captureMac, .manual, .captureIPhone, .captureIPhone, .agentSuggestion, .tidyUp]
        for (index, note) in notes.enumerated() {
            let back = days.isEmpty ? 1 : days[index * days.count / notes.count]
            var draft = MemoryDraft(title: note.0, body: note.1, categoryKeys: [note.2], sensitivity: note.3)
            draft.source = index % 9 == 4 ? .importClaude : sources[rng.next(sources.count)]
            if draft.source == .agentSuggestion { draft.sourceAgentID = claude.id }
            let at = calendar.date(byAdding: .day, value: -back, to: today)!.addingTimeInterval(Double(9 + rng.next(11)) * 3_600)
            _ = try store.createMemory(draft, now: at)
        }

        // Requests: Claude Code most days and Cursor on weekdays, approved and delivered; paused
        // Codex refused now and then.
        let disclosures = environment.disclosures
        let tasks: [(String, [String])] = [
            ("Set up the test target for the new package", ["test framework", "swift"]),
            ("Write the commit message for this change", ["commit messages"]),
            ("Draft a reply to the design review thread", ["communication", "short emails"]),
            ("Plan the Harbor release checklist", ["harbor", "release"]),
            ("Add a SQLite cache to the sync service", ["sqlite", "storage"]),
        ]
        func share(_ agent: Agent, _ task: (String, [String]), at: Date) async throws {
            guard at < now else { return }
            let outcome = try await disclosures.request(agentID: agent.id, MemoryRequest(task: task.0, keywords: task.1), now: at)
            guard outcome.status == .needsApproval, let id = outcome.requestID else { return }
            let panel = try await disclosures.panel(requestID: id, now: at + 30)
            let chosen = panel.map { $0.strong.isEmpty ? Array($0.memories.prefix(2).map(\.id)) : Array($0.strong) } ?? []
            guard let panel, !chosen.isEmpty else {
                try await disclosures.deny(requestID: id, now: at + 30)
                return
            }
            try await disclosures.approve(requestID: id, snapshotRevision: panel.snapshotRevision, memoryIDs: chosen, now: at + 40)
            _ = try await disclosures.deliver(requestID: id, agentID: agent.id, now: at + 45)
        }
        for back in stride(from: 83, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let workday = weekday != 1 && weekday != 7
            for _ in 0..<(rng.chance(back < 35 ? 0.8 : 0.45) ? 1 + rng.next(2) : 0) {
                let at = day.addingTimeInterval(Double(9 + rng.next(9)) * 3_600 + Double(rng.next(3_000)))
                try await share(claude, tasks[rng.next(tasks.count)], at: at)
            }
            if workday && rng.chance(back < 40 ? 0.6 : 0.3) {
                try await share(cursor, tasks[rng.next(2)], at: day.addingTimeInterval(Double(10 + rng.next(8)) * 3_600))
            }
            if rng.chance(0.1) {
                let at = day.addingTimeInterval(Double(14 + rng.next(5)) * 3_600)
                if at < now {
                    _ = try await disclosures.request(agentID: codex.id, MemoryRequest(task: tasks[0].0, keywords: tasks[0].1), now: at)
                }
            }
        }
    }

    /// Phase 6b's Tidy-up section, through the real run with a canned model: a duplicate archived
    /// automatically, a merge and a conflict left for the user.
    private static func tidyUp(_ environment: VaultEnvironment, now: Date) async throws {
        let store = environment.store
        let pairs: [(String, String, String, Sensitivity, Int)] = [
            ("Prefers dark mode", "Use dark mode in every app.", "personal_preferences", .low, 50),
            ("Dark mode", "Dark mode everywhere, please.", "personal_preferences", .low, 2),
            ("Running days", "I run on Tuesdays and Saturdays.", "personal_preferences", .low, 80),
            ("Running schedule", "I run on Mondays and Thursdays.", "personal_preferences", .low, 1),
            ("Harbor beta", "Harbor beta to club members by 31 January.", "project_context", .internal, 20),
            ("Harbor submission", "Harbor App Store submission by 1 March.", "project_context", .internal, 3),
        ]
        for (title, body, category, sensitivity, days) in pairs {
            _ = try store.createMemory(MemoryDraft(title: title, body: body, categoryKeys: [category], sensitivity: sensitivity),
                                       now: now.addingTimeInterval(-Double(days) * 86_400))
        }
        let router = ModelRouter(classifier: SampleTidyUp(), onDevice: nil)
        _ = try await TidyUpService(store: store, activity: environment.activity).run(
            .init(router: router, autoApply: TidyUpAutoApply(level: .exceptConflicts, qualified: ["sample": .duplicatesOnly])),
            now: now.addingTimeInterval(-3 * 3_600))
    }

    /// Phase 6a's Inbox: an agent's dump split into a group (new pieces, an update, one already
    /// saved, one outside its scope) and a seed answer applied automatically, all through the real
    /// pipeline with a canned model; then a capture still being split ("Processing…") and one
    /// whose split failed ("Couldn't split").
    private static func split(_ environment: VaultEnvironment, claude: Agent, now: Date) async throws {
        let dump = "The user is vegetarian and switched their coffee order to a cortado. They run 30 km a week and are "
            + "recovering from runner's knee. They prefer short, direct answers."
        _ = try await environment.suggestions.suggest(agentID: claude.id, SuggestInput(
            title: "What I know about you", body: dump, kind: .summary, categories: ["personal_preferences"], sensitivity: .low),
            now: now.addingTimeInterval(-40 * 60))
        _ = try await environment.suggestions.seed(SeedQuestion.all[1], answer: "Bullet points for lists. No emojis.", now: now)
        let router = ModelRouter(classifier: SampleSplitter(), onDevice: nil)
        let processor = NewMemoryProcessor(
            store: environment.store, captures: environment.captures, now: { now },
            configuration: { .init(router: router, split: true,
                                   autoApply: NewMemoryAutoApply(level: .exceptConflicts, qualified: ["sample": .exceptConflicts])) })
        let queue = ProcessingQueue(store: environment.store, activity: environment.activity)
        try await queue.drain(now: { now }, processor.process)
        // The failed one's job gave up; the other's stays running, so nothing else is taken.
        _ = try await environment.captures.capture("Dentist on the 14th at 9:30, and renew the car insurance",
                                                   now: now.addingTimeInterval(-8 * 60))
        if let job = try await queue.claim(now: now) { try await queue.finish(job, .failed(code: "timeout"), now: now) }
        _ = try await environment.captures.capture("Learning Portuguese on Duolingo, and I read before bed",
                                                   now: now.addingTimeInterval(-60))
        _ = try await queue.claim(now: now)
    }
}

/// A small seeded generator, so the sample history is the same on every run.
private struct SampleRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(upperBound, 1)))
    }

    mutating func chance(_ p: Double) -> Bool { Double(next(10_000)) / 10_000 < p }
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

/// The canned model behind SampleData's tidy-up: the dark-mode pair is a duplicate, the Harbor
/// dates merge, and the running days disagree.
private struct SampleTidyUp: GenerationProvider {
    let id: ProviderID = "sample"
    let locality = Locality.localServer
    let modelID = "sample"

    func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        var aliases: [String: String] = [:]
        let lines = request.prompt.split(separator: "\n").map(String.init)
        for (i, line) in lines.enumerated() where line.hasPrefix("<memory id=\"") && i + 1 < lines.count {
            aliases[lines[i + 1]] = String(line.dropFirst(12).prefix { $0 != "\"" })
        }
        func alias(_ prefix: String) -> String? { aliases.first { $0.key.hasPrefix(prefix) }?.value }
        var actions: [[String: Any]] = []
        if let old = alias("Prefers dark mode"), let new = alias("Dark mode.") {
            actions.append(["type": "archive", "target": new, "survivor": old, "archiveReason": "duplicate",
                            "reason": "\(new) says the same as \(old).", "confidence": 0.95])
        }
        if let a = alias("Running days"), let b = alias("Running schedule") {
            actions.append(["type": "conflict", "ids": [a, b], "question": "Which days do you run now: Tuesdays and Saturdays, or Mondays and Thursdays?"])
        }
        if let a = alias("Harbor beta"), let b = alias("Harbor submission") {
            actions.append(["type": "merge", "sources": [a, b], "title": "Harbor dates", "kind": "project_context",
                            "body": "Harbor beta to club members by 31 January; App Store submission by 1 March.",
                            "keptPerSource": [["id": a, "kept": "the beta date"], ["id": b, "kept": "the submission date"]],
                            "reason": "Two dates of the same release plan.", "confidence": 0.9])
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["actions": actions]), as: UTF8.self)
        return (try JSONDecoder().decode(T.self, from: Data(json.utf8)), ProviderUsage(requests: 1))
    }
}
#endif
