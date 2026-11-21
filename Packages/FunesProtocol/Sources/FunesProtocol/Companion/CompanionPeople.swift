import Foundation

// People & history on the iPhone (companion protocol §4.3, Phase 13 plan 13d.2, ADR-0032 amended 2026-11-20): the Mac's
// section read live, as data. The phone words kinds, bases, statuses and dates as the Mac does; the Mac sends worded only
// what the registry and 13d already word (attributes, why lines, correction labels). Every method needs the `people`
// capability.

/// `status.get`'s `people` (for a call with the `people` capability): whether the Mac's section has anything to show, and
/// the revision it reads at.
public struct PeopleStatus: Codable, Sendable, Equatable {
    /// False while the Mac's section shows its Facts-off empty state (*Learn from memories* off, nothing of yours kept).
    public var shown: Bool
    /// The revision People reads at; absent when `shown` is false or your names can't be read.
    public var factsRevision: String?

    public init(shown: Bool, factsRevision: String? = nil) {
        self.shown = shown
        self.factsRevision = factsRevision
    }
}

/// Why a `people.*` call sent nothing (`not_found`'s `reason`).
public enum PeopleUnavailable {
    /// The Mac's section shows its Facts-off empty state.
    public static let factsOff = "facts_off"
    /// The Mac can't read your names in About You, so it shows nothing (someone could be read as you).
    public static let namesUnavailable = "names_unavailable"
}

/// A date at the precision written, as day numbers (1 January of year 1 is day 1).
public struct PeopleDateRange: Codable, Sendable, Hashable {
    public enum Precision: String, Codable, Sendable {
        case year, month, day
        /// Derived bounds: an "ended by" limit, a succession, a hand-over, memories that disagree.
        case bound, inferred, handover, conflict
        /// A kind a newer Mac sends: read as derived.
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Precision(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var lo: Int
    public var hi: Int
    public var precision: Precision

    public init(lo: Int, hi: Int, precision: Precision) {
        self.lo = lo
        self.hi = hi
        self.precision = precision
    }

    /// The earliest and latest days the Mac's ranges use (`DateRange.minDay`, `maxDay`): an open end.
    public static let minDay = 1
    public static let maxDay = PeopleDay.number(year: 9999, month: 12, day: 31)
}

/// A fact's status as shown.
public enum PeopleFactStatus: String, Codable, Sendable {
    case current, former, unknown

    public init(from decoder: any Decoder) throws {
        self = PeopleFactStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// A fact's basis on an entity's page (04-ux-mac.md's table).
public enum PeopleBasis: String, Codable, Sendable {
    case confirmed, named, context, untrusted
    /// A basis a newer Mac sends: shown without words.
    case other

    public init(from decoder: any Decoder) throws {
        self = PeopleBasis(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

// MARK: people.directory

public enum PeopleDirectoryGet: CompanionCall {
    public static let method = CompanionMethod.peopleDirectory
    public typealias Params = EmptyParams
    public typealias Result = PeopleDirectoryResult
}

/// One row of People & names.
public struct PeopleEntry: Codable, Sendable, Equatable, Identifiable {
    public struct Group: Codable, Sendable, Equatable {
        /// The registry's attribute with the group's word ("your parents").
        public var attribute: String
        /// How many, when it's known and more than one.
        public var count: Int?

        public init(attribute: String, count: Int? = nil) {
            self.attribute = attribute
            self.count = count
        }
    }

    /// The fact about you in a few words.
    public struct Fact: Codable, Sendable, Equatable {
        /// "your sister", "where you worked", "your client".
        public var attribute: String
        public var status: PeopleFactStatus
        /// Only while the predicate's timeline use is on.
        public var since: PeopleDateRange?
        public var until: PeopleDateRange?
        /// Shown, not used in search.
        public var recordedOnly: Bool

        public init(attribute: String, status: PeopleFactStatus, since: PeopleDateRange? = nil, until: PeopleDateRange? = nil,
                    recordedOnly: Bool = false) {
            self.attribute = attribute
            self.status = status
            self.since = since
            self.until = until
            self.recordedOnly = recordedOnly
        }
    }

    public var id: String
    public var kind: String
    /// Nil for a role group (`group`), or an entry no memory names any more.
    public var name: String?
    public var group: Group?
    public var fact: Fact?
    /// How many memories mention it.
    public var mentions: Int
    public var aliases: [String]
    /// Something you made or corrected (tagged You).
    public var manual: Bool
    /// Hidden from the list (on the Mac); never in `people.directory`, readable by id.
    public var hidden: Bool
    public var deceased: Bool
    /// Nothing in your memories supports it any more: only what you typed or confirmed is kept.
    public var tombstone: Bool

    public init(id: String, kind: String, name: String? = nil, group: Group? = nil, fact: Fact? = nil, mentions: Int,
                aliases: [String] = [], manual: Bool = false, hidden: Bool = false, deceased: Bool = false, tombstone: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.group = group
        self.fact = fact
        self.mentions = mentions
        self.aliases = aliases
        self.manual = manual
        self.hidden = hidden
        self.deceased = deceased
        self.tombstone = tombstone
    }
}

/// Everything the Mac's section reads in one go: the list, your timeline and To check, at one revision.
public struct PeopleDirectoryResult: Codable, Sendable, Equatable {
    public struct Reading: Codable, Sendable, Equatable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    public struct Section: Codable, Sendable, Equatable {
        public var predicate: String
        /// The registry's noun ("job").
        public var noun: String
        /// The predicate's timeline use is on. Off: only your own entries, with your dates, nothing derived.
        public var on: Bool
        /// Newest first.
        public var episodes: [PeopleEpisode]

        public init(predicate: String, noun: String, on: Bool, episodes: [PeopleEpisode]) {
            self.predicate = predicate
            self.noun = noun
            self.on = on
            self.episodes = episodes
        }
    }

    /// Hidden entries left out.
    public var entries: [PeopleEntry]
    /// The registry's kinds, for the Kind filter.
    public var kinds: [String]
    public var timeline: [Section]
    public var toCheck: [PeopleToCheckItem]
    /// *Learn from memories* is on.
    public var learning: Bool
    /// The first backfill, while it runs.
    public var reading: Reading?
    public var factsRevision: String

    public init(entries: [PeopleEntry], kinds: [String], timeline: [Section], toCheck: [PeopleToCheckItem], learning: Bool,
                reading: Reading? = nil, factsRevision: String) {
        self.entries = entries
        self.kinds = kinds
        self.timeline = timeline
        self.toCheck = toCheck
        self.learning = learning
        self.reading = reading
        self.factsRevision = factsRevision
    }
}

// MARK: people.get

public enum PeopleGet: CompanionCall {
    public static let method = CompanionMethod.peopleGet
    public typealias Params = PeopleGetParams
    public typealias Result = PeopleEntityResult
}

public struct PeopleGetParams: Codable, Sendable, Equatable {
    public var entityID: String

    public init(entityID: String) { self.entityID = entityID }

    enum CodingKeys: String, CodingKey {
        case entityID = "entityId"
    }

    public func validate() throws(CompanionError) {
        guard !entityID.isEmpty, entityID.count <= 200 else { throw CompanionError(.invalidInput, message: "Bad entityId") }
    }
}

/// An episode of a fact: on your timeline, and the dates of a fact on its entity's page.
public struct PeopleEpisode: Codable, Sendable, Equatable, Identifiable {
    public struct Title: Codable, Sendable, Equatable {
        public var title: String
        public var from: PeopleDateRange?

        public init(title: String, from: PeopleDateRange? = nil) {
            self.title = title
            self.from = from
        }
    }

    /// What came just before it: Funes can't tell, or a gap longer than the predicate allows.
    public struct Previous: Codable, Sendable, Equatable {
        public var cantTell: Bool?
        public var gapMonths: Int?

        public init(cantTell: Bool? = nil, gapMonths: Int? = nil) {
            self.cantTell = cantTell
            self.gapMonths = gapMonths
        }
    }

    public var id: String
    public var factID: String
    public var entityID: String
    public var name: String
    public var start: PeopleDateRange?
    public var end: PeopleDateRange?
    public var ongoing: Bool
    /// Stated as ended.
    public var former: Bool
    /// Ended by a later one: "probably former".
    public var inferredEnd: Bool
    public var conflictStart: Bool
    public var conflictEnd: Bool
    /// Only from text you didn't write.
    public var untrusted: Bool
    /// The slot qualifier as the registry writes it (`employee`, `self_employed`).
    public var kind: String?
    public var titles: [Title]
    /// How many memories state it.
    public var stating: Int
    public var previous: Previous?
    /// It rests only on your own entries.
    public var yours: Bool
    /// You set its dates.
    public var yourDates: Bool

    public init(id: String, factID: String, entityID: String, name: String, start: PeopleDateRange? = nil, end: PeopleDateRange? = nil,
                ongoing: Bool = false, former: Bool = false, inferredEnd: Bool = false, conflictStart: Bool = false,
                conflictEnd: Bool = false, untrusted: Bool = false, kind: String? = nil, titles: [Title] = [], stating: Int = 0,
                previous: Previous? = nil, yours: Bool = false, yourDates: Bool = false) {
        self.id = id
        self.factID = factID
        self.entityID = entityID
        self.name = name
        self.start = start
        self.end = end
        self.ongoing = ongoing
        self.former = former
        self.inferredEnd = inferredEnd
        self.conflictStart = conflictStart
        self.conflictEnd = conflictEnd
        self.untrusted = untrusted
        self.kind = kind
        self.titles = titles
        self.stating = stating
        self.previous = previous
        self.yours = yours
        self.yourDates = yourDates
    }

    enum CodingKeys: String, CodingKey {
        case id, name, start, end, ongoing, former, inferredEnd, conflictStart, conflictEnd, untrusted, kind, titles, stating,
             previous, yours, yourDates
        case factID = "factId"
        case entityID = "entityId"
    }
}

/// A fact about you on an entity's page.
public struct PeopleFact: Codable, Sendable, Equatable, Identifiable {
    public var id: String { factID }
    public var factID: String
    public var predicate: String
    /// The registry's attribute with your word: "your sister".
    public var attribute: String
    public var label: String?
    public var status: PeopleFactStatus
    public var basis: PeopleBasis
    /// Shown, not used in search: "recorded only, not used in search", with Remove.
    public var recordedOnly: Bool
    /// The predicate is on the timeline (dates apply).
    public var dated: Bool
    public var episodes: [PeopleEpisode]
    /// **Not this** (**Remove** when recorded only): the fact everywhere.
    public var notThis: FactsCorrectionTarget?

    public init(factID: String, predicate: String, attribute: String, label: String? = nil, status: PeopleFactStatus,
                basis: PeopleBasis, recordedOnly: Bool = false, dated: Bool = false, episodes: [PeopleEpisode] = [],
                notThis: FactsCorrectionTarget? = nil) {
        self.factID = factID
        self.predicate = predicate
        self.attribute = attribute
        self.label = label
        self.status = status
        self.basis = basis
        self.recordedOnly = recordedOnly
        self.dated = dated
        self.episodes = episodes
        self.notThis = notThis
    }

    enum CodingKeys: String, CodingKey {
        case predicate, attribute, label, status, basis, recordedOnly, dated, episodes, notThis
        case factID = "factId"
    }
}

/// A memory that mentions the entity.
public struct PeopleMemoryRow: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { memoryID }
    public var memoryID: UUID
    public var title: String
    public var updatedAt: Date
    /// Why it's linked, as the Mac words it; nil when the memory simply names it.
    public var why: String?
    public var untrusted: Bool
    /// **Not <name>**: this memory isn't about them.
    public var notName: FactsCorrectionTarget?

    public init(memoryID: UUID, title: String, updatedAt: Date, why: String? = nil, untrusted: Bool = false,
                notName: FactsCorrectionTarget? = nil) {
        self.memoryID = memoryID
        self.title = title
        self.updatedAt = updatedAt
        self.why = why
        self.untrusted = untrusted
        self.notName = notName
    }

    enum CodingKeys: String, CodingKey {
        case title, updatedAt, why, untrusted, notName
        case memoryID = "memoryId"
    }
}

public struct PeopleEntityResult: Codable, Sendable, Equatable {
    public struct Alias: Codable, Sendable, Equatable {
        public var alias: String
        public var memories: Int
        /// You typed or confirmed it.
        public var yours: Bool

        public init(alias: String, memories: Int, yours: Bool = false) {
            self.alias = alias
            self.memories = memories
            self.yours = yours
        }
    }

    public var entry: PeopleEntry
    public var aliases: [Alias]
    public var facts: [PeopleFact]
    public var memories: [PeopleMemoryRow]
    public var factsRevision: String

    public init(entry: PeopleEntry, aliases: [Alias], facts: [PeopleFact], memories: [PeopleMemoryRow], factsRevision: String) {
        self.entry = entry
        self.aliases = aliases
        self.facts = facts
        self.memories = memories
        self.factsRevision = factsRevision
    }
}

// MARK: To check

/// One open question. Exactly one of `link`, `merge` and `episode`; none for a kind this phone doesn't know (skipped).
public struct PeopleToCheckItem: Codable, Sendable, Equatable, Identifiable {
    /// "Who is “my boss” in *Budget review*?"
    public struct Link: Codable, Sendable, Equatable {
        public var memoryID: UUID
        public var memoryTitle: String
        public var surface: String
        /// A role phrase (else a name two people share).
        public var role: Bool
        public var candidates: [String]

        public init(memoryID: UUID, memoryTitle: String, surface: String, role: Bool, candidates: [String]) {
            self.memoryID = memoryID
            self.memoryTitle = memoryTitle
            self.surface = surface
            self.role = role
            self.candidates = candidates
        }

        enum CodingKeys: String, CodingKey {
            case memoryTitle, surface, role, candidates
            case memoryID = "memoryId"
        }
    }

    /// "Are Maria and María López the same?"
    public struct Merge: Codable, Sendable, Equatable {
        public var names: [String]

        public init(names: [String]) { self.names = names }
    }

    /// "Which Acme job did you mean?"
    public struct Episode: Codable, Sendable, Equatable {
        public var name: String
        public var noun: String
        /// The episodes it could mean now (none: it matches none).
        public var choices: [PeopleDateRange]

        public init(name: String, noun: String, choices: [PeopleDateRange]) {
            self.name = name
            self.noun = noun
            self.choices = choices
        }
    }

    public var id: String
    public var link: Link?
    public var merge: Merge?
    public var episode: Episode?

    public init(id: String, link: Link? = nil, merge: Merge? = nil, episode: Episode? = nil) {
        self.id = id
        self.link = link
        self.merge = merge
        self.episode = episode
    }
}

// MARK: The filter

/// The list's name and kind filter, the Mac's search field and Kind menu (FunesCore's `PeopleDirectory.filtered`) and the
/// phone's: names and aliases, case and accents ignored; any of `kinds` (none: every kind); hidden only with `showHidden`.
public enum PeopleFilter {
    public static func matches(name: String, aliases: [String], kind: String, hidden: Bool, query: String, kinds: Set<String>,
                               showHidden: Bool) -> Bool {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        return (showHidden || !hidden)
            && (kinds.isEmpty || kinds.contains(kind))
            && (q.isEmpty || ([name] + aliases).contains { fold($0).contains(q) })
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}

extension PeopleEntry {
    /// The name a row shows before wording: its name, else its group's attribute.
    public var listName: String { name ?? group?.attribute ?? "" }

    public func matches(query: String, kinds: Set<String>) -> Bool {
        PeopleFilter.matches(name: listName, aliases: aliases, kind: kind, hidden: hidden, query: query, kinds: kinds, showHidden: false)
    }
}

// MARK: Days

/// Day numbers as civil dates (proleptic Gregorian; day 1 is 1 January of year 1, as Python's `date.toordinal`), shared
/// by the Mac's People words and the phone's: Foundation's calendar turns Julian before 1582, so it can't count from
/// year 1. Howard Hinnant's days_from_civil and civil_from_days.
public enum PeopleDay {
    public static func number(year y: Int, month m: Int, day d: Int) -> Int {
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468 + 719_163
    }

    public static func civil(_ day: Int) -> DateComponents {
        let z = day - 719_163 + 719_468                  // days since 0000-03-01
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        var c = DateComponents()
        c.day = doy - (153 * mp + 2) / 5 + 1
        c.month = mp < 10 ? mp + 3 : mp - 9
        c.year = yoe + era * 400 + (c.month! <= 2 ? 1 : 0)
        return c
    }
}
