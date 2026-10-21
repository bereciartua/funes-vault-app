import Foundation
import Testing
@testable import FunesProtocol

@Suite struct ReplayCacheTests {
    let device = UUID()
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    func nonce(_ i: Int) -> Data { withUnsafeBytes(of: Int64(i).bigEndian) { Data($0) } + Data(count: 8) }

    @Test func remembersANonceForTenMinutes() {
        var cache = ReplayCache()
        cache.record(nonce: nonce(1), deviceID: device, sentAt: t0, now: t0)
        #expect(cache.isReplay(nonce: nonce(1), deviceID: device, sentAt: t0, now: t0.addingTimeInterval(599)))
        #expect(!cache.isReplay(nonce: nonce(1), deviceID: device, sentAt: t0, now: t0.addingTimeInterval(601)))
        #expect(!cache.isReplay(nonce: nonce(2), deviceID: device, sentAt: t0, now: t0))
    }

    @Test func noncesArePerDevice() {
        var cache = ReplayCache()
        cache.record(nonce: nonce(1), deviceID: device, sentAt: t0, now: t0)
        #expect(!cache.isReplay(nonce: nonce(1), deviceID: UUID(), sentAt: t0, now: t0))
    }

    @Test func expiredNoncesArePruned() {
        var cache = ReplayCache()
        for i in 0..<100 { cache.record(nonce: nonce(i), deviceID: device, sentAt: t0, now: t0) }
        let later = t0.addingTimeInterval(700)
        cache.record(nonce: nonce(1_000), deviceID: device, sentAt: later, now: later)
        #expect(cache.count(deviceID: device) == 1)
    }

    /// Full: the oldest nonce goes, and anything sent at or before it is refused from then on.
    @Test func fullCacheFailsClosed() {
        var cache = ReplayCache(capacityPerDevice: 3)
        for i in 0..<4 {
            let sent = t0.addingTimeInterval(Double(i))
            cache.record(nonce: nonce(i), deviceID: device, sentAt: sent, now: sent)
        }
        #expect(cache.count(deviceID: device) == 3)
        // nonce 0 was evicted, but its envelope still can't be replayed.
        #expect(cache.isReplay(nonce: nonce(0), deviceID: device, sentAt: t0, now: t0.addingTimeInterval(5)))
        // A new nonce sent before the evicted one is refused too; one sent after is fine.
        #expect(cache.isReplay(nonce: nonce(99), deviceID: device, sentAt: t0, now: t0.addingTimeInterval(5)))
        #expect(!cache.isReplay(nonce: nonce(99), deviceID: device, sentAt: t0.addingTimeInterval(4), now: t0.addingTimeInterval(5)))
    }

    @Test func removingADeviceForgetsIt() {
        var cache = ReplayCache()
        cache.record(nonce: nonce(1), deviceID: device, sentAt: t0, now: t0)
        cache.remove(deviceID: device)
        #expect(cache.count(deviceID: device) == 0)
    }

    @Test func tenThousandNoncesStayFast() {
        var cache = ReplayCache()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<20_000 {
                let now = t0.addingTimeInterval(Double(i) / 100)
                #expect(!cache.isReplay(nonce: nonce(i), deviceID: device, sentAt: now, now: now))
                cache.record(nonce: nonce(i), deviceID: device, sentAt: now, now: now)
            }
        }
        #expect(cache.count(deviceID: device) == 10_000)
        #expect(elapsed < .seconds(5))
    }
}
