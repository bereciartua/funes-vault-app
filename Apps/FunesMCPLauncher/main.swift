import BridgeKitCore
import Foundation
import FunesProtocol

// funes-mcp: the stdio launcher agents run (FunesVault.app/Contents/MacOS/funes-mcp).
// BridgeKitCore's launcher with Funes's names and paths: a dumb pipe to the in-app MCP
// server, Claude Code's headersHelper (`headers`) and a self-test (`check`). It reads the
// agent's key from agent-keys/<agentId>.key and sends it only to a listener it verified is
// this user's Funes Vault (mcp-server.md §1, overview "funes-mcp").

private let app = "Funes Vault"
private let launcher = Identifiers.mcpLauncherName

/// `~/Library/Application Support/FunesVault`. Debug builds honour FUNES_DATA_DIR, like the
/// app, so a development vault never touches the real one.
private let supportDirectory: @Sendable () -> String = {
    #if DEBUG
    if let override = ProcessInfo.processInfo.environment["FUNES_DATA_DIR"], !override.isEmpty { return override }
    #endif
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Identifiers.supportFolderName, isDirectory: true).path
}

BridgeLauncher.run(LauncherConfiguration(
    launcherName: launcher,
    displayName: app,
    keyPrefix: Identifiers.mcpKeyPrefix,
    supportDirectory: supportDirectory,
    keyFolderName: "agent-keys",
    keyFileSuffix: ".key",
    agentOption: "agent",
    agentMetaKey: "com.funesvault/agent",
    // list_memory_categories is read-only and always visible, so it tells whether Funes is on.
    probe: LauncherProbe(tool: "list_memory_categories") { result in
        let structured = result["structuredContent"] as? [String: Any]
        guard structured?["status"] as? String == "denied" else { return .on }
        switch structured?["reason"] as? String {
        case "funes_paused": return .warning("\(app) is paused: requests will be refused until it's resumed")
        case "agent_paused": return .warning("this agent is paused: requests will be refused until it's resumed in \(app)")
        case "access_expired": return .warning("this agent's access has expired: renew it in \(app)")
        case let reason: return .warning("list_memory_categories was refused (\(reason ?? "unknown"))")
        }
    },
    texts: LauncherTexts(
        help: """
            Usage: \(launcher) --agent ID                      stdio MCP relay
                   \(launcher) --token-file PATH               stdio relay, explicit key file
                   \(launcher) headers --agent ID --url URL    for Claude Code's headersHelper
                   \(launcher) check --agent ID                diagnose a setup
                   \(launcher) --help | --version

            Connects an agent on this Mac to \(app)'s MCP server. The relay reads one JSON-RPC
            message per stdin line, posts it to the server and writes each reply as one stdout
            line. Problems go to stderr. Copy the setup for your agent from its page in \(app).

            Options:
              --agent ID          The agent's ID (a UUID). Its key is read from
                                  ~/Library/Application Support/\(Identifiers.supportFolderName)/agent-keys.
              --token-file PATH   Read the key from this file (mode 600) instead.
              --url URL           headers only: the URL in the agent's config. The key is
                                  printed only when it's the URL the app serves and the listener
                                  there is this user's \(app).
                                  CLAUDE_CODE_MCP_SERVER_URL takes precedence when set.

            Exit codes:
              0  ok (relay: stdin closed)
              1  check: key rejected
              2  usage error
              3  check, headers: app or server unavailable, or another program on its port
              4  missing or unsafe key file
            headers prints {} on stdout whenever it refuses, with the reason on stderr.

            """,
        agentIDNotUUID: "--agent takes the agent's ID (a UUID), not its name. "
            + "Copy the setup from the agent's page in \(app).",
        squatter: "Another program is using \(app)'s port. Open \(app) and check Settings ▸ MCP.",
        rejected: "\(app) doesn't recognize this agent's key. Open the agent in \(app) and check its key.",
        rejectedLog: "the key was rejected. Open the agent in \(app) and check its key.",
        urlMismatch: { target, served in
            "the agent's URL \(target) isn't the one \(app) serves (\(served)). "
                + "Copy the setup again from the agent's page."
        },
        agentNoun: "agent",
        noTools: "no tools available: give this agent access in \(app)",
        checkRejected: "key rejected: open the agent in \(app) and check its key")))
