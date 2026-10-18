import BridgeKitCore
import Foundation
@testable import FunesCore
@testable import FunesMCP
import FunesProtocol
import Synchronization
import Testing

/// The tool contract (task 2.7): the shipped `mcp-tools.json` matches the golden fixture byte
/// for byte, and visibility follows the agent's operations (mcp-server.md §6).
@Suite("Tool contract")
struct ContractTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/mcp/fixtures/tools.json")

    @Test func matchesGoldenByteForByte() throws {
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
            try FunesTools.contractData.write(to: Self.fixture)
        }
        let golden = try Data(contentsOf: Self.fixture)
        #expect(golden == FunesTools.contractData, "Tests/mcp/fixtures/tools.json differs; run with UPDATE_GOLDENS=1")
    }

    @Test func fiveToolsInOrder() {
        #expect(FunesTools.contract.tools.map(\.name)
            == ["list_memory_categories", "request_memory", "get_memory_request", "suggest_memory", "open_in_funes"])
        #expect(FunesTools.contract.serverInstructions.contains("request_memory"))
    }

    @Test func requestMemoryHasOptionalKeywords() throws {
        let tool = try #require(FunesTools.contract.tool(named: "request_memory"))
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let keywords = try #require(properties["keywords"] as? [String: Any])
        #expect(keywords["maxItems"] as? Int == 20)
        #expect((tool.inputSchema["required"] as? [String]) == ["task"])
        #expect((tool.definition["description"] as? String)?.contains("5–15 keywords") == true)
    }

    @Test func annotations() {
        let writes = FunesTools.contract.tools.filter(\.isWrite).map(\.name)
        #expect(writes == ["suggest_memory"])
    }

    struct Visibility: Sendable, CustomTestStringConvertible {
        let operations: Set<AccessOperation>
        let expected: [String]
        var testDescription: String { operations.map(\.rawValue).sorted().joined(separator: "+") }
    }

    static let always = ["list_memory_categories", "open_in_funes"]
    static let visibilityCases: [Visibility] = [
        Visibility(operations: [], expected: always),
        Visibility(operations: [.read], expected: ["list_memory_categories", "request_memory", "get_memory_request",
                                                   "open_in_funes"]),
        Visibility(operations: [.suggest], expected: ["list_memory_categories", "suggest_memory", "open_in_funes"]),
        Visibility(operations: [.write], expected: ["list_memory_categories", "suggest_memory", "open_in_funes"]),
        Visibility(operations: [.read, .suggest, .write],
                   expected: ["list_memory_categories", "request_memory", "get_memory_request", "suggest_memory",
                              "open_in_funes"]),
    ]

    @Test(arguments: visibilityCases)
    func visibility(_ row: Visibility) {
        #expect(FunesTools.visibleTools(access: Access(operations: row.operations)).map(\.name) == row.expected)
    }

    @Test func unknownAgentFailsClosed() {
        #expect(FunesTools.visibleTools(access: nil).map(\.name) == ["list_memory_categories", "open_in_funes"])
    }

    @Test func schemaCountsCharacters() throws {
        let tool = try #require(FunesTools.contract.tool(named: "request_memory"))
        let task = String(repeating: "é", count: 1_000)
        #expect(JSONSchemaValidator.validate(["task": task], against: tool.inputSchema, counting: .unicodeScalars) == nil)
        #expect(JSONSchemaValidator.validate(["task": task + "é"], against: tool.inputSchema, counting: .unicodeScalars)
            == "task: must be at most 1000 characters, got 1001")
    }
}

/// The result size limit (mcp-server.md §9): the largest bundle a request can return, with every
/// character escaped twice, still makes a JSON-RPC response under 200,000 bytes.
@Suite("Result size")
struct ResultSizeTests {
    @Test func theLargestBundleFitsTheLimit() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let pattern = "\"\u{1}\\\n日😀"
        let memories = (0..<8).map { i in
            Memory(title: String(repeating: "\"", count: 180), body: String(String(repeating: pattern, count: 2_000).prefix(10_000)),
                   kind: .fact, categoryKeys: ["software_development"], sensitivity: .low, source: .manual,
                   createdAt: t0, updatedAt: t0)
        }
        let bundle = BundleCompiler.compile(memories, maxTokens: InputLimits.maxTokens.upperBound)
        #expect(!bundle.items.isEmpty)
        let withheld = Dictionary(uniqueKeysWithValues: ReasonCode.allCases.map { ($0, 9_999) })
        let outcome = RequestOutcome(status: .delivered, requestID: UUID(), bundle: bundle, withheld: withheld,
                                     maxTokens: InputLimits.maxTokens.upperBound)
        let result = RequestPipeline.output(outcome)
        let response = JSONRPC.encode(["jsonrpc": "2.0", "id": String(repeating: "9", count: 64), "result": result.json])
        #expect(response.count <= BundleCompiler.maxResultBytes, "\(response.count) bytes")
    }

    /// The complete response body as BridgeKit writes it, in the modern era (which adds
    /// `resultType` and `_meta`), echoing the request's id unchanged.
    static func response(id: JSONRPCID, _ result: ToolResult) -> Data {
        var json = result.json
        json["resultType"] = "complete"
        json["_meta"] = ["io.modelcontextprotocol/serverInfo": ["name": "funes", "version": "0.1.0-preview.99"]]
        return JSONRPC.result(id: id, json)
    }

    static func fulfilled(_ memories: [Memory], maxTokens: Int) -> ToolResult {
        let bundle = BundleCompiler.compile(memories, maxTokens: maxTokens)
        let withheld = Dictionary(uniqueKeysWithValues: ReasonCode.allCases.map { ($0, 9_999) })
        return RequestPipeline.output(RequestOutcome(status: .fulfilled, requestID: UUID(), bundle: bundle,
                                                     withheld: withheld, maxTokens: maxTokens))
    }

    static let configuration = FunesMCPConfiguration.server(dataFolder: URL(fileURLWithPath: "/tmp"), version: "0")

    /// Ids exactly at Funes's cap, as the response writes them: plain, and all escapes (`\"`).
    static var idsAtTheCap: [JSONRPCID] {
        let cap = configuration.maxIDBytes
        return [.string(String(repeating: "r", count: cap - 2)), .string(String(repeating: "\"", count: (cap - 2) / 2))]
    }

    /// The room bundles keep for the id covers the longest id BridgeKit lets through, so raising
    /// the cap or shrinking the room fails here.
    @Test func theIDRoomCoversTheIDCap() {
        #expect(Self.configuration.maxIDBytes == JSONRPC.defaultMaxIDBytes)
        #expect(BundleCompiler.requestIDBytes >= Self.configuration.maxIDBytes)
        for id in Self.idsAtTheCap { #expect(id.encodedByteCount == Self.configuration.maxIDBytes) }
    }

    /// PR #5 review 4307609724, as reproduced: three memories titled `M` with 10,000, 10,000 and
    /// 3,500 emoji and `max_tokens` 8,000, with a 20,000-character id, made a 210,099-byte response.
    /// Such an id is now refused (below); with the longest id accepted, the response fits.
    @Test func theReviewersBundleWithAnIDAtTheCapFitsTheLimit() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let memories = [10_000, 10_000, 3_500].map { count in
            Memory(title: "M", body: String(repeating: "😀", count: count), kind: .fact,
                   categoryKeys: ["personal_preferences"], sensitivity: .public, source: .manual,
                   createdAt: t0, updatedAt: t0)
        }
        let result = Self.fulfilled(memories, maxTokens: 8_000)
        let content = try #require(result.json["structuredContent"] as? [String: Any])
        #expect((content["items"] as? [Any])?.count == 3)
        for id in Self.idsAtTheCap {
            let response = Self.response(id: id, result)
            #expect(response.count <= BundleCompiler.maxResultBytes, "\(response.count) bytes")
        }
    }

    /// The worst case: the largest bundle, every character escaped, every withheld count, and an
    /// id at the cap. The whole response stays within 200,000 bytes.
    @Test func theLargestBundleWithAnIDAtTheCapFitsTheLimit() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let pattern = "\"\u{1}\\\n日😀"
        let memories = (0..<8).map { _ in
            Memory(title: String(repeating: "\"", count: 180), body: String(String(repeating: pattern, count: 2_000).prefix(10_000)),
                   kind: .fact, categoryKeys: ["software_development"], sensitivity: .low, source: .manual,
                   createdAt: t0, updatedAt: t0)
        }
        let result = Self.fulfilled(memories, maxTokens: InputLimits.maxTokens.upperBound)
        for id in Self.idsAtTheCap {
            let response = Self.response(id: id, result)
            #expect(response.count <= BundleCompiler.maxResultBytes, "\(response.count) bytes")
        }
    }

    /// Not only tool results: `initialize` and `tools/list` echo the id too.
    @Test func protocolResultsWithAnIDAtTheCapFitTheLimit() {
        let results: [[String: Any]] = [
            ["tools": FunesTools.contract.tools.map(\.definition)],
            ["instructions": FunesTools.contract.serverInstructions, "capabilities": ["tools": ["listChanged": false]]],
        ]
        for result in results {
            let response = Self.response(id: Self.idsAtTheCap[0], ToolResult(result))
            #expect(response.count <= BundleCompiler.maxResultBytes, "\(response.count) bytes")
        }
    }
}

/// Funes's MCP server with BridgeKit 0.1.1's id cap (PR #5 review 4307609724): an id longer than
/// 1,024 encoded bytes is refused with -32600 and `"id": null` before any tool runs; one at the cap
/// reaches the pipeline and is echoed.
@Suite("Request id cap")
@MainActor
struct RequestIDCapTests {
    struct Accept: AgentAuthenticator {
        func authenticate(_ key: PresentedKey) async -> AuthenticationOutcome {
            .authenticated(AuthenticatedAgent(id: UUID().uuidString.lowercased(), name: "Test"))
        }
    }

    final class Recorder: BridgeHandler {
        let calls = Mutex(0)
        func handle(_ call: ToolCall) async -> ToolResult {
            calls.withLock { $0 += 1 }
            return ToolOutput.make(["status": "fulfilled"])
        }
    }

    /// One `tools/call` through Funes's configuration, as the listener hands it over.
    func send(id: JSONRPCID, handler: Recorder) async throws -> (status: Int, body: [String: Any]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("funes-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = FunesMCPConfiguration.server(dataFolder: directory, version: "0")
        let server = MCPServer(configuration: configuration, authenticator: Accept(),
                               tools: FunesTools(store: try VaultStore.open(directory: directory)), handler: handler,
                               limiter: RateLimiter(policy: configuration.limits), counters: MCPTrafficCounters())
        let body = JSONRPC.encode(["jsonrpc": "2.0", "id": id.json, "method": "tools/call",
                                   "params": ["name": "request_memory", "arguments": ["task": "Plan the week"]]])
        let request = HTTPRequest(method: "POST", target: "/mcp", path: "/mcp", version: "HTTP/1.1",
                                  headers: [("content-type", "application/json"), ("mcp-protocol-version", "2025-11-25")],
                                  body: body)
        let reply = await withCheckedContinuation { (continuation: CheckedContinuation<MCPServer.Reply, Never>) in
            server.handle(request, key: "unused", whenClosed: { _ in {} }, reply: { continuation.resume(returning: $0) })
        }
        let json = try #require(try JSONSerialization.jsonObject(with: reply.response.body) as? [String: Any])
        return (reply.response.status, json)
    }

    /// 1,023 characters is 1,025 bytes with its quotes, one over; 20,000 is the reviewer's id.
    @Test(arguments: [JSONRPC.defaultMaxIDBytes - 1, 20_000])
    func longIDsAreRefused(characters: Int) async throws {
        let handler = Recorder()
        let (status, body) = try await send(id: .string(String(repeating: "r", count: characters)), handler: handler)
        #expect(status == 400)
        #expect(body["id"] is NSNull)
        #expect((body["error"] as? [String: Any])?["code"] as? Int == JSONRPC.invalidRequest)
        #expect(handler.calls.withLock { $0 } == 0)
    }

    @Test func anIDAtTheCapReachesThePipeline() async throws {
        let handler = Recorder()
        for id in ResultSizeTests.idsAtTheCap {
            let (status, body) = try await send(id: id, handler: handler)
            #expect(status == 200)
            #expect(body["id"] as? String == (id.json as? String))
        }
        #expect(handler.calls.withLock { $0 } == 2)
    }
}
