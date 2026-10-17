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
        /// The text the agent would get, in full; the panel shows `PanelText.preview` of it with
        /// **Show all** when that's shorter.
        public var detail: String?
        /// Changes when the content changes (a memory's version): a refreshed row with the same id
        /// and version keeps the user's tick.
        public var version: String?
        /// "Low", "Sensitive"…
        public var badge: String?
        /// Badges at or above a level the app considers sensitive are drawn in orange.
        public var badgeIsWarning: Bool
        public var selectable: Bool
        public var selected: Bool

        public init(id: String, title: String, detail: String? = nil, version: String? = nil, badge: String? = nil,
                    badgeIsWarning: Bool = false, selectable: Bool = true, selected: Bool = true) {
            self.id = id
            self.title = title
            self.detail = detail
            self.version = version
            self.badge = badge
            self.badgeIsWarning = badgeIsWarning
            self.selectable = selectable
            self.selected = selected
        }

        /// Whether the panel shows less than the whole text until **Show all**.
        public var isClipped: Bool { detail.map { PanelText.preview($0) != $0 } ?? false }

        /// What the user approves when ticking this row; a change re-arms the buttons.
        var content: [String?] { [id, version, title, detail, badge] }
    }

    /// A label and value under the rows: "Purpose (as reported)", "Retention"…
    public struct Fact: Sendable, Equatable {
        public let label: String
        public let value: String
        /// Long values (an agent's keywords) preview to `PanelText.factLines` with Show all.
        public let collapsible: Bool

        public init(label: String, value: String, collapsible: Bool = false) {
            self.label = label
            self.value = value
            self.collapsible = collapsible
        }

        public var isClipped: Bool { collapsible && PanelText.preview(value, lines: PanelText.factLines,
                                                                      characters: PanelText.factCharacters) != value }
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

/// The preview a row shows before **Show all**: the first 3 lines, at most 160 characters, cut at a
/// word. Decided here rather than by clipping in the view, so the panel always knows whether text
/// is hidden and offers the full text (the user approves the exact text; 04-ux-mac.md).
public enum PanelText {
    public static let previewLines = 3
    public static let previewCharacters = 160
    /// A fact such as "Looking for": about two lines.
    public static let factLines = 2
    public static let factCharacters = 100

    public static func preview(_ text: String, lines previewLines: Int = previewLines,
                               characters previewCharacters: Int = previewCharacters) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = lines.prefix(previewLines).joined(separator: "\n")
        let cutLines = lines.count > previewLines
        guard cutLines || shown.count > previewCharacters else { return text }
        if shown.count > previewCharacters {
            shown = String(shown.prefix(previewCharacters))
            if let space = shown.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "," }),
               shown.distance(from: shown.startIndex, to: space) > previewCharacters / 2 {
                shown = String(shown[..<space])
            }
        }
        return shown.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
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

    /// Bumped when an item's approvable content changes, so the panel re-arms its buttons.
    public private(set) var generations = [UUID: Int]()
    /// Rows the user expanded with **Show all**, as "item|row".
    public private(set) var expanded = Set<String>()

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
    /// waiting is refreshed in place and keeps its first completion: rows with the same id and
    /// content keep the user's tick, and if the content changed the buttons re-arm.
    public func enqueue(_ item: PanelItem, completion: @escaping (PanelAnswer) -> Void) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let old = items[index]
            var refreshed = item
            for rowIndex in refreshed.rows.indices {
                let row = refreshed.rows[rowIndex]
                if let previous = old.rows.first(where: { $0.id == row.id }), previous.content == row.content {
                    refreshed.rows[rowIndex].selected = previous.selected
                } else {
                    expanded.remove(key(item.id, row.id))
                }
            }
            if old.rows.map(\.content) != refreshed.rows.map(\.content) {
                generations[item.id, default: 0] += 1
            }
            items[index] = refreshed
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
        generations[id] = nil
        expanded = expanded.filter { !$0.hasPrefix(id.uuidString + "|") }
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

    public func generation(of id: UUID) -> Int { generations[id, default: 0] }

    public func isExpanded(row: String, in id: UUID) -> Bool { expanded.contains(key(id, row)) }

    public func toggleExpanded(row: String, in id: UUID) {
        let key = key(id, row)
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    /// A fact's value now: its preview, or all of it after **Show all**.
    public func displayedValue(_ fact: PanelItem.Fact, in id: UUID) -> String {
        guard fact.collapsible, !isExpanded(row: "fact:" + fact.label, in: id) else { return fact.value }
        return PanelText.preview(fact.value, lines: PanelText.factLines, characters: PanelText.factCharacters)
    }

    /// The text the panel shows for a row now: the preview, or everything after **Show all**.
    public func displayedDetail(_ row: PanelItem.Row, in id: UUID) -> String? {
        guard let detail = row.detail else { return nil }
        return isExpanded(row: row.id, in: id) ? detail : PanelText.preview(detail)
    }

    private func key(_ id: UUID, _ row: String) -> String { id.uuidString + "|" + row }

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

extension PanelItem {
    /// The **Share with <agent>?** panel (04-ux-mac.md): the task, what the agent says it's looking
    /// for (its keywords), purpose as reported, retention and processors above the memories, then
    /// the withheld line. Agent-provided text is labelled as such; nothing here decides anything.
    public static func share(id: UUID, agentID: String, agentName: String, task: String?, keywords: [String],
                             purpose: String?, keepsIt: String, sharedWith: [String], rows: [Row], note: String?,
                             expiresAt: Date?) -> PanelItem {
        var facts = [Fact]()
        let lookingFor = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !lookingFor.isEmpty {
            facts.append(Fact(label: String(localized: "Looking for"), value: lookingFor.joined(separator: ", "),
                              collapsible: true))
        }
        if let purpose, !purpose.isEmpty {
            facts.append(Fact(label: String(localized: "Purpose"), value: String(localized: "“\(purpose)” (as reported)")))
        }
        facts.append(Fact(label: String(localized: "Keeps it"), value: keepsIt))
        if !sharedWith.isEmpty {
            facts.append(Fact(label: String(localized: "Shared with"), value: sharedWith.joined(separator: ", ")))
        }
        return PanelItem(
            id: id, kind: .share, agentID: agentID,
            title: String(localized: "\(agentName) wants to use your memories"),
            subtitle: task.map { String(localized: "Task: “\($0)”") }, rows: rows, facts: facts, note: note,
            primary: String(localized: "Share"), secondary: String(localized: "Deny"), expiresAt: expiresAt,
            announcement: String(localized: "\(agentName) asks to use \(rows.count) memories in Funes"))
    }
}

