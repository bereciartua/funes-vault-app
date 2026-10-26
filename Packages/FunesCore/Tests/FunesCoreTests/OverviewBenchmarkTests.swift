import Foundation
import FunesProtocol
import GRDB
import Testing
@testable import FunesCore

/// FR-H-01's budget: the overview under 50 ms on a 10,000-memory vault with a year and a half of
/// agent traffic (ADR-0025), with the `v5_overview_indexes`. Measured at user-interactive QoS as
/// the CPU time of the read on its database thread, the best of 7 after one to warm the cache:
/// the work itself, which a busy Mac or the suites running alongside inflate less than they do
/// wall-clock time (printed too). Measured times are in spec/plans/phase-7-home.md (7.2).
///
/// It runs alone, with `FUNES_OVERVIEW_BENCHMARK=1`, as test.sh does outside CI: beside the other
/// suites, which share the CPU, or on CI's shared runners, a timing says little.
@Suite struct OverviewBenchmarkTests {
    static let budget: Duration = .milliseconds(50)

    /// SplitMix64, so the fixture is the same on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 10,000 memories over 540 days (bodies of about 300 characters), 8 agents, 8,000 delivered
    /// requests sharing 1–5 memories each (about 24,000 items), 2,000 refused and 500 others, each
    /// with a 20-memory candidate snapshot as real requests keep, 60 Inbox items, 30 tidy-up runs.
    /// Heavier than the author's vault, so the budget holds with room.
    static func fixture() throws -> TestVault {
        let vault = try TestVault()
        var rng = Seeded(state: 42)
        let sources = MemorySource.allCases
        let categories = MemoryCategory.builtins.map(\.key)
        let reasons: [ReasonCode] = [.deniedByUser, .funesPaused, .noAllowedMemories, .approvalExpired]
        func at(_ rng: inout Seeded) -> Date { t0.addingTimeInterval(-Double.random(in: 0..<(540 * 86_400), using: &rng)) }
        let snapshot = JSON.encode((0..<20).map { _ in SnapshotItem(id: UUID(), version: 3, score: 0.41) })
        let filler = String(repeating: "Something worth remembering, in a few words. ", count: 6)
        try vault.store.writer.write { db in
            let seed = OverviewSeed(db: db)
            for i in 0..<10_000 {
                let picked = Array(categories.shuffled(using: &rng).prefix(Int.random(in: 1...2, using: &rng)))
                try seed.memory("Memory \(i)", body: "\(filler)\(i)", source: sources.randomElement(using: &rng)!, at: at(&rng),
                                status: Int.random(in: 0..<10, using: &rng) == 0 ? .archived : .active,
                                sensitivity: Sensitivity.allCases.randomElement(using: &rng)!,
                                kind: MemoryKind.allCases.randomElement(using: &rng)!, categories: picked)
            }
            let agents = try (0..<8).map { i in
                try seed.agent("Agent \(i)", kind: AgentKind.allCases[i], removed: i == 7 ? t0.plus(days: -30) : nil, lastRequest: t0)
            }
            for _ in 0..<8_000 {
                let items = (0..<Int.random(in: 1...5, using: &rng)).map { _ in
                    (Sensitivity.allCases.randomElement(using: &rng)!, categories.randomElement(using: &rng)!)
                }
                try seed.delivered(agents.randomElement(using: &rng)!, at: at(&rng), items: items,
                                   withheld: ["above_sensitivity_ceiling": Int.random(in: 0...3, using: &rng)], snapshot: snapshot)
            }
            for _ in 0..<2_000 {
                try seed.disclosure(agents.randomElement(using: &rng)!, status: .denied, at: at(&rng),
                                    reason: reasons.randomElement(using: &rng)!, withheld: ["denied_category": 1], snapshot: snapshot)
            }
            for _ in 0..<500 {
                try seed.disclosure(agents.randomElement(using: &rng)!, status: .failed, at: at(&rng), snapshot: snapshot)
            }
            for i in 0..<60 { try seed.suggestion("Suggestion \(i)", body: "Body \(i)", at: at(&rng)) }
            for i in 0..<30 { try seed.tidyUp(started: t0.plus(days: Double(-i)), finished: t0.plus(days: Double(-i)).plus(minutes: 3)) }
        }
        return vault
    }

    /// The calling thread's CPU time.
    static func threadCPUTime() -> Duration {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }

    /// One read at user-interactive QoS, as Home asks for it: its CPU time on the database
    /// thread, and its wall-clock time. (The test's own thread runs at default QoS, which a busy
    /// Mac puts on its efficiency cores.)
    static func measure(_ store: VaultStore, _ range: OverviewRange) throws -> (cpu: Duration, wall: Duration) {
        try DispatchQueue.global(qos: .userInteractive).sync {
            let clock = ContinuousClock()
            var cpu = Duration.zero
            let wall = try clock.measure {
                cpu = try store.writer.read { db in
                    let start = threadCPUTime()
                    _ = try OverviewStore.overview(db, range: range, now: t0, calendar: .current)
                    return threadCPUTime() - start
                }
            }
            return (cpu, wall)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUNES_OVERVIEW_BENCHMARK"] != nil,
                   "Run alone: FUNES_OVERVIEW_BENCHMARK=1 swift test --package-path Packages/FunesCore --filter OverviewBenchmarkTests"))
    func underFiftyMillisecondsOnTenThousandMemories() throws {
        let vault = try Self.fixture()
        #expect(try vault.count("SELECT COUNT(*) FROM memory") == 10_000)
        let ms = Duration.UnitsFormatStyle.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))
        for range in OverviewRange.allCases {
            _ = try Self.measure(vault.store, range)
            let runs = try (0..<7).map { _ in try Self.measure(vault.store, range) }
            let cpu = runs.map(\.cpu).sorted(), wall = runs.map(\.wall).sorted()
            print("overview \(range.rawValue): CPU best \(cpu[0].formatted(ms)), median \(cpu[3].formatted(ms)); "
                  + "wall-clock best \(wall[0].formatted(ms)), median \(wall[3].formatted(ms))")
            #expect(cpu[0] < Self.budget, "overview \(range.rawValue) took \(cpu[0]) of CPU")
        }
    }
}
