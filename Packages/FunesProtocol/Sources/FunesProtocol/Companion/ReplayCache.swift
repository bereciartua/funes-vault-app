import Foundation

/// The nonces seen in the last 10 minutes, per device, up to 10,000 each (§3, step 3).
///
/// When a device's list is full, the oldest nonce is dropped and its timestamp becomes that
/// device's floor: any later envelope sent at or before the floor counts as a replay. So a full
/// cache refuses old envelopes instead of forgetting them (fail closed). Hold it in an actor.
///
/// The cache itself lives in memory; the Mac keeps its entries on disk too and records them
/// back at launch (`entries`), so a relaunch doesn't forget what it saw.
public struct ReplayCache: Sendable {
    public let window: TimeInterval
    public let capacityPerDevice: Int
    private var devices: [UUID: DeviceNonces] = [:]

    /// One remembered nonce: whose, the envelope's own `ts`, and when the Mac recorded it.
    public struct Entry: Sendable, Equatable {
        public var deviceID: UUID
        public var nonce: Data
        public var sentAt: Date
        public var recordedAt: Date

        public init(deviceID: UUID, nonce: Data, sentAt: Date, recordedAt: Date) {
            self.deviceID = deviceID
            self.nonce = nonce
            self.sentAt = sentAt
            self.recordedAt = recordedAt
        }
    }

    public init(window: TimeInterval = CompanionProtocol.replayWindow,
                capacityPerDevice: Int = CompanionProtocol.replayCapacityPerDevice) {
        self.window = window
        self.capacityPerDevice = max(1, capacityPerDevice)
    }

    /// Whether an envelope with this nonce, sent at `sentAt`, must be refused.
    public func isReplay(nonce: Data, deviceID: UUID, sentAt: Date, now: Date) -> Bool {
        guard let entry = devices[deviceID] else { return false }
        if let floor = entry.floor, sentAt <= floor { return true }
        guard let seen = entry.seen[nonce] else { return false }
        return seen > now.addingTimeInterval(-window)
    }

    public mutating func record(nonce: Data, deviceID: UUID, sentAt: Date, now: Date) {
        // Mutated in place: a copy would duplicate up to 10,000 entries on every call.
        devices[deviceID, default: DeviceNonces()].record(nonce: nonce, sentAt: sentAt, now: now, window: window,
                                                          capacity: capacityPerDevice)
    }

    /// Forgets a device (revoked or unpaired).
    public mutating func remove(deviceID: UUID) { devices[deviceID] = nil }

    /// Nonces remembered for a device; for tests.
    public func count(deviceID: UUID) -> Int { devices[deviceID]?.seen.count ?? 0 }

    /// Every nonce remembered, each device's in the order recorded. Recording them again, oldest
    /// first, with `now` their `recordedAt`, gives the same cache (a full device's floor comes
    /// back from its own overflow; under the rate limit a device never fills it).
    public var entries: [Entry] {
        devices.flatMap { deviceID, nonces in
            nonces.order[nonces.head...].compactMap { item in
                nonces.seen[item.nonce].map { Entry(deviceID: deviceID, nonce: item.nonce, sentAt: item.sentAt, recordedAt: $0) }
            }
        }
    }

    private struct DeviceNonces: Sendable {
        /// Nonce → when the Mac recorded it.
        var seen: [Data: Date] = [:]
        /// Insertion order, with each envelope's own `ts`; `head` skips removed entries.
        var order: [(nonce: Data, sentAt: Date)] = []
        var head = 0
        var floor: Date?

        mutating func record(nonce: Data, sentAt: Date, now: Date, window: TimeInterval, capacity: Int) {
            prune(before: now.addingTimeInterval(-window))
            if seen[nonce] == nil {
                seen[nonce] = now
                order.append((nonce, sentAt))
            }
            while seen.count > capacity, let oldest = removeFirst() {
                seen[oldest.nonce] = nil
                floor = max(floor ?? oldest.sentAt, oldest.sentAt)
            }
        }

        mutating func removeFirst() -> (nonce: Data, sentAt: Date)? {
            guard head < order.count else { return nil }
            let first = order[head]
            head += 1
            if head > 1_024, head * 2 > order.count {
                order.removeFirst(head)
                head = 0
            }
            return first
        }

        /// Drops nonces recorded before `cutoff`. Recording times only grow, so they are at the front.
        mutating func prune(before cutoff: Date) {
            while head < order.count, let recorded = seen[order[head].nonce], recorded <= cutoff {
                seen[order[head].nonce] = nil
                _ = removeFirst()
            }
        }
    }
}
