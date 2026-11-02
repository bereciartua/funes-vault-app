import Foundation
import FunesProtocol
import Testing
@testable import FunesPhone

/// The overview on the phone (ADR-0025, companion protocol §6.1): the cache file, the model that
/// keeps it current, and the demo vault's answer.
@MainActor @Suite struct OverviewCacheTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "overview-tests-\(UUID().uuidString)")
    var cache: OverviewCache { OverviewCache(url: directory.appending(path: OverviewCache.fileName)) }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        calendar.firstWeekday = 2
        return calendar
    }

    func demo(_ content: DemoContent? = nil) -> DemoVault { DemoVault(content: content, calendar: Self.calendar, clock: { t0 }) }

    /// A caller whose every call fails as an unreachable Mac's would.
    struct Unreachable: CompanionCalling {
        func perform<Call: CompanionCall>(_ request: PendingCall<Call>) async throws(CompanionClientError) -> Call.Result {
            throw .unreachable(localNetworkDenied: false)
        }
    }

    @Test func keepsTheLastAnswerOfEachRange() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(cache.read().isEmpty)
        let vault = demo()
        let days = try await vault.overview(.days30)
        try cache.write(days)
        try cache.write(try await vault.overview(.weeks12))
        var later = days
        later.generatedAt = t0.addingTimeInterval(60)
        try cache.write(later)
        let read = cache.read()
        #expect(read.keys.sorted { $0.rawValue < $1.rawValue } == [.weeks12, .days30])
        #expect(read[.days30] == later)
        #expect(read[.weeks12]?.days.count == 12)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: OverviewCache.fileName + ".tmp").path))

        cache.delete()
        #expect(cache.read().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))
    }

    @Test func anUnreadableFileIsNoCache() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: cache.url)
        #expect(cache.read().isEmpty)
        // A write replaces it.
        try cache.write(VaultOverview(range: .days30, generatedAt: t0, timeZone: "UTC", total: 1, thisWeek: .init(), days: [],
                                      rhythm: .init(start: t0, counts: [])))
        #expect(cache.read()[.days30]?.total == 1)
    }

    /// The model shows the cache at once, refreshes it from the vault, keeps it when the Mac is
    /// away, and deletes it on clear.
    @Test func theModelKeepsTheCacheCurrent() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = VaultOverview(range: .days30, generatedAt: t0.addingTimeInterval(-3_600), timeZone: "UTC", total: 7,
                                  thisWeek: .init(), days: [], rhythm: .init(start: t0, counts: []))
        try cache.write(stale)

        let away = OverviewModel(caller: Unreachable(), cache: cache)
        var failures: [CompanionClientError] = []
        away.onFailure = { failures.append($0) }
        #expect(away.overview(.days30) == stale)
        await away.load()
        #expect(away.overview(.days30) == stale)
        #expect(failures == [.unreachable(localNetworkDenied: false)])
        #expect(cache.read()[.days30] == stale)

        let model = OverviewModel(caller: demo(), cache: cache)
        await model.load()
        await model.load(.months12)
        let fresh = try #require(model.overview(.days30))
        #expect(fresh.generatedAt == t0 && fresh.days.count == 30)
        #expect(cache.read()[.days30] == fresh)
        #expect(cache.read()[.months12]?.days.count == 12)

        model.clear()
        #expect(model.overview(.days30) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))
        #expect(OverviewModel(caller: demo(), cache: cache).overviews.isEmpty)
    }

    /// The demo's 12 weeks of sample days, grouped as the Mac groups them, with today last.
    @Test func theDemoAnswersFromItsSampleDays() async throws {
        let content = DemoVault.bundled()
        let sample = try #require(content.overview)
        #expect(sample.days.count == 84)
        let vault = demo()

        let o = try await vault.overview(.days30)
        #expect(o.days.count == 30)
        #expect(o.days.last?.date == Self.calendar.startOfDay(for: t0))
        let last30 = sample.days.suffix(30)
        #expect(o.days.map(\.inbound.total) == last30.map(\.inbound.total))
        #expect(o.days.map(\.shared) == last30.map { $0.out.reduce(0, +) })
        #expect(o.days.map(\.refused) == last30.map(\.refused))
        #expect(o.thisWeek.saved == sample.days.suffix(7).map(\.inbound.total).reduce(0, +))
        #expect(o.rhythm.counts == sample.days.map(\.inbound.total))
        #expect(o.rhythm.start == Self.calendar.date(byAdding: .day, value: -83, to: Self.calendar.startOfDay(for: t0)))
        #expect(o.total == sample.total && o.bySensitivity == sample.bySensitivity)
        let shared = o.days.map(\.shared).reduce(0, +)
        #expect(o.sharedBySensitivity.values.reduce(0, +) == shared)
        #expect(o.sharedByCategory.values.reduce(0, +) == shared)
        #expect(o.agents.map(\.name) == ["Claude Code", "Cursor", "Codex"])
        #expect(o.agents.map(\.shared).reduce(0, +) == shared)
        #expect(o.agents.allSatisfy { ($0.lastRequestAt ?? .distantFuture) < t0 })
        #expect(o.inboxPending == 7 && o.oldestPendingAt != nil)
        #expect(try #require(o.lastTidyUpAt) <= t0)
        // Agent ids are the keys of each day's out.
        #expect(Set(o.days.flatMap(\.out.keys)).isSubset(of: Set(o.agents.map(\.id))))

        let weeks = try await vault.overview(.weeks12)
        #expect(weeks.days.count == 12)
        #expect(weeks.days.last?.date == Self.calendar.dateInterval(of: .weekOfYear, for: t0)?.start)
        #expect(weeks.days.map(\.inbound.total).reduce(0, +) <= sample.days.map(\.inbound.total).reduce(0, +))
        #expect(weeks.days.last?.inbound.total == sample.days.suffix(5).map(\.inbound.total).reduce(0, +))
        let months = try await vault.overview(.months12)
        #expect(months.days.count == 12 && months.days.prefix(8).allSatisfy { $0.inbound.total == 0 })
    }

    @Test func scaledCountsAddUp() {
        #expect(DemoVault.scaled(["a": 1, "b": 1, "c": 1], to: 10).values.reduce(0, +) == 10)
        #expect(DemoVault.scaled(["a": 3, "b": 1], to: 8) == ["a": 6, "b": 2])
        #expect(DemoVault.scaled(["a": 1], to: 0).isEmpty)
    }

    /// Counts only: no demo memory's or suggestion's text reaches the overview or its cache file.
    @Test func noMemoryTextInTheCache() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = DemoVault.bundled()
        let vault = demo()
        let model = OverviewModel(caller: vault, cache: cache)
        for range in OverviewRange.allCases { await model.load(range) }
        let file = String(decoding: try Data(contentsOf: cache.url), as: UTF8.self)
        let inbox = try await vault.call(InboxList.self, InboxListParams())
        let texts = content.memories.flatMap { [$0.title, $0.body] } + inbox.items.flatMap { [$0.title, $0.body] }
        #expect(!texts.isEmpty)
        for text in texts { #expect(!file.contains(text), "\(text)") }
        #expect(file.contains("Claude Code"))
    }
}

/// The widgets tell the demo's counts from the Mac's (FR-H-06): the cache says whose they are,
/// never mixes the two, and a demo's left behind goes when the app starts on the real pairing.
@MainActor @Suite struct OverviewCacheDemoTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "overview-demo-tests-\(UUID().uuidString)")
    var cache: OverviewCache { OverviewCache(url: directory.appending(path: OverviewCache.fileName)) }

    func overview(_ range: OverviewRange, total: Int) -> VaultOverview {
        VaultOverview(range: range, generatedAt: t0, timeZone: "UTC", total: total, thisWeek: .init(), days: [],
                      rhythm: .init(start: t0, counts: []))
    }

    @Test func theDemosCountsAreMarkedAndNeverMixed() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try cache.write(overview(.days30, total: 1))
        try cache.write(overview(.weeks12, total: 1))
        #expect(cache.contents() == OverviewCache.Contents(overviews: [.days30: overview(.days30, total: 1),
                                                                       .weeks12: overview(.weeks12, total: 1)]))
        try cache.write(overview(.days30, total: 2), demo: true)
        #expect(cache.contents() == OverviewCache.Contents(overviews: [.days30: overview(.days30, total: 2)], isDemo: true))
        try cache.write(overview(.days30, total: 3))
        #expect(cache.contents() == OverviewCache.Contents(overviews: [.days30: overview(.days30, total: 3)]))
    }

    @Test func theModelSaysWhenTheCacheChanges() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = DemoVault(calendar: OverviewCacheTests.calendar, clock: { t0 })
        let demo = OverviewModel(caller: vault, cache: cache, demo: true)
        var changes = 0
        demo.onCacheChange = { changes += 1 }
        await demo.load()
        #expect(changes == 1 && cache.contents().isDemo)

        // The app was closed in the demo: the real model starts without its counts.
        let real = OverviewModel(caller: OverviewCacheTests.Unreachable(), cache: cache)
        #expect(real.overviews.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))

        demo.clear()
        #expect(changes == 2)
    }
}

extension OverviewCacheDemoTests {
    /// The widgets' gallery and placeholder: the demo's answer, at once.
    @Test func theSampleIsTheDemosAnswer() async throws {
        let vault = DemoVault(calendar: OverviewCacheTests.calendar, clock: { t0 })
        #expect(vault.sampleOverview() == (try await vault.overview(.days30)))
    }
}
