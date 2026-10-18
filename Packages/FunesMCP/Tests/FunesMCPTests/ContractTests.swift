import BridgeKitCore
import Foundation
@testable import FunesCore
@testable import FunesMCP
import FunesProtocol
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
    static func response(id: String, _ result: ToolResult) -> Data {
        var json = result.json
        json["resultType"] = "complete"
        json["_meta"] = ["io.modelcontextprotocol/serverInfo": ["name": "funes", "version": "0.1.0-preview.99"]]
        return JSONRPC.result(id: .string(id), json)
    }

    static func fulfilled(_ memories: [Memory], maxTokens: Int) -> ToolResult {
        let bundle = BundleCompiler.compile(memories, maxTokens: maxTokens)
        let withheld = Dictionary(uniqueKeysWithValues: ReasonCode.allCases.map { ($0, 9_999) })
        return RequestPipeline.output(RequestOutcome(status: .fulfilled, requestID: UUID(), bundle: bundle,
                                                     withheld: withheld, maxTokens: maxTokens))
    }

    /// PR #5 review 4307609724, as reproduced: three memories titled `M` with 10,000, 10,000 and
    /// 3,500 emoji, `max_tokens` 8,000 and a JSON-RPC id of 20,000 characters made a 210,099-byte
    /// response. The id is echoed, so the bundle has to leave room for it.
    @Test func aLongRequestIDStillFitsTheLimit() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let memories = [10_000, 10_000, 3_500].map { count in
            Memory(title: "M", body: String(repeating: "😀", count: count), kind: .fact,
                   categoryKeys: ["personal_preferences"], sensitivity: .public, source: .manual,
                   createdAt: t0, updatedAt: t0)
        }
        let result = Self.fulfilled(memories, maxTokens: 8_000)
        let content = try #require(result.json["structuredContent"] as? [String: Any])
        #expect((content["items"] as? [Any])?.isEmpty == false)
        let response = Self.response(id: String(repeating: "r", count: 20_000), result)
        #expect(response.count <= BundleCompiler.maxResultBytes, "\(response.count) bytes")
    }

    /// The room kept for the id covers every id the transport accepts: none can be longer than
    /// the request body it came in.
    @Test func theIDRoomCoversTheBodyLimit() {
        let http = FunesMCPConfiguration.server(dataFolder: URL(fileURLWithPath: "/tmp"), version: "0").http
        #expect(BundleCompiler.requestIDBytes >= http.maxBodyBytes)
    }

    /// Echoed ids are never escaped more than they arrived (raw control characters aren't valid
    /// JSON), so an id's echo is no longer than its share of the request body. Each piece is JSON
    /// source text.
    @Test(arguments: ["r", "\\\"", "\\\\", "\\u0001", "\\n", "\\/", "日", "\\ud83d\\ude00", "\u{7F}", "\u{2028}"])
    func echoedIDsAreNoLongerThanSent(_ piece: String) throws {
        let id = String(repeating: piece, count: 1_000)
        let body = Data(#"{"jsonrpc":"2.0","id":""#.utf8) + Data(id.utf8) + Data(#"","method":"ping"}"#.utf8)
        guard case .success(.request(let parsed, _, _)) = JSONRPC.parse(body) else {
            Issue.record("not parsed")
            return
        }
        let sent = body.count - #"{"jsonrpc":"2.0","id":,"method":"ping"}"#.utf8.count
        let echoed = JSONRPC.encode(["id": parsed.json]).count - #"{"id":}"#.utf8.count
        #expect(echoed <= sent, "\(echoed) > \(sent)")
    }

    /// The worst case: the largest bundle, every character escaped, every withheld count, and the
    /// longest id that fits the request body. The whole response stays within 200,000 bytes.
    @Test func theLargestBundleWithTheLongestIDFitsTheLimit() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let pattern = "\"\u{1}\\\n日😀"
        let memories = (0..<8).map { _ in
            Memory(title: String(repeating: "\"", count: 180), body: String(String(repeating: pattern, count: 2_000).prefix(10_000)),
                   kind: .fact, categoryKeys: ["software_development"], sensitivity: .low, source: .manual,
                   createdAt: t0, updatedAt: t0)
        }
        let longest = String(repeating: "r", count: BundleCompiler.requestIDBytes - 2)
        let response = Self.response(id: longest, Self.fulfilled(memories, maxTokens: InputLimits.maxTokens.upperBound))
        #expect(response.count <= BundleCompiler.maxResultBytes, "\(response.count) bytes")
    }

    /// Not only tool results: `initialize` and `tools/list` echo the id too.
    @Test func protocolResultsWithTheLongestIDFitTheLimit() {
        let longest = String(repeating: "r", count: BundleCompiler.requestIDBytes - 2)
        let results: [[String: Any]] = [
            ["tools": FunesTools.contract.tools.map(\.definition)],
            ["instructions": FunesTools.contract.serverInstructions, "capabilities": ["tools": ["listChanged": false]]],
        ]
        for result in results {
            let response = Self.response(id: longest, ToolResult(result))
            #expect(response.count <= BundleCompiler.maxResultBytes, "\(response.count) bytes")
        }
    }
}
