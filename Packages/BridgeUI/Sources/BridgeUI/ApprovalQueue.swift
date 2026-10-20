import Foundation
import Observation

// Adapted from EK Bridge's ApprovalCenter (Upstream/ApprovalCenter.swift): the same selection,
// timeouts and exactly-once answers, over a generic panel item instead of EK Bridge's change
// summaries, with items on a clock shown first. The app builds each item from fresh data, never
// from agent prose.

/// What a panel shows for one request. Built by the app; shown, never stored.
public struct PanelItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Share memories: checkbox rows, a countdown, Share N / Deny.
        case share
        /// Save a suggested memory: no countdown, non-blocking.
        case save
        /// "<Agent> wants to read <Category>": Not Now, **Allow Once** (tertiary, the default) and
        /// Always Allow (primary, a link on its own line, never the default).
        case access
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
        /// A weaker match: offered unticked under "Also matched" (access policy §3.2).
        public var weak: Bool

        public init(id: String, title: String, detail: String? = nil, version: String? = nil, badge: String? = nil,
                    badgeIsWarning: Bool = false, selectable: Bool = true, selected: Bool = true, weak: Bool = false) {
            self.id = id
            self.title = title
            self.detail = detail
            self.version = version
            self.badge = badge
            self.badgeIsWarning = badgeIsWarning
            self.selectable = selectable
            self.selected = selected
            self.weak = weak
        }

        /// Whether the panel shows less than the whole text until **Show all**.
        public var isClipped: Bool { detail.map { PanelText.preview($0) != $0 } ?? false }

        /// What the user approves when ticking this row; a change re-arms the buttons.
        var content: [String?] { [id, version, title, detail, badge] }
    }

    /// Where shared text goes, built only from what Funes knows (the agent, local or remote, the
    /// tunnel, the cloud app's vendor): "Claude Code on this Mac. It may send what it reads to its AI
    /// service."
    public struct Destination: Sendable, Equatable {
        public let text: String
        /// Drawn with the Cloud chip: the text leaves this Mac for someone else's servers.
        public let isCloud: Bool

        public init(text: String, isCloud: Bool) {
            self.text = text
            self.isCloud = isCloud
        }
    }

    /// A label and value: "Kind", "Your note"; or, in `agentSays`, "Task", "Purpose"…
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
    /// Who asked.
    public var agentID: String
    /// "Claude Code wants 3 memories".
    public var title: String
    /// "Cursor · access": the item's chip when several wait.
    public var shortLabel: String
    public var subtitle: String?
    /// Share: where the text goes. Shown first, as Funes's own words.
    public var destination: Destination?
    /// What the agent said about its request (task, keywords, purpose, retention): shown in its own
    /// block, labelled as not checked by Funes (principle 4).
    public var agentSays: [Fact]
    public var rows: [Row]
    /// Facts Funes holds: the user's note on the agent, a suggestion's kind and category…
    public var facts: [Fact]
    /// A line in secondary text under the facts ("2 more weren't offered: …").
    public var note: String?
    /// "Share" (the count of ticked rows is added) or "Save".
    public var primary: String
    /// "Deny" or "Later".
    public var secondary: String
    /// "Reject" for a suggestion, "Allow Once" for an access request.
    public var tertiary: String?
    /// "Edit…" on the Save panel: opens the suggestion in the Inbox. Drawn as a link.
    public var edit: String?
    /// "More time" on a Share panel: moves the request to Pending requests now (`.deferred`).
    public var moreTime: String?
    /// The panel answers `.expired` at this time; nil for no countdown.
    public var expiresAt: Date?
    /// Read by VoiceOver when the item appears.
    public var announcement: String

    public init(id: UUID, kind: Kind, agentID: String, title: String, shortLabel: String? = nil, subtitle: String? = nil,
                destination: Destination? = nil, agentSays: [Fact] = [], rows: [Row], facts: [Fact] = [],
                note: String? = nil, primary: String, secondary: String, tertiary: String? = nil, edit: String? = nil,
                moreTime: String? = nil, expiresAt: Date? = nil, announcement: String) {
        self.id = id
        self.kind = kind
        self.agentID = agentID
        self.title = title
        self.shortLabel = shortLabel ?? title
        self.subtitle = subtitle
        self.destination = destination
        self.agentSays = agentSays
        self.rows = rows
        self.facts = facts
        self.note = note
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.edit = edit
        self.moreTime = moreTime
        self.expiresAt = expiresAt
        self.announcement = announcement
    }

    public var selectedIDs: [String] { rows.filter { $0.selectable && $0.selected }.map(\.id) }

    /// What Return answers once the panel is key, or nil for none. Never Always Allow: on an
    /// access request it's Allow Once, and when Allow Once isn't offered nothing is the default.
    public var defaultAnswer: PanelAnswer? {
        switch kind {
        case .share: selectedIDs.isEmpty ? nil : .primary(selected: selectedIDs)
        case .save: .primary(selected: selectedIDs)
        case .access: tertiary == nil ? nil : .tertiary
        }
    }
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
    /// Reject (or Discard), or Allow Once.
    case tertiary
    /// Edit… (the Save panel).
    case edit
    /// The countdown ran out.
    case expired
    /// More time: the user moved a request to Pending requests before its countdown ran out.
    case deferred
    /// The app took it back (the agent hung up, Funes paused, quit).
    case withdrawn
}

/// Items waiting for the user, shown one at a time in one panel with a chip for each, each
/// answered exactly once. Items on a clock come first, soonest first, so a Save panel (which waits
/// for nothing) never hides a request that is running out (UX review F3).
@MainActor @Observable
public final class ApprovalQueue {
    /// Panels a user can step through; later items wait unseen until one is answered.
    public static let maxShown = 3

    /// In arrival order; `ordered` and `shown` give the order the panel uses.
    public private(set) var items = [PanelItem]()
    /// The item the user chose (a chip, or acting on it); nil shows the most urgent.
    public private(set) var selectedID: UUID?
    /// Ticks once a second while an item counts down, so the panel redraws.
    public private(set) var now = Date()

    /// Bumped when an item's approvable content changes, so the panel re-arms its buttons.
    public private(set) var generations = [UUID: Int]()
    /// Rows the user expanded with **Show all**, as "item|row".
    public private(set) var expanded = Set<String>()
    /// Set by `close()`: the app is quitting, so nothing new is shown.
    public private(set) var isClosed = false

    @ObservationIgnored private var completions = [UUID: (PanelAnswer) -> Void]()
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var timer: Timer?
    /// Called whenever the queue changes, so the app can show or hide the panel.
    @ObservationIgnored public var queueChanged: () -> Void = {}

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        now = clock()
    }

    /// Items on a clock first, soonest deadline first; then the rest in arrival order.
    public var ordered: [PanelItem] {
        let timed = items.filter { $0.expiresAt != nil }.enumerated()
            .sorted { ($0.element.expiresAt!, $0.offset) < ($1.element.expiresAt!, $1.offset) }.map(\.element)
        return timed + items.filter { $0.expiresAt == nil }
    }

    public var shown: [PanelItem] { Array(ordered.prefix(Self.maxShown)) }

    /// Items beyond `shown`, waiting unseen.
    public var hiddenCount: Int { max(0, items.count - Self.maxShown) }

    public var current: PanelItem? {
        let visible = shown
        if let selectedID, let item = visible.first(where: { $0.id == selectedID }) { return item }
        return visible.first
    }

    /// Shows this item (its chip was clicked, or the user acted on it), so a more urgent arrival
    /// doesn't replace it under the cursor.
    public func select(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Adds an item; `completion` runs once, on the main actor. An item whose id is already
    /// waiting is refreshed in place and keeps its first completion: rows with the same id and
    /// content keep the user's tick, and if the content changed the buttons re-arm. Once the queue
    /// is closed, `completion` runs at once with `.withdrawn` and nothing is shown.
    public func enqueue(_ item: PanelItem, completion: @escaping (PanelAnswer) -> Void) {
        guard !isClosed else {
            completion(.withdrawn)
            return
        }
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
        if selectedID == id { selectedID = nil }
        let completion = completions.removeValue(forKey: id)
        generations[id] = nil
        expanded = expanded.filter { !$0.hasPrefix(id.uuidString + "|") }
        tick()
        queueChanged()
        completion?(answer)
    }

    public func withdraw(_ id: UUID) { answer(id, .withdrawn) }

    /// Withdraws everything (Funes paused, the server switched off). Later items still show.
    public func withdrawAll() {
        for item in items { answer(item.id, .withdrawn) }
    }

    /// The app is quitting: withdraws everything, and answers anything enqueued later `.withdrawn`
    /// at once, so a panel built after the quit began never shows and its caller never waits.
    /// On the main actor, like `enqueue`, so nothing slips in between.
    public func close() {
        isClosed = true
        withdrawAll()
    }

    public func toggle(row: String, in id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let rowIndex = items[index].rows.firstIndex(where: { $0.id == row && $0.selectable }) else { return }
        items[index].rows[rowIndex].selected.toggle()
        selectedID = id
    }

    public func generation(of id: UUID) -> Int { generations[id, default: 0] }

    public func isExpanded(row: String, in id: UUID) -> Bool { expanded.contains(key(id, row)) }

    public func toggleExpanded(row: String, in id: UUID) {
        let key = key(id, row)
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        if items.contains(where: { $0.id == id }) { selectedID = id }
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

    /// "41 s", or "9:05" from a minute up (a pending request's 15 minutes).
    public static func countdown(_ seconds: Int) -> String {
        seconds < 60 ? String(localized: "\(seconds) s") : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The countdown as VoiceOver reads it: "41 seconds left", "9 minutes 5 seconds left".
    public static func spokenCountdown(_ seconds: Int) -> String {
        guard seconds >= 60 else { return String(localized: "\(seconds) seconds left") }
        let minutes = seconds / 60, rest = seconds % 60
        return rest == 0 ? String(localized: "\(minutes) minutes left")
                         : String(localized: "\(minutes) minutes \(rest) seconds left")
    }

    /// Seconds left on an item's countdown, never negative.
    public func remaining(_ item: PanelItem) -> Int? {
        item.expiresAt.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
    }

    /// Expires what ran out and keeps a one-second timer while anything counts down.
    public func tick() {
        now = clock()
        for item in ordered where item.expiresAt.map({ $0 <= now }) == true {
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
    /// The **Share** panel (04-ux-mac.md): where the text goes, then what the agent said about its
    /// request in a block of its own (task, keywords, purpose, retention, processors), then the
    /// memories (strong matches ticked, weaker ones offered unticked), then the withheld line.
    /// Agent-provided text is labelled as such; nothing here decides anything.
    public static func share(id: UUID, agentID: String, agentName: String, destination: Destination?, task: String?,
                             keywords: [String], purpose: String?, keepsIt: String?, sharedWith: [String],
                             facts: [Fact] = [], rows: [Row], note: String?, expiresAt: Date?) -> PanelItem {
        var says = [Fact]()
        if let task, !task.isEmpty {
            says.append(Fact(label: String(localized: "Task"), value: "“\(task)”", collapsible: true))
        }
        let lookingFor = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !lookingFor.isEmpty {
            says.append(Fact(label: String(localized: "Looking for"), value: lookingFor.joined(separator: ", "),
                             collapsible: true))
        }
        if let purpose, !purpose.isEmpty {
            says.append(Fact(label: String(localized: "Purpose"), value: "“\(purpose)”"))
        }
        if let keepsIt { says.append(Fact(label: String(localized: "Keeps what it gets"), value: keepsIt)) }
        if !sharedWith.isEmpty {
            says.append(Fact(label: String(localized: "Shared with"), value: sharedWith.joined(separator: ", ")))
        }
        let count = rows.filter(\.selected).count
        return PanelItem(
            id: id, kind: .share, agentID: agentID,
            title: rows.count == 1 ? String(localized: "\(agentName) wants 1 memory")
                                   : String(localized: "\(agentName) wants \(rows.count) memories"),
            shortLabel: String(localized: "\(agentName) · share"), destination: destination, agentSays: says,
            rows: rows, facts: facts, note: note, primary: String(localized: "Share"), secondary: String(localized: "Deny"),
            moreTime: expiresAt == nil ? nil : String(localized: "More Time"), expiresAt: expiresAt,
            announcement: count == rows.count
                ? String(localized: "\(agentName) asks to use \(rows.count) memories in Funes")
                : String(localized: "\(agentName) asks to use your memories in Funes: \(count) of \(rows.count) ticked"))
    }
}
