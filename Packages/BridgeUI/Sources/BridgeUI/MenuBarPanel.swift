import BridgeKitRemote
import Foundation

// The menu bar panel's models (written for Funes, ADR-0029): what waits for the user, and the
// Agents and Remote Access tiles. Plain values from the app's state, so the panel, Review
// Request and the tests read the same answer. Nothing here answers anything.

/// "Waiting for you": one card per item the user must answer, each request once (matched by
/// its id), at most 3 shown.
public struct WaitingItems: Equatable, Sendable {
    public static let maxShown = 3

    /// Where a card's **Review** goes. It only brings an item's own panel forward: the panel
    /// keeps its arming delay and keys, and answers it.
    public enum Route: Hashable, Sendable {
        /// An item of the approval panel: selected there, which comes forward, key.
        case queueItem(UUID)
        /// A cloud sign-in: its own panel comes forward.
        case signIn(UUID)
        /// A Pending request: reopened (and refreshed) in the approval panel.
        case pending(UUID)
    }

    /// The line under a card's title.
    public enum Time: Equatable, Sendable {
        /// A panel on a clock: "0:41 to answer".
        case answerBy(Date)
        /// A sign-in: "Until 10:52".
        case until(Date)
        /// A Pending request: "Still answerable · 12 min left".
        case stillAnswerable(Date)
        /// A Save: nothing.
        case none
    }

    public struct Card: Identifiable, Equatable, Sendable {
        public let route: Route
        public let title: String
        public let time: Time
        public var id: Route { route }
    }

    /// A Pending request the user can still share.
    public struct Pending: Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let expiresAt: Date
        public init(id: UUID, title: String, expiresAt: Date) {
            self.id = id
            self.title = title
            self.expiresAt = expiresAt
        }
    }

    /// Every card, in order: the approval panel's items in its order, the waiting sign-in (one at
    /// a time), then Pending requests not already a card, soonest expiry first.
    public let cards: [Card]
    /// What Review Request (⌃⌥⌘R) reviews: the approval panel's current item, else the soonest
    /// Pending request. The card it names shows the shortcut.
    public let reviewTarget: Route?

    /// - Parameters:
    ///   - queue: the approval panel's items as `ApprovalQueue.ordered` gives them.
    ///   - current: the item the approval panel shows (`ApprovalQueue.current`).
    ///   - signIns: waiting sign-ins, oldest first.
    ///   - pending: Pending requests that need an answer, in any order.
    public init(queue: [PanelItem], current: PanelItem?, signIns: [PairingRequest], pending: [Pending], now: Date) {
        var cards = queue.map { item in
            Card(route: .queueItem(item.id), title: item.cardTitle ?? item.title,
                 time: item.expiresAt.map(Time.answerBy) ?? .none)
        }
        if let signIn = signIns.first(where: { $0.expiresAt > now }) {
            cards.append(Card(route: .signIn(signIn.id), title: Self.signInTitle(signIn.appName), time: .until(signIn.expiresAt)))
        }
        let inQueue = Set(queue.map(\.id))
        let open = pending.filter { !inQueue.contains($0.id) && $0.expiresAt > now }.sorted { $0.expiresAt < $1.expiresAt }
        cards += open.map { Card(route: .pending($0.id), title: $0.title, time: .stillAnswerable($0.expiresAt)) }
        self.cards = cards
        reviewTarget = current.map { .queueItem($0.id) } ?? open.first.map { .pending($0.id) }
    }

    public var shown: [Card] { Array(cards.prefix(Self.maxShown)) }
    /// Cards beyond the first 3: "2 more waiting".
    public var hiddenCount: Int { max(0, cards.count - Self.maxShown) }
    /// Whether some of the hidden cards are Pending requests: the line offers Show All Pending Requests.
    public var hidesPending: Bool {
        cards.dropFirst(Self.maxShown).contains { if case .pending = $0.route { true } else { false } }
    }
    public var isEmpty: Bool { cards.isEmpty }

    /// "claude.ai wants to connect".
    public static func signInTitle(_ appName: String) -> String { String(localized: "\(appName) wants to connect") }

    /// A card's time, as it reads: "0:41 to answer", "Until 10:52", "Still answerable · 12 min left".
    public static func timeText(_ time: Time, now: Date) -> String? {
        switch time {
        case .answerBy(let deadline):
            let seconds = secondsLeft(deadline, now: now)
            return String(localized: "\(String(format: "%d:%02d", seconds / 60, seconds % 60)) to answer")
        case .until(let end):
            return String(localized: "Until \(end.formatted(date: .omitted, time: .shortened))")
        case .stillAnswerable(let end):
            return String(localized: "Still answerable · \(minutesLeft(end, now: now)) min left")
        case .none:
            return nil
        }
    }

    /// The same time as VoiceOver reads it: "41 seconds to answer", "12 minutes left".
    @MainActor public static func spokenTime(_ time: Time, now: Date) -> String? {
        switch time {
        case .answerBy(let deadline):
            let seconds = secondsLeft(deadline, now: now)
            guard seconds >= 60 else { return String(localized: "\(seconds) seconds to answer") }
            return ApprovalQueue.spokenCountdown(seconds)
        case .until, .none:
            return timeText(time, now: now)
        case .stillAnswerable(let end):
            return String(localized: "Still answerable, \(minutesLeft(end, now: now)) minutes left")
        }
    }

    static func secondsLeft(_ deadline: Date, now: Date) -> Int { max(0, Int(deadline.timeIntervalSince(now).rounded(.up))) }
    static func minutesLeft(_ end: Date, now: Date) -> Int { max(0, Int((end.timeIntervalSince(now) / 60).rounded(.up))) }
}

/// The Agents tile: the agent server's state, checked in the UX table's order (off in Settings,
/// can't connect, starting, paused, no agents yet, on). Only Paused and On have a switch.
public enum AgentsTile: Equatable, Sendable {
    case offInSettings
    /// The agent server failed: `port` when another app has it.
    case cantConnect(portInUse: Int?)
    case starting
    case paused(until: Date)
    case noAgents
    case on(agents: Int)

    /// The agent server as the app sees it.
    public enum Server: Equatable, Sendable {
        case off, starting, listening
        case failed(portInUse: Int?)
    }

    /// `pausedUntil` is `.distantFuture` for "until you resume".
    public init(serverEnabled: Bool, server: Server, pausedUntil: Date?, agents: Int) {
        if !serverEnabled {
            self = .offInSettings
        } else if case .failed(let port) = server {
            self = .cantConnect(portInUse: port)
        } else if server != .listening {
            self = .starting
        } else if let pausedUntil {
            self = .paused(until: pausedUntil)
        } else {
            self = agents == 0 ? .noAgents : .on(agents: agents)
        }
    }

    /// Whether the tile has a switch (on, or paused), rather than a button.
    public var hasSwitch: Bool {
        switch self {
        case .on, .paused: true
        default: false
        }
    }

    public var isOn: Bool { if case .on = self { true } else { false } }

    /// "On · 4 agents", "Paused until 14:00", "Port 47625 is in use".
    public func status(now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .offInSettings: String(localized: "Off · agents can't connect")
        case .cantConnect(let port?): String(localized: "Port \(String(port)) is in use")
        case .cantConnect(nil): String(localized: "The agent server stopped")
        case .starting: String(localized: "Starting…")
        case .paused(let until): Self.pausedText(until, now: now, calendar: calendar)
        case .noAgents: String(localized: "No agents yet")
        case .on(1): String(localized: "On · 1 agent")
        case .on(let count): String(localized: "On · \(count) agents")
        }
    }

    /// "Paused until 14:00", "Paused until tomorrow at 09:00", "Paused until you resume".
    public static func pausedText(_ until: Date, now: Date, calendar: Calendar = .current) -> String {
        if until == .distantFuture { return String(localized: "Paused until you resume") }
        let time = until.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(until, inSameDayAs: now) { return String(localized: "Paused until \(time)") }
        return String(localized: "Paused until tomorrow at \(time)")
    }
}

/// The Remote Access tile, checked in the UX table's order (not set up, off, not listening, tunnel
/// down, on). While it's on there's always a switch, whatever else is wrong.
public enum RemoteTile: Equatable, Sendable {
    case notSetUp
    case off
    case notListening
    case tunnelDown
    /// On: "told it's paused" while agents are paused, else "until 18:00" with an automatic
    /// turn-off, else the cloud agents.
    case on(cloudAgents: Int, until: Date?, agentsPaused: Bool)

    public var hasSwitch: Bool { self != .notSetUp }
    public var isOn: Bool { self != .notSetUp && self != .off }
    /// Drawn with the warning tint.
    public var isWarning: Bool { self == .notListening || self == .tunnelDown }

    public var status: String {
        switch self {
        case .notSetUp: String(localized: "Not set up")
        case .off: String(localized: "Off")
        case .notListening: String(localized: "On · not listening")
        case .tunnelDown: String(localized: "On · tunnel down")
        case .on(_, _, true): String(localized: "On · told it's paused")
        case .on(_, let until?, false): String(localized: "On · until \(until.formatted(date: .omitted, time: .shortened))")
        case .on(1, nil, false): String(localized: "On · 1 cloud agent")
        case .on(let count, nil, false): String(localized: "On · \(count) cloud agents")
        }
    }
}

extension RemoteAccessController {
    /// The Remote Access section shows its introduction: never set up, off, and not in the guide
    /// or a tunnel switch. The menu bar's tile says "Not set up" by the same rule.
    public var showsIntroduction: Bool { tunnelSwitch == nil && !guideActive && origin == nil && !enabled }

    /// The menu bar panel's tile. `agentServerUp`: the app's agent server is listening (Remote
    /// Access is a second door to it, so it can't answer while that's off or failed).
    public func tile(agentServerUp: Bool, agentsPaused: Bool) -> RemoteTile {
        if showsIntroduction { return .notSetUp }
        guard enabled else { return .off }
        let listening = switch status {
        case .listening, .starting: true
        case .off, .failed: false
        }
        guard agentServerUp, listening else { return .notListening }
        if tunnelDown { return .tunnelDown }
        return .on(cloudAgents: cloudAgents.count, until: offAt, agentsPaused: agentsPaused)
    }
}
