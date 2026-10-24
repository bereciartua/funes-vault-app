import Foundation
import FunesProtocol
import GRDB

// Mapping between rows and domain values. Ids are lowercase UUID text, times use GRDB's UTC text
// format, sensitivities are their rank, and lists are JSON text.

enum JSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding the value types used here can't fail.
        return String(decoding: (try? encoder.encode(value)) ?? Data("null".utf8), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let text else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}

extension Row {
    func uuid(_ column: String) -> UUID? {
        guard let text: String = self[column] else { return nil }
        return UUID(uuidString: text)
    }

    func requiredUUID(_ column: String) throws -> UUID {
        guard let id = uuid(column) else { throw VaultError.invalidState }
        return id
    }

    func sensitivity(_ column: String) -> Sensitivity? {
        guard let rank: Int = self[column] else { return nil }
        return Sensitivity(rawValue: rank)
    }

    func enumValue<E: RawRepresentable>(_ column: String, as: E.Type = E.self) -> E? where E.RawValue == String {
        guard let raw: String = self[column] else { return nil }
        return E(rawValue: raw)
    }

    func required<E: RawRepresentable>(_ column: String, as: E.Type = E.self) throws -> E where E.RawValue == String {
        guard let value: E = enumValue(column) else { throw VaultError.invalidState }
        return value
    }
}

extension Memory {
    static func from(row: Row, categoryKeys: [String]) throws -> Memory {
        guard let sensitivity = row.sensitivity("sensitivity") else { throw VaultError.invalidState }
        return Memory(
            id: try row.requiredUUID("id"), title: row["title"], body: row["body"], kind: try row.required("kind"),
            categoryKeys: categoryKeys, sensitivity: sensitivity, status: try row.required("status"),
            expiresAt: row["expires_at"], confidence: row["confidence"], source: try row.required("source"),
            sourceAgentID: row.uuid("source_agent_id"), sourceDeviceID: row.uuid("source_device_id"),
            createdAt: row["created_at"], updatedAt: row["updated_at"], lastConfirmedAt: row["last_confirmed_at"],
            deletedAt: row["deleted_at"], version: row["version"])
    }
}

extension MemoryCategory {
    static func from(row: Row) -> MemoryCategory {
        MemoryCategory(
            key: row["key"], name: row["name"], description: row["description"], builtin: row["builtin"],
            defaultSensitivity: row.sensitivity("default_sensitivity") ?? .low, sortOrder: row["sort_order"])
    }
}

extension Suggestion {
    static func from(row: Row) throws -> Suggestion {
        Suggestion(
            id: try row.requiredUUID("id"), origin: try row.required("origin"), agentID: row.uuid("agent_id"),
            deviceID: row.uuid("device_id"), importRunID: row.uuid("import_run_id"), captureID: row.uuid("capture_id"),
            targetMemoryID: row.uuid("target_memory_id"), targetMemoryVersion: row["target_memory_version"],
            action: try row.required("action"),
            title: row["title"], body: row["body"], kind: row.enumValue("kind"),
            categoryKeys: JSON.decode([String].self, row["category_keys"]) ?? [],
            sensitivity: row.sensitivity("sensitivity"), expiresAt: row["expires_at"], confidence: row["confidence"],
            evidence: row["evidence"], purpose: row["purpose"], callerMetadata: row["caller_metadata"],
            classification: row["classification"], status: try row.required("status"), createdAt: row["created_at"],
            decidedAt: row["decided_at"], expiresAfter: row["expires_after"], resultMemoryID: row.uuid("result_memory_id"),
            groupID: row.uuid("group_id"), intent: row.enumValue("intent"), outsideScope: row["outside_scope"])
    }
}

extension Device {
    static func from(row: Row) throws -> Device {
        Device(
            id: try row.requiredUUID("id"), name: row["name"], model: row["model"],
            signingPublicKey: row["signing_public_key"], hpkePublicKey: row["hpke_public_key"],
            pairedAt: row["paired_at"], lastSeenAt: row["last_seen_at"], lastTransport: row.enumValue("last_transport"),
            revokedAt: row["revoked_at"], approvalsEnabled: row["approvals_enabled"], doorbellTag: row["doorbell_tag"])
    }
}

extension Disclosure {
    static func from(row: Row) throws -> Disclosure {
        let withheldRaw = JSON.decode([String: Int].self, row["withheld"]) ?? [:]
        var withheld: [ReasonCode: Int] = [:]
        for (key, count) in withheldRaw {
            guard let code = ReasonCode(rawValue: key) else { throw VaultError.invalidState }
            withheld[code] = count
        }
        return Disclosure(
            id: try row.requiredUUID("id"), agentID: try row.requiredUUID("agent_id"),
            agentRevisionAtRequest: row["agent_revision"], taskHash: row["task_hash"], taskLength: row["task_length"],
            purpose: row["purpose"], retention: try row.required("retention"),
            processors: JSON.decode([String].self, row["processors"]) ?? [], maxTokens: row["max_tokens"],
            requestedCategoryKeys: JSON.decode([String].self, row["requested_categories"]) ?? [],
            status: try row.required("status"), reason: row.enumValue("reason"),
            candidateSnapshot: JSON.decode([SnapshotItem].self, row["candidate_snapshot"]) ?? [],
            snapshotRevision: row["snapshot_revision"],
            approvedMemoryIDs: JSON.decode([UUID].self, row["approved_memory_ids"]),
            approvalExpiresAt: row["approval_expires_at"], withheld: withheld, createdAt: row["created_at"],
            decidedAt: row["decided_at"], deliveredAt: row["delivered_at"])
    }
}

extension Dictionary where Key == ReasonCode, Value == Int {
    /// `{"reason_code": count}` as stored and sent to agents.
    var json: String { JSON.encode(Dictionary<String, Int>(uniqueKeysWithValues: map { ($0.key.rawValue, $0.value) })) }
}
