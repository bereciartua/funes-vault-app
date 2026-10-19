import BridgeKitCore
import Foundation

// Adapted from EK Bridge's cloud agent setups (Upstream/AgentSetup.swift, "Cloud agents (§22.2)"):
// the setup to copy for each cloud agent on an agent's Cloud section (04-ux-mac.md, MCP server
// §12). EK Bridge's connections become Funes agents, its calendar examples memories, and the app's
// names come from `RemoteNames`. Pure, so every snippet is golden-tested
// (fixtures/agent-setup/cloud-*.txt). No snippet ever holds a token or a client secret: header-based
// ones read the remote token from an environment variable, or say where to paste it from.

/// A cloud agent the Cloud section can set up. Claude.ai, ChatGPT and Gemini Enterprise sign in
/// with OAuth; the others send the agent's remote token in a header. Codex cloud tasks can't add an
/// MCP server, so they're listed only to say so.
public enum CloudAgent: String, CaseIterable, Identifiable, Sendable {
    case claudeAI, chatGPT, geminiEnterprise, anthropicAPI, managedAgents, openAIResponses, claudeCodeCloud,
         cursorCloud, copilotAgent, devin, codexCloud

    public var id: String { rawValue }
}

/// What a cloud setup needs to know.
public struct CloudSetupContext: Sendable, Equatable {
    /// The public MCP URL with the secret path, `https://host/r/<secret>/mcp`; nil until Remote
    /// Access has a public address, and then the setup says to finish that first.
    public let mcpURL: String?
    /// The MCP server's name in configs: `funes`.
    public let serverKey: String
    /// The Funes agent this setup is for, as the user named it.
    public let agentName: String
    /// The OAuth scope Gemini Enterprise is told to ask for: `memory`.
    public let scope: String
    /// The tools the contract marks read-only, for agents that take an allowlist.
    public let readOnlyTools: [String]
    public let names: RemoteNames

    /// Funes's tools with `readOnlyHint` (mcp-tools.json).
    public static let funesReadOnlyTools = ["list_memory_categories", "request_memory", "get_memory_request", "open_in_funes"]

    public init(mcpURL: String?, serverKey: String = "funes", agentName: String, scope: String = "memory",
                readOnlyTools: [String] = CloudSetupContext.funesReadOnlyTools, names: RemoteNames = .funes) {
        self.mcpURL = mcpURL
        self.serverKey = serverKey
        self.agentName = agentName
        self.scope = scope
        self.readOnlyTools = readOnlyTools
        self.names = names
    }

    /// The public host, for allowlists.
    public var host: String? { mcpURL.map { URL(string: $0)?.host ?? $0 } }

    /// Where the OAuth routes live: the MCP URL without `/mcp`.
    var oauthBase: String? {
        mcpURL.map { $0.hasSuffix("/mcp") ? String($0.dropLast(4)) + "/oauth" : $0 + "/oauth" }
    }

    /// Copilot passes only secrets whose names start with COPILOT_MCP_.
    public var copilotSecretName: String { "COPILOT_MCP_" + names.remoteTokenEnvironmentVariable }

    /// Where a snippet says to paste the token by hand.
    public var remoteTokenPlaceholder: String { String(localized: "<remote token from \(names.copyTokenAction)>") }

    /// Every way a cloud snippet refers to the remote token without containing it.
    public var remoteTokenPlaceholders: [String] {
        ["$\(names.remoteTokenEnvironmentVariable)", "${\(names.remoteTokenEnvironmentVariable)}",
         "$\(copilotSecretName)", remoteTokenPlaceholder]
    }
}

extension CloudAgent {
    public var name: String {
        switch self {
        case .claudeAI: String(localized: "claude.ai · Claude Desktop · mobile")
        case .chatGPT: String(localized: "ChatGPT")
        case .geminiEnterprise: String(localized: "Gemini Enterprise")
        case .anthropicAPI: String(localized: "Anthropic API (MCP connector)")
        case .managedAgents: String(localized: "Claude Managed Agents")
        case .openAIResponses: String(localized: "OpenAI Responses API")
        case .claudeCodeCloud: String(localized: "Claude Code on the web")
        case .cursorCloud: String(localized: "Cursor cloud agents")
        case .copilotAgent: String(localized: "GitHub Copilot coding agent")
        case .devin: String(localized: "Devin")
        case .codexCloud: String(localized: "Codex cloud tasks")
        }
    }

    /// Signs in with OAuth (Connect a Cloud App…). The others, except Codex cloud tasks, send the
    /// remote token.
    public var usesOAuth: Bool { [.claudeAI, .chatGPT, .geminiEnterprise].contains(self) }

    /// False for Codex cloud tasks, which have no way to add an MCP server.
    public var isSupported: Bool { self != .codexCloud }

    /// Sends the agent's remote token in a header: the Cloud section offers Copy Remote Token….
    public var usesRemoteToken: Bool { isSupported && !usesOAuth }

    /// The agent kind the app stores for an agent set up from this tile (domain model `agentKind`).
    public var agentKind: String {
        switch self {
        case .claudeAI: "claude_ai"
        case .chatGPT: "chatgpt"
        case .geminiEnterprise: "gemini_enterprise"
        case .anthropicAPI: "anthropic_api"
        case .managedAgents: "managed_agents"
        case .openAIResponses: "openai_responses"
        case .claudeCodeCloud: "claude_code_web"
        case .cursorCloud: "cursor_cloud"
        case .copilotAgent: "copilot_agent"
        case .devin: "devin"
        case .codexCloud: "codex_cloud"
        }
    }

    /// An SF Symbol for the tile and the agent's icon.
    public var symbol: String {
        switch self {
        case .claudeAI: "sparkle"
        case .chatGPT: "bubble.left.and.bubble.right"
        case .geminiEnterprise: "building.2"
        case .anthropicAPI, .openAIResponses: "curlybraces"
        case .managedAgents: "gearshape.2"
        case .claudeCodeCloud, .codexCloud: "terminal"
        case .cursorCloud: "chevron.left.forwardslash.chevron.right"
        case .copilotAgent: "arrow.triangle.branch"
        case .devin: "hammer"
        }
    }

    /// Gemini Enterprise is configured with a client ID and secret rather than discovering the
    /// server: Set Up OAuth Client… sets up a confidential client with this redirect URI.
    public var preRegisteredRedirectURI: String? {
        // Where Gemini Enterprise returns after authorization (Google's custom MCP server docs).
        self == .geminiEnterprise ? "https://vertexaisearch.cloud.google.com/oauth-redirect" : nil
    }

    /// For every cloud agent that can connect, last.
    public static var awayWarning: String {
        String(localized: "Cloud agents often run while you're away. With Ask before sharing on, a request waits up to 45 s for you at this Mac; after that, you can still approve it from the pending list within 15 minutes.")
    }

    public func warnings(_ names: RemoteNames) -> [String] {
        let apiRunsTools = String(localized: "The API calls tools without asking you, so this agent's access in \(names.appName) is the only limit. Give it only the categories it needs.")
        let list: [String]
        switch self {
        case .anthropicAPI, .managedAgents, .openAIResponses:
            list = [apiRunsTools]
        case .claudeCodeCloud:
            list = [String(localized: "Anyone who uses that cloud environment can read its environment variables, including this token. Use an environment only you use, or on Pro and Max plans an API credential.")]
        case .copilotAgent:
            list = [String(localized: "Copilot runs MCP tools without asking for approval. Give this agent read access only and keep the tools list to the read tools.")]
        case .cursorCloud, .devin, .claudeAI, .chatGPT, .geminiEnterprise:
            list = []
        case .codexCloud:
            return []
        }
        return list + [Self.awayWarning]
    }

    public var footnote: String? {
        switch self {
        case .anthropicAPI:
            String(localized: "Keep the remote token with your app's other secrets; every request carries it.")
        case .managedAgents:
            String(localized: "The Anthropic vault matches the credential by URL. If you reset the secret path, add the credential again.")
        case .claudeCodeCloud:
            String(localized: "Cloud sessions load .mcp.json only when the session has one repository.")
        case .cursorCloud:
            String(localized: "Cursor keeps the header on its servers and relays tool calls, so the agent's machine never sees the token.")
        case .copilotAgent:
            String(localized: "Copilot can't sign in with OAuth, so it uses the remote token.")
        case .devin:
            nil
        case .openAIResponses:
            String(localized: "The authorization field takes the bare token, without Bearer.")
        case .claudeAI:
            String(localized: "Once added, the connector also works in Claude Desktop and the Claude mobile app. Claude signs in with OAuth; sending a fixed header is a limited beta.")
        case .chatGPT:
            String(localized: "ChatGPT can't send an API key, so it connects with OAuth.")
        case .geminiEnterprise:
            String(localized: "Gemini Enterprise needs an OAuth client set up ahead of time: Set Up OAuth Client… creates one for this agent. Clicking it again replaces one that hasn't connected.")
        case .codexCloud:
            String(localized: "Codex cloud tasks can't use your own MCP servers yet. Use Codex on this Mac with the local setup, or the OpenAI Responses API.")
        }
    }
}

public enum CloudSetup {
    public static func snippet(_ agent: CloudAgent, context c: CloudSetupContext) -> SetupSnippet {
        let names = c.names
        let app = names.appName
        let variable = names.remoteTokenEnvironmentVariable
        let unsupported = SetupSnippet(kind: .values, text: "", steps: [
            String(localized: "Codex cloud tasks have no documented way to add an MCP server, so they can't reach \(app)."),
        ])
        if !agent.isSupported { return unsupported }
        guard let url = c.mcpURL, let host = c.host, let oauth = c.oauthBase else {
            return SetupSnippet(kind: .values, text: "", steps: [
                String(localized: "Finish setting up Remote Access in \(app) first. This setup appears once the tunnel's public address is saved."),
            ])
        }
        let placeholder = c.remoteTokenPlaceholder
        let curl = SetupCurl(variable: variable)
        let copyToken = String(localized: "Paste the remote token from \(names.copyTokenAction) on the Cloud section of “\(c.agentName)” in \(app).")
        let exportToken = { (apiKey: String) in
            String(localized: "In Terminal, set \(variable) to the remote token (\(names.copyTokenAction) on the agent's Cloud section) and \(apiKey) to your API key, then run the command.")
        }
        let pairing = String(localized: "When it asks you to sign in, open “\(c.agentName)” in \(app), choose Connect a Cloud App… on its Cloud section, and approve the code you see in both places.")
        let question = "What do my memories say about how I like to work?"

        switch agent {
        case .claudeAI:
            return SetupSnippet(kind: .values, text: url, steps: [
                String(localized: "In Claude, open Customize ▸ Connectors and click Add custom connector. On Team and Enterprise plans, an Owner adds it in Organization settings ▸ Connectors."),
                String(localized: "Paste this URL, leave the OAuth settings as they are, and click Add."),
                pairing,
            ])

        case .chatGPT:
            return SetupSnippet(kind: .values, text: url, steps: [
                String(localized: "In ChatGPT, open Plugins, click +, then Create custom MCP server."),
                String(localized: "Give it a name, paste this URL under Connection, and choose OAuth."),
                pairing,
            ])

        case .geminiEnterprise:
            let fromSheet = { (value: String) in String(localized: "<\(value) from Set Up OAuth Client…>") }
            let settings = SetupValues.lines([
                (String(localized: "Authorization URL"), oauth + "/authorize"),
                (String(localized: "Token URL"), oauth + "/token"),
                (String(localized: "Client ID"), fromSheet(String(localized: "Client ID"))),
                (String(localized: "Client secret"), fromSheet(String(localized: "Client secret"))),
                (String(localized: "Scopes"), c.scope),
            ])
            return SetupSnippet(
                kind: .values, text: url,
                steps: [
                    String(localized: "In the Google Cloud console, open Gemini Enterprise ▸ Data stores ▸ Create data store and choose Custom MCP Server."),
                    String(localized: "Paste this URL as the MCP server URL and choose OAuth 2.0. Turn on Enable PKCE Support."),
                    String(localized: "In \(app), click Set Up OAuth Client… on the Cloud section of “\(c.agentName)”. Enter the OAuth settings below, copying the Client ID and Client secret from that sheet."),
                    pairing,
                ],
                extraSnippets: [(String(localized: "OAuth settings"), .values, settings)])

        case .anthropicAPI:
            let body = SetupJSON.object([
                ("model", .string("claude-opus-5-5")), ("max_tokens", .number(1024)),
                ("messages", .array([.object([("role", .string("user")), ("content", .string(question))])])),
                ("mcp_servers", .array([.object([
                    ("type", .string("url")), ("url", .string(url)), ("name", .string(c.serverKey)),
                    ("authorization_token", .string(SetupCurl.tokenSentinel)),
                ])])),
                ("tools", .array([.object([("type", .string("mcp_toolset")), ("mcp_server_name", .string(c.serverKey))])])),
            ])
            return SetupSnippet(
                kind: .shellCommand,
                text: curl.post("https://api.anthropic.com/v1/messages", headers: [
                    "content-type: application/json", "x-api-key: $ANTHROPIC_API_KEY",
                    "anthropic-version: 2023-06-01", "anthropic-beta: mcp-client-2025-11-20",
                ], body: body),
                steps: [
                    exportToken("ANTHROPIC_API_KEY"),
                    String(localized: "In your own code, send the same mcp_servers entry with each request and keep the anthropic-beta header."),
                ],
                needsLiteralSecret: true)

        case .managedAgents:
            let body = SetupJSON.object([
                ("display_name", .string("\(app) (\(c.agentName))")),
                ("auth", .object([
                    ("type", .string("static_bearer")), ("mcp_server_url", .string(url)),
                    ("token", .string(SetupCurl.tokenSentinel)),
                ])),
            ])
            let agentJSON = SetupJSON.object([
                ("mcp_servers", .array([.object([("type", .string("url")), ("name", .string(c.serverKey)), ("url", .string(url))])])),
                ("tools", .array([.object([("type", .string("mcp_toolset")), ("mcp_server_name", .string(c.serverKey))])])),
            ]).text
            return SetupSnippet(
                kind: .shellCommand,
                text: curl.post("https://api.anthropic.com/v1/vaults/$VAULT_ID/credentials", headers: [
                    "content-type: application/json", "x-api-key: $ANTHROPIC_API_KEY",
                    "anthropic-version: 2023-06-01", "anthropic-beta: managed-agents-2026-04-01",
                ], body: body),
                steps: [
                    String(localized: "Create an Anthropic vault, or pick an existing one, and set VAULT_ID to its ID."),
                    exportToken("ANTHROPIC_API_KEY"),
                    String(localized: "Add the mcp_servers and tools entries below to your agent."),
                    String(localized: "Pass the vault in vault_ids when you create a session."),
                ],
                needsLiteralSecret: true,
                extraSnippets: [(String(localized: "In your agent"), .json, agentJSON)])

        case .openAIResponses:
            let body = SetupJSON.object([
                ("model", .string("gpt-6-astra")), ("input", .string(question)),
                ("tools", .array([.object([
                    ("type", .string("mcp")), ("server_label", .string(c.serverKey)),
                    ("server_url", .string(url)), ("authorization", .string(SetupCurl.tokenSentinel)),
                    ("allowed_tools", .strings(c.readOnlyTools)), ("require_approval", .string("never")),
                ])])),
            ])
            return SetupSnippet(
                kind: .shellCommand,
                text: curl.post("https://api.openai.com/v1/responses", headers: [
                    "content-type: application/json", "authorization: Bearer $OPENAI_API_KEY",
                ], body: body),
                steps: [
                    exportToken("OPENAI_API_KEY"),
                    String(localized: "This example allows only the read tools, without approval in the API. To let it suggest memories too, remove allowed_tools and handle approval requests in your code."),
                ],
                needsLiteralSecret: true)

        case .claudeCodeCloud:
            func mcpJSON(_ headers: Bool) -> String {
                var entry: [(String, SetupJSON)] = [("type", .string("http")), ("url", .string(url))]
                if headers {
                    entry.append(("headers", .object([("Authorization", .string("Bearer ${\(variable)}"))])))
                }
                return SetupJSON.object([("mcpServers", .object([(c.serverKey, .object(entry))]))]).text
            }
            return SetupSnippet(
                kind: .json, text: mcpJSON(true),
                steps: [
                    String(localized: "Add this to .mcp.json at the root of the repository and commit it. It holds no token."),
                    String(localized: "At claude.ai/code, edit the cloud environment and add \(variable)=\(placeholder) under Environment variables. \(names.copyTokenAction) is on the agent's Cloud section in \(app)."),
                    String(localized: "Set Network access to Custom and add \(host) under Allowed domains."),
                    String(localized: "On Pro and Max plans, you can add an API credential for \(host) instead (Bearer, with the remote token as the value) and commit the version without headers."),
                ],
                needsLiteralSecret: true,
                extraSnippets: [(String(localized: "With an API credential"), .json, mcpJSON(false))])

        case .cursorCloud:
            return SetupSnippet(
                kind: .values,
                text: SetupValues.lines([
                    (String(localized: "Name"), c.serverKey), (String(localized: "Type"), "HTTP"),
                    (String(localized: "URL"), url), (String(localized: "Header"), "Authorization: Bearer \(placeholder)"),
                ]),
                steps: [
                    String(localized: "At cursor.com/agents, open the MCP menu and add a server."),
                    String(localized: "Choose HTTP and enter these values."), copyToken,
                ],
                needsLiteralSecret: true)

        case .copilotAgent:
            let json = SetupJSON.object([("mcpServers", .object([(c.serverKey, .object([
                ("type", .string("http")), ("url", .string(url)),
                ("headers", .object([("Authorization", .string("Bearer $\(c.copilotSecretName)"))])),
                ("tools", .strings(c.readOnlyTools)),
            ]))]))]).text
            return SetupSnippet(
                kind: .json, text: json,
                steps: [
                    String(localized: "In the repository on GitHub, open Settings ▸ Copilot ▸ MCP servers and paste this under MCP configuration."),
                    String(localized: "Add an Agents secret named \(c.copilotSecretName) and paste the remote token (\(names.copyTokenAction) on the agent's Cloud section) as its value."),
                    String(localized: "The tools list holds only the read tools. Add suggest_memory only if this agent may suggest memories."),
                ],
                needsLiteralSecret: true)

        case .devin:
            return SetupSnippet(
                kind: .values,
                text: SetupValues.lines([
                    (String(localized: "Server name"), c.serverKey), (String(localized: "Transport"), "HTTP"),
                    (String(localized: "Server URL"), url), (String(localized: "Authentication"), "Auth Header"),
                    (String(localized: "Header key"), "Authorization"), (String(localized: "Header value"), "Bearer \(placeholder)"),
                ]),
                steps: [
                    String(localized: "In Devin, open Customize ▸ MCPs, choose Add MCP, then Add custom MCP."),
                    String(localized: "Enter these values."), copyToken, String(localized: "Click Test tools."),
                ],
                needsLiteralSecret: true)

        case .codexCloud:
            return unsupported
        }
    }
}

/// `curl` POSTs whose JSON body splices in the remote token from the environment, so the snippet
/// never holds it.
struct SetupCurl {
    static let tokenSentinel = "@@REMOTE_TOKEN@@"
    let variable: String

    func post(_ url: String, headers: [String], body: SetupJSON) -> String {
        let quoted = SetupShell.singleQuoted(body.text)
            .replacingOccurrences(of: "\"\(Self.tokenSentinel)\"", with: "\"'\"$\(variable)\"'\"")
        let lines = ["curl \"\(url)\""] + headers.map { "  -H \"\($0)\"" } + ["  -d \(quoted)"]
        return lines.joined(separator: " \\\n")
    }
}

enum SetupValues {
    static func lines(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }
}
