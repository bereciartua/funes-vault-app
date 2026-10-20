@preconcurrency import CloudKit
import Foundation
import Observation

/// One doorbell record and what came back for it.
struct Ring: Identifiable, Sendable {
    var id: String { recordName }
    let seq: Int
    let recordName: String
    let startedAt: Date
    var savedAt: Date?
    var saveError: String?
    /// When the extension's acknowledgement reached the Mac (Mac clock).
    var ackAt: Date?
    var ackPhase: DoorbellAck.Phase?
    /// Phone clock minus Mac clock, from the acknowledgement.
    var phoneDelay: Double?

    var saveSeconds: Double? { savedAt.map { $0.timeIntervalSince(startedAt) } }
    /// Saving started → the extension on the phone reached the Mac. One clock, the Mac's.
    var deliverySeconds: Double? { ackAt.map { $0.timeIntervalSince(startedAt) } }
}

@MainActor @Observable
final class RingModel {
    var tag = Doorbell.defaultTag
    var rings: [Ring] = []
    var status = "Starting…"
    var accountStatus = "Checking iCloud…"
    var listenerStatus = ""
    var autoRemaining = 0
    var interval: Double = 90
    var count = 20

    private let container = CKContainer(identifier: Doorbell.container)
    private var server: AckServer?
    private var autoTask: Task<Void, Never>?

    init() {
        do {
            let server = try AckServer(port: Doorbell.ackPort) { [weak self] ack, arrived in
                Task { @MainActor in self?.received(ack, at: arrived) }
            }
            server.start { [weak self] state in Task { @MainActor in self?.listenerStatus = state } }
            self.server = server
        } catch {
            listenerStatus = "Couldn't listen: \(error.localizedDescription)"
        }
        Task { await checkAccount() }
    }

    func checkAccount() async {
        do {
            let status = try await container.accountStatus()
            accountStatus = switch status {
            case .available: "iCloud available"
            case .noAccount: "Not signed in to iCloud"
            case .restricted: "iCloud restricted"
            case .temporarilyUnavailable: "iCloud temporarily unavailable"
            case .couldNotDetermine: "iCloud status unknown"
            @unknown default: "iCloud status \(status.rawValue)"
            }
        } catch {
            accountStatus = "iCloud error: \(error.localizedDescription)"
        }
    }

    func ring() async {
        let seq = (rings.map(\.seq).max() ?? 0) + 1
        let name = UUID().uuidString.lowercased()
        let started = Date()
        rings.insert(Ring(seq: seq, recordName: name, startedAt: started), at: 0)
        let record = CKRecord(recordType: Doorbell.recordType, recordID: CKRecord.ID(recordName: name))
        record[Doorbell.tagField] = tag as CKRecordValue
        record[Doorbell.seqField] = seq as CKRecordValue
        record[Doorbell.sentAtField] = started as CKRecordValue
        do {
            _ = try await container.privateCloudDatabase.save(record)
            update(name) { $0.savedAt = Date() }
            status = "Ring \(seq) saved"
        } catch {
            update(name) { $0.saveError = error.localizedDescription }
            status = "Ring \(seq) failed: \(error.localizedDescription)"
        }
    }

    func startAuto() {
        autoTask?.cancel()
        autoRemaining = count
        autoTask = Task {
            while autoRemaining > 0, !Task.isCancelled {
                await ring()
                autoRemaining -= 1
                guard autoRemaining > 0 else { break }
                try? await Task.sleep(for: .seconds(interval))
            }
            autoRemaining = 0
        }
    }

    func stopAuto() {
        autoTask?.cancel()
        autoRemaining = 0
    }

    /// Deletes every record this run created.
    func deleteRecords() async {
        let ids = rings.map { CKRecord.ID(recordName: $0.recordName) }
        guard !ids.isEmpty else { return }
        do {
            _ = try await container.privateCloudDatabase.modifyRecords(saving: [], deleting: ids)
            status = "Deleted \(ids.count) records from iCloud"
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func received(_ ack: DoorbellAck, at arrived: Date) {
        if ack.phase == .test {
            status = "The phone reached the Mac (test)"
            return
        }
        update(ack.recordName) { ring in
            guard ring.ackAt == nil else { return }
            ring.ackAt = arrived
            ring.ackPhase = ack.phase
            ring.phoneDelay = Double(ack.phoneReceivedAt - ring.startedAt.milliseconds) / 1000
        }
    }

    private func update(_ name: String, _ change: (inout Ring) -> Void) {
        guard let index = rings.firstIndex(where: { $0.recordName == name }) else { return }
        change(&rings[index])
    }

    // MARK: Results

    var summary: String {
        let delivered = rings.compactMap(\.deliverySeconds).sorted()
        let phone = rings.compactMap(\.phoneDelay).sorted()
        func pct(_ values: [Double], _ p: Double) -> String {
            guard !values.isEmpty else { return "–" }
            let index = min(values.count - 1, Int((Double(values.count - 1) * p).rounded()))
            return String(format: "%.1f s", values[index])
        }
        let saved = rings.filter { $0.savedAt != nil }.count
        return """
        Rings: \(rings.count), saved: \(saved), acknowledged: \(delivered.count), missing: \(saved - delivered.count)
        Mac clock (save → extension reached the Mac): median \(pct(delivered, 0.5)), p90 \(pct(delivered, 0.9)), max \(pct(delivered, 1))
        Phone clock (save → extension ran): median \(pct(phone, 0.5)), p90 \(pct(phone, 0.9)), max \(pct(phone, 1))
        """
    }

    var markdown: String {
        var lines = ["| # | Saved after | Reached the Mac after | Phone clock | Via |", "|---|---|---|---|---|"]
        for ring in rings.reversed() {
            func s(_ v: Double?) -> String { v.map { String(format: "%.2f s", $0) } ?? (ring.saveError == nil ? "–" : "error") }
            lines.append("| \(ring.seq) | \(s(ring.saveSeconds)) | \(s(ring.deliverySeconds)) | \(s(ring.phoneDelay)) | \(ring.ackPhase?.rawValue ?? "missing") |")
        }
        return summary + "\n\n" + lines.joined(separator: "\n")
    }
}
