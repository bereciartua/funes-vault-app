import Foundation
import FunesProtocol
import GRDB
import Synchronization
import Testing
@testable import FunesCore

/// Spike F's 12 episodes (long agent-written memories about one episode or entity each, from
/// spikes/memory-processing/fixtures/episodes.json) split by the tidy-up with Claude Opus 5.5's
/// recorded outputs of the prompt Funes ships (C3), replayed by `EpisodeReplay`.
///
/// The replay finds each episode by the `title` of the note tag, so every split here also shows
/// that the memory's title reaches the model. Funes's validation (quotes and words checked against
/// the title, the date and the text) keeps exactly the pieces the spike's Python validation kept.
/// Spike F (Opus, C3): 140 of 141 keep facts, 6 of 26 drop facts kept, 163 of 168 pieces about an
/// episode name its subject.
@Suite struct SpikeFFixtureTests {
    struct Fact: Decodable {
        let id: String
        let keys: [String]
        let keep: String
        let other: Bool
        let subject: [String]?
    }

    struct Episode: Decodable {
        let id: String
        let title: String
        let written: String
        let source: String
        let sensitivity: String
        let categories: [String]
        let subject: [String]
        let text: String
        let facts: [Fact]
    }

    struct File: Decodable { let episodes: [Episode] }

    static func episodes() throws -> [Episode] {
        try JSONDecoder().decode(File.self, from: Data(contentsOf: SpikeE.url("episodes"))).episodes
    }

    /// Replays the recorded extraction of each chunk, by the note tag's title; no tidy-up actions,
    /// no decisions.
    final class EpisodeReplay: GenerationProvider {
        let id: ProviderID = "anthropic"
        let locality: Locality = .cloud
        let modelID = "claude-opus-5-5"
        struct Recording: @unchecked Sendable {
            let extract: [Any]
            let kept: Int
        }

        let recordings: [String: Recording]
        let byTitle: [String: String]
        let seen = Mutex<[String: Int]>([:])

        init(_ episodes: [Episode]) throws {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: SpikeE.url("recorded-episodes-claude-opus"))) as! [String: Any]
            var recordings: [String: Recording] = [:]
            for (key, value) in root["episodes"] as! [String: [String: Any]] {
                recordings[key] = Recording(extract: value["extract"] as! [Any], kept: value["keptPieces"] as! Int)
            }
            self.recordings = recordings
            byTitle = Dictionary(uniqueKeysWithValues: episodes.map { ($0.title, $0.id) })
        }

        func generate<T: Decodable & Sendable>(_ request: StructuredRequest<T>) async throws -> (T, ProviderUsage) {
            let object: [String: Any]
            switch request.schemaName {
            case "Extraction":
                let title = SpikeE.regex(#"<note title="([^"]*)" written="[^"]+">"#)
                    .firstMatch(in: request.prompt, range: NSRange(request.prompt.startIndex..., in: request.prompt))
                    .flatMap { Range($0.range(at: 1), in: request.prompt) }.map { String(request.prompt[$0]) }
                guard let title, let episode = byTitle[title], let recording = recordings[episode] else { throw ProviderError.invalidOutput }
                let chunk = request.prompt.contains("<context>") ? 1 : 0
                seen.withLock { $0[episode, default: 0] += 1 }
                object = ["pieces": chunk < recording.extract.count ? recording.extract[chunk] : []]
            case "TidyUp":
                object = ["actions": []]
            default:
                object = ["decisions": []]
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            return (try HTTPClient.decode(json, as: T.self), ProviderUsage(requests: 1))
        }
    }

    @Test func theEpisodesSplitIntoPiecesThatNameTheirSubject() async throws {
        let episodes = try Self.episodes()
        #expect(episodes.count == 12)
        let v = try TestVault()
        var ids: [String: UUID] = [:]
        for e in episodes {
            let m = try v.store.createMemory(MemoryDraft(title: e.title, body: e.text, kind: .summary, categoryKeys: e.categories,
                                                         sensitivity: Sensitivity(name: e.sensitivity), source: .agentWrite,
                                                         trust: .untrusted), now: SpikeE.day(e.written))
            ids[e.id] = m.id
        }
        let provider = try EpisodeReplay(episodes)
        let log = InMemoryActivityLog()
        // Spike F sent everything; the cloud limit has its own tests.
        let run = try await TidyUpService(store: v.store, activity: log).run(
            .init(router: ModelRouter(classifier: provider, onDevice: nil, cloudLimit: .upTo(.secret))), now: SpikeE.day("2026-10-24"))
        #expect(run.error == nil && run.suggestions == 12)
        // Every episode's title reached the prompt; e01, e05 and e12 needed two chunks.
        let calls = provider.seen.withLock { $0 }
        #expect(calls.count == 12 && calls.filter { $0.value == 2 }.keys.sorted() == ["e01", "e05", "e12"])

        let suggestions = SuggestionService(store: v.store, activity: log, pause: FunesPause())
        let proposals = try await suggestions.pending().filter { $0.origin == .consolidation && $0.action == .split }
        var keep = (found: 0, of: 0), drop = (kept: 0, of: 0), subject = (named: 0, of: 0)
        var countMismatches: [String] = []
        for e in episodes {
            let proposal = try #require(proposals.first { $0.targetMemoryID == ids[e.id] }, "\(e.id)")
            let pieces = try #require(try await suggestions.group(id: proposal.id)?.pieces).map { "\($0.title) \($0.body)" }
            if pieces.count != provider.recordings[e.id]?.kept { countMismatches.append("\(e.id): \(pieces.count)") }
            func hits(_ f: Fact) -> [Int] { pieces.indices.filter { i in f.keys.allSatisfy { SpikeE.matches($0, pieces[i]) } } }
            for f in e.facts where f.keep != "either" {
                let found = !hits(f).isEmpty
                if f.keep == "keep" { keep.of += 1; keep.found += found ? 1 : 0 } else { drop.of += 1; drop.kept += found ? 1 : 0 }
            }
            for i in pieces.indices {
                let about = e.facts.filter { !$0.other && hits($0).contains(i) }
                guard !about.isEmpty else { continue }
                subject.of += 1
                let names = Set(about.flatMap { $0.subject ?? e.subject })
                if names.contains(where: { SpikeE.matches($0, pieces[i]) }) { subject.named += 1 }
            }
        }
        print("Spike F episodes: keep \(keep.found)/\(keep.of), drop kept \(drop.kept)/\(drop.of), subject \(subject.named)/\(subject.of)")
        #expect(countMismatches.isEmpty, "\(countMismatches)")
        #expect(keep.found >= keep.of - 1)
        #expect(drop.kept <= 6)
        #expect(Double(subject.named) >= 0.95 * Double(subject.of))
    }
}
