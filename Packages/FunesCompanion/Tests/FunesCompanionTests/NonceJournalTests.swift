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

    /// A phone 90 s fast: an envelope it sent before the Mac restarts is still a replay after.
    @Test func aFastPhonesEnvelopeIsAReplayAfterARelaunch() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let before = h.router(guardian: EnvelopeGuard(journal: Self.journal(h), now: h.clock.now))
        let captured = try h.sealedRequest(phone: phone, at: t0.addingTimeInterval(90))
        #expect(await before.handle(captured, transport: .lan).status == 200)

        h.clock.advance(5)
        let relaunched = h.router(guardian: EnvelopeGuard(journal: Self.journal(h), now: h.clock.now))
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
        let router = h.router(guardian: EnvelopeGuard(journal: Self.journal(h), now: h.clock.now))
        let early = try h.sealedRequest(phone: phone, at: t0)
        #expect(await router.handle(early, transport: .lan).status == 200)
        h.clock.advance(-300)
        let request = try h.sealedRequest(phone: phone, at: h.clock.now)
        #expect(await router.handle(request, transport: .lan).status == 200)
        #expect(CompanionAuthError(body: await router.handle(request, transport: .lan).body) == .replay)
        // Relaunched on the corrected clock, the earlier nonces are still remembered.
        let relaunched = h.router(guardian: EnvelopeGuard(journal: Self.journal(h), now: h.clock.now))
        #expect(CompanionAuthError(body: await relaunched.handle(request, transport: .lan).body) == .replay)
    }

    /// The file is 0600, keeps only the window's entries across a launch, and ignores a torn
    /// last record.
    @Test func theFileKeepsOnlyTheWindow() async throws {
        let h = try CompanionHarness()
        let phone = try await h.pairedPhone()
        let url = Self.journal(h)
        let router = h.router(guardian: EnvelopeGuard(journal: url, now: h.clock.now))
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
        #expect(try NonceJournal(url: url).load(since: .distantPast).count == 3)

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
