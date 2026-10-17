import BridgeKitCore
import Darwin
import Foundation
import FunesCore
import FunesMCP
import FunesProtocol

// funes-mcp-test-server: the FUNES_MCP_TEST build. The real listener, gate, MCP server,
// pipeline, handlers, vault and key files, on a temporary vault, with a fake approval
// responder instead of panels. Offline: loopback only. Tests/mcp/mcp_test.py drives it.
//
// Environment:
// - FUNES_MCP_TEST_DIR: a private temp folder (required); the vault and agent-keys go here.
// - FUNES_MCP_TEST_PORT: default 0, any free port.
// - FUNES_MCP_TEST_WAIT: the in-call approval wait in seconds (default 45).
// - FUNES_MCP_TEST_APPROVAL: how the fake responder answers panels: none (default; answer
//   with the control channel), allow or deny.
//
// Prints {"port":…,"agents":{name:{"id","key"}},"memories":{name:id}} on stdout, then answers
// one JSON control command per stdin line, and exits when stdin closes.

/// Every active memory, in creation order, narrowed by category: retrieval quality isn't what
/// this harness tests (the policy is), so it doesn't depend on the embedding model.
struct AllMemories: MemoryRetriever {
    let store: VaultStore
    let ids: [UUID]

    func candidateIDs(task: String, keywords: [String], categories: [String]) async throws -> [UUID] {
        let memories = try store.memories(ids: ids).filter { $0.status == .active }
        let wanted = Set(categories)
        return memories.filter { wanted.isEmpty || !wanted.isDisjoint(with: $0.categoryKeys) }.map(\.id)
    }
}

/// Answers panels as FUNES_MCP_TEST_APPROVAL says, or waits for the control channel.
final class FakeResponder: FunesPresenter, @unchecked Sendable {
    private let lock = NSLock()
    var mode = "none"
    var disclosures: DisclosureService!
    private(set) var shown = [UUID]()
    private(set) var suggestions = [UUID]()
    private(set) var opened = [String]()
    /// How access requests are answered: "notnow" (the default), "once" or "always".
    var accessMode = "notnow"
    private(set) var accessPrompts = [AccessPrompt]()

    func showApproval(requestID: UUID, agentID: UUID) async {
        let mode = lock.withLock { () -> String in
            shown.append(requestID)
            return self.mode
        }
        switch mode {
        case "allow": _ = await answer(requestID, allow: true)
        case "deny": _ = await answer(requestID, allow: false)
        default: break
        }
    }

    func showSuggestion(suggestionID: UUID, agentID: UUID) async {
        lock.withLock { suggestions.append(suggestionID) }
    }

    func askForAccess(_ prompt: AccessPrompt) async -> AccessAnswer {
        let mode = lock.withLock { () -> String in
            accessPrompts.append(prompt)
            return accessMode
        }
        switch mode {
        case "once": return prompt.allowsOnce ? .allowOnce : .notNow
        case "always": return .alwaysAllow
        default: return .notNow
        }
    }

    func open(requestID: UUID) async { lock.withLock { opened.append("request:" + requestID.uuidString.lowercased()) } }
    func open(suggestionID: UUID) async {
        lock.withLock { opened.append("suggestion:" + suggestionID.uuidString.lowercased()) }
    }

    /// Shares every memory the panel shows (or `count` of them), or denies.
    func answer(_ requestID: UUID, allow: Bool, count: Int? = nil) async -> Bool {
        do {
            if allow {
                guard let panel = try await disclosures.panel(requestID: requestID, now: Date()) else { return false }
                let ids = panel.memories.map(\.id).prefix(count ?? panel.memories.count)
                try await disclosures.approve(requestID: requestID, snapshotRevision: panel.snapshotRevision,
                                              memoryIDs: Array(ids), now: Date())
            } else {
                try await disclosures.deny(requestID: requestID, now: Date())
            }
            return true
        } catch {
            return false
        }
    }

    var latest: UUID? { lock.withLock { shown.last } }
    var snapshot: (shown: Int, suggestions: Int, opened: [String], access: [AccessPrompt]) {
        lock.withLock { (shown.count, suggestions.count, opened, accessPrompts) }
    }
}

@MainActor
final class Harness {
    let directory: URL
    let store: VaultStore
    let activity = InMemoryActivityLog()
    let pause = FunesPause()
    let keys: AgentKeyFileStore
    let agents: AgentService
    let disclosures: DisclosureService
    let suggestions: SuggestionService
    let responder = FakeResponder()
    var server: FunesMCPServer!
    var agentIDs = [String: UUID]()
    var memoryIDs = [String: UUID]()
    var lastPort = 0

    init(directory: URL) throws {
        self.directory = directory
        store = try VaultStore.open(directory: directory)
        keys = AgentKeyFileStore(dataFolder: directory)
        agents = AgentService(store: store, issuer: BridgeKitKeyIssuer(), keys: keys, activity: activity)
        let now = Date()
        // Memories across categories and sensitivities; health is SENSITIVE by default.
        for (name, title, body, categories, sensitivity) in [
            ("pnpm", "Prefers pnpm and Vitest", "Use pnpm for packages and Vitest for tests.", ["software_development"], Sensitivity?.none),
            ("swift", "Writes Swift 6", "New Mac code is Swift 6 with strict concurrency.", ["software_development"], .low),
            ("coffee", "Coffee", "Flat white, oat milk, no sugar.", ["personal_preferences"], .public),
            ("allergy", "Allergic to penicillin", "Penicillin allergy since childhood.", ["health"], nil),
            ("project", "Funes launch", "Funes v0.1 ships as a Mac preview.", ["project_context"], .internal),
        ] {
            let memory = try store.createMemory(MemoryDraft(title: title, body: body, categoryKeys: categories,
                                                            sensitivity: sensitivity), now: now)
            memoryIDs[name] = memory.id
        }
        disclosures = DisclosureService(store: store, retriever: AllMemories(store: store, ids: Array(memoryIDs.values)),
                                        activity: activity, pause: pause)
        suggestions = SuggestionService(store: store, activity: activity, pause: pause, disclosures: disclosures)
        responder.disclosures = disclosures
    }

    /// - reader: reads up to INTERNAL without asking.
    /// - asker: reads with approval (ask before sharing).
    /// - suggester: suggests only (queued for review).
    /// - writer: reads and writes without asking (saved directly).
    /// - narrow: reads Software Development only, with approval.
    /// - none: nothing; sees list_memory_categories and open_in_funes.
    /// - expired: reads, but its access expired.
    func makeAgents() async throws -> [String: [String: String]] {
        let now = Date()
        var result = [String: [String: String]]()
        let presets: [(String, Access)] = [
            ("reader", Access(operations: [.read], maxSensitivity: .internal, askBeforeSharing: false)),
            ("asker", Access(operations: [.read], maxSensitivity: .internal, askBeforeSharing: true)),
            ("suggester", Access(operations: [.suggest], maxSensitivity: .internal)),
            ("writer", Access(operations: [.read, .write], maxSensitivity: .internal, askBeforeSharing: false,
                              askBeforeSaving: false)),
            ("narrow", Access(operations: [.read, .suggest], maxSensitivity: .internal,
                              allowedCategoryKeys: ["software_development"], askBeforeSharing: true)),
            ("none", Access()),
            ("expired", Access(operations: [.read], maxSensitivity: .internal, askBeforeSharing: false,
                               expiresAt: now.addingTimeInterval(-60))),
        ]
        // Let it ask for more access (access policy §7): Software Development only, no ceiling to
        // speak of, so everything else is withheld only for its category.
        let narrowRead = Access(operations: [.read], maxSensitivity: .secret, allowedCategoryKeys: ["software_development"],
                                askBeforeSharing: false)
        let asking: [(String, Access)] = [
            ("asknotnow", narrowRead), ("askonce", narrowRead), ("askalways", narrowRead), ("askshared", narrowRead),
            ("asksuggest", Access(operations: [.suggest], maxSensitivity: .internal,
                                  allowedCategoryKeys: ["software_development"])),
            ("askwriter", Access(operations: [.write], maxSensitivity: .internal, allowedCategoryKeys: ["software_development"],
                                 askBeforeSaving: false)),
        ]
        for (name, access) in asking {
            let (agent, key) = try await agents.create(name: name, kind: .claudeCode, access: access, asksForAccess: true,
                                                       now: now)
            agentIDs[name] = agent.id
            result[name] = ["id": agent.id.uuidString.lowercased(), "key": key.plaintext]
        }
        for (name, access) in presets {
            let (agent, key) = try await agents.create(name: name, kind: .claudeCode, access: access, now: now)
            agentIDs[name] = agent.id
            result[name] = ["id": agent.id.uuidString.lowercased(), "key": key.plaintext]
        }
        return result
    }

    func control(_ command: [String: Any]) async -> [String: Any] {
        let agent = (command["agent"] as? String).flatMap { agentIDs[$0] }
        let now = Date()
        switch command["cmd"] as? String {
        case "approval":
            responder.mode = command["mode"] as? String ?? "none"
            return ["ok": true]
        case "answer":
            guard let id = responder.latest else { return ["ok": false] }
            let ok = await responder.answer(id, allow: command["decision"] as? String != "deny",
                                            count: command["count"] as? Int)
            return ["ok": ok]
        case "presented":
            let snapshot = responder.snapshot
            return ["approvals": snapshot.shown, "suggestions": snapshot.suggestions, "opened": snapshot.opened,
                    "access": snapshot.access.map { ["category": $0.categoryKey ?? "", "operation": $0.operation.rawValue,
                                                     "task": $0.task ?? "",
                                                     "allows_once": $0.allowsOnce] }]
        case "access":
            responder.accessMode = command["mode"] as? String ?? "notnow"
            return ["ok": true]
        case "pause":
            if command["on"] as? Bool ?? true { pause.pause(until: .distantFuture) } else { pause.resume() }
            return ["ok": true]
        case "agent_pause":
            guard let agent else { return ["ok": false] }
            do {
                if command["on"] as? Bool ?? true {
                    try await agents.pause(agentID: agent, now: now)
                } else {
                    try await agents.resume(agentID: agent, now: now)
                }
                return ["ok": true]
            } catch { return ["ok": false] }
        case "remove":
            guard let agent else { return ["ok": false] }
            do { try await agents.remove(agentID: agent, now: now); return ["ok": true] } catch { return ["ok": false] }
        case "rotate":
            guard let agent else { return ["ok": false] }
            do {
                let key = try await agents.rotateKey(agentID: agent, now: now)
                return ["ok": true, "key": key.plaintext]
            } catch { return ["ok": false] }
        case "inbox":
            let pending = (try? await suggestions.pending()) ?? []
            return ["pending": pending.count,
                    "titles": pending.map(\.title)]
        case "memory_count":
            let count = (try? store.memories(MemoryFilter(), now: now).count) ?? -1
            return ["count": count]
        case "edit_memory":
            // A memory changed after approval: delivery must refuse it (policy_changed).
            guard let name = command["memory"] as? String, let id = memoryIDs[name],
                  let memory = try? store.memory(id: id) else { return ["ok": false] }
            var edit = MemoryEdit()
            edit.body = memory.body + " (edited)"
            return ["ok": (try? store.updateMemory(id: id, edit, now: now)) != nil]
        case "activity":
            return ["activity": activity.events.reversed().map { event -> [String: Any] in
                var row: [String: Any] = ["event": event.event, "actor": event.actor, "via": event.via.rawValue]
                if let outcome = event.outcome { row["outcome"] = outcome }
                if let reason = event.reason { row["reason"] = reason.rawValue }
                if !event.ids.isEmpty { row["ids"] = event.ids.map { $0.uuidString.lowercased() } }
                if !event.counts.isEmpty { row["counts"] = event.counts }
                return row
            }]
        case "connection":
            guard let agent, let connection = server.connections[agent.uuidString.lowercased()] else {
                return ["connection": NSNull()]
            }
            return ["connection": ["agent": connection.agent as Any? ?? NSNull()]]
        case "counters":
            let snapshot = server.counters.snapshot
            return ["requests": snapshot.requests, "authFailures": snapshot.authFailures]
        case "stop":
            server.stop()
            return ["ok": true]
        case "start":
            server.start(port: command["port"] as? Int ?? lastPort)
            return ["ok": true]
        default:
            return ["error": "unknown command"]
        }
    }
}

enum Output {
    static func line(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
func startControl(_ harness: Harness) {
    let box = Unchecked(harness)
    Thread.detachNewThread {
        while let line = readLine() {
            let command = Unchecked((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:])
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                Output.line(await box.value.control(command.value))
                done.signal()
            }
            done.wait()
        }
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value.server.stop()
            done.signal()
        }
        done.wait()
        exit(0)
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let environment = ProcessInfo.processInfo.environment
guard let path = environment["FUNES_MCP_TEST_DIR"] else {
    FileHandle.standardError.write(Data("FUNES_MCP_TEST_DIR is required\n".utf8))
    exit(2)
}
Task { @MainActor in
    do {
        let harness = try Harness(directory: URL(fileURLWithPath: path, isDirectory: true))
        harness.responder.mode = environment["FUNES_MCP_TEST_APPROVAL"] ?? "none"
        let agents = try await harness.makeAgents()
        let wait = Double(environment["FUNES_MCP_TEST_WAIT"] ?? "") ?? 45
        let services = FunesServices(store: harness.store, agents: harness.agents, disclosures: harness.disclosures,
                                     suggestions: harness.suggestions, pause: harness.pause, activity: harness.activity)
        harness.server = FunesMCPServer(services: services, presenter: harness.responder,
                                        dataFolder: harness.directory, version: "0.0.0-test",
                                        inCallWait: .milliseconds(Int(wait * 1000)))
        var announced = false
        harness.server.statusChanged = { status in
            switch status {
            case .listening(let port):
                harness.lastPort = port
                if !announced {
                    announced = true
                    Output.line(["port": port, "agents": agents,
                                 "memories": harness.memoryIDs.mapValues { $0.uuidString.lowercased() }])
                    startControl(harness)
                }
            case .failed(let failure):
                if !announced {
                    FileHandle.standardError.write(Data("listener failed: \(failure)\n".utf8))
                    exit(1)
                }
            default: break
            }
        }
        harness.server.start(port: Int(environment["FUNES_MCP_TEST_PORT"] ?? "0") ?? 0)
    } catch {
        FileHandle.standardError.write(Data("harness failed: \(error)\n".utf8))
        exit(1)
    }
}
// The main run loop, not dispatchMain(): Swift 6's main-actor checks need the main thread.
let keepAlive = Timer(timeInterval: 86_400, repeats: true) { _ in }
RunLoop.main.add(keepAlive, forMode: .default)
while true { RunLoop.main.run() }
