import Foundation
import FunesCore
import FunesProtocol
import Observation

/// Home's numbers (FR-H-02): the vault's overview for the chosen range, read from the vault
/// directly (no companion call), when Home appears and whenever the vault changes while it shows.
/// Counts only, never memory text or titles (ADR-0025).
@MainActor @Observable
final class HomeModel {
    static let rangeKey = "HomePulseRange"

    private let services: VaultEnvironment
    private let defaults: UserDefaults
    /// The pulse's range, remembered; 30 days at first.
    var range: OverviewInsights.Range {
        didSet {
            guard range != oldValue else { return }
            defaults.set(range.rawValue, forKey: Self.rangeKey)
            Task { await load() }
        }
    }
    private(set) var overview: VaultOverview?
    /// What the chart draws: the overview for `range`, once it's read.
    private(set) var insights: OverviewInsights?
    @ObservationIgnored private var generation = 0

    init(services: VaultEnvironment, defaults: UserDefaults) {
        self.services = services
        self.defaults = defaults
        range = defaults.string(forKey: Self.rangeKey).flatMap(OverviewInsights.Range.init) ?? .days30
    }

    /// Reads the overview off the main actor; a later read wins over a slower earlier one.
    func load(now: Date = Date()) async {
        generation += 1
        let mine = generation
        let range = self.range
        let store = services.store
        let calendar = Calendar.current
        let read = await Task.detached(priority: .userInitiated) {
            try? store.overview(range.overviewRange, now: now, calendar: calendar)
        }.value
        guard mine == generation, let read else { return }
        overview = read
        insights = OverviewInsights(read, range: range, calendar: calendar)
    }
}
