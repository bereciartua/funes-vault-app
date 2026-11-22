import Foundation
import Testing
@testable import FunesCore

/// 13e.2: a *timeline* record measured with answer models (ADR-0032 decision 9, amended 2026-11-21) is an answer's
/// alone: it covers only those models at that answer prompt version, and plain search's grammar never reads it.
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

    @Test func aTimelineRecordWithAnswerModelsIsTheirsAlone() {
        let haikuAnswers = "claude-code/claude-haiku-5-5"
        let q = FactsQualification(records: [record([.recorded, .linked]),
                                             record([.timeline], answerModels: [haikuAnswers], answerPrompt: SearchAnswerer.promptVersion)])
        let engines = [work: Self.haiku]
        let versions = FactsQualification.promptVersions(reg)
        // Plain search and the Facts task: no timeline.
        #expect(!q.uses(engines: engines, registry: reg, promptVersions: versions).isOn(d, .timeline))
        // The answer model it was measured with, at this prompt: on.
        let mine = q.uses(engines: engines, registry: reg, promptVersions: versions,
                          answer: .init(model: haikuAnswers, promptVersion: SearchAnswerer.promptVersion))
        #expect(mine.isOn(d, .timeline) && mine.isOn(d, .linked))
        // Another answer model, or another answer prompt: off.
        for key in [FactsQualification.AnswerKey(model: "codex/gpt-5.6-terra", promptVersion: SearchAnswerer.promptVersion),
                    FactsQualification.AnswerKey(model: haikuAnswers, promptVersion: "a13d-1")] {
            #expect(!q.uses(engines: engines, registry: reg, promptVersions: versions, answer: key).isOn(d, .timeline), "\(key)")
        }
        // An engine-free timeline record (13e.1's form) still counts for plain search, as before.
        let engineFree = FactsQualification(records: [record([.recorded, .linked, .timeline])])
        #expect(engineFree.uses(engines: engines, registry: reg, promptVersions: versions).isOn(d, .timeline))
    }
}
