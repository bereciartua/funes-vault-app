import BridgeUI
import Foundation
import FunesCore
import FunesProtocol
import SwiftUI

/// How an agent is shown: its setup type, icon, status line and access summary (04-ux-mac.md).
extension AgentKind {
    var setupAgent: SetupAgent {
        switch self {
        case .claudeCode: .claudeCode
        case .claudeDesktop: .claudeDesktop
        case .cursor: .cursor
        case .codex: .codex
        case .vscode: .vsCode
        case .zed: .zed
        case .geminiCLI: .geminiCLI
        case .devinDesktop: .devinDesktop
        case .cline: .cline
        case .jetBrains: .jetBrains
        case .other: .other
        default: .other
        }
    }

    /// The cloud agent this kind is, for its Cloud tab's setup.
    var cloudAgent: CloudAgent? { CloudAgent.allCases.first { $0.agentKind == rawValue } }

    init(_ agent: CloudAgent) {
        self = AgentKind(rawValue: agent.agentKind) ?? .other
    }

    init(_ agent: SetupAgent) {
        self = AgentKind.allCases.first { $0.setupAgent == agent } ?? .other
    }

    var symbol: String {
        switch self {
        case .claudeCode, .codex, .geminiCLI: "terminal"
        case .claudeDesktop: "sparkle"
        case .cursor, .vscode, .zed, .cline, .jetBrains: "chevron.left.forwardslash.chevron.right"
        case .devinDesktop: "desktopcomputer"
        case .other: "puzzlepiece.extension"
        default: cloudAgent?.symbol ?? "cloud"
        }
    }

    var tint: Color {
        switch self {
        case .claudeCode, .claudeDesktop: .orange
        case .cursor: .indigo
        case .codex: .teal
        case .vscode: .blue
        case .zed: .purple
        case .geminiCLI: .cyan
        case .devinDesktop: .green
        case .cline, .jetBrains: .pink
        case .other: .gray
        case .claudeAI, .anthropicAPI, .managedAgents, .claudeCodeWeb: .orange
        case .chatGPT, .openAIResponses, .codexCloud: .teal
        case .geminiEnterprise: .cyan
        case .cursorCloud: .indigo
        case .copilotAgent: .blue
        case .devin: .green
        }
    }
}

/// The agent's icon: its type's symbol on a tinted square.
struct AgentIcon: View {
    let kind: AgentKind
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24).fill(kind.tint.gradient))
            .accessibilityHidden(true)
    }
}

enum AgentText {
    enum Status { case waiting, connected, paused, expired }

    static func status(_ agent: Agent, now: Date) -> Status {
        if agent.paused { return .paused }
        if let expiry = agent.access.expiresAt, expiry <= now { return .expired }
        return agent.firstRequestAt == nil ? .waiting : .connected
    }

    /// "Connected · 2 min ago", "Waiting for first request", "Paused", "Access expired" (FR-A-09).
    static func statusLine(_ agent: Agent, now: Date, client: String? = nil) -> String {
        switch status(agent, now: now) {
        case .paused: return String(localized: "Paused")
        case .expired: return String(localized: "Access expired")
        case .waiting: return String(localized: "Waiting for first request")
        case .connected:
            let when = agent.lastRequestAt.map { RelativeTime.short($0, now: now) } ?? ""
            if let client, !client.isEmpty { return String(localized: "Connected · \(client) · \(when)") }
            return String(localized: "Connected · \(when)")
        }
    }

    static func tone(_ agent: Agent, now: Date) -> Pill.Tone {
        switch status(agent, now: now) {
        case .connected: .good
        case .waiting: .accent
        case .paused: .warning
        case .expired: .bad
        }
    }

    /// "Reads Low and below in 3 categories · asks first".
    static func accessSummary(_ access: Access, categories: [MemoryCategory]) -> String {
        let ops = access.operations
        guard !ops.isEmpty else { return String(localized: "No access yet") }
        var parts: [String] = []
        let level = access.maxSensitivity.title
        let scope: String
        if !access.allowedCategoryKeys.isEmpty {
            let count = access.allowedCategoryKeys.subtracting(access.deniedCategoryKeys).count
            scope = count == 1 ? String(localized: "in 1 category") : String(localized: "in \(count) categories")
        } else if !access.deniedCategoryKeys.isEmpty {
            let count = categories.filter { !access.deniedCategoryKeys.contains($0.key) }.count
            scope = String(localized: "in \(count) categories")
        } else {
            scope = String(localized: "in all categories")
        }
        if ops.contains(.read) {
            parts.append(access.maxSensitivity == .secret ? String(localized: "Reads everything \(scope)")
                                                          : String(localized: "Reads \(level) and below \(scope)"))
        }
        if ops.contains(.write) {
            parts.append(access.askBeforeSaving ? String(localized: "suggests") : String(localized: "saves without asking"))
        } else if ops.contains(.suggest) {
            parts.append(String(localized: "suggests"))
        }
        if ops.contains(.read) {
            parts.append(access.askBeforeSharing ? String(localized: "asks first") : String(localized: "shares without asking"))
        }
        var text = parts.joined(separator: " · ")
        if let first = text.first { text = first.uppercased() + text.dropFirst() }
        if let expiry = access.expiresAt { text += " · " + String(localized: "until \(expiry.formatted(date: .abbreviated, time: .omitted))") }
        return text
    }

    /// "Keeps what it gets": one set of words for the user's note on an agent and for what an agent
    /// says about a request.
    static func retention(_ retention: Retention) -> String {
        switch retention {
        case .none: String(localized: "Not at all")
        case .session: String(localized: "For the session")
        case .persistent: String(localized: "Beyond the session")
        case .unknown: String(localized: "Not said")
        }
    }
}

/// The starting access offered when adding an agent (FR-A-02).
enum StartingAccess: String, CaseIterable, Identifiable {
    case nothingYet, readLowAskFirst, readAndSuggestAskFirst, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothingYet: String(localized: "Nothing yet")
        case .readLowAskFirst: String(localized: "Read low-sensitivity memories, ask first")
        case .readAndSuggestAskFirst: String(localized: "Read and suggest, ask first")
        case .custom: String(localized: "Custom")
        }
    }

    var detail: String {
        switch self {
        case .nothingYet: String(localized: "It can connect, but sees nothing until you give it access.")
        case .readLowAskFirst: String(localized: "Read, up to Low, in all categories. Funes asks before sharing.")
        case .readAndSuggestAskFirst: String(localized: "Read and suggest, up to Internal, except Health, Finance and Legal. Funes asks before sharing.")
        case .custom: String(localized: "Start with nothing and set it up on the Access tab.")
        }
    }

    var access: Access {
        switch self {
        case .nothingYet, .custom: Access.Preset.nothingYet.access
        case .readLowAskFirst: Access.Preset.readLowAskFirst.access
        case .readAndSuggestAskFirst: Access.Preset.readAndSuggestAskFirst.access
        }
    }
}
