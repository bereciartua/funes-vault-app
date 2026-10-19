import BridgeKitRemote
import Foundation

// The app's words for BridgeKitRemote's typed tunnel results, and the tunnel guide's commands.
// Adapted from EK Bridge (Upstream/TunnelHealth.swift, TunnelSwitch.swift, RemoteAccessSupport.swift
// and the "Tunnels (§22.5)" part of Upstream/AgentSetup.swift): EK Bridge's "connection" and
// calendar data become Funes's agents and memories, and the app's names come from `RemoteNames`.
// Pure, so the commands and steps are golden-tested (fixtures/agent-setup/tunnel-*.txt).

/// The app's names in Remote Access text and cloud snippets.
public struct RemoteNames: Sendable, Equatable {
    /// "Funes Vault".
    public var appName: String
    /// The named Cloudflare tunnel the guide creates: `funes-vault`.
    public var tunnelName: String
    /// The environment variable header-based cloud setups read the remote token from.
    public var remoteTokenEnvironmentVariable: String
    /// The button on the agent's Cloud section that copies it: "Copy Remote Token…".
    public var copyTokenAction: String

    public init(appName: String, tunnelName: String, remoteTokenEnvironmentVariable: String, copyTokenAction: String) {
        self.appName = appName
        self.tunnelName = tunnelName
        self.remoteTokenEnvironmentVariable = remoteTokenEnvironmentVariable
        self.copyTokenAction = copyTokenAction
    }

    public static let funes = RemoteNames(appName: "Funes Vault", tunnelName: "funes-vault",
                                          remoteTokenEnvironmentVariable: "FUNES_REMOTE_TOKEN",
                                          copyTokenAction: String(localized: "Copy Remote Token…"))
}

// MARK: - Tunnels

extension TunnelProvider {
    /// The Remote Access listener's default port (MCP server §12): clear of 47625 and 47626
    /// (Funes's MCP and companion ports) and EK Bridge's 47615 and 47616.
    public static let defaultRemotePort = 47627

    /// The guide's tunnel choice.
    public var displayName: String {
        switch self {
        case .tailscaleFunnel: String(localized: "Tailscale Funnel (recommended)")
        case .cloudflareTunnel: String(localized: "Cloudflare Tunnel (your own domain)")
        case .ngrok: String(localized: "ngrok")
        case .cloudflareQuick: String(localized: "Cloudflare quick tunnel (testing only)")
        case .other: String(localized: "Other tunnel")
        }
    }

    /// The plain name, for chips, Activity and the Test result.
    public var name: String {
        switch self {
        case .tailscaleFunnel: String(localized: "Tailscale Funnel")
        case .cloudflareTunnel: String(localized: "Cloudflare Tunnel")
        case .ngrok: String(localized: "ngrok")
        case .cloudflareQuick: String(localized: "Cloudflare quick tunnel")
        case .other: String(localized: "Other")
        }
    }

    /// The tunnel inside a sentence: "Switch to Tailscale Funnel?", but "Switch to another
    /// tunnel?" for Other tunnel.
    public var inSentence: String { self == .other ? String(localized: "another tunnel") : name }

    /// One line for the guide's tunnel choice.
    public var summary: String {
        switch self {
        case .tailscaleFunnel: String(localized: "Free; TLS ends on this Mac. Needs Tailscale installed and signed in.")
        case .cloudflareTunnel: String(localized: "Free with your own domain on Cloudflare. TLS ends at Cloudflare.")
        case .ngrok: String(localized: "A free dev domain with an ngrok account. TLS ends at ngrok.")
        case .cloudflareQuick: String(localized: "No account, but a random address each time. For testing only.")
        case .other: String(localized: "Any HTTPS tunnel that forwards to the Remote Access port.")
        }
    }

    /// Start commands, then `offCommands`, to run in order in Terminal. `hostname` is the one
    /// typed for Cloudflare Tunnel and ngrok (`asksForHostname`), never the address in use.
    /// `publicPort` is Funnel's public port (`FunnelPorts.publicPort`); nil when all three serve
    /// other apps, and then Funnel has no command.
    public func commands(port: Int, hostname: String?, names: RemoteNames, publicPort: Int? = 443) -> [String] {
        let name = names.tunnelName
        let start: [String]
        switch self {
        case .tailscaleFunnel:
            guard let publicPort else { return [] }
            return [TailscaleFunnelCommand.start(port: port, publicPort: publicPort)]
                + offCommands(port: port, publicPort: publicPort)
        case .cloudflareTunnel:
            // The port is in config.yml.
            start = [
                "brew install cloudflared", "cloudflared tunnel login", "cloudflared tunnel create \(name)",
                "cloudflared tunnel route dns \(name) \(hostname ?? Self.cloudflareTunnel.hostnamePlaceholder)",
                "cloudflared tunnel run \(name)",
            ]
        case .ngrok:
            start = [
                "ngrok config add-authtoken <your ngrok authtoken>",
                "ngrok http \(port) --url https://\(hostname ?? Self.ngrok.hostnamePlaceholder) --host-header=rewrite",
            ]
        case .cloudflareQuick:
            // Without the rewrite, the random trycloudflare.com Host fails the remote Host check.
            start = ["cloudflared tunnel --url http://127.0.0.1:\(port) --http-host-header 127.0.0.1:\(port)"]
        case .other:
            start = []
        }
        return start + offCommands(port: port)
    }

    /// Only Funnel keeps running in the background; the others stop with Control-C. Funnel's
    /// turns off only its own public port, never another app's.
    public func offCommands(port: Int, publicPort: Int = 443) -> [String] {
        self == .tailscaleFunnel ? [TailscaleFunnelCommand.off(port: port, publicPort: publicPort)] : []
    }

    /// `~/.cloudflared/config.yml` for a named Cloudflare tunnel; nil for the others.
    public func configFile(port: Int, hostname: String?, names: RemoteNames) -> String? {
        guard self == .cloudflareTunnel else { return nil }
        return """
            tunnel: \(names.tunnelName)
            credentials-file: ~/.cloudflared/<tunnel-UUID>.json
            ingress:
              - hostname: \(hostname ?? hostnamePlaceholder)
                service: http://127.0.0.1:\(port)
                originRequest:
                  httpHostHeader: "127.0.0.1:\(port)"
              - service: http_status:404
            """
    }

    /// The one command that starts the tunnel once it's set up, for the Tunnel row's Not running
    /// state. Nil for Other tunnel.
    public func runCommand(port: Int, hostname: String?, names: RemoteNames, publicPort: Int? = 443) -> String? {
        switch self {
        case .tailscaleFunnel, .cloudflareQuick:
            commands(port: port, hostname: hostname, names: names, publicPort: publicPort).first
        case .cloudflareTunnel: "cloudflared tunnel run \(names.tunnelName)"
        case .ngrok: commands(port: port, hostname: hostname, names: names).first { $0.hasPrefix("ngrok http ") }
        case .other: nil
        }
    }

    /// The guide's step 2, after the commands. "Step 3" is the guide's Paste its address.
    public var steps: [String] {
        let paste = { (address: String) in String(localized: "Paste \(address) in step 3.") }
        let controlC = { (tool: String) in
            String(localized: "To turn it off, press Control-C in the Terminal window running \(tool).")
        }
        switch self {
        case .tailscaleFunnel:
            return [
                String(localized: "Install Tailscale on this Mac and sign in."),
                String(localized: "In the Tailscale admin console, turn on MagicDNS and HTTPS certificates, and add the funnel node attribute to your tailnet policy."),
                String(localized: "Run the first command in Terminal. Funnel prints your public address, such as https://my-mac.tail1234.ts.net."),
                paste(String(localized: "that address")) + " " + String(localized: "Public DNS can take about 10 minutes the first time."),
                String(localized: "To turn it off, run the last command."),
            ]
        case .cloudflareTunnel:
            return [
                String(localized: "You need a domain on Cloudflare. The login command opens your browser."),
                String(localized: "Before you run the tunnel, save the configuration as ~/.cloudflared/config.yml, with <tunnel-UUID> replaced by the ID that tunnel create printed."),
                paste(String(localized: "https:// and your hostname")), controlC("cloudflared"),
            ]
        case .ngrok:
            return [
                String(localized: "Sign up at ngrok.com, then put your authtoken and your free dev domain from the dashboard into the commands."),
                paste(String(localized: "https:// and your dev domain")), controlC("ngrok"),
            ]
        case .cloudflareQuick:
            return [
                String(localized: "Run the command. cloudflared prints a random https://….trycloudflare.com address."),
                paste(String(localized: "that address")), controlC("cloudflared"),
            ]
        case .other:
            return [
                String(localized: "Point the tunnel at http://127.0.0.1 and the Remote Access port, never at the port local agents use."),
                String(localized: "Have it rewrite Host to 127.0.0.1 and the port, or keep its public hostname, which must then be the address you paste."),
                paste(String(localized: "its HTTPS address")),
            ]
        }
    }

    /// What to know about the tunnel, below its steps.
    public var notes: [String] {
        let edge = { (provider: String) in
            String(localized: "TLS ends at \(provider)'s edge, so \(provider) can read the traffic, memories included.")
        }
        switch self {
        case .tailscaleFunnel:
            return [
                String(localized: "TLS ends on this Mac, inside Tailscale, so the relays in between can't read the traffic."),
                String(localized: "Funnel keeps the public hostname in Host, so it must match Address."),
                String(localized: "Tailscale Serve isn't enough: cloud agents aren't on your tailnet."),
                String(localized: "Funnel keeps running in the background, even after a restart, until you turn it off."),
                String(localized: "Funnel has three public ports, 443, 8443 and 10000, one app each. The guide uses the first one nothing on this Mac serves yet, so it never replaces another app's tunnel."),
            ]
        case .cloudflareTunnel:
            return [
                edge("Cloudflare"),
                String(localized: "The configuration rewrites Host to this Mac's address."),
                String(localized: "Optionally, put Cloudflare Access service tokens in front for agents that can send two extra headers, such as Cursor, Copilot and Devin."),
            ]
        case .ngrok:
            return [
                edge("ngrok"),
                String(localized: "The free plan allows 20,000 requests a month."),
                String(localized: "Don't turn on ngrok's basic auth: it takes over the Authorization header that carries the token."),
                String(localized: "Optionally, allow only your agent's addresses with a Traffic Policy IP restriction, for example Anthropic's 160.79.104.0/21."),
            ]
        case .cloudflareQuick:
            return [
                String(localized: "For testing only: the address changes every time it starts, which breaks every cloud agent you set up."),
                edge("Cloudflare"),
            ]
        case .other:
            return [
                String(localized: "The tunnel must pass the Authorization header through unchanged."),
                String(localized: "If TLS ends at the provider's edge, the provider can read the traffic."),
            ]
        }
    }
}

// MARK: - Tunnel health

extension TunnelHealth {
    /// The Tunnel row's pill.
    public var label: String {
        switch self {
        case .running: String(localized: "Running")
        case .wrongPort: String(localized: "Wrong port")
        case .notPublic: String(localized: "Not public")
        case .notRunning(let reason):
            reason == .allPortsTaken ? String(localized: "No free port") : String(localized: "Not running")
        case .notInstalled: String(localized: "Not installed")
        case .unknown: String(localized: "Can't check on this Mac")
        }
    }

    /// The text next to the pill. `remotePort` is the Remote Access port, `mcpPort` the local MCP
    /// server's.
    public func detail(_ provider: TunnelProvider, remotePort: Int, mcpPort: Int) -> String? {
        switch self {
        case .running(_, let port):
            return String(localized: "on this Mac · forwards to \(String(port))")
        case .wrongPort(let port, _):
            return port == mcpPort
                ? String(localized: "Forwards to \(String(port)), the local MCP port. Use \(String(remotePort)).")
                : String(localized: "Forwards to \(String(port)). Use \(String(remotePort)).")
        case .notPublic:
            return provider == .tailscaleFunnel
                ? String(localized: "Tailscale Serve is on, but Funnel isn't, so cloud agents can't reach it.")
                : String(localized: "It's reachable only from your own network, so cloud agents can't reach it.")
        case .notRunning(let reason):
            switch reason {
            case .loggedOut: return String(localized: "Tailscale is logged out. Open Tailscale and log in.")
            case .funnelNotAllowed:
                return String(localized: "Your tailnet policy doesn't allow Funnel for this Mac. Add the funnel node attribute in the Tailscale admin console.")
            case .stopped:
                return provider == .tailscaleFunnel
                    ? String(localized: "Tailscale is turned off. Turn it on, then start Funnel.")
                    : String(localized: "\(provider.name) runs, but isn't connected yet.")
            case .noTunnel: return nil
            case .allPortsTaken:
                return String(localized: "Funnel's three public ports already serve other apps on this Mac. Turn one off, or choose another tunnel.")
            }
        case .notInstalled:
            switch provider {
            case .tailscaleFunnel: return String(localized: "Install Tailscale, or choose another tunnel.")
            case .ngrok: return String(localized: "Install ngrok, or choose another tunnel.")
            case .cloudflareTunnel, .cloudflareQuick, .other:
                return String(localized: "Install cloudflared with brew install cloudflared, or choose another tunnel.")
            }
        case .unknown:
            return nil
        }
    }

    /// The Status row's reason when the reachability test failed and this check explains it
    /// ("Tailscale Funnel isn't running on this Mac.").
    public func unreachableReason(_ provider: TunnelProvider, remotePort: Int) -> String? {
        switch self {
        case .notRunning: String(localized: "\(provider.name) isn't running on this Mac.")
        case .wrongPort(let port, _):
            String(localized: "\(provider.name) forwards to port \(String(port)), not \(String(remotePort)).")
        case .notPublic: provider == .tailscaleFunnel
            ? String(localized: "Tailscale Serve is on, but Funnel isn't.")
            : String(localized: "\(provider.name) isn't public.")
        case .notInstalled: String(localized: "\(provider.name) isn't installed on this Mac.")
        case .running, .unknown: nil
        }
    }
}

// MARK: - Funnel's public ports

extension FunnelPorts {
    /// Step 2's line above the commands: why Funnel uses another port than 443, or what's on all
    /// three. Nil when it uses 443 or already runs.
    public func reason(names: RemoteNames) -> String? {
        let taken = inTheWay.map(Self.describe).formatted(.list(type: .and))
        guard !taken.isEmpty else { return nil }
        guard let publicPort else {
            return String(localized: "Funnel already serves other apps on this Mac on \(taken). Starting it would replace one of them, so turn one off first, or choose another tunnel.")
        }
        return inTheWay.count == 1
            ? String(localized: "Funnel already serves another app on this Mac on \(taken), so \(names.appName) uses port \(String(publicPort)). Its address ends in :\(String(publicPort)).")
            : String(localized: "Funnel already serves other apps on this Mac on \(taken), so \(names.appName) uses port \(String(publicPort)). Its address ends in :\(String(publicPort)).")
    }

    /// "port 443 (it forwards to 47616)".
    static func describe(_ entry: Entry) -> String {
        let port = String(entry.publicPort)
        switch entry.targets.count {
        case 0: return String(localized: "port \(port)")
        case 1: return String(localized: "port \(port) (it forwards to \(String(entry.targets[0])))")
        default:
            let targets = entry.targets.map { String($0) }.formatted(.list(type: .and))
            return String(localized: "port \(port) (it forwards to \(targets))")
        }
    }

    /// When the check couldn't read what Funnel serves: the 443 command, with this warning.
    public static func unknownWarning(names: RemoteNames) -> String {
        String(localized: "\(names.appName) couldn't check what Funnel already serves on this Mac. If it serves another app on port 443, this command replaces it: check with tailscale funnel status first.")
    }
}

// MARK: - Switch Tunnel…

extension TunnelSwitch {
    /// The header's name for a step.
    public func title(_ step: Step) -> String {
        switch step {
        case .choose: String(localized: "Choose")
        case .start: String(localized: "Start it")
        case .test: String(localized: "Paste and test")
        case .confirm: kind == .editAddress ? String(localized: "Save") : String(localized: "Switch")
        }
    }
}

// MARK: - Test

extension RemoteProbeFailure {
    /// The Status row's reason when Test didn't reach the app. `port` is the Remote Access port.
    public func reason(appName: String, port: Int) -> String {
        switch self {
        case .noAddress: String(localized: "Add the tunnel's address first.")
        case .invalidAddress: String(localized: "The address isn't valid.")
        case .timedOut: String(localized: "No answer within 10 seconds. Is the tunnel running?")
        case .cannotFindHost:
            String(localized: "The address doesn't resolve yet. A new address can take a few minutes (about 10 for Tailscale Funnel).")
        case .connectionRefused: String(localized: "The tunnel refused the connection.")
        case .certificateRejected: String(localized: "The tunnel's HTTPS certificate wasn't accepted.")
        case .requestFailed(let code): String(localized: "The request failed (\(String(code))).")
        case .wrongHost:
            String(localized: "The tunnel sent a different host name. Check the address, or set the tunnel to rewrite Host.")
        case .notThisApp(let status):
            String(localized: "Something answered at that address, but not \(appName) (HTTP \(String(status))). Check that the tunnel points at port \(String(port)).")
        case .noAnswer: String(localized: "No answer.")
        }
    }
}
