import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Phase 6a.1–6a.2: chunking, the extraction request, validation (memory processing §5.3–§5.4),
/// the related-memories finder and the decision call (§5.5).
@Suite struct ExtractionTests {
    typealias Raw = ExtractionPrompt.RawPiece
    static let categories = MemoryCategory.builtins

    static func raw(_ body: String, quote: String? = nil, title: String = "T", categories: [String] = ["personal_preferences"],
                    sensitivity: String = "low", atomic: Bool? = true, confidence: Double? = 0.9) -> Raw {
        Raw(evidence: [quote ?? body], body: body, title: title, kind: "fact", categoryKeys: categories, sensitivity: sensitivity,
            timeLimited: false, intent: "assertion", atomic: atomic, confidence: confidence)
    }

    static func validate(_ raw: [[Raw]], source: String, floors: ExtractionValidator.Floors = .init()) -> ExtractionValidator.Outcome {
        ExtractionValidator.validate(raw, source: source, categories: categories, floors: floors)
    }

    // MARK: Chunking

    @Test func chunksOnParagraphsThenSentences() {
        #expect(Chunker.chunks("  Short note.  ") == ["Short note."])
        let sentence = String(repeating: "word ", count: 59) + "end."  // 299 characters
        let paragraph = Array(repeating: sentence, count: 4).joined(separator: " ")  // about 1,200
        let text = [paragraph, paragraph, paragraph].joined(separator: "\n\n")
        let chunks = Chunker.chunks(text)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.count <= Chunker.size })
        #expect(chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace) == text.split(whereSeparator: \.isWhitespace))
        // A paragraph boundary is kept inside a chunk.
        #expect(chunks[0].contains("\n\n"))
        // A sentence longer than a chunk is cut at a space.
        let long = Chunker.chunks(String(repeating: "abcdefghi ", count: 450))
        #expect(long.count == 3 && long.allSatisfy { $0.count <= Chunker.size && !$0.hasPrefix(" ") })
    }

    @Test func theLongestFixtureNeedsTwoChunks() throws {
        let text = try #require(try SpikeE.inputs().inputs.max { $0.text.count < $1.text.count }?.text)
        #expect(text.count == 2_204)
        #expect(Chunker.chunks(text).count == 2)
    }

    // MARK: The request

    @Test func requestHasBothVariantsTheCompoundRuleAndEvidenceFirst() throws {
        let first = ExtractionPrompt.request(chunk: "I like tea.", context: nil, hint: nil, variant: .firstPerson, categories: Self.categories)
        let about = ExtractionPrompt.request(chunk: "The user likes tea.", context: "Earlier text", hint: nil, variant: .aboutUser,
                                             categories: Self.categories)
        #expect(first.instructions.contains("typed, dictated or shared by the user"))
        #expect(about.instructions.contains("written by an AI assistant"))
        #expect(first.instructions.contains("Split into the smallest pieces that each still make sense on their own"))
        #expect(first.instructions.contains("- health: "))
        #expect(first.prompt == "<note>\nI like tea.\n</note>")
        #expect(about.prompt.hasPrefix("<context>\nEarlier text\n</context>"))
        let seed = ExtractionPrompt.prompt(chunk: "x", context: nil, hint: ExtractionHint(question: "Q?", kind: .goal, categoryKey: "project_context"))
        #expect(seed.hasPrefix("The note answers the question: \"Q?\" (likely kind goal, category project_context)."))
        // Properties keep their order on the wire: evidence before body.
        let json = first.schema.json
        let evidence = try #require(json.range(of: "\"evidence\""))
        let body = try #require(json.range(of: "\"body\""))
        #expect(evidence.lowerBound < body.lowerBound)
        #expect(!json.contains("maxItems"))
        #expect((try JSONSerialization.jsonObject(with: Data(json.utf8))) is [String: Any])
    }

    /// Spike F: the note tag carries the title and written date, the rules ask each piece to name its
    /// subject and an episode's time, and the context may supply names.
    @Test func theNoteTagCarriesTheTitleAndDate() {
        let utc = TimeZone(identifier: "UTC")!
        let written = SpikeE.day("2026-10-14")
        let note = ExtractionNote(title: "Interview loop at \"Verdant\" Grid\n(Staff Data Engineer)", written: written)
        let prompt = ExtractionPrompt.prompt(chunk: "The user completed the loop.", context: "Earlier text", hint: nil, note: note,
                                             timeZone: utc)
        #expect(prompt.hasSuffix("""
            <note title="Interview loop at 'Verdant' Grid (Staff Data Engineer)" written="Wednesday 14 October 2026">
            The user completed the loop.
            </note>
            """))
        #expect(prompt.contains("</context>\n(The context is the text just before the note: extract nothing from it, but use its names"))
        // A capture's title isn't the user's: the date only.
        let capture = ExtractionPrompt.prompt(chunk: "Ran 21 km this morning.", context: nil, hint: nil,
                                              note: ExtractionNote(title: nil, written: written), timeZone: utc)
        #expect(capture == "<note written=\"Wednesday 14 October 2026\">\nRan 21 km this morning.\n</note>")
        #expect(note.header(timeZone: utc) == "Interview loop at 'Verdant' Grid (Staff Data Engineer)\nWednesday 14 October 2026\n")
        let rules = ExtractionPrompt.instructions(.aboutUser, categories: Self.categories)
        for rule in ["Name its subject: who or what it is about, by name", "Anchor in time what belongs to an episode or a moment",
                     "Never put a date on a lasting fact or preference", "Keep its status:",
                     "Keep only what could help an assistant later. Keep every fact about the note's subject itself",
                     "title: at most 80 characters, naming the subject too."] {
            #expect(rules.contains(rule), "\(rule)")
        }
        #expect(ExtractionPrompt.version == 2)
    }

    /// Validation compares quotes and words against the title and date as well as the text.
    @Test func aNameFromTheTitleIsSupported() throws {
        let utc = TimeZone(identifier: "UTC")!
        let note = ExtractionNote(title: "Interview loop at Verdant Grid", written: SpikeE.day("2026-10-14"))
        let text = "The hiring manager said the role is fully remote."
        let piece = Self.raw("The Staff role at Verdant Grid is fully remote (October 2026).",
                             quote: "<note title=\"Interview loop at Verdant Grid\" written=\"Wednesday 14 October 2026\">the role is fully remote")
        let fromTitle = Self.raw("I interviewed at Verdant Grid.", quote: "Interview loop at Verdant Grid")
        let with = Self.validate([[piece, fromTitle]], source: note.header(timeZone: utc) + text)
        #expect(with.pieces.count == 2)
        #expect(with.pieces[0].unsupportedWords == ["staff"])
        let without = Self.validate([[piece, fromTitle]], source: text)
        #expect(without.pieces.count == 1 && without.dropped[.evidence] == 1)
        #expect(without.pieces[0].unsupportedWords == ["2026", "grid", "october", "staff", "verdant"])
    }

    // MARK: Validation

    @Test func evidenceMustBeVerbatimAfterNormalizing() {
        let source = "I’m allergic to peanuts — and I don't eat  shellfish."
        let out = Self.validate([[
            Self.raw("I'm allergic to peanuts.", quote: "<note>I'm allergic to peanuts</note>"),  // tags stripped, quotes normalized
            Raw(evidence: ["", "  I DON'T eat shellfish. "], body: "I don't eat shellfish.", title: "Shellfish"),  // empty ignored
            Self.raw("I'm allergic to tree nuts.", quote: "allergic to tree nuts"),  // not in the input
            Raw(evidence: [], body: "No quotes", title: "x"),
            Raw(evidence: ["peanuts"], body: "  ", title: "x"),
        ]], source: source)
        #expect(out.pieces.map(\.body) == ["I'm allergic to peanuts.", "I don't eat shellfish."])
        #expect(out.dropped == [.evidence: 2, .empty: 1])
        #expect(out.pieces[1].atomic == false)  // missing atomic counts as not atomic
    }

    @Test func secretsLengthAndDuplicatesAreDropped() {
        let source = "My key is sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456. I like tea. I like tea."
        let out = Self.validate([[
            Self.raw("My key is sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456.", quote: "My key is sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456"),
            Self.raw("I like tea.", quote: "I like tea"),
            Self.raw("I  like TEA.", quote: "I like tea"),
        ]], source: source)
        #expect(out.pieces.map(\.body) == ["I like tea."])
        #expect(out.dropped == [.secret: 1, .duplicate: 1])
    }

    @Test func sensitivityNeverGoesBelowAnyFloor() {
        let source = "I see my therapist on Mondays. I like tea. Project Harbor ships in May."
        let out = Self.validate([[
            Self.raw("I see my therapist on Mondays.", quote: "I see my therapist on Mondays", categories: ["personal_preferences"]),
            Self.raw("I like tea.", quote: "I like tea", categories: ["unknown_key"], sensitivity: "public"),
            Self.raw("Harbor ships in May.", quote: "Project Harbor ships in May", categories: ["health"], sensitivity: "low"),
        ]], source: source)
        // The pre-screen (therapist → health), unknown categories dropped, the category default.
        #expect(out.pieces.map(\.sensitivity) == [.sensitive, .low, .sensitive])
        #expect(out.pieces[1].categoryKeys == ["personal_preferences"])
        #expect(out.pieces[1].modelSensitivity == .public)
        let floored = Self.validate([[Self.raw("I like tea.", quote: "I like tea", sensitivity: "public")]], source: source,
                                    floors: .init(hint: .low, declared: .internal, original: .restricted))
        #expect(floored.pieces[0].sensitivity == .restricted)
        #expect(Self.validate([[Self.raw("I like tea.", quote: "I like tea", sensitivity: "public")]], source: source,
                              floors: .init(hint: .internal)).pieces[0].sensitivity == .internal)
    }

    @Test func theSupportCheckFlagsWordsNotInTheInput() {
        let source = "Ran a PB at the Lisbon half marathon last Sunday."
        let out = Self.validate([[
            Self.raw("I ran a personal best at the Lisbon half marathon.", quote: "Ran a PB at the Lisbon half marathon"),
            Self.raw("I ran the Lisbon half marathon.", quote: "Lisbon half marathon"),
        ]], source: source)
        #expect(out.pieces[0].unsupportedWords == ["best", "personal"])
        #expect(!out.pieces[0].supported)  // flagged, kept
        #expect(out.pieces[1].supported)
        #expect(ExtractionValidator.contentWords("Dr. Okafor's clinic opens at 9:30, costs €1,250") ==
                ["dr", "okafor", "clinic", "open", "9:30", "cost", "1,250"])
    }

    @Test func capsPiecesPerChunkAndPerInput() {
        let words = (0..<50).map { "item\($0)" }
        let source = words.joined(separator: " ")
        let chunk1 = words.prefix(31).map { Self.raw("I have \($0).", quote: $0) }
        let chunk2 = words.dropFirst(31).map { Self.raw("I have \($0).", quote: $0) }
        let out = Self.validate([Array(chunk1), Array(chunk2)], source: source)
        #expect(out.pieces.count == 40)
        #expect(out.truncated == 1 + (30 + 19 - 40))
        #expect(out.pieces.last?.chunk == 1)
    }

    @Test func confidenceIsRecordedNotTrusted() {
        let out = Self.validate([[Self.raw("A.", quote: "A", confidence: -1), Self.raw("B.", quote: "B", confidence: 0.4)]], source: "A B")
        #expect(out.pieces.map(\.confidence) == [nil, 0.4])
    }

    @Test func outputDecodesLeniently() throws {
        let json = #"{"pieces": [{"evidence": ["x"], "body": "x", "kind": 3}, "junk", {"evidence": ["y"], "body": "y", "confidence": "high"}]}"#
        let out = try HTTPClient.decode(json, as: ExtractionPrompt.Output.self)
        #expect(out.pieces.map(\.body) == ["x", "y"])
        #expect(out.pieces[0].kind == nil && out.pieces[1].confidence == nil)
    }

    // MARK: The finder and the decision call

    @Test func finderUsesKeywordsWithoutTheModelAndExcludesTheOriginal() async throws {
        let v = try TestVault()
        let coffee = try v.memory("Coffee order", "Oat milk flat white, no sugar")
        let original = try v.memory("Coffee habits", "Oat milk flat white in the morning")
        _ = try v.memory("Dentist", "Dr. Silva, every six months")
        let archived = try v.memory("Old coffee", "Oat milk latte")
        try await v.store.writer.write { db in _ = try MemoryStore.setStatus(db, id: archived.id, to: .archived, actor: .user, now: t0) }
        let finder = RelatedMemoryFinder(store: v.store, indexer: nil)
        let query = RelatedMemoryFinder.Query(title: "Coffee", body: "I switched to oat milk cortado", kind: .preference,
                                              categoryKeys: ["personal_preferences"])
        let found = try await finder.related([query], excluding: [original.id])
        #expect(found == [[coffee.id]])
        let pooled = try await finder.related([query], pool: [original.id])
        #expect(pooled == [[original.id]])
        let none = try await finder.related([])
        #expect(none.isEmpty)
    }

    @Test func decisionsAreValidatedAgainstTheSuppliedMemories() throws {
        let m = Memory(title: "Coffee", body: "Flat white", kind: .preference, categoryKeys: ["personal_preferences"], sensitivity: .low,
                       source: .manual, createdAt: t0, updatedAt: t0, version: 3)
        let other = Memory(title: "Tea", body: "Green", kind: .preference, categoryKeys: ["personal_preferences"], sensitivity: .low,
                           source: .manual, createdAt: t0, updatedAt: t0)
        let piece = ExtractionTests.validate([[Self.raw("I drink cortados.", quote: "cortados")]], source: "cortados").pieces[0]
        let batch = DecisionPrompt.Batch(pieces: (0..<7).map { ($0, piece) }, related: Dictionary(uniqueKeysWithValues: (0..<7).map {
            ($0, $0 == 6 ? [("m2", other)] : [("m1", m)])
        }))
        let output = DecisionPrompt.Output(decisions: [
            .init(piece: 0, action: "update", target: "m1", body: "Cortado now"),
            .init(piece: 1, action: "duplicate", target: "m9"),          // not listed
            .init(piece: 2, action: "update", target: "m1", body: " "),  // no new text
            .init(piece: 3, action: "retract", target: "m1"),
            .init(piece: 4, action: "merge", target: "m1"),              // unknown action
            .init(piece: 0, action: "create"),                           // a second answer for 0 is ignored
            .init(piece: 6, action: "duplicate", target: "m1"),          // m1 isn't listed for piece 6
            .init(piece: 9, action: "duplicate", target: "m1"),          // no such piece
        ])
        let d = DecisionPrompt.validate(output, batch: batch)
        #expect(d[0] == LinkDecision(action: .update, target: m.id, targetVersion: 3, updatedBody: "Cortado now"))
        #expect([1, 2, 4, 5, 6].allSatisfy { d[$0]?.action == .create })  // 5: no answer
        #expect(d[3]?.action == .retract && d[3]?.target == m.id)
        let prompt = DecisionPrompt.prompt(DecisionPrompt.Batch(pieces: [(0, piece)], related: [0: [("m1", m)]]))
        #expect(prompt.contains("<piece index=\"0\" intent=\"assertion\">"))
        #expect(prompt.contains("- m1 (created \(DecisionPrompt.day(t0)), updated \(DecisionPrompt.day(t0))) title: Coffee | body: Flat white"))
        #expect(!prompt.contains(m.id.db))  // memories are named by alias only
    }

    @Test func anUpdateMayRetitleItsTarget() throws {
        let m = Memory(title: "Likes the color blue", body: "My favorite color is blue.", kind: .preference,
                       categoryKeys: ["personal_preferences"], sensitivity: .low, source: .manual, createdAt: t0, updatedAt: t0)
        let piece = ExtractionTests.validate([[Self.raw("My favorite color is orange.", quote: "orange")]], source: "orange").pieces[0]
        let batch = DecisionPrompt.Batch(pieces: (0..<3).map { ($0, piece) }, related: [0: [("m1", m)], 1: [("m1", m)], 2: [("m1", m)]])
        let output = DecisionPrompt.Output(decisions: [
            .init(piece: 0, action: "update", target: "m1", title: " Favorite color: orange ", body: "My favorite color is orange."),
            .init(piece: 1, action: "update", target: "m1", title: "", body: "My favorite color is orange."),
            .init(piece: 2, action: "update", target: "m1", title: String(repeating: "x", count: 181), body: "Orange."),
        ])
        let d = DecisionPrompt.validate(output, batch: batch)
        #expect(d[0]?.updatedTitle == "Favorite color: orange")
        #expect(d[1]?.action == .update && d[1]?.updatedTitle == nil)  // keeps the target's
        #expect(d[2]?.action == .update && d[2]?.updatedTitle == nil)  // past the limit
        #expect(DecisionPrompt.rules.contains("title = its title"))
    }
}

extension DecisionPrompt.Output {
    init(decisions: [DecisionPrompt.RawDecision]) {
        let json = try! JSONSerialization.data(withJSONObject: ["decisions": decisions.map { d -> [String: Any] in
            var o: [String: Any] = [:]
            if let p = d.piece { o["piece"] = p }
            if let a = d.action { o["action"] = a }
            if let t = d.target { o["target"] = t }
            if let t = d.title { o["title"] = t }
            if let b = d.body { o["body"] = b }
            return o
        }])
        self = try! JSONDecoder().decode(DecisionPrompt.Output.self, from: json)
    }
}
