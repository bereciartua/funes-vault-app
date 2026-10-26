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

    /// The file's contents: one overview per range.
    struct File: Codable {
        var overviews: [String: VaultOverview]
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
    public func read() -> [OverviewRange: VaultOverview] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let file = try? CompanionJSON.decoder().decode(File.self, from: data) else {
            logger.error("The cached overview couldn't be read")
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: file.overviews.compactMap { key, overview in
            OverviewRange(rawValue: key).map { ($0, overview) }
        })
    }

    /// Keeps `overview` as its range's, beside the other ranges' answers.
    public func write(_ overview: VaultOverview) throws {
        var all = read()
        all[overview.range] = overview
        let file = File(overviews: Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value) }))
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
    private let caller: any CompanionCalling
    private let cache: OverviewCache?

    public init(caller: any CompanionCalling, cache: OverviewCache?) {
        self.caller = caller
        self.cache = cache
        overviews = cache?.read() ?? [:]
    }

    public func overview(_ range: OverviewRange) -> VaultOverview? { overviews[range] }

    /// Asks for `range` and keeps the answer, here and in the cache.
    public func load(_ range: OverviewRange = .days30) async {
        do {
            let overview = try await caller.overview(range)
            overviews[range] = overview
            do { try cache?.write(overview) } catch { logger.error("The overview couldn't be cached") }
        } catch {
            onFailure?(error)
        }
    }

    /// Unpaired, removed or leaving the demo: the counts leave the phone.
    public func clear() {
        overviews = [:]
        cache?.delete()
    }
}
