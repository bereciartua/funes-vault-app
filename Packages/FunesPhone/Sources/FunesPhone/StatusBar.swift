import Foundation
import Observation

/// When the status bar above the tab bar shows what (UX: iPhone, Status bar; FR-iOS-06): nothing
/// while connected, a state only once it has lasted 2 s, "Back online" for 3 s after the Mac
/// comes back, and the demo label always. Times are passed in, so it's tested without waiting.
public struct StatusBarTimeline: Sendable, Equatable {
    /// What the bar shows.
    public enum Item: Sendable, Equatable {
        /// A `BannerState` other than `.connected`.
        case state(BannerState)
        /// "Back online · 3 captures sent".
        case backOnline(sent: Int)
        /// "Demo vault: not your data".
        case demo
    }

    /// How long a state lasts before the bar shows it, so a quick reconnect never flashes it.
    public static let delay: Duration = .seconds(2)
    /// How long "Back online" stays.
    public static let backOnlineDuration: Duration = .seconds(3)

    public private(set) var shown: Item?
    /// When `tick` has something to do: a pending state's 2 s, or "Back online"'s 3 s.
    public private(set) var deadline: ContinuousClock.Instant?
    /// What the latest state asks for, and since when.
    private var wanted: Item?
    private var wantedSince: ContinuousClock.Instant?
    /// The bar said the Mac couldn't be reached, so connecting again is "Back online".
    private var away = false
    /// Captures sent since the Mac went away.
    private var sent = 0
    private var backOnlineUntil: ContinuousClock.Instant?

    public init() {}

    /// The app's state changed. The demo shows at once and stays.
    public mutating func update(_ banner: BannerState, isDemo: Bool, at now: ContinuousClock.Instant) {
        let item: Item? = if isDemo {
            .demo
        } else if case .connected = banner {
            nil
        } else {
            .state(banner)
        }
        if item == .demo {
            wanted = item
            show(item, at: now)
            return
        }
        if Self.sameKind(item, shown) {
            // Same state, new numbers ("3 waiting" to "4 waiting"): no wait. Anything pending is off.
            wanted = item
            wantedSince = nil
            if item != nil { shown = item }
            schedule()
            return
        }
        if item == nil, !away {
            // Connected after "Connecting…", pairing or Pair Again: the bar goes at once. Only
            // "Back online" waits, in case the Mac drops again.
            wanted = nil
            wantedSince = nil
            show(nil, at: now)
            schedule()
            return
        }
        if !Self.sameKind(item, wanted) || wantedSince == nil {
            wantedSince = now
        }
        wanted = item
        schedule()
        tick(at: now)
    }

    /// Captures reached the Mac.
    public mutating func delivered(_ count: Int) {
        guard count > 0, away || isBackOnline else { return }
        sent += count
        if isBackOnline { shown = .backOnline(sent: sent) }
    }

    /// Time passed: a pending state shows once it has lasted 2 s, and "Back online" goes after 3 s.
    public mutating func tick(at now: ContinuousClock.Instant) {
        if let since = wantedSince, now >= since + Self.delay {
            wantedSince = nil
            show(wanted, at: now)
        }
        if let until = backOnlineUntil, now >= until, isBackOnline {
            backOnlineUntil = nil
            shown = nil
            sent = 0
        }
        schedule()
    }

    private var isBackOnline: Bool {
        if case .backOnline = shown { return true }
        return false
    }

    private mutating func show(_ item: Item?, at now: ContinuousClock.Instant) {
        switch item {
        case nil:
            if away {
                away = false
                shown = .backOnline(sent: sent)
                backOnlineUntil = now + Self.backOnlineDuration
            } else if !isBackOnline {
                shown = nil
            }
        case let .state(banner)?:
            switch banner {
            case .unreachable, .localNetworkOff, .failed:
                if !away { sent = 0 }
                away = true
            // Still away while it checks again.
            case .connecting: break
            case .notPaired, .revoked, .connected: away = false
            }
            backOnlineUntil = nil
            shown = item
        case .demo?, .backOnline?:
            away = false
            backOnlineUntil = nil
            shown = item
        }
    }

    private mutating func schedule() {
        let pending = wantedSince.map { $0 + Self.delay }
        deadline = [pending, backOnlineUntil].compactMap(\.self).min()
    }

    /// Two items are the same state, whatever their counts or names.
    static func sameKind(_ a: Item?, _ b: Item?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (.state(x)?, .state(y)?): x.kind == y.kind
        case (.backOnline?, .backOnline?), (.demo?, .demo?): true
        // "Back online" is the bar's way of showing nothing.
        case (nil, .backOnline?): true
        default: false
        }
    }
}

extension StatusBarTimeline.Item {
    /// The same state, whatever its counts: VoiceOver announces only a new one.
    public func isSameState(as other: Self?) -> Bool { StatusBarTimeline.sameKind(self, other) }
}

extension BannerState {
    /// The state without its counts and names.
    enum Kind: Equatable { case notPaired, connecting, connected, unreachable, localNetworkOff, revoked, failed }

    var kind: Kind {
        switch self {
        case .notPaired: .notPaired
        case .connecting: .connecting
        case .connected: .connected
        case .unreachable: .unreachable
        case .localNetworkOff: .localNetworkOff
        case .revoked: .revoked
        case .failed: .failed
        }
    }

    /// The captures waiting on this iPhone.
    public var waiting: Int {
        switch self {
        case let .notPaired(waiting), let .connecting(_, waiting), let .connected(_, _, waiting), let .unreachable(waiting),
             let .localNetworkOff(waiting), let .revoked(waiting), let .failed(_, waiting):
            waiting
        }
    }
}

/// The status bar's state for the app: `StatusBarTimeline` on the real clock. The app feeds it
/// the banner state and delivery outcomes; `item` is what the bar shows.
@MainActor @Observable
public final class StatusBar {
    public private(set) var item: StatusBarTimeline.Item?
    @ObservationIgnored private var timeline = StatusBarTimeline()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let clock = ContinuousClock()

    public init() {}

    public func update(_ banner: BannerState, isDemo: Bool) {
        timeline.update(banner, isDemo: isDemo, at: clock.now)
        apply()
    }

    public func delivered(_ outcome: DeliveryOutcome) {
        switch outcome {
        case let .drained(sent, _), let .failed(_, _, sent): timeline.delivered(sent)
        case .waiting, .notPaired, .revoked, .busy, .storage: break
        }
        apply()
    }

    private func apply() {
        if item != timeline.shown { item = timeline.shown }
        timer?.cancel()
        guard let deadline = timeline.deadline else { return }
        timer = Task { [weak self, clock] in
            try? await clock.sleep(until: deadline)
            guard !Task.isCancelled, let self else { return }
            self.timeline.tick(at: clock.now)
            self.apply()
        }
    }
}
