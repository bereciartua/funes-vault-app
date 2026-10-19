import BridgeKitCore
import BridgeKitRemote
import Foundation
import Testing
@testable import BridgeUI

/// Remote Access setup (4b.10, 4b.11), ported from EK Bridge's cloud and tunnel checks in
/// AgentSetupTests: every cloud agent and tunnel byte for byte against fixtures/agent-setup
/// (`cloud-*.txt`, `tunnel-*.txt`; UPDATE_GOLDENS=1 rewrites them), no token or secret in any
/// snippet, tunnel commands on the Remote Access port only, and the words for the typed results.
@Suite("Remote setup")
struct RemoteSetupTests {
    static let cloudURL = "https://my-mac.tail1234.ts.net/r/q7Zk2vN4bXwP9sL1mT6hYa/mcp"
    static let names = RemoteNames.funes
    static let cloud = CloudSetupContext(mcpURL: cloudURL, agentName: "Work agent")
    static let tricky = CloudSetupContext(mcpURL: cloudURL, agentName: #"O'Brien's "cloud" $HOME `x` \ bot"#)
    static let other = CloudSetupContext(mcpURL: "https://other.example.net/r/AAAAAAAAAAAAAAAAAAAAAA/mcp",
                                         serverKey: "test-key", agentName: "Other")
    static let noAddress = CloudSetupContext(mcpURL: nil, agentName: "Work agent")
    static let remotePort = TunnelProvider.defaultRemotePort
    static let mcpPort = 47625
    static let tunnelHost = "my-mac.tail1234.ts.net"

    /// The goldens this suite owns; AgentSetupTests leaves them alone.
    static func isRemoteGolden(_ name: String) -> Bool { name.hasPrefix("cloud-") || name.hasPrefix("tunnel-") }

    static func slug(_ agent: CloudAgent) -> String {
        switch agent {
        case .anthropicAPI: "anthropic-api"
        case .openAIResponses: "openai-responses"
        case .claudeAI: "claude-ai"
        case .chatGPT: "chatgpt"
        default: kebab(agent.rawValue)
        }
    }

    static func slug(_ provider: TunnelProvider) -> String { kebab(provider.rawValue) }

    static func kebab(_ name: String) -> String {
        name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased()
    }

    static func credential(_ agent: CloudAgent) -> String {
        agent.usesOAuth ? "oauth" : agent.usesRemoteToken ? "remote token" : "unsupported"
    }

    /// Everything the user reads for one cloud agent, so wording changes show up in review.
    static func render(_ agent: CloudAgent, _ context: CloudSetupContext) -> String {
        let snippet = CloudSetup.snippet(agent, context: context)
        var lines = [agent.name, "credential: \(credential(agent))", "agentKind: \(agent.agentKind)",
                     "symbol: \(agent.symbol)", "needsLiteralSecret: \(snippet.needsLiteralSecret)", "",
                     "snippet (\(snippet.kind)):", snippet.text]
        for extra in snippet.extraSnippets { lines += ["", "\(extra.title) (\(extra.kind)):", extra.text] }
        lines += ["", "steps:"] + snippet.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        let warnings = agent.warnings(context.names)
        if !warnings.isEmpty { lines += ["", "warnings:"] + warnings.map { "- \($0)" } }
        if let footnote = agent.footnote { lines += ["", "footnote: \(footnote)"] }
        return lines.joined(separator: "\n")
    }

    /// The hostname typed for the tunnels that ask for one (`asksForHostname`).
    static func sampleHost(_ provider: TunnelProvider) -> String? {
        switch provider {
        case .cloudflareTunnel: "funes.example.com"
        case .ngrok: "calm-otter-42.ngrok-free.app"
        default: nil
        }
    }

    /// The public paths for the sample secret.
    static let paths = RemoteConfiguration(secret: "q7Zk2vN4bXwP9sL1mT6hYa", publicOrigin: nil, port: remotePort).publicPaths

    static func render(_ provider: TunnelProvider, publicPort: Int? = 443) -> String {
        let host = sampleHost(provider)
        var lines = [provider.displayName, "name: \(provider.name)", "summary: \(provider.summary)",
                     "preservesHost: \(provider.preservesHost)", "detectionHeader: \(provider.detectionHeader ?? "none")",
                     "installLink: \(provider.installLink ?? "none")", "", "commands:"]
        lines += provider.commands(port: remotePort, hostname: host, names: names, publicPort: publicPort, paths: paths)
        if provider == .tailscaleFunnel, let publicPort {
            lines += ["", "off:"] + provider.offCommands(port: remotePort, publicPort: publicPort, paths: paths)
        }
        let run = provider.runCommand(port: remotePort, hostname: host, names: names, publicPort: publicPort, paths: paths)
        lines += ["", "run: \(run ?? "none")"]
        if let config = provider.configFile(port: remotePort, hostname: host, names: names) {
            lines += ["", "config.yml:", config]
        }
        lines += ["", "steps:"] + provider.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines += ["", "notes:"] + provider.notes.map { "- \($0)" }
        return lines.joined(separator: "\n")
    }

    static func texts(_ agent: CloudAgent, _ context: CloudSetupContext) -> [String] {
        let snippet = CloudSetup.snippet(agent, context: context)
        return [snippet.text] + snippet.extraSnippets.map(\.text) + snippet.steps + agent.warnings(context.names)
            + [agent.footnote ?? "", agent.name]
    }

    static func tunnelTexts(_ provider: TunnelProvider, port: Int = remotePort, hostname: String? = tunnelHost) -> [String] {
        provider.commands(port: port, hostname: hostname, names: names) + provider.steps + provider.notes
            + [provider.configFile(port: port, hostname: hostname, names: names) ?? "",
               provider.runCommand(port: port, hostname: hostname, names: names) ?? "",
               provider.displayName, provider.summary]
    }

    /// What Funnel serves on this Mac, as the Tailscale check reads it: per public port, its
    /// paths (path → local port, keeping the path unless it's `/`) and whether Funnel is on.
    static func funnel(_ entries: [(Int, [(String, Int)], Bool)], tcp: (Int, Int)? = nil) -> FunnelPorts {
        var all = entries.map { port, handlers, funnel in
            FunnelPorts.Entry(publicPort: port, host: tunnelHost,
                              handlers: handlers.map { FunnelPorts.Handler(path: $0.0, port: $0.1, targetPath: $0.0 == "/" ? "" : $0.0) },
                              funnel: funnel)
        }
        if let tcp { all.append(FunnelPorts.Entry(publicPort: tcp.0, host: nil, handlers: [], funnel: true, tcpForward: tcp.1)) }
        return FunnelPorts(entries: all, port: remotePort, paths: paths)
    }

    /// Step 2's line for each situation, and the new states' words.
    static func renderFunnelPorts() -> String {
        let ours = paths.map { ($0, remotePort) }
        let cases: [(String, FunnelPorts)] = [
            ("nothing served", funnel([])),
            ("EK Bridge on / of 443", funnel([(443, [("/", 47616)], true)])),
            ("443 tailnet-only", funnel([(443, [("/", 4000)], false)])),
            ("443 and 8443 tailnet-only", funnel([(443, [("/", 4000)], false), (8443, [("/", 4001)], false)])),
            ("nothing shareable", funnel([(443, [("/", 4000)], false), (8443, [], false)], tcp: (10000, 5432))),
            ("running beside EK Bridge", funnel([(443, [("/", 47616)] + ours, true)])),
            ("three of four paths", funnel([(443, [("/", 47616)] + Array(ours.prefix(3)), true)])),
        ]
        var lines = cases.map { name, ports in
            "\(name): port \(ports.publicPort.map(String.init) ?? "none") · add \(ports.pathsToAdd.count) · "
                + (ports.reason(names: names) ?? "no line")
        }
        let none = TunnelHealth.notRunning(reason: .noSharablePort)
        lines += ["", "unknown: \(FunnelPorts.unknownWarning(names: names))",
                  "no shareable port: \(none.label) · \(none.detail(.tailscaleFunnel, remotePort: remotePort, mcpPort: 47626) ?? "")"]
        for missing in [1, 2] {
            let health = TunnelHealth.incomplete(address: "https://" + tunnelHost, missing: missing)
            lines.append("incomplete \(missing): \(health.label) · \(health.detail(.tailscaleFunnel, remotePort: remotePort, mcpPort: 47626) ?? "") · \(health.unreachableReason(.tailscaleFunnel, remotePort: remotePort) ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/agent-setup")
    }

    @Test func goldens() throws {
        var expected: [String: String] = [:]
        for agent in CloudAgent.allCases { expected["cloud-\(Self.slug(agent)).txt"] = Self.render(agent, Self.cloud) }
        expected["cloud-no-address.txt"] = Self.render(.claudeAI, Self.noAddress)
        for provider in TunnelProvider.allCases { expected["tunnel-\(Self.slug(provider)).txt"] = Self.render(provider) }
        // Funnel shared with other apps on this Mac: another public port, or none free.
        expected["tunnel-tailscale-funnel-8443.txt"] = Self.render(.tailscaleFunnel, publicPort: 8443)
        expected["tunnel-tailscale-funnel-no-shareable-port.txt"] = Self.render(.tailscaleFunnel, publicPort: nil)
        expected["tunnel-funnel-ports.txt"] = Self.renderFunnelPorts()
        let folder = Self.fixtures
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for old in try FileManager.default.contentsOfDirectory(atPath: folder.path) where Self.isRemoteGolden(old) {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(old))
            }
            for (name, text) in expected {
                try (text + "\n").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        let present = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter(Self.isRemoteGolden))
        #expect(present == Set(expected.keys), "goldens: run with UPDATE_GOLDENS=1 after an intended change")
        for (name, text) in expected {
            let golden = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            #expect(golden == text + "\n", "\(name) differs from its golden")
        }
    }

    /// No remote token, OAuth token, client secret or bare 64-hex secret, in any context.
    @Test func noSecrets() throws {
        let secret = try Regex(#"(fns_(mcpr|oat|ort|ocs|mcp)_v1_[0-9a-fA-F])|([0-9a-fA-F]{64})"#)
        var all: [String] = []
        for context in [Self.cloud, Self.tricky, Self.other, Self.noAddress] {
            for agent in CloudAgent.allCases { all += Self.texts(agent, context) }
        }
        for provider in TunnelProvider.allCases { all += Self.tunnelTexts(provider) + Self.tunnelTexts(provider, hostname: nil) }
        for text in all {
            #expect(text.firstMatch(of: secret) == nil, "\(text)")
            for prefix in ["fns_mcpr_v1_", "fns_oat_v1_", "fns_ort_v1_", "fns_ocs_v1_", "fns_mcp_v1_"] {
                #expect(!text.contains(prefix), "\(text)")
            }
            #expect(!text.contains("EK Bridge") && !text.contains("EK_BRIDGE") && !text.contains("ek-bridge"), "\(text)")
            #expect(!text.contains("calendar"), "\(text)")
        }
    }

    @Test func cloudCatalog() {
        #expect(CloudAgent.allCases.count == 11 && TunnelProvider.allCases.count == 5)
        #expect(CloudAgent.allCases.filter(\.usesOAuth) == [.claudeAI, .chatGPT, .geminiEnterprise])
        #expect(CloudAgent.allCases.filter { !$0.isSupported } == [.codexCloud])
        #expect(Set(CloudAgent.allCases.map(\.agentKind)).count == CloudAgent.allCases.count)
        #expect(CloudAgent.claudeAI.agentKind == "claude_ai" && CloudAgent.chatGPT.agentKind == "chatgpt"
            && CloudAgent.geminiEnterprise.agentKind == "gemini_enterprise" && CloudAgent.anthropicAPI.agentKind == "anthropic_api")
        #expect(CloudAgent.allCases.allSatisfy { !$0.symbol.isEmpty && !$0.name.isEmpty })
        #expect(CloudAgent.allCases.filter { $0.preRegisteredRedirectURI != nil } == [.geminiEnterprise])
        for context in [Self.cloud, Self.tricky, Self.other] {
            for agent in CloudAgent.allCases {
                let snippet = CloudSetup.snippet(agent, context: context)
                let key = "\(agent)"
                let url = context.mcpURL!
                #expect(snippet.destination == nil && snippet.installURL == nil && !snippet.skipsListenerCheck, "\(key)")
                #expect(!snippet.steps.isEmpty, "\(key)")
                #expect(snippet.needsLiteralSecret == agent.usesRemoteToken, "\(key)")
                let pieces = [snippet.text] + snippet.extraSnippets.map(\.text)
                if agent.usesRemoteToken {
                    #expect(pieces.allSatisfy { $0.contains(url) }, "\(key)")
                    #expect(context.remoteTokenPlaceholders.contains { snippet.text.contains($0) }, "\(key)")
                    #expect(pieces.joined().contains(context.serverKey), "\(key)")
                    #expect(snippet.steps.contains { $0.contains(Self.names.copyTokenAction) && $0.contains("Cloud section") }, "\(key)")
                } else if agent.usesOAuth {
                    #expect(snippet.text == url, "\(key)")
                    #expect(snippet.steps.contains { $0.contains("Connect a Cloud App…") && $0.contains(context.agentName) }, "\(key)")
                    #expect(agent == .geminiEnterprise || snippet.extraSnippets.isEmpty, "\(key)")
                } else {
                    #expect(snippet.text.isEmpty && agent.footnote != nil && agent.warnings(Self.names).isEmpty, "\(key)")
                    #expect(snippet.steps == ["Codex cloud tasks have no documented way to add an MCP server, so they can't reach Funes Vault."])
                }
                if context.serverKey != "funes" {
                    for text in pieces {
                        for stale in ["\"funes\"", Self.cloudURL, "tail1234"] { #expect(!text.contains(stale), "\(key) contains \(stale)") }
                    }
                }
            }
        }
        #expect(CloudAgent.copilotAgent.warnings(Self.names).contains { $0.contains("read access only") })
        #expect(CloudAgent.claudeCodeCloud.warnings(Self.names).contains { $0.contains("Anyone who uses") })
        #expect(CloudAgent.allCases.filter(\.isSupported).allSatisfy { $0.warnings(Self.names).last == CloudAgent.awayWarning })
    }

    /// Before Remote Access has a public address, every setup says to finish it, except Codex
    /// cloud tasks, which can't connect at all.
    @Test func withoutAnAddress() {
        for agent in CloudAgent.allCases {
            let snippet = CloudSetup.snippet(agent, context: Self.noAddress)
            #expect(snippet.text.isEmpty && snippet.extraSnippets.isEmpty && !snippet.needsLiteralSecret, "\(agent)")
            if agent.isSupported {
                #expect(snippet.steps == ["Finish setting up Remote Access in Funes Vault first. This setup appears once the tunnel's public address is saved."], "\(agent)")
            } else {
                #expect(snippet.steps.first?.contains("can't reach Funes Vault") == true)
            }
        }
    }

    @Test func geminiOAuthSettings() throws {
        let snippet = CloudSetup.snippet(.geminiEnterprise, context: Self.cloud)
        let settings = try #require(snippet.extraSnippets.first)
        #expect(settings.kind == .values)
        #expect(settings.text == """
            Authorization URL: https://my-mac.tail1234.ts.net/r/q7Zk2vN4bXwP9sL1mT6hYa/oauth/authorize
            Token URL: https://my-mac.tail1234.ts.net/r/q7Zk2vN4bXwP9sL1mT6hYa/oauth/token
            Client ID: <Client ID from Set Up OAuth Client…>
            Client secret: <Client secret from Set Up OAuth Client…>
            Scopes: memory
            """)
    }

    @Test func cloudJSON() throws {
        var count = 0
        for context in [Self.cloud, Self.tricky, Self.other] {
            for agent in CloudAgent.allCases {
                let snippet = CloudSetup.snippet(agent, context: context)
                for (kind, text) in [(snippet.kind, snippet.text)] + snippet.extraSnippets.map({ ($0.kind, $0.text) }) where kind == .json {
                    #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any], "\(agent)")
                    count += 1
                }
            }
            let key = context.serverKey
            let copilot = try Self.object(CloudSetup.snippet(.copilotAgent, context: context).text)
            let entry = try #require((copilot["mcpServers"] as? [String: Any])?[key] as? [String: Any])
            #expect(entry["type"] as? String == "http" && entry["url"] as? String == context.mcpURL)
            #expect(entry["tools"] as? [String] == CloudSetupContext.funesReadOnlyTools)
            #expect((entry["headers"] as? [String: String])?["Authorization"] == "Bearer $COPILOT_MCP_FUNES_REMOTE_TOKEN")

            let claudeCode = CloudSetup.snippet(.claudeCodeCloud, context: context)
            let withHeaders = try #require((try Self.object(claudeCode.text)["mcpServers"] as? [String: Any])?[key] as? [String: Any])
            #expect((withHeaders["headers"] as? [String: String])?["Authorization"] == "Bearer ${FUNES_REMOTE_TOKEN}")
            let bare = try #require((try Self.object(claudeCode.extraSnippets[0].text)["mcpServers"] as? [String: Any])?[key] as? [String: Any])
            #expect(bare.keys.sorted() == ["type", "url"] && bare["url"] as? String == context.mcpURL)
        }
        #expect(count == 12)
    }

    /// Each curl snippet through /bin/sh with a stub curl and a fake token in the environment: the
    /// body parses and carries the token exactly, whatever the agent's name holds.
    @Test func curlRoundTrip() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("cloud-curl-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let stub = root.appendingPathComponent("curl")
        try "#!/bin/sh\nprintf '%s\\0' \"$0\" \"$@\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let token = "fake-token-with-'quote-and-$dollar"
        let environment = ["PATH": root.path + ":/usr/bin:/bin", "FUNES_REMOTE_TOKEN": token,
                           "ANTHROPIC_API_KEY": "fake-anthropic", "OPENAI_API_KEY": "fake-openai", "VAULT_ID": "vlt_test"]
        for context in [Self.cloud, Self.tricky] {
            for agent in [CloudAgent.anthropicAPI, .managedAgents, .openAIResponses] {
                let argv = try Self.run(CloudSetup.snippet(agent, context: context).text, environment: environment)
                let data = try #require(argv.firstIndex(of: "-d").map { argv[$0 + 1] })
                let body = try Self.object(data)
                switch agent {
                case .anthropicAPI:
                    #expect(argv[1] == "https://api.anthropic.com/v1/messages" && argv.contains("x-api-key: fake-anthropic"))
                    let server = try #require((body["mcp_servers"] as? [[String: Any]])?.first)
                    #expect(server["authorization_token"] as? String == token && server["url"] as? String == context.mcpURL)
                case .managedAgents:
                    #expect(argv[1] == "https://api.anthropic.com/v1/vaults/vlt_test/credentials")
                    let auth = try #require(body["auth"] as? [String: Any])
                    #expect(auth["token"] as? String == token && auth["type"] as? String == "static_bearer")
                    #expect(auth["mcp_server_url"] as? String == context.mcpURL)
                    #expect((body["display_name"] as? String)?.contains(context.agentName) == true)
                default:
                    #expect(argv.contains("authorization: Bearer fake-openai"))
                    let tool = try #require((body["tools"] as? [[String: Any]])?.first)
                    #expect(tool["authorization"] as? String == token && tool["server_url"] as? String == context.mcpURL)
                    #expect(tool["allowed_tools"] as? [String] == CloudSetupContext.funesReadOnlyTools)
                }
            }
        }
    }

    @Test func tunnelCommands() throws {
        for provider in TunnelProvider.allCases {
            let key = "\(provider)"
            let commands = provider.commands(port: Self.remotePort, hostname: Self.tunnelHost, names: Self.names,
                                             paths: Self.paths)
            let moved = provider.commands(port: 50123, hostname: nil, names: Self.names, paths: Self.paths)
            #expect(commands.isEmpty == (provider == .other), "\(key)")
            if provider != .other {
                // A named Cloudflare tunnel takes the port from config.yml.
                let config = { (port: Int) in [provider.configFile(port: port, hostname: nil, names: Self.names) ?? ""] }
                #expect((commands + config(Self.remotePort)).contains { $0.contains("47627") }, "\(key)")
                #expect((moved + config(50123)).contains { $0.contains("50123") }, "\(key)")
            }
            #expect(!moved.contains { $0.contains("47627") || $0.contains(Self.tunnelHost) }, "\(key)")
            if provider != .tailscaleFunnel {
                #expect(Array(commands.suffix(provider.offCommands(port: Self.remotePort).count)) == provider.offCommands(port: Self.remotePort))
            }
            #expect(!provider.steps.isEmpty && !provider.notes.isEmpty, "\(key)")
            for text in Self.tunnelTexts(provider) + Self.tunnelTexts(provider, hostname: nil) {
                #expect(!text.contains("47625") && !text.contains("47626"), "\(key) points at a local port")
                #expect(!text.contains("47616") && !text.contains("47615"), "\(key) uses EK Bridge's port")
            }
        }
        #expect(TunnelProvider.defaultRemotePort == 47627)
        // Funnel: one command per public path on 443, its off commands apart, each naming the path.
        let funnel = TunnelProvider.tailscaleFunnel.commands(port: Self.remotePort, hostname: nil, names: Self.names,
                                                             paths: Self.paths)
        #expect(funnel.count == 4 && funnel[0] == "tailscale funnel --bg --https=443 --set-path /r/q7Zk2vN4bXwP9sL1mT6hYa "
            + "http://127.0.0.1:47627/r/q7Zk2vN4bXwP9sL1mT6hYa")
        #expect(TunnelProvider.tailscaleFunnel.offCommands(port: Self.remotePort, paths: Self.paths)
            .allSatisfy { $0.hasPrefix("tailscale funnel --https=443 --set-path /") && $0.hasSuffix(" off") })
        #expect(TunnelProvider.tailscaleFunnel.commands(port: Self.remotePort, hostname: nil, names: Self.names).isEmpty,
                "no paths, no Funnel command")
        #expect(TunnelProvider.ngrok.commands(port: Self.remotePort, hostname: nil, names: Self.names)[1]
            == "ngrok http 47627 --url https://<your-dev-domain> --host-header=rewrite")
        #expect(TunnelProvider.cloudflareTunnel.commands(port: Self.remotePort, hostname: nil, names: Self.names)
            .contains("cloudflared tunnel route dns funes-vault mcp.example.com"))
        let config = try #require(TunnelProvider.cloudflareTunnel.configFile(port: 50123, hostname: nil, names: Self.names))
        #expect(config.contains("tunnel: funes-vault") && config.contains("service: http://127.0.0.1:50123")
            && config.contains(#"httpHostHeader: "127.0.0.1:50123""#) && config.contains("hostname: mcp.example.com"))
        #expect(TunnelProvider.allCases.map { $0.configFile(port: 1, hostname: nil, names: Self.names) != nil } == [false, true, false, false, false])
        let run = TunnelProvider.allCases.map {
            $0.runCommand(port: Self.remotePort, hostname: "calm-otter-42.ngrok-free.app", names: Self.names, paths: [Self.paths[0]])
        }
        #expect(run == ["tailscale funnel --bg --https=443 --set-path /r/q7Zk2vN4bXwP9sL1mT6hYa http://127.0.0.1:47627/r/q7Zk2vN4bXwP9sL1mT6hYa",
                        "cloudflared tunnel run funes-vault",
                        "ngrok http 47627 --url https://calm-otter-42.ngrok-free.app --host-header=rewrite",
                        "cloudflared tunnel --url http://127.0.0.1:47627 --http-host-header 127.0.0.1:47627", nil])
        #expect(TunnelProvider.ngrok.notes.contains { $0.contains("20,000") })
        #expect(TunnelProvider.cloudflareQuick.notes[0].contains("testing only"))
        #expect(TunnelProvider.cloudflareTunnel.notes[0] == "TLS ends at Cloudflare's edge, so Cloudflare can read the traffic, memories included.")
        #expect(TunnelProvider.ngrok.inSentence == "ngrok" && TunnelProvider.other.inSentence == "another tunnel")
    }

    @Test func healthWords() {
        let port = Self.remotePort, mcp = Self.mcpPort
        let cases: [(TunnelHealth, TunnelProvider, String, String?, String?)] = [
            (.running(address: "https://\(Self.tunnelHost)", port: port), .tailscaleFunnel, "Running", "on this Mac · forwards to 47627", nil),
            (.wrongPort(port: mcp, address: nil), .tailscaleFunnel, "Wrong port",
             "Forwards to 47625, the local MCP port. Use 47627.", "Tailscale Funnel forwards to port 47625, not 47627."),
            (.wrongPort(port: 8080, address: nil), .ngrok, "Wrong port", "Forwards to 8080. Use 47627.", "ngrok forwards to port 8080, not 47627."),
            (.notPublic(address: nil), .tailscaleFunnel, "Not public",
             "Tailscale Serve is on, but Funnel isn't, so cloud agents can't reach it.", "Tailscale Serve is on, but Funnel isn't."),
            (.notPublic(address: nil), .cloudflareTunnel, "Not public",
             "It's reachable only from your own network, so cloud agents can't reach it.", "Cloudflare Tunnel isn't public."),
            (.notRunning(reason: .stopped), .tailscaleFunnel, "Not running",
             "Tailscale is turned off. Turn it on, then start Funnel.", "Tailscale Funnel isn't running on this Mac."),
            (.notRunning(reason: .stopped), .cloudflareQuick, "Not running",
             "Cloudflare quick tunnel runs, but isn't connected yet.", "Cloudflare quick tunnel isn't running on this Mac."),
            (.notRunning(reason: .loggedOut), .tailscaleFunnel, "Not running",
             "Tailscale is logged out. Open Tailscale and log in.", "Tailscale Funnel isn't running on this Mac."),
            (.notRunning(reason: .funnelNotAllowed), .tailscaleFunnel, "Not running",
             "Your tailnet policy doesn't allow Funnel for this Mac. Add the funnel node attribute in the Tailscale admin console.",
             "Tailscale Funnel isn't running on this Mac."),
            (.notRunning(reason: .noTunnel), .ngrok, "Not running", nil, "ngrok isn't running on this Mac."),
            (.notInstalled, .tailscaleFunnel, "Not installed", "Install Tailscale, or choose another tunnel.", "Tailscale Funnel isn't installed on this Mac."),
            (.notInstalled, .ngrok, "Not installed", "Install ngrok, or choose another tunnel.", "ngrok isn't installed on this Mac."),
            (.notInstalled, .cloudflareTunnel, "Not installed", "Install cloudflared with brew install cloudflared, or choose another tunnel.",
             "Cloudflare Tunnel isn't installed on this Mac."),
            (.unknown, .other, "Can't check on this Mac", nil, nil),
        ]
        for (health, provider, label, detail, reason) in cases {
            #expect(health.label == label, "\(health)")
            #expect(health.detail(provider, remotePort: port, mcpPort: mcp) == detail, "\(health) \(provider)")
            #expect(health.unreachableReason(provider, remotePort: port) == reason, "\(health) \(provider)")
        }
    }

    @Test func probeReasons() {
        let cases: [(RemoteProbeFailure, String)] = [
            (.noAddress, "Add the tunnel's address first."),
            (.invalidAddress, "The address isn't valid."),
            (.timedOut, "No answer within 10 seconds. Is the tunnel running?"),
            (.cannotFindHost, "The address doesn't resolve yet. A new address can take a few minutes (about 10 for Tailscale Funnel)."),
            (.connectionRefused, "The tunnel refused the connection."),
            (.certificateRejected, "The tunnel's HTTPS certificate wasn't accepted."),
            (.requestFailed(code: -1005), "The request failed (-1005)."),
            (.wrongHost, "The tunnel sent a different host name. Check the address, or set the tunnel to rewrite Host."),
            (.notThisApp(status: 404), "Something answered at that address, but not Funes Vault (HTTP 404). Check that the tunnel points at port 47627."),
            (.noAnswer, "No answer."),
        ]
        for (failure, reason) in cases {
            #expect(failure.reason(appName: "Funes Vault", port: Self.remotePort) == reason, "\(failure)")
        }
    }

    @Test func switchTitles() {
        let change = TunnelSwitch(kind: .switchTunnel, fromTunnel: .tailscaleFunnel, fromOrigin: "https://\(Self.tunnelHost)")
        #expect(change.steps.map(change.title) == ["Choose", "Start it", "Paste and test", "Switch"])
        let edit = TunnelSwitch(kind: .editAddress, fromTunnel: .ngrok, fromOrigin: "https://calm-otter-42.ngrok-free.app")
        #expect(edit.steps.map(edit.title) == ["Paste and test", "Save"])
    }

    @Test func funesNames() {
        #expect(RemoteNames.funes == RemoteNames(appName: "Funes Vault", tunnelName: "funes-vault",
                                                 remoteTokenEnvironmentVariable: "FUNES_REMOTE_TOKEN",
                                                 copyTokenAction: "Copy Remote Token…"))
        #expect(Self.cloud.serverKey == "funes" && Self.cloud.scope == "memory" && Self.cloud.names == .funes)
    }

    static func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Runs `command` in /bin/sh and returns the stub curl's NUL-separated argv.
    static func run(_ command: String, environment: [String: String]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }
}
