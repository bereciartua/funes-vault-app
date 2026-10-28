import Foundation
import FunesProtocol
import Synchronization
@testable import FunesCore

/// A splitting provider with scripted answers: extraction pieces per call, and decisions built
/// from the decision prompt. Records every request it gets.
final class ScriptedSplitter: GenerationProvider {
    let id: ProviderID
    let locality: Locality
    let modelID: String

    struct Request: Sendable {
        let schema: String
        let instructions: String
        let prompt: String
    }

    /// One piece as a model would return it.
    static func piece(_ body: String, quote: String? = nil, title: String? = nil, kind: String = "fact",
                      categories: [String] = ["personal_preferences"], sensitivity: String = "low", intent: String = "assertion",
                      atomic: Bool = true, confidence: Double = 0.9) -> [String: Any] {
        ["evidence": [quote ?? body], "body": body, "title": title ?? String(body.prefix(60)), "kind": kind,
         "categoryKeys": categories, "sensitivity": sensitivity, "timeLimited": false, "intent": intent, "atomic": atomic,
         "confidence": confidence]
    }

    private let extract: @Sendable (Int, String) -> [[String: Any]]
    /// (piece index, the memories listed for it as (alias, "title. body"), the prompt) → a decision or nil.
    private let decide: @Sendable (Int, [(String, String)], String) -> [String: Any]?
    let requests = Mutex<[Request]>([])
    let failure = Mutex<ProviderError?>(nil)

    init(id: ProviderID = "anthropic", locality: Locality = .cloud, modelID: String = "claude-test",
         extract: @escaping @Sendable (Int, String) -> [[String: Any]],
         decide: @escaping @Sendable (Int, [(String, String)], String) -> [String: Any]? = { _, _, _ in nil }) {
        self.id = id
        self.locality = locality
        self.modelID = modelID
        self.extract = extract
        self.decide = decide
    }

    var all: [Request] { requests.withLock { $0 } }
    var extractions: [Request] { requests.withLock { $0.filter { $0.schema == "Extraction" } } }
    var decisions: [Request] { requests.withLock { $0.filter { $0.schema == "Decisions" } } }

    func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        let n = requests.withLock { r -> Int in
            r.append(Request(schema: request.schemaName, instructions: request.instructions, prompt: request.prompt))
            return r.filter { $0.schema == request.schemaName }.count - 1
        }
        if let failure = failure.withLock({ $0 }) { throw failure }
        let object: Any
        if request.schemaName == "Extraction" {
            object = ["pieces": extract(n, request.prompt)]
        } else {
            object = ["decisions": Self.pieces(in: request.prompt).compactMap { index, memories in
                decide(index, memories, request.prompt).map { d in d.merging(["piece": index]) { a, _ in a } }
            }]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return (try HTTPClient.decode(json, as: T.self), ProviderUsage(requests: 1))
    }

    /// The decision prompt's pieces, each with its memories as (alias, "title. body").
    static func pieces(in prompt: String) -> [(Int, [(String, String)])] {
        var out: [(Int, [(String, String)])] = []
        for line in prompt.split(separator: "\n").map(String.init) {
            if let m = SpikeE.regex(#"^<piece index="(\d+)""#).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(m.range(at: 1), in: line), let i = Int(line[r]) {
                out.append((i, []))
            } else if let m = SpikeE.regex(#"^- (m\d+) \(created [^)]*\) title: (.*?) \| body: (.*)$"#).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let a = Range(m.range(at: 1), in: line), let t = Range(m.range(at: 2), in: line),
                      let b = Range(m.range(at: 3), in: line), !out.isEmpty {
                out[out.count - 1].1.append((String(line[a]), "\(line[t]). \(line[b])"))
            }
        }
        return out
    }
}

/// A processor over `v` with `provider` as the New memories engine, splitting on.
func splittingProcessor(_ v: TestVault, _ provider: any GenerationProvider, log: InMemoryActivityLog = InMemoryActivityLog(),
                        cloudLimit: CloudLimit = .upTo(.internal), cap: CloudRequestCap? = nil, onDevice: (any GenerationProvider)? = nil,
                        autoApply: NewMemoryAutoApply = NewMemoryAutoApply(),
                        split: Bool = true, now: Date = t0) -> NewMemoryProcessor {
    let router = ModelRouter(classifier: provider, onDevice: onDevice, cloudLimit: cloudLimit, cap: cap)
    return NewMemoryProcessor(store: v.store, captures: CaptureService(store: v.store, activity: log), now: { now },
                              configuration: { .init(router: router, split: split, autoApply: autoApply) })
}
