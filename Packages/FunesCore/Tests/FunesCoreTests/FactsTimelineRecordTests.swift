import Foundation
import Testing
@testable import FunesCore

/// 13e.2's *timeline* records, measured with answer models, and the record step's evidence rules. Since ADR-0032's
/// amendment of 2026-11-24 a record only marks an engine tested: the timeline is on for every reader, every engine and
/// every answer model.
@Suite struct FactsTimelineRecordTests {
    let reg = FactsRegistry.bundled
    var d: String { FX.dated }
    var work: String { reg.predicate(d)!.callGroup }
    static let haiku = FactsEngine(model: "claude-code/claude-haiku-5-5", adapter: "claude-code/1;effort=low")

    func record(_ uses: [FactsUse], answerModels: [String] = [], answerPrompt: String = "") -> FactsQualification.Record {
        .init(predicates: [d], uses: uses.map(\.rawValue), callGroup: work, engine: Self.haiku,
              promptVersion: FactsPrompt.version(work, registry: reg), registryVersion: reg.fingerprint, gate: "test",
              recordedAt: "2026-11-21", answerModels: answerModels, answerPromptVersion: answerPrompt)
    }

    /// The persons' records: {recorded, linked}, and *attributes* for `answerModels` (13d's form).
    func persons(_ uses: [FactsUse], answerModels: [String] = []) -> FactsQualification.Record {
        let people = reg.predicates.filter { $0.objectKind == FactsValidator.personKind }
        let group = people[0].callGroup
        return .init(predicates: people.filter { $0.callGroup == group }.map(\.id), uses: uses.map(\.rawValue), callGroup: group,
                     engine: Self.haiku, promptVersion: FactsPrompt.version(group, registry: reg), registryVersion: reg.fingerprint,
                     gate: "test", recordedAt: "2026-11-21", answerModels: answerModels,
                     answerPromptVersion: answerModels.isEmpty ? "" : SearchAnswerer.promptVersion)
    }

    @Test func aTimelineRecordWithAnswerModelsNoLongerHoldsTheTimelineBack() {
        let haikuAnswers = "claude-code/claude-haiku-5-5"
        let q = FactsQualification(records: [record([.recorded, .linked]),
                                             record([.timeline], answerModels: [haikuAnswers], answerPrompt: SearchAnswerer.promptVersion),
                                             persons([.recorded, .linked]), persons([.attributes], answerModels: [haikuAnswers])])
        let people = reg.predicates.first { $0.objectKind == FactsValidator.personKind }!
        let versions = FactsQualification.promptVersions(reg)
        let opus = FactsEngine(model: "claude-code/claude-opus-5-5", adapter: Self.haiku.adapter)
        // Plain search, People & history and the Facts task (no answer model): on, for the tested engine and another.
        for engine in [Self.haiku, opus] {
            let on = q.uses(engines: [work: engine, people.callGroup: engine], registry: reg, promptVersions: versions)
            #expect(on.isOn(d, .timeline) && on.isOn(d, .linked), "\(engine.model)")
        }
        // The persons' *attributes* switched off: the timeline stays on (the gate's coupling went with the gate).
        var off = q
        for p in reg.groupPredicates(people.callGroup) {
            off.off.insert(.init(predicate: p, use: .attributes, engine: Self.haiku,
                                 promptVersion: versions[people.callGroup]!, registryVersion: reg.fingerprint))
        }
        let on = off.uses(engines: [work: Self.haiku, people.callGroup: Self.haiku], registry: reg, promptVersions: versions)
        #expect(on.isOn(d, .timeline) && on.predicates(.attributes) == [d])
    }

    /// The record step's evidence rules (the author's decision of 2026-11-24): a waiver caps only owed checks and
    /// marking, at the measured value, for exactly the model, answer prompt, registry and read it names.
    @Test func aTimelineWaiverCapsOnlyOwedChecksAndMarking() throws {
        let w: [String: Any] = ["waived": ["owed_checks": ["measure": "owed_skipped", "max": 2], "marking": ["measure": "unmarked_inferred", "max": 1],
                                           "someone_else": ["measure": "someone_else", "max": 5]]]
        let gates = ["owed_checks": false, "marking": false, "someone_else": false, "p95": true]
        let m: [String: Any] = ["owed_skipped": 2, "unmarked_inferred": 1, "someone_else": 1]
        #expect(FactsGateEvidence.unwaived(gates, measures: m, waiver: w) == ["someone_else"])
        #expect(FactsGateEvidence.unwaived(gates, measures: m.merging(["owed_skipped": 3]) { $1 }, waiver: w) == ["owed_checks", "someone_else"])
        #expect(FactsGateEvidence.unwaived(gates, measures: m, waiver: nil) == ["marking", "owed_checks", "someone_else"])
        let file = FileManager.default.temporaryDirectory.appending(path: "waivers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: ["waivers": [["gate": "timeline-answers", "answerModel": "claude-code/claude-haiku-5-5",
            "answerPromptVersion": "a13e2-3", "registryVersion": "v1-x", "tag": "r4", "readCallsSha256": "c1", "answersSha256": "a1"]]]).write(to: file)
        func waived(_ model: String = "claude-code/claude-haiku-5-5", reg: String = "v1-x", tag: String = "r4", calls: String? = "c1", answers: String? = "a1") -> Bool {
            FactsGateEvidence.timelineWaiver(model: model, answerPromptVersion: "a13e2-3", registryVersion: reg, tag: tag,
                                             readCallsSha256: calls, answersSha256: answers, file: file) != nil
        }
        #expect(waived())
        #expect(!waived("codex/gpt-5.6-terra") && !waived(reg: "v1-y") && !waived(tag: "r5"))
        // Bound to the read and the answers it was given on.
        #expect(!waived(calls: "c2") && !waived(answers: "a2") && !waived(calls: nil))
        // A timeline record with answer models needs 13e.2's scores, not 13e.1's.
        let r = record([.timeline], answerModels: ["claude-code/claude-haiku-5-5"], answerPrompt: SearchAnswerer.promptVersion)
        #expect(FactsGateEvidence.problems(r, registry: reg) == ["no scores-13e2-<engine>.json in the evidence"])
    }
}
