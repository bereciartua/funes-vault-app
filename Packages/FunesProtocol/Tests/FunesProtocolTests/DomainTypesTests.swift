import Foundation
import Testing
@testable import FunesProtocol

@Suite struct DomainTypesTests {
    @Test func sensitivityIsOrderedAndRanked() {
        #expect(Sensitivity.allCases == [.public, .low, .internal, .sensitive, .restricted, .secret])
        #expect(Sensitivity.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5])
        #expect(Sensitivity.public < .low && .low < .internal && .internal < .sensitive)
        #expect(Sensitivity.sensitive < .restricted && .restricted < .secret)
        #expect(Sensitivity.allCases.sorted(by: >).first == .secret)
    }

    @Test func sensitivityCodesAsItsName() throws {
        let data = try JSONEncoder().encode([Sensitivity.internal, .secret])
        #expect(String(decoding: data, as: UTF8.self) == #"["internal","secret"]"#)
        #expect(try JSONDecoder().decode([Sensitivity].self, from: Data(#"["public","restricted"]"#.utf8)) == [.public, .restricted])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([Sensitivity].self, from: Data(#"["top"]"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([Sensitivity].self, from: Data("[2]".utf8)) }
        for level in Sensitivity.allCases { #expect(Sensitivity(name: level.name) == level) }
    }

    // The raw values are the wire and database spellings: pinned (spec/domain/domain-model.md).
    @Test func rawValuesMatchTheSpec() {
        #expect(MemoryKind.allCases.map(\.rawValue) == [
            "fact", "preference", "instruction", "goal", "project_context", "relationship", "constraint", "event", "summary",
        ])
        #expect(AccessOperation.allCases.map(\.rawValue) == ["read", "suggest", "write"])
        #expect(Retention.allCases.map(\.rawValue) == ["none", "session", "persistent", "unknown"])
        #expect(DisclosureStatus.allCases.map(\.rawValue) == [
            "evaluating", "fulfilled", "needs_approval", "approved", "delivered", "denied", "failed",
        ])
        #expect(SuggestionStatus.allCases.map(\.rawValue) == ["pending", "applied", "rejected", "expired"])
        #expect(MemorySource.allCases.map(\.rawValue) == [
            "manual", "capture_mac", "capture_iphone", "agent_suggestion", "agent_write", "import_chatgpt",
            "import_claude", "import_markdown", "import_funes", "seed_question",
        ])
        #expect(SuggestionOrigin.allCases.map(\.rawValue) == [
            "agent", "capture_mac", "capture_iphone", "import", "seed_question", "consolidation",
        ])
        #expect(Set(ReasonCode.allCases.map(\.rawValue)) == [
            "funes_paused", "agent_paused", "access_expired", "operation_not_allowed", "no_matching_memories",
            "inactive_memory", "expired_memory", "above_sensitivity_ceiling", "denied_category", "category_not_allowed",
            "no_allowed_memories", "confirmation_required", "allowed", "allowed_by_window", "denied_by_user",
            "approval_expired", "policy_changed", "already_delivered", "not_found", "invalid_input", "unknown_category",
            "secret_like_content", "rate_limited",
        ])
        #expect(MemoryKind.projectContext.words == "project context")
    }

    @Test func inputLimitsMatchTheSpec() {
        #expect(InputLimits.title == 1...180)
        #expect(InputLimits.body == 1...10_000)
        #expect(InputLimits.task == 1...1_000)
        #expect(InputLimits.keywordCount == 20 && InputLimits.keywordLength == 1...60)
        #expect(InputLimits.purpose == 160 && InputLimits.evidence == 2_000)
        #expect(InputLimits.memoryCategories == 12 && InputLimits.requestCategories == 24)
        #expect(InputLimits.processorCount == 12 && InputLimits.processorLength == 120)
        #expect(InputLimits.maxTokens == 100...8_000 && InputLimits.defaultMaxTokens == 1_200)
    }

    // Lengths count Unicode scalars, like SQLite's length(), so a valid text always fits the schema.
    @Test func lengthsCountUnicodeScalars() {
        #expect(InputLimits.length(of: "abc") == 3)
        #expect(InputLimits.length(of: "é") == 1)
        #expect(InputLimits.length(of: "e\u{301}") == 2)
        #expect(InputLimits.length(of: "👩‍💻") == 3)
        #expect(InputLimits.length(of: "🇦🇷") == 2)
    }

    @Test func expiryIsComputedAtTheBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var m = Memory(title: "t", body: "b", kind: .fact, categoryKeys: ["legal"], sensitivity: .low,
                       source: .manual, createdAt: now, updatedAt: now)
        #expect(!m.isExpired(at: now))
        m.expiresAt = now
        #expect(m.isExpired(at: now))
        m.expiresAt = now.addingTimeInterval(1)
        #expect(!m.isExpired(at: now))
        #expect(m.disclosureText == "t: b")
    }

    @Test func builtinCategories() {
        #expect(MemoryCategory.builtins.map(\.key) == [
            "communication_style", "personal_preferences", "software_development", "project_context",
            "privacy_preferences", "health", "finance", "legal",
        ])
        let sensitive = MemoryCategory.builtins.filter { $0.defaultSensitivity == .sensitive }.map(\.key)
        #expect(sensitive == ["health", "finance", "legal"])
        #expect(MemoryCategory.builtins.allSatisfy { $0.builtin && MemoryCategory.isValidKey($0.key) })
        #expect(!MemoryCategory.isValidKey("Health") && !MemoryCategory.isValidKey("1abc") && !MemoryCategory.isValidKey("")
            && !MemoryCategory.isValidKey("a-b") && MemoryCategory.isValidKey("side_projects2"))
    }
}
