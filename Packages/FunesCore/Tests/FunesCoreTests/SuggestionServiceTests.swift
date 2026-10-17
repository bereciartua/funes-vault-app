import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Task 1.8: suggestions, direct writes, the Inbox, captures and owner devices
/// (access policy §5–6, T23–T29, T34, T35).
@Suite struct SuggestionServiceTests {
    static func make() throws -> (ServiceFixture, SuggestionService) {
        let fx = try ServiceFixture()
        return (fx, SuggestionService(store: fx.store, activity: fx.activity, pause: fx.pause, disclosures: fx.disclosures))
    }

    static let dev = SuggestInput(title: "Prefers pnpm", body: "Use pnpm for packages", categories: ["software_development"],
                                  sensitivity: .low)

    // MARK: Vectors

    @Test func t23SuggestQueues() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest] }
        let out = try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now)
        #expect(out.status == .queued && out.memoryID == nil)
        let pending = try await s.pending()
        #expect(pending.map(\.id) == [out.suggestionID!])
        #expect(pending[0].origin == .agent && pending[0].agentID == fx.agentID && pending[0].status == .pending)
        #expect(pending[0].expiresAfter == fx.now.plus(days: 30))
        #expect(try fx.vault.count("SELECT count(*) FROM memory WHERE title = 'Prefers pnpm'") == 0)
    }

    @Test func t24DirectWriteSaves() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.write]; $0.askBeforeSaving = false }
        let out = try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now)
        #expect(out.status == .saved && out.suggestionID == nil)
        let memoryID = try #require(out.memoryID)
        let m = try #require(try fx.store.memory(id: memoryID))
        #expect(m.status == .active && m.source == .agentWrite && m.sourceAgentID == fx.agentID && m.confidence == 0.5)
        #expect(try fx.store.provenance(memoryID: m.id).map(\.actor) == ["agent:\(fx.agentID.db)"])
    }

    @Test func t25WriteWithAskBeforeSavingQueues() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.write]; $0.askBeforeSaving = true }
        #expect(try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now).status == .queued)
    }

    @Test func t26SecretsAreRefusedAndNothingIsStored() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest, .write]; $0.askBeforeSaving = false }
        let secret = "sk-abc" + String(repeating: "d", count: 24)
        for input in [SuggestInput(title: "Key", body: "my key \(secret)"),
                      SuggestInput(title: "Key", body: "fine", evidence: "the user said \(secret)"),
                      SuggestInput(title: "Key", body: "fine", metadataJSON: #"{"note": "\#(secret)"}"#)] {
            let out = try await s.suggest(agentID: fx.agentID, input, now: fx.now)
            #expect(out.status == .denied && out.reason == .secretLikeContent && out.findings == [.openAIStyleKey])
        }
        #expect(try fx.vault.count("SELECT count(*) FROM suggestion") == 0)
        #expect(try fx.vault.count("SELECT count(*) FROM memory WHERE title = 'Key'") == 0)
        let log = String(decoding: try JSONEncoder().encode(fx.activity.events), as: UTF8.self)
        #expect(!log.contains(secret) && !log.contains("my key") && log.contains("openai_style_key"))
    }

    @Test func t27SuggestingIntoADeniedCategory() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest]; $0.deniedCategoryKeys = ["health"] }
        let out = try await s.suggest(agentID: fx.agentID, SuggestInput(title: "Meds", body: "Takes vitamin D", categories: ["health"],
                                                                        sensitivity: .low), now: fx.now)
        #expect(out.status == .denied && out.reason == .deniedCategory)
        #expect(try fx.vault.count("SELECT count(*) FROM suggestion") == 0)
    }

    @Test func t28SuggestingAboveTheCeiling() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest] }
        var input = Self.dev
        input.sensitivity = .secret
        #expect(try await s.suggest(agentID: fx.agentID, input, now: fx.now).reason == .aboveSensitivityCeiling)
        // With no sensitivity given, Health's default (SENSITIVE) is above INTERNAL too.
        let health = SuggestInput(title: "Allergy", body: "Peanuts", categories: ["health"])
        #expect(try await s.suggest(agentID: fx.agentID, health, now: fx.now).reason == .aboveSensitivityCeiling)
    }

    @Test func t29ACorrectionOfAnUnreadableMemoryIsNotFound() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest] }
        for target in [fx.id("m3"), fx.id("m4"), fx.id("m5"), UUID()] {   // above ceiling, expired, archived, unknown
            var input = Self.dev
            input.targetMemoryID = target
            let out = try await s.suggest(agentID: fx.agentID, input, now: fx.now)
            #expect(out.status == .denied && out.reason == .notFound)
        }
    }

    @Test func gateAndOperationDenials() async throws {
        let (fx, s) = try Self.make()
        // The fixture agent only reads.
        #expect(try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now).reason == .operationNotAllowed)
        try fx.setAccess { $0.operations = [.suggest] }
        fx.pause.pause(until: .distantFuture)
        #expect(try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now).reason == .funesPaused)
        fx.pause.resume()
        try fx.setAgent(paused: true)
        #expect(try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now).reason == .agentPaused)
        try fx.setAgent(paused: false)
        try fx.setAccess { $0.expiresAt = fx.now }
        #expect(try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now).reason == .accessExpired)
        await #expect(throws: VaultError.unauthenticated) { try await s.suggest(agentID: UUID(), Self.dev, now: fx.now) }
        #expect(try fx.vault.count("SELECT count(*) FROM suggestion") == 0)
    }

    @Test func validation() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest] }
        let bad: [(SuggestInput, ReasonCode)] = [
            (SuggestInput(title: "", body: "b"), .invalidInput),
            (SuggestInput(title: "t", body: String(repeating: "b", count: 10_001)), .invalidInput),
            (SuggestInput(title: "t", body: "b", evidence: String(repeating: "e", count: 2_001)), .invalidInput),
            (SuggestInput(title: "t", body: "b", purpose: String(repeating: "p", count: 161)), .invalidInput),
            (SuggestInput(title: "t", body: "b", categories: Array(repeating: "legal", count: 13)), .invalidInput),
            (SuggestInput(title: "t", body: "b", expiresAt: fx.now), .invalidInput),
            (SuggestInput(title: "t", body: "b", confidence: 1.5), .invalidInput),
            (SuggestInput(title: "t", body: "b", metadataJSON: "[1, 2]"), .invalidInput),
            (SuggestInput(title: "t", body: "b", metadataJSON: #"{"k": ""# + String(repeating: "v", count: 4_100) + #""}"#), .invalidInput),
            (SuggestInput(title: "t", body: "b", categories: ["hobbies"]), .unknownCategory),
        ]
        for (input, reason) in bad {
            #expect(try await s.suggest(agentID: fx.agentID, input, now: fx.now).reason == reason)
        }
        #expect(try fx.vault.count("SELECT count(*) FROM suggestion") == 0)
    }

    @Test func defaultsComeFromClassification() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest]; $0.maxSensitivity = .secret }
        let a = try await s.suggest(agentID: fx.agentID, SuggestInput(title: "Git habits", body: "Squash commits before merging the branch"),
                                    now: fx.now)
        let b = try await s.suggest(agentID: fx.agentID, SuggestInput(title: "Weekend", body: "Likes long walks"), now: fx.now)
        let sa = try await s.suggestion(id: a.suggestionID!)!, sb = try await s.suggestion(id: b.suggestionID!)!
        #expect(sa.categoryKeys == ["software_development"] && sa.sensitivity == .low && sa.kind == nil)
        #expect(sb.categoryKeys == ["personal_preferences"])
    }

    @Test func callerMetadataIsStoredInert() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest] }
        let meta = #"{"action": "delete_all", "archive": ["m1"]}"#
        var input = Self.dev
        input.metadataJSON = meta
        let out = try await s.suggest(agentID: fx.agentID, input, now: fx.now)
        #expect(try await s.suggestion(id: out.suggestionID!)?.callerMetadata == meta)
        #expect(try fx.store.memory(id: fx.id("m1"))?.status == .active)
    }

    // MARK: Corrections and the Inbox

    @Test func correctionsQueueAndApplyAsReplaceOrKeepBoth() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest, .write]; $0.askBeforeSaving = false }
        var input = SuggestInput(title: "Memory m1", body: "Corrected body", categories: ["communication_style"], sensitivity: .low)
        input.targetMemoryID = fx.id("m1")
        let out = try await s.suggest(agentID: fx.agentID, input, now: fx.now)
        #expect(out.status == .queued)  // even with direct write: agents can't edit (FR-S-06)
        #expect(try await s.suggestion(id: out.suggestionID!)?.action == .update)
        #expect(try fx.store.provenance(memoryID: fx.id("m1")).last?.event == .suggestedCorrection)

        let replaced = try await s.apply(suggestionID: out.suggestionID!, mode: .replace, now: fx.now.plus(minutes: 1))
        #expect(replaced.memoryID == fx.id("m1"))
        let m1 = try #require(try fx.store.memory(id: fx.id("m1")))
        #expect(m1.body == "Corrected body" && m1.version == 2)
        #expect(try fx.store.provenance(memoryID: m1.id).suffix(2).map(\.event) == [.edited, .appliedFromSuggestion])

        let second = try await s.suggest(agentID: fx.agentID, input, now: fx.now)
        let kept = try await s.apply(suggestionID: second.suggestionID!, mode: .keepBoth, now: fx.now)
        #expect(kept.memoryID != fx.id("m1") && kept.similarMemoryIDs == [fx.id("m1")])
    }

    @Test func applyCreatesTheMemoryWithProvenanceAndEdits() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest] }
        let out = try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now)
        let result = try await s.apply(suggestionID: out.suggestionID!, edits: SuggestionEdit(title: "Uses pnpm", kind: .preference),
                                       now: fx.now.plus(minutes: 2))
        let m = try #require(try fx.store.memory(id: result.memoryID))
        #expect(m.title == "Uses pnpm" && m.kind == .preference && m.source == .agentSuggestion && m.sourceAgentID == fx.agentID)
        #expect(try fx.store.provenance(memoryID: m.id).map(\.event) == [.created, .appliedFromSuggestion])
        #expect(try fx.store.provenance(memoryID: m.id).map(\.actor) == ["agent:\(fx.agentID.db)", "user"])
        let applied = try #require(try await s.suggestion(id: out.suggestionID!))
        #expect(applied.status == .applied && applied.resultMemoryID == m.id && applied.decidedAt == fx.now.plus(minutes: 2))
        await #expect(throws: VaultError.invalidState) { try await s.apply(suggestionID: out.suggestionID!, now: fx.now) }
        let secret = "ghp_" + String(repeating: "a", count: 30)
        let other = try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now)
        await #expect(throws: VaultError.secretLikeContent([.githubToken])) {
            try await s.apply(suggestionID: other.suggestionID!, edits: SuggestionEdit(body: secret), now: fx.now)
        }
        #expect(try await s.suggestion(id: other.suggestionID!)?.status == .pending)
    }

    @Test func rejectExpireAndRestore() async throws {
        let (fx, s) = try Self.make()
        try fx.setAccess { $0.operations = [.suggest] }
        let a = try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now).suggestionID!
        let b = try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now).suggestionID!
        try await s.reject(suggestionID: a, now: fx.now)
        #expect(try await s.suggestion(id: a)?.status == .rejected)
        await #expect(throws: VaultError.invalidState) { try await s.reject(suggestionID: a, now: fx.now) }
        #expect(try await s.expire(now: fx.now.plus(days: 29)) == (0, 0))
        #expect(try await s.expire(now: fx.now.plus(days: 30)) == (1, 0))
        #expect(try await s.suggestion(id: b)?.status == .expired)
        try await s.restore(suggestionID: b, now: fx.now.plus(days: 31))
        #expect(try await s.suggestion(id: b)?.status == .pending)
        #expect(try await s.expire(now: fx.now.plus(days: 61)) == (1, 0))
        await #expect(throws: VaultError.invalidState) { try await s.restore(suggestionID: b, now: fx.now.plus(days: 68)) }
        #expect(try await s.expire(now: fx.now.plus(days: 68)).deleted == 1)
        #expect(try await s.suggestion(id: b) == nil)
    }

    @Test func accessIsOfferedForMissingSuggestOperations() async throws {
        let (fx, s) = try Self.make()
        try fx.setAgent(asksForAccess: true)
        let first = try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now)
        #expect(first.reason == .operationNotAllowed && first.accessOffer?.operation == .suggest)
        #expect(try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now.plus(minutes: 5)).accessOffer == nil)
        try fx.setAccess { $0.operations = [.suggest]; $0.allowedCategoryKeys = ["legal"] }
        let out = try await s.suggest(agentID: fx.agentID, Self.dev, now: fx.now)
        #expect(out.reason == .categoryNotAllowed && out.accessOffer?.categoryKeys == ["software_development"])
    }
}

/// Task 1.8: captures and paired devices (FR-C-01..05, access policy §6).
@Suite struct CaptureServiceTests {
    @Test func aMacCaptureBecomesAClassifiedSuggestion() async throws {
        let v = try TestVault()
        let captures = CaptureService(store: v.store, activity: InMemoryActivityLog())
        let r = try await captures.capture("Dentist appointment next week\nBring the X-ray", now: t0)
        let s = try #require(try await SuggestionService(store: v.store, activity: InMemoryActivityLog(), pause: FunesPause())
            .suggestion(id: r.suggestionID))
        #expect(s.origin == .captureMac && s.status == .pending && s.title == "Dentist appointment next week")
        #expect(s.categoryKeys == ["health"] && s.sensitivity == .sensitive && s.kind == .fact)
        let record = try #require(JSON.decode(ClassificationRecord.self, s.classification))
        #expect(record.engine == "rules" && record.proposal.timeLimited && !record.keptOnDevice)
        #expect(try v.count("SELECT count(*) FROM memory") == 0)
    }

    @Test func capturesAreScannedAndValidated() async throws {
        let v = try TestVault()
        let captures = CaptureService(store: v.store, activity: InMemoryActivityLog())
        await #expect(throws: VaultError.secretLikeContent([.awsAccessKey])) {
            try await captures.capture("deploy key AKIA" + String(repeating: "B", count: 16), now: t0)
        }
        await #expect(throws: VaultError.invalidInput(field: "text")) { try await captures.capture("   \n ", now: t0) }
        #expect(try v.count("SELECT count(*) FROM suggestion") == 0)
    }

    @Test func iPhoneCapturesAreIdempotent() async throws {
        let v = try TestVault()
        let devices = DeviceService(store: v.store, activity: InMemoryActivityLog())
        let phone = try await devices.register(name: "Phone", model: "iPhone", signingPublicKey: Data([1]), hpkePublicKey: Data([2]), now: t0)
        let log = InMemoryActivityLog()
        let captures = CaptureService(store: v.store, activity: log)
        let captureID = UUID()
        let first = try await captures.capture("Buy oat milk", origin: .captureIPhone, captureID: captureID, deviceID: phone.id, now: t0)
        let again = try await captures.capture("Buy oat milk", origin: .captureIPhone, captureID: captureID, deviceID: phone.id,
                                               now: t0.plus(minutes: 1))
        #expect(!first.duplicate && again.duplicate && again.suggestionID == first.suggestionID)
        #expect(try v.count("SELECT count(*) FROM suggestion") == 1 && v.count("SELECT count(*) FROM capture_receipt") == 1)
        #expect(log.events.map(\.actor) == ["device:\(phone.id.db)", "device:\(phone.id.db)"])
        #expect(try await captures.cleanupReceipts(now: t0.plus(days: 91)) == 1)
        await #expect(throws: VaultError.unauthenticated) {
            try await captures.capture("No id", origin: .captureIPhone, deviceID: phone.id, now: t0)
        }
    }

    @Test func t35ARevokedDeviceCantCapture() async throws {
        let v = try TestVault()
        let devices = DeviceService(store: v.store, activity: InMemoryActivityLog())
        let phone = try await devices.register(name: "Phone", model: "iPhone", signingPublicKey: Data([1]), hpkePublicKey: Data([2]), now: t0)
        try await devices.revoke(deviceID: phone.id, now: t0)
        let captures = CaptureService(store: v.store, activity: InMemoryActivityLog())
        await #expect(throws: VaultError.unauthenticated) {
            try await captures.capture("Hello", origin: .captureIPhone, captureID: UUID(), deviceID: phone.id, now: t0)
        }
        await #expect(throws: VaultError.unauthenticated) {
            try await captures.capture("Hello", origin: .captureIPhone, captureID: UUID(), deviceID: UUID(), now: t0)
        }
        await #expect(throws: VaultError.unauthenticated) { try await devices.authenticate(deviceID: phone.id) }
        await #expect(throws: VaultError.unauthenticated) {
            try await devices.createMemory(deviceID: phone.id, MemoryDraft(title: "t", body: "b", categoryKeys: ["legal"]), now: t0)
        }
        #expect(try v.count("SELECT count(*) FROM suggestion") == 0 && v.count("SELECT count(*) FROM memory") == 0)
    }

    @Test func t34TheOwnersDeviceIsNotSubjectToAgentAccess() async throws {
        let v = try TestVault()
        let log = InMemoryActivityLog()
        let devices = DeviceService(store: v.store, activity: log)
        let phone = try await devices.register(name: "Phone", model: "iPhone", signingPublicKey: Data([1]), hpkePublicKey: Data([2]), now: t0)
        let m = try await devices.createMemory(deviceID: phone.id, MemoryDraft(title: "Diagnosis", body: "Details",
                                                                                categoryKeys: ["health"], sensitivity: .secret), now: t0)
        #expect(m.sensitivity == .secret && m.sourceDeviceID == phone.id)
        #expect(try v.store.provenance(memoryID: m.id).map(\.actor) == ["device:\(phone.id.db)"])
        #expect(log.events.last?.actor == "device:\(phone.id.db)" && log.events.last?.via == .companion)
        // The secret scanner still applies.
        await #expect(throws: VaultError.secretLikeContent([.privateKey])) {
            try await devices.updateMemory(deviceID: phone.id, memoryID: m.id, MemoryEdit(body: "-----BEGIN PRIVATE KEY-----"), now: t0)
        }
        #expect(try await devices.updateMemory(deviceID: phone.id, memoryID: m.id, MemoryEdit(body: "Edited"), now: t0).version == 2)
    }
}

@Suite struct RulesClassifierTests {
    @Test func proposals() {
        let cats = MemoryCategory.builtins
        let p = RulesClassifier.propose("My salary is paid on the 25th and rent leaves on the 1st", categories: cats)
        #expect(p.categoryKeys == ["finance"] && p.sensitivity == .sensitive && p.kind == .fact && !p.timeLimited)
        #expect(RulesClassifier.propose("Likes jazz", categories: cats).categoryKeys == ["personal_preferences"])
        #expect(RulesClassifier.propose("Likes jazz", categories: cats, hint: .restricted).sensitivity == .restricted)
        let long = String(repeating: "word ", count: 40)
        #expect(RulesClassifier.propose(long, categories: cats).title.unicodeScalars.count <= 80)
        let custom = cats + [MemoryCategory(key: "garden", name: "Garden")]
        #expect(RulesClassifier.propose("The garden needs water this week", categories: custom).categoryKeys == ["garden"])
    }

    @Test func validationDropsUnknownCategoriesAndRaisesSensitivity() {
        let p = CaptureProposal(title: "  ", kind: .goal, categoryKeys: ["nope", "legal", "legal", "health", "finance", "communication_style"],
                                sensitivity: .public, timeLimited: false)
            .validated(categories: MemoryCategory.builtins, fallbackTitle: "Fallback title")
        #expect(p.categoryKeys == ["legal", "health", "finance"] && p.sensitivity == .sensitive && p.title == "Fallback title")
        let none = CaptureProposal(title: "T", kind: .fact, categoryKeys: ["x"], sensitivity: .low, timeLimited: false)
            .validated(categories: MemoryCategory.builtins, fallbackTitle: "")
        #expect(none.categoryKeys == ["personal_preferences"])
    }
}
