import BridgeKitCore
import Foundation
import Testing
@testable import BridgeUI

/// Agent setup (FR-A-07, FR-A-08), ported from EK Bridge's AgentSetupTests: every agent × method
/// byte for byte against fixtures/agent-setup (UPDATE_GOLDENS=1 rewrites them), no key in any
/// snippet, valid JSON and TOML, and shell commands that parse back to the intended arguments.
@Suite("Agent setup")
struct AgentSetupTests {
    static let agentID = "3f1c2b7e-8a41-4d0c-9a8e-5b6f1d2e9a1c"
    static let url = "http://127.0.0.1:47625/mcp"
    static let names = SetupNames(appName: "Funes Vault", agentOption: "agent", secretNoun: "key",
                                  copySecretAction: "Copy Key…", environmentVariable: "FUNES_MCP_KEY")
    static let keyPath = "/Users/you/Library/Application Support/FunesVault/agent-keys/\(agentID).key"
    static let context = SetupContext(serverKey: "funes", url: url,
                                      launcherPath: "/Applications/FunesVault.app/Contents/MacOS/funes-mcp",
                                      agentID: agentID, keyPath: keyPath, names: names)
    static let apostrophe = SetupContext(serverKey: "funes", url: url,
                                         launcherPath: "/Users/o'brien/Apps/Funes Vault.app/Contents/MacOS/funes-mcp",
                                         agentID: agentID, keyPath: keyPath, names: names)

    static func all(_ context: SetupContext) -> [(SetupAgent, SetupMethod, SetupSnippet)] {
        SetupAgent.allCases.flatMap { agent in agent.methods.map { (agent, $0, agent.snippet($0, context)) } }
    }

    static func slug(_ agent: SetupAgent) -> String {
        switch agent {
        case .jetBrains: "jetbrains"
        case .geminiCLI: "gemini-cli"
        case .vsCode: "vs-code"
        default: agent.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased()
        }
    }

    static func slug(_ method: SetupMethod) -> String { method == .launcher ? "launcher" : "direct-http" }

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/agent-setup")
    }

    @Test func goldens() throws {
        var expected: [String: String] = [:]
        for (agent, method, snippet) in Self.all(Self.context) {
            let base = "\(Self.slug(agent)).\(Self.slug(method))"
            expected["\(base).txt"] = snippet.text
            for (index, extra) in snippet.extraSnippets.enumerated() { expected["\(base).extra\(index + 1).txt"] = extra.text }
            if let link = snippet.installURL { expected["\(base).install-url.txt"] = link.absoluteString }
        }
        for (agent, method, snippet) in Self.all(Self.apostrophe) where agent == .claudeCode {
            expected["\(Self.slug(agent)).\(Self.slug(method)).apostrophe.txt"] = snippet.text
        }
        let folder = Self.fixtures
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for old in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(old))
            }
            for (name, text) in expected { try (text + "\n").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        }
        let present = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(present == Set(expected.keys), "goldens: run with UPDATE_GOLDENS=1 after an intended change")
        for (name, text) in expected {
            let golden = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            #expect(golden == text + "\n", "\(name) differs from its golden")
        }
    }

    @Test func noKeyAndTheLauncherOption() {
        for (agent, method, snippet) in Self.all(Self.context) {
            let texts = [snippet.text] + snippet.extraSnippets.map(\.text)
            for text in texts {
                #expect(!text.contains("fns_mcp_v1_"), "\(agent) \(method)")
                #expect(!text.contains("--client"), "\(agent) \(method) uses EK Bridge's option")
            }
            if method == .launcher, agent != .other {
                #expect(texts.contains { $0.contains("--agent") && $0.contains(Self.agentID) }, "\(agent)")
            }
        }
    }

    @Test func jsonAndTOMLParse() throws {
        for (agent, method, snippet) in Self.all(Self.context) {
            for (kind, text) in [(snippet.kind, snippet.text)] + snippet.extraSnippets.map({ ($0.kind, $0.text) }) {
                switch kind {
                case .json:
                    #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any], "\(agent) \(method)")
                case .toml:
                    #expect(text.hasPrefix("[mcp_servers.funes]"), "\(agent) \(method)")
                    let after = try AgentConfigWriter.appendTOML(current: nil, key: "funes", table: text)
                    #expect(after.outcome == .created)
                default: break
                }
            }
        }
    }

    @Test func oneClickSetupsMatchTheirSnippets() throws {
        for agent in SetupAgent.allCases {
            let setup = agent.oneClickSetup(Self.context)
            #expect((setup != nil) == agent.oneClick, "\(agent)")
        }
        guard case .claudeCode(let key, let arguments) = SetupAgent.claudeCode.oneClickSetup(Self.context) else {
            Issue.record("Claude Code")
            return
        }
        #expect(key == "funes" && arguments.prefix(5) == ["mcp", "add-json", "--scope", "user", "funes"])
        let json = try #require(JSONSerialization.jsonObject(with: Data(arguments[5].utf8)) as? [String: String])
        #expect(json["url"] == Self.url && json["type"] == "http")
        #expect(json["headersHelper"] == "\"/Applications/FunesVault.app/Contents/MacOS/funes-mcp\" headers --agent \(Self.agentID) --url \(Self.url)")
        guard case .codex(_, let codexArgs, let file, let table) = SetupAgent.codex.oneClickSetup(Self.context) else {
            Issue.record("Codex")
            return
        }
        #expect(codexArgs == ["mcp", "add", "funes", "--", Self.context.launcherPath, "--agent", Self.agentID])
        #expect(file == "~/.codex/config.toml" && table.contains("--agent"))
    }

    @Test func installLink() throws {
        let snippet = SetupAgent.vsCode.snippet(.launcher, Self.context)
        let link = try #require(snippet.installURL)
        #expect(link.scheme == "vscode")
        let query = try #require(link.absoluteString.split(separator: "?", maxSplits: 1).last.map(String.init)?.removingPercentEncoding)
        #expect((try? JSONSerialization.jsonObject(with: Data(query.utf8))) is [String: Any])
    }

    /// The Claude Code commands, run through a real shell, give exactly the intended arguments.
    @Test func shellRoundTrip() throws {
        for context in [Self.context, Self.apostrophe] {
            for method in SetupAgent.claudeCode.methods {
                let command = SetupAgent.claudeCode.snippet(method, context).text
                let printed = try Self.shellWords(command.replacingOccurrences(of: "claude mcp", with: "printf '%s\\n' mcp"))
                let expected = method == .launcher
                    ? ["mcp", "add", "--scope", "user", "funes", "--", context.launcherPath, "--agent", Self.agentID]
                    : nil
                if let expected { #expect(printed == expected) }
                #expect(printed.contains("funes"))
            }
        }
    }

    static func shellWords(_ command: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
}

/// Detection (FR-A-01) with a fake probe.
@Suite("Agent detection")
struct AgentDetectionTests {
    @Test func signals() {
        let probe = AgentProbe(appURL: { $0 == "com.anthropic.claudefordesktop" ? URL(fileURLWithPath: "/Applications/Claude.app") : nil },
                               fileExists: { $0 == "/Users/someone/.cursor" || $0 == "/Users/someone/.codex" },
                               home: "/Users/someone",
                               executable: { $0 == "claude" ? "/opt/homebrew/bin/claude" : nil })
        #expect(AgentDetection.installed(probe) == [.claudeDesktop, .cursor, .codex, .claudeCode])
        let nothing = AgentProbe(appURL: { _ in nil }, fileExists: { _ in false }, home: "/Users/someone")
        #expect(AgentDetection.installed(nothing).isEmpty)
        #expect(AgentDetection.signals(.other) == nil && AgentDetection.signals(.cline) == nil)
    }
}

/// One-click setup (FR-A-07) in a scratch HOME: previews, backups, the change on disk, and the
/// agents' own commands run with HOME set to the scratch folder. Never touches real configs.
@Suite("One-click setup")
struct OneClickSetupTests {
    func scratch() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oneclick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func claudeDesktopFileIsMergedWithABackup() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = home + "/Library/Application Support/Claude"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let original = "{\n  \"mcpServers\": {\n    \"other\": { \"command\": \"x\" }\n  },\n  \"theme\": \"dark\"\n}\n"
        try original.write(toFile: folder + "/claude_desktop_config.json", atomically: true, encoding: .utf8)
        let setup = try #require(SetupAgent.claudeDesktop.oneClickSetup(AgentSetupTests.context))
        let preview = try OneClickAgents.preview(.claudeDesktop, setup, home: home, appName: "Funes Vault",
                                                 locator: ExecutableLocator(isExecutable: { _ in false }, loginShellLookup: { _ in nil })).get()
        guard case .file(_, let change) = preview else {
            Issue.record("expected a file change")
            return
        }
        #expect(change.outcome == .added && change.diffLines.contains { $0.kind == .added && $0.text.contains("funes") })
        let result = try OneClickAgents.apply(preview, home: home, appName: "Funes Vault", tag: "funes").get()
        let backup = try #require(result.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(backup.lastPathComponent.hasPrefix("claude_desktop_config.json.funes-backup-"))
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: folder + "/claude_desktop_config.json"))) as? [String: Any])
        let servers = try #require(written["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil && written["theme"] as? String == "dark")
        let funes = try #require(servers["funes"] as? [String: Any])
        #expect(funes["args"] as? [String] == ["--agent", AgentSetupTests.agentID])
        // Again: already set up, nothing written.
        let again = try OneClickAgents.preview(.claudeDesktop, setup, home: home, appName: "Funes Vault",
                                               locator: ExecutableLocator(isExecutable: { _ in false }, loginShellLookup: { _ in nil })).get()
        #expect(try OneClickAgents.apply(again, home: home, appName: "Funes Vault", tag: "funes").get().alreadySetUp)
    }

    @Test func invalidConfigIsLeftAlone() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.cursor", withIntermediateDirectories: true)
        try "{ not json".write(toFile: home + "/.cursor/mcp.json", atomically: true, encoding: .utf8)
        let setup = try #require(SetupAgent.cursor.oneClickSetup(AgentSetupTests.context))
        let result = OneClickAgents.preview(.cursor, setup, home: home, appName: "Funes Vault",
                                            locator: ExecutableLocator(isExecutable: { _ in false }, loginShellLookup: { _ in nil }))
        guard case .failure(let failure) = result else {
            Issue.record("expected a refusal")
            return
        }
        #expect(failure.message.contains("Funes Vault won't change it") && failure.copyInstead)
        #expect(try String(contentsOfFile: home + "/.cursor/mcp.json", encoding: .utf8) == "{ not json")
    }

    @Test func codexWithoutItsCommandAppendsToItsConfig() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let setup = try #require(SetupAgent.codex.oneClickSetup(AgentSetupTests.context))
        let preview = try OneClickAgents.preview(.codex, setup, home: home, appName: "Funes Vault",
                                                 locator: ExecutableLocator(isExecutable: { _ in false }, loginShellLookup: { _ in nil })).get()
        _ = try OneClickAgents.apply(preview, home: home, appName: "Funes Vault", tag: "funes").get()
        let toml = try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)
        #expect(toml.contains("[mcp_servers.funes]") && toml.contains("--agent"))
    }

    /// A fake `claude` that records its HOME and arguments: the command runs in the scratch HOME.
    @Test func claudeCodeCommandRunsInTheGivenHome() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tool = home + "/bin/claude"
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        try """
            #!/bin/sh
            if [ "$2" = "get" ]; then exit 1; fi
            printf '%s\\n' "$HOME" > "$HOME/claude-ran"
            printf '%s\\n' "$@" >> "$HOME/claude-ran"
            echo "Added stdio MCP server funes"
            """.write(toFile: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        let locator = ExecutableLocator(isExecutable: { $0 == tool }, loginShellLookup: { _ in tool })
        let setup = try #require(SetupAgent.claudeCode.oneClickSetup(AgentSetupTests.context))
        let preview = try OneClickAgents.preview(.claudeCode, setup, home: home, appName: "Funes Vault", locator: locator).get()
        guard case .command(_, _, _, _, let replacing) = preview else {
            Issue.record("expected a command")
            return
        }
        #expect(!replacing)
        let result = try OneClickAgents.apply(preview, home: home, appName: "Funes Vault", tag: "funes").get()
        #expect(result.output?.contains("Added") == true)
        let ran = try String(contentsOfFile: home + "/claude-ran", encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(ran.first == home && Array(ran.dropFirst().prefix(5)) == ["mcp", "add-json", "--scope", "user", "funes"])
    }
}
