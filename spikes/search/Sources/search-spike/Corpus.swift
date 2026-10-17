import Foundation

struct FixtureMemory: Decodable {
    let id: String
    let key: String
    let title: String
    let body: String
    let kind: String
    let categories: [String]
    let sensitivity: String
}

struct FixtureQuery: Decodable {
    let id: String
    let query: String
    let relevant: [String]
}

private struct MemoriesFile: Decodable { let memories: [FixtureMemory] }
private struct QueriesFile: Decodable { let queries: [FixtureQuery] }

/// One searchable document. Synthesized documents carry `sourceId` when they paraphrase a
/// fixture memory; mixtures of several memories have none.
struct Doc {
    let id: String
    let sourceId: String?
    let title: String
    let body: String
    let kind: String
    let categories: [String]
    /// For mixtures: the fixture memories whose sentences it contains.
    var mixSources: [String] = []

    /// The id a hit counts as when scoring: a paraphrase counts as its source.
    var scoringId: String { sourceId ?? id }
}

let categoryNames: [String: String] = [
    "communication_style": "Communication style",
    "personal_preferences": "Personal preferences",
    "software_development": "Software development",
    "project_context": "Project context",
    "privacy_preferences": "Privacy preferences",
    "health": "Health",
    "finance": "Finance",
    "legal": "Legal",
]

/// The embedding input from spec/domain/memory-processing.md §2.
func embeddingText(_ d: Doc) -> String {
    let cats = d.categories.map { categoryNames[$0] ?? $0 }.joined(separator: ", ")
    return "\(d.title)\n\(d.kind.replacingOccurrences(of: "_", with: " "))\n\(cats)\n\(d.body)"
}

func loadFixtures(dir: URL) throws -> ([FixtureMemory], [FixtureQuery]) {
    let m = try JSONDecoder().decode(MemoriesFile.self, from: Data(contentsOf: dir.appendingPathComponent("memories-200.json")))
    let q = try JSONDecoder().decode(QueriesFile.self, from: Data(contentsOf: dir.appendingPathComponent("queries-30.json")))
    return (m.memories, q.queries)
}

// MARK: - Synthesizing a 10,000-memory corpus

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let synonyms: [String: [String]] = [
    "prefer": ["like", "would rather have", "favour"], "use": ["rely on", "go with", "stick to"],
    "never": ["do not ever", "under no circumstances"], "always": ["every time", "consistently"],
    "client": ["customer"], "clients": ["customers"], "email": ["mail", "e-mail"], "emails": ["mails"],
    "write": ["compose", "put together"], "app": ["application"], "apps": ["applications"],
    "project": ["piece of work"], "week": ["seven days"], "month": ["calendar month"],
    "short": ["brief", "compact"], "small": ["little", "minor"], "new": ["fresh", "recent"],
    "about": ["roughly", "around"], "every": ["each"], "keep": ["maintain", "hold"],
    "want": ["would like"], "need": ["require"], "start": ["begin"], "help": ["assist"],
    "good": ["decent", "solid"], "quick": ["fast"], "files": ["documents"], "code": ["source"],
    "tests": ["checks"], "money": ["funds"], "doctor": ["physician"], "trip": ["journey"],
    "morning": ["early hours"], "evening": ["night"], "weekend": ["Saturday and Sunday"],
    "work": ["job"], "messages": ["notes"], "share": ["pass on", "disclose"], "don't": ["do not"],
]

private let prefixes = ["", "", "", "Note: ", "Reminder: ", "For the record, ", "Still true: ", "Update: "]
private let suffixes = ["", "", "", " This came up again recently.", " Confirmed in 2026.", " (Noted from a chat.)", " Worth keeping in mind."]

private func sentences(_ text: String) -> [String] {
    var out: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
        if let s { out.append(s.trimmingCharacters(in: .whitespaces)) }
    }
    return out.isEmpty ? [text] : out
}

private func paraphrase(_ text: String, rng: inout SplitMix64) -> String {
    text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
        let w = String(word)
        let core = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard let options = synonyms[core], Bool.random(using: &rng) else { return w }
        let trailing = w.reversed().prefix { $0.isPunctuation }.reversed()
        return options.randomElement(using: &rng)! + String(trailing)
    }.joined(separator: " ")
}

/// 70% paraphrased copies of fixture memories (word swaps, sentence shuffles, framing), 30%
/// mixtures of sentences from two or three unrelated memories. Deterministic.
func synthesize(from base: [Doc], total: Int, seed: UInt64 = 42) -> [Doc] {
    var rng = SplitMix64(state: seed)
    var docs = base
    var n = 0
    while docs.count < total {
        n += 1
        if Double.random(in: 0..<1, using: &rng) < 0.7 {
            let src = base.randomElement(using: &rng)!
            var parts = sentences(src.body)
            if parts.count > 1, Bool.random(using: &rng) { parts.shuffle(using: &rng) }
            let body = prefixes.randomElement(using: &rng)! + paraphrase(parts.joined(separator: " "), rng: &rng)
                + suffixes.randomElement(using: &rng)!
            let title = Bool.random(using: &rng) ? paraphrase(src.title, rng: &rng) : src.title
            docs.append(Doc(id: "s\(n)", sourceId: src.id, title: title, body: body, kind: src.kind, categories: src.categories))
        } else {
            let picks = (0..<Int.random(in: 2...3, using: &rng)).map { _ in base.randomElement(using: &rng)! }
            let body = picks.map { sentences($0.body).randomElement(using: &rng)! }.joined(separator: " ")
            docs.append(Doc(id: "s\(n)", sourceId: nil, title: picks[0].title + " (misc)", body: body,
                            kind: picks[0].kind, categories: picks[0].categories, mixSources: picks.map(\.id)))
        }
    }
    return docs
}
