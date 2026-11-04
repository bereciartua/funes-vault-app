import Foundation
import FunesProtocol
import Synchronization

/// Where a subscription CLI stands, for Settings ▸ AI ▸ Models & Accounts (ADR-0024).
public enum SubscriptionStatus: Sendable, Hashable {
    /// Found, new enough and signed in to the plan.
    case ready(version: String)
    case notInstalled
    /// "Not signed in: run `claude` in Terminal and sign in".
    case notSignedIn(version: String)
    /// It lacks a flag Funes needs: "Update Claude Code to use it".
    case needsUpdate(version: String?)
    /// Codex has a feature on that Funes doesn't know to be safe: "This Codex version isn't supported yet".
    case unsupportedFeatures(version: String, features: [String])
    /// Codex can run commands that read files, and the user hasn't accepted that (the opt-in is off).
    case fileReadsNotAllowed(version: String)
    /// A run showed a tool or command event: off until Test connection passes.
    case blocked

    public var isReady: Bool { if case .ready = self { true } else { false } }
}

/// What both subscription clients share: the CLI's path, the process runner, and the checks.
public protocol SubscriptionClient: GenerationProvider {
    var executable: String { get }
    /// Version, flags, sign-in (and for Codex, its features), without a model call.
    func status() async -> SubscriptionStatus
}

extension SubscriptionClient {
    /// A short check run: `--version`, `--help`, sign-in status. Never a model call.
    static func check(_ runner: any CLIProcessRunning, _ executable: String, _ arguments: [String],
                      environment: [String: String]) async -> CLIOutput? {
        try? await CLIRunner.inTemporaryDirectory { dir in
            try await runner.run(CLIInvocation(executable: executable, arguments: arguments, environment: environment,
                                               directory: dir, timeout: .seconds(15))) { _ in true }
        }
    }

    static func decodeOutput<T: Decodable>(_ object: Any, as type: T.Type) throws -> T {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw ProviderError.invalidOutput
        }
        return try HTTPClient.decode(String(decoding: data, as: UTF8.self), as: T.self)
    }
}

// MARK: - Claude (Claude Code)

/// Claude through the user's own `claude` CLI, signed in to their Claude plan (ADR-0024, model
/// providers §5.8). Every call: a new empty directory, no API keys in the environment, no
/// built-in tools, MCP servers, hooks, plugins or session file, never `--bare` (it skips the
/// plan's sign-in). The start event must show nothing loaded but the structured-output tool, and
/// any other tool use stops the run and discards its output.
public struct ClaudeCodeClient: SubscriptionClient {
    public static let providerID: ProviderID = "claude-code"
    /// The tool Claude Code adds for `--json-schema`; the only one a run may show.
    static let structuredOutputTool = "StructuredOutput"
    /// Plugins that ship inside Claude Code (path "builtin") and that `--safe-mode` doesn't turn off,
    /// read from 2.1.310's start event. With no tool but the structured-output one they can't act.
    /// Any other plugin, installed or a new built-in, stops the run until Funes knows it.
    static let knownBuiltinPlugins: Set<String> = ["cc-plugin-agents-md", "cc-plugin-plugin-authoring"]
    /// Flags Funes needs; a CLI without them is "Update Claude Code to use it".
    static let requiredFlags = ["--safe-mode", "--tools", "--disallowedTools", "--strict-mcp-config", "--settings",
                                "--no-session-persistence", "--json-schema", "--output-format", "--system-prompt"]
    /// Model suggestions (Spike E ran both).
    public static let suggestedModels = ["haiku", "opus"]
    /// Telemetry and error reporting off where Claude Code allows it.
    static let quiet = ["DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]

    public let id: ProviderID = ClaudeCodeClient.providerID
    public let locality = Locality.cloud
    public let modelID: String
    public let executable: String
    public let effort: String?
    let runner: any CLIProcessRunning
    let baseEnvironment: [String: String]

    public init(executable: String, model: String, effort: String? = "low", runner: any CLIProcessRunning = SystemCLIProcess(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        modelID = model
        self.effort = effort
        self.runner = runner
        baseEnvironment = environment
    }

    var environment: [String: String] { CLIRunner.environment(baseEnvironment, extra: Self.quiet) }

    /// The call's arguments (model providers §5.8).
    func arguments(instructions: String, schema: JSONSchema) -> [String] {
        var args = ["-p", "--safe-mode", "--tools", "", "--disallowedTools", "mcp__*", "--strict-mcp-config",
                    "--settings", #"{"disableAllHooks": true}"#, "--no-session-persistence",
                    "--system-prompt", instructions, "--json-schema", schema.json,
                    "--output-format", "stream-json", "--verbose", "--model", modelID]
        if let effort { args += ["--effort", effort] }
        return args
    }

    public func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        guard !CLIRunner.isBlocked(id) else { throw ProviderError.unavailable }
        let stream = ClaudeStream()
        let output = try await CLIRunner.inTemporaryDirectory { dir in
            try await runner.run(CLIInvocation(executable: executable, arguments: arguments(instructions: request.instructions,
                                                                                             schema: request.schema),
                                               environment: environment, directory: dir, input: request.prompt,
                                               timeout: CLIRunner.timeout)) { line in stream.take(line) }
        }
        if stream.toolEvent {
            CLIRunner.block(id)
            throw ProviderError.unavailable
        }
        if output.timedOut { throw ProviderError.timeout }
        return try stream.result(as: T.self, exitCode: output.exitCode)
    }

    public func status() async -> SubscriptionStatus {
        guard !CLIRunner.isBlocked(id) else { return .blocked }
        guard let versionRun = await Self.check(runner, executable, ["--version"], environment: environment),
              versionRun.exitCode == 0 else { return .notInstalled }
        let version = CLIRunner.version(in: versionRun.lines.joined(separator: " "))
        guard let help = await Self.check(runner, executable, ["--help"], environment: environment),
              Self.requiredFlags.allSatisfy(help.lines.joined(separator: "\n").contains) else { return .needsUpdate(version: version) }
        guard let auth = await Self.check(runner, executable, ["auth", "status", "--json"], environment: environment),
              Self.signedInToPlan(auth.lines.joined(separator: "\n")) else { return .notSignedIn(version: version ?? "") }
        return .ready(version: version ?? "")
    }

    /// `claude auth status --json`: signed in, with a Claude plan rather than an API key. Only
    /// these two fields are read; the account's details are never kept.
    static func signedInToPlan(_ json: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
        return object["loggedIn"] as? Bool == true && (object["authMethod"] as? String).map { $0.hasPrefix("claude.ai") } == true
    }
}

/// Reads Claude Code's `stream-json` events as they arrive (ADR-0024 §3).
final class ClaudeStream: @unchecked Sendable {
    private let lock = NSLock()
    private var structured: Any?
    private var usage = ProviderUsage(requests: 1)
    private var failure: ProviderError?
    private(set) var toolEvent = false

    /// False stops the run: something loaded or used that isn't the structured-output tool.
    func take(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        lock.lock()
        defer { lock.unlock() }
        let type = event["type"] as? String
        let subtype = event["subtype"] as? String
        switch (type, subtype) {
        case ("system", "init"):
            let tools = (event["tools"] as? [Any]) ?? []
            let allowed = tools.allSatisfy { ($0 as? String) == ClaudeCodeClient.structuredOutputTool }
            // Built-in agent types and skills are allowed: without the Agent or Skill tool they can't run.
            let empty = ["mcp_servers", "hooks"].allSatisfy { key in
                guard let value = event[key] else { return true }
                if let list = value as? [Any] { return list.isEmpty }
                if let map = value as? [String: Any] { return map.isEmpty }
                return false
            }
            let plugins = (event["plugins"] as? [Any]) ?? (event["plugins"] == nil ? [] : [event["plugins"] as Any])
            let builtins = plugins.allSatisfy { plugin in
                guard let p = plugin as? [String: Any], p["path"] as? String == "builtin", let name = p["name"] as? String else { return false }
                return ClaudeCodeClient.knownBuiltinPlugins.contains(name)
            }
            // A key or helper in managed settings would bill the API, not the plan.
            let plan = (event["apiKeySource"] as? String).map { $0 == "none" } ?? true
            if !allowed || !empty || !builtins || !plan { return stop() }
        case ("system", let sub?) where sub.hasPrefix("hook"):
            return stop()
        case ("assistant", _):
            let content = ((event["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in content where (block["type"] as? String)?.hasSuffix("tool_use") == true {
                guard block["name"] as? String == ClaudeCodeClient.structuredOutputTool else { return stop() }
                if let input = block["input"] as? [String: Any] { structured = input }
            }
        case ("result", _):
            if let output = event["structured_output"] as? [String: Any] { structured = output }
            if let model = (event["modelUsage"] as? [String: Any])?.values.first as? [String: Any] {
                usage.inputTokens = ["inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"].reduce(0) {
                    $0 + (model[$1] as? Int ?? 0)
                }
                usage.outputTokens = model["outputTokens"] as? Int ?? 0
            } else if let u = event["usage"] as? [String: Any] {
                usage.inputTokens = u["input_tokens"] as? Int ?? 0
                usage.outputTokens = u["output_tokens"] as? Int ?? 0
            }
            if event["is_error"] as? Bool == true || subtype != "success" {
                failure = Self.error(event)
                structured = nil
            }
        default:
            break
        }
        return true
    }

    private func stop() -> Bool {
        toolEvent = true
        structured = nil
        return false
    }

    /// Error codes only, never the text (model providers §5.4).
    static func error(_ event: [String: Any]) -> ProviderError {
        let text = ((event["result"] as? String) ?? (event["subtype"] as? String) ?? "").lowercased()
        if event["stop_reason"] as? String == "refusal" { return .refused }
        if text.contains("limit") { return .rateLimited(retryAfter: nil) }
        if text.contains("log in") || text.contains("login") || text.contains("not logged") || text.contains("auth") {
            return .unauthorized
        }
        return .invalidOutput
    }

    func result<T: Decodable>(as type: T.Type, exitCode: Int32) throws -> (T, ProviderUsage) {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        guard let structured else { throw exitCode == 0 ? ProviderError.invalidOutput : ProviderError.server(status: Int(exitCode)) }
        return (try ClaudeCodeClient.decodeOutput(structured, as: T.self), usage)
    }
}

// MARK: - ChatGPT (Codex)

/// OpenAI models through the user's own `codex` CLI, signed in with ChatGPT (ADR-0024, model
/// providers §5.8). Codex has no "no tools" mode, so every tool feature is turned off one by one,
/// and the provider refuses to run while any enabled feature isn't on the list Funes knows to be
/// safe. Any tool or command event stops the run and discards its output.
public struct CodexClient: SubscriptionClient {
    public static let providerID: ProviderID = "codex"
    static let requiredFlags = ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "--sandbox",
                                "--output-schema", "--json", "--disable", "--output-last-message"]
    /// Model suggestions: the ones Spike E measured.
    public static let suggestedModels = ["gpt-6-luna", "gpt-5.6-terra"]

    /// Features turned off for every call: tools, commands, browsing, apps, plugins, hooks, images,
    /// agents, and anything that starts work outside the call.
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "unified_exec_tty", "shell_snapshot", "write_stdin_approval",
        "browser_use", "browser_use_external", "browser_use_full_cdp_access", "browser_annotation_api", "in_app_browser",
        "computer_use", "apps", "plugins", "remote_plugin", "plugin_sharing", "hooks", "image_generation", "view_image",
        "code_mode_host", "code_mode_interrupt", "multi_agent", "goals", "sleep_tool", "skill_search",
        "skill_mcp_dependency_install", "tool_suggest", "tool_call_mcp_elicitation", "mcp_oauth_refresh_coordination",
        "incremental_tools", "mentions_v2", "workspace_dependencies", "in_app_local_automation", "in_app_chat",
        "in_app_dictation", "in_app_voice", "guardian_approval", "daemon_auto_start", "cli_daybreak",
    ]
    /// Features that may stay on: transport, accounts and display, no tools (read from codex-cli
    /// 0.164.0's `features list`).
    static let safeFeatures: Set<String> = [
        "api_key_cyber_access_programs", "api_key_model_discovery", "auth_elicitation", "bedrock_setup_wizard",
        "compaction_image_budget", "content_item_kinds", "enable_request_compression", "fast_mode", "ultrafast_mode",
        "guardian_reuse_parent_compaction", "instant_interrupt", "in_app_updates", "system_proxy_fallback",
        "unbounded_connection_retries",
    ]
    /// Item types a run may show; anything else is a tool or a command.
    static let allowedItems: Set<String> = ["agent_message", "reasoning", "error"]

    public let id: ProviderID = CodexClient.providerID
    public let locality = Locality.cloud
    public let modelID: String
    public let executable: String
    public let effort: String
    /// The user's opt-in (Settings, off by default): Codex 0.164 keeps `unified_exec`, which can run
    /// commands that read files, on whatever Funes asks. Only with it does the feature check accept
    /// `unified_exec`, and only that; a run that uses a command is still stopped and discarded.
    public let allowsFileReads: Bool
    let runner: any CLIProcessRunning
    let baseEnvironment: [String: String]

    /// The feature the opt-in accepts.
    static let fileReadFeature = "unified_exec"

    public init(executable: String, model: String, effort: String = "low", allowsFileReads: Bool = false,
                runner: any CLIProcessRunning = SystemCLIProcess(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        modelID = model
        self.effort = effort
        self.allowsFileReads = allowsFileReads
        self.runner = runner
        baseEnvironment = environment
    }

    var environment: [String: String] { CLIRunner.environment(baseEnvironment) }

    var disableArguments: [String] { Self.disabledFeatures.flatMap { ["--disable", $0] } }

    /// The call's arguments (model providers §5.8). The task's instructions replace Codex's own.
    func arguments(directory: URL, schemaFile: URL, instructionsFile: URL, outputFile: URL) -> [String] {
        ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
         "-C", directory.path, "--output-schema", schemaFile.path, "--output-last-message", outputFile.path, "--json",
         "-m", modelID, "-c", "model_reasoning_effort=\(effort)", "-c", "model_instructions_file=\"\(instructionsFile.path)\"",
         "-c", "web_search=disabled"] + disableArguments + ["-"]
    }

    public func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        guard !CLIRunner.isBlocked(id) else { throw ProviderError.unavailable }
        // The features check runs before the first call and after each update (it's cached per version).
        guard case .ready = await featureCheck() else { throw ProviderError.unavailable }
        let stream = CodexStream()
        let (output, text) = try await CLIRunner.inTemporaryDirectory { dir -> (CLIOutput, String?) in
            let work = dir.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let schema = dir.appending(path: "schema.json"), instructions = dir.appending(path: "instructions.md")
            let last = dir.appending(path: "last-message.json")
            try Data(request.schema.json.utf8).write(to: schema)
            try Data(request.instructions.utf8).write(to: instructions)
            let output = try await runner.run(CLIInvocation(
                executable: executable, arguments: arguments(directory: work, schemaFile: schema, instructionsFile: instructions,
                                                            outputFile: last),
                environment: environment, directory: work, input: request.prompt, timeout: CLIRunner.timeout)) { stream.take($0) }
            return (output, try? String(contentsOf: last, encoding: .utf8))
        }
        if stream.toolEvent {
            CLIRunner.block(id)
            throw ProviderError.unavailable
        }
        if output.timedOut { throw ProviderError.timeout }
        if let failure = stream.failure { throw failure }
        guard let text = text ?? stream.lastMessage, !text.isEmpty else {
            throw output.exitCode == 0 ? ProviderError.invalidOutput : ProviderError.server(status: Int(output.exitCode))
        }
        return (try HTTPClient.decode(text, as: T.self), stream.usage)
    }

    public func status() async -> SubscriptionStatus {
        guard !CLIRunner.isBlocked(id) else { return .blocked }
        guard let versionRun = await Self.check(runner, executable, ["--version"], environment: environment),
              versionRun.exitCode == 0 else { return .notInstalled }
        let version = CLIRunner.version(in: versionRun.lines.joined(separator: " "))
        guard let help = await Self.check(runner, executable, ["exec", "--help"], environment: environment),
              Self.requiredFlags.allSatisfy(help.lines.joined(separator: "\n").contains) else { return .needsUpdate(version: version) }
        guard let login = await Self.check(runner, executable, ["login", "status"], environment: environment),
              login.exitCode == 0, (login.lines + [login.errorTail]).contains(where: { $0.contains("ChatGPT") }) else {
            return .notSignedIn(version: version ?? "")
        }
        return await featureCheck(version: version)
    }

    private static let checked = Mutex<[String: SubscriptionStatus]>([:])

    /// `codex features list` with Funes's `--disable`s: every feature still on must be known to
    /// be safe. Cached per executable and version.
    func featureCheck(version known: String? = nil) async -> SubscriptionStatus {
        var version = known
        if version == nil, let run = await Self.check(runner, executable, ["--version"], environment: environment) {
            version = CLIRunner.version(in: run.lines.joined(separator: " "))
        }
        guard let version else { return .notInstalled }
        let key = "\(executable)@\(version)/\(allowsFileReads)"
        if let cached = Self.checked.withLock({ $0[key] }) { return cached }
        guard let list = await Self.check(runner, executable, ["features", "list"] + disableArguments, environment: environment),
              list.exitCode == 0 else {
            // A feature Funes turns off is gone from this version: Funes needs updating first.
            return .unsupportedFeatures(version: version, features: [])
        }
        let unknown = Self.unknownEnabled(list.lines, allowing: allowsFileReads ? [Self.fileReadFeature] : [])
        let status: SubscriptionStatus = if unknown.isEmpty {
            .ready(version: version)
        } else if unknown == [Self.fileReadFeature] {
            .fileReadsNotAllowed(version: version)
        } else {
            .unsupportedFeatures(version: version, features: unknown)
        }
        Self.checked.withLock { $0[key] = status }
        return status
    }

    /// Lines of `name stage state`: features that are on, not removed, and not known to be safe
    /// (or accepted by the user's opt-in).
    static func unknownEnabled(_ lines: [String], allowing accepted: Set<String> = []) -> [String] {
        lines.compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3, fields.last == "true" else { return nil }
            let name = fields[0]
            if fields.dropFirst().dropLast().joined(separator: " ") == "removed" { return nil }
            return safeFeatures.contains(name) || accepted.contains(name) ? nil : name
        }
    }
}

/// Reads Codex's `--json` events as they arrive (ADR-0024 §3).
final class CodexStream: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var toolEvent = false
    private(set) var failure: ProviderError?
    private(set) var lastMessage: String?
    private(set) var usage = ProviderUsage(requests: 1)

    func take(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        lock.lock()
        defer { lock.unlock() }
        let type = event["type"] as? String ?? ""
        if type.hasPrefix("item."), let item = event["item"] as? [String: Any] {
            let kind = item["type"] as? String ?? item["item_type"] as? String ?? ""
            guard CodexClient.allowedItems.contains(kind) else {
                toolEvent = true
                lastMessage = nil
                return false
            }
            if kind == "agent_message", let text = item["text"] as? String { lastMessage = text }
        } else if type == "turn.completed" {
            let u = event["usage"] as? [String: Any] ?? [:]
            usage.inputTokens = u["input_tokens"] as? Int ?? 0
            usage.outputTokens = (u["output_tokens"] as? Int ?? 0)
        } else if type == "turn.failed" || type == "error" {
            let message = ((event["error"] as? [String: Any])?["message"] as? String ?? event["message"] as? String ?? "").lowercased()
            failure = message.contains("limit") ? .rateLimited(retryAfter: nil)
                : message.contains("401") || message.contains("unauthorized") || message.contains("login") ? .unauthorized
                : .server(status: 500)
        }
        return true
    }
}
