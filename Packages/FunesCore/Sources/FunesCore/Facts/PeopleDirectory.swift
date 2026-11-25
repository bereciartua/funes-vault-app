import Foundation
import FunesProtocol
import GRDB

/// Vault ▸ People & history as data (04-ux-mac.md, FR-F-07; owner side only, nothing here is sent anywhere): the
/// entities memories mention, by how many memories mention them, the facts about you with their basis, your timeline,
/// and To check. Built in one read from `FactStore.load` with the uses search would use (shipped records and the
/// off-switches, for each call group's current engine), whether or not *Use in search and answers* is on:
/// - a predicate whose *recorded* is off shows only your own entries (`load` hides the rest, §11.10);
/// - *linked* off (a recorded-only predicate, like client): its facts are shown as recorded only, its role phrases link
///   nothing and aren't in To check;
/// - *timeline* off: your timeline lists only your own entries for that predicate, with your dates and no derived
///   basis, order or gap.
public struct PeopleDirectory: Sendable {
    public var entries: [Entry]
    public var toCheck: [ToCheckItem]
    /// Your answers in To check that name no one (Skip, Someone Else), each with Undo.
    public var answered: [Answered]
    public var timeline: [TimelineSection]
    public var summary: Summary
    /// The registry's kinds, for the Kind filter.
    public var kinds: [String]

    public var isEmpty: Bool { entries.isEmpty && timeline.allSatisfy { $0.episodes.isEmpty } }

    /// The list as filtered (the Mac's search field and Kind menu, and the phone's `people.list`): names and aliases,
    /// case and accents ignored; any of `kinds` (none: every kind); hidden entries only with `showHidden`.
    public func filtered(query: String, kinds: Set<String>, showHidden: Bool) -> [Entry] {
        entries.filter { e in
            PeopleFilter.matches(name: e.name ?? e.group?.attribute ?? "", aliases: e.aliases, kind: e.kind, hidden: e.hidden,
                                 query: query, kinds: kinds, showHidden: showHidden)
        }
    }

    /// One row of People & names.
    public struct Entry: Sendable, Identifiable, Hashable {
        public var id: String
        public var kind: String
        /// Its name; nil for a role group, which reads as `group`.
        public var name: String?
        /// A role group until its members are named: the registry's attribute with the group's word ("your parents"),
        /// and how many when it's known.
        public var group: Group?
        /// The fact about you in a few words ("your sister", "where you worked", "your client").
        public var fact: FactLine?
        /// How many memories mention it (names, role phrases of linked predicates, statements).
        public var mentions: Int
        public var aliases: [String]
        public var hidden: Bool
        /// Something you made or confirmed (tagged You).
        public var manual: Bool
        public var deceased: Bool
        /// Nothing in your memories supports it any more: only what you typed or confirmed is kept.
        public var tombstone: Bool

        public struct Group: Sendable, Hashable {
            public var attribute: String
            public var count: Int?
        }
    }

    /// A fact in a few words, for a list row.
    public struct FactLine: Sendable, Hashable {
        public var attribute: String
        public var status: FactAssertion.Status
        /// Only while the predicate's timeline is on: "until 2021", "since 2021".
        public var since: DateRange?
        public var until: DateRange?
        /// *Recorded* only: shown, not used in search.
        public var recordedOnly: Bool
    }

    /// The counts after the first backfill: "Funes found 23 people, 9 employers and 41 other names."
    public struct Summary: Sendable, Hashable {
        public var people = 0
        /// Entities holding a fact of a predicate that declares the timeline (where you've worked, in v0.10), while that
        /// predicate is recorded.
        public var employers = 0
        public var others = 0
    }

    // MARK: Timeline

    public struct TimelineSection: Sendable, Hashable {
        public var predicate: String
        /// The registry's noun ("job").
        public var noun: String
        /// The predicate's timeline use is on: Funes orders and dates it. Off: only your own entries, with your dates.
        public var on: Bool
        /// Newest first.
        public var episodes: [TimelineEpisode]
    }

    public struct TimelineEpisode: Sendable, Hashable, Identifiable {
        public var id: String { factID + "|" + String(start?.lo ?? 0) + "|" + String(end?.hi ?? 0) + "|" + String(index) }
        public var index: Int
        public var factID: String
        public var entity: String
        public var name: String
        public var start: DateRange?
        public var end: DateRange?
        public var ongoing: Bool
        /// Stated as ended.
        public var former: Bool
        /// Ended by a later one (succession): "probably former".
        public var inferredEnd: Bool
        /// Two memories disagree on its start or end.
        public var conflictStart: Bool
        public var conflictEnd: Bool
        /// Only from text you didn't write.
        public var untrusted: Bool
        /// The slot qualifier's value, as the registry writes it (employee, self_employed).
        public var kind: String?
        /// Title history in the order it was written: each title with when it was first given, if dated.
        public var titles: [Title]
        /// Memories that state it, newest first.
        public var stating: [UUID]
        /// What came just before it, as the timeline answers it (timeline on only).
        public var previous: Previous?
        /// Its date range when you act on it (an episode selector, memory processing §11.8).
        public var selector: DateRange?
        /// You set its dates.
        public var yourDates: Bool
        /// It rests only on your own entries.
        public var yours: Bool
        /// Every episode selector your rows on it used (Clear Dates takes back all of them).
        public var yourSelectors: [DateRange?] = []
        /// A stated rename's row: the same predicate's facts on its other names (Remove from Timeline takes them too).
        public var renamedFactIDs: [String] = []

        public struct Title: Sendable, Hashable {
            public var title: String
            public var from: DateRange?
        }

        public enum Previous: Sendable, Hashable {
            /// Funes can't tell which came first.
            case cantTell
            /// A gap longer than the predicate allows, in months.
            case gap(months: Int)
        }
    }

    // MARK: To check

    public enum ToCheckItem: Sendable, Hashable, Identifiable {
        /// A role phrase or a name Funes couldn't settle: "Who is “my boss” in *Budget review*?"
        case link(UnsettledLink)
        /// "Are Maria and María López the same person?"
        case merge(entity: String, other: String, names: [String])
        /// One of your dates, statuses or orders that no longer matches exactly one episode.
        case episode(LostEpisode)

        public var id: String {
            switch self {
            case let .link(l): "link|" + l.memoryID.uuidString + "|" + String(l.start)
            case let .merge(a, b, _): "merge|" + a + "|" + b
            case let .episode(e): "episode|" + e.rowID
            }
        }
    }

    public struct UnsettledLink: Sendable, Hashable {
        public var memoryID: UUID
        public var memoryTitle: String
        /// As the memory writes it ("my boss", "Maria").
        public var surface: String
        /// UTF-16 offset in title + "\n" + body.
        public var start: Int
        /// A role phrase (else a name two people share).
        public var role: Bool
        public var candidates: [Candidate]

        public struct Candidate: Sendable, Hashable {
            public var entity: String
            public var name: String
        }
    }

    /// A To check answer that names no one.
    public struct Answered: Sendable, Hashable, Identifiable {
        public var id: String { group }
        /// The action's stamp (Undo takes it back).
        public var group: String
        public var memoryTitle: String
        public var surface: String
        public var skipped: Bool
    }

    public struct LostEpisode: Sendable, Hashable {
        /// Your evidence row.
        public var rowID: String
        public var factID: String
        /// The order's other endpoint lost its episode (its fact's name and episodes are the ones shown).
        public var otherEndpoint: Bool
        public var name: String
        public var noun: String
        /// The episodes it could mean now (none: it matches none).
        public var choices: [DateRange]
    }
}

/// People & history for a phone (companion protocol §4.3): the directory and People's revision, from one read.
public struct PeoplePhoneDirectory: Sendable {
    public var directory: PeopleDirectory
    public var revision: String
}

/// An entity's page with its corrections as a phone's buttons (companion protocol §4.3): **Not <name>** per memory row,
/// **Not this** per fact, tokens minted with the page.
public struct PeoplePhonePage: Sendable {
    public var page: PeopleEntityPage
    /// People's revision, read with the page (`VaultStore.peopleRevision`).
    public var revision: String
    /// By memory id.
    public var notName: [UUID: FactsCorrection] = [:]
    /// By fact id.
    public var notThis: [String: FactsCorrection] = [:]
}

/// An entity's page in People & history.
public struct PeopleEntityPage: Sendable {
    public var entry: PeopleDirectory.Entry
    /// Each alias with how many memories use it; yours (typed or confirmed) are marked.
    public var aliases: [Alias]
    /// About you: each fact that involves it.
    public var facts: [Fact]
    /// Every memory that mentions it, most recently changed first.
    public var memories: [MemoryRow]
    /// What you changed here, newest first.
    public var corrections: [Correction]
    /// Entities of the same kind, for Merge With….
    public var mergeCandidates: [PeopleDirectory.Entry]

    public struct Alias: Sendable, Hashable {
        public var alias: String
        public var memories: Int
        public var yours: Bool
    }

    public struct Fact: Sendable, Hashable, Identifiable {
        public var id: String { factID }
        public var factID: String
        public var predicate: String
        /// The registry's attribute with your word: "your sister".
        public var attribute: String
        public var label: String?
        public var status: FactAssertion.Status
        public var basis: Basis
        /// *Recorded* only: "recorded only, not used in search", with Remove.
        public var recordedOnly: Bool
        /// Its episodes' dates (timeline on), or the dates you set (timeline off).
        public var episodes: [PeopleDirectory.TimelineEpisode]
        /// The predicate is on the timeline (dates, orders and former apply).
        public var dated: Bool

        /// A fact's basis in words (04-ux-mac.md's table).
        public enum Basis: String, Sendable, Hashable {
            case confirmed      // You said so
            case named          // Named in the memory
            case context        // From the memory's context (mentioned, not stated)
            case untrusted      // From an agent's or an import's text
        }
    }

    public struct MemoryRow: Sendable, Hashable, Identifiable {
        public var id: UUID { memoryID }
        public var memoryID: UUID
        public var title: String
        public var updatedAt: Date
        /// Why it's linked, as 13b words it; nil when the memory simply names it.
        public var whyLine: WhyLine?
        /// **Not <name>**: always offered.
        public var notName: WhyLine.NotName
        public var untrusted: Bool
    }

    public struct Correction: Sendable, Hashable, Identifiable {
        /// The action's stamp: Undo takes back every row it wrote.
        public var id: String
        public var what: What
        /// The memory it was made from, when it was.
        public var memoryTitle: String?
        public var createdAt: Date

        public enum What: Sendable, Hashable {
            case renamed(String)
            case kind(String)
            case deceased(Bool)
            case mergedFrom(String?)
            case mergedInto(String?)
            case notSame(String?)
            case label(attribute: String, label: String)
            case factRejected(attribute: String)
            case linkRejected
            case linkConfirmed
            case someoneElse
            case skipped
            case dates(attribute: String, start: String?, end: String?)
            case status(attribute: String, FactAssertion.Status)
            case order(attribute: String)
            case orderRejected
            case factAdded(attribute: String)
            case hidden(Bool)
            /// To check: a row of yours removed (or moved to another episode).
            case retired
            case alias(String)
            case other
        }
    }
}
