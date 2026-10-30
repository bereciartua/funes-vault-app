import FunesCore
import FunesProtocol
import SwiftUI

/// One memory: the editor, "Shared with", its history and the actions (04-ux-mac.md, FR-V-02..04,
/// FR-V-12, FR-V-15).
struct MemoryDetailView: View {
    let model: AppModel
    let memoryID: UUID
    @State private var memory: Memory?
    @State private var history: [ProvenanceEntry] = []
    @State private var form = MemoryForm()
    /// The version the form was filled from: Save sends it, so a change made meanwhile (from the
    /// iPhone, the Inbox, an import) isn't silently overwritten (6.1.2).
    @State private var formVersion: Int?
    /// Save found a newer version: offer to reload it.
    @State private var changedMeanwhile = false
    @State private var error: String?
    @State private var similar: [Memory] = []
    @State private var confirmStillTrue = false
    @State private var confirmDeleteNow = false
    @State private var missing = false

    private var dirty: Bool { memory.map { MemoryForm($0) != form } ?? false }

    #if FUNES_UI_REVIEW
    /// The UI review's Tidy Up scene: the actions and their result line in view.
    @MainActor static var reviewScrollsToActions = false
    #endif

    var body: some View {
        Group {
            if let memory {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            status(memory)
                            if let quoted = model.vault.quoted, quoted.memoryID == memoryID, !dirty,
                               let range = QuoteLocator.range(of: quoted.quote, in: memory.body) {
                                QuotedPassage(text: memory.body, range: range)
                            }
                            MemoryEditor(form: $form, categories: model.categories, editable: memory.status != .deleted)
                            if memory.status != .deleted { saveRow }
                            if !similar.isEmpty { similarHint }
                            Divider()
                            shared(memory)
                            HistoryList(entries: history, model: model).id("history")
                            VStack(alignment: .leading, spacing: 10) {
                                actions(memory)
                                if memory.status == .active, let result = model.tidyUp.memoryResult(memory) { tidyResult(result) }
                            }
                            .id("actions")
                        }
                        .padding(20)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #if FUNES_UI_REVIEW
                    .task(id: memoryID) {
                        guard HistoryList.reviewExpandsChanges || Self.reviewScrollsToActions else { return }
                        try? await Task.sleep(for: .milliseconds(400))
                        if Self.reviewScrollsToActions { proxy.scrollTo("actions", anchor: .bottom) }
                        else { proxy.scrollTo("history", anchor: .top) }
                    }
                    #endif
                }
            } else if missing {
                ContentUnavailableView(String(localized: "This memory is gone"), systemImage: "questionmark.folder",
                                       description: Text(String(localized: "It was deleted for good.")))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.pane)
        .task { load(resetForm: true) }
        // A quoted sentence stays highlighted until the text is edited (04-ux-mac.md ▸ Search answers).
        .onChange(of: form.body) { _, body in
            if let memory, body != memory.body, model.vault.quoted?.memoryID == memoryID { model.vault.quoted = nil }
        }
        // An edit from elsewhere (the iPhone, the Inbox) also retires it.
        .onChange(of: memory?.body) { old, _ in
            if old != nil, model.vault.quoted?.memoryID == memoryID { model.vault.quoted = nil }
        }
        .onChange(of: model.dataGeneration) { _, _ in load(resetForm: !dirty) }
        .confirmationDialog(String(localized: "Is this still true?"), isPresented: $confirmStillTrue) {
            Button(String(localized: "Still True")) { stillTrue() }
        } message: {
            Text(String(localized: "Funes notes that you checked it today."))
        }
        .confirmationDialog(String(localized: "Delete this memory now?"), isPresented: $confirmDeleteNow) {
            Button(String(localized: "Delete Now"), role: .destructive) { deleteNow() }
        } message: {
            Text(String(localized: "It's removed for good, with its history. This can't be undone."))
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func status(_ memory: Memory) -> some View {
        HStack(spacing: 8) {
            switch memory.status {
            case .archived: Pill(label: String(localized: "Archived"), tone: .warning)
            case .deleted: Pill(label: String(localized: "Recently Deleted"), tone: .bad)
            case .active:
                if memory.isExpired(at: model.now) { Pill(label: String(localized: "Expired"), tone: .bad) }
            }
            Text(memory.source.title).font(.callout).foregroundStyle(.secondary)
            if let confirmed = memory.lastConfirmedAt {
                Text(String(localized: "· confirmed \(RelativeTime.short(confirmed, now: model.now))"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        if memory.status == .deleted, let deletedAt = memory.deletedAt {
            let left = max(0, 30 - (Calendar.current.dateComponents([.day], from: deletedAt, to: model.now).day ?? 0))
            Text(String(localized: "Deleted \(RelativeTime.short(deletedAt, now: model.now)). It's removed for good in \(left) days unless you restore it."))
                .font(.callout).foregroundStyle(.secondary)
        }
        if memory.status == .archived {
            Text(String(localized: "Archived memories are kept, but never shared with agents."))
                .font(.callout).foregroundStyle(.secondary)
        }
        if model.embeddings.searchedOnThisMacOnly(memory.sensitivity) {
            Text(String(localized: "Searched on this Mac only (above cloud limit)."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var saveRow: some View {
        HStack(spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let problem = form.problem, dirty {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(changedMeanwhile ? String(localized: "Reload") : String(localized: "Revert")) {
                load(resetForm: true)
                error = nil
            }
            .disabled(!dirty && !changedMeanwhile)
            Button(String(localized: "Save")) { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!dirty || form.problem != nil)
        }
    }

    private var similarHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "doc.on.doc").foregroundStyle(Palette.warning)
            Text(String(localized: "Similar memory exists:"))
            ForEach(similar.prefix(2)) { other in
                Button(other.title) { model.showMemory(other.id) }.buttonStyle(.link)
            }
        }
        .font(.callout)
    }

    /// "Shared 4 times · last with Claude Code yesterday", linking to Activity.
    @ViewBuilder
    private func shared(_ memory: Memory) -> some View {
        let shares = history.filter { $0.event == .shared }
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.forward.circle").foregroundStyle(.secondary)
            if let last = shares.last {
                let agent = ActorLabel.agentName(last.actor, model: model)
                Text(shares.count == 1
                     ? String(localized: "Shared once · with \(agent) \(RelativeTime.short(last.at, now: model.now))")
                     : String(localized: "Shared \(shares.count) times · last with \(agent) \(RelativeTime.short(last.at, now: model.now))"))
                Button(String(localized: "Show in Activity")) { model.showActivity(.memory(memory.id)) }
                    .buttonStyle(.link)
            } else {
                Text(String(localized: "Never shared with an agent"))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func actions(_ memory: Memory) -> some View {
        HStack(spacing: 10) {
            switch memory.status {
            case .active:
                Button(String(localized: "Still True…")) { confirmStillTrue = true }
                    .help(String(localized: "Mark that you checked this memory today"))
                Button(model.tidyUp.tidying == memoryID ? String(localized: "Tidying Up…") : String(localized: "Tidy Up")) {
                    Task {
                        await model.tidyUp.tidy(memoryID: memoryID, version: memory.version)
                        await model.refresh()
                    }
                }
                .disabled(!model.tidyUp.canTidyMemory || model.tidyUp.running || model.tidyUp.tidying != nil || dirty)
                .help(model.tidyUp.canTidyMemory
                      ? String(localized: "Check this memory against itself and related memories now.")
                      : String(localized: "Choose a tidy-up model in Settings ▸ AI Models to tidy up a memory."))
                Button(String(localized: "Archive")) {
                    act { try model.services.store.archiveMemory(id: memoryID, expectedVersion: memory.version, now: Date()) }
                }
                Button(String(localized: "Delete"), role: .destructive) {
                    act { try model.services.store.deleteMemory(id: memoryID, expectedVersion: memory.version, now: Date()) }
                }
            case .archived:
                Button(String(localized: "Restore")) {
                    act { try model.services.store.restoreMemory(id: memoryID, expectedVersion: memory.version, now: Date()) }
                }
                Button(String(localized: "Delete"), role: .destructive) {
                    act { try model.services.store.deleteMemory(id: memoryID, expectedVersion: memory.version, now: Date()) }
                }
            case .deleted:
                Button(String(localized: "Restore")) {
                    act { try model.services.store.restoreMemory(id: memoryID, expectedVersion: memory.version, now: Date()) }
                }
                Button(String(localized: "Delete Now…"), role: .destructive) { confirmDeleteNow = true }
            }
            Spacer()
        }
    }

    /// What Tidy Up found, with a way to the Inbox when it left suggestions there.
    private func tidyResult(_ result: TidyUpController.MemoryResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.sparkles").foregroundStyle(.secondary)
            Text(TidyUpController.memoryNotice(result))
            if case .suggestions(let ids) = result {
                Button(String(localized: "Show in Inbox")) {
                    model.inboxState.focused = ids.first
                    model.show(.inbox)
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private func load(resetForm: Bool) {
        do {
            guard let found = try model.services.store.memory(id: memoryID) else {
                memory = nil
                missing = true
                return
            }
            let changed = memory?.version != found.version
            memory = found
            history = (try? model.services.store.provenance(memoryID: memoryID)) ?? []
            if resetForm || (changed && !dirty) {
                form = MemoryForm(found)
                formVersion = found.version
                changedMeanwhile = false
            }
        } catch {
            missing = true
        }
    }

    private func save() {
        guard let memory else { return }
        do {
            let saved = try model.services.store.updateMemory(id: memoryID, form.edit(from: memory),
                                                              expectedVersion: formVersion ?? memory.version, now: Date())
            self.memory = saved
            form = MemoryForm(saved)
            formVersion = saved.version
            changedMeanwhile = false
            error = nil
            history = (try? model.services.store.provenance(memoryID: memoryID)) ?? []
            Task { similar = await DuplicateHint.similar(to: saved, in: model) }
        } catch VaultError.versionConflict {
            changedMeanwhile = true
            self.error = String(localized: "This memory changed since you started editing. Reload it to see the change; your edits will be lost.")
        } catch {
            self.error = ErrorText.message(error)
        }
    }

    private func stillTrue() {
        act { try model.services.store.confirmMemory(id: memoryID, now: Date()) }
    }

    private func deleteNow() {
        do {
            try model.services.store.purgeMemory(id: memoryID)
            model.vault.selection = []
        } catch {
            self.error = ErrorText.message(error)
        }
    }

    private func act(_ body: () throws -> Void) {
        do {
            try body()
            error = nil
            load(resetForm: true)
        } catch {
            self.error = ErrorText.message(error)
        }
    }
}

/// The duplicate hint (FR-V-13): the same normalized text, or a raw cosine of at least 0.92.
@MainActor
enum DuplicateHint {
    static func similar(to memory: Memory, in model: AppModel) async -> [Memory] {
        let services = model.services
        var ids = (try? services.store.exactDuplicates(title: memory.title, body: memory.body, excluding: memory.id)) ?? []
        let names = memory.categoryKeys.map(model.categoryName)
        let near = (try? await services.search.nearDuplicates(title: memory.title, body: memory.body, kind: memory.kind,
                                                               categoryNames: names, excluding: memory.id)) ?? []
        for id in near where !ids.contains(id) { ids.append(id) }
        return (try? services.store.memories(ids: ids)) ?? []
    }
}

/// A memory's history: created, edited, archived, shared… Rows hold labels only (FR-V-12). A
/// change's row opens to what it did: an automatic change's from the undo log (30 days), any
/// other's from the memory's earlier versions (90 days, ADR-0027). A merge's or split's row links
/// to the other memory; each row can show its Activity row. Forget Earlier Versions deletes them.
struct HistoryList: View {
    let entries: [ProvenanceEntry]
    let model: AppModel
    @State private var changes: [UndoChange] = []
    @State private var revisions: [RevisionChange] = []
    @State private var confirmForget = false
    @State private var relatedTitles: [UUID: String] = [:]
    @State private var expanded: Set<ProvenanceEntry> = []

    #if FUNES_UI_REVIEW
    /// The UI-review build opens every change's details.
    @MainActor static var reviewExpandsChanges = false
    #endif

    var body: some View {
        let rows = Array(entries.reversed().prefix(30))
        let details = Self.details(for: rows, changes: changes, revisions: revisions)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "History")).font(.headline)
                Spacer()
                if !revisions.isEmpty {
                    Button(String(localized: "Forget Earlier Versions…")) { confirmForget = true }
                        .buttonStyle(.link).font(.callout)
                        .help(String(localized: "Delete the earlier text of this memory. Its history keeps the labels."))
                }
                if let id = entries.first?.memoryID {
                    Button(String(localized: "Show All in Activity")) { model.showActivity(.memory(id)) }
                        .buttonStyle(.link).font(.callout)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                row(index, entry, detail: details[index])
            }
            if entries.count > 30 {
                Text(String(localized: "\(entries.count - 30) earlier entries")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: entries) { await load() }
        .confirmationDialog(String(localized: "Forget this memory's earlier versions?"), isPresented: $confirmForget) {
            Button(String(localized: "Forget Earlier Versions"), role: .destructive) {
                guard let id = entries.first?.memoryID else { return }
                _ = try? model.services.store.forgetEarlierVersions(memoryID: id)
                Task { await load() }
            }
        } message: {
            Text(String(localized: "Their text is deleted from this Mac. The history keeps its labels, and automatic changes keep theirs until Undo expires."))
        }
    }

    private func row(_ index: Int, _ entry: ProvenanceEntry, detail: Detail?) -> some View {
        let open = expanded.contains(entry)
        let related = entry.relatedMemoryID.flatMap { id in relatedTitles[id].map { (id, $0) } }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if detail != nil {
                    Button {
                        if open { expanded.remove(entry) } else { expanded.insert(entry) }
                    } label: {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(open ? String(localized: "Hide what changed") : String(localized: "Show what changed"))
                } else {
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6).frame(width: 10).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.label(entry, model: model))
                    if let (id, title) = related {
                        Button(title) { model.showMemory(id) }.buttonStyle(.link).lineLimit(1)
                            .help(String(localized: "Show this memory"))
                    }
                }
                Spacer(minLength: 8)
                Text(RelativeTime.full(entry.at)).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: detail == nil && related == nil ? .combine : .contain)
            if open, let detail {
                VStack(alignment: .leading, spacing: 6) {
                    switch detail {
                    case .automatic(let change, let reversed): ChangeDetailView(model: model, change: change, reversed: reversed)
                    case .version(let revision): ChangeDetailView(model: model, revision: revision)
                    }
                    Button(String(localized: "Show in Activity")) { model.showActivity(memoryID: entry.memoryID, near: entry.at) }
                        .buttonStyle(.link)
                }
                .padding(.leading, 18)
            }
        }
        .font(.callout)
        .contextMenu {
            Button(String(localized: "Show in Activity")) { model.showActivity(memoryID: entry.memoryID, near: entry.at) }
        }
    }

    private func load() async {
        guard let id = entries.first?.memoryID else { return }
        changes = (try? await UndoLog(store: model.services.store, activity: model.services.activity).changes(memoryID: id, now: Date()))
            ?? []
        revisions = (try? model.services.store.revisionChanges(memoryID: id)) ?? []
        #if FUNES_UI_REVIEW
        if Self.reviewExpandsChanges {
            let rows = Array(entries.reversed().prefix(30))
            expanded = Set(Self.details(for: rows, changes: changes, revisions: revisions).keys.map { rows[$0] })
        }
        #endif
        let related = Array(Set(entries.compactMap(\.relatedMemoryID)))
        relatedTitles = Dictionary(((try? model.services.store.memories(ids: related)) ?? []).filter { $0.status != .deleted }
            .map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    enum Detail {
        /// From the undo log; `reversed` on the change's undo row.
        case automatic(UndoChange, reversed: Bool)
        /// From the memory's earlier versions.
        case version(RevisionChange)
    }

    /// Which row shows each change. An automatic change goes on the row that names it best
    /// (changed automatically, merged, split), else the first at the moment it was made, and its
    /// undo on the undone row at that moment. Any other change goes on the edited, archived,
    /// restored or deleted row by the same actor at its moment, unless an automatic change already
    /// covers that moment.
    static func details(for rows: [ProvenanceEntry], changes: [UndoChange], revisions: [RevisionChange]) -> [Int: Detail] {
        let preferred: [ProvenanceEvent] = [.autoApplied, .mergedInto, .mergedFrom, .splitInto, .splitFrom]
        let versioned: [ProvenanceEvent] = [.edited, .archived, .restored, .deleted]
        let near = { (a: Date, b: Date) in abs(a.timeIntervalSince(b)) < 2 }
        var out: [Int: Detail] = [:]
        for change in changes {
            let made = rows.indices.filter { rows[$0].event != .undone && near(rows[$0].at, change.entry.createdAt) && out[$0] == nil }
            if let i = made.first(where: { preferred.contains(rows[$0].event) }) ?? made.first {
                out[i] = .automatic(change, reversed: false)
            }
            if let undoneAt = change.entry.undoneAt,
               let i = rows.indices.first(where: { rows[$0].event == .undone && near(rows[$0].at, undoneAt) && out[$0] == nil }) {
                out[i] = .automatic(change, reversed: true)
            }
        }
        let automatic = changes.flatMap { [$0.entry.createdAt] + [$0.entry.undoneAt].compactMap { $0 } }
        for revision in revisions where !automatic.contains(where: { near($0, revision.at) }) {
            if let i = rows.indices.first(where: {
                versioned.contains(rows[$0].event) && rows[$0].actor == revision.actor && near(rows[$0].at, revision.at) && out[$0] == nil
            }) {
                out[i] = .version(revision)
            }
        }
        return out
    }

    @MainActor static func label(_ entry: ProvenanceEntry, model: AppModel) -> String {
        let who = ActorLabel.text(entry.actor, model: model)
        switch entry.event {
        case .created: return String(localized: "Created \(who)")
        case .edited:
            let fields = entry.fieldsChanged.map(fieldName).joined(separator: ", ")
            return fields.isEmpty ? String(localized: "Edited \(who)") : String(localized: "Edited \(fields) \(who)")
        case .archived: return String(localized: "Archived \(who)")
        case .restored: return String(localized: "Restored \(who)")
        case .deleted: return String(localized: "Deleted \(who)")
        case .shared: return String(localized: "Shared with \(ActorLabel.agentName(entry.actor, model: model))")
        case .confirmed: return String(localized: "Confirmed still true \(who)")
        case .suggestedCorrection: return String(localized: "Correction suggested \(who)")
        case .appliedFromSuggestion: return String(localized: "Applied from the Inbox")
        case .splitInto: return String(localized: "Split into a new memory \(who)")
        case .splitFrom: return String(localized: "Split from another memory \(who)")
        case .mergedInto: return String(localized: "Merged into a new memory \(who)")
        case .mergedFrom: return String(localized: "Merged from another memory \(who)")
        case .autoApplied: return String(localized: "Changed automatically")
        case .undone: return String(localized: "Undone \(who)")
        }
    }

    static func fieldName(_ field: String) -> String {
        switch field {
        case "title": String(localized: "title")
        case "body": String(localized: "text")
        case "kind": String(localized: "kind")
        case "categories": String(localized: "categories")
        case "sensitivity": String(localized: "sensitivity")
        case "expires_at": String(localized: "expiry")
        case "status": String(localized: "status")
        case "confidence": String(localized: "confidence")
        default: field
        }
    }
}

/// "by you", "by Claude Code", "on iPhone", "by an import".
@MainActor
enum ActorLabel {
    static func text(_ actor: String, model: AppModel) -> String {
        if actor == "user" { return String(localized: "by you") }
        if actor.hasPrefix("agent:") { return String(localized: "by \(agentName(actor, model: model))") }
        if actor.hasPrefix("device:") { return String(localized: "on iPhone") }
        if actor.hasPrefix("import:") { return String(localized: "by an import") }
        return String(localized: "by Funes Vault")
    }

    static func agentName(_ actor: String, model: AppModel) -> String {
        guard actor.hasPrefix("agent:"), let id = UUID(uuidString: String(actor.dropFirst(6))) else {
            return String(localized: "an agent")
        }
        return model.agentName(id)
    }
}

/// The sentence a search answer quoted, highlighted in its context, above the memory's text
/// (found with `QuoteLocator`; FR-AI-17).
struct QuotedPassage: View {
    let text: String
    let range: Range<String.Index>

    /// Characters of context kept on each side of the quote.
    static let context = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "Quoted in the answer"), systemImage: "quote.opening")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(Self.excerpt(text, range: range))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    /// The quote with up to `context` characters either side, at word boundaries, with "…" where
    /// cut, and the quote highlighted.
    static func excerpt(_ text: String, range: Range<String.Index>) -> AttributedString {
        var start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        while start > text.startIndex, start < range.lowerBound, !text[text.index(before: start)].isWhitespace { start = text.index(after: start) }
        while end < text.endIndex, end > range.upperBound, !text[end].isWhitespace { end = text.index(before: end) }
        var result = AttributedString(start > text.startIndex ? "…" : "")
        result += AttributedString(String(text[start..<range.lowerBound]))
        var quote = AttributedString(String(text[range]))
        quote.backgroundColor = Color.yellow.opacity(0.45)
        quote.inlinePresentationIntent = .stronglyEmphasized
        result += quote
        result += AttributedString(String(text[range.upperBound..<end]))
        result += AttributedString(end < text.endIndex ? "…" : "")
        return result
    }
}
