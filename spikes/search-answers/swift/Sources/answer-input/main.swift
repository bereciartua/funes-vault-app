// Spike G's search step: the fixture vault in a temporary FunesCore store, embedded with the bundled bge-small
// when it's fetched (keyword-only otherwise), then for each question the vault search's top results (active,
// unexpired, as shown) with the text memory processing §10.3 sends for each: the body, or its best passages.
//
//   answer-input <vault.json> <questions.json> <out.json> [model directory]
//
// Two profiles: "cloud" (top 8, 1,500 characters a memory) and "apple" (top 5, 600). Every result keeps its
// sensitivity, so the runner applies the cloud limit for cloud providers.
import Foundation
import FunesCore
import FunesProtocol

struct FixtureMemory: Decodable {
    let id, title, body, kind, sensitivity, createdAt, updatedAt, source, trust: String
    let categories: [String]
}
struct VaultFile: Decodable { let memories: [FixtureMemory] }
struct Question: Decodable { let id, query: String }
struct QuestionsFile: Decodable { let questions: [Question] }

struct Result: Encodable {
    let fixtureId, title, kind, created, updated, source, sensitivity, text: String
    let categories: [String]
    let bodyChars: Int
    let passages: Bool
}
struct Profile: Encodable { let limit: Int; let results: [Result] }
struct Output: Encodable { let id, query: String; let totalHits: Int; let cloud, apple: Profile }

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: answer-input <vault.json> <questions.json> <out.json> [model dir]\n".utf8))
    exit(2)
}
let vault = try JSONDecoder().decode(VaultFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let questions = try JSONDecoder().decode(QuestionsFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let day = DateFormatter()
day.locale = Locale(identifier: "en_US_POSIX")
day.timeZone = TimeZone(identifier: "Europe/Lisbon")
day.dateFormat = "yyyy-MM-dd"
let today = day.date(from: "2026-10-29")!.addingTimeInterval(12 * 3_600)

let folder = FileManager.default.temporaryDirectory.appending(path: "spike-g-\(UUID().uuidString)")
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
/// The source as the prompt names it (§10.3).
func label(_ m: FixtureMemory) -> String {
    guard m.trust == "untrusted" else { return "you" }
    switch m.source {
    case "agent_write", "agent_suggestion": return "an agent"
    case "import": return "an import"
    default: return "shared text"
    }
}

var byID: [UUID: FixtureMemory] = [:]
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
    byID[memory.id] = m
}
let names = Dictionary(uniqueKeysWithValues: try store.categories().map { ($0.key, $0.name) })

var indexer: EmbeddingIndexer?
if args.count > 4 {
    let dir = URL(fileURLWithPath: args[4])
    let embedder = try BundledBGEEmbedder(compiledModelURL: dir.appending(path: BundledBGEEmbedder.compiledModelName),
                                          vocabURL: dir.appending(path: "vocab.txt"))
    let i = EmbeddingIndexer(store: store, provider: embedder)
    let n = try await i.embedPending()
    FileHandle.standardError.write(Data("embedded \(n) memories with bge-small\n".utf8))
    indexer = i
} else {
    FileHandle.standardError.write(Data("no model directory: keyword-only search\n".utf8))
}
let search = SearchService(store: store, indexer: indexer)

@MainActor func profile(_ hits: [SearchHit], query: String, count: Int, limit: Int) async throws -> Profile {
    let top = Array(hits.prefix(count))
    let memories = try store.memories(ids: top.map(\.memoryID))
    let matches = try await search.bodyMatches(query, ids: memories.map(\.id))
    let results = memories.map { memory -> Result in
        let f = byID[memory.id]!
        let text = matches[memory.id]?.answerText(limit: limit) ?? BodyMatches.answerText(body: memory.body, spans: [], limit: limit)
        return Result(fixtureId: f.id, title: memory.title, kind: memory.kind.rawValue, created: f.createdAt, updated: f.updatedAt,
                      source: label(f), sensitivity: memory.sensitivity.name, text: text,
                      categories: memory.categoryKeys.map { names[$0] ?? $0 }, bodyChars: memory.body.count,
                      passages: text != memory.body)
    }
    return Profile(limit: limit, results: results)
}

var out: [Output] = []
for q in questions.questions {
    let hits = try await search.vaultSearch(q.query, filter: MemoryFilter(), now: today)
    out.append(Output(id: q.id, query: q.query, totalHits: hits.count,
                      cloud: try await profile(hits, query: q.query, count: 8, limit: 1_500),
                      apple: try await profile(hits, query: q.query, count: 5, limit: 600)))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(out).write(to: URL(fileURLWithPath: args[3]))
FileHandle.standardError.write(Data("\(out.count) questions written to \(args[3])\n".utf8))
