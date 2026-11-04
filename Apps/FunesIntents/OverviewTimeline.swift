import FunesPhone
import FunesProtocol
import os
import SwiftUI
import WidgetKit

private let logger = Logger(subsystem: Identifiers.iOSLoggerSubsystem, category: "widgets")

/// One moment of the widgets' timeline: FunesPhone's `WidgetSnapshot`.
struct OverviewEntry: TimelineEntry {
    let snapshot: WidgetSnapshot
    var date: Date { snapshot.date }

    /// The gallery's and the placeholder's: the demo vault's counts, labelled as the demo's.
    static func sample(_ date: Date = Date()) -> OverviewEntry {
        OverviewEntry(snapshot: WidgetSnapshot(date: date, content: .overview(sampleOverview), isDemo: true))
    }

    /// Read once a process: the demo vault is a whole JSON file to decode, and WidgetKit asks for
    /// placeholders often.
    static let sampleOverview = DemoVault().sampleOverview()
}

/// The one timeline the widgets share (ADR-0025: they never call the Mac): the cached 30-day
/// overview, an entry when "as of" begins and when it dims, and one each midnight, which moves the
/// days along without new counts. The app reloads it after every cache write.
struct OverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> OverviewEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (OverviewEntry) -> Void) {
        let entry = OverviewEntry(snapshot: Self.current(Date()))
        // The gallery shows what the widget does, even before the first counts.
        completion(context.isPreview && entry.snapshot.overview == nil ? .sample() : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OverviewEntry>) -> Void) {
        let now = Date()
        let snapshot = Self.current(now)
        let overview = snapshot.overview
        let dates = WidgetSnapshot.dates(from: now, generatedAt: snapshot.isDemo ? nil : overview?.generatedAt,
                                         calendar: overview?.calendar ?? .autoupdatingCurrent)
        completion(Timeline(entries: dates.map { OverviewEntry(snapshot: snapshot.at($0)) }, policy: .atEnd))
    }

    /// The cache; without it, whether this iPhone holds a pairing.
    static func current(_ now: Date) -> WidgetSnapshot {
        let contents = OverviewCache.appGroup()?.contents() ?? OverviewCache.Contents()
        return WidgetSnapshot(date: now, cache: contents, paired: paired())
    }

    /// Nil while the Keychain can't say (before the first unlock).
    private static func paired() -> Bool? {
        do {
            return try PairingRecordStore(store: KeychainSecretStore()).load() != nil
        } catch {
            logger.error("Couldn't read the pairing")
            return nil
        }
    }
}
