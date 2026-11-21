import FunesCore
import FunesProtocol
import Observation
import SwiftUI

/// Vault ▸ People & history (04-ux-mac.md, FR-F-07): what Funes learned about you, read off the main actor from
/// `VaultStore.peopleDirectory` with the uses search would use, whether or not *Use in search and answers* is on.
@MainActor @Observable
final class PeopleModel {
    enum Tab: String, CaseIterable, Identifiable {
        case people, timeline, toCheck
        var id: String { rawValue }
    }

    private let services: VaultEnvironment
    /// How to read: the registry, qualification, engines, your names and the cloud limit (`AppModel.peopleConfig`).
    @ObservationIgnored var config: () async -> FactsSearchConfig? = { nil }
    @ObservationIgnored private let phrases = RolePhraseCache()

    var tab: Tab = .people
    var directory: PeopleDirectory?
    var selection: String?
    var page: PeopleEntityPage?
    var query = ""
    var kinds: Set<String> = []
    var showHidden = false
    var loaded = false
    /// The last action's refusal, shown until the next one.
    var problem: String?
    /// Your names couldn't be read: nothing is shown (someone could be read as you).
    var unavailable = false

    @ObservationIgnored private var generation = 0

    init(services: VaultEnvironment) {
        self.services = services
    }

    /// The list as filtered: name search (names and aliases, case and accents ignored), kinds, hidden.
    var entries: [PeopleDirectory.Entry] {
        directory?.filtered(query: query, kinds: kinds, showHidden: showHidden) ?? []
    }

    var toCheckCount: Int { directory?.toCheck.count ?? 0 }

    // MARK: Loading

    func load() async {
        generation += 1
        let mine = generation
        guard let config = await config() else {
            guard mine == generation else { return }
            // Your names can't be read: show nothing (someone could be read as you), not what was there before.
            unavailable = true
            directory = nil
            page = nil
            loaded = true
            return
        }
        let store = services.store, phrases = phrases, selected = selection
        let result = await Task.detached(priority: .userInitiated) { () -> (PeopleDirectory?, PeopleEntityPage?) in
            let d = try? store.peopleDirectory(config: config, phrases: phrases)
            let p = try? selected.flatMap { try store.peopleEntity($0, config: config, phrases: phrases) }
            return (d, p)
        }.value
        guard mine == generation else { return }
        unavailable = false
        directory = result.0
        page = result.1
        if page == nil { selection = nil }
        loaded = true
    }

    func select(_ id: String?) {
        selection = id
        page = nil
        Task { await load() }
    }

    /// Learned facts turned off: no memory's text stays in the phrase cache.
    func clear() {
        phrases.clear()
        directory = nil
        page = nil
        selection = nil
        loaded = false
    }

    // MARK: Actions

    /// Runs a store action off the main actor, then reloads; a refusal is shown in words.
    func perform(_ action: @escaping @Sendable (VaultStore, any ActivityRecorder, FactsSearchConfig) throws -> Void) async {
        guard let config = await config() else { return }
        let store = services.store, activity = services.activity
        problem = nil
        do {
            try await Task.detached(priority: .userInitiated) { try action(store, activity, config) }.value
        } catch PeopleError.kindConflict {
            problem = String(localized: "It holds a fact about another kind of thing. Use Not This on that fact first.")
        } catch PeopleError.badDate {
            problem = String(localized: "Write dates as a year, a month or a day: 2019, 2019-03 or 2019-03-15.")
        } catch {
            problem = String(localized: "That didn't work. Try again.")
        }
        await load()
    }

    func rename(_ id: String, _ name: String) async {
        await perform { s, a, _ in try s.renameEntity(id, to: name, activity: a) }
    }

    func setKind(_ id: String, _ kind: String) async {
        await perform { s, a, c in try s.setEntityKind(id, to: kind, registry: c.registry, activity: a) }
    }

    func setDeceased(_ id: String, _ on: Bool) async {
        await perform { s, a, _ in try s.setDeceased(id, on, activity: a) }
    }

    func merge(_ other: String, into: String) async {
        await perform { s, a, _ in try s.mergeEntity(other, into: into, activity: a) }
    }

    func notSame(_ a: String, _ b: String) async {
        await perform { s, act, _ in try s.markNotSame(a, b, activity: act) }
    }

    func setHidden(_ id: String, _ hidden: Bool) async {
        await perform { s, _, _ in try s.setHidden(id, hidden) }
    }

    func setRelation(_ entity: String, predicate: String, label: String?, replacing: String?) async {
        await perform { s, a, c in
            try s.setRelation(entity: entity, predicate: predicate, label: label, replacing: replacing, registry: c.registry, activity: a)
        }
    }

    func setStatus(_ factID: String, _ status: FactAssertion.Status, selector: DateRange?) async {
        await perform { s, a, _ in try s.setFactStatus(factID, status, selector: selector, activity: a) }
    }

    func setDates(_ factID: String, start: String?, end: String?, selector: DateRange?) async {
        await perform { s, a, _ in try s.setDates(factID, start: start, end: end, selector: selector, activity: a) }
    }

    func clearDates(_ e: PeopleDirectory.TimelineEpisode) async {
        await perform { s, a, _ in try s.clearYourDates(e.factID, selectors: e.yourSelectors, activity: a) }
    }

    func addOrder(before: PeopleDirectory.TimelineEpisode, after: PeopleDirectory.TimelineEpisode) async {
        await perform { s, a, _ in
            try s.addOrder(before: before.factID, after: after.factID, beforeSelector: before.selector, afterSelector: after.selector,
                           activity: a)
        }
    }

    func rejectFact(_ factID: String) async {
        await perform { s, a, _ in try s.rejectFact(factID: factID, activity: a) }
    }

    func notName(_ target: WhyLine.NotName) async {
        await perform { s, a, c in _ = try s.rejectLink(memoryID: target.memoryID, entity: target.entity, config: c, activity: a) }
    }

    func add(_ entry: PeopleManualEntry) async {
        let box = IDBox()
        await perform { s, a, c in box.set(try s.addManualEntry(entry, registry: c.registry, activity: a)) }
        guard let id = box.value else { return }
        tab = .people
        selection = id
        await load()
    }

    func answer(_ link: PeopleDirectory.UnsettledLink, _ answer: PeopleLinkAnswer) async {
        await perform { s, a, _ in try s.answerLink(memoryID: link.memoryID, surface: link.surface, start: link.start, answer, activity: a) }
    }

    func retarget(_ lost: PeopleDirectory.LostEpisode, to range: DateRange?) async {
        await perform { s, a, _ in try s.retargetUserRow(lost.rowID, otherEndpoint: lost.otherEndpoint, to: range, activity: a) }
    }

    func undo(_ stamp: String) async {
        await perform { s, a, c in try s.undoPeopleAction(stamp, registry: c.registry, activity: a) }
    }
}

/// The id an action made, handed back from its background task.
private final class IDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    var value: String? { lock.withLock { id } }
    func set(_ v: String) { lock.withLock { id = v } }
}
