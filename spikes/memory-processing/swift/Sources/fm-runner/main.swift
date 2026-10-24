// Spike E: Apple Foundation Models (on-device) for the Python harness.
// Reads one JSON request per stdin line: {id, instructions, prompt, schema, guardrails?, maxTokens?}
// and writes one JSON response per stdout line: {id, ok, content?, error?, errorKind?, tokens..., ms}.
// The schema is a JSON Schema subset (object, array, string with enum, number, integer, boolean),
// converted to a DynamicGenerationSchema as FunesCore's AppleFoundationGenerator does.
import Foundation
import FoundationModels

struct SchemaError: Error { let message: String }

final class SchemaBuilder {
    private var counter = 0

    func build(_ node: [String: Any], name: String) throws -> DynamicGenerationSchema {
        let description = node["description"] as? String
        if let options = node["enum"] as? [String] {
            counter += 1
            return DynamicGenerationSchema(name: "\(name)Choice\(counter)", description: description, anyOf: options)
        }
        switch node["type"] as? String {
        case "string": return DynamicGenerationSchema(type: String.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            guard let items = node["items"] as? [String: Any] else { throw SchemaError(message: "array without items") }
            return DynamicGenerationSchema(arrayOf: try build(items, name: name + "Item"),
                                           minimumElements: node["minItems"] as? Int, maximumElements: node["maxItems"] as? Int)
        case "object":
            let props = node["properties"] as? [String: Any] ?? [:]
            let order = node["x-order"] as? [String] ?? props.keys.sorted()
            counter += 1
            let properties = try order.map { key -> DynamicGenerationSchema.Property in
                let child = props[key] as? [String: Any] ?? [:]
                return DynamicGenerationSchema.Property(name: key, description: child["description"] as? String,
                                                        schema: try build(child, name: key.capitalized))
            }
            return DynamicGenerationSchema(name: "\(name)\(counter)", description: description, properties: properties)
        default: throw SchemaError(message: "unsupported type \(node["type"] ?? "nil")")
        }
    }
}

func errorKind(_ error: Error) -> String {
    if let e = error as? LanguageModelSession.GenerationError {
        switch e {
        case .exceededContextWindowSize: return "context_window"
        case .guardrailViolation: return "guardrail"
        case .refusal: return "refusal"
        case .decodingFailure: return "decoding"
        case .unsupportedLanguageOrLocale: return "language"
        case .rateLimited: return "rate_limited"
        case .concurrentRequests: return "concurrent"
        case .assetsUnavailable: return "assets"
        case .unsupportedGuide: return "unsupported_guide"
        @unknown default: return "generation_other"
        }
    }
    if error is SchemaError { return "schema" }
    return "other"
}

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

@main
struct Runner {
    static func main() async {
        let defaultModel = SystemLanguageModel.default
        let permissive = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        emit(["ready": true, "availability": "\(defaultModel.availability)", "contextSize": defaultModel.contextSize])
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = req["id"] as? String ?? ""
            let instructions = req["instructions"] as? String ?? ""
            let prompt = req["prompt"] as? String ?? ""
            let schemaJSON = req["schema"] as? [String: Any] ?? [:]
            let model = (req["guardrails"] as? String) == "permissive" ? permissive : defaultModel
            var out: [String: Any] = ["id": id]
            let start = Date()
            do {
                let schemaText = String(data: try JSONSerialization.data(withJSONObject: schemaJSON), encoding: .utf8) ?? ""
                out["instructionTokens"] = try await model.tokenCount(for: instructions)
                out["promptTokens"] = try await model.tokenCount(for: prompt)
                out["schemaTokens"] = try await model.tokenCount(for: schemaText)
                let schema = try GenerationSchema(root: SchemaBuilder().build(schemaJSON, name: "Root"), dependencies: [])
                let session = LanguageModelSession(model: model, instructions: instructions)
                var options = GenerationOptions(sampling: .greedy)
                if let max = req["maxTokens"] as? Int { options.maximumResponseTokens = max }
                let response = try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: true, options: options)
                let content = response.content.jsonString
                out["ok"] = true
                out["content"] = content
                out["outputTokens"] = try await model.tokenCount(for: content)
            } catch {
                out["ok"] = false
                out["errorKind"] = errorKind(error)
                out["error"] = String(describing: error).prefix(500).description
            }
            out["ms"] = Int(Date().timeIntervalSince(start) * 1000)
            emit(out)
        }
    }
}
