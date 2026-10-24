import Foundation
import FunesProtocol

/// A small JSON Schema, enough for structured output (model providers §3). It serializes to the
/// strict subset OpenAI-compatible and Anthropic endpoints accept (every object closed, every
/// property required, no numeric, string-length or array-size constraints), and converts to Apple
/// Foundation Models' dynamic schemas. Constraints the wire format can't carry are re-checked by
/// the caller's validation. Properties keep their order on the wire: models generate in that
/// order, so the extraction schema can ask for the evidence before the body (memory processing §5.3).
public indirect enum JSONSchema: Sendable, Hashable {
    case string(description: String? = nil, oneOf: [String]? = nil)
    case boolean(description: String? = nil)
    case number(description: String? = nil)
    case integer(description: String? = nil)
    case array(of: JSONSchema, description: String? = nil, minItems: Int? = nil, maxItems: Int? = nil)
    /// Properties in order; all required.
    case object(name: String, description: String? = nil, properties: [(String, JSONSchema)])

    public static func == (a: JSONSchema, b: JSONSchema) -> Bool { a.json == b.json }
    public func hash(into hasher: inout Hasher) { hasher.combine(json) }

    /// The JSON value, as nested dictionaries and arrays.
    public var wire: [String: Any] {
        switch self {
        case let .string(description, oneOf):
            var o: [String: Any] = ["type": "string"]
            if let description { o["description"] = description }
            if let oneOf { o["enum"] = oneOf }
            return o
        case let .boolean(description):
            return description.map { ["type": "boolean", "description": $0] } ?? ["type": "boolean"]
        case let .number(description):
            return description.map { ["type": "number", "description": $0] } ?? ["type": "number"]
        case let .integer(description):
            return description.map { ["type": "integer", "description": $0] } ?? ["type": "integer"]
        case let .array(items, description, _, _):
            var o: [String: Any] = ["type": "array", "items": items.wire]
            if let description { o["description"] = description }
            return o
        case let .object(_, description, properties):
            var o: [String: Any] = [
                "type": "object", "additionalProperties": false, "required": properties.map(\.0),
                "properties": OrderedJSONObject(properties.map { ($0.0, $0.1.wire) }),
            ]
            if let description { o["description"] = description }
            return o
        }
    }

    /// Canonical JSON text (sorted keys, properties in their order).
    public var json: String { String(decoding: (try? JSONWriter.data(wire)) ?? Data(), as: UTF8.self) }
}

/// A JSON object whose keys go on the wire in this order.
struct OrderedJSONObject: @unchecked Sendable {
    let pairs: [(String, Any)]
    init(_ pairs: [(String, Any)]) { self.pairs = pairs }
}

/// JSON text from dictionaries (sorted keys), `OrderedJSONObject`s (in order), arrays and
/// JSONSerialization's leaf values.
enum JSONWriter {
    static func data(_ value: Any) throws -> Data {
        var out = Data()
        try write(value, to: &out)
        return out
    }

    private static func write(_ value: Any, to out: inout Data) throws {
        switch value {
        case let object as OrderedJSONObject:
            try writeObject(object.pairs, to: &out)
        case let dictionary as [String: Any]:
            try writeObject(dictionary.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, to: &out)
        case let array as [Any]:
            out.append(UInt8(ascii: "["))
            for (i, element) in array.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                try write(element, to: &out)
            }
            out.append(UInt8(ascii: "]"))
        default:
            out.append(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        }
    }

    private static func writeObject(_ pairs: [(String, Any)], to out: inout Data) throws {
        out.append(UInt8(ascii: "{"))
        for (i, (key, element)) in pairs.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            out.append(try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed]))
            out.append(UInt8(ascii: ":"))
            try write(element, to: &out)
        }
        out.append(UInt8(ascii: "}"))
    }
}

/// A structured-output request: instructions (system), the user text passed as quoted data, and
/// the schema the answer must follow. The same prompt goes to every provider.
public struct StructuredRequest<Output: Decodable & Sendable>: Sendable {
    public var instructions: String
    public var prompt: String
    public var schema: JSONSchema
    public var maxOutputTokens: Int
    public var outputType: Output.Type { Output.self }

    public init(instructions: String, prompt: String, schema: JSONSchema, maxOutputTokens: Int = 1_024) {
        self.instructions = instructions
        self.prompt = prompt
        self.schema = schema
        self.maxOutputTokens = maxOutputTokens
    }

    /// Every text the request would send, for the guardrails.
    public var outgoingTexts: [String] { [instructions, prompt] }

    public var schemaName: String {
        if case let .object(name, _, _) = schema { return name }
        return "output"
    }
}

/// Token counts from a provider's response, where it reports them.
public struct ProviderUsage: Sendable, Hashable, Codable {
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int

    public init(requests: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// How a provider call failed. Messages never carry request or response text, only codes.
public enum ProviderError: Error, Sendable, Equatable {
    /// Not configured, not supported on this Mac, or the model can't load.
    case unavailable
    /// 401/403: "Unavailable: check API key".
    case unauthorized
    /// 429, with the `retry-after` seconds when given.
    case rateLimited(retryAfter: TimeInterval?)
    /// 5xx, 529 or another unexpected status.
    case server(status: Int)
    /// The response wasn't the JSON the schema promised.
    case invalidOutput
    /// The model declined.
    case refused
    case timeout
    /// A cloud endpoint over plain HTTP (model providers §5.5).
    case insecureEndpoint
    /// Funes didn't send it: the text matched the secret scanner, or is above the cloud limit
    /// (model providers §5). Nothing left the Mac.
    case blocked
    case transport
    /// Funes didn't send it: today's cloud request cap, or the agents' share of it, is used up
    /// (ADR-0022). Nothing left the Mac.
    case capReached
}

/// A model that answers structured requests (model providers §3).
public protocol GenerationProvider: Sendable {
    var id: ProviderID { get }
    var locality: Locality { get }
    /// The model id, recorded with each proposal ("anthropic/<model>").
    var modelID: String { get }
    func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage)
}

/// Runs `operation`, failing with `ProviderError.timeout` after `limit`.
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw ProviderError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw ProviderError.timeout }
        return first
    }
}
