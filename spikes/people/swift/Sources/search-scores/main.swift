// Spike H's search step: an invented fixture vault in a temporary FunesCore store, embedded with the bundled bge-small,
// then for each query and for its "rest" (the query with the people in it taken out, from search.py's plan) the vault
// search's hits with their scores, the raw cosine of every memory, and the answer text of memories whose body is cut
// to passages. search.py ranks with people on top of these numbers; nothing about people is in here.
//
//   search-scores <vault.json> <plan.json> <out.json> <model directory>
//
// plan.json: [{"id", "query", "rest"}]; "rest" may be null (no people in the query).
import Foundation
import FunesCore
import FunesProtocol

struct FixtureMemory: Decodable {
    let id, title, body, kind, sensitivity, createdAt, updatedAt, source, trust: String
    let categories: [String]
}
struct VaultFile: Decodable { let memories: [FixtureMemory] }
struct PlanEntry: Decodable { let id, query: String; let rest: String? }

struct Hit: Encodable { let id: String; let score, keyword, semantic: Float; let cosine: Float? }
struct Scores: Encodable {
    let hits: [Hit]                 // vault search, ranked, after its thresholds
    let cosines: [String: Float]    // every memory's raw cosine with the text
    let passages: [String: String]  // answer text (cloud profile, 1,500 characters) where it isn't the whole body
}
struct Output: Encodable { let id, query: String; let rest: String?; let full: Scores; let restScores: Scores? }
struct File: Encodable { let categoryNames: [String: String]; let queries: [Output] }

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write(Data("usage: search-scores <vault.json> <plan.json> <out.json> <model dir>\n".utf8))
    exit(2)
}
let vault = try JSONDecoder().decode(VaultFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let plan = try JSONDecoder().decode([PlanEntry].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let day = DateFormatter()
day.locale = Locale(identifier: "en_US_POSIX")
day.timeZone = TimeZone(identifier: "Europe/Lisbon")
day.dateFormat = "yyyy-MM-dd"
let today = day.date(from: "2026-10-29")!.addingTimeInterval(12 * 3_600)

let folder = FileManager.default.temporaryDirectory.appending(path: "spike-h-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: folder) }
let store = try VaultStore.open(directory: folder)

func source(_ raw: String) -> MemorySource {
    switch raw {
    case "import": .importClaude
    case "agent_write": .agentWrite
    default: MemorySource(rawValue: raw) ?? .manual
    }
}

var fixtureID: [UUID: String] = [:]
var body: [UUID: String] = [:]
for m in vault.memories {
    let created = day.date(from: m.createdAt)!.addingTimeInterval(9 * 3_600)
    let memory = try store.createMemory(MemoryDraft(title: m.title, body: m.body, kind: MemoryKind(rawValue: m.kind) ?? .fact,
                                                    categoryKeys: m.categories, sensitivity: Sensitivity(name: m.sensitivity),
                                                    source: source(m.source), trust: m.trust == "untrusted" ? .untrusted : .trusted),
                                        now: created)
    if m.updatedAt != m.createdAt {
        let updated = day.date(from: m.updatedAt)!.addingTimeInterval(9 * 3_600)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE memory SET updated_at = ? WHERE id = ?", arguments: [updated, memory.id.uuidString.lowercased()])
        }
    }
    fixtureID[memory.id] = m.id
    body[memory.id] = m.body
}
let names = Dictionary(uniqueKeysWithValues: try store.categories().map { ($0.key, $0.name) })

let dir = URL(fileURLWithPath: args[4])
let embedder = try BundledBGEEmbedder(compiledModelURL: dir.appending(path: BundledBGEEmbedder.compiledModelName),
                                      vocabURL: dir.appending(path: "vocab.txt"))
let indexer = EmbeddingIndexer(store: store, provider: embedder)
let n = try await indexer.embedPending()
FileHandle.standardError.write(Data("embedded \(n) memories with bge-small\n".utf8))
let search = SearchService(store: store, indexer: indexer)
let allIDs = Array(fixtureID.keys)

@MainActor func scores(_ text: String) async throws -> Scores {
    let hits = try await search.vaultSearch(text, filter: MemoryFilter(), now: today)
    var cos: [String: Float] = [:]
    if let q = try await embedder.embed([text], as: .query).first {
        // Funes L2-normalizes after return (EmbeddingProvider); the index does the same for documents.
        var norm: Float = 0
        for x in q { norm += x * x }
        let v = q.map { $0 / max(norm.squareRoot(), 1e-12) }
        for (id, c) in indexer.index.cosines(v) { if let f = fixtureID[id] { cos[f] = c } }
    }
    let matches = try await search.bodyMatches(text, ids: allIDs)
    var passages: [String: String] = [:]
    for id in allIDs {
        let t = matches[id]?.answerText(limit: 1_500) ?? BodyMatches.answerText(body: body[id]!, spans: [], limit: 1_500)
        if t != body[id]! { passages[fixtureID[id]!] = t }
    }
    return Scores(hits: hits.map { Hit(id: fixtureID[$0.memoryID]!, score: $0.score, keyword: $0.keyword, semantic: $0.semantic,
                                       cosine: $0.cosine) },
                  cosines: cos, passages: passages)
}

var out: [Output] = []
for p in plan {
    let full = try await scores(p.query)
    let rest: Scores? = if let r = p.rest, !r.trimmingCharacters(in: .whitespaces).isEmpty { try await scores(r) } else { nil }
    out.append(Output(id: p.id, query: p.query, rest: p.rest, full: full, restScores: rest))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
try encoder.encode(File(categoryNames: names, queries: out)).write(to: URL(fileURLWithPath: args[3]))
FileHandle.standardError.write(Data("\(out.count) queries written to \(args[3])\n".utf8))
