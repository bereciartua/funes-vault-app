import CryptoKit
import Foundation
import FunesProtocol
import GRDB
import Synchronization
@testable import FunesCore

/// The facts fixture harness (Phase 13a.2): plays the spike's story fixtures (`spikes/people/fixtures/stories*.json`)
/// through a fresh vault, `FactsExtractor` and `ModelRouter`, and writes what the spike's scorers read:
/// `run_facts.py`'s `dump_people` lines with a `state` (`dump_state`), so `score.py` and `score_facts.py stories` score
/// them unchanged. Timeline questions are also answered by the Swift `TimelineIntent` and `Timeline` and judged as
/// `score_facts.judge` does, so the time model measured is Swift's, not Python's.
///
/// Providers: `replay` (the spike's recorded outputs, exported by `spikes/people/export_replay.py`, in their recorded
/// order and modes), and `live` (a real model, only with the author's go-ahead).
enum FactsHarness {
    // MARK: Fixtures

    struct Fixture: Decodable {
        struct User: Decodable { let name: String; let aliases: [String] }
        struct Name: Decodable { let surface: String; let person: String }
        struct Memory: Decodable {
            let id: String
            let text: String
            let written: String
            let source: String
            let trust: String?
            let names: [Name]?
            /// The memory's sensitivity (canary and work sets may set it); `low` when absent.
            let sensitivity: String?
            /// 13e.2's timeline gate: a filler memory (shared, or one of a story's own), not part of the story's labels.
            var filler: Bool? = nil

            var trusted: Bool { (trust ?? (source == "agent" ? "untrusted" : "trusted")) == "trusted" }
        }
        struct Query: Decodable {
            let id: String
            let kind: String
            let query: String
            let answer_org: String?
        }
        struct TimelineEntry: Decodable { let org: String?; let kind: String? }
        struct Person: Decodable { let names: [String] }
        /// The user's own operations in a story (the canary's): "reject" a role phrase's person in a memory, or give a
        /// person's "start" or "end".
        struct Correction: Decodable {
            let after: String
            let op: String
            let person: String
            let memory: String?
            let surface: String?
            let predicate: String?
            let value: String?
        }
        struct Story: Decodable {
            let id: String
            var memories: [Memory]
            var orders: [[String]]?
            var queries: [Query]?
            /// 13e.2, development only (`comparisons=`): Spike T round 2's recorded comparisons, run through the direct
            /// time-model call to compare with the spike's canonical-question path.
            var comparisons: [SpikeComparison]? = nil
            let timeline: [TimelineEntry]?
            let people: [String: Person]?
            let corrections: [Correction]?
        }
        let user: User
        var stories: [Story]

        /// A comparison as Spike T round 2 recorded it (organization names, not aliases).
        struct SpikeComparison: Decodable {
            let id: String
            let search: String
            let made: Bool
            let `operator`: String
            let anchor_org: String
            let stint: String
            let anchor_date: String
            let end_date: String
            let kind: String
            let answer_org: String
        }
    }

    static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The 13a.2 canary (written blind by GPT-6-Astra after the code freeze) keeps its registry beside its stories.
    static let canaryDirectory = "spikes/people/fixtures/canary-13a2"

    static func fixtureURL(_ set: String) -> URL {
        if set == "canary13" { return repo.appending(path: canaryDirectory + "/stories.json") }
        return repo.appending(path: "spikes/people/fixtures/\(set == "main" ? "stories" : "stories-\(set)").json")
    }

    /// A set's own registry, if it has one (repo-relative).
    static func defaultRegistry(_ set: String) -> String? { set == "canary13" ? canaryDirectory + "/registry.json" : nil }

    static func fixture(_ set: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL(set)))
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// The commit measured, with "+dirty" when the tree has changes (a run's manifest records it).
    static func commit() -> String {
        func git(_ args: [String]) -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return "" }
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let head = git(["rev-parse", "HEAD"])
        return git(["status", "--porcelain"]).isEmpty ? head : head + "+dirty"
    }

    /// A live provider that remembers which models it said answered (an alias resolves to one).
    final class ModelsSeen: GenerationProvider, @unchecked Sendable {
        let inner: any GenerationProvider
        let models = Mutex<Set<String>>([])
        /// Every response, and those the provider gave no model id for (a record needs every one identified).
        let responses = Mutex<(all: Int, unidentified: Int)>((0, 0))
        init(_ inner: any GenerationProvider) { self.inner = inner }
        var id: ProviderID { inner.id }
        var locality: Locality { inner.locality }
        var modelID: String { inner.modelID }
        var factsAdapter: String { inner.factsAdapter }
        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let (out, usage) = try await inner.generate(request)
            if let m = usage.model { models.withLock { _ = $0.insert(m) } }
            responses.withLock { $0.all += 1; if usage.model == nil { $0.unidentified += 1 } }
            return (out, usage)
        }
    }

    /// Any JSON value: what a provider returned, kept as it came (13e.2: the harness records live calls).
    enum JSONValue: Codable, Sendable, Equatable {
        case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
            else { self = .object(try c.decode([String: JSONValue].self)) }
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

    /// The key a call is recorded and replayed under: its instructions, prompt and schema. The Swift pipeline is
    /// deterministic, so a replay on the same commit and fixture asks the same prompts.
    static func callKey<T>(_ request: StructuredRequest<T>) -> String {
        let text = request.instructions + "\u{1}" + request.prompt + "\u{1}" + request.schema.json
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A provider error as the record keeps it, and back (13e.2: a failed live call replays as that failure).
    static func errorCode(_ e: any Error) -> String {
        guard let p = e as? ProviderError else { return e is CancellationError ? "cancelled" : "other" }
        switch p {
        case .unavailable: return "unavailable"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rate_limited"
        case let .server(status): return "server_\(status)"
        case .invalidOutput: return "invalid_output"
        case .refused: return "refused"
        case .timeout: return "timeout"
        case .insecureEndpoint: return "insecure_endpoint"
        case .blocked: return "blocked"
        case .transport: return "transport"
        case .capReached: return "cap_reached"
        }
    }

    static func error(_ code: String) -> ProviderError {
        switch code {
        case "unavailable": .unavailable
        case "unauthorized": .unauthorized
        case "rate_limited": .rateLimited(retryAfter: nil)
        case "refused": .refused
        case "timeout": .timeout
        case "blocked": .blocked
        case "transport": .transport
        case "cap_reached": .capReached
        case "invalid_output": .invalidOutput
        case "insecure_endpoint": .insecureEndpoint
        default: code.hasPrefix("server_") ? .server(status: Int(code.dropFirst(7)) ?? 500) : .transport
        }
    }

    /// Records every live call (13e.2, "the Swift harness records live calls"): its key, the provider and adapter, the
    /// model that answered and the raw output, or the error, so a gate read replays (`calls=`). Each line is appended to
    /// the file as its call ends, so an interrupted run keeps what it paid for. The prompt itself isn't kept: the key
    /// binds it.
    final class CallRecorder: GenerationProvider, @unchecked Sendable {
        let inner: any GenerationProvider
        let file: URL
        let count = Mutex<Int>(0)
        init(_ inner: any GenerationProvider, file: URL) throws {
            self.inner = inner
            self.file = file
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Never over a record: an interrupted read's calls are evidence (run again under the next tag).
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 0 {
                throw CocoaError(.fileWriteFileExists)
            }
            try Data().write(to: file)
        }
        var id: ProviderID { inner.id }
        var locality: Locality { inner.locality }
        var modelID: String { inner.modelID }
        var factsAdapter: String { inner.factsAdapter }

        private func append(_ entry: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
            count.withLock { _ in
                if let h = try? FileHandle(forWritingTo: file) {
                    h.seekToEndOfFile()
                    h.write(data + Data("\n".utf8))
                    try? h.close()
                }
            }
        }

        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let raw = StructuredRequest<JSONValue>(instructions: request.instructions, prompt: request.prompt, schema: request.schema,
                                                   maxOutputTokens: request.maxOutputTokens)
            var entry: [String: Any] = ["key": FactsHarness.callKey(request), "provider": inner.id.rawValue, "adapter": inner.factsAdapter]
            // One entry per provider call, with its final outcome: the output it returned (even if it then doesn't decode
            // as the request's type, which replays the same way), or its error.
            let result: Result<(JSONValue, ProviderUsage), any Error>
            do { result = .success(try await inner.generate(raw)) } catch { result = .failure(error) }
            switch result {
            case let .failure(error):
                entry["error"] = FactsHarness.errorCode(error)
                append(entry)
                count.withLock { $0 += 1 }
                throw error
            case let .success((value, usage)):
                let data = try JSONEncoder().encode(value)
                entry["model"] = usage.model ?? NSNull()
                entry["output"] = try JSONSerialization.jsonObject(with: data)
                append(entry)
                count.withLock { $0 += 1 }
                return (try HTTPClient.decode(String(decoding: data, as: UTF8.self), as: T.self), usage)
            }
        }
    }

    /// Replays a recorded run (`calls=`): each call is served the next recorded entry for its key (its output, or its
    /// error), as the recorded provider and adapter; a call the record doesn't have is a miss (counted, and answered as
    /// unreadable output, so the run shows it).
    final class CallReplay: GenerationProvider, @unchecked Sendable {
        struct Entry { var output: Data?; var error: String?; var model: String? }
        let queues: Mutex<[String: [Entry]]>
        let misses = Mutex<Int>(0)
        let modelID: String
        let id: ProviderID
        let factsAdapter: String
        init(_ url: URL) throws {
            var q: [String: [Entry]] = [:]
            var model: String?, provider: String?, adapter: String?
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let d = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let m = d["model"] as? String
                model = model ?? m
                provider = provider ?? d["provider"] as? String
                adapter = adapter ?? d["adapter"] as? String
                let out = try d["output"].map { try JSONSerialization.data(withJSONObject: $0) }
                q[d["key"] as! String, default: []].append(Entry(output: out, error: d["error"] as? String, model: m))
            }
            queues = Mutex(q)
            modelID = (model ?? "recorded").components(separatedBy: "/").last ?? "recorded"
            id = ProviderID(rawValue: provider ?? "anthropic")
            factsAdapter = adapter ?? "recorded"
        }
        var locality: Locality { .cloud }
        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let key = FactsHarness.callKey(request)
            guard let next = queues.withLock({ q -> Entry? in
                guard var list = q[key], !list.isEmpty else { return nil }
                let first = list.removeFirst()
                q[key] = list
                return first
            }) else {
                misses.withLock { $0 += 1 }
                throw ProviderError.invalidOutput
            }
            if let e = next.error { throw FactsHarness.error(e) }
            return (try HTTPClient.decode(String(decoding: next.output ?? Data("{}".utf8), as: UTF8.self), as: T.self),
                    ProviderUsage(requests: 1, model: next.model))
        }
    }

    /// 13e.2's timeline gate read: calls shared across stories (the fillers every story vault reads first). Within a
    /// story, the n-th ask of a call key is served the n-th recorded entry for that key (its output or its error); with
    /// none, a live call (with `inner`) is made and appended to the record, else it's a miss. The fillers' calls are
    /// byte-identical in every story (positional roster ids, a deterministic clock), so they're paid once; the same rule
    /// on the same record, in the same story order, replays the whole read. Each story's (key, occurrence, source) list
    /// is kept for the manifest.
    final class SharedCalls: GenerationProvider, @unchecked Sendable {
        struct Entry { var output: Data?; var error: String?; var model: String? }
        struct State {
            var entries: [String: [Entry]] = [:]
            var seen: [String: Int] = [:]
            var log: [[String: Any]] = []
            var live = 0, reused = 0, misses = 0, liveErrors = 0, servedErrors = 0
            var lines = 0
        }
        let inner: (any GenerationProvider)?
        let file: URL
        let state: Mutex<State>
        let id: ProviderID
        let modelID: String
        let factsAdapter: String

        /// `inner` nil replays `file` only; with `inner`, `file` is the record (new, or one an interrupted read began).
        init(_ inner: (any GenerationProvider)?, file: URL) throws {
            self.inner = inner
            self.file = file
            var st = State()
            var model: String?, provider: String?, adapter: String?
            if FileManager.default.fileExists(atPath: file.path) {
                for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                    let d = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                    model = model ?? d["model"] as? String
                    provider = provider ?? d["provider"] as? String
                    adapter = adapter ?? d["adapter"] as? String
                    let out = try d["output"].map { try JSONSerialization.data(withJSONObject: $0) }
                    st.entries[d["key"] as! String, default: []].append(Entry(output: out, error: d["error"] as? String, model: d["model"] as? String))
                    st.lines += 1
                }
            } else if inner != nil {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: file)
            } else {
                throw CocoaError(.fileNoSuchFile)
            }
            state = Mutex(st)
            id = inner?.id ?? ProviderID(rawValue: provider ?? "anthropic")
            modelID = inner?.modelID ?? (model ?? "recorded").components(separatedBy: "/").last ?? "recorded"
            factsAdapter = inner?.factsAdapter ?? adapter ?? "recorded"
        }
        var locality: Locality { .cloud }

        /// A new story: occurrences count from zero again; returns the previous story's log.
        @discardableResult
        func begin() -> [[String: Any]] {
            state.withLock { s in
                defer { s.seen = [:]; s.log = [] }
                return s.log
            }
        }
        var counts: (live: Int, reused: Int, misses: Int, liveErrors: Int, servedErrors: Int) {
            state.withLock { ($0.live, $0.reused, $0.misses, $0.liveErrors, $0.servedErrors) }
        }

        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let key = FactsHarness.callKey(request)
            let served: Entry? = state.withLock { s in
                let n = s.seen[key, default: 0]
                s.seen[key] = n + 1
                guard let list = s.entries[key], n < list.count else { return nil }
                s.reused += 1
                if list[n].error != nil { s.servedErrors += 1 }
                s.log.append(["key": key, "n": n, "source": "recorded"])
                return list[n]
            }
            if let e = served {
                if let code = e.error { throw FactsHarness.error(code) }
                return (try HTTPClient.decode(String(decoding: e.output ?? Data("{}".utf8), as: UTF8.self), as: T.self),
                        ProviderUsage(requests: 1, model: e.model))
            }
            guard let inner else {
                state.withLock { $0.misses += 1 }
                throw ProviderError.invalidOutput
            }
            let raw = StructuredRequest<JSONValue>(instructions: request.instructions, prompt: request.prompt, schema: request.schema,
                                                   maxOutputTokens: request.maxOutputTokens)
            var line: [String: Any] = ["key": key, "provider": inner.id.rawValue, "adapter": inner.factsAdapter,
                                       "maxOutputTokens": request.maxOutputTokens ?? NSNull()]
            let result: Result<(JSONValue, ProviderUsage), any Error>
            do { result = .success(try await inner.generate(raw)) } catch { result = .failure(error) }
            var entry = Entry()
            switch result {
            case let .failure(error):
                line["error"] = FactsHarness.errorCode(error)
                entry.error = line["error"] as? String
            case let .success((value, usage)):
                let data = try JSONEncoder().encode(value)
                line["model"] = usage.model ?? NSNull()
                line["output"] = try JSONSerialization.jsonObject(with: data)
                entry.output = data
                entry.model = usage.model
            }
            let bytes = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            state.withLock { s in
                if let h = try? FileHandle(forWritingTo: file) {
                    h.seekToEndOfFile()
                    h.write(bytes + Data("\n".utf8))
                    try? h.close()
                }
                s.entries[key, default: []].append(entry)
                s.live += 1
                s.lines += 1
                if entry.error != nil { s.liveErrors += 1 }
                s.log.append(["key": key, "n": s.seen[key, default: 1] - 1, "source": entry.error == nil ? "live" : "live_error"])
            }
            switch result {
            case let .failure(error): throw error
            case let .success((value, usage)):
                return (try HTTPClient.decode(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), as: T.self), usage)
            }
        }
    }

    /// Counts requests whose payload carries a fixture memory above the run's cloud limit (the sentinel is the memory's
    /// text as it would be sent). A gate run must have none: the router refuses them before any provider sees them.
    final class PayloadGuard: GenerationProvider, @unchecked Sendable {
        let inner: any GenerationProvider
        let forbidden = Mutex<[String]>([])
        let leaks = Mutex<Int>(0)
        init(_ inner: any GenerationProvider) { self.inner = inner }
        var id: ProviderID { inner.id }
        var locality: Locality { inner.locality }
        var modelID: String { inner.modelID }
        var factsAdapter: String { inner.factsAdapter }
        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let payload = request.instructions + "\n" + request.prompt
            // The memory's text as sent, and each of its sentences of 20 characters or more: part of it is a leak too.
            let bad = forbidden.withLock { $0 }.filter { text in
                guard !text.isEmpty else { return false }
                let parts = [text] + text.split(whereSeparator: { ".!?\n".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 20 }
                return parts.contains { payload.contains($0) }
            }
            if !bad.isEmpty { leaks.withLock { $0 += bad.count } }
            return try await inner.generate(request)
        }
    }

    static func sensitivity(_ name: String?) -> Sensitivity {
        Sensitivity.allCases.first { $0.name == name } ?? .low
    }

    static func cloudLimit(_ name: String?) -> CloudLimit {
        guard let name, name != "secret" else { return .upTo(.secret) }
        return name == "never" ? .never : .upTo(sensitivity(name))
    }

    /// A registry file (`registry=`, the canary's), or the bundled one.
    static func registry(_ path: String?) throws -> FactsRegistry {
        guard let path else { return .bundled }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appending(path: path)
        return try FactsRegistry.decode(Data(contentsOf: url))
    }

    // MARK: Recorded calls (export_replay.py)

    struct Recorded: @unchecked Sendable {
        let story: String
        let orderIndex: Int
        let memory: String
        let group: String
        let mode: String
        let raw: [String: Any]
        /// The Python roster then: id → (name, aliases, group, kind).
        let roster: [String: [String: Any]]
        let line: [String: Any]

        init(_ d: [String: Any]) {
            story = d["story"] as! String
            orderIndex = d["orderIndex"] as! Int
            memory = d["memory"] as! String
            group = d["group"] as! String
            mode = d["mode"] as! String
            raw = d["raw"] as! [String: Any]
            roster = d["roster"] as? [String: [String: Any]] ?? [:]
            line = d
        }
    }

    static func recorded(_ url: URL) throws -> [Recorded] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            Recorded(try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])
        }
    }

    /// Replays recorded outputs. The harness sets which recorded call is next; a call the recording doesn't have (a
    /// Swift-only re-ask) gets that memory and group's latest output. Python roster ids become the Swift roster's by
    /// the entity's exact alias set, or its role group.
    final class Replay: GenerationProvider, @unchecked Sendable {
        let id: ProviderID = "anthropic"
        let locality: Locality = .cloud
        let modelID = "claude-haiku-replay"
        /// Gold answers (`gold_answers.py`) were written against the spike's roster; with `reader`, an answer about
        /// someone the Swift roster doesn't show is translated as a reader of the Swift prompt would answer.
        let reader: Bool
        init(reader: Bool = false) { self.reader = reader }

        /// What the gold reader may assume about a fixture memory: its text, and the folded names of people who, so far
        /// in the play, were named only by untrusted memories (so a trusted memory's roster leaves them out, §11.4).
        struct Context { var text: String; var trusted: Bool; var untrustedOnly: Set<String> }
        private let contexts = Mutex<[String: Context]>([:])
        private let counts = Mutex<(substituted: Int, unexplained: Int)>((0, 0))
        func context(_ memory: String, _ c: Context) { contexts.withLock { $0[memory] = c } }
        /// Answers about someone the Swift roster left out, translated by the reader (alias trust).
        var substituted: Int { counts.withLock { $0.substituted } }
        /// Unmapped roster ids the alias-trust rule doesn't explain (a gold play must have none).
        var unexplained: Int { counts.withLock { $0.unexplained } }

        struct Part { var raw: [String: Any]; var roster: [String: [String: Any]] }
        struct Sources { var people, facts, roles, things: Part }
        private let state = Mutex<(next: Recorded?, reask: String?, sources: [String: Sources], unmapped: Int, served: Int, reasks: Int)>(
            (nil, nil, [:], 0, 0, 0))

        var unmapped: Int { state.withLock { $0.unmapped } }
        var reasks: Int { state.withLock { $0.reasks } }

        func expect(_ r: Recorded) { state.withLock { $0.next = r; $0.reask = nil } }
        /// Swift's own schedule served from a recording: every call is a re-ask, answered with what the recording's
        /// calls for that memory and group add up to (the spike applied only the roles of a roles re-ask, and only the
        /// names of a names re-ask). For counting calls; the answers were made knowing other rosters.
        func preload(_ recs: [Recorded]) {
            state.withLock { s in
                for r in recs { s.sources[r.memory + "\u{1F}" + r.group] = Self.merged(s.sources[r.memory + "\u{1F}" + r.group], r) }
            }
        }

        static func merged(_ old: Sources?, _ r: Recorded) -> Sources {
            let part = Part(raw: r.raw, roster: r.roster)
            var src = old ?? Sources(people: part, facts: part, roles: part, things: part)
            switch r.mode {
            case "roles": src.roles = part
            case "names": src.people = part
            default: src = Sources(people: part, facts: part, roles: part, things: part)
            }
            return src
        }
        /// A Swift-only re-ask of a fixture memory in a group: served with its latest recorded output.
        func reask(_ memory: String, _ group: String) { state.withLock { $0.next = nil; $0.reask = memory + "\u{1F}" + group } }

        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let swift = Self.parseRoster(request.prompt)
            let data: Data = try state.withLock { s in
                let key: String
                if let r = s.next {
                    key = r.memory + "\u{1F}" + r.group
                    s.sources[key] = Self.merged(s.sources[key], r)
                    s.next = nil
                    s.served += 1
                } else {
                    guard let k = s.reask, s.sources[k] != nil else { throw ProviderError.invalidOutput }
                    key = k
                    s.reasks += 1
                }
                let src = s.sources[key]!
                var unmapped = 0
                /// The Swift roster's id for a Python roster id, or the Python entity when the Swift roster doesn't show it.
                func tr(_ v: Any?, _ part: Part) -> (value: Any?, hidden: [String: Any]?) {
                    guard let id = v as? String, id.range(of: "^p\\d+$", options: .regularExpression) != nil else { return (v, nil) }
                    guard let e = part.roster[id] else { return (id, nil) }     // not in the spike's roster either: dropped by both
                    if let mapped = Self.translate(e, swift) { return (mapped, nil) }
                    unmapped += 1
                    return (id, e)
                }
                /// A gold reader of Swift's prompt (`reader`): someone the Swift roster leaves out because, so far,
                /// only untrusted memories named them (§11.4: a trusted memory's roster doesn't show them) is answered
                /// as the gold script answers someone not yet known: by the name this memory gives them, else the group
                /// (roles) or nothing (facts). Any other unmapped id stays unmapped and counts as unexplained.
                let ctx = contexts.withLock { $0[String(key.split(separator: "\u{1F}")[0])] }
                var substituted = 0, unexplained = 0
                func explained(_ e: [String: Any]) -> Bool {
                    guard reader, let ctx, ctx.trusted else { return false }
                    let aliases = ((e["aliases"] as? [String]) ?? []).map(FactsText.fold)
                    return !aliases.isEmpty && aliases.allSatisfy { ctx.untrustedOnly.contains($0) }
                }
                func named(_ e: [String: Any]) -> String? {
                    let aliases = ((e["aliases"] as? [String]) ?? []).sorted { $0.count > $1.count }
                    return aliases.first { ctx?.text.contains($0) ?? false }
                }
                func list(_ k: String, _ part: Part, _ field: String) -> [[String: Any]] {
                    (part.raw[k] as? [[String: Any]] ?? []).compactMap { item in
                        var item = item
                        let (value, hidden) = tr(item[field], part)
                        item[field] = value
                        guard let hidden else { return item }
                        guard explained(hidden) else { unexplained += 1; return item }
                        substituted += 1
                        switch field {
                        case "person":
                            let shown = Set(swift.flatMap { $0.aliases ?? [] }.map(FactsText.fold))
                            item[field] = shown.contains(FactsText.fold(item["name"] as? String ?? "")) ? "different" : "new"
                        case "entity":
                            guard let name = named(hidden) else { return nil }
                            item[field] = "name"
                            item["name"] = name
                        default:
                            item[field] = named(hidden).map { "name:" + $0 } ?? "group"
                        }
                        return item
                    }
                }
                var out: [String: Any] = [
                    "facts": list("facts", src.facts, "entity"), "roles": list("roles", src.roles, "refers_to"),
                    "things": src.things.raw["things"] ?? [],
                ]
                if request.schema.json.contains("\"people\"") { out["people"] = list("people", src.people, "person") }
                s.unmapped += unmapped
                if reader { counts.withLock { $0.substituted += substituted; $0.unexplained += unexplained } }
                return try JSONSerialization.data(withJSONObject: out)
            }
            return (try HTTPClient.decode(String(decoding: data, as: UTF8.self), as: T.self), ProviderUsage(requests: 1))
        }

        /// The Swift roster's lines: `e…` → (aliases, or a role group's label and predicate).
        static func parseRoster(_ prompt: String) -> [(id: String, aliases: Set<String>?, group: (String, String)?)] {
            var out: [(String, Set<String>?, (String, String)?)] = []
            for line in prompt.split(separator: "\n").map(String.init) where line.hasPrefix("- e") {
                let body = line.dropFirst(2)
                guard let colon = body.range(of: ": ") else { continue }
                let id = String(body[..<colon.lowerBound]), rest = String(body[colon.upperBound...])
                if let m = rest.range(of: "^unnamed (.+) \\(([a-z_]+)(, count \\d+)?\\)$", options: .regularExpression) {
                    let s = String(rest[m])
                    let label = s.dropFirst("unnamed ".count).components(separatedBy: " (")[0]
                    let pred = s.components(separatedBy: " (").last!.components(separatedBy: CharacterSet(charactersIn: ",)"))[0]
                    out.append((id, nil, (pred, label)))
                } else if let dash = rest.range(of: " — ") {
                    out.append((id, Set(rest[..<dash.lowerBound].components(separatedBy: ", ")), nil))
                }
            }
            return out
        }

        static func translate(_ e: [String: Any], _ swift: [(id: String, aliases: Set<String>?, group: (String, String)?)]) -> String? {
            if let g = e["group"] as? [Any], e["name"] is NSNull || e["name"] == nil, let pred = g.first as? String {
                let label = (g.count > 1 ? g[1] as? String : nil) ?? pred
                let hits = swift.filter { $0.group.map { $0.0 == pred && $0.1 == label } ?? false }
                return hits.count == 1 ? hits[0].id : nil
            }
            let aliases = Set(e["aliases"] as? [String] ?? [])
            let exact = swift.filter { $0.aliases == aliases }
            if exact.count == 1 { return exact[0].id }
            guard let name = e["name"] as? String else { return nil }
            let loose = swift.filter { $0.aliases?.contains(name) ?? false }
            return loose.count == 1 ? loose[0].id : nil
        }
    }

    // MARK: Playing a story

    struct Play {
        var line: [String: Any]
        var judged: [(id: String, outcome: String)]
        var unmapped: Int
        var reasks: Int
        /// Memory versions reconciliation still found due after a drain (a loop if not 0).
        var unsettled = 0
        /// The gold reader's alias-trust substitutions, and unmapped ids it couldn't explain.
        var substituted = 0
        var unexplained = 0
        /// With `keep`: the vault as the play left it, and each fixture memory's id in it (13e.2's timeline gate).
        var vault: TestVault? = nil
        var vaultIDs: [String: String] = [:]
    }

    /// A monotonic clock: roster tokens are `updated_at` values compared as text.
    final class Clock: @unchecked Sendable {
        private let t = Mutex<Date>(t0)
        func now() -> Date { t.withLock { $0 = $0.addingTimeInterval(1); return $0 } }
    }

    /// The title every story memory gets (13e.2). A memory's title is its own field in the app (a summary, or the
    /// capture's first line), so a body sentence is never broken by the title's line break; a fixture's text is the
    /// memory's body, whole, under this neutral title. (Until 13e.2 the text was split at a space inside its last
    /// sentence, which hid that sentence from the sentence-bounded rules: a never-denial, the placeholder fold.)
    static let title = "Note"

    /// The stored text's offsets ahead of the story's text: the title and its line break (UTF-16 and code points alike).
    static let prefix = title.utf16.count + 1

    /// A story's text as a memory's title and body: the neutral title, and the text as written.
    static func split(_ text: String) -> (String, String) { (title, text) }

    /// The stored text of a story memory (`title\nbody`, as `FactStore.text` makes it).
    static func stored(_ text: String) -> String { title + "\n" + text }

    static func day(_ written: String) -> Date {
        let p = written.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }

    /// Plays one story in one order, through the facts lane: each memory's jobs are queued and the queue drained (with
    /// the reconciliation sweep and the partial re-reads it queues) before the next memory is added, as the spike's
    /// `play` reconciled after each memory. With `replay`, the recorded calls drive the schedule instead (as
    /// `replay.py`), each applied in its recorded scope; then the queue's sweep asks again whatever is still due, served
    /// from the recording.
    static func play(_ story: Fixture.Story, order: [String], orderIndex: Int, user: [String], provider: any GenerationProvider,
                     replay: [Recorded]?, groups: [String], label: String, registry: FactsRegistry = .bundled,
                     limit: CloudLimit = .upTo(.secret), prelude: [Fixture.Memory] = [],
                     memoryID: (@Sendable (String) -> UUID)? = nil, afterPrelude: (() throws -> Void)? = nil,
                     keep: Bool = false) async throws -> Play {
        let v = try TestVault()
        let clock = Clock()
        let router = ModelRouter(classifier: nil, onDevice: nil, cloudLimit: limit, factsModel: provider)
        var x = FactsExtractor(store: v.store, router: router, activity: InMemoryActivityLog(), registry: registry, userAliases: user,
                               qualification: .unchecked)
        x.clock = { clock.now() }
        let queue = ProcessingQueue(store: v.store, activity: InMemoryActivityLog(), launchedAt: .distantPast, ungatedFacts: true)
        let worker = FactsQueueWorker(extractor: x)
        // 13e.2's timeline gate: `prelude` (the shared fillers) is read first, each drained before the next, then the order.
        let mems = Dictionary(uniqueKeysWithValues: (prelude + story.memories).map { ($0.id, $0) })
        var vaultID: [String: String] = [:], fixtureID: [String: String] = [:]
        func add(_ mid: String) throws -> String {
            if let id = vaultID[mid] { return id }
            let m = mems[mid]!
            let (title, body) = split(m.text)
            let mem: Memory
            if let memoryID {
                // A fixed id per fixture memory (13e.2): search breaks ties by id, so a replay ranks as the run did.
                let draft = MemoryDraft(title: title, body: body, kind: .fact, categoryKeys: ["personal_preferences"],
                                        sensitivity: sensitivity(m.sensitivity))
                mem = try v.store.writer.write { db in
                    let id = memoryID(mid)
                    _ = try MemoryStore.insert(db, draft, actor: .user, now: day(m.written), id: id)
                    return try MemoryStore.fetch(db, id: id)!
                }
            } else {
                mem = try v.memory(title, body, sensitivity: sensitivity(m.sensitivity), now: day(m.written))
            }
            let source = ["agent": MemorySource.agentWrite, "import": .importMarkdown][m.source] ?? .captureMac
            let trust = m.trust ?? (m.source == "agent" ? "untrusted" : "trusted")
            try v.store.writer.write { db in
                try db.execute(sql: "UPDATE memory SET source = ?, trust = ? WHERE id = ?", arguments: [source.rawValue, trust, mem.id.db])
            }
            vaultID[mid] = mem.id.db
            fixtureID[mem.id.db] = mid
            return mem.id.db
        }
        let log = Mutex<[[String: Any]]>([])
        let fixtureIDs = Mutex<[String: String]>([:])
        @Sendable func record(_ r: FactsLearnReport, mode: String) {
            let ids = fixtureIDs.withLock { $0 }
            log.withLock { calls in
                for c in r.calls where c.outcome != .codeOnly {
                    calls.append(["memory": ids[c.memoryID] ?? c.memoryID, "group": c.group, "mode": mode, "reconcile": mode != "full",
                                  "ok": c.outcome == .applied, "ms": c.milliseconds, "promptTokens": c.usage.inputTokens,
                                  "outputTokens": c.usage.outputTokens, "dropped": c.dropped])
                }
            }
        }
        let rp = (provider as? Replay) ?? ((provider as? PayloadGuard)?.inner as? Replay)
        /// Drains the facts lane; a replayed re-ask is served the recording's answers for that memory and group.
        var unsettled = 0
        func drain() async throws {
            let ids = fixtureIDs.withLock { $0 }
            _ = try await queue.drain(now: { clock.now() }) { job in
                if let g = job.callGroup { rp?.reask(ids[job.subject.db] ?? job.subject.db, g) }
                return try await worker.process(job) { r, mode in record(r, mode: mode) }
            }
            // A fixpoint: once the lane is drained, reconciliation finds nothing left to ask.
            unsettled += try await v.store.writer.write { db in try FactsReconciler.reconcile(db, registry: registry, userAliases: user).count }
        }
        // For the gold reader: who, before each memory, was named only by untrusted memories (fixture labels).
        if let rp, rp.reader {
            var named: [String: (surfaces: Set<String>, trusted: Bool)] = [:]
            for mid in order {
                let m = mems[mid]!
                let only = Set(named.values.filter { !$0.trusted }.flatMap(\.surfaces))
                rp.context(mid, .init(text: m.text, trusted: m.trusted, untrustedOnly: only))
                for n in m.names ?? [] where !["user", "?"].contains(n.person) {
                    var e = named[n.person] ?? ([], false)
                    e.surfaces.insert(FactsText.fold(n.surface))
                    e.trusted = e.trusted || m.trusted
                    named[n.person] = e
                }
            }
        }
        if let replay {
            for r in replay where mems[r.memory] != nil {     // (trusted_only: an agent's memory left out)
                let id = try add(r.memory)
                fixtureIDs.withLock { $0 = fixtureID }
                rp?.expect(r)
                // The spike's re-asks were scoped: a roles re-ask applied every role answer, a names re-ask every name.
                var scope = FactsScope.full
                if r.mode != "full" {
                    scope = try await v.store.writer.read { db in
                        let g = try FactStore.load(db, registry: registry, userAliases: user).graph
                        guard let mem = try FactStore.countedMemories(db, ids: [id])[id]?.memory
                            ?? Row.fetchOne(db, sql: "SELECT title, body FROM memory WHERE id = ?", arguments: [id]).map({
                                FactsMemory(id: id, text: FactStore.text(title: $0["title"], body: $0["body"]), written: "", source: .capture, trusted: true)
                            }) else { return .full }
                        if r.mode == "roles" {
                            let starts = g.rolePhrases(mem.text, predicates: Set(registry.groupPredicates(r.group)))
                                .map { FactStore.scalarOffset(mem.text, utf16: $0.start) }
                            return .partial(roles: Set(starts), names: [])
                        }
                        let said = (r.raw["people"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                        let had = g.names.keys.filter { $0.memoryID == id }.map(\.surface)
                        return .partial(roles: [], names: Set((said + had).map { FactsText.fold($0) }))
                    }
                }
                record(try await x.learn([id], groups: [r.group], kind: r.mode == "full" ? "incremental" : "reconciliation", scope: scope),
                       mode: r.mode)
            }
            // Order memories the recording never read (none expected) are added so their role links resolve.
            for mid in order where vaultID[mid] == nil { _ = try add(mid) }
            fixtureIDs.withLock { $0 = fixtureID }
            try await drain()
        } else {
            for (k, mid) in (prelude.map(\.id) + order).enumerated() {
                if k == prelude.count, let afterPrelude { try afterPrelude() }
                let id = try add(mid)
                fixtureIDs.withLock { $0 = fixtureID }
                let now = clock.now()
                try await v.store.writer.write { db in
                    let version = try Int.fetchOne(db, sql: "SELECT version FROM memory WHERE id = ?", arguments: [id]) ?? 1
                    for g in groups {
                        try ProcessingQueue.enqueueFacts(db, memoryID: UUID(uuidString: id)!, version: version, group: g, reason: .version(text: true), now: now)
                    }
                }
                try await drain()
                if try applyCorrections(story, after: mid, store: v.store, registry: registry, user: user, vaultID: vaultID, now: clock.now()) {
                    try await drain()
                }
            }
        }
        let calls = log.withLock { $0 }
        // The final state, as the spike dumps it.
        var g = try await v.store.writer.read { db in try FactStore.load(db, registry: registry, userAliases: user).graph }
        for mid in order {
            guard let id = vaultID[mid], g.memories[id] == nil else { continue }
            let m = mems[mid]!
            let source: FactsMemory.Source = ["agent": .agent, "import": .import][m.source] ?? .capture
            g.memories[id] = FactsMemory(id: id, text: stored(m.text), written: m.written, source: source,
                                         trusted: (m.trust ?? (m.source == "agent" ? "untrusted" : "trusted")) == "trusted")
        }
        let dump = Dump(graph: g, fixtureID: fixtureID, texts: Dictionary(uniqueKeysWithValues: story.memories.map { ($0.id, $0.text) }),
                        order: order.compactMap { vaultID[$0] })
        var line = dump.people(calls: calls)
        line["story"] = story.id
        line["orderIndex"] = orderIndex
        line["order"] = order
        line["provider"] = label
        line["run"] = 1
        line["groups"] = groups.count > 1 ? "separate" : groups.first ?? ""
        line["registry"] = registry.version
        line["state"] = dump.state(user: user)
        var judged: [(String, String)] = []
        var answers: [String: Any] = [:]
        for q in story.queries ?? [] {
            judged.append((q.id, judge(g, q, timeline: story.timeline ?? [])))
            // What the answer named, for the gates' scorer (a gap answer that names someone on an undecidable question).
            if let it = g.intent(q.query) {
                let a = g.answer(it, query: q.query)
                answers[q.id] = ["entities": a.entities.compactMap { g.entities[$0]?.name }, "basis": "\(a.basis)"]
            }
        }
        line["swift_judged"] = Dictionary(judged, uniquingKeysWith: { a, _ in a })
        line["swift_answers"] = answers
        // 13e.2: each recorded comparison through the direct call, on the full graph and the trusted graph.
        if let comps = story.comparisons, let pred = registry.timelinePredicates.first {
            let rows = TimelineRows.build(g, predicate: pred, limit: 100)
            func alias(_ name: String) -> String {
                let n = FactsText.fold(name)
                return rows.rows.first { r in ([r.name] + r.renames).contains { FactsText.fold($0) == n } }?.alias ?? ""
            }
            let check = TimelineCheck(graph: g, local: nil, rows: rows)
            var direct: [String: Any] = [:]
            for c in comps where c.made {
                let cmp = TimelineComparison(predicate: pred, op: c.operator, anchor: c.anchor_org.isEmpty ? "" : alias(c.anchor_org),
                                             stint: c.stint, anchorDate: c.anchor_date, endDate: c.end_date,
                                             slot: c.kind == "any" ? "" : c.kind, answer: alias(c.answer_org))
                let n = ["first": 1, "second": 2][c.stint]
                guard let (it, _) = check.intent(cmp, stint: n) else { direct[c.id] = ["invalid": true]; continue }
                func run(_ gr: FactsGraph) -> [String: Any] {
                    let a = gr.answer(it, query: "")
                    return ["entities": a.entities.compactMap { gr.entities[$0]?.name }, "basis": "\(a.basis)"]
                }
                direct[c.id] = ["full": run(g), "trusted": run(g.trustedOnly(pred)),
                                "verdict": check.check(cmp, search: c.search).verdict.rawValue]
            }
            line["swift_direct"] = direct
        }
        return Play(line: line, judged: judged, unmapped: rp?.unmapped ?? 0, reasks: rp?.reasks ?? 0, unsettled: unsettled,
                    substituted: rp?.substituted ?? 0, unexplained: rp?.unexplained ?? 0, vault: keep ? v : nil,
                    vaultIDs: keep ? vaultID : [:])
    }

    /// A story's corrections after a memory, as the user's own operations in the store. True if any was applied.
    static func applyCorrections(_ story: Fixture.Story, after mid: String, store: VaultStore, registry: FactsRegistry,
                                 user: [String], vaultID: [String: String], now: Date) throws -> Bool {
        var applied = false
        for c in story.corrections ?? [] where c.after == mid {
            try store.writer.write { db in
                let g = try FactStore.load(db, registry: registry, userAliases: user).graph
                let names = Set((story.people?[c.person]?.names ?? []).map(FactsText.fold))
                guard let e = g.orderedEntities.first(where: { !Set($0.aliases.map(FactsText.fold)).isDisjoint(with: names) })?.id else { return }
                switch c.op {
                case "reject":
                    guard let target = c.memory.flatMap({ vaultID[$0] }), let surface = c.surface else { return }
                    _ = try FactStore.decideMention(db, memoryID: target, quote: surface, entityID: e, outcome: "rejected", now: now)
                default:
                    guard let pred = c.predicate ?? g.facts.first(where: { $0.entity == e })?.predicate, let value = c.value,
                          let fact = try String.fetchOne(db, sql: "SELECT id FROM fact WHERE entity_id = ? AND predicate = ? AND tombstone = 0",
                                                         arguments: [e, pred]) else { return }
                    _ = try FactStore.addUserEvidence(db, factID: fact, asserted: [c.op: value], sensitivity: Sensitivity.low.rawValue, now: now)
                }
                applied = true
            }
        }
        return applied
    }

    // MARK: Judging timeline questions in Swift (score_facts.judge)

    static let timelineKinds = ["before", "after", "year", "current", "previous", "no_answer"]
    static let modelledKinds: Set<String> = ["employee", "self_employed", "partner"]

    static func judge(_ g: FactsGraph, _ q: Fixture.Query, timeline: [Fixture.TimelineEntry]) -> String {
        judge(g, q, timeline: timeline, intent: g.intent(q.query))
    }

    /// The same judgment with the intent supplied (port fidelity: the time model compared with the grammar set aside).
    static func judge(_ g: FactsGraph, _ q: Fixture.Query, timeline: [Fixture.TimelineEntry], intent it: TimelineIntent?) -> String {
        guard timelineKinds.contains(q.kind) || ["negative", "role_in_stint"].contains(q.kind) else { return "not_timeline" }
        if ["negative", "role_in_stint"].contains(q.kind) { return it == nil ? "quiet" : "triggered" }
        let decidable = !(q.answer_org ?? "").isEmpty
        guard let it else { return decidable ? "miss" : "told_no_intent" }
        let ans = g.answer(it, query: q.query)
        // The truth's entity by name, independent of the system's own merges: a stated rename's answer is right only if
        // every name of its group is the truth's organization (by the kind's loose rule), so a wrong merge stays wrong.
        var want: Set<String> = decidable ? Set(g.entityMatches(it.predicate, q.answer_org!)) : []
        if decidable, !want.isEmpty {
            let loose = Set(g.byName(q.answer_org!, kind: g.registry.kindOf(it.predicate)).map(\.id)).union(want)
            for grp in g.statedGroups(it.predicate) where !grp.isDisjoint(with: want) && grp.isSubset(of: loose) {
                want.insert(g.timelineEntity(it.predicate, grp.first!))
            }
        }
        var got: String?
        if ans.entities.count > 1 {
            got = Set(ans.entities) == want && want.count == 1 ? want.first : "several"
        } else {
            got = ans.entities.first
        }
        guard let got else { return decidable ? "told_decidable" : "told" }
        let kinds = Set(timeline.filter { FactsText.fold($0.org) == FactsText.fold(q.answer_org) }.compactMap(\.kind))
        if decidable, want.isEmpty, ans.basis == .gap, !kinds.isEmpty, kinds.isDisjoint(with: modelledKinds) { return "told_gap" }
        if !decidable { return ans.basis == .gap ? "told_gap" : "wrong" }
        if want.contains(got) { return ans.basis == .gap ? "right_gap" : "right" }
        return "wrong"
    }
}

// MARK: - Dumps in the spike's shapes

extension FactsHarness {
    struct Dump {
        let graph: FactsGraph
        let fixtureID: [String: String]
        let texts: [String: String]
        let order: [String]
        let pid: [String: String]

        init(graph: FactsGraph, fixtureID: [String: String], texts: [String: String], order: [String]) {
            // Resolving can make a role group no stored fact has yet (a decision for the group); make them first, so
            // every link's person has an id in this dump.
            var graph = graph
            for id in order {
                guard let mem = graph.memories[id] else { continue }
                for ph in graph.rolePhrases(mem.text) where graph.registry.kindOf(ph.predicate) == FactsValidator.personKind {
                    _ = graph.resolve(mem, ph)
                }
            }
            self.graph = graph
            self.fixtureID = fixtureID
            self.texts = texts
            self.order = order
            var pid: [String: String] = [:]
            for (i, e) in graph.orderedEntities.enumerated() { pid[e.id] = "p\(i + 1)" }
            self.pid = pid
        }

        func mid(_ id: String) -> String { fixtureID[id] ?? id }
        /// A surface as the story writes it (a story's own line breaks read as spaces, as the spike's scorers compare).
        func flat(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }
        func p(_ id: String?) -> Any { id.flatMap { pid[$0] } ?? NSNull() }

        /// UTF-16 offset in the stored text → code-point offset in the story's text (Python's `str.find`): the title and
        /// its line break come first.
        func codePoint(_ memoryID: String, _ utf16: Int) -> Int {
            let t = graph.memories[memoryID]?.text ?? ""
            return FactStore.scalarOffset(t, utf16: utf16) - FactsHarness.prefix
        }

        func people(calls: [[String: Any]]) -> [String: Any] {
            var g = graph
            var links: [[String: Any]] = []
            for id in order {
                guard let mem = g.memories[id] else { continue }
                for ph in g.rolePhrases(mem.text) where g.registry.kindOf(ph.predicate) == FactsValidator.personKind {
                    let (e, basis) = g.resolve(mem, ph)
                    var link: [String: Any] = ["memory": mid(id), "kind": "role", "start": codePoint(id, ph.start), "surface": flat(ph.surface),
                                               "person": basis == .someoneElse ? NSNull() : p(e), "basis": basis.rawValue,
                                               "predicate": ph.predicate]
                    if basis == .candidates {
                        let (d, w) = g.asOf(mem, ph)
                        link["candidates"] = g.holders(ph, asOf: d, written: w).holders.map { p($0.entity.id) }
                    }
                    links.append(link)
                }
                for (key, n) in g.names where key.memoryID == id {
                    links.append(["memory": mid(id), "kind": "name", "surface": flat(key.surface), "person": p(n.entity),
                                  "basis": n.basis.rawValue, "candidates": n.candidates.map { p($0) }])
                }
            }
            let persons = g.orderedEntities.filter { $0.kind == FactsValidator.personKind }
            return [
                "links": links,
                "people": persons.map { e in
                    ["id": p(e.id), "name": e.name ?? NSNull(), "aliases": e.aliases.sorted(),
                     "group": e.group.map { [$0.predicate, $0.cls ?? NSNull()] as [Any] } ?? NSNull(), "count": e.count ?? NSNull()] as [String: Any]
                },
                "relations": g.facts.filter { g.entities[$0.entity]?.kind == FactsValidator.personKind }.map { f in
                    ["person": p(f.entity), "type": f.predicate, "label": f.label ?? NSNull(), "cls": f.cls ?? NSNull(),
                     "status": g.status(of: f).rawValue, "valid_from": NSNull(), "valid_to": NSNull(),
                     "deceased": g.entities[f.entity]?.deceased ?? false, "only": f.only, "negated": f.negated, "trusted": f.trusted,
                     "evidence": f.assertions.filter { !$0.fromUser }.map { mid($0.memoryID) }] as [String: Any]
                },
                "decisions": g.decisions.sorted { ($0.key.memoryID, $0.key.start) < ($1.key.memoryID, $1.key.start) }.map { k, d in
                    ["memory": mid(k.memoryID), "start": codePoint(k.memoryID, k.start),
                     "person": d.basis == .someoneElse ? "someone_else" : p(d.entity), "basis": d.basis.rawValue] as [String: Any]
                },
                "things": things.map { ["name": $0.0, "kind": $0.1] },
                "calls": calls,
            ]
        }

        /// Each timeline predicate's episodes as the Swift time model derives them (days are proleptic ordinals, Python's
        /// `date.toordinal`), with who ended each by succession: the timeline gate's facts and dates are scored from these.
        func episodes() -> [[String: Any]] {
            func range(_ r: DateRange?) -> Any { r.map { [$0.lo, $0.hi, "\($0.precision)"] as [Any] } ?? NSNull() }
            return graph.registry.timelinePredicates.flatMap { pred in
                graph.episodes(pred).filter { $0.entity != nil }.map { e in
                    ["entity": p(e.entity), "predicate": pred, "start": range(e.start), "end": range(e.end), "slot": e.slot,
                     "inferred_end": e.inferredEnd, "former": e.former, "uncertain": e.uncertain, "trusted": e.trusted,
                     "start_trusted": e.startTrusted, "end_trusted": e.endTrusted,
                     "memories": Array(Set(e.assertions.filter { !$0.fromUser }.map { mid($0.memoryID) })).sorted(),
                     "ended_by": e.endedBy.map { p($0.entity) } ?? NSNull()] as [String: Any]
                }
            }
        }

        /// The timeline gate's "0 succession from untrusted text or across slots", checked two ways: every inferred end's
        /// successor started on trusted evidence in the same slot; and with every untrusted assertion removed, every
        /// inferred end of an episode with trusted evidence is still inferred (so no untrusted row caused it).
        func succession() -> [String: Any] {
            var untrusted: [String] = [], crossSlot: [String] = [], unexplained: [String] = []
            var trustedOnly = graph
            for i in trustedOnly.facts.indices { trustedOnly.facts[i].assertions.removeAll { !$0.trusted } }
            for pred in graph.registry.timelinePredicates {
                let kept = trustedOnly.episodes(pred)
                for e in graph.episodes(pred) where e.inferredEnd {
                    let at = "\(p(e.entity)) \(pred) \(e.start.map { "\($0.lo)" } ?? "-")"
                    guard let by = e.endedBy else { unexplained.append(at); continue }
                    if !by.startTrusted || !by.trusted { untrusted.append(at) }
                    if by.slot != e.slot { crossSlot.append(at) }
                    if e.assertions.contains(where: { $0.trusted }),
                       !kept.contains(where: { $0.entity == e.entity && $0.inferredEnd && $0.start?.lo == e.start?.lo }) {
                        untrusted.append(at + " (gone without untrusted rows)")
                    }
                }
            }
            return ["from_untrusted": untrusted, "across_slots": crossSlot, "without_successor": unexplained]
        }

        var things: [(String, String)] {
            graph.orderedEntities.filter { $0.kind != FactsValidator.personKind && $0.name != nil }.map { ($0.name!, $0.kind) }
        }

        func state(user: [String]) -> [String: Any] {
            let g = graph
            return [
                "registry": g.registry.version,
                "entities": g.orderedEntities.map { e in
                    ["id": p(e.id), "kind": e.kind, "name": e.name ?? NSNull(), "aliases": e.aliases.sorted(),
                     "group": e.group.map { [$0.predicate, $0.cls ?? NSNull()] as [Any] } ?? NSNull(),
                     "count": e.count ?? NSNull(), "deceased": e.deceased] as [String: Any]
                },
                "facts": g.facts.map { f in
                    let rows = f.assertions.filter { !$0.fromUser }
                    return ["entity": p(f.entity), "type": f.predicate, "label": f.label ?? NSNull(), "cls": f.cls ?? NSNull(),
                            "status": g.status(of: f).rawValue, "valid_from": NSNull(), "valid_to": NSNull(), "only": f.only,
                            "negated": f.negated,
                            "evidence": rows.map { [mid($0.memoryID), $0.trusted ? "trusted" : "untrusted"] },
                            "stating": rows.filter(\.states).map { mid($0.memoryID) },
                            "assertions": rows.map { a in
                                ["memory": mid(a.memoryID), "trust": a.trusted ? "trusted" : "untrusted", "written": a.written,
                                 "start": a.start ?? NSNull(), "end": a.end ?? NSNull(), "status": a.status.rawValue,
                                 "time": a.time ?? NSNull(), "preceded_by": a.precededBy ?? NSNull(),
                                 "followed_by": a.followedBy ?? NSNull(), "qualifiers": a.qualifiers, "states": a.states,
                                 "label": a.label ?? NSNull(), "quote": a.quote, "handover": a.handover] as [String: Any]
                            }] as [String: Any]
                },
                "names": g.names.sorted { ($0.key.memoryID, $0.key.surface) < ($1.key.memoryID, $1.key.surface) }.map { k, n in
                    [mid(k.memoryID), flat(k.surface), p(n.entity), n.basis.rawValue, n.candidates.map { p($0) }] as [Any]
                },
                // Sorted: a dictionary's order changes with each process's hash seed, and the gate's digests must not.
                "decisions": g.decisions.sorted { ($0.key.memoryID, $0.key.start) < ($1.key.memoryID, $1.key.start) }.map { k, d in
                    [mid(k.memoryID), codePoint(k.memoryID, k.start), d.basis == .someoneElse ? "someone_else" : p(d.entity),
                     d.basis.rawValue] as [Any]
                },
                "things": things.map { [$0.0, $0.1] },
                "episodes": episodes(),
                // Stated renames read as one entity on the timeline (13e.1): an episode's entity stands for its group.
                // By dump id (order made), not entity id (new each run), so a replay dumps what the live read did.
                "timeline_groups": g.registry.timelinePredicates.flatMap { g.statedGroups($0) }.map { $0.compactMap { pid[$0] }.sorted() }
                    .sorted { $0.lexicographicallyPrecedes($1) },
                "succession": succession(),
                "user_aliases": user,
                "memories": Dictionary(uniqueKeysWithValues: order.compactMap { id -> (String, Any)? in
                    guard let m = g.memories[id] else { return nil }
                    return (mid(id), ["id": mid(id), "text": texts[mid(id)] ?? m.text, "written": m.written,
                                      "source": m.source == .agent ? "agent" : m.source == .import ? "import" : "capture",
                                      "trust": m.trusted ? "trusted" : "untrusted"] as [String: Any])
                }),
                "calls": [] as [Any],
            ]
        }
    }
}

extension FactsHarness {
    /// Port fidelity's investigated differences (`spikes/people/port_fidelity_known.json`): key → (rule, facts.py's value,
    /// Swift's value). An entry excuses only exactly that difference.
    static func knownPortDifferences() throws -> [String: (rule: String, python: String?, swift: String?)] {
        let url = repo.appending(path: "spikes/people/port_fidelity_known.json")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var out: [String: (rule: String, python: String?, swift: String?)] = [:]
        for e in d?["differences"] as? [[String: Any]] ?? [] {
            if let at = e["at"] as? String, let rule = e["rule"] as? String { out[at] = (rule, e["python"] as? String, e["swift"] as? String) }
        }
        return out
    }
}
