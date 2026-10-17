import AppKit
import BridgeKitCore

// Adapted from EK Bridge's AgentDetection (Upstream/AgentDetection.swift): which agents are
// installed on this Mac, for the Add-agent sheet's tiles (FR-A-01). The probe is injected, so tests
// use fakes. EK Bridge's ConnectionAgentKinds (its per-connection store) isn't needed: Funes keeps
// each agent's kind in the vault.

/// How detection looks at the Mac. The live probe asks LaunchServices for an app by bundle ID and
/// checks paths; tests pass closures over fixed data.
public struct AgentProbe: Sendable {
    /// Bundle ID → the app's URL (live: `NSWorkspace.urlForApplication(withBundleIdentifier:)`).
    public var appURL: @Sendable (String) -> URL?
    /// Whether an absolute path exists.
    public var fileExists: @Sendable (String) -> Bool
    /// The user's home folder, without a trailing slash.
    public var home: String
    /// Finds a command-line tool; nil when it isn't installed.
    public var executable: @Sendable (String) -> String?

    public init(appURL: @escaping @Sendable (String) -> URL?, fileExists: @escaping @Sendable (String) -> Bool, home: String,
                executable: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.appURL = appURL
        self.fileExists = fileExists
        self.home = home
        self.executable = executable
    }

    /// LaunchServices, the file system and the usual tool folders (no login shell, so it's quick).
    public static var live: AgentProbe {
        let home = NSHomeDirectory()
        return AgentProbe(
            appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            home: home,
            executable: { name in
                ExecutableLocator.candidates(name, home: home).first { FileManager.default.isExecutableFile(atPath: $0) }
            })
    }
}

public enum AgentDetection {
    /// What marks an agent as installed: an app bundle ID, and paths as a fallback. Paths starting
    /// with "~/" are under the user's home.
    public struct Signals: Sendable {
        public var bundleIDs: [String] = []
        public var paths: [String] = []
        public var executable: String? = nil
    }

    public static func signals(_ agent: SetupAgent) -> Signals? {
        switch agent {
        case .claudeCode: Signals(paths: ["~/.claude"], executable: "claude")
        case .claudeDesktop: Signals(bundleIDs: ["com.anthropic.claudefordesktop"],
                                     paths: ["/Applications/Claude.app", "~/Applications/Claude.app"])
        case .codex: Signals(paths: ["~/.codex"], executable: "codex")
        case .cursor: Signals(bundleIDs: ["com.todesktop.230313mzl4w4u92"],
                              paths: ["/Applications/Cursor.app", "~/Applications/Cursor.app", "~/.cursor"])
        case .vsCode: Signals(bundleIDs: ["com.microsoft.VSCode"],
                              paths: ["/Applications/Visual Studio Code.app", "~/Applications/Visual Studio Code.app"])
        case .geminiCLI: Signals(paths: ["~/.gemini"], executable: "gemini")
        // Devin Desktop's bundle ID isn't confirmed, so only its config folder counts.
        case .devinDesktop: Signals(paths: ["~/.config/devin"])
        case .zed: Signals(bundleIDs: ["dev.zed.Zed"], paths: ["/Applications/Zed.app", "~/Applications/Zed.app", "~/.config/zed"])
        // Extensions inside other editors: never marked installed.
        case .cline, .jetBrains, .other: nil
        }
    }

    public static func installed(_ probe: AgentProbe) -> Set<SetupAgent> {
        Set(SetupAgent.allCases.filter { isInstalled($0, probe) })
    }

    public static func isInstalled(_ agent: SetupAgent, _ probe: AgentProbe) -> Bool {
        guard let signals = signals(agent) else { return false }
        if signals.bundleIDs.contains(where: { probe.appURL($0) != nil }) { return true }
        if signals.paths.contains(where: { probe.fileExists(expand($0, home: probe.home)) }) { return true }
        if let tool = signals.executable, probe.executable(tool) != nil { return true }
        return false
    }

    static func expand(_ path: String, home: String) -> String {
        path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }
}
