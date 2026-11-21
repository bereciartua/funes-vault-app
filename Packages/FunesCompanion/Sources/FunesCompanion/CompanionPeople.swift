import Foundation
import FunesCore
import FunesProtocol

/// What the companion needs from the Mac app to read People & history as the Mac's section does (companion protocol
/// §4.3): *Learn from memories*, and the People configuration (`AppModel.peopleConfig`: the uses search would use,
/// whether or not *Use in search and answers* is on; nil while your names can't be read).
public struct CompanionPeople: Sendable {
    public var learning: @Sendable () async -> Bool
    public var config: @Sendable () async -> FactsSearchConfig?
    /// People's role phrases for the phone, which hold memory text: the companion clears it whenever it finds People
    /// closed, and the app when Facts goes off on the Mac, whether or not a phone calls again.
    public let phrases: RolePhraseCache

    public init(learning: @escaping @Sendable () async -> Bool, config: @escaping @Sendable () async -> FactsSearchConfig?,
                phrases: RolePhraseCache = RolePhraseCache()) {
        self.learning = learning
        self.config = config
        self.phrases = phrases
    }
}

extension CompanionHandlers {
    /// People's state for one call: open with its configuration, or why it's closed. Read at every call, never cached.
    enum PeopleAccess {
        case open(FactsSearchConfig, learning: Bool)
        case closed(reason: String)
    }

    /// The phrase cache People reads with (empty without People).
    var phrases: RolePhraseCache { services.people?.phrases ?? RolePhraseCache() }

    func peopleAccess() async throws -> PeopleAccess {
        guard let source = services.people else { throw CompanionError(.unknownMethod) }
        // The configuration first (it awaits your names), *Learn from memories* last: nothing suspends between that and
        // the read that checks the gate again, so learning turned off meanwhile is never read as on.
        let config = await source.config()
        let learning = await source.learning()
        guard try services.store.peopleOpen(learning: learning) else {
            // Closed: no memory's text stays in the phrase cache.
            phrases.clear()
            return .closed(reason: PeopleUnavailable.factsOff)
        }
        guard let config else {
            phrases.clear()
            return .closed(reason: PeopleUnavailable.namesUnavailable)
        }
        return .open(config, learning: learning)
    }

    /// After a gated read: People must still be open, so a *Learn from memories* turned off between reading the switch on
    /// the main actor and the read never lets that read's data out.
    func stillOpen() async throws {
        guard let source = services.people else { return }
        let learning = await source.learning()
        guard try services.store.peopleOpen(learning: learning) else {
            phrases.clear()
            throw CompanionError(.notFound, reason: PeopleUnavailable.factsOff)
        }
    }

    /// The open configuration, or `not_found` with why (no data).
    func openPeople(showsPeople: Bool) async throws -> (FactsSearchConfig, Bool) {
        guard showsPeople else { throw CompanionError(.invalidInput, message: "Needs the people capability") }
        switch try await peopleAccess() {
        case let .open(config, learning): return (config, learning)
        case let .closed(reason): throw CompanionError(.notFound, reason: reason)
        }
    }

    /// `status.get`'s `people`, for a call with the `people` capability on a Mac that has People.
    func peopleStatus() async -> PeopleStatus? {
        guard services.people != nil else { return nil }
        switch try? await peopleAccess() {
        case let .open(config, learning)?:
            return PeopleStatus(shown: true, factsRevision: try? services.store.peopleRevision(config: config, learning: learning))
        case let .closed(reason)?:
            return PeopleStatus(shown: reason != PeopleUnavailable.factsOff)
        case nil:
            // The vault couldn't be read for a moment: People is still there; the phone reads it when it asks.
            return PeopleStatus(shown: true)
        }
    }

    /// `people.directory`: the list (hidden entries left out), your timeline and To check, in one read.
    func peopleDirectory(device: UUID, showsPeople: Bool, now: Date) async throws -> PeopleDirectoryResult {
        let (config, learning) = try await openPeople(showsPeople: showsPeople)
        let read: PeoplePhoneDirectory
        do {
            read = try services.store.peoplePhoneDirectory(config: config, learning: learning, phrases: phrases)
        } catch PeopleError.closed {
            phrases.clear()
            throw CompanionError(.notFound, reason: PeopleUnavailable.factsOff)
        }
        try await stillOpen()
        let d = read.directory
        let progress = try? services.store.factsBackfill()
        let reading = progress.flatMap { $0.state.isRunning ? PeopleDirectoryResult.Reading(done: $0.done, total: $0.total) : nil }
        let result = PeopleDirectoryResult(
            entries: d.filtered(query: "", kinds: [], showHidden: false).map(Self.entry),
            kinds: d.kinds,
            timeline: d.timeline.map { s in
                PeopleDirectoryResult.Section(predicate: s.predicate, noun: s.noun, on: s.on, episodes: s.episodes.map(Self.episode))
            },
            toCheck: d.toCheck.map(Self.toCheck),
            learning: learning, reading: reading, factsRevision: read.revision)
        logRead("people_listed", device: device, now: now,
                counts: ["entries": result.entries.count, "episodes": result.timeline.reduce(0) { $0 + $1.episodes.count },
                         "toCheck": result.toCheck.count])
        return result
    }

    /// `people.get`: an entity's page, with **Not <name>** per memory row and **Not this** per fact.
    func peopleEntity(_ params: PeopleGetParams, device: UUID, showsPeople: Bool, now: Date) async throws -> PeopleEntityResult {
        try params.validate()
        let (config, learning) = try await openPeople(showsPeople: showsPeople)
        let read: PeoplePhonePage?
        do {
            read = try services.store.peoplePhonePage(params.entityID, config: config, learning: learning, phrases: phrases)
        } catch PeopleError.closed {
            phrases.clear()
            throw CompanionError(.notFound, reason: PeopleUnavailable.factsOff)
        }
        try await stillOpen()
        guard let read else { throw CompanionError(.notFound) }
        let wording = services.factsWording
        func target(_ c: FactsCorrection?) -> FactsCorrectionTarget? {
            guard let c else { return nil }
            var t = c.target
            t.label = wording.label(c)
            return t
        }
        let page = read.page
        let result = PeopleEntityResult(
            entry: Self.entry(page.entry),
            aliases: page.aliases.map { PeopleEntityResult.Alias(alias: $0.alias, memories: $0.memories, yours: $0.yours) },
            facts: page.facts.map { f in
                PeopleFact(factID: f.factID, predicate: f.predicate, attribute: f.attribute, label: f.label, status: Self.status(f.status),
                           basis: PeopleBasis(rawValue: f.basis.rawValue) ?? .other, recordedOnly: f.recordedOnly, dated: f.dated,
                           episodes: f.episodes.map(Self.episode), notThis: target(read.notThis[f.factID]))
            },
            memories: page.memories.map { m in
                PeopleMemoryRow(memoryID: m.memoryID, title: m.title, updatedAt: m.updatedAt,
                                why: m.whyLine.map { Self.clip(wording.whyLine($0)) }, untrusted: m.untrusted,
                                notName: target(read.notName[m.memoryID]))
            },
            factsRevision: read.revision)
        logRead("people_viewed", device: device, now: now, counts: ["facts": result.facts.count, "memories": result.memories.count])
        return result
    }

    // MARK: FunesCore's read as the protocol's data

    static func entry(_ e: PeopleDirectory.Entry) -> PeopleEntry {
        PeopleEntry(id: e.id, kind: e.kind, name: e.name, group: e.group.map { PeopleEntry.Group(attribute: $0.attribute, count: $0.count) },
                    fact: e.fact.map { f in
                        PeopleEntry.Fact(attribute: f.attribute, status: status(f.status), since: f.since.map(range), until: f.until.map(range),
                                         recordedOnly: f.recordedOnly)
                    },
                    mentions: e.mentions, aliases: e.aliases, manual: e.manual, hidden: e.hidden, deceased: e.deceased, tombstone: e.tombstone)
    }

    static func episode(_ e: PeopleDirectory.TimelineEpisode) -> PeopleEpisode {
        let previous: PeopleEpisode.Previous? = switch e.previous {
        case .cantTell?: PeopleEpisode.Previous(cantTell: true)
        case let .gap(months)?: PeopleEpisode.Previous(gapMonths: months)
        case nil: nil
        }
        return PeopleEpisode(id: e.id, factID: e.factID, entityID: e.entity, name: e.name, start: e.start.map(range), end: e.end.map(range),
                             ongoing: e.ongoing, former: e.former, inferredEnd: e.inferredEnd, conflictStart: e.conflictStart,
                             conflictEnd: e.conflictEnd, untrusted: e.untrusted, kind: e.kind,
                             titles: e.titles.map { PeopleEpisode.Title(title: $0.title, from: $0.from.map(range)) },
                             stating: e.stating.count, previous: previous, yours: e.yours, yourDates: e.yourDates)
    }

    static func toCheck(_ item: PeopleDirectory.ToCheckItem) -> PeopleToCheckItem {
        switch item {
        case let .link(l):
            PeopleToCheckItem(id: item.id, link: .init(memoryID: l.memoryID, memoryTitle: l.memoryTitle, surface: l.surface, role: l.role,
                                                       candidates: l.candidates.map(\.name)))
        case let .merge(_, _, names):
            PeopleToCheckItem(id: item.id, merge: .init(names: names))
        case let .episode(e):
            PeopleToCheckItem(id: item.id, episode: .init(name: e.name, noun: e.noun, choices: e.choices.map(range)))
        }
    }

    static func range(_ r: DateRange) -> PeopleDateRange {
        PeopleDateRange(lo: r.lo, hi: r.hi, precision: PeopleDateRange.Precision(rawValue: r.precision.rawValue) ?? .unknown)
    }

    static func status(_ s: FactAssertion.Status) -> PeopleFactStatus {
        PeopleFactStatus(rawValue: s.rawValue) ?? .unknown
    }
}
