import Foundation
import FunesProtocol
import Synchronization
import Testing
@testable import FunesCore

/// Phase 6a.0: the user's Claude or ChatGPT plan through their own Claude Code or Codex
/// (ADR-0024, model providers §5.8): the isolation flags and environment, the stream contracts
/// (success, schema failure, signed out, plan limit, an injected tool call that must be stopped),
/// the status checks and Codex's feature list.
@Suite(.serialized) struct SubscriptionProviderTests {
    /// Replays CLI output per invocation and records what it was asked to run.
    final class FakeCLI: CLIProcessRunning {
        struct Reply: Sendable {
            var lines: [String]
            var exitCode: Int32 = 0
            /// Written to the path after `--output-last-message` (Codex).
            var lastMessage: String?
        }
        let reply: @Sendable (CLIInvocation) -> Reply
        let seen = Mutex<[CLIInvocation]>([])
        let directories = Mutex<[(URL, Bool)]>([])

        init(_ reply: @escaping @Sendable (CLIInvocation) -> Reply) { self.reply = reply }

        var invocations: [CLIInvocation] { seen.withLock { $0 } }

        func run(_ invocation: CLIInvocation, line: @escaping @Sendable (String) -> Bool) async throws -> CLIOutput {
            seen.withLock { $0.append(invocation) }
            let empty = (try? FileManager.default.contentsOfDirectory(atPath: invocation.directory.path))?.isEmpty ?? false
            directories.withLock { $0.append((invocation.directory, empty)) }
            let r = reply(invocation)
            if let message = r.lastMessage, let i = invocation.arguments.firstIndex(of: "--output-last-message") {
                try? Data(message.utf8).write(to: URL(fileURLWithPath: invocation.arguments[i + 1]))
            }
            var lines: [String] = []
            for text in r.lines {
                lines.append(text)
                if !line(text) { return CLIOutput(exitCode: 143, lines: lines, stopped: true) }
            }
            return CLIOutput(exitCode: r.exitCode, lines: lines)
        }
    }

    struct Answer: Decodable, Sendable { let title: String }
    static let request = StructuredRequest<Answer>(instructions: "Propose a title.", prompt: "<note>Prefers green tea.</note>",
                                                   schema: .object(name: "Answer", properties: [("title", .string())]))
    static let environment = ["HOME": "/Users/test", "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-ant-x", "OPENAI_API_KEY": "sk-x",
                              "CODEX_API_KEY": "c", "ANTHROPIC_AUTH_TOKEN": "t"]

    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: Claude Code

    /// As Claude Code 2.1.310 starts with Funes's flags: its built-in plugins and agent types listed.
    static let claudeInit = json(["type": "system", "subtype": "init", "tools": ["StructuredOutput"], "mcp_servers": [],
                                  "plugins": [["name": "cc-plugin-agents-md", "path": "builtin", "source": "cc-plugin-agents-md@builtin"],
                                              ["name": "cc-plugin-plugin-authoring", "path": "builtin",
                                               "source": "cc-plugin-plugin-authoring@builtin"]],
                                  "agents": ["claude", "Explore", "general-purpose", "Plan"], "skills": ["debug"],
                                  "apiKeySource": "none", "model": "claude-haiku-5-5"])
    static func claudeResult(_ output: [String: Any]? = ["title": "Green tea"], error: String? = nil, subtype: String = "success") -> String {
        var event: [String: Any] = ["type": "result", "subtype": subtype, "is_error": error != nil,
                                    "modelUsage": ["claude-haiku-5-5": ["inputTokens": 1_200, "cacheReadInputTokens": 300, "outputTokens": 40]]]
        if let output { event["structured_output"] = output }
        if let error { event["result"] = error }
        return json(event)
    }

    static func claude(_ lines: [String], exitCode: Int32 = 0) -> (ClaudeCodeClient, FakeCLI) {
        let cli = FakeCLI { _ in FakeCLI.Reply(lines: lines, exitCode: exitCode) }
        return (ClaudeCodeClient(executable: "/Users/test/.local/bin/claude", model: "haiku", runner: cli, environment: environment), cli)
    }

    @Test func claudeRunsIsolatedWithoutAPIKeys() async throws {
        CLIRunner.unblock(ClaudeCodeClient.providerID)
        let (client, cli) = Self.claude([Self.claudeInit, Self.claudeResult()])
        let (answer, usage) = try await client.generate(Self.request)
        #expect(answer.title == "Green tea")
        #expect(usage.requests == 1 && usage.inputTokens == 1_500 && usage.outputTokens == 40)
        let run = try #require(cli.invocations.first)
        let args = run.arguments
        for flag in ["-p", "--safe-mode", "--strict-mcp-config", "--no-session-persistence", "--verbose"] { #expect(args.contains(flag)) }
        #expect(!args.contains("--bare"))
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
        #expect(args[args.firstIndex(of: "--disallowedTools")! + 1] == "mcp__*")
        #expect(args[args.firstIndex(of: "--settings")! + 1] == #"{"disableAllHooks": true}"#)
        #expect(args[args.firstIndex(of: "--output-format")! + 1] == "stream-json")
        #expect(args[args.firstIndex(of: "--system-prompt")! + 1] == "Propose a title.")
        #expect(args[args.firstIndex(of: "--json-schema")! + 1] == Self.request.schema.json)
        #expect(run.input == Self.request.prompt)  // the note on stdin, never in the arguments
        #expect(!args.contains { $0.contains("green tea") })
        for key in CLIRunner.strippedVariables { #expect(run.environment[key] == nil) }
        #expect(run.environment["HOME"] == "/Users/test" && run.environment["DISABLE_TELEMETRY"] == "1")
        #expect(run.timeout == .seconds(90))
        // A new empty directory per call, outside the repository, gone afterwards.
        let (dir, empty) = try #require(cli.directories.withLock { $0.first })
        #expect(empty && dir.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func claudeStopsOnAnythingButStructuredOutput() async throws {
        let mcp = Self.json(["type": "system", "subtype": "init", "tools": ["StructuredOutput"],
                             "mcp_servers": [["name": "funes", "status": "connected"]], "apiKeySource": "none"])
        let bash = Self.json(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash",
                                                                            "input": ["command": "cat ~/.ssh/id_rsa"]]]]])
        let tools = Self.json(["type": "system", "subtype": "init", "tools": ["StructuredOutput", "Read"], "apiKeySource": "none"])
        let apiKey = Self.json(["type": "system", "subtype": "init", "tools": ["StructuredOutput"], "apiKeySource": "ANTHROPIC_API_KEY"])
        let hook = Self.json(["type": "system", "subtype": "hook_started", "hook_name": "SessionStart"])
        let installed = Self.json(["type": "system", "subtype": "init", "tools": ["StructuredOutput"], "apiKeySource": "none",
                                   "plugins": [["name": "my-plugin", "path": "/Users/test/.claude/plugins/my-plugin"]]])
        let newBuiltin = Self.json(["type": "system", "subtype": "init", "tools": ["StructuredOutput"], "apiKeySource": "none",
                                    "plugins": [["name": "cc-plugin-new-thing", "path": "builtin"]]])
        let hooks = Self.json(["type": "system", "subtype": "init", "tools": ["StructuredOutput"], "apiKeySource": "none",
                               "hooks": ["SessionStart": ["x"]]])
        for stream in [[mcp, Self.claudeResult()], [Self.claudeInit, bash, Self.claudeResult()], [tools, Self.claudeResult()],
                       [apiKey, Self.claudeResult()], [Self.claudeInit, hook, Self.claudeResult()], [installed, Self.claudeResult()],
                       [newBuiltin, Self.claudeResult()], [hooks, Self.claudeResult()]] {
            CLIRunner.unblock(ClaudeCodeClient.providerID)
            let (client, _) = Self.claude(stream)
            await #expect(throws: ProviderError.unavailable) { try await client.generate(Self.request) }
            // Off until Test connection passes again.
            #expect(CLIRunner.isBlocked(ClaudeCodeClient.providerID))
            #expect(await client.status() == .blocked)
        }
        // The structured-output tool itself is fine, and its input is the answer.
        CLIRunner.unblock(ClaudeCodeClient.providerID)
        let structured = Self.json(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "StructuredOutput",
                                                                                  "input": ["title": "Tea"]]]]])
        let (client, _) = Self.claude([Self.claudeInit, structured, Self.claudeResult(nil)])
        #expect(try await client.generate(Self.request).0.title == "Tea")
    }

    @Test func claudeMapsFailuresToCodes() async throws {
        CLIRunner.unblock(ClaudeCodeClient.providerID)
        let cases: [([String], Int32, ProviderError)] = [
            ([Self.claudeInit, Self.claudeResult(nil, error: "Claude AI usage limit reached|1761300000")], 1, .rateLimited(retryAfter: nil)),
            ([Self.claudeResult(nil, error: "Not logged in · Please run /login")], 1, .unauthorized),
            ([Self.claudeInit, Self.claudeResult(nil, subtype: "error_max_structured_output_retries")], 1, .invalidOutput),
            ([Self.claudeInit, Self.claudeResult(["wrong": 1])], 0, .invalidOutput),
            (["not json", ""], 2, .server(status: 2)),
        ]
        for (lines, code, expected) in cases {
            let (client, _) = Self.claude(lines, exitCode: code)
            await #expect(throws: expected) { try await client.generate(Self.request) }
        }
        #expect(!CLIRunner.isBlocked(ClaudeCodeClient.providerID))
    }

    @Test func claudeStatus() async {
        CLIRunner.unblock(ClaudeCodeClient.providerID)
        let help = ClaudeCodeClient.requiredFlags.joined(separator: "\n")
        func client(version: Int32 = 0, help: String = help, auth: [String: Any] = ["loggedIn": true, "authMethod": "claude.ai",
                                                                                     "email": "someone@example.com"]) -> ClaudeCodeClient {
            let authLine = Self.json(auth)
            let cli = FakeCLI { inv in
                switch inv.arguments.first {
                case "--version": FakeCLI.Reply(lines: ["2.1.310 (Claude Code)"], exitCode: version)
                case "--help": FakeCLI.Reply(lines: help.split(separator: "\n").map(String.init))
                default: FakeCLI.Reply(lines: [authLine])
                }
            }
            return ClaudeCodeClient(executable: "/x/claude", model: "haiku", runner: cli, environment: Self.environment)
        }
        #expect(await client().status() == .ready(version: "2.1.310"))
        #expect(await client(version: 127).status() == .notInstalled)
        #expect(await client(help: "--tools\n--json-schema").status() == .needsUpdate(version: "2.1.310"))
        #expect(await client(auth: ["loggedIn": false]).status() == .notSignedIn(version: "2.1.310"))
        // Signed in with an API key: that isn't the plan.
        #expect(await client(auth: ["loggedIn": true, "authMethod": "api_key"]).status() == .notSignedIn(version: "2.1.310"))
    }

    // MARK: Codex

    static let codexEvents = [
        json(["type": "thread.started", "thread_id": "t"]), json(["type": "turn.started"]),
        json(["type": "item.completed", "item": ["id": "1", "type": "reasoning", "text": "…"]]),
        json(["type": "item.completed", "item": ["id": "2", "type": "agent_message", "text": #"{"title":"Green tea"}"#]]),
        json(["type": "turn.completed", "usage": ["input_tokens": 8_000, "cached_input_tokens": 6_000, "output_tokens": 30]]),
    ]
    static let featuresOK = ["fast_mode stable true", "apps stable false", "shell_tool stable false", "collaboration_modes removed true",
                             "chronicle under development false"]

    static func codex(_ events: [String], features: [String] = featuresOK, exitCode: Int32 = 0, allowsFileReads: Bool = false,
                      lastMessage: String? = #"{"title":"Green tea"}"#) -> (CodexClient, FakeCLI) {
        let cli = FakeCLI { inv in
            switch inv.arguments.first {
            case "--version": FakeCLI.Reply(lines: ["codex-cli 0.164.0"])
            case "features": FakeCLI.Reply(lines: features)
            case "login": FakeCLI.Reply(lines: ["Logged in using ChatGPT"])
            case "exec" where inv.arguments.contains("--help"): FakeCLI.Reply(lines: CodexClient.requiredFlags)
            default: FakeCLI.Reply(lines: events, exitCode: exitCode, lastMessage: lastMessage)
            }
        }
        return (CodexClient(executable: "/x/codex-\(UUID().uuidString.prefix(6))", model: "gpt-6-luna",
                            allowsFileReads: allowsFileReads, runner: cli, environment: environment), cli)
    }

    @Test func codexRunsIsolatedWithEveryToolOff() async throws {
        CLIRunner.unblock(CodexClient.providerID)
        let (client, cli) = Self.codex(Self.codexEvents)
        let (answer, usage) = try await client.generate(Self.request)
        #expect(answer.title == "Green tea" && usage.inputTokens == 8_000 && usage.outputTokens == 30)
        let run = try #require(cli.invocations.last)
        let args = run.arguments
        for flag in ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "--json"] {
            #expect(args.contains(flag))
        }
        #expect(args[args.firstIndex(of: "--sandbox")! + 1] == "read-only")
        #expect(args[args.firstIndex(of: "-C")! + 1] == run.directory.path)
        #expect(args.last == "-" && run.input == Self.request.prompt)
        for feature in ["shell_tool", "unified_exec", "browser_use", "computer_use", "apps", "plugins", "hooks", "image_generation",
                        "view_image", "in_app_browser"] {
            #expect(zip(args, args.dropFirst()).contains { $0 == "--disable" && $1 == feature }, "\(feature)")
        }
        for key in CLIRunner.strippedVariables { #expect(run.environment[key] == nil) }
        // The features were checked first, with the same --disable list.
        let check = try #require(cli.invocations.first { $0.arguments.first == "features" })
        #expect(Array(check.arguments.dropFirst(2)) == client.disableArguments)
    }

    @Test func codexStopsOnAToolOrCommand() async throws {
        for kind in ["command_execution", "file_change", "mcp_tool_call", "web_search", "something_new"] {
            CLIRunner.unblock(CodexClient.providerID)
            let event = Self.json(["type": "item.started", "item": ["id": "9", "type": kind, "command": "ls ~"]])
            let (client, _) = Self.codex([Self.codexEvents[0], event] + Self.codexEvents.dropFirst())
            await #expect(throws: ProviderError.unavailable) { try await client.generate(Self.request) }
            #expect(CLIRunner.isBlocked(CodexClient.providerID), "\(kind)")
        }
        CLIRunner.unblock(CodexClient.providerID)
    }

    @Test func codexRefusesUnknownFeaturesAndMapsFailures() async throws {
        CLIRunner.unblock(CodexClient.providerID)
        // A newer Codex with a feature Funes doesn't know is on: unavailable, nothing run.
        let (newer, cli) = Self.codex(Self.codexEvents, features: Self.featuresOK + ["telepathy stable true"])
        await #expect(throws: ProviderError.unavailable) { try await newer.generate(Self.request) }
        #expect(!cli.invocations.contains { $0.arguments.first == "exec" })
        #expect(await newer.status() == .unsupportedFeatures(version: "0.164.0", features: ["telepathy"]))
        #expect(CodexClient.unknownEnabled(["sqlite removed true", "fast_mode stable true", "goals stable true"]) == ["goals"])

        let limit = Self.json(["type": "turn.failed", "error": ["message": "You've hit your usage limit."]])
        let (limited, _) = Self.codex([limit], exitCode: 1, lastMessage: nil)
        await #expect(throws: ProviderError.rateLimited(retryAfter: nil)) { try await limited.generate(Self.request) }
        let (garbled, _) = Self.codex(Self.codexEvents, lastMessage: "not json")
        await #expect(throws: ProviderError.invalidOutput) { try await garbled.generate(Self.request) }
        let (ready, _) = Self.codex(Self.codexEvents)
        #expect(await ready.status() == .ready(version: "0.164.0"))
    }

    /// Codex 0.164 keeps `unified_exec` on whatever Funes asks: only the user's opt-in accepts it,
    /// nothing else, and a command is still stopped and discarded.
    @Test func codexFileReadsNeedTheOptIn() async throws {
        CLIRunner.unblock(CodexClient.providerID)
        let withExec = Self.featuresOK + ["unified_exec stable true"]
        let (off, offCLI) = Self.codex(Self.codexEvents, features: withExec)
        #expect(await off.status() == .fileReadsNotAllowed(version: "0.164.0"))
        await #expect(throws: ProviderError.unavailable) { try await off.generate(Self.request) }
        #expect(!offCLI.invocations.contains { $0.arguments.first == "exec" && !$0.arguments.contains("--help") })

        let (on, onCLI) = Self.codex(Self.codexEvents, features: withExec, allowsFileReads: true)
        #expect(await on.status() == .ready(version: "0.164.0"))
        #expect(try await on.generate(Self.request).0.title == "Green tea")
        let run = try #require(onCLI.invocations.last)
        #expect(zip(run.arguments, run.arguments.dropFirst()).contains { $0 == "--disable" && $1 == "shell_tool" })
        #expect(run.arguments[run.arguments.firstIndex(of: "--sandbox")! + 1] == "read-only")

        // Another unknown feature still refuses, opt-in or not.
        let (other, _) = Self.codex(Self.codexEvents, features: withExec + ["telepathy stable true"], allowsFileReads: true)
        #expect(await other.status() == .unsupportedFeatures(version: "0.164.0", features: ["telepathy"]))
        // A command is still stopped and discarded with the opt-in on.
        let command = Self.json(["type": "item.started", "item": ["id": "9", "type": "command_execution", "command": "cat ~/notes"]])
        let (reading, _) = Self.codex([command] + Self.codexEvents, features: withExec, allowsFileReads: true)
        await #expect(throws: ProviderError.unavailable) { try await reading.generate(Self.request) }
        #expect(CLIRunner.isBlocked(CodexClient.providerID))
        CLIRunner.unblock(CodexClient.providerID)
    }

    // MARK: The process runner

    @Test func theProcessRunnerStreamsStopsAndTimesOut() async throws {
        let runner = SystemCLIProcess()
        try await CLIRunner.inTemporaryDirectory { dir in
            let echo = try await runner.run(CLIInvocation(
                executable: "/bin/sh", arguments: ["-c", "read line; echo \"got $line\"; pwd; echo \"key=${OPENAI_API_KEY:-none}\""],
                environment: CLIRunner.environment(Self.environment), directory: dir, input: "hello\n", timeout: .seconds(10))) { _ in true }
            #expect(echo.exitCode == 0 && echo.lines.first == "got hello")
            #expect(echo.lines.contains { $0.hasSuffix(dir.lastPathComponent) })
            #expect(echo.lines.contains("key=none"))
            // A false answer from the handler kills it before the rest arrives.
            let stopped = try await runner.run(CLIInvocation(
                executable: "/bin/sh", arguments: ["-c", "echo tool; sleep 5; echo late"], environment: [:], directory: dir,
                timeout: .seconds(10))) { $0 != "tool" }
            #expect(stopped.stopped && !stopped.lines.contains("late"))
            let slow = try await runner.run(CLIInvocation(
                executable: "/bin/sh", arguments: ["-c", "sleep 5"], environment: [:], directory: dir, timeout: .milliseconds(300))) { _ in true }
            #expect(slow.timedOut)
        }
    }

    // MARK: The guardrails apply

    @Test func subscriptionsAreCloudProviders() async throws {
        CLIRunner.unblock(ClaudeCodeClient.providerID)
        let (client, cli) = Self.claude([Self.claudeInit, Self.claudeResult()])
        let secret = StructuredRequest<Answer>(instructions: "x", prompt: "<note>key sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456</note>",
                                               schema: Self.request.schema)
        await #expect(throws: ProviderError.blocked) {
            try await ModelRouter.send(secret, items: [ModelItem("note", sensitivity: .low)], to: client, cloudLimit: .upTo(.secret),
                                       timeout: .seconds(5))
        }
        await #expect(throws: ProviderError.blocked) {
            try await ModelRouter.send(Self.request, items: [ModelItem("note", sensitivity: .sensitive)], to: client,
                                       cloudLimit: .upTo(.internal), timeout: .seconds(5))
        }
        #expect(cli.invocations.isEmpty)
        let v = try TestVault()
        let cap = CloudRequestCap(store: v.store, limit: 5)
        _ = try await ModelRouter.send(Self.request, items: [ModelItem("note", sensitivity: .low)], to: client,
                                       cloudLimit: .upTo(.internal), cap: cap, timeout: .seconds(5))
        #expect(try await cap.today(now: Date()).total == 1)
        #expect(ModelRouter.engine(client) == "claude-code/haiku")
    }

    // MARK: Live smoke test (manual, on the developer's own plans)

    /// `FUNES_LIVE_SUBSCRIPTIONS=1 swift test --package-path Packages/FunesCore --filter liveSmokeTest`:
    /// one made-up note through each installed, signed-in CLI. Checks the start events show no
    /// tools (but Claude Code's structured-output one), MCP servers, plugins or hooks, and that
    /// nothing was stopped. Run before each release that touches the adapters (model providers §9).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUNES_LIVE_SUBSCRIPTIONS"] == "1"))
    func liveSmokeTest() async throws {
        final class Recorder: CLIProcessRunning {
            let lines = Mutex<[String]>([])
            func run(_ invocation: CLIInvocation, line: @escaping @Sendable (String) -> Bool) async throws -> CLIOutput {
                try await SystemCLIProcess().run(invocation) { text in
                    self.lines.withLock { $0.append(text) }
                    return line(text)
                }
            }
        }
        let home = NSHomeDirectory()
        for (name, make) in [("claude", { (path: String, r: Recorder) -> any SubscriptionClient in
                                  ClaudeCodeClient(executable: path, model: "haiku", runner: r) }),
                              ("codex", { (path: String, r: Recorder) -> any SubscriptionClient in
                                  CodexClient(executable: path, model: "gpt-6-luna", allowsFileReads: true, runner: r) })] {
            guard let path = [home + "/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
                .first(where: FileManager.default.isExecutableFile(atPath:)) else { continue }
            let recorder = Recorder()
            let client = make(path, recorder)
            CLIRunner.unblock(client.id)
            let status = await client.status()
            guard case .ready = status else { Issue.record("\(name) isn't ready: \(status)"); continue }
            // Only the model call is kept: the status checks print account details.
            recorder.lines.withLock { $0 = [] }
            // One call; on failure the events are still saved, so nothing has to be retried.
            let outcome: Result<CaptureProposal, any Error>
            do { outcome = .success(try await ModelRouter.testConnection(client, timeout: CLIRunner.timeout)) } catch { outcome = .failure(error) }
            let events = recorder.lines.withLock { $0 }
            if let folder = ProcessInfo.processInfo.environment["FUNES_LIVE_EVENTS_DIR"] {
                try? events.joined(separator: "\n").write(toFile: folder + "/\(name)-events.jsonl", atomically: true, encoding: .utf8)
            }
            switch outcome {
            case let .success(proposal): #expect(!proposal.title.isEmpty, "\(name)")
            case let .failure(error): Issue.record("\(name) failed: \(error)")
            }
            #expect(!CLIRunner.isBlocked(client.id), "\(name)")
            if name == "claude" {
                let initEvent = events.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                    .first { $0["type"] as? String == "system" && $0["subtype"] as? String == "init" }
                #expect(initEvent != nil)
                #expect(((initEvent?["tools"] as? [String]) ?? []).allSatisfy { $0 == ClaudeCodeClient.structuredOutputTool })
                #expect(((initEvent?["mcp_servers"] as? [Any]) ?? []).isEmpty)
            }
            let shape = events.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .map { e in [e["type"] as? String, e["subtype"] as? String, (e["item"] as? [String: Any])?["type"] as? String]
                    .compactMap { $0 }.joined(separator: "/") }
            FileHandle.standardError.write(Data("\(name) events: \(shape)\n".utf8))
        }
    }
}
