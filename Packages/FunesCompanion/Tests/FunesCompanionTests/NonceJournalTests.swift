import BridgeKitCore
import Foundation
import FunesCore
import FunesProtocol
import Testing
@testable import FunesCompanion

/// Replay protection across a relaunch (§3, step 3): the nonces are journalled in the data
/// folder, so it holds whatever the phone's and the Mac's clocks say.
@Suite struct NonceJournalTests {
    static func journal(_ h: CompanionHarness) -> URL { EnvelopeGuard.journalURL(dataDirectory: h.directory) }

    /// A guard on the harness's journal, as a launch after the first one with it finds it.
    static func guardian(_ h: CompanionHarness) -> EnvelopeGuard {
        let url = journal(h)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        return EnvelopeGuard(journal: url, now: h.clock.now)
    }

    static func entries(_ url: URL) throws -> [ReplayCache.Entry] {
        guard case let .entries(entries) = try NonceJournal(url: url).load(since: .distantPast) else { return [] }
        return entries
    }

    /// The monotonic clock the refusal windows run on, moved by hand.
    final class Uptime: @unchecked Sendable {
        private let lock = NSLock()
        private let start = ContinuousClock.now
        private var offset: Duration = .zero
        var now: ContinuousClock.Instant { lock.withLock { start + offset } }
        func advance(_ seconds: Double) { lock.withLock { offset += .seconds(seconds) } }
    }

    /// No journal (the first launch with it, or deleted): what the last run accepted in its last
    /// two minutes is unknown, so calls are refused, signed and retryable, until the clock-skew
    /// window has passed; then they go through, and the journal exists from then on.
    /// No journal: refused for twice the clock skew, since a phone up to the skew fast sends a
    /// timestamp that stays acceptable that long; a relaunch inside the window starts it again,
    /// because the file only appears once a call is accepted.
    @Test func noJournalRefusesForTwiceTheClockSkew() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let uptime = Uptime()
        let router = h.router(guardian: EnvelopeGuard(journal: Self.journal(h), now: h.clock.now, monotonic: { uptime.now }))
        let early = await router.handle(try h.sealedRequest(phone: phone, at: t0), transport: .lan)
        #expect(early.status == 401 && CompanionAuthError(body: early.body) == .unavailable)
        uptime.advance(2 * CompanionProtocol.maxClockSkew - 1)
        #expect(CompanionAuthError(body: await router.handle(try h.sealedRequest(phone: phone, at: t0), transport: .lan).body)
            == .unavailable)
        #expect(!FileManager.default.fileExists(atPath: Self.journal(h).path))
        // Relaunched inside the window: still no journal, so the window starts again.
        let relaunchUptime = Uptime()
        let relaunched = h.router(guardian: EnvelopeGuard(journal: Self.journal(h), now: h.clock.now,
                                                          monotonic: { relaunchUptime.now }))
        #expect(CompanionAuthError(body: await relaunched.handle(try h.sealedRequest(phone: phone, at: t0), transport: .lan).body)
            == .unavailable)
        uptime.advance(2)
        #expect(await router.handle(try h.sealedRequest(phone: phone, at: t0), transport: .lan).status == 200)
        #expect(FileManager.default.fileExists(atPath: Self.journal(h).path))
    }

    /// A phone 90 s fast: an envelope it sent before the Mac restarts is still a replay after.
    @Test func aFastPhonesEnvelopeIsAReplayAfterARelaunch() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let before = h.router(guardian: Self.guardian(h))
        let captured = try h.sealedRequest(phone: phone, at: t0.addingTimeInterval(90))
        #expect(await before.handle(captured, transport: .lan).status == 200)

        h.clock.advance(5)
        let relaunched = h.router(guardian: Self.guardian(h))
        #expect(CompanionAuthError(body: await relaunched.handle(captured, transport: .lan).body) == .replay)
        // New requests go through, on any clock within two minutes.
        #expect(await relaunched.handle(try h.sealedRequest(phone: phone, at: h.clock.now.addingTimeInterval(90)),
                                        transport: .lan).status == 200)
        #expect(await relaunched.handle(try h.sealedRequest(phone: phone, at: h.clock.now), transport: .lan).status == 200)
    }

    /// The Mac's clock steps back after launch (NTP fixing a fast clock): calls on the corrected
    /// clock go through at once, and a replay is still refused.
    @Test func aMacClockSteppingBackRefusesNothingNew() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let router = h.router(guardian: Self.guardian(h))
        let early = try h.sealedRequest(phone: phone, at: t0)
        #expect(await router.handle(early, transport: .lan).status == 200)
        h.clock.advance(-300)
        let request = try h.sealedRequest(phone: phone, at: h.clock.now)
        #expect(await router.handle(request, transport: .lan).status == 200)
        #expect(CompanionAuthError(body: await router.handle(request, transport: .lan).body) == .replay)
        // Relaunched on the corrected clock, the earlier nonces are still remembered.
        let relaunched = h.router(guardian: Self.guardian(h))
        #expect(CompanionAuthError(body: await relaunched.handle(request, transport: .lan).body) == .replay)
    }

    /// The file is 0600, keeps only the window's entries across a launch, and ignores a torn
    /// last record.
    @Test func theFileKeepsOnlyTheWindow() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let url = Self.journal(h)
        let router = h.router(guardian: Self.guardian(h))
        for i in 0..<3 {
            #expect(await router.handle(try h.sealedRequest(phone: phone, at: t0.addingTimeInterval(Double(i))), transport: .lan).status == 200)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.size] as? NSNumber)?.intValue == 3 * NonceJournal.recordBytes)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 20))
        try handle.close()
        #expect(try Self.entries(url).count == 3)
        // The next append cuts the torn tail off first, so nothing after it is out of line.
        var journal = NonceJournal(url: url)
        try journal.append(ReplayCache.Entry(deviceID: UUID(), nonce: Data(count: 16), sentAt: t0, recordedAt: t0))
        #expect(try Self.entries(url).count == 4)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue == 4 * NonceJournal.recordBytes)

        // A launch past the window drops them all.
        _ = EnvelopeGuard(journal: url, now: t0.addingTimeInterval(CompanionProtocol.replayWindow + 60))
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue == 0)
    }

    /// A journal that's there but can't be read (here a symlink) refuses calls, signed and
    /// retryable, rather than forgetting what it held.
    @Test func anUnreadableJournalFailsClosed() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let url = Self.journal(h)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: h.directory.appending(path: "elsewhere"))
        let router = h.router(guardian: EnvelopeGuard(journal: url, now: h.clock.now))
        let response = await router.handle(try h.sealedRequest(phone: phone, at: t0), transport: .lan)
        #expect(response.status == 401 && CompanionAuthError(body: response.body) == .unavailable)
    }

    @Test func recordsRoundTrip() {
        let entry = ReplayCache.Entry(deviceID: UUID(), nonce: Data((0..<16).map { UInt8($0) }), sentAt: Date(timeIntervalSince1970: 1_800_000_000.123),
                                      recordedAt: Date(timeIntervalSince1970: 1_800_000_001.456))
        #expect(NonceJournal.decode(NonceJournal.encode(entry)) == entry)
    }
}
