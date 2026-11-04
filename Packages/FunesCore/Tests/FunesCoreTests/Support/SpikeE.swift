import Foundation
import FunesProtocol
import GRDB
import Synchronization
@testable import FunesCore

/// Spike E's synthetic fixtures (spikes/memory-processing/fixtures, exported by
/// `export_recordings.py`) and a provider that replays one model's recorded outputs.
enum SpikeE {
    struct Link: Decodable {
        let decision: [String]
        let target: [String]
    }
    struct Expected: Decodable {
        let claim: String
        let keys: [String]
        let link: Link
        let optional: Bool?
        let intent: [String]?
    }
    struct MustNot: Decodable {
        let label: String
        let all: [String]?
        let none: [String]?
        let intent: String?
        let retract: String?
    }
    struct Hint: Decodable {
        let seedId: String
        let kind: String
        let category: String
        let sensitivity: String?
    }
    struct Input: Decodable {
        let id: String
        let type: String
        let variant: String
        let text: String
        let expected: [Expected]
        let mustNot: [MustNot]
        let expectRejected: String?
        let declaredSensitivity: String?
        let hint: Hint?
        let tags: [String]?
        let singleClaim: Bool?
    }
    struct InputsFile: Decodable {
        let now: String
        let inputs: [Input]
    }
    struct VaultMemory: Decodable {
        let id: String
        let title: String
        let body: String
        let kind: String
        let categories: [String]
        let sensitivity: String
        let createdAt: String
        let updatedAt: String
        let source: String
        let trust: String
    }
    struct VaultFile: Decodable { let memories: [VaultMemory] }

    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "fixtures/processing") else {
            throw VaultError.notFound
        }
        return url
    }

    static func inputs(_ set: String = "inputs") throws -> InputsFile {
        try JSONDecoder().decode(InputsFile.self, from: Data(contentsOf: url(set)))
    }

    static func vault() throws -> [VaultMemory] {
        try JSONDecoder().decode(VaultFile.self, from: Data(contentsOf: url("vault"))).memories
    }

    static func day(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(text.prefix(10)))!.addingTimeInterval(12 * 3_600)
    }

    /// The 200 vault memories in a fresh vault, at their dates. Returns fixture id → memory id.
    static func loadVault(into v: TestVault) throws -> [String: UUID] {
        var ids: [String: UUID] = [:]
        try v.store.writer.write { db in
            for m in try vault() {
                let memory = try MemoryStore.insert(db, MemoryDraft(
                    title: m.title, body: m.body, kind: MemoryKind(rawValue: m.kind)!, categoryKeys: m.categories,
                    sensitivity: Sensitivity(name: m.sensitivity)!, source: m.source == "agent_write" ? .agentWrite : .manual,
                    trust: MemoryTrust(rawValue: m.trust)), actor: .user, now: day(m.createdAt))
                try db.execute(sql: "UPDATE memory SET updated_at = ? WHERE id = ?", arguments: [day(m.updatedAt), memory.id.db])
                ids[m.id] = memory.id
            }
        }
        return ids
    }

    static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        regex(pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Replays a model's recorded Spike E outputs: the extraction of each chunk in order, and the
/// decisions, with the vault's `mNNN` targets mapped to the aliases the prompt gave them.
final class RecordedProvider: GenerationProvider {
    let id: ProviderID
    let locality: Locality
    let modelID: String

    struct Recording: @unchecked Sendable {
        let extract: [Any]
        let decisions: [[String: Any]]
        let keptPieces: Int
    }
    struct Seen: Sendable {
        var input: String?
        var chunk = 0
        var variants: [String: String] = [:]
        var calls: [String: Int] = [:]
        var prompts: [String] = []
    }

    let recordings: [String: Recording]
    /// Fixture id → "title. body", as the decision prompt writes a memory.
    let memoryText: [String: String]
    let seen = Mutex(Seen())

    init(name: String = "claude-opus", id: ProviderID = "anthropic", locality: Locality = .cloud,
         modelID: String = "claude-opus-5-5") throws {
        self.id = id
        self.locality = locality
        self.modelID = modelID
        let data = try Data(contentsOf: SpikeE.url("recorded-\(name)"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var recordings: [String: Recording] = [:]
        for (key, value) in root["inputs"] as! [String: [String: Any]] {
            recordings[key] = Recording(extract: value["extract"] as! [Any], decisions: value["decisions"] as! [[String: Any]],
                                        keptPieces: value["keptPieces"] as! Int)
        }
        self.recordings = recordings
        memoryText = Dictionary(uniqueKeysWithValues: try SpikeE.vault().map { ($0.id, "\($0.title). \($0.body)") })
    }

    /// The next calls are for this input.
    func begin(_ input: String) {
        seen.withLock {
            $0.input = input
            $0.chunk = 0
        }
    }

    func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        let (input, chunk) = seen.withLock { s -> (String?, Int) in
            s.prompts.append(request.prompt)
            return (s.input, s.chunk)
        }
        guard let input, let recording = recordings[input] else { throw ProviderError.server(status: 500) }
        let object: Any
        switch request.schemaName {
        case "Extraction":
            guard chunk < recording.extract.count else { throw ProviderError.server(status: 500) }
            object = ["pieces": recording.extract[chunk]]
            seen.withLock { s in
                s.chunk += 1
                s.variants[input] = request.instructions.contains("written by an AI assistant") ? "about_user" : "first_person"
                s.calls[input, default: 0] += 1
            }
        case "Decisions":
            object = ["decisions": decisions(recording, prompt: request.prompt)]
            seen.withLock { $0.calls[input, default: 0] += 1 }
        default:
            throw ProviderError.invalidOutput
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return (try HTTPClient.decode(json, as: T.self), ProviderUsage(requests: 1))
    }

    /// The recorded decisions for the pieces in this prompt, targets as the prompt's aliases
    /// (empty when the finder didn't supply that memory: validation makes it `create`).
    func decisions(_ recording: Recording, prompt: String) -> [[String: Any]] {
        let indices = Set(SpikeE.regex(#"<piece index="(\d+)""#).matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))
            .compactMap { Range($0.range(at: 1), in: prompt).flatMap { Int(prompt[$0]) } })
        var aliases: [String: String] = [:]
        for line in prompt.split(separator: "\n") {
            guard let m = SpikeE.regex(#"^- (m\d+) \(created [^)]*\) title: (.*?) \| body: (.*)$"#).firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)),
                  let a = Range(m.range(at: 1), in: line), let t = Range(m.range(at: 2), in: line),
                  let b = Range(m.range(at: 3), in: line) else { continue }
            aliases["\(line[t]). \(line[b])"] = String(line[a])
        }
        return recording.decisions.compactMap { d in
            guard let piece = d["piece"] as? Int, indices.contains(piece) else { return nil }
            var out = d
            let target = d["target"] as? String ?? ""
            out["target"] = memoryText[target].flatMap { aliases[$0] } ?? ""
            return out
        }
    }
}
