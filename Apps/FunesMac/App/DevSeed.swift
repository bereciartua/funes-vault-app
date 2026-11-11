#if DEBUG
import Foundation
import FunesCore
import FunesProtocol
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "dev-seed")

/// Debug builds only, with `--dev-seed`: SampleData in an empty development vault (memories in
/// every state, agents including "Claude Code" with read and suggest, asking before sharing and
/// saving, and Inbox items). Writes Claude Code's id (not its key) to `dev-seed.json` in the data
/// folder; the key is in agent-keys/ as usual. Never the real vault: it needs FUNES_DATA_DIR, and
/// a vault with anything in it is left alone (a vault it seeded before only gets the id again).
enum DevSeed {
    static func runIfAsked(_ environment: VaultEnvironment) async {
        guard CommandLine.arguments.contains("--dev-seed") else { return }
        guard Preferences.isDevelopmentVault else {
            logger.error("--dev-seed needs a development vault (FUNES_DATA_DIR); nothing was seeded")
            return
        }
        do {
            let existing = try await environment.agents.agents(includingRemoved: true)
            if let agent = existing.first(where: { $0.name == "Claude Code" && !$0.isRemoved }) {
                write(agentID: agent.id, to: environment.dataFolder)
                return
            }
            guard existing.isEmpty, try await isEmpty(environment) else {
                logger.error("--dev-seed needs an empty vault; nothing was seeded")
                return
            }
            let agents = try await SampleData.fill(environment)
            write(agentID: agents.claudeCode.id, to: environment.dataFolder)
            logger.notice("Seeded the development vault")
        } catch {
            logger.error("Seeding the development vault failed")
        }
    }

    /// No memory in any state, and nothing in the Inbox.
    private static func isEmpty(_ environment: VaultEnvironment) async throws -> Bool {
        let now = Date()
        for status in [MemoryFilter.StatusFilter.activeIncludingExpired, .archived, .recentlyDeleted]
        where !(try environment.store.memories(MemoryFilter(status: status), now: now, limit: 1)).isEmpty {
            return false
        }
        return try await environment.suggestions.pending().isEmpty
    }

    private static func write(agentID: UUID, to folder: URL) {
        let object = ["agent_id": agentID.uuidString.lowercased(), "agent_name": "Claude Code"]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("dev-seed.json"), options: .atomic)
        }
    }
}
#endif
