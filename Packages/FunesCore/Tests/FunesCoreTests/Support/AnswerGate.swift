import CryptoKit
import Foundation
import FunesProtocol
import GRDB
import Synchronization
@testable import FunesCore

/// JSON of any shape: a model's raw output, cached as given.
enum RawJSON: Codable, Sendable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([RawJSON]), object([String: RawJSON])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) } else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([RawJSON].self) { self = .array(a) } else { self = .object(try c.decode([String: RawJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }
}

/// The 13d answer gate's model (the Phase 13 plan's acceptance table, "Answers on linked questions" and "Spike G's gates
/// with the feature on"): the app's own subscription client, or none for a dry run, with every response cached on disk
/// by request and sample. A rerun resumes where a run stopped, and an arm whose request is byte for byte another's (no
/// learned fact changed it) reuses that answer rather than asking again. A dry run calls nothing: it answers "no answer"
/// (or what `fake` says) and counts the distinct requests a live run would send that the cache doesn't hold.
final class GateModel: GenerationProvider, @unchecked Sendable {
    struct Entry: Codable {
        var content: String
        var ms: Int
        var inputTokens: Int
        var outputTokens: Int
        var model: String?
    }

    struct State {
        var rep = 1
        var prompt: String?
        var requestHash: String?
        var ms: Int?
        var model: String?
        var cached = false
        var calls = 0
        var reused = 0
        var wouldCall: Set<String> = []
        var fake: (@Sendable (String) -> [String: Any])?
    }

    let base: (any GenerationProvider)?
    let id: ProviderID
    let modelID: String
    var locality: Locality { .cloud }
    let cache: URL
    private let state = Mutex(State())

    init(base: (any GenerationProvider)?, id: ProviderID, modelID: String, cache: URL) {
        self.base = base
        self.id = id
        self.modelID = modelID
        self.cache = cache
    }

    var isDry: Bool { base == nil }
    func next(rep: Int) {
        state.withLock {
            $0.rep = rep
            $0.prompt = nil
            $0.requestHash = nil
            $0.ms = nil
            $0.model = nil
            $0.cached = false
        }
    }
    func fake(_ f: (@Sendable (String) -> [String: Any])?) { state.withLock { $0.fake = f } }
    var last: (prompt: String?, hash: String?, ms: Int?, cached: Bool, model: String?) {
        state.withLock { ($0.prompt, $0.requestHash, $0.ms, $0.cached, $0.model) }
    }
    var counts: (calls: Int, reused: Int, wouldCall: Int) { state.withLock { ($0.calls, $0.reused, $0.wouldCall.count) } }

    /// A dry run's answer: one claim quoting the start of `m1`'s text, so the records and scorers see claims.
    static func echo(_ prompt: String) -> [String: Any] {
        guard let start = prompt.range(of: "<text>"), let end = prompt.range(of: "</text>", range: start.upperBound..<prompt.endIndex)
        else { return ["found": "no", "claims": [] as [Any]] }
        let quote = String(prompt[start.upperBound..<end.lowerBound].prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard quote.count >= 8 else { return ["found": "no", "claims": [] as [Any]] }
        return ["found": "yes", "claims": [["text": "The note says: \(quote)", "citations": [["ref": "m1", "quote": quote]]]]]
    }

    static func key(_ parts: [String]) -> String {
        let d = SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8))
        return d.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
        let rep = state.withLock { $0.rep }
        let hash = Self.key([modelID, request.instructions, request.prompt, request.schema.json])
        let key = Self.key([hash, String(rep)])
        let file = cache.appending(path: key + ".json")
        state.withLock {
            $0.prompt = request.prompt
            $0.requestHash = hash
        }
        if let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data) {
            state.withLock {
                $0.reused += 1
                $0.cached = true
                $0.ms = entry.ms
                $0.model = entry.model
            }
            return (try HTTPClient.decode(entry.content, as: T.self), ProviderUsage(requests: 0))
        }
        guard let base else {
            let fake = state.withLock { s -> (@Sendable (String) -> [String: Any])? in
                s.wouldCall.insert(key)
                return s.fake
            }
            let object = fake?(request.prompt) ?? Self.echo(request.prompt)
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            return (try HTTPClient.decode(text, as: T.self), ProviderUsage(requests: 1))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let (raw, usage) = try await base.generate(StructuredRequest<RawJSON>(instructions: request.instructions, prompt: request.prompt,
                                                                             schema: request.schema,
                                                                             maxOutputTokens: request.maxOutputTokens))
        let elapsed = clock.now - start
        let ms = Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        let content = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(content: content, ms: ms, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                                       model: usage.model)).write(to: file, options: .atomic)
        state.withLock {
            $0.calls += 1
            $0.ms = ms
            $0.model = usage.model
        }
        return (try HTTPClient.decode(content, as: T.self), usage)
    }
}

/// The answer gate's fixtures and arms (13d): Spike H's people sets and Spike G's two sets, each in a fresh vault with
/// learned facts from a recorded Haiku read applied through `FactStore.apply` (`SearchGate.applyPeople`), answered by
/// the real `SearchAnswerer` through `ModelRouter`.
///
/// - **P**, plain: 13b's answer (`facts: false`), what ships today.
/// - **F**, facts: the shipped search uses plus *attributes* (both bases) for every linked predicate, as the record
///   this gate would write turns on.
/// - **W**, a wrong link: F, with one memory the question's author marked as a trap linked to the person the search
///   names (a role link the Facts task decided, full basis), so it's admitted with that person's attribute.
enum AnswerGate {
    static let now = SearchGate.date("2026-10-29").addingTimeInterval(12 * 3_600)      // Spike G's and Spike H's today

    enum Arm: String, CaseIterable, Sendable { case plain = "P", facts = "F", wrong = "W" }

    struct Question: Decodable, Sendable {
        let id: String
        let set: String?
        let query: String
        let decoys: [String]?
        let family: String?
        let tags: [String]?
        let noAnswerCall: Bool?
    }

    static func questions(_ file: URL) throws -> [Question] {
        struct F: Decodable {
            let queries: [Question]?
            let questions: [Question]?
        }
        let f = try JSONDecoder().decode(F.self, from: Data(contentsOf: file))
        return f.queries ?? f.questions ?? []
    }

    struct Env: @unchecked Sendable {
        let vault: TestVault
        let ids: [String: UUID]
        let fixture: [UUID: String]
        let indexer: EmbeddingIndexer?
        let titles: [String: String]

        var index: String { indexer == nil ? "keyword only" : "bge-small" }
    }

    /// A fixture vault with a recorded read applied; bge-small when it's fetched and `embeddings`.
    static func env(vault: URL, backfill: URL, embeddings: Bool) async throws -> Env {
        let (v, ids, texts) = try SearchGate.vault(vault)
        try SearchGate.applyPeople(v, ids: ids, texts: texts, backfill: backfill)
        var indexer: EmbeddingIndexer?
        if embeddings, let dir = Fixtures.modelDirectory {
            let bge = try BundledBGEEmbedder(compiledModelURL: dir.appending(path: BundledBGEEmbedder.compiledModelName),
                                             vocabURL: dir.appending(path: "vocab.txt"))
            let i = EmbeddingIndexer(store: v.store, provider: bge)
            _ = try await i.embedPending()
            indexer = i
        }
        let vf = try JSONDecoder().decode(SearchGate.VaultFile.self, from: Data(contentsOf: vault))
        return Env(vault: v, ids: ids, fixture: Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) }), indexer: indexer,
                   titles: Dictionary(uniqueKeysWithValues: vf.memories.map { ($0.id, $0.title) }))
    }

    /// The shipped records' uses (recorded, linked, timeline, bridges as they are) with *attributes* on, at both bases,
    /// for every predicate that's linked and declares it.
    static func answerUses(_ env: Env) throws -> FactsUses {
        let reg = FactsRegistry.bundled
        var shipped = try env.vault.store.writer.read { db in try SearchGate.shipped.uses(db) }
        // While nothing ships (13e.1's code voided the records until its gate runs), the mechanism runs on every
        // declared use, as the next records would turn on.
        if reg.predicates.allSatisfy({ !shipped.isOn($0.id, .linked) }) { shipped = .everyDeclared(reg) }
        var on = Set<FactsUses.Key>()
        for p in reg.predicates {
            for use in [FactsUse.recorded, .linked, .timeline, .bridges] where shipped.isOn(p.id, use) {
                on.insert(.init(predicate: p.id, use: use, basis: ""))
            }
            if shipped.isOn(p.id, .linked), p.uses.contains(FactsUse.attributes.rawValue) {
                on.insert(.init(predicate: p.id, use: .attributes, basis: ""))
                on.insert(.init(predicate: p.id, use: .attributes, basis: LinkBasis.soleKnown.rawValue))
            }
        }
        return FactsUses(registry: reg, on: on)
    }

    static func config(_ arm: Arm, uses: FactsUses, links: [String: [MemoryLink]] = [:]) -> FactsSearchConfig {
        var c = SearchGate.shipped
        if arm != .plain { c.measuredUses = uses }
        c.measuredLinks = links
        return c
    }

    /// W's wrong link for `q`: the first trap memory within the cloud limit, active, not already linked to the person
    /// the search names, linked to them as a role phrase the Facts task decided. Nil when the search names no person
    /// with a linked fact, or no trap qualifies.
    static func wrongLink(_ q: Question, env: Env, search: SearchService, config: FactsSearchConfig)
        async throws -> (memory: String, entity: String, name: String, link: MemoryLink)? {
        guard let decoys = q.decoys, !decoys.isEmpty, let (index, _, _) = try await search.factsIndex(config) else { return nil }
        let g = index.graph
        let plan = index.plan(q.query, today: FactStore.writtenDay(now))
        for m in plan.matches {
            guard let e = g.entities[m.entity], e.kind == FactsValidator.personKind, e.group == nil, let name = e.name,
                  let fact = g.facts.first(where: { $0.entity == m.entity && !$0.negated && index.linked.contains($0.predicate) })
            else { continue }
            for d in decoys {
                guard let id = env.ids[d] else { continue }
                let mem = try await env.vault.store.writer.read { db in try MemoryStore.fetch(db, id: id) }
                guard let mem, mem.status == .active, CloudLimit.upTo(.internal).allows(mem.sensitivity) else { continue }
                if (index.links[id.db] ?? []).contains(where: { $0.entity == m.entity }) { continue }
                let link = MemoryLink(kind: .role, entity: m.entity, candidates: [], basis: .context, surface: m.word ?? name, start: 0,
                                      predicate: fact.predicate, word: nil)
                return (d, m.entity, name, link)
            }
        }
        return nil
    }

    /// One answer, or the error it ended with.
    struct Outcome {
        var answer: SearchAnswer?
        var error: SearchAnswerError?
        var prompt: String?
        var hash: String?
        var ms: Int?
        var cached: Bool
        /// The model the provider says answered (an alias resolved), where it says.
        var model: String?
        /// Shown results a link or the timeline admitted (the arm's own search).
        var admitted: [UUID] = []
    }

    static func answer(_ query: String, arm: Arm, search: SearchService, env: Env, model: GateModel, rep: Int) async throws -> Outcome {
        let hits = try await search.vaultSearch(query, filter: MemoryFilter(status: .active), now: now)
        let shown = hits.map(\.memoryID), admitted = hits.filter { $0.admission != nil }.map(\.memoryID)
        let answerer = SearchAnswerer(store: env.vault.store, search: search, activity: InMemoryActivityLog())
        model.next(rep: rep)
        do {
            // The whole list as shown, as the Mac's Ask gives it: 13b's selection keeps plain search's top results among
            // them (VaultModel.ask), and learned facts' selection recomputes the list itself.
            let a = try await answerer.answer(query, ids: shown, facts: arm != .plain,
                                              router: ModelRouter(classifier: model, onDevice: nil), now: now)
            let l = model.last
            return Outcome(answer: a, prompt: l.prompt, hash: l.hash, ms: l.ms, cached: l.cached, model: l.model, admitted: admitted)
        } catch let e as SearchAnswerError {
            // The plan's limit or a sign-in problem stops the run (the cache keeps what's done); anything else is this answer's.
            switch e {
            case .provider(.rateLimited), .provider(.unauthorized), .needsUpdate, .toolBlocked: throw e
            default: break
            }
            let l = model.last
            return Outcome(error: e, prompt: l.prompt, hash: l.hash, ms: l.ms, cached: l.cached, model: l.model, admitted: admitted)
        }
    }

    /// The `about="…"` each memory of the prompt carries, by its ref's position (m1 is 0).
    static func abouts(_ prompt: String?) -> [Int: String] {
        guard let prompt else { return [:] }
        var out: [Int: String] = [:]
        let re = try! NSRegularExpression(pattern: #"<memory ref="m(\d+)"[^>]*? about="([^"]*)">"#)
        for m in re.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)) {
            guard let r = Range(m.range(at: 1), in: prompt), let n = Int(prompt[r]), let a = Range(m.range(at: 2), in: prompt) else { continue }
            out[n - 1] = String(prompt[a]).replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        }
        return out
    }

    /// An answer as `spikes/people/search_answers.py` records it (its judge and scorer read these), with Swift's marks:
    /// each claim's `inferred` is the app's (§10.4), which the judge's "[Funes marks this as inferred]" note now follows.
    static func record(_ o: Outcome, id: String, arm: Arm, rep: Int, env: Env, injected: (memory: String, name: String)?) -> [String: Any] {
        var r: [String: Any] = ["id": id, "arm": arm.rawValue, "rep": rep, "hash": o.hash ?? "", "ms": o.ms ?? 0, "reused": o.cached]
        let fid = { (u: UUID) in env.fixture[u] ?? u.uuidString }
        if let injected { r["injected"] = injected.memory }
        guard let a = o.answer else {
            r.merge(["outcome": "failed", "claims": [] as [Any], "dropped": [] as [Any], "found": NSNull(), "sent": [] as [Any],
                     "error": o.error?.code ?? "unknown"]) { $1 }
            return r
        }
        let sent = a.readIDs.map(fid)
        let abouts = abouts(o.prompt)
        var about: [String: String] = [:]
        for (i, m) in sent.enumerated() { if let t = abouts[i] { about[m] = t } }
        r["sent"] = sent
        r["bridges"] = a.bridgeIDs.map(fid)
        r["about"] = about
        r["admitted"] = o.admitted.map(fid).filter(Set(sent).contains)
        // Learned facts really shaped this answer (an F or W answer without one fell back to 13b's selection).
        r["factsRevision"] = a.factsRevision ?? NSNull()
        r["model"] = o.model ?? NSNull()
        // W: the trap reached the prompt with the wrong attribute.
        if let injected { r["trapSent"] = about[injected.memory]?.contains(injected.name) == true }
        r["about_names"] = injected.map { [$0.memory: [$0.name]] } ?? [:]
        r["read"] = a.read
        r["withheld"] = a.withheld
        r["unreadLinked"] = a.unreadLinked
        r["outcome"] = a.outcome.rawValue
        r["found"] = a.outcome == .answered ? "yes" : "no"
        r["dropped"] = Array(repeating: ["reason": "validation"], count: a.dropped)
        r["claims"] = a.claims.map { c -> [String: Any] in
            var out: [String: Any] = ["text": c.text, "citations": c.citations.map { ["memory": fid($0.memoryID), "quote": $0.quote] },
                                      "inferred": c.inference != nil]
            if let i = c.inference {
                out["basis"] = i.basis
                out["factIds"] = i.factIDs
                out["corrections"] = i.corrections.map(\.target.what.rawValue)
            }
            return out
        }
        return r
    }

    static func jsonl(_ records: [[String: Any]]) throws -> String {
        try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
            .joined(separator: "\n") + (records.isEmpty ? "" : "\n")
    }
}
