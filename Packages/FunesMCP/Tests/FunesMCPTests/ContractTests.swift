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
}
