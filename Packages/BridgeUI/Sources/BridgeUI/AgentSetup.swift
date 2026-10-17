import BridgeKitCore
import Foundation

// Adapted from EK Bridge's AgentSetup (Upstream/AgentSetup.swift): copy-paste setup for each agent
// on this Mac, and what one-click setup writes. The app's names (its display name, the launcher's
// agent option, "key" or "token") come from `SetupNames`; EK Bridge's cloud agents and tunnels
// (tier 3) are left out. Pure, so every snippet is golden-tested. No snippet ever holds a key.

/// An agent the setup knows (EK Bridge's `AgentKind`, renamed so it doesn't clash with the app's).
public enum SetupAgent: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, claudeDesktop, codex, cursor, vsCode, geminiCLI, devinDesktop, zed, cline, jetBrains, other

    public var id: String { rawValue }
}

public enum SetupMethod: String, CaseIterable, Sendable {
    case launcher, directHTTP
}

/// The app's words and names in snippets.
public struct SetupNames: Sendable, Equatable {
    /// "Funes Vault".
    public var appName: String
    /// The launcher's option naming the agent: `--agent` for Funes, `--client` for EK Bridge.
    public var agentOption: String
    /// "key" or "token", as in "Copy Key…".
    public var secretNoun: String
    /// The button that copies it: "Copy Key…".
    public var copySecretAction: String
    /// The environment variable direct-HTTP setups read it from: `FUNES_MCP_KEY`.
    public var environmentVariable: String

    public init(appName: String, agentOption: String, secretNoun: String, copySecretAction: String,
                environmentVariable: String) {
        self.appName = appName
        self.agentOption = agentOption
        self.secretNoun = secretNoun
        self.copySecretAction = copySecretAction
        self.environmentVariable = environmentVariable
    }
}

public struct SetupContext: Sendable, Equatable {
    public let serverKey: String
    public let url: String
    public let launcherPath: String
    public let agentID: String
    /// The key file, for setups that read it directly (Devin Desktop's `${file:}`).
    public let keyPath: String
    public let names: SetupNames

    public init(serverKey: String, url: String, launcherPath: String, agentID: String, keyPath: String, names: SetupNames) {
        self.serverKey = serverKey
        self.url = url
        self.launcherPath = launcherPath
        self.agentID = agentID
        self.keyPath = keyPath
        self.names = names
    }

    /// `["--agent", "<id>"]`.
    var launcherArguments: [String] { ["--" + names.agentOption, agentID] }
}

public struct SetupSnippet: Sendable {
    public enum Kind: Sendable { case shellCommand, json, toml, values }

    public let kind: Kind
    public let text: String
    /// The config file this ends up in, in tilde form for display.
    public var destination: String? = nil
    /// Set only when the user edits `destination` by hand, for Show in Finder.
    public var destinationFolder: String? = nil
    public var steps: [String] = []
    public var installURL: URL? = nil
    /// The UI offers Copy Key… only for these methods.
    public var needsLiteralSecret = false
    /// The agent sends the key without the launcher's listener check.
    public var skipsListenerCheck = false
    public var extraSnippets: [(title: String, kind: Kind, text: String)] = []
}

/// What Add to <Agent>… does: merge an entry into a JSON config file, or run the agent's own
/// command. Never contains a key: entries start the launcher, which reads the key file.
public enum OneClickSetup: Equatable, Sendable {
    /// `file` in tilde form; the entry goes under `root` ▸ `key`.
    case jsonMerge(file: String, root: String, key: String, entry: SetupJSON)
    /// `claude` with these arguments (an argument array, never a shell string).
    case claudeCode(key: String, arguments: [String])
    /// Codex: its own `codex mcp add` when the command is found, otherwise `table` appended to its
    /// config.toml (`file`, in tilde form).
    case codex(key: String, arguments: [String], file: String, table: String)
}

extension SetupAgent {
    /// Agents with one-click setup (FR-A-07): Claude Desktop, Claude Code, Cursor and Codex.
    public var oneClick: Bool { [.claudeDesktop, .cursor, .claudeCode, .codex].contains(self) }

    /// The one-click setup for the recommended method, matching its snippet.
    public func oneClickSetup(_ c: SetupContext) -> OneClickSetup? {
        let stdio: [(String, SetupJSON)] = [("command", .string(c.launcherPath)), ("args", .strings(c.launcherArguments))]
        switch self {
        case .claudeDesktop:
            return .jsonMerge(file: "~/Library/Application Support/Claude/claude_desktop_config.json",
                              root: "mcpServers", key: c.serverKey, entry: .object(stdio))
        case .cursor:
            return .jsonMerge(file: "~/.cursor/mcp.json", root: "mcpServers", key: c.serverKey,
                              entry: .object([("type", .string("stdio"))] + stdio))
        case .claudeCode:
            let helper = "\(SetupShell.quoted(c.launcherPath)) headers --\(c.names.agentOption) "
                + "\(SetupShell.word(c.agentID)) --url \(SetupShell.word(c.url))"
            let json = SetupJSON.object([
                ("type", .string("http")), ("url", .string(c.url)), ("headersHelper", .string(helper)),
            ]).text
            return .claudeCode(key: c.serverKey, arguments: ["mcp", "add-json", "--scope", "user", c.serverKey, json])
        case .codex:
            return .codex(key: c.serverKey, arguments: ["mcp", "add", c.serverKey, "--", c.launcherPath] + c.launcherArguments,
                          file: "~/.codex/config.toml", table: SetupTOML.table(c.serverKey, stdio))
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .claudeCode: String(localized: "Claude Code")
        case .claudeDesktop: String(localized: "Claude Desktop")
        case .codex: String(localized: "Codex")
        case .cursor: String(localized: "Cursor")
        case .vsCode: String(localized: "VS Code (Copilot)")
        case .geminiCLI: String(localized: "Gemini CLI")
        case .devinDesktop: String(localized: "Devin Desktop")
        case .zed: String(localized: "Zed")
        case .cline: String(localized: "Cline")
        case .jetBrains: String(localized: "JetBrains AI Assistant")
        case .other: String(localized: "Other MCP client")
        }
    }

    /// Recommended first.
    public var methods: [SetupMethod] {
        switch self {
        case .claudeCode, .other: [.directHTTP, .launcher]
        case .codex, .cursor, .vsCode, .geminiCLI, .devinDesktop: [.launcher, .directHTTP]
        case .claudeDesktop, .zed, .cline, .jetBrains: [.launcher]
        }
    }

    public var recommended: SetupMethod { methods[0] }

    public func footnote(_ names: SetupNames) -> String? {
        switch self {
        case .claudeDesktop:
            String(localized: "Claude Desktop's custom connectors run from Anthropic's cloud and can't reach this Mac, so use this local setup instead.")
        case .codex:
            String(localized: "Codex started from an app doesn't see your shell's environment variables, so the launcher is more reliable than direct HTTP.")
        case .cursor:
            String(localized: "Use your own ~/.cursor/mcp.json, never a project's .cursor/mcp.json, which often gets committed.")
        case .vsCode:
            String(localized: "Servers that prompt for input aren't sent to VS Code's Agent Host, so the launcher works in more places.")
        case .zed:
            String(localized: "Zed starts a sign-in when a remote server has no Authorization header, so only the launcher is offered.")
        case .cline:
            String(localized: "Cline treats a remote server without a type as legacy SSE, so only the launcher is offered.")
        case .jetBrains:
            String(localized: "AI Assistant has known problems with local HTTP servers, so only the launcher is offered.")
        case .claudeCode, .geminiCLI, .devinDesktop, .other:
            nil
        }
    }

    public func snippet(_ method: SetupMethod, _ c: SetupContext) -> SetupSnippet {
        let method = methods.contains(method) ? method : recommended
        let path = SetupShell.quoted(c.launcherPath)
        let key = SetupShell.word(c.serverKey)
        let option = "--\(c.names.agentOption)"
        let id = SetupShell.word(c.agentID)
        let stdio: [(String, SetupJSON)] = [("command", .string(c.launcherPath)), ("args", .strings(c.launcherArguments))]
        func servers(_ entry: [(String, SetupJSON)], under root: String = "mcpServers") -> String {
            SetupJSON.object([(root, .object([(c.serverKey, .object(entry))]))]).text
        }
        let variable = c.names.environmentVariable
        let bearerEnv = "Bearer ${env:\(variable)}"
        let open = { (file: String) in String(localized: "Open \(file).") }
        let addEntry = String(localized: "Add the \(c.serverKey) entry under mcpServers.")
        let setEnv = { (agent: String) in
            String(localized: "Set \(variable) to the \(c.names.secretNoun) (\(c.names.copySecretAction)) in the environment \(agent) starts from.")
        }
        let claudeCodeStep = String(localized: "Run it in Terminal. Claude Code connects the next time it starts (or run /mcp to reconnect).")

        switch (self, method) {
        case (.claudeCode, .directHTTP):
            let helper = "\(path) headers \(option) \(id) --url \(SetupShell.word(c.url))"
            let json = SetupJSON.object([
                ("type", .string("http")), ("url", .string(c.url)), ("headersHelper", .string(helper)),
            ]).text
            return SetupSnippet(kind: .shellCommand,
                                text: "claude mcp add-json --scope user \(key) \(SetupShell.singleQuoted(json))",
                                destination: "~/.claude.json", steps: [claudeCodeStep])
        case (.claudeCode, _):
            return SetupSnippet(kind: .shellCommand, text: "claude mcp add --scope user \(key) -- \(path) \(option) \(id)",
                                destination: "~/.claude.json", steps: [claudeCodeStep])

        case (.claudeDesktop, _):
            let file = "~/Library/Application Support/Claude/claude_desktop_config.json"
            return SetupSnippet(kind: .json, text: servers(stdio), destination: file,
                                destinationFolder: "~/Library/Application Support/Claude",
                                steps: [open(file), addEntry, String(localized: "Restart Claude Desktop.")])

        case (.codex, .launcher):
            let toml = SetupTOML.table(c.serverKey, stdio)
            return SetupSnippet(
                kind: .shellCommand, text: "codex mcp add \(key) -- \(path) \(option) \(id)",
                destination: "~/.codex/config.toml", destinationFolder: "~/.codex",
                steps: [String(localized: "Run it in Terminal, or add the lines below to ~/.codex/config.toml."),
                        String(localized: "Codex connects the next time it starts.")],
                extraSnippets: [(String(localized: "Or in ~/.codex/config.toml"), .toml, toml)])
        case (.codex, _):
            let toml = SetupTOML.table(c.serverKey, [("url", .string(c.url)), ("bearer_token_env_var", .string(variable))])
            return SetupSnippet(kind: .toml, text: toml, destination: "~/.codex/config.toml", destinationFolder: "~/.codex",
                                steps: [String(localized: "Add this to ~/.codex/config.toml."), setEnv("Codex"),
                                        String(localized: "Restart Codex.")],
                                needsLiteralSecret: true, skipsListenerCheck: true)

        case (.cursor, .launcher):
            return SetupSnippet(kind: .json, text: servers([("type", .string("stdio"))] + stdio),
                                destination: "~/.cursor/mcp.json", destinationFolder: "~/.cursor",
                                steps: [open("~/.cursor/mcp.json"), addEntry, String(localized: "Restart Cursor.")])
        case (.cursor, _):
            let headers = SetupJSON.object([("Authorization", .string(bearerEnv))])
            return SetupSnippet(kind: .json, text: servers([("url", .string(c.url)), ("headers", headers)]),
                                destination: "~/.cursor/mcp.json", destinationFolder: "~/.cursor",
                                steps: [open("~/.cursor/mcp.json"), addEntry, setEnv("Cursor"), String(localized: "Restart Cursor.")],
                                needsLiteralSecret: true, skipsListenerCheck: true)

        case (.vsCode, .launcher):
            let json = SetupJSON.object([("name", .string(c.serverKey))] + stdio).text
            return SetupSnippet(kind: .shellCommand, text: "code --add-mcp \(SetupShell.singleQuoted(json))",
                                steps: [String(localized: "Click Install in VS Code, or run the command in Terminal."),
                                        String(localized: "Start \(c.serverKey) when VS Code asks.")],
                                installURL: URL(string: "vscode:mcp/install?" + SetupShell.percentEncoded(json)))
        case (.vsCode, _):
            let inputID = "\(c.serverKey)-key"
            let json = SetupJSON.object([
                ("inputs", .array([.object([
                    ("type", .string("promptString")), ("id", .string(inputID)),
                    ("description", .string("\(c.names.appName) MCP \(c.names.secretNoun)")), ("password", .bool(true)),
                ])])),
                ("servers", .object([(c.serverKey, .object([
                    ("type", .string("http")), ("url", .string(c.url)),
                    ("headers", .object([("Authorization", .string("Bearer ${input:\(inputID)}"))])),
                ]))])),
            ]).text
            return SetupSnippet(kind: .json, text: json, destination: "~/Library/Application Support/Code/User/mcp.json",
                                destinationFolder: "~/Library/Application Support/Code/User",
                                steps: [String(localized: "In VS Code, run MCP: Open User Configuration."),
                                        String(localized: "Add the inputs and servers entries."),
                                        String(localized: "When VS Code asks for the \(c.names.secretNoun), paste it from \(c.names.copySecretAction).")],
                                needsLiteralSecret: true, skipsListenerCheck: true)

        case (.geminiCLI, .launcher):
            return SetupSnippet(kind: .json, text: servers(stdio + [("timeout", .number(60000))]),
                                destination: "~/.gemini/settings.json", destinationFolder: "~/.gemini",
                                steps: [open("~/.gemini/settings.json"), addEntry, String(localized: "Restart Gemini CLI.")])
        case (.geminiCLI, _):
            let headers = SetupJSON.object([("Authorization", .string("Bearer $\(variable)"))])
            return SetupSnippet(kind: .json,
                                text: servers([("httpUrl", .string(c.url)), ("headers", headers), ("timeout", .number(60000))]),
                                destination: "~/.gemini/settings.json", destinationFolder: "~/.gemini",
                                steps: [open("~/.gemini/settings.json"), addEntry, setEnv("Gemini CLI"),
                                        String(localized: "Restart Gemini CLI.")],
                                needsLiteralSecret: true, skipsListenerCheck: true)

        case (.devinDesktop, _):
            // `${file:}` works because the key file holds the bare key.
            let entry: [(String, SetupJSON)] = method == .launcher ? stdio : [
                ("serverUrl", .string(c.url)),
                ("headers", .object([("Authorization", .string("Bearer ${file:\(c.keyPath)}"))])),
            ]
            return SetupSnippet(kind: .json, text: servers(entry), destination: "~/.config/devin/mcp_config.json",
                                destinationFolder: "~/.config/devin",
                                steps: [open("~/.config/devin/mcp_config.json"), addEntry, String(localized: "Restart Devin Desktop.")],
                                skipsListenerCheck: method == .directHTTP)

        case (.zed, _):
            return SetupSnippet(kind: .json, text: servers(stdio + [("env", .object([]))], under: "context_servers"),
                                destination: "~/.config/zed/settings.json", destinationFolder: "~/.config/zed",
                                steps: [String(localized: "In Zed, run zed: open settings."),
                                        String(localized: "Add the \(c.serverKey) entry under context_servers.")])

        case (.cline, _):
            return SetupSnippet(kind: .json, text: servers(stdio + [("disabled", .bool(false)), ("autoApprove", .array([]))]),
                                steps: [String(localized: "In Cline, open MCP Servers and click Configure MCP Servers."), addEntry])

        case (.jetBrains, _):
            return SetupSnippet(kind: .json, text: servers(stdio),
                                steps: [String(localized: "Open Settings ▸ Tools ▸ AI Assistant ▸ Model Context Protocol (MCP)."),
                                        String(localized: "Add a server, choose As JSON, and paste this.")])

        case (.other, _):
            let lines = [
                (String(localized: "Server name"), c.serverKey),
                (String(localized: "Transport"), "Streamable HTTP"),
                (String(localized: "URL"), c.url),
                (String(localized: "Header"), "Authorization: Bearer <\(c.names.secretNoun)>"),
                (String(localized: "Key file"), c.keyPath),
                (String(localized: "stdio command"), c.launcherPath),
                (String(localized: "stdio args"), "\(option) \(c.agentID)"),
            ]
            return SetupSnippet(kind: .values, text: lines.map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
                                steps: [String(localized: "Use the HTTP values if the agent supports Streamable HTTP with a custom header; otherwise run the launcher over stdio."),
                                        String(localized: "For HTTP, paste the \(c.names.secretNoun) from \(c.names.copySecretAction) or read it from the key file.")],
                                needsLiteralSecret: true, skipsListenerCheck: true)
        }
    }
}

/// Shell quoting for snippets.
enum SetupShell {
    static let bareKey = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    private static let safe = bareKey.union(CharacterSet(charactersIn: "./:=@%+,"))

    /// Bare when no shell would read anything special into it.
    static func word(_ text: String) -> String {
        !text.isEmpty && text.unicodeScalars.allSatisfy { safe.contains($0) } ? text : quoted(text)
    }

    /// Double quotes for ordinary text, single quotes when it holds characters a shell would
    /// expand inside double quotes.
    static func quoted(_ text: String) -> String {
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "\"$`\\!")) == nil { return "\"\(text)\"" }
        return singleQuoted(text)
    }

    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func percentEncoded(_ text: String) -> String {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }
}
