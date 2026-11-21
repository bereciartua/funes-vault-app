import Foundation
import FunesProtocol
import Observation

/// People & history on the iPhone (05-ux-iphone.md, companion protocol §4.3, 13d.2): the Mac's section, read live with
/// `people.directory` and `people.get`, corrected only with `facts.reject`. Nothing outlives the screen: what's shown is
/// in memory, dropped when the screen goes, when the Mac says People is closed, or when a newer revision comes.
///
/// Freshness: every request has a generation, so a late reply never brings back what a newer one, a closing screen or a
/// closed gate cleared. `status.get` and a correction's reply reload what's open when the revision moved; a reply that
/// brings another revision only marks the other view stale, reloaded when it shows, so a backfill (whose counter moves
/// constantly) never makes it loop.
@MainActor @Observable
public final class PeopleModel {
    public enum Tab: String, CaseIterable, Sendable {
        case people, timeline, toCheck
    }

    public enum Phase: Sendable, Equatable {
        case idle, loading, loaded
        /// The Mac's section has nothing to send: `facts_off` or `names_unavailable` (`PeopleUnavailable`).
        case closed(reason: String)
        case failed(CompanionClientError)
    }

    /// The Mac has People for this phone (`status.get`'s `people`); false on an older Mac, and the entry hides.
    public private(set) var available = false
    public var tab = Tab.people
    /// The name search and the Kind filter, applied here to the list the Mac sent (the Mac's own filter, `PeopleFilter`).
    public var query = ""
    public var kinds: Set<String> = []

    public private(set) var phase = Phase.idle
    public private(set) var directory: PeopleDirectoryResult?

    /// The open entity's page.
    public private(set) var pageID: String?
    public private(set) var page: PeopleEntityResult?
    public private(set) var pagePhase = Phase.idle

    /// A correction didn't go through: the Mac wasn't reachable (nothing queued), or it refused one that changed.
    public private(set) var correctionFailure: CompanionClientError?
    /// A correction is on its way.
    public private(set) var correcting = false

    /// Hears every failed call, for the reachability banner.
    @ObservationIgnored public var onFailure: @MainActor (CompanionClientError) -> Void
    /// Hears a correction the Mac applied: Search drops its held answer, and the app asks `status.get` again.
    @ObservationIgnored public var onCorrected: @MainActor () -> Void = {}

    private let caller: any CompanionCalling
    private var generation = 0
    private var pageGeneration = 0
    /// The screen is open (the view sets it); closing it drops everything.
    private var visible = false
    /// A reply brought another revision than the view shows: reload it when it shows.
    private var directoryStale = false
    private var pageStale = false

    public init(caller: any CompanionCalling, onFailure: @escaping @MainActor (CompanionClientError) -> Void = { _ in }) {
        self.caller = caller
        self.onFailure = onFailure
    }

    // MARK: What's listed

    /// The list as filtered: names and aliases, case and accents ignored, and the kinds picked.
    public var entries: [PeopleEntry] {
        (directory?.entries ?? []).filter { $0.matches(query: query, kinds: kinds) }
    }

    public var toCheckCount: Int { directory?.toCheck.filter { PeopleWording.question($0) != nil }.count ?? 0 }

    // MARK: The status

    /// Every `status.get` that reached the Mac: `people` nil (an older Mac, or none for this phone) hides the entry and
    /// drops everything; `shown: false` closes it; another revision reloads what's open.
    public func statusChecked(_ status: PeopleStatus?) {
        guard let status else {
            available = false
            clear()
            return
        }
        available = true
        guard status.shown else {
            close(PeopleUnavailable.factsOff)
            return
        }
        guard visible else { return }
        // Read again whatever is open and not shown at this revision: older, absent (still loading: a reply on its way
        // may predate the change, and the new request's generation drops it), closed (Facts or your names may be back),
        // or a status with no revision (your names unreadable now). What's shown at this revision isn't read again.
        // Still unreadable names, already said: not read again at each status (pull to refresh or Try Again still reads).
        let r = status.factsRevision
        let names = Phase.closed(reason: PeopleUnavailable.namesUnavailable)
        // A reply on its way is dropped now, not when the new read's task gets to run.
        if r == nil || directory?.factsRevision != r, !(r == nil && phase == names) {
            generation += 1
            Task { await load() }
        }
        if let id = pageID, r == nil || page?.factsRevision != r, !(r == nil && (pagePhase == names || phase == names)) {
            pageGeneration += 1
            Task { await loadPage(id) }
        }
    }

    /// A memory opened from a page was edited, archived or deleted on the phone: its row, the counts and the buttons may
    /// be out of date, so the page and the list are read again when they show.
    public func memoryChanged() {
        if page != nil { pageStale = true }
        if directory != nil { directoryStale = true }
    }

    // MARK: The screen

    /// The screen opened: read the directory.
    public func appeared() async {
        visible = true
        if directory == nil || directoryStale { await load() }
    }

    /// The screen closed: nothing outlives it, and a reply on its way is dropped.
    public func disappeared() {
        visible = false
        clear()
    }

    /// `people.directory`.
    public func load() async {
        generation += 1
        let mine = generation
        if directory == nil { phase = .loading }
        do {
            let result = try await caller.call(PeopleDirectoryGet.self, EmptyParams())
            guard mine == generation, visible else { return }
            directory = result
            directoryStale = false
            phase = .loaded
            if let shown = page?.factsRevision, shown != result.factsRevision { pageStale = true }
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            if let reason = Self.closedReason(error) {
                close(reason)
                return
            }
            if directory == nil { phase = .failed(error) }
            onFailure(error)
        }
    }

    /// An entity's page opened (from the list, the timeline or To check).
    public func openPage(_ id: String) async {
        if pageID != id {
            pageID = id
            page = nil
            pagePhase = .idle
        }
        if page == nil || pageStale { await loadPage(id) }
    }

    /// The page closed.
    public func closePage(_ id: String) {
        guard pageID == id else { return }
        pageGeneration += 1
        pageID = nil
        page = nil
        pagePhase = .idle
        pageStale = false
        // The list, if it changed under the page, reloads when it shows again (`appeared`).
    }

    /// `people.get`. A merged-away id answers with the entity it went into (the Mac follows the merge at each read).
    public func loadPage(_ id: String) async {
        pageGeneration += 1
        let mine = pageGeneration
        if page == nil { pagePhase = .loading }
        do {
            let result = try await caller.call(PeopleGet.self, PeopleGetParams(entityID: id))
            guard mine == pageGeneration, pageID == id else { return }
            page = result
            pageStale = false
            pagePhase = .loaded
            if let shown = directory?.factsRevision, shown != result.factsRevision { directoryStale = true }
        } catch {
            guard mine == pageGeneration, pageID == id, !Task.isCancelled else { return }
            if let reason = Self.closedReason(error) {
                close(reason)
                return
            }
            if case let .method(e) = error, e.code == .notFound {
                page = nil
                pagePhase = .failed(error)
                return
            }
            if page == nil { pagePhase = .failed(error) }
            onFailure(error)
        }
    }

    // MARK: Corrections

    /// **Not <name>** on a memory row, **Not this** (or Remove) on a fact: sent to the Mac, which applies it at once. The
    /// page and the list reload, and Search drops its held answer. Unreachable: nothing is queued. Refused because it
    /// changed on the Mac: the page reloads with current buttons.
    public func correct(_ target: FactsCorrectionTarget) async {
        guard !correcting else { return }       // a second tap while the first is on its way
        correctionFailure = nil
        correcting = true
        defer { correcting = false }
        let screen = generation
        do {
            _ = try await caller.call(FactsReject.self, target)
            // Search's held answer goes first, before any further call can wait.
            onCorrected()
            // The screen went meanwhile: nothing to reload or say.
            guard screen == generation, visible else { return }
            await reloadAfterCorrection()
        } catch {
            guard screen == generation, visible else { return }
            let failure = error
            guard case let .method(e) = failure else {
                correctionFailure = failure
                onFailure(failure)
                return
            }
            if let reason = Self.closedReason(failure) {
                close(reason)                   // the closed screen says why; no alert over it
                return
            }
            // Changed since the page was read: say so. Gone (or anything else): the page is simply read again.
            if e.code == .targetChanged { correctionFailure = failure }
            await reloadAfterCorrection()
        }
    }

    public func dismissCorrectionFailure() { correctionFailure = nil }

    private func reloadAfterCorrection() async {
        if let id = pageID { await loadPage(id) }
        if pageID == nil { await load() } else { directoryStale = true }
    }

    // MARK: Clearing

    /// Everything goes; replies on their way are dropped.
    public func clear() {
        generation += 1
        pageGeneration += 1
        directory = nil
        page = nil
        pageID = nil
        phase = .idle
        pagePhase = .idle
        directoryStale = false
        pageStale = false
        correctionFailure = nil
        query = ""
        kinds = []
        tab = .people
    }

    /// The Mac says People is closed: nothing it sent before stays.
    private func close(_ reason: String) {
        generation += 1
        pageGeneration += 1
        directory = nil
        page = nil
        phase = .closed(reason: reason)
        pagePhase = pageID == nil ? .idle : .closed(reason: reason)
        directoryStale = false
        pageStale = false
    }

    static func closedReason(_ error: CompanionClientError) -> String? {
        guard case let .method(e) = error, e.code == .notFound, let reason = e.reason,
              reason == PeopleUnavailable.factsOff || reason == PeopleUnavailable.namesUnavailable else { return nil }
        return reason
    }
}
