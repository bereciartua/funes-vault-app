#if DEBUG
import Foundation
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "dev-seed")

/// Debug builds only, with `--dev-seed`: SampleData in an empty vault (memories in every state,
/// agents including "Claude Code" with read and suggest, asking before sharing and saving, and
/// Inbox items). Writes Claude Code's id (not its key) to `dev-seed.json` in the data folder; the
/// key is in agent-keys/ as usual.
enum DevSeed {
    static func runIfAsked(_ environment: VaultEnvironment) async {
        guard CommandLine.arguments.contains("--dev-seed") else { return }
        do {
            let existing = try await environment.agents.agents()
            if let agent = existing.first(where: { $0.name == "Claude Code" }) {
                write(agentID: agent.id, to: environment.dataFolder)
                return
            }
            let agents = try await SampleData.fill(environment)
            write(agentID: agents.claudeCode.id, to: environment.dataFolder)
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
