#if DEBUG
import Foundation
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "dev-seed")

/// Debug builds only, with `--dev-seed`: a few memories and a "Claude Code" agent (read and
/// suggest, asking before sharing and saving) in an empty vault, for development and the
/// Phase 2 live check until Phase 3's screens exist. Writes the agent's id (not its key) to
/// `dev-seed.json` in the data folder; the key is in agent-keys/ as usual.
enum DevSeed {
    static func runIfAsked(_ environment: VaultEnvironment) async {
        guard CommandLine.arguments.contains("--dev-seed") else { return }
        do {
            let existing = try await environment.agents.agents()
            if let agent = existing.first(where: { $0.name == "Claude Code" }) {
                write(agentID: agent.id, to: environment.dataFolder)
                return
            }
            let now = Date()
            for (title, body, category, sensitivity) in [
                ("Prefers pnpm and Vitest", "Use pnpm for packages and Vitest for tests in TypeScript projects.",
                 "software_development", Sensitivity.low),
                ("Writes Swift 6", "New Mac code is Swift 6 with strict concurrency and Swift Testing.",
                 "software_development", .low),
                ("Commit messages", "Short imperative subject, details in the body, task ids in the subject.",
                 "software_development", .low),
                ("Coffee order", "Flat white with oat milk, no sugar.", "personal_preferences", .public),
                ("Vegetarian", "Doesn't eat meat or fish; eggs and dairy are fine.", "personal_preferences", .low),
                ("Funes launch", "Funes Vault v0.1 ships as a Mac preview first.", "project_context", .internal),
                ("Penicillin allergy", "Allergic to penicillin since childhood.", "health", .sensitive),
            ] {
                _ = try environment.store.createMemory(MemoryDraft(title: title, body: body, categoryKeys: [category],
                                                                   sensitivity: sensitivity), now: now)
            }
            let access = Access(operations: [.read, .suggest], maxSensitivity: .internal, askBeforeSharing: true,
                                askBeforeSaving: true)
            let (agent, _) = try await environment.agents.create(name: "Claude Code", kind: .claudeCode, access: access,
                                                                 now: now)
            write(agentID: agent.id, to: environment.dataFolder)
            logger.notice("Seeded the development vault")
        } catch {
            logger.error("Seeding the development vault failed")
        }
    }

    private static func write(agentID: UUID, to folder: URL) {
        let object = ["agent_id": agentID.uuidString.lowercased(), "agent_name": "Claude Code"]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("dev-seed.json"), options: .atomic)
        }
    }
}
#endif
