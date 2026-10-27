import FunesCore
import FunesProtocol
import SwiftUI

/// What a change did (FR-L-02, FR-V-12): each memory it touched, before and after. An automatic
/// change's comes from the undo log (30 days); any other change's from the memory's earlier
/// versions (90 days, ADR-0027). Shown by Activity's inspector, a memory's History and the Inbox's
/// Applied automatically list.
struct ChangeDetailView: View {
    let model: AppModel
    let items: [UndoChange.Item]
    /// "Tidy-up: merged 2 memories into “Harbor dates”"; nil where the row around it says what happened.
    var headline: String?
    var undone = false
    /// For an `undone` row: what the change made is what went away, and what it replaced came back.
    var reversed = false

    init(model: AppModel, change: UndoChange, reversed: Bool = false, showsHeadline: Bool = true) {
        self.model = model
        items = change.items
        let titles = Dictionary(change.items.compactMap { item in (item.after ?? item.before).map { (item.memoryID, $0.title) } },
                                uniquingKeysWith: { first, _ in first })
        headline = showsHeadline ? GroupText.change(change.entry, titles: titles) : nil
        undone = change.entry.undoneAt != nil
        self.reversed = reversed
    }

    init(model: AppModel, revision: RevisionChange) {
        self.model = model
        items = [UndoChange.Item(memoryID: revision.memoryID, before: revision.before, after: revision.after)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let headline {
                HStack(spacing: 6) {
                    Text(headline).font(.callout.weight(.medium))
                    if undone, !reversed { Pill(label: String(localized: "Undone"), tone: .neutral) }
                }
            }
            ForEach(items, id: \.memoryID) { item in
                ChangeItemView(model: model, item: reversed ? .init(memoryID: item.memoryID, before: item.after, after: item.before) : item,
                               reversed: reversed)
            }
        }
    }
}

/// One memory of a change: new, archived, restored or changed, with what changed.
private struct ChangeItemView: View {
    let model: AppModel
    let item: UndoChange.Item
    let reversed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Pill(label: verdict.text, tone: verdict.tone)
                if let title = (item.after ?? item.before)?.title {
                    Button(title) { model.showMemory(item.memoryID) }.buttonStyle(.link).lineLimit(1)
                        .help(String(localized: "Show this memory"))
                }
            }
            content
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder
    private var content: some View {
        switch (item.before, item.after) {
        case (nil, let after?):
            BodyText(text: after.body)
        case (let before?, nil):
            BodyText(text: before.body, faded: true)
            if !reversed {
                Text(String(localized: "What this change saved isn't kept."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case (let before?, let after?) where before == after:
            BodyText(text: after.body, faded: true)
        case (let before?, let after?):
            if before.title != after.title { DiffRow(label: String(localized: "Title"), before: before.title, after: after.title) }
            if before.body != after.body {
                DiffRow(label: String(localized: "Text"), before: before.body, after: after.body)
            } else if after.status != .active {
                BodyText(text: after.body, faded: true)
            }
            let fields = Self.fieldChanges(before, after, categoryName: model.categoryName)
            if !fields.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(fields, id: \.label) { field in
                        GridRow {
                            Text(field.label).font(.caption).foregroundStyle(.secondary)
                            Text("\(field.before) → \(field.after)")
                                .accessibilityLabel(String(localized: "\(field.label): \(field.before) before, \(field.after) after"))
                        }
                    }
                }
            }
        case (nil, nil):
            EmptyView()
        }
    }

    /// "New", "Archived", "Restored", "Changed"; "Removed" for a new memory an undo took back;
    /// "Kept" for one a change named but left alone (a duplicate's survivor).
    private var verdict: (text: String, tone: Pill.Tone) {
        switch (item.before, item.after) {
        case (nil, _): return (String(localized: "New"), .good)
        case (_, nil): return reversed ? (String(localized: "Removed"), .warning) : (String(localized: "Changed"), .accent)
        case (let before?, let after?) where before == after: return (String(localized: "Kept"), .neutral)
        case (let before?, let after?):
            guard before.status != after.status else { return (String(localized: "Changed"), .accent) }
            switch after.status {
            case .archived: return (String(localized: "Archived"), .warning)
            case .deleted: return (String(localized: "Deleted"), .warning)
            case .active: return (String(localized: "Restored"), .good)
            }
        }
    }

    /// Kind, categories, sensitivity and expiry, old → new. Status is in the verdict.
    static func fieldChanges(_ before: MemoryState, _ after: MemoryState,
                             categoryName: (String) -> String) -> [(label: String, before: String, after: String)] {
        var out: [(label: String, before: String, after: String)] = []
        if before.kind != after.kind { out.append((String(localized: "Kind"), before.kind.title, after.kind.title)) }
        if before.categoryKeys != after.categoryKeys {
            out.append((String(localized: "Categories"), before.categoryKeys.map(categoryName).joined(separator: ", "),
                        after.categoryKeys.map(categoryName).joined(separator: ", ")))
        }
        if before.sensitivity != after.sensitivity {
            out.append((String(localized: "Sensitivity"), before.sensitivity.title, after.sensitivity.title))
        }
        if before.expiresAt != after.expiresAt {
            let text = { (date: Date?) in date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "Never") }
            out.append((String(localized: "Expires"), text(before.expiresAt), text(after.expiresAt)))
        }
        return out
    }
}

/// A memory's text in a change's details; faded for text that's no longer in use.
private struct BodyText: View {
    let text: String
    var faded = false

    var body: some View {
        Text(text).foregroundStyle(faded ? .secondary : .primary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Old → new for one field: the old struck through above the new (FR-S-06).
struct DiffRow: View {
    let label: String
    let before: String
    let after: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(before).strikethrough().foregroundStyle(.secondary).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(String(localized: "Before: \(before)"))
            Text(after).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(String(localized: "After: \(after)"))
        }
        .textSelection(.enabled)
    }
}

/// What an Activity row changed (FR-L-02), looked up when it's selected: an automatic change's
/// before and after from the undo log, any other change's from its memories' earlier versions
/// (ADR-0027), or else the fields it changed from provenance. Nothing here is stored in the
/// Activity log, which holds ids and counts only.
struct ActivityChangeDetails: Equatable {
    var changes: [UndoChange] = []
    /// Edits, Inbox applies, archives and restores, from earlier versions.
    var revisions: [RevisionChange] = []
    /// An undo: its changes are shown taken back.
    var reversed = false
    /// The fields each memory's edit changed, for edits the undo log doesn't hold.
    var fields: [(memoryID: UUID, fields: [String])] = []
    /// An automatic change whose undo entry is gone (after 30 days).
    var expired = false

    /// Titles from the changes themselves, for their headlines.
    var titles: [UUID: String] {
        Dictionary(changes.flatMap(\.items).compactMap { item in (item.after ?? item.before).map { (item.memoryID, $0.title) } },
                   uniquingKeysWith: { first, _ in first })
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.changes == rhs.changes && lhs.revisions == rhs.revisions && lhs.reversed == rhs.reversed && lhs.expired == rhs.expired
            && lhs.fields.map(\.memoryID) == rhs.fields.map(\.memoryID) && lhs.fields.map(\.fields) == rhs.fields.map(\.fields)
    }

    @MainActor static func load(_ entry: ActivityEntry, model: AppModel) async -> Self {
        let e = entry.event
        let undo = UndoLog(store: model.services.store, activity: model.services.activity)
        let now = Date()
        var details = Self()
        switch e.event {
        case "auto_applied":
            details.changes = (try? await undo.changes(suggestionIDs: e.ids, now: now)) ?? []
            details.expired = details.changes.isEmpty
        case "undone":
            details.changes = (try? await undo.changes(ids: e.ids, now: now)) ?? []
            details.reversed = true
            details.expired = details.changes.isEmpty
        case "split" where e.outcome == "applied":
            // The memory that was split comes first; its change was recorded in the same moment.
            guard let id = e.ids.first else { break }
            details.changes = ((try? await undo.changes(memoryID: id, now: now)) ?? [])
                .filter { $0.entry.action == "split" && abs($0.entry.createdAt.timeIntervalSince(e.time)) < 2 }
            details.expired = details.changes.isEmpty
        case "tidy_up_run":
            guard let run = e.ids.first else { break }
            details.changes = (try? await undo.changes(runID: run, now: now)) ?? []
            details.expired = details.changes.isEmpty && (e.counts["applied"] ?? 0) > 0
        case "memory_edited", "sensitivity_raised", "suggestion_applied", "memory_archived", "memory_restored":
            for id in e.ids {
                let versions = ((try? model.services.store.revisionChanges(memoryID: id)) ?? [])
                    .filter { abs($0.at.timeIntervalSince(e.time)) < 2 }
                guard versions.isEmpty else {
                    details.revisions += versions
                    continue
                }
                let edits = ((try? model.services.store.provenance(memoryID: id)) ?? [])
                    .filter { $0.event == .edited && abs($0.at.timeIntervalSince(e.time)) < 2 }
                let fields = edits.flatMap(\.fieldsChanged).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                if !fields.isEmpty { details.fields.append((id, fields)) }
            }
        default: break
        }
        return details
    }
}

/// Where a change's details would be but its undo entry is gone.
struct ChangeDetailExpired: View {
    var body: some View {
        Text(String(localized: "Details of automatic changes are kept for 30 days."))
            .font(.caption).foregroundStyle(.secondary)
    }
}
