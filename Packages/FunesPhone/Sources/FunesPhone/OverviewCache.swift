import Foundation
import FunesProtocol
import Observation
import os

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "overview")

extension CompanionCalling {
    /// `overview.get`: the vault's counts for `range` (ADR-0025).
    public func overview(_ range: OverviewRange) async throws(CompanionClientError) -> VaultOverview {
        try await call(OverviewGet.self, OverviewParams(range: range))
    }
}

/// The last `overview.get` answer for each range, kept as `overview.json` in the App Group
/// container (ADR-0025, companion protocol §6.1) for Home, which shows it at once and while the
/// Mac is away, and for the widgets, which never call the Mac. Counts, dates and agent names
/// only: never memory text or titles.
///
/// Written atomically after each successful call, readable after the first unlock
/// (`completeUntilFirstUserAuthentication`, which Lock Screen widgets need), and deleted on
/// unpair, on revocation and when leaving the demo.
public struct OverviewCache: Sendable {
    public static let fileName = "overview.json"

    /// The file's contents: one overview per range, and whether they're the demo's.
    struct File: Codable {
        var overviews: [String: VaultOverview]
        /// Nil in files written before the widgets (task 7.5), which were never the demo's.
        var demo: Bool?
    }

    /// What's cached: the answers by range, and whether they're the demo vault's (the widgets
    /// label them **DEMO**).
    public struct Contents: Sendable, Equatable {
        public var overviews: [OverviewRange: VaultOverview]
        public var isDemo: Bool

        public init(overviews: [OverviewRange: VaultOverview] = [:], isDemo: Bool = false) {
            self.overviews = overviews
            self.isDemo = isDemo
        }
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    /// The cache the app and its extensions share; nil without the App Group container.
    public static func appGroup() -> OverviewCache? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Identifiers.appGroup) else {
            logger.error("No App Group container")
            return nil
        }
        return OverviewCache(url: container.appending(path: fileName))
    }

    /// What's cached, by range; empty when there's nothing, or nothing readable.
    public func read() -> [OverviewRange: VaultOverview] { contents().overviews }

    /// What's cached, and whose it is; empty when there's nothing, or nothing readable.
    public func contents() -> Contents {
        guard let data = try? Data(contentsOf: url) else { return Contents() }
        guard let file = try? CompanionJSON.decoder().decode(File.self, from: data) else {
            logger.error("The cached overview couldn't be read")
            return Contents()
        }
        let overviews = Dictionary(uniqueKeysWithValues: file.overviews.compactMap { key, overview in
            OverviewRange(rawValue: key).map { ($0, overview) }
        })
        return Contents(overviews: overviews, isDemo: file.demo ?? false)
    }

    /// Keeps `overview` as its range's, beside the other ranges' answers. The demo's and the
    /// Mac's are never mixed: writing one drops the other's.
    public func write(_ overview: VaultOverview, demo: Bool = false) throws {
        let current = contents()
        var all = current.isDemo == demo ? current.overviews : [:]
        all[overview.range] = overview
        let file = File(overviews: Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value) }), demo: demo ? true : nil)
        let data = try CompanionJSON.encoder().encode(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The overview Home and the widgets show (ADR-0025): the cached answers at once, refreshed from
/// the Mac (or the demo vault) on launch, foreground and refresh, and written back to the cache.
/// A failed call keeps what's there, so Home can say "As of 10:42".
@MainActor @Observable
public final class OverviewModel {
    public private(set) var overviews: [OverviewRange: VaultOverview]
    public var onFailure: ((CompanionClientError) -> Void)?
    /// The cache was written or deleted: the app reloads the widgets' timelines.
    public var onCacheChange: (() -> Void)?
    private let caller: any CompanionCalling
    private let cache: OverviewCache?
    private let demo: Bool

    /// With `demo`, `caller` is the demo vault and the cache is marked as the demo's. Without, a
    /// demo's cache left behind (the app was closed in the demo) is deleted.
    public init(caller: any CompanionCalling, cache: OverviewCache?, demo: Bool = false) {
        self.caller = caller
        self.cache = cache
        self.demo = demo
        let contents = cache?.contents() ?? OverviewCache.Contents()
        if contents.isDemo != demo, !contents.overviews.isEmpty {
            cache?.delete()
            overviews = [:]
        } else {
            overviews = contents.overviews
        }
    }

    public func overview(_ range: OverviewRange) -> VaultOverview? { overviews[range] }

    /// Asks for `range` and keeps the answer, here and in the cache.
    public func load(_ range: OverviewRange = .days30) async {
        do {
            let overview = try await caller.overview(range)
            overviews[range] = overview
            do {
                try cache?.write(overview, demo: demo)
                onCacheChange?()
            } catch {
                logger.error("The overview couldn't be cached")
            }
        } catch {
            onFailure?(error)
        }
    }

    /// Shows `overview` without asking or caching it: the debug builds' made-up connection
    /// scenes, which have no Mac to ask.
    public func show(_ overview: VaultOverview) {
        overviews[overview.range] = overview
    }

    /// Unpaired, removed or leaving the demo: the counts leave the phone.
    public func clear() {
        overviews = [:]
        cache?.delete()
        onCacheChange?()
    }
}
