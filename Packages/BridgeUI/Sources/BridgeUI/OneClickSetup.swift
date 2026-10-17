import AppKit
import BridgeKitCore

// Adapted from EK Bridge's OneClickSetup (Upstream/OneClickSetup.swift): the live preview, apply
// and restart behind Add to <Agent>…, over BridgeKitCore's AgentConfigWriter. Nothing runs without
// a click, every change is shown first, files are backed up, and no key is written anywhere.
// Changes from EK Bridge: the backup tag and app name are parameters, and the agents' own commands
// run with HOME set to the home being configured, so a scratch HOME in tests (or the UI-review
// build) can never reach the user's real configs.

/// What the preview sheet shows before Add.
public enum OneClickPreview: Equatable, Sendable {
    case file(agent: SetupAgent, change: ConfigChange)
    /// The agent's own command (`claude`, `codex`) with these arguments; `replacing` when it already
    /// has the server.
    case command(agent: SetupAgent, executable: String, arguments: [String], key: String, replacing: Bool)

    public var agent: SetupAgent {
        switch self {
        case .file(let agent, _), .command(let agent, _, _, _, _): agent
        }
    }
}

public struct OneClickResult: Equatable, Sendable {
    public let agent: SetupAgent
    /// The backup of the changed file (file agents).
    public var backup: URL?
    /// The command's output, last 20 lines.
    public var output: String?
    public var alreadySetUp = false
}

public struct OneClickFailure: Error, Equatable, Sendable {
    public let message: String
    public var output: String? = nil
    /// Offer Copy the Setup Instead (invalid file, tool not found).
    public var copyInstead = true

    public init(message: String, output: String? = nil, copyInstead: Bool = true) {
        self.message = message
        self.output = output
        self.copyInstead = copyInstead
    }
}

/// The live controls the Connect tab uses; the UI-review build passes fakes.
@MainActor
public struct AgentSetupControls {
    public var preview: @MainActor (SetupAgent, SetupContext, @escaping @MainActor (Result<OneClickPreview, OneClickFailure>) -> Void) -> Void
    public var apply: @MainActor (OneClickPreview, @escaping @MainActor (Result<OneClickResult, OneClickFailure>) -> Void) -> Void
    /// Quits the agent's app and opens it again; false when it didn't quit in 5 s.
    public var restart: @MainActor (SetupAgent, @escaping @MainActor (Bool) -> Void) -> Void

    public init(preview: @escaping @MainActor (SetupAgent, SetupContext, @escaping @MainActor (Result<OneClickPreview, OneClickFailure>) -> Void) -> Void,
                apply: @escaping @MainActor (OneClickPreview, @escaping @MainActor (Result<OneClickResult, OneClickFailure>) -> Void) -> Void,
                restart: @escaping @MainActor (SetupAgent, @escaping @MainActor (Bool) -> Void) -> Void) {
        self.preview = preview
        self.apply = apply
        self.restart = restart
    }
}

public enum OneClickAgents {
    /// The app an agent runs in, for Restart.
    public static func bundleID(_ agent: SetupAgent) -> String? {
        AgentDetection.signals(agent)?.bundleIDs.first
    }

    /// The live controls. `home` is the user's home (a scratch HOME in tests); `tag` names the app
    /// in backups (`<file>.<tag>-backup-<time>`).
    @MainActor
    public static func live(home: String = NSHomeDirectory(), appName: String, tag: String,
                            locator: ExecutableLocator = .live) -> AgentSetupControls {
        AgentSetupControls(
            preview: { agent, context, done in
                guard let setup = agent.oneClickSetup(context) else {
                    return done(.failure(OneClickFailure(message: String(localized: "There's no one-click setup for \(agent.displayName)."))))
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = preview(agent, setup, home: home, appName: appName, locator: locator)
                    DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
                }
            },
            apply: { preview, done in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = apply(preview, home: home, appName: appName, tag: tag)
                    DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
                }
            },
            restart: { agent, done in
                guard let bundleID = bundleID(agent),
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                    return done(false)
                }
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                running.forEach { $0.terminate() }
                @MainActor func reopen(_ waited: Double) {
                    if running.allSatisfy(\.isTerminated) {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                            let ok = error == nil
                            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
                        }
                    } else if waited >= 5 {
                        done(false)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { reopen(waited + 0.25) } }
                    }
                }
                reopen(0)
            })
    }

    static func expand(_ path: String, home: String) -> URL {
        URL(fileURLWithPath: path.hasPrefix("~/") ? home + path.dropFirst(1) : path)
    }

    public static func preview(_ agent: SetupAgent, _ setup: OneClickSetup, home: String, appName: String,
                               locator: ExecutableLocator) -> Result<OneClickPreview, OneClickFailure> {
        switch setup {
        case .jsonMerge(let file, let root, let key, let entry):
            do {
                let change = try AgentConfigWriter.preview(fileURL: expand(file, home: home), root: root, key: key, entry: entry)
                return .success(.file(agent: agent, change: change))
            } catch let error as ConfigWriteError {
                return .failure(OneClickFailure(message: error.message(appName: appName)))
            } catch {
                return .failure(OneClickFailure(message: error.localizedDescription))
            }
        case .claudeCode(let key, let arguments):
            guard let claude = locator.locate("claude", home: home) else {
                return .failure(OneClickFailure(message: String(localized: "Claude Code's claude command wasn't found on this Mac.")))
            }
            let existing = ProcessRunner.run(claude, ["mcp", "get", key], timeout: 20, environment: environment(claude, home: home))
            return .success(.command(agent: agent, executable: claude, arguments: arguments, key: key,
                                     replacing: existing?.exitCode == 0))
        case .codex(let key, let arguments, let file, let table):
            // Codex's own command when it's installed; its config file otherwise.
            if let codex = locator.locate("codex", home: home) {
                let existing = ProcessRunner.run(codex, ["mcp", "get", key], timeout: 20, environment: environment(codex, home: home))
                return .success(.command(agent: agent, executable: codex, arguments: arguments, key: key,
                                         replacing: existing?.exitCode == 0))
            }
            do {
                let change = try AgentConfigWriter.previewTOML(fileURL: codexConfig(file, home: home), key: key, table: table)
                return .success(.file(agent: agent, change: change))
            } catch let error as ConfigWriteError {
                return .failure(OneClickFailure(message: error.message(appName: appName)))
            } catch {
                return .failure(OneClickFailure(message: error.localizedDescription))
            }
        }
    }

    /// Codex keeps its config in CODEX_HOME when that's set (for the real home only).
    static func codexConfig(_ file: String, home: String) -> URL {
        if home == NSHomeDirectory(), let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], codexHome.hasPrefix("/") {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("config.toml")
        }
        return expand(file, home: home)
    }

    /// How each agent's command removes a server before it's added again.
    static func removeArguments(_ agent: SetupAgent, key: String) -> [String] {
        agent == .codex ? ["mcp", "remove", key] : ["mcp", "remove", "--scope", "user", key]
    }

    public static func apply(_ preview: OneClickPreview, home: String, appName: String,
                             tag: String) -> Result<OneClickResult, OneClickFailure> {
        switch preview {
        case .file(let agent, let change):
            if change.outcome == .unchanged { return .success(OneClickResult(agent: agent, alreadySetUp: true)) }
            do {
                let backup = try AgentConfigWriter.apply(change, tag: tag, backupSuffix: AgentConfigWriter.backupSuffix())
                return .success(OneClickResult(agent: agent, backup: backup))
            } catch let error as ConfigWriteError {
                return .failure(OneClickFailure(message: error.message(appName: appName),
                                                copyInstead: error != .changedSinceReading))
            } catch {
                return .failure(OneClickFailure(message: error.localizedDescription))
            }
        case .command(let agent, let tool, let arguments, let key, let replacing):
            var log = ""
            let name = agent.displayName
            let environment = environment(tool, home: home)
            // Replacing an existing entry (PR #3 review 4304236146): the file the agent's command keeps
            // it in is backed up first, removal must succeed before adding, and a failed add puts the
            // backup back, so a working setup is never left deleted.
            var backup: (file: URL, copy: URL)?
            if replacing {
                let file = cliConfigFile(agent, home: home)
                guard FileManager.default.fileExists(atPath: file.path) else {
                    return .failure(OneClickFailure(message: String(localized: "\(name) already has a \(key) entry, but its settings file wasn't where \(appName) expected, so nothing was changed.")))
                }
                let copy = file.deletingLastPathComponent()
                    .appendingPathComponent("\(file.lastPathComponent).\(tag)-backup-\(AgentConfigWriter.backupSuffix())")
                do {
                    try? FileManager.default.removeItem(at: copy)
                    try FileManager.default.copyItem(at: file, to: copy)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                } catch {
                    return .failure(OneClickFailure(message: String(localized: "\(appName) couldn't back up \(file.lastPathComponent) first, so nothing was changed.")))
                }
                backup = (file, copy)
                let removed = ProcessRunner.run(tool, removeArguments(agent, key: key), timeout: 20, environment: environment)
                log += removed?.output ?? ""
                guard let removed, !removed.timedOut, removed.exitCode == 0 else {
                    let restored = restore(backup)
                    return .failure(OneClickFailure(
                        message: restored ? String(localized: "\(name) couldn't remove its existing \(key) entry, so it was left as it was.")
                                          : String(localized: "\(name) couldn't remove its existing \(key) entry. Its previous settings are in \(copy.path)."),
                        output: lastLines(log, 20)))
                }
            }
            let added = ProcessRunner.run(tool, arguments, timeout: 20, environment: environment)
            log += added?.output ?? ""
            let tail = lastLines(log, 20)
            let problem: String? = switch added {
            case nil: String(localized: "\(name) couldn't be started.")
            case let added? where added.timedOut: String(localized: "\(name) didn't finish within 20 seconds.")
            case let added? where added.exitCode != 0: String(localized: "\(name) reported an error (exit code \(added.exitCode)).")
            default: nil
            }
            if let problem {
                guard let backup else { return .failure(OneClickFailure(message: problem, output: tail)) }
                let note = restore(backup) ? String(localized: "Your previous setup was put back.")
                                           : String(localized: "Your previous setup couldn't be put back; it's in \(backup.copy.path).")
                return .failure(OneClickFailure(message: problem + " " + note, output: tail))
            }
            return .success(OneClickResult(agent: agent, backup: backup?.copy, output: tail))
        }
    }

    /// Where an agent's own command keeps its MCP servers: `~/.claude.json` (user scope) or Codex's
    /// config.toml.
    static func cliConfigFile(_ agent: SetupAgent, home: String) -> URL {
        agent == .codex ? codexConfig("~/.codex/config.toml", home: home) : expand("~/.claude.json", home: home)
    }

    /// Copies the backup over the file again; true when it matches afterwards.
    static func restore(_ backup: (file: URL, copy: URL)?) -> Bool {
        guard let backup else { return true }
        let manager = FileManager.default
        let staged = backup.file.deletingLastPathComponent().appendingPathComponent(".\(backup.file.lastPathComponent).restoring")
        try? manager.removeItem(at: staged)
        guard (try? manager.copyItem(at: backup.copy, to: staged)) != nil else { return false }
        if manager.fileExists(atPath: backup.file.path) {
            guard (try? manager.replaceItemAt(backup.file, withItemAt: staged)) != nil else { return false }
        } else {
            guard (try? manager.moveItem(at: staged, to: backup.file)) != nil else { return false }
        }
        return manager.contents(atPath: backup.file.path) == manager.contents(atPath: backup.copy.path)
    }

    /// A GUI app's PATH is minimal; `claude` may be a Node script, so its own folder and the usual
    /// tool folders come first. HOME is the home being configured.
    static func environment(_ executable: String, home: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let folder = (executable as NSString).deletingLastPathComponent
        let path = [folder, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (path + [environment["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        environment["HOME"] = home
        if home != NSHomeDirectory() { environment["CODEX_HOME"] = home + "/.codex" }
        return environment
    }

    static func lastLines(_ text: String, _ count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count)
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
