import Foundation
import Testing
@testable import FunesCore

/// Task 3.1: "Pause Funes Vault" durations (FR-A-11) and change observation for the app's screens.
@Suite struct AppShellTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func pauseDurations() {
        let now = date(17, 23, 30)
        #expect(FunesPause.Duration.oneHour.end(from: now) == now.addingTimeInterval(3_600))
        #expect(FunesPause.Duration.untilTomorrow.end(from: now, calendar: Self.calendar) == date(18, 8))
        // Just after midnight, "tomorrow" is still the next calendar day.
        #expect(FunesPause.Duration.untilTomorrow.end(from: date(18, 0, 10), calendar: Self.calendar) == date(19, 8))
        #expect(FunesPause.Duration.untilResumed.end(from: now) == .distantFuture)
    }

    @Test func pauseEndsOnTime() {
        let pause = FunesPause()
        let now = date(17, 10)
        pause.pause(until: FunesPause.Duration.oneHour.end(from: now))
        #expect(pause.isPaused(at: now) && pause.pausedUntil(at: now) == now.addingTimeInterval(3_600))
        #expect(!pause.isPaused(at: now.addingTimeInterval(3_600)) && pause.pausedUntil(at: now.addingTimeInterval(3_600)) == nil)
        pause.pause(until: .distantFuture)
        #expect(pause.pausedUntil(at: now) == .distantFuture)
        pause.resume()
        #expect(!pause.isPaused(at: now))
    }

    @Test func changesAreObserved() async throws {
        let v = try TestVault()
        let seen = AsyncStream<Void>.makeStream()
        let observation = v.store.observeChanges { seen.continuation.yield() }
        try v.store.createMemory(MemoryDraft(title: "Coffee", body: "Flat white", categoryKeys: ["personal_preferences"]),
                                 now: Date())
        var iterator = seen.stream.makeAsyncIterator()
        _ = await iterator.next()
        withExtendedLifetime(observation) {}
    }
}
