import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 6a (task 6a.7): Spike E's fixtures through the whole pipeline (every ingest path, the
/// processing job, extraction, validation, the finder, the decision call and the group), with
/// Claude Opus 5.5's recorded outputs (the v2 extraction prompt) replayed by `RecordedProvider`.
/// Measures claim recall, wrong claims (including the injection attempts), links and the
/// rejected secrets, on both fixture sets.
///
/// The finder uses bge-small when it's fetched (`sh scripts/fetch_embedding_model.sh`) and is
/// keyword-only otherwise. Measured 2026-10-24 (both ways within a point): set 1 recall 207/210
/// (in25's 33 claims meet the 30-a-chunk cap), links 230/240; set 2 recall 69/69, links 63/65; no
/// wrong claims. Spike E (Opus, v2, the Python stand-in finder): recall 100%, links 95%.
@Suite(.serialized) struct SpikeEFixtureTests {
    struct Measured {
        var required = 0, found = 0
        var wrong: [String] = []
        var linksRight = 0, linksJudged = 0
        var linkMisses: [String] = []
        var rejected: [String: String] = [:]
        var variantMismatches: [String] = []
        var pieceCountMismatches: [String] = []
        var groups = 0, singles = 0, unchanged = 0
        var outsideScope = 0
        var recall: Double { Double(found) / Double(max(1, required)) }
        var links: Double { Double(linksRight) / Double(max(1, linksJudged)) }
    }

    static func run(_ set: String) async throws -> Measured {
        let file = try SpikeE.inputs(set)
        let now = SpikeE.day(file.now)
        let fx = try ServiceFixture()
        let v = fx.vault
        // Only the Spike E vault: drop the fixture's own memories.
        try await v.store.writer.write { db in try db.execute(sql: "DELETE FROM memory") }
        let ids = try SpikeE.loadVault(into: v)
        let byID = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
        try fx.setAccess {
            $0.operations = [.read, .suggest]
            $0.maxSensitivity = .restricted
            $0.allowedCategoryKeys = []
            $0.deniedCategoryKeys = []
            $0.askBeforeSaving = true
        }
        var indexer: EmbeddingIndexer?
        if let dir = Fixtures.modelDirectory {
            let i = EmbeddingIndexer(store: v.store, provider: try BundledBGEEmbedder(directory: dir))
            try await i.embedPending()
            indexer = i
        }
        let provider = try RecordedProvider()
        // Spike E sent everything; the cloud limit has its own tests.
        let router = ModelRouter(classifier: provider, onDevice: nil, cloudLimit: .upTo(.secret))
        let captures = CaptureService(store: v.store, activity: fx.activity)
        let suggestions = SuggestionService(store: v.store, activity: fx.activity, pause: fx.pause)
        let imports = ImportService(store: v.store, activity: fx.activity)
        let processor = NewMemoryProcessor(store: v.store, captures: captures, finder: RelatedMemoryFinder(store: v.store, indexer: indexer),
                                           now: { now }, configuration: { .init(router: router, split: true) })
        let queue = ProcessingQueue(store: v.store, activity: fx.activity)

        var m = Measured()
        for input in file.inputs {
            let subject: UUID
            do {
                subject = try await ingest(input, fx: fx, captures: captures, suggestions: suggestions, imports: imports, now: now)
            } catch VaultError.secretLikeContent(let findings) {
                m.rejected[input.id] = findings.first?.rawValue
                continue
            }
            guard let job = try await queue.claim(now: now) else { Issue.record("\(input.id): no job"); continue }
            #expect(job.subject == subject)
            provider.begin(input.id)
            try await queue.finish(job, try await processor.process(job), now: now)

            if let seen = provider.seen.withLock({ $0.variants[input.id] }), seen != input.variant {
                m.variantMismatches.append(input.id)
            }
            // The pieces as stored: a group, or the one suggestion.
            let pieces: [Suggestion]
            if let group = try await suggestions.group(id: subject) {
                pieces = group.pieces
                m.groups += 1
                // At most 30 pieces a chunk (Spike E's run had no cap).
                let recorded = provider.recordings[input.id].map { min($0.keptPieces, ExtractionPrompt.maxPiecesPerChunk * $0.extract.count) }
                if group.pieces.count != recorded { m.pieceCountMismatches.append(input.id) }
            } else {
                let s = try #require(try await suggestions.suggestion(id: subject))
                pieces = [s]
                if JSON.decode(ClassificationRecord.self, s.classification)?.piece != nil { m.singles += 1 } else { m.unchanged += 1 }
            }
            m.outsideScope += pieces.filter(\.outsideScope).count
            score(input, pieces: pieces, names: byID, into: &m)
        }
        return m
    }

    static func ingest(_ input: SpikeE.Input, fx: ServiceFixture, captures: CaptureService, suggestions: SuggestionService,
                       imports: ImportService, now: Date) async throws -> UUID {
        let firstLine = CaptureProposal.trim(String(input.text.split(whereSeparator: \.isNewline).first ?? ""), to: 80)
        switch input.type {
        case "seed_answer":
            let question = try #require(SeedQuestion.all.first { $0.id == input.hint?.seedId })
            return try await suggestions.seed(question, answer: input.text, now: now)
        case "agent":
            let outcome = try await suggestions.suggest(agentID: fx.agentID, SuggestInput(
                title: firstLine, body: input.text, sensitivity: input.declaredSensitivity.flatMap(Sensitivity.init(name:))), now: now)
            if outcome.reason == .secretLikeContent { throw VaultError.secretLikeContent(outcome.findings) }
            return try #require(outcome.suggestionID, "\(input.id): \(String(describing: outcome.reason))")
        case "import_chatgpt", "import_claude", "import_markdown":
            let source: ImportSource = input.type == "import_chatgpt" ? .chatgpt : input.type == "import_claude" ? .claude : .markdown
            let preview = try await imports.preview([ImportItem(title: firstLine, body: input.text)], source: source)
            if case let .blocked(findings) = preview.entries[0].status { throw VaultError.secretLikeContent(findings) }
            return try #require(try await imports.commit(preview, includeDuplicates: true, now: now).suggestionIDs.first)
        default:
            return try await captures.capture(input.text, now: now).suggestionID
        }
    }

    /// What a piece claims: an update's own claim, not the target's new text.
    static func text(_ s: Suggestion) -> String {
        JSON.decode(ClassificationRecord.self, s.classification)?.piece?.claim.map { "\(s.title) \($0)" } ?? "\(s.title) \(s.body)"
    }

    static func score(_ input: SpikeE.Input, pieces: [Suggestion], names: [UUID: String], into m: inout Measured) {
        for e in input.expected {
            let match = pieces.first { p in e.keys.allSatisfy { SpikeE.matches($0, text(p)) } }
            let covered = match != nil || e.keys.allSatisfy { k in pieces.contains { SpikeE.matches(k, text($0)) } }
            if e.optional != true {
                m.required += 1
                if covered { m.found += 1 }
            }
            guard let p = match else { continue }
            let action = switch p.action {
            case .update: "update"
            case .duplicate: "duplicate"
            case .archive: "retract"
            default: "create"
            }
            let target = p.targetMemoryID.flatMap { names[$0] }
            let right = e.link.decision.contains(action) && (action == "create" || target.map(e.link.target.contains) == true)
            m.linksJudged += 1
            if right { m.linksRight += 1 } else { m.linkMisses.append("\(input.id): \(action) \(target ?? "") (expected \(e.link.decision) \(e.link.target))") }
        }
        for rule in input.mustNot {
            for p in pieces {
                let hit: Bool
                if let intent = rule.intent {
                    hit = p.intent?.rawValue == intent
                } else if let retract = rule.retract {
                    hit = p.action == .archive && (retract == "*" || p.targetMemoryID.flatMap { names[$0] } == retract)
                } else {
                    hit = (rule.all ?? []).allSatisfy { SpikeE.matches($0, text(p)) }
                        && !(rule.none ?? []).contains { SpikeE.matches($0, text(p)) }
                }
                if hit { m.wrong.append("\(input.id): \(rule.label) [\(text(p))]") }
            }
        }
    }

    static func report(_ label: String, _ m: Measured) {
        let line = String(format: "%@: recall %d/%d (%.3f), links %d/%d (%.3f), wrong %d, groups %d, singles %d, unchanged %d, outside %d, model %@",
                          label, m.found, m.required, m.recall, m.linksRight, m.linksJudged, m.links, m.wrong.count, m.groups, m.singles,
                          m.unchanged, m.outsideScope, Fixtures.modelAvailable ? "bge-small" : "keyword-only")
        FileHandle.standardError.write(Data((line + "\n").utf8))
        if ProcessInfo.processInfo.environment["FUNES_SPIKE_E_VERBOSE"] != nil {
            for miss in m.linkMisses { FileHandle.standardError.write(Data(("  link: \(miss)\n").utf8)) }
            FileHandle.standardError.write(Data(("  piece counts differ: \(m.pieceCountMismatches)\n").utf8))
        }
    }

    @Test func firstSet() async throws {
        let m = try await Self.run("inputs")
        Self.report("Spike E set 1", m)
        #expect(m.rejected == ["in16": "assigned_secret", "in62": "openai_style_key"])
        #expect(m.variantMismatches.isEmpty)
        #expect(m.recall >= 0.98)
        #expect(m.wrong.isEmpty, "\(m.wrong)")
        #expect(m.links >= 0.93, "\(m.linkMisses)")
        // Validation keeps what Spike E's did, so the decisions line up.
        #expect(m.pieceCountMismatches.isEmpty, "\(m.pieceCountMismatches)")
    }

    @Test func secondSetWrittenBlind() async throws {
        let m = try await Self.run("inputs-astra")
        Self.report("Spike E set 2 (Astra)", m)
        #expect(m.rejected.keys.sorted() == ["a14"])
        #expect(m.variantMismatches.isEmpty)
        #expect(m.recall >= 0.98)
        #expect(m.wrong.isEmpty, "\(m.wrong)")
        #expect(m.links >= 0.93, "\(m.linkMisses)")
        #expect(m.pieceCountMismatches.isEmpty, "\(m.pieceCountMismatches)")
    }
}
