import BridgeKitCore
import Foundation
import FunesCore
@testable import FunesMCP
import FunesProtocol
import Synchronization
import Testing

/// Retrieval that waits until the test releases it with the candidates to return, so a quit can
/// land while `request_memory` is still retrieving.
final class SuspendedRetriever: MemoryRetriever {
    private let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let released: AsyncStream<[UUID]>
    private let releaseContinuation: AsyncStream<[UUID]>.Continuation

    init() {
        (entered, enteredContinuation) = AsyncStream.makeStream()
        (released, releaseContinuation) = AsyncStream.makeStream()
    }

    func candidateIDs(task: String, keywords: [String], categories: [String]) async throws -> [UUID] {
        enteredContinuation.yield()
        for await ids in released { return ids }
        return []
    }

    /// Returns once retrieval has started.
    func waitUntilRetrieving() async {
        for await _ in entered { return }
    }

    func release(_ ids: [UUID]) { releaseContinuation.yield(ids) }
}

/// Panels as the app shows them: an access request waits until it's answered or withdrawn, and
/// the Share panel waits for the user (the pipeline's own wait ends on quit). It doesn't refuse
/// anything after `withdrawAll()`, so these tests check the pipeline's own guard.
final class WaitingPresenter: FunesPresenter {
    private struct State {
        var accessPrompts = [AccessPrompt]()
        var approvals = [UUID]()
        var open = [CheckedContinuation<AccessAnswer, Never>]()
    }
    private let state = Mutex(State())

    func showApproval(requestID: UUID, agentID: UUID) async { state.withLock { $0.approvals.append(requestID) } }
    func showSuggestion(suggestionID: UUID, agentID: UUID) async {}
    func open(requestID: UUID) async {}
    func open(suggestionID: UUID) async {}

    func askForAccess(_ prompt: AccessPrompt) async -> AccessAnswer {
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.accessPrompts.append(prompt)
                $0.open.append(continuation)
            }
        }
    }

    /// What the app does on quit: every open panel is withdrawn (answered Not Now).
    func withdrawAll() {
        let open = state.withLock { state in
            defer { state.open.removeAll() }
            return state.open
        }
        for continuation in open { continuation.resume(returning: .notNow) }
    }

    var accessPrompts: [AccessPrompt] { state.withLock { $0.accessPrompts } }
    var approvals: [UUID] { state.withLock { $0.approvals } }
}

/// Quitting while a call is still retrieving (PR #5 review, comment 4307518013; mcp-server.md
/// §7): no panel appears after the quit began, and the call answers `funes_quit` at once instead
/// of waiting for a panel no one will see until the app's quit deadline cuts it off. The Python
/// harness covers quitting with a Share panel already open (`run_quit`).
@Suite("Quit during retrieval")
struct QuitDuringRetrievalTests {
    struct Case: Sendable, CustomTestStringConvertible {
        /// True: the request also has a memory to approve, so it waits in Pending requests.
        let asksBeforeSharing: Bool
        var testDescription: String { asksBeforeSharing ? "needs approval" : "denied" }
    }

    @Test(arguments: [Case(asksBeforeSharing: false), Case(asksBeforeSharing: true)])
    func noAccessPromptAfterQuit(_ row: Case) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("funes-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore.open(directory: directory)
        let activity = InMemoryActivityLog()
        let pause = FunesPause()
        let retriever = SuspendedRetriever()
        let agents = AgentService(store: store, issuer: BridgeKitKeyIssuer(), keys: AgentKeyFileStore(dataFolder: directory),
                                  activity: activity)
        let disclosures = DisclosureService(store: store, retriever: retriever, activity: activity, pause: pause)
        let suggestions = SuggestionService(store: store, activity: activity, pause: pause, disclosures: disclosures)
        let now = Date()
        let inside = try store.createMemory(MemoryDraft(title: "Writes Swift 6", body: "Strict concurrency.",
                                                        categoryKeys: ["software_development"], sensitivity: .low), now: now)
        let outside = try store.createMemory(MemoryDraft(title: "Coffee", body: "Flat white.",
                                                         categoryKeys: ["personal_preferences"], sensitivity: .public), now: now)
        // Software Development only, and it may ask for more (access policy §7).
        let (agent, _) = try await agents.create(
            name: "Narrow", kind: .claudeCode,
            access: Access(operations: [.read], maxSensitivity: .secret, allowedCategoryKeys: ["software_development"],
                           askBeforeSharing: row.asksBeforeSharing),
            asksForAccess: true, now: now)
        let presenter = WaitingPresenter()
        let pipeline = RequestPipeline(
            services: FunesServices(store: store, agents: agents, disclosures: disclosures, suggestions: suggestions,
                                    pause: pause, activity: activity),
            presenter: presenter, limiter: RateLimiter(), inCallWait: .seconds(60))
        let call = ToolCall(name: "request_memory", arguments: ["task": "Set up a Swift package"],
                            agent: AuthenticatedAgent(id: agent.id.uuidString.lowercased(), name: "Narrow"),
                            agentName: nil, remote: false, context: CallContext())

        let started = ContinuousClock.now
        let inFlight = Task { await pipeline.handle(call) }
        await retriever.waitUntilRetrieving()
        // The app's quit: the pipeline first, then the open panels.
        pipeline.quit()
        presenter.withdrawAll()
        retriever.release(row.asksBeforeSharing ? [inside.id, outside.id] : [outside.id])

        // Promptly: well inside the 3 s the app holds its quit for. If it doesn't answer, withdraw
        // the late panel so the test ends, and fail.
        let answered = await withTaskGroup(of: ToolResult?.self) { group -> ToolResult? in
            group.addTask { await inFlight.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            defer { group.cancelAll() }
            if let first = await group.next(), let result = first { return result }
            presenter.withdrawAll()
            return nil
        }
        let elapsed = ContinuousClock.now - started

        #expect(presenter.accessPrompts.isEmpty, "an access request was shown after the quit began")
        #expect(presenter.approvals.isEmpty, "a Share panel was shown after the quit began")
        let result = try #require(answered, "the call didn't answer within 2 s of the quit")
        #expect(elapsed < .seconds(2))
        let content = try #require(result.json["structuredContent"] as? [String: Any])
        #expect(content["status"] as? String == "denied")
        #expect(content["reason"] as? String == ReasonCode.funesQuit.rawValue)
        #expect(result.json["isError"] as? Bool == true)
        if row.asksBeforeSharing {
            // Still waiting in Pending requests, for get_memory_request after a relaunch.
            let id = try #require((content["request_id"] as? String).flatMap(UUID.init(uuidString:)))
            #expect(try await disclosures.disclosure(requestID: id)?.status == .needsApproval)
            #expect((content["message"] as? String)?.contains("get_memory_request") == true)
        } else {
            #expect(content["request_id"] == nil)
        }
        #expect(activity.events.contains { $0.reason == .funesQuit })
    }
}
