import BridgeKitCore
import Foundation
import FunesCore
@testable import FunesMCP
import FunesProtocol
import Synchronization
import Testing

/// Every active memory, and a record of what retrieval was asked.
final class RecordingRetriever: MemoryRetriever {
    let store: VaultStore
    private let asked = Mutex<[String]>([])

    init(store: VaultStore) { self.store = store }

    func candidateIDs(task: String, keywords: [String], categories: [String]) async throws -> [UUID] {
        asked.withLock { $0.append([task, keywords.joined(separator: ","), categories.joined(separator: ",")].joined(separator: "|")) }
        let wanted = Set(categories)
        return try store.memories(MemoryFilter(), now: Date())
            .filter { wanted.isEmpty || !wanted.isDisjoint(with: $0.categoryKeys) }.map(\.id)
    }

    var inputs: [String] { asked.withLock { $0 } }
}

/// Answers nothing: requests that need approval time out (the wait is short in these tests).
final class SilentPresenter: FunesPresenter {
    func showApproval(requestID: UUID, agentID: UUID) async {}
    func showSuggestion(suggestionID: UUID, agentID: UUID) async {}
    func askForAccess(_ prompt: AccessPrompt) async -> AccessAnswer { .notNow }
    func open(requestID: UUID) async {}
    func open(suggestionID: UUID) async {}
}

/// Phase 4b, task 4b.13 (ADR-0018 decision 2): `RequestPipeline`, and the FunesCore services and
/// `PolicyEngine` behind it, get the same inputs for a local and a remote call, so `ToolCall.remote`
/// only changes Activity's `via`. Each case runs the same call once per channel, each on a fresh vault,
/// and compares the results and the Activity rows field by field, ids aside.
@Suite("Remote calls: the same inputs as local ones")
struct RemoteSameInputsTests {
    struct Run {
        var result: [String: Any]
        var retrieval: [String]
        var rows: [ActivityEvent]
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let tool: String
        let arguments: [String: String]
        let categories: [String]
        let access: Access
        var testDescription: String { tool + " " + arguments.keys.sorted().joined(separator: ",") }
    }

    static let cases: [Case] = [
        Case(tool: "list_memory_categories", arguments: [:], categories: [],
             access: Access(operations: [.read], maxSensitivity: .internal, askBeforeSharing: false)),
        Case(tool: "request_memory", arguments: ["task": "Set up a TypeScript project"], categories: [],
             access: Access(operations: [.read], maxSensitivity: .internal, askBeforeSharing: false)),
        Case(tool: "request_memory", arguments: ["task": "Plan dinner"], categories: ["health"],
             access: Access(operations: [.read], maxSensitivity: .internal, askBeforeSharing: false)),
        Case(tool: "request_memory", arguments: ["task": "Needs a yes"], categories: [],
             access: Access(operations: [.read], maxSensitivity: .internal, askBeforeSharing: true)),
        Case(tool: "request_memory", arguments: ["task": "Not allowed"], categories: [], access: Access()),
        Case(tool: "suggest_memory", arguments: ["title": "Prefers dark mode", "body": "Dark mode everywhere."],
             categories: ["personal_preferences"], access: Access(operations: [.suggest], maxSensitivity: .internal)),
        Case(tool: "suggest_memory", arguments: ["title": "Uses Zed", "body": "Zed as the editor."],
             categories: ["software_development"],
             access: Access(operations: [.write], maxSensitivity: .internal, askBeforeSaving: false)),
    ]

    @Test(arguments: cases)
    func sameInputs(_ row: Case) async throws {
        let local = try await run(row, remote: false)
        let remote = try await run(row, remote: true)
        #expect(Self.normalized(local.result) == Self.normalized(remote.result))
        #expect(local.retrieval == remote.retrieval)
        #expect(local.rows.count == remote.rows.count && !local.rows.isEmpty)
        for (l, r) in zip(local.rows, remote.rows) {
            #expect(l.event == r.event && l.outcome == r.outcome && l.reason == r.reason && l.counts == r.counts
                    && l.ids.count == r.ids.count && l.approval == r.approval && l.phase == r.phase)
            #expect(l.via == .mcp && r.via == .remote)
        }
    }

    /// One fresh vault, one agent, one call.
    func run(_ row: Case, remote: Bool) async throws -> Run {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("funes-same-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore.open(directory: directory)
        let activity = InMemoryActivityLog()
        let pause = FunesPause()
        let retriever = RecordingRetriever(store: store)
        let agents = AgentService(store: store, issuer: BridgeKitKeyIssuer(), keys: AgentKeyFileStore(dataFolder: directory),
                                  activity: activity)
        let disclosures = DisclosureService(store: store, retriever: retriever, activity: activity, pause: pause)
        let suggestions = SuggestionService(store: store, activity: activity, pause: pause, disclosures: disclosures)
        let now = Date()
        for (title, body, category, sensitivity) in [
            ("Prefers pnpm", "pnpm and Vitest.", "software_development", Sensitivity.low),
            ("Coffee", "Flat white.", "personal_preferences", .public),
            ("Allergy", "Penicillin.", "health", .sensitive),
            ("Launch", "v0.1 ships.", "project_context", .internal),
        ] {
            _ = try store.createMemory(MemoryDraft(title: title, body: body, categoryKeys: [category],
                                                   sensitivity: sensitivity), now: now)
        }
        let (agent, _) = try await agents.create(name: "Agent", kind: .other, access: row.access, now: now)
        try await agents.setCloudAccess(agentID: agent.id, true, now: now)
        let pipeline = RequestPipeline(
            services: FunesServices(store: store, agents: agents, disclosures: disclosures, suggestions: suggestions,
                                    pause: pause, activity: activity),
            presenter: SilentPresenter(), limiter: RateLimiter(policy: FunesMCPConfiguration.limits),
            inCallWait: .milliseconds(300))
        let start = activity.events.count
        var arguments: [String: Any] = row.arguments
        if !row.categories.isEmpty { arguments["categories"] = row.categories }
        let call = ToolCall(name: row.tool, arguments: arguments,
                            agent: AuthenticatedAgent(id: agent.id.uuidString.lowercased(), name: "Agent"),
                            agentName: "Some Agent 1.0", remote: remote, context: CallContext())
        let result = await pipeline.handle(call)
        return Run(result: result.json, retrieval: retriever.inputs, rows: Array(activity.events.dropFirst(start)))
    }

    /// The result as JSON text without ids, which differ per vault. The memory text is left out of
    /// the comparison here (the Python harness compares it); every other item field stays.
    static func normalized(_ json: [String: Any]) -> String {
        func strip(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                var out = [String: Any]()
                for (key, item) in object where !["request_id", "memory_id", "suggestion_id", "now", "text"].contains(key) {
                    out[key] = strip(item)
                }
                return out
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        let data = (try? JSONSerialization.data(withJSONObject: strip(json), options: [.sortedKeys])) ?? Data()
        // Ids inside messages too ("call get_memory_request with request_id …").
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", with: "<id>",
                                  options: .regularExpression)
    }
}
