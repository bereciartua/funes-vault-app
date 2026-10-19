import BridgeKitCore
import Foundation
import FunesProtocol

/// Funes's values for BridgeKitCore (spec/architecture/mcp-server.md).
public enum FunesMCPConfiguration {
    /// Avoids EK Bridge's 47615 and 47616.
    public static let defaultPort = 47625
    /// The ports Settings ▸ MCP accepts: no privileged ones.
    public static let portRange = 1024...65_535
    /// `server/discover` names the agent a key belongs to under this key (`funes-mcp check`).
    public static let agentMetaKey = "com.funesvault/agent"
    /// `agent-keys/<agentId>.key` (storage §1).
    public static let keyFolderName = "agent-keys"
    public static let keyFile = SecretFileKind(fileSuffix: ".key", maxBytes: 128)
    /// `agent-keys/<agentId>.remote.key`: the agent's Remote Access token (ADR-0018).
    public static let remoteKeyFile = SecretFileKind(fileSuffix: ".remote.key", maxBytes: 128)
    /// How long `request_memory` waits for the panel before returning `needs_approval` (Spike 3).
    public static let inCallWait: Duration = .seconds(45)
    /// The time to answer a call, below agents' 60 s.
    public static let toolCallTimeout: TimeInterval = 55
    public static let serverDescription =
        "Personal memory from the user's Funes vault on their Mac, limited to what the user allowed this agent."

    /// mcp-server.md §9.
    public static var limits: RateLimiter.Policy {
        var policy = RateLimiter.Policy()
        policy.callsPerMinute = 120
        policy.callBurst = 30
        policy.writesPerMinute = 20
        policy.writeBurst = 10
        policy.writesPerDay = 250
        policy.failedAuthsPerMinute = 120
        policy.failedAuthLockout = 60
        // Remote Access (§12): EK Bridge's stricter buckets, taken in addition to the agent's own,
        // and the lockout per forwarded address.
        policy.remoteCallsPerMinute = 60
        policy.remoteCallBurst = 15
        policy.remoteWritesPerMinute = 10
        policy.remoteWriteBurst = 5
        policy.remoteFailedAuthsPerMinute = 30
        policy.remoteFailedAuthLockout = 300
        return policy
    }

    /// `callTimeout` is longer only in a Debug build measuring how long agents wait (task 4b.15).
    public static func server(dataFolder: URL, version: String, port: Int = defaultPort,
                              allowedOrigins: Set<String> = [], callTimeout: TimeInterval = toolCallTimeout) -> BridgeConfiguration {
        let app = "Funes Vault"
        return BridgeConfiguration(
            identity: BridgeIdentity(displayName: app, bundleID: Identifiers.macBundleID, dataFolder: dataFolder,
                                     version: version),
            mcpPort: port, keyPrefix: Identifiers.mcpKeyPrefix, serverKey: Identifiers.mcpServerKey,
            launcherName: Identifiers.mcpLauncherName, serverDescription: serverDescription,
            agentMetaKey: agentMetaKey, limits: limits, toolCallTimeout: callTimeout,
            allowedOrigins: allowedOrigins,
            // mcp-server.md §4: X-Forwarded-*, Forwarded, CF-* and Tailscale-* are refused.
            forwardedHeaderPrefixes: ["x-forwarded-", "forwarded", "cf-", "tailscale-"],
            stringLength: .unicodeScalars,
            // Longer ids get -32600 before any tool runs, so bundles keep room for exactly this
            // much (`BundleCompiler.requestIDBytes`; mcp-server.md §9).
            maxIDBytes: JSONRPC.defaultMaxIDBytes,
            texts: BridgeTexts(
                unavailable: "\(app) can't read its vault. Ask the user to open \(app).",
                unauthorized: "\(app) doesn't recognize this agent's key. "
                    + "Copy the setup again from the agent's page in \(app).",
                tunnelRefused: "This port is only for agents on this Mac."))
    }
}
