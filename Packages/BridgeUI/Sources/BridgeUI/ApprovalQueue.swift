import Foundation
import Observation

// Adapted from EK Bridge's ApprovalCenter (Upstream/ApprovalCenter.swift): the same FIFO,
// selection, timeouts and exactly-once answers, over a generic panel item instead of
// EK Bridge's change summaries. The app builds each item from fresh data, never from
// agent prose.

/// What a panel shows for one request. Built by the app; shown, never stored.
public struct PanelItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Share memories: checkbox rows, a countdown, Share N / Deny.
        case share
        /// Save a suggested memory: no countdown, non-blocking.
        case save
    }

    /// A row the user can tick (or just read, when `selectable` is false).
    public struct Row: Identifiable, Sendable, Equatable {
        public let id: String
        public var title: String
        /// A preview of the text the agent would get.
        public var detail: String?
        /// "Low", "Sensitive"…
        public var badge: String?
        /// Badges at or above a level the app considers sensitive are drawn in orange.
        public var badgeIsWarning: Bool
        public var selectable: Bool
        public var selected: Bool

        public init(id: String, title: String, detail: String? = nil, badge: String? = nil,
                    badgeIsWarning: Bool = false, selectable: Bool = true, selected: Bool = true) {
            self.id = id
            self.title = title
            self.detail = detail
            self.badge = badge
            self.badgeIsWarning = badgeIsWarning
            self.selectable = selectable
            self.selected = selected
        }
    }

    /// A label and value under the rows: "Purpose (as reported)", "Retention"…
    public struct Fact: Sendable, Equatable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public let id: UUID
    public var kind: Kind
    /// Who asked; limits and "1 of 3" are per agent.
    public var agentID: String
    /// "Claude Code wants to use your memories".
    public var title: String
    public var subtitle: String?
    public var rows: [Row]
    public var facts: [Fact]
    /// A line in secondary text under the facts ("2 more weren't offered: …").
    public var note: String?
    /// "Share" (the count of ticked rows is added) or "Save".
    public var primary: String
    /// "Deny" or "Later".
    public var secondary: String
    /// "Reject" for a suggestion.
    public var tertiary: String?
    /// The panel answers `.expired` at this time; nil for no countdown.
    public var expiresAt: Date?
    /// Read by VoiceOver when the item appears.
    public var announcement: String

    public init(id: UUID, kind: Kind, agentID: String, title: String, subtitle: String? = nil, rows: [Row],
                facts: [Fact] = [], note: String? = nil, primary: String, secondary: String, tertiary: String? = nil,
                expiresAt: Date? = nil, announcement: String) {
        self.id = id
        self.kind = kind
        self.agentID = agentID
        self.title = title
        self.subtitle = subtitle
        self.rows = rows
        self.facts = facts
        self.note = note
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.expiresAt = expiresAt
        self.announcement = announcement
    }

    public var selectedIDs: [String] { rows.filter { $0.selectable && $0.selected }.map(\.id) }
}

public enum PanelAnswer: Sendable, Equatable {
    /// Share or Save, with the ticked rows.
    case primary(selected: [String])
    /// Deny or Later.
    case secondary
    /// Reject.
    case tertiary
    /// The countdown ran out.
    case expired
    /// The app took it back (the agent hung up, Funes paused, quit).
    case withdrawn
}

/// A FIFO of items waiting for the user, shown one at a time in one panel ("1 of 3"), each
/// answered exactly once.
@MainActor @Observable
public final class ApprovalQueue {
    /// Panels a user can step through; later items wait unseen until one is answered.
    public static let maxShown = 3

    public private(set) var items = [PanelItem]()
    /// Index of the item the panel shows, within `shown`.
    public var selection = 0
    /// Ticks once a second while an item counts down, so the panel redraws.
    public private(set) var now = Date()

    @ObservationIgnored private var completions = [UUID: (PanelAnswer) -> Void]()
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var timer: Timer?
    /// Called whenever the queue changes, so the app can show or hide the panel.
    @ObservationIgnored public var queueChanged: () -> Void = {}

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        now = clock()
    }

    public var shown: [PanelItem] { Array(items.prefix(Self.maxShown)) }

    public var current: PanelItem? {
        let visible = shown
        guard !visible.isEmpty else { return nil }
        return visible[min(max(selection, 0), visible.count - 1)]
    }

    /// Adds an item; `completion` runs once, on the main actor. An item whose id is already
    /// waiting replaces it on screen and keeps its first completion.
    public func enqueue(_ item: PanelItem, completion: @escaping (PanelAnswer) -> Void) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            completions[item.id] = completion
        }
        tick()
        queueChanged()
    }

    /// Records the user's answer (or an expiry, or a withdrawal) and removes the item.
    public func answer(_ id: UUID, _ answer: PanelAnswer) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        if selection >= shown.count { selection = max(0, shown.count - 1) }
        let completion = completions.removeValue(forKey: id)
        tick()
        queueChanged()
        completion?(answer)
    }

    public func withdraw(_ id: UUID) { answer(id, .withdrawn) }

    /// Withdraws everything (quit, Funes paused).
    public func withdrawAll() {
        for item in items { answer(item.id, .withdrawn) }
    }

    public func toggle(row: String, in id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let rowIndex = items[index].rows.firstIndex(where: { $0.id == row && $0.selectable }) else { return }
        items[index].rows[rowIndex].selected.toggle()
    }

    /// Seconds left on an item's countdown, never negative.
    public func remaining(_ item: PanelItem) -> Int? {
        item.expiresAt.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
    }

    /// Expires what ran out and keeps a one-second timer while anything counts down.
    public func tick() {
        now = clock()
        for item in items where item.expiresAt.map({ $0 <= now }) == true {
            answer(item.id, .expired)
            return
        }
        let counting = items.contains { $0.expiresAt != nil }
        if counting, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !counting {
            timer?.invalidate()
            timer = nil
        }
    }
}
