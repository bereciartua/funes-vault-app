import Foundation
import FunesProtocol
import GRDB
import Security

public struct CaptureResult: Sendable, Hashable {
    public var suggestionID: UUID
    /// The same `captureId` was delivered before: nothing new was stored (FR-C-05).
    public var duplicate: Bool
}

/// Captures from the Mac and the iPhone (FR-C-01..05, access policy §6). A capture always becomes
/// a suggestion with proposed fields, never a memory directly.
public final class CaptureService: Sendable {
    public static let receiptLifetime: TimeInterval = 90 * 86_400

    public let store: VaultStore
    public let activity: any ActivityRecorder

    public init(store: VaultStore, activity: any ActivityRecorder) {
        self.store = store
        self.activity = activity
    }

    /// Stores a capture as a pending suggestion, classified by the rules (a model can refine it
    /// later; capture never waits for one). iPhone captures need a paired, unrevoked device and are
    /// idempotent by `captureID`, with the receipt in the same transaction (NFR-REL-04).
    @discardableResult
    public func capture(_ text: String, origin: SuggestionOrigin = .captureMac, captureID: UUID? = nil, deviceID: UUID? = nil,
                        sensitivityHint: Sensitivity? = nil, now: Date) async throws -> CaptureResult {
        guard origin == .captureMac || origin == .captureIPhone else { throw VaultError.invalidInput(field: "origin") }
        if origin == .captureIPhone, deviceID == nil || captureID == nil { throw VaultError.unauthenticated }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let actor: Actor = deviceID.map(Actor.device) ?? .user
        let result = try await store.writer.write { db -> CaptureResult in
            if let deviceID {
                guard let device = try DeviceStore.fetch(db, id: deviceID), !device.isRevoked else { throw VaultError.unauthenticated }
                try db.execute(sql: "UPDATE device SET last_seen_at = ? WHERE id = ?", arguments: [now, deviceID.db])
            }
            if let captureID, let existing = try String.fetchOne(db, sql: "SELECT id FROM suggestion WHERE capture_id = ?",
                                                                   arguments: [captureID.db]).flatMap(UUID.init(uuidString:)) {
                return CaptureResult(suggestionID: existing, duplicate: true)
            }
            guard InputLimits.body.contains(InputLimits.length(of: body)) else { throw VaultError.invalidInput(field: "text") }
            let findings = SecretScanner.scan(body)
            guard findings.isEmpty else { throw VaultError.secretLikeContent(findings) }
            let proposal = RulesClassifier.propose(body, categories: try CategoryStore.all(db), hint: sensitivityHint)
            let record = ClassificationRecord(engine: RulesClassifier.engine, proposal: proposal, keptOnDevice: false)
            let id = try SuggestionService.insertSuggestion(
                db, origin: origin, deviceID: deviceID, captureID: captureID,
                input: SuggestInput(title: proposal.title, body: body, kind: proposal.kind),
                categories: proposal.categoryKeys, sensitivity: proposal.sensitivity, classification: JSON.encode(record), now: now)
            if let captureID, let deviceID {
                try db.execute(sql: "INSERT INTO capture_receipt (capture_id, device_id, received_at, suggestion_id) VALUES (?, ?, ?, ?)",
                               arguments: [captureID.db, deviceID.db, now, id.db])
            }
            return CaptureResult(suggestionID: id, duplicate: false)
        }
        activity.record(ActivityEvent(time: now, actor: actor, via: deviceID == nil ? .app : .companion, event: "capture",
                                      outcome: result.duplicate ? "duplicate" : "queued", ids: [result.suggestionID]))
        return result
    }

    /// Replaces a pending capture's proposal, e.g. with a model's classification. `floor` is the
    /// minimum sensitivity the user picked when capturing: no engine's proposal goes below it.
    public func reclassify(suggestionID: UUID, record: ClassificationRecord, floor: Sensitivity? = nil) async throws {
        try await store.writer.write { db in
            guard let s = try SuggestionService.fetch(db, id: suggestionID), s.status == .pending else { throw VaultError.invalidState }
            let p = record.proposal.validated(categories: try CategoryStore.all(db), fallbackTitle: s.title, floor: floor)
            try db.execute(sql: """
                UPDATE suggestion SET title = ?, kind = ?, category_keys = ?, sensitivity = ?, classification = ? WHERE id = ?
                """, arguments: [p.title, p.kind.rawValue, JSON.encode(p.categoryKeys), p.sensitivity.rawValue,
                                 JSON.encode(ClassificationRecord(engine: record.engine, proposal: p, keptOnDevice: record.keptOnDevice)),
                                 suggestionID.db])
        }
    }

    /// The daily job: receipts older than 90 days are deleted.
    @discardableResult
    public func cleanupReceipts(now: Date) async throws -> Int {
        try await store.writer.write { db in
            try db.execute(sql: "DELETE FROM capture_receipt WHERE received_at <= ?", arguments: [now - Self.receiptLifetime])
            return db.changesCount
        }
    }
}

enum DeviceStore {
    static func fetch(_ db: Database, id: UUID) throws -> Device? {
        try Row.fetchOne(db, sql: "SELECT * FROM device WHERE id = ?", arguments: [id.db]).map(Device.from(row:))
    }
}

/// Paired iPhones act as the user (access policy §6): no agent access, panels, ceilings or
/// categories, but still authentication, revocation, the secret scanner, validation and Activity.
/// Pairing and the envelope crypto come in v0.2 (companion protocol); this is the vault side.
public final class DeviceService: Sendable {
    public let store: VaultStore
    public let activity: any ActivityRecorder

    public init(store: VaultStore, activity: any ActivityRecorder) {
        self.store = store
        self.activity = activity
    }

    @discardableResult
    public func register(name: String, model: String, signingPublicKey: Data, hpkePublicKey: Data, now: Date) async throws -> Device {
        let device = Device(id: UUID(), name: name, model: model, signingPublicKey: signingPublicKey, hpkePublicKey: hpkePublicKey,
                            pairedAt: now)
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO device (id, name, model, signing_public_key, hpke_public_key, paired_at) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [device.id.db, name, model, signingPublicKey, hpkePublicKey, now])
        }
        return device
    }

    /// Revoke on the Mac (`actor` the user) or unpair from the phone (the device itself). The
    /// device's next request is refused (T35); its row stays, so Activity can name it.
    public func revoke(deviceID: UUID, now: Date, actor: Actor = .user) async throws {
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE device SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ?", arguments: [now, deviceID.db])
            guard db.changesCount == 1 else { throw VaultError.notFound }
        }
        activity.record(ActivityEvent(time: now, phase: .event, actor: actor, via: actor == .user ? .app : .companion,
                                      event: "device_revoked", outcome: "revoked", ids: [deviceID]))
    }

    /// Paired devices, oldest first.
    public func devices(includingRevoked: Bool = false) async throws -> [Device] {
        try await store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM device \(includingRevoked ? "" : "WHERE revoked_at IS NULL ") ORDER BY paired_at")
                .map(Device.from(row:))
        }
    }

    public func device(id: UUID) async throws -> Device? {
        try await store.writer.read { db in try DeviceStore.fetch(db, id: id) }
    }

    /// Approvals from this iPhone on or off (Settings ▸ iPhone on the Mac, or Settings on the
    /// phone, `actor` the device). Off drops the doorbell tag, so the phone's subscription goes
    /// quiet and the next tag is new.
    @discardableResult
    public func setApprovals(deviceID: UUID, enabled: Bool, now: Date, actor: Actor = .user) async throws -> Device {
        let (device, changed) = try await store.writer.write { db -> (Device, Bool) in
            guard let d = try DeviceStore.fetch(db, id: deviceID), !d.isRevoked else { throw VaultError.notFound }
            guard d.approvalsEnabled != enabled else { return (d, false) }
            try db.execute(sql: """
                UPDATE device SET approvals_enabled = ?, doorbell_tag = CASE WHEN ? THEN doorbell_tag END WHERE id = ?
                """, arguments: [enabled, enabled, deviceID.db])
            return (try DeviceStore.fetch(db, id: deviceID)!, true)
        }
        if changed {
            activity.record(ActivityEvent(time: now, phase: .event, actor: actor, via: actor == .user ? .app : .companion,
                                          event: "device_approvals", outcome: enabled ? "on" : "off", ids: [deviceID]))
        }
        return device
    }

    /// The device's doorbell tag while approvals are on, made the first time the phone asks
    /// (128 random bits, base64url). Nil while they're off.
    public func doorbellTag(deviceID: UUID) async throws -> String? {
        try await store.writer.write { db -> String? in
            guard let d = try DeviceStore.fetch(db, id: deviceID), !d.isRevoked else { throw VaultError.unauthenticated }
            guard d.approvalsEnabled else { return nil }
            if let tag = d.doorbellTag { return tag }
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw VaultError.invalidState }
            let tag = Base64URL.encode(Data(bytes))
            try db.execute(sql: "UPDATE device SET doorbell_tag = ? WHERE id = ?", arguments: [tag, deviceID.db])
            return tag
        }
    }

    /// Last seen and how, for Settings ▸ iPhone. Written at most once a minute per device unless
    /// the transport changed.
    public func touch(deviceID: UUID, transport: DeviceTransport, now: Date) async throws {
        try await store.writer.write { db in
            try db.execute(sql: """
                UPDATE device SET last_seen_at = ?, last_transport = ?
                WHERE id = ? AND revoked_at IS NULL
                  AND (last_seen_at IS NULL OR last_seen_at <= ? OR last_transport IS NOT ?)
                """, arguments: [now, transport.rawValue, deviceID.db, now.addingTimeInterval(-60), transport.rawValue])
        }
    }

    /// How often a memory was shared with agents, and when last (the phone's memory detail).
    public func sharing(memoryID: UUID) async throws -> (count: Int, last: Date?) {
        try await store.writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT count(*) AS n, max(d.delivered_at) AS last FROM disclosure_item i
                JOIN disclosure d ON d.id = i.disclosure_id
                WHERE i.memory_id = ? AND d.status = 'delivered'
                """, arguments: [memoryID.db])
            return (row?["n"] ?? 0, row?["last"])
        }
    }

    /// A paired, unrevoked device, or `unauthenticated` (HTTP 401 at the transport; T35).
    public func authenticate(deviceID: UUID) async throws -> Device {
        guard let d = try await store.writer.read({ db in try DeviceStore.fetch(db, id: deviceID) }), !d.isRevoked else {
            throw VaultError.unauthenticated
        }
        return d
    }

    /// The user creating a memory from the phone (T34): owner rights, logged as `device:<id>`.
    @discardableResult
    public func createMemory(deviceID: UUID, _ draft: MemoryDraft, now: Date) async throws -> Memory {
        var owned = draft
        owned.source = .manual
        owned.sourceDeviceID = deviceID
        let draft = owned
        let memory = try await store.writer.write { db -> Memory in
            guard let d = try DeviceStore.fetch(db, id: deviceID), !d.isRevoked else { throw VaultError.unauthenticated }
            return try MemoryStore.insert(db, draft, actor: .device(deviceID), now: now)
        }
        activity.record(ActivityEvent(time: now, actor: .device(deviceID), via: .companion, event: "memory_created",
                                      outcome: "saved", ids: [memory.id]))
        return memory
    }

    /// `expectedVersion`: the version the phone showed. Another one is `versionConflict`, checked
    /// in the same transaction as the write.
    @discardableResult
    public func updateMemory(deviceID: UUID, memoryID: UUID, _ edit: MemoryEdit, expectedVersion: Int? = nil,
                             now: Date) async throws -> Memory {
        let memory = try await store.writer.write { db -> Memory in
            guard let d = try DeviceStore.fetch(db, id: deviceID), !d.isRevoked else { throw VaultError.unauthenticated }
            try MemoryStore.checkVersion(db, id: memoryID, expected: expectedVersion)
            return try MemoryStore.update(db, id: memoryID, edit, actor: .device(deviceID), now: now)
        }
        activity.record(ActivityEvent(time: now, actor: .device(deviceID), via: .companion, event: "memory_edited",
                                      outcome: "saved", ids: [memory.id]))
        return memory
    }

    /// Archive (`archived`), restore (`active`) or delete (`deleted`) from the phone, at the
    /// version it showed.
    @discardableResult
    public func setMemoryStatus(deviceID: UUID, memoryID: UUID, to status: MemoryStatus, expectedVersion: Int,
                                now: Date) async throws -> Memory {
        let memory = try await store.writer.write { db -> Memory in
            guard let d = try DeviceStore.fetch(db, id: deviceID), !d.isRevoked else { throw VaultError.unauthenticated }
            try MemoryStore.checkVersion(db, id: memoryID, expected: expectedVersion)
            return try MemoryStore.setStatus(db, id: memoryID, to: status, actor: .device(deviceID), now: now)
        }
        let event = switch status {
        case .archived: "memory_archived"
        case .active: "memory_restored"
        case .deleted: "memory_deleted"
        }
        activity.record(ActivityEvent(time: now, actor: .device(deviceID), via: .companion, event: event, outcome: "saved",
                                      ids: [memory.id]))
        return memory
    }
}
