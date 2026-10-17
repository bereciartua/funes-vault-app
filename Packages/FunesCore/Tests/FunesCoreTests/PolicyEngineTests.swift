import Foundation
import FunesProtocol
import Testing
@testable import FunesCore

/// Access policy test vectors T1–T12, T27–T29 and T31–T33 at the engine level (task 1.5).
/// DisclosureServiceTests and SuggestionServiceTests run the same vectors through the database.
@Suite struct PolicyEngineTests {
    typealias F = PolicyFixture

    struct ReadVector: Sendable, CustomTestStringConvertible {
        let id: String
        var globalPaused = false
        var agent: @Sendable (inout Agent) -> Void = { _ in }
        var access: @Sendable (inout Access) -> Void = { _ in }
        var retrieved: [String]? = nil
        var window: AllowWindow? = nil
        let decision: Decision
        var eligible: Set<String> = []
        /// nil: a gate denial, which has no withheld counts.
        let withheld: [ReasonCode: Int]?
        var testDescription: String { id }
    }

    static let window7 = AllowWindow(agentID: F.agentID, revision: 7, until: F.now.plus(minutes: 10))

    static let readVectors: [ReadVector] = [
        ReadVector(id: "T1", decision: .needsApproval, eligible: ["m1", "m2"],
                   withheld: [.aboveSensitivityCeiling: 2, .expiredMemory: 1]),
        ReadVector(id: "T2", access: { $0.askBeforeSharing = false }, decision: .allow(.allowed), eligible: ["m1", "m2"],
                   withheld: [.aboveSensitivityCeiling: 2, .expiredMemory: 1]),
        ReadVector(id: "T3", globalPaused: true, decision: .deny(.funesPaused), withheld: nil),
        ReadVector(id: "T4", agent: { $0.paused = true }, decision: .deny(.agentPaused), withheld: nil),
        ReadVector(id: "T5", access: { $0.expiresAt = F.now.plus(days: -1) }, decision: .deny(.accessExpired), withheld: nil),
        ReadVector(id: "T6", access: { $0.operations = [.suggest] }, decision: .deny(.operationNotAllowed), withheld: nil),
        ReadVector(id: "T7", access: { $0.allowedCategoryKeys = ["project_context"] }, decision: .needsApproval,
                   eligible: ["m2"], withheld: [.aboveSensitivityCeiling: 2, .expiredMemory: 1, .categoryNotAllowed: 1]),
        ReadVector(id: "T8", access: { $0.allowedCategoryKeys = ["project_context"]; $0.deniedCategoryKeys = ["project_context"] },
                   decision: .deny(.noAllowedMemories),
                   withheld: [.aboveSensitivityCeiling: 2, .expiredMemory: 1, .deniedCategory: 1, .categoryNotAllowed: 1]),
        ReadVector(id: "T9", access: { $0.maxSensitivity = .secret }, decision: .needsApproval,
                   eligible: ["m1", "m2", "m3", "m6"], withheld: [.expiredMemory: 1]),
        ReadVector(id: "T10", retrieved: [], decision: .deny(.noMatchingMemories), withheld: [:]),
        ReadVector(id: "T11", access: { $0.maxSensitivity = .public }, decision: .deny(.noAllowedMemories),
                   withheld: [.aboveSensitivityCeiling: 4, .expiredMemory: 1]),
        ReadVector(id: "T31", agent: { $0.revision = 7 }, retrieved: ["m1"], window: window7,
                   decision: .allow(.allowedByWindow), eligible: ["m1"], withheld: [:]),
        ReadVector(id: "T32", agent: { $0.revision = 7 }, retrieved: ["m1", "m2"], window: window7,
                   decision: .needsApproval, eligible: ["m1", "m2"], withheld: [:]),
        ReadVector(id: "T33", agent: { $0.revision = 8 }, retrieved: ["m1"], window: window7,
                   decision: .needsApproval, eligible: ["m1"], withheld: [:]),
    ]

    /// Gate, then evaluation, as DisclosureService runs them.
    static func run(_ v: ReadVector) -> (Decision, Set<String>, [ReasonCode: Int]?) {
        var agent = F.agent
        v.agent(&agent)
        var access = F.access
        v.access(&access)
        if let reason = PolicyEngine.gate(agent: agent, access: access, globalPaused: v.globalPaused, now: F.now) {
            return (.deny(reason), [], nil)
        }
        let candidates = v.retrieved.map { $0.map { F.memories[$0]! } } ?? F.retrieved
        let e = PolicyEngine.evaluate(candidates: candidates, agent: agent, access: access, window: v.window, now: F.now)
        return (e.decision, Set(e.eligible.map { F.name(of: $0.id) }), e.withheld)
    }

    @Test(arguments: readVectors) func readVector(_ v: ReadVector) {
        let (decision, eligible, withheld) = Self.run(v)
        #expect(decision == v.decision)
        #expect(eligible == v.eligible)
        #expect(withheld == v.withheld)
    }

    /// T12 and principle 2: the engine never sees the task or purpose, so its inputs can't carry
    /// them; eligible memories keep the retrieval (score) order.
    @Test func eligibleKeepsScoreOrder() {
        let reversed = Array(F.retrieved.reversed())
        let e = PolicyEngine.evaluate(candidates: reversed, agent: F.agent, access: F.access, window: nil, now: F.now)
        #expect(e.eligible.map { F.name(of: $0.id) } == ["m2", "m1"])
    }

    @Test func archivedIsInactiveDefensively() {
        #expect(PolicyEngine.eligibility(F.memories["m5"]!, access: F.access, now: F.now) == .inactiveMemory)
        var deleted = F.memories["m1"]!
        deleted.status = .deleted
        #expect(PolicyEngine.eligibility(deleted, access: F.access, now: F.now) == .inactiveMemory)
    }

    @Test func gateOrderIsG1ToG4() {
        var agent = F.agent
        agent.paused = true
        var access = F.access
        access.expiresAt = F.now
        access.operations = []
        #expect(PolicyEngine.gate(agent: agent, access: access, globalPaused: true, now: F.now) == .funesPaused)
        #expect(PolicyEngine.gate(agent: agent, access: access, globalPaused: false, now: F.now) == .agentPaused)
        agent.paused = false
        #expect(PolicyEngine.gate(agent: agent, access: access, globalPaused: false, now: F.now) == .accessExpired)
        access.expiresAt = F.now.plus(minutes: 1)
        #expect(PolicyEngine.gate(agent: agent, access: access, globalPaused: false, now: F.now) == .operationNotAllowed)
        #expect(PolicyEngine.gate(agent: agent, access: access, globalPaused: false, now: F.now, requiring: nil) == nil)
    }

    @Test func expiredWindowsAndWindowsAboveLowAreIgnored() {
        var agent = F.agent
        agent.revision = 7
        let expired = AllowWindow(agentID: F.agentID, revision: 7, until: F.now)
        let other = AllowWindow(agentID: UUID(), revision: 7, until: F.now.plus(minutes: 5))
        let m1 = [F.memories["m1"]!]
        for w in [expired, other] {
            #expect(PolicyEngine.decide(eligible: m1, access: F.access, window: w, agentID: F.agentID, agentRevision: 7, now: F.now)
                == .needsApproval)
        }
        #expect(AllowWindow(agentID: F.agentID, revision: 7, until: F.now, maxSensitivity: .secret).maxSensitivity == .low)
    }

    // MARK: Suggest scope (T27–T29)

    @Test func t27SuggestToADeniedCategory() {
        var access = F.access
        access.operations = [.suggest]
        access.deniedCategoryKeys = ["health"]
        #expect(PolicyEngine.scopeCheck(sensitivity: .low, categoryKeys: ["health"], access: access) == .deniedCategory)
    }

    @Test func t28SuggestAboveTheCeiling() {
        #expect(PolicyEngine.scopeCheck(sensitivity: .secret, categoryKeys: ["personal_preferences"], access: F.access)
            == .aboveSensitivityCeiling)
        #expect(PolicyEngine.scopeCheck(sensitivity: .internal, categoryKeys: ["personal_preferences"], access: F.access) == nil)
    }

    /// The service answers `not_found` whenever the target isn't readable (SuggestionServiceTests).
    @Test func t29TargetAboveTheCeilingIsNotReadable() {
        #expect(PolicyEngine.eligibility(F.memories["m3"]!, access: F.access, now: F.now) == .aboveSensitivityCeiling)
    }

    @Test func scopeCheckAllowList() {
        var access = F.access
        access.allowedCategoryKeys = ["legal"]
        #expect(PolicyEngine.scopeCheck(sensitivity: .low, categoryKeys: ["health"], access: access) == .categoryNotAllowed)
        #expect(PolicyEngine.scopeCheck(sensitivity: .low, categoryKeys: ["health", "legal"], access: access) == nil)
    }
}

/// Task 1.6: bundle compilation (access policy §4, FR-D-09), T21 and edge cases.
@Suite struct BundleCompilerTests {
    static func memory(_ title: String, chars: Int, version: Int = 1) -> Memory {
        // "<title>: <body>" is `chars` characters long.
        let body = String(repeating: "x", count: chars - title.count - 2)
        return Memory(title: title, body: body, kind: .fact, categoryKeys: ["communication_style", "legal"],
                      sensitivity: .low, source: .manual, createdAt: t0, updatedAt: t0, version: version)
    }

    @Test func t21FirstItemClippedAndTheRestSkipped() {
        let m1 = Self.memory("m1", chars: 600), m2 = Self.memory("m2", chars: 40)
        let b = BundleCompiler.compile([m1, m2], maxTokens: 100)
        #expect(b.items.count == 1)
        #expect(b.items[0].memoryID == m1.id && b.items[0].clipped)
        #expect(b.items[0].text.unicodeScalars.count == 400 && b.items[0].text.hasSuffix("…"))
        #expect(b.items[0].estimatedTokens == 100 && b.estimatedTokens == 100)
        #expect(b.items[0].category == "communication_style")
        #expect(b.instructions == BundleCompiler.instructions && b.instructionsVersion == 1 && b.maxTokens == 100)
    }

    @Test func overflowingItemsAreSkippedAndSmallerOnesStillFit() {
        let a = Self.memory("a", chars: 200), big = Self.memory("big", chars: 300), small = Self.memory("small", chars: 100)
        let b = BundleCompiler.compile([a, big, small], maxTokens: 100)
        #expect(b.items.map(\.memoryID) == [a.id, small.id])
        #expect(b.estimatedTokens == 75 && b.items.allSatisfy { !$0.clipped })
    }

    @Test func theBudgetCanBeMetExactly() {
        let a = Self.memory("a", chars: 200), c = Self.memory("c", chars: 200), d = Self.memory("d", chars: 4)
        let b = BundleCompiler.compile([a, c, d], maxTokens: 100)
        #expect(b.items.map(\.memoryID) == [a.id, c.id] && b.estimatedTokens == 100)
        #expect(BundleCompiler.compile([Self.memory("e", chars: 400)], maxTokens: 100).items[0].clipped == false)
    }

    @Test func tokensAreCeilOfScalarsOverFour() {
        #expect(BundleCompiler.estimateTokens("abc") == 1)
        #expect(BundleCompiler.estimateTokens("abcd") == 1)
        #expect(BundleCompiler.estimateTokens("abcde") == 2)
        #expect(BundleCompiler.estimateTokens("👩‍💻") == 1)        // 3 scalars
        #expect(BundleCompiler.estimateTokens("👩‍💻👩‍💻") == 2)     // 6 scalars
    }

    @Test func clippingKeepsWholeCharacters() {
        let m = Memory(title: "E", body: String(repeating: "👩‍💻", count: 400), kind: .fact, categoryKeys: ["legal"],
                       sensitivity: .low, source: .manual, createdAt: t0, updatedAt: t0)
        let item = BundleCompiler.compile([m], maxTokens: 100).items[0]
        #expect(item.clipped && item.text.unicodeScalars.count <= 400 && item.estimatedTokens <= 100)
        #expect(item.text.dropLast().allSatisfy { $0 == "👩‍💻" || "E: ".contains($0) })
        #expect(item.text.hasSuffix("…"))
    }

    @Test func emptyInputGivesAnEmptyBundle() {
        let b = BundleCompiler.compile([], maxTokens: 1200)
        #expect(b.items.isEmpty && b.estimatedTokens == 0)
    }
}
