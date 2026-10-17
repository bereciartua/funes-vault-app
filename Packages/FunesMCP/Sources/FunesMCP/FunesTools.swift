import BridgeKitCore
import Foundation
import FunesCore
import FunesProtocol

/// The five tools of `mcp-tools.json` and who sees which (mcp-server.md §6, "Tool visibility").
@MainActor
public final class FunesTools: ToolRegistry {
    /// The contract as shipped: loaded at launch, compared byte for byte with the golden fixture.
    public nonisolated static let contractData: Data = {
        guard let url = Bundle.module.url(forResource: "mcp-tools", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("mcp-tools.json is missing from the FunesMCP bundle")
        }
        return data
    }()

    public nonisolated static let contract: ToolContract = {
        do { return try ToolContract(json: contractData) } catch {
            preconditionFailure("mcp-tools.json isn't a valid tool contract")
        }
    }()

    private let store: VaultStore

    public init(store: VaultStore) {
        self.store = store
    }

    public var serverInstructions: String { Self.contract.serverInstructions }

    public func tool(named name: String) -> ToolDefinition? { Self.contract.tool(named: name) }

    /// A paused or expired agent sees the same list; its calls are refused with a reason.
    /// Fails closed: an agent that can't be read sees only the always-visible tools.
    public func visibleTools(for agent: AuthenticatedAgent) -> [ToolDefinition] {
        let access = UUID(uuidString: agent.id).flatMap { try? store.agent(id: $0) }.map(\.access)
        return Self.visibleTools(access: access)
    }

    public nonisolated static func visibleTools(access: Access?) -> [ToolDefinition] {
        let operations = access?.operations ?? []
        return contract.tools.filter { tool in
            switch tool.name {
            case "request_memory", "get_memory_request": operations.contains(.read)
            case "suggest_memory": operations.contains(.suggest) || operations.contains(.write)
            default: true
            }
        }
    }

    public func failureResult(_ failure: ToolFailure, tool: String, arguments: [String: Any]?) -> ToolResult {
        switch failure {
        case .invalidArguments(let detail):
            ToolOutput.denied(.invalidInput, message: detail, isError: true)
        case .timeout:
            ToolOutput.make(["status": "denied", "reason": "timeout",
                             "message": "Funes Vault didn't answer in time. Try again in a moment."], isError: true)
        }
    }
}

/// Builds `tools/call` results: the output object as `structuredContent` and as JSON text.
enum ToolOutput {
    static func make(_ object: [String: Any], isError: Bool = false) -> ToolResult {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return ToolResult(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                           "structuredContent": object, "isError": isError])
    }

    static func denied(_ reason: ReasonCode, message: String? = nil, isError: Bool = false,
                       extra: [String: Any] = [:]) -> ToolResult {
        var object: [String: Any] = ["status": "denied", "reason": reason.rawValue,
                                     "message": message ?? Messages.text(for: reason)]
        object.merge(extra) { _, new in new }
        return make(object, isError: isError)
    }
}
