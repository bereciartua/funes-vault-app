import Foundation
import FunesProtocol
@testable import FunesCore

/// The default fixture of spec/domain/access-policy.md §9: agent A reads with ceiling INTERNAL,
/// no allow or deny lists, ask on; memories m1–m6.
enum PolicyFixture {
    static let agentID = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
    static let now = t0

    static var access: Access { Access(operations: [.read], maxSensitivity: .internal) }

    static var agent: Agent {
        Agent(id: agentID, name: "Agent A", agentKind: .claudeCode, keyIssuedAt: t0, paused: false, revision: 1,
              declaredRetention: .session, asksForAccess: false, createdAt: t0, access: access)
    }

    /// m1–m6 by name.
    static let specs: [(name: String, sensitivity: Sensitivity, category: String, expired: Bool, archived: Bool)] = [
        ("m1", .low, "communication_style", false, false),
        ("m2", .internal, "project_context", false, false),
        ("m3", .sensitive, "health", false, false),
        ("m4", .low, "software_development", true, false),
        ("m5", .low, "project_context", false, true),
        ("m6", .secret, "finance", false, false),
    ]

    static func id(_ name: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", Int(name.dropFirst())!))")!
    }

    static let memories: [String: Memory] = Dictionary(uniqueKeysWithValues: specs.map { s in
        (s.name, Memory(id: id(s.name), title: "Memory \(s.name)", body: "Body of \(s.name)", kind: .fact,
                        categoryKeys: [s.category], sensitivity: s.sensitivity, status: s.archived ? .archived : .active,
                        expiresAt: s.expired ? now.plus(days: -1) : nil, source: .manual, createdAt: t0, updatedAt: t0))
    })

    /// "Assume retrieval returns every active memory": m1, m2, m3, m4, m6.
    static var retrieved: [Memory] { ["m1", "m2", "m3", "m4", "m6"].map { memories[$0]! } }

    static func name(of id: UUID) -> String { memories.first { $0.value.id == id }!.key }
}
