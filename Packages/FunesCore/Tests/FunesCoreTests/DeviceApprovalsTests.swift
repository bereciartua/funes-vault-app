import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// Approvals from the iPhone (task 5.6, FR-iOS-12): the per-device switch, the doorbell tag, and
/// a phone's answer going through the same single-use approval as the Mac's.
@Suite struct DeviceApprovalsTests {
    static func phone(_ v: TestVault, log: InMemoryActivityLog = InMemoryActivityLog()) async throws -> (DeviceService, Device) {
        let devices = DeviceService(store: v.store, activity: log)
        let phone = try await devices.register(name: "Phone", model: "iPhone", signingPublicKey: Data([1]),
                                               hpkePublicKey: Data([2]), now: t0)
        return (devices, phone)
    }

    /// Storage §3: a v2 vault's paired iPhone keeps its keys and gets approvals on, with no tag yet.
    @Test func migratesAVersion2Vault() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "funes-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "vault.sqlite")
        let deviceID = UUID()
        do {
            let queue = try DatabaseQueue(path: file.path)
            try Schema.migrator.migrate(queue, upTo: "v2_remote_access")
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO device (id, name, model, signing_public_key, hpke_public_key, paired_at) VALUES (?, 'Phone', 'iPhone17,1', ?, ?, ?)
                    """, arguments: [deviceID.db, Data([1]), Data([2]), t0])
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = try VaultStore.open(directory: directory)
        let device = try #require(try await DeviceService(store: store, activity: InMemoryActivityLog()).device(id: deviceID))
        #expect(device.name == "Phone" && device.signingPublicKey == Data([1]) && device.approvalsEnabled && device.doorbellTag == nil)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Backups").path)
        #expect(backups.contains { $0.hasPrefix("pre-v3_device_approvals") })
    }

    @Test func onByDefaultWithNoTagUntilThePhoneAsks() async throws {
        let v = try TestVault()
        let (devices, phone) = try await Self.phone(v)
        #expect(phone.approvalsEnabled && phone.doorbellTag == nil && !phone.rings)
        let tag = try #require(try await devices.doorbellTag(deviceID: phone.id))
        #expect(tag.count == 22 && Base64URL.decode(tag)?.count == 16)
        #expect(try await devices.doorbellTag(deviceID: phone.id) == tag)
        #expect(try await devices.device(id: phone.id)?.rings == true)
    }

    @Test func turningOffDropsTheTagAndTheNextOneIsNew() async throws {
        let v = try TestVault()
        let log = InMemoryActivityLog()
        let (devices, phone) = try await Self.phone(v, log: log)
        let first = try await devices.doorbellTag(deviceID: phone.id)
        let off = try await devices.setApprovals(deviceID: phone.id, enabled: false, now: t0)
        #expect(!off.approvalsEnabled && off.doorbellTag == nil && !off.rings)
        #expect(try await devices.doorbellTag(deviceID: phone.id) == nil)
        try await devices.setApprovals(deviceID: phone.id, enabled: true, now: t0, actor: .device(phone.id))
        let second = try await devices.doorbellTag(deviceID: phone.id)
        #expect(second != nil && second != first)
        // Each change once in Activity; setting the same value again logs nothing.
        try await devices.setApprovals(deviceID: phone.id, enabled: true, now: t0)
        #expect(log.events.map(\.outcome) == ["off", "on"])
        #expect(log.events.map(\.actor) == ["user", "device:\(phone.id.db)"])
        #expect(log.events.map(\.via) == [.app, .companion])
    }

    @Test func aRevokedDeviceHasNoTagAndNoSwitch() async throws {
        let v = try TestVault()
        let (devices, phone) = try await Self.phone(v)
        _ = try await devices.doorbellTag(deviceID: phone.id)
        try await devices.revoke(deviceID: phone.id, now: t0)
        #expect(try await devices.device(id: phone.id)?.rings == false)
        await #expect(throws: VaultError.unauthenticated) { try await devices.doorbellTag(deviceID: phone.id) }
        await #expect(throws: VaultError.notFound) { try await devices.setApprovals(deviceID: phone.id, enabled: false, now: t0) }
    }

    /// The phone's answer is logged under the device; whichever answer comes second is refused.
    @Test func aPhoneAnswerIsLoggedUnderTheDeviceAndIsSingleUse() async throws {
        let fx = try ServiceFixture()
        let id = try #require(try await fx.request().requestID)
        let panel = try #require(try await fx.disclosures.panel(requestID: id, now: fx.now))
        let device = UUID()
        try await fx.disclosures.approve(requestID: id, snapshotRevision: panel.snapshotRevision, memoryIDs: [fx.id("m2")],
                                         now: fx.now, actor: .device(device), via: .companion)
        let row = try #require(fx.activity.events.last)
        #expect(row.event == "approval" && row.outcome == "approved" && row.actor == "device:\(device.db)" && row.via == .companion)
        await #expect(throws: VaultError.invalidState) {
            try await fx.disclosures.approve(requestID: id, snapshotRevision: panel.snapshotRevision, memoryIDs: [fx.id("m2")],
                                             now: fx.now)
        }
        await #expect(throws: VaultError.invalidState) {
            try await fx.disclosures.deny(requestID: id, now: fx.now, waitingOnly: true, actor: .device(device), via: .companion)
        }
        #expect(try await fx.status(id).0 == .approved)
    }
}
