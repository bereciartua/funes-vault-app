import FunesPhone
import FunesProtocol
import SwiftUI

/// The Inbox tab (UX: iPhone, Inbox tab; FR-iOS-09, ADR-0031): the Mac's waiting suggestions,
/// every card answered as on the Mac. Swipe right saves a new memory or closes one already saved
/// (where the row shows everything that changes); every other card opens to be answered. Swipe
/// left rejects, pull to refresh; every action is also in the row's context menu and on the
/// suggestion's own screen. A row the Mac is still splitting is greyed and can only be rejected;
/// one whose split failed offers Try Again and Keep as One.
struct InboxView: View {
    let model: PhoneModel

    /// A suggestion as it was opened: its screen stays while the row is away being answered.
    struct Route: Hashable {
        let item: InboxItem

        func hash(into hasher: inout Hasher) { hasher.combine(item.id) }
    }

    /// A memory a card refers to, opened as in Search.
    struct MemoryLink: Hashable {
        let id: UUID
    }

    var body: some View {
        @Bindable var inbox = model.inbox
        NavigationStack {
            List {
                if model.reachability.isConnected, !inbox.items.isEmpty {
                    if inbox.answeredElsewhere > 0 {
                        Label("Already answered on your Mac", systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(inbox.items) { item in
                            NavigationLink(value: Route(item: item)) {
                                InboxRow(item: item, categories: model.categories)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if item.processing == .failed {
                                    Button("Try Again") { Task { await inbox.retry(item.id) } }
                                        .tint(.blue)
                                } else if InboxModel.swipes(item) {
                                    Button(InboxItemView.saveLabel(item.action)) { Task { await inbox.save(item.id) } }
                                        .tint(.green)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Reject", role: .destructive) { Task { await inbox.reject(item.id) } }
                            }
                            .contextMenu {
                                if item.processing == .failed {
                                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await inbox.retry(item.id) } }
                                    Button("Keep as One", systemImage: "square") { Task { await inbox.keepAsOne(item.id) } }
                                } else if InboxModel.swipes(item) {
                                    Button(InboxItemView.saveLabel(item.action), systemImage: "checkmark") { Task { await inbox.save(item.id) } }
                                }
                                Button("Reject", systemImage: "xmark", role: .destructive) { Task { await inbox.reject(item.id) } }
                            }
                        }
                        if inbox.nextCursor != nil {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .task { await inbox.loadMore() }
                        }
                    }
                }
            }
            .overlay { placeholder }
            .refreshable {
                inbox.answeredElsewhere = 0
                if model.reachability.isConnected { await inbox.load() } else { await model.refresh(fresh: true) }
            }
            .navigationTitle("Inbox")
            // Read once on connecting; pull to refresh and coming to the front read it again.
            .task(id: model.reachability.isConnected) {
                if model.reachability.isConnected, inbox.phase != .loaded { await inbox.load() }
            }
            .navigationDestination(for: Route.self) { route in
                InboxItemView(model: model, item: route.item)
            }
            .navigationDestination(for: MemoryLink.self) { link in
                MemoryDetailView(model: model, id: link.id)
            }
            .alert(inbox.failure.map(InboxItemView.failureTitle) ?? "",
                   isPresented: Binding(get: { inbox.failure != nil }, set: { if !$0 { inbox.failure = nil } }),
                   presenting: inbox.failure) { _ in
                Button("OK") {}
            } message: { failure in
                Text(InboxItemView.failureMessage(failure))
            }
        }
    }

    /// What shows over the list while there are no suggestions to list.
    @ViewBuilder private var placeholder: some View {
        let inbox = model.inbox
        if !model.reachability.isConnected {
            VaultUnavailableView(model: model, feature: .inbox)
        } else if inbox.items.isEmpty {
            switch inbox.phase {
            case .idle, .loading:
                ProgressView()
            case let .failed(error):
                ContentUnavailableView {
                    Label("Couldn't read the Inbox", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(PhoneModel.vaultMessage(for: error))
                } actions: {
                    Button("Try Again") { Task { await inbox.load() } }
                }
            case .loaded:
                ContentUnavailableView("Your Inbox is empty", systemImage: "tray",
                                       description: Text("Suggestions from agents, captures and imports wait here until you save or reject them."))
            }
        }
    }
}

/// A suggestion card: where it came from, what it does, the proposed title and text, and its fields.
struct InboxRow: View {
    let item: InboxItem
    let categories: CategoryList

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(InboxItemView.sourceLine(item)).font(.caption).foregroundStyle(.secondary)
            switch item.processing {
            case .processing:
                Label("Processing…", systemImage: "hourglass").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            case .failed:
                Label("Couldn't split", systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            case nil:
                if item.action != .create {
                    Text(InboxItemView.action(item)).font(.caption.weight(.medium)).foregroundStyle(.tint)
                }
            }
            Text(item.title).font(.headline).lineLimit(2)
            Text(item.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 4) {
                SensitivityBadge(sensitivity: item.sensitivity)
                Text(item.kind.title).font(.caption2).foregroundStyle(.secondary)
                CategoryChips(keys: item.categories, categories: categories)
            }
            .lineLimit(1)
            if item.outsideScope {
                OutsideScopeLabel(agent: item.sourceLabel)
            }
        }
        .padding(.vertical, 2)
        // Greyed while the Mac is still splitting it: it can't be saved yet.
        .opacity(item.processing == .processing ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// "Outside Claude Code's scope", as the Mac's piece badge: a warning, never a refusal.
struct OutsideScopeLabel: View {
    let agent: String

    var body: some View {
        Label("Outside \(agent)'s scope", systemImage: "exclamationmark.triangle")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.orange)
    }
}

/// One suggestion in full (ADR-0031): what it changes, fetched when it opens, and the Mac card's
/// choices for its action, with Reject.
struct InboxItemView: View {
    let model: PhoneModel
    /// As it was opened: the row leaves the list while an answer is on its way.
    let item: InboxItem
    /// The card in full (`inbox.get`); nil until it's read.
    @State private var detail: InboxDetail?
    @State private var loadError: CompanionClientError?
    @State private var edit: Edit?
    @State private var busy = false
    /// Why the last answer didn't go through. Shown here rather than on the list underneath.
    @State private var failure: InboxModel.Failure?
    @Environment(\.dismiss) private var dismiss

    /// The edit sheet: Edit & Save / Replace / Merge on the proposal, or a conflict's Edit… on
    /// the memory it keeps.
    private struct Edit {
        var draft: MemoryEditDraft
        let original: MemoryEditDraft
        let keep: UUID?
    }

    /// As the list has it now: Try Again and Keep as One change it in place.
    private var processing: InboxProcessing? { model.inbox.items.first { $0.id == item.id }?.processing ?? item.processing }
    private var current: InboxItem { detail?.item ?? item }
    private var stale: Bool { detail?.stale ?? false }

    var body: some View {
        details
            .navigationBarTitleDisplayMode(.inline)
            .task { await reload() }
            .refreshable { await reload() }
            .sheet(isPresented: Binding(get: { edit != nil }, set: { if !$0 { edit = nil } })) {
                if let sheet = edit {
                    MemoryEditSheet(title: editTitle, saveLabel: Self.saveKey(current.action),
                                    // As in the memory detail: a closing sheet's last write doesn't reopen it.
                                    draft: Binding(get: { edit?.draft ?? sheet.draft }, set: { if edit != nil { edit?.draft = $0 } }),
                                    original: sheet.original, categories: model.categories, busy: busy,
                                    error: failure.map(Self.failureMessage),
                                    save: {
                                        guard let edit else { return }
                                        let changes = edit.draft.changes(from: edit.original)
                                        if let keep = edit.keep {
                                            await answer(.save, mode: .keep, keep: keep, edits: changes)
                                        } else {
                                            await answer(.save, edits: changes)
                                        }
                                    },
                                    cancel: {
                                        edit = nil
                                        failure = nil
                                    })
                }
            }
    }

    private var editTitle: LocalizedStringKey {
        switch current.action {
        case .update: "Edit & Replace"
        case .merge: "Edit & Merge"
        case .conflict: "Edit"
        default: "Edit & Save"
        }
    }

    private var details: some View {
        List {
            if let failure, edit == nil {
                Section {
                    Label("\(Self.failureTitle(failure)) \(Self.failureMessage(failure))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            if stale, processing == nil {
                Section {
                    Label("Changed since this was suggested", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Review Again") { Task { await answer(.reviewAgain) } }
                } footer: {
                    Text("Compare with the memory as it is now, then decide again.")
                }
                .disabled(busy)
            }
            Section {
                Text(Self.sourceLine(current)).font(.footnote).foregroundStyle(.secondary)
                if showsProposal {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(current.title).font(.title3.bold())
                        Text(current.body).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                if current.outsideScope { OutsideScopeLabel(agent: current.sourceLabel) }
                if let reason = detail?.tidyUp?.archiveReason, current.action == .archive { ReasonPill(reason: reason) }
            } header: {
                Text(Self.action(current))
            } footer: {
                if current.origin == .agent {
                    Text("Proposed by \(current.sourceLabel). Check it before you save it.")
                }
            }
            if let detail {
                context(detail)
            } else if let loadError {
                Section {
                    Label(PhoneModel.vaultMessage(for: loadError), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await reload() } }
                }
            } else if processing == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            if showsFields {
                Section {
                    KindRow(kind: current.kind)
                    LabeledContent("Categories", value: current.categories.map(model.categories.name).formatted(.list(type: .and)))
                    LabeledContent("Sensitivity") { SensitivityBadge(sensitivity: current.sensitivity) }
                    if let expiry = current.expiresAt {
                        LabeledContent("Expires") { Text(expiry, format: .dateTime.day().month().year()) }
                    }
                }
            }
            if let reason = detail?.tidyUp?.reason, !reason.isEmpty {
                Section("Why, as the Model Put It") { Text(reason) }
            }
            if let evidence = current.evidence, !evidence.isEmpty {
                Section("\(current.sourceLabel)'s Reason") { Text(evidence) }
            }
            if let purpose = current.purpose, !purpose.isEmpty {
                Section("\(current.sourceLabel)'s Task") { Text(purpose) }
            }
            if let similar = detail?.similar, !similar.isEmpty {
                Section("Similar Memory Exists") {
                    ForEach(similar) { memory in
                        NavigationLink(memory.title, value: InboxView.MemoryLink(id: memory.id))
                    }
                }
            }
            actions
        }
    }

    /// The proposal's own title and text: what it saves. An archive, a duplicate and a conflict
    /// show the memories instead; a split shows its original.
    private var showsProposal: Bool {
        switch current.action {
        case .create, .update, .merge, .unknown: true
        case .archive, .duplicate, .conflict, .split: detail == nil
        }
    }

    private var showsFields: Bool { [.create, .update, .merge].contains(current.action) }

    /// What the card changes, per action, as the Mac's card words it.
    @ViewBuilder
    private func context(_ detail: InboxDetail) -> some View {
        let targets = detail.memories(.target)
        switch current.action {
        case .create, .unknown:
            EmptyView()
        case .update:
            if let target = targets.first {
                Section("Changes “\(target.title)”") {
                    if target.title != current.title {
                        Change(label: "Title", old: target.title, new: current.title)
                    }
                    Change(label: "Text", old: target.body, new: current.body)
                }
            }
            ForEach(detail.memories(.source)) { copy in
                Section { QuotedMemory(memory: copy) } header: { Text("Also archives “\(copy.title)”") }
            }
        case .archive:
            if let target = targets.first {
                Section {
                    QuotedMemory(memory: target)
                    if detail.tidyUp?.archiveReason == .expired, let date = target.expiresAt {
                        Text("It expired \(date.formatted(.relative(presentation: .named))).").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Archives “\(target.title)”")
                }
            }
            if let survivor = detail.memories(.survivor).first {
                Section { QuotedMemory(memory: survivor) } header: { Text("Keeps “\(survivor.title)”") }
            }
        case .duplicate:
            if let target = targets.first {
                Section { QuotedMemory(memory: target) } header: { Text("Already in your vault: “\(target.title)”") }
            }
        case .split:
            if let target = targets.first {
                Section { QuotedMemory(memory: target) } header: { Text("Splits “\(target.title)” into \(detail.pieces.count)") }
            }
            Section {
                ForEach(detail.pieces) { piece in
                    VStack(alignment: .leading, spacing: 4) {
                        if let badge = Self.pieceBadge(piece, memories: detail.memories) {
                            Text(badge).font(.caption.weight(.medium)).foregroundStyle(piece.action == .archive ? .orange : .secondary)
                        }
                        if piece.outsideScope { OutsideScopeLabel(agent: piece.sourceLabel) }
                        Text(piece.title).font(.subheadline.weight(.medium))
                        Text(piece.body).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Into")
            } footer: {
                if detail.pieces.contains(where: { $0.action == .update || $0.action == .archive }) {
                    Text("Pieces that change other memories stay in your Inbox to review on their own.")
                }
            }
        case .merge:
            let sources = detail.memories(.source)
            Section {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        NavigationLink(value: InboxView.MemoryLink(id: source.id)) {
                            Label(source.title, systemImage: "arrow.triangle.merge")
                        }
                        if let kept = detail.tidyUp?.kept.first(where: { $0.memoryId == source.id }) {
                            Text("Keeps: \(kept.text)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Merges \(sources.count) memories into one:")
            }
        case .conflict:
            ForEach(Array(targets.enumerated()), id: \.element.id) { index, memory in
                Section {
                    QuotedMemory(memory: memory)
                    Button("Keep This") { Task { await answer(.save, mode: .keep, keep: memory.id) } }
                        .disabled(busy || stale)
                        .accessibilityLabel("Keep “\(memory.title)”")
                } header: {
                    if index == 0 { Text("These disagree. Which is true?") }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Section {
            switch processing {
            case .processing:
                EmptyView()
            case .failed:
                Button("Try Again") { Task { await answer(.retry) } }
                Button("Keep as One") { Task { await answer(.keep) } }
            case nil:
                applyButtons
            }
            Button("Reject", role: .destructive) { Task { await answer(.reject) } }
        } footer: {
            switch processing {
            case .processing:
                Text("Your Mac is still splitting this into separate memories. It can be saved once that's done.")
            case .failed:
                Text("Your Mac couldn't split this. Try again, or keep it as one memory.")
            case nil:
                if !current.action.appliesOnPhone {
                    Text("Review on your Mac: this version of Funes for iPhone can't apply it.")
                } else if current.action == .duplicate {
                    Text("Nothing changes: it's already in your vault.")
                } else if current.action == .update, current.origin != .consolidation {
                    Text("Keep Both saves it as a new memory and leaves “\(detail?.memories(.target).first?.title ?? current.title)” as it is.")
                }
            }
        }
        .disabled(busy)
    }

    /// The Mac card's choices for the action. Off until the card is read (so an apply is bound to
    /// what it shows), and while it's stale (Keep Both excepted, as on the Mac).
    @ViewBuilder
    private var applyButtons: some View {
        let ready = detail != nil && !stale
        switch current.action {
        case .create:
            Button("Save") { Task { await answer(.save) } }.disabled(!ready)
            Button("Edit & Save…") { edit = Edit(draft: MemoryEditDraft(current), original: MemoryEditDraft(current), keep: nil) }
                .disabled(!ready)
        case .update:
            Button("Replace") { Task { await answer(.save, mode: .replace) } }.disabled(!ready)
            Button("Edit & Replace…") { edit = Edit(draft: MemoryEditDraft(current), original: MemoryEditDraft(current), keep: nil) }
                .disabled(!ready)
            // A tidy-up update replaces or is rejected: keeping both would leave two copies.
            if current.origin != .consolidation {
                Button("Keep Both") { Task { await answer(.save, mode: .keepBoth) } }.disabled(detail == nil)
            }
        case .archive:
            Button("Archive") { Task { await answer(.save) } }.disabled(!ready)
        case .duplicate:
            Button("Already Saved") { Task { await answer(.save) } }.disabled(!ready)
        case .split:
            let count = detail?.pieces.filter { $0.action == .create }.count ?? 0
            Button("Split into \(count)") { Task { await answer(.save) } }.disabled(!ready || count == 0)
        case .merge:
            Button("Merge") { Task { await answer(.save) } }.disabled(!ready)
            Button("Edit & Merge…") { edit = Edit(draft: MemoryEditDraft(current), original: MemoryEditDraft(current), keep: nil) }
                .disabled(!ready)
        case .conflict:
            Button("Both Are True") { Task { await answer(.save, mode: .bothTrue) } }.disabled(!ready)
            if let first = detail?.memories(.target).first {
                Button("Edit…") { edit = Edit(draft: MemoryEditDraft(first), original: MemoryEditDraft(first), keep: first.id) }
                    .disabled(!ready)
            }
        case .unknown:
            EmptyView()
        }
    }

    /// `inbox.get`. One answered on the Mac meanwhile: back to the list.
    private func reload() async {
        do {
            detail = try await model.inbox.detail(item.id)
            loadError = nil
        } catch .method(let error) where error.code == .notFound {
            dismiss()
        } catch {
            if !Task.isCancelled { loadError = error }
        }
    }

    /// Answers. Done (or answered on the Mac first): back to the list. Failed: the reason shows
    /// here, an edit stays open with its text, and a card that changed is read again. Try Again,
    /// Keep as One and Review Again stay.
    private func answer(_ answer: InboxModel.Answer, mode: InboxApplyMode? = nil, keep: UUID? = nil,
                        edits: MemoryChanges? = nil) async {
        busy = true
        defer { busy = false }
        failure = nil
        let inbox = model.inbox
        let done = switch answer {
        case .save: await inbox.save(item.id, mode: mode, keep: keep, edits: edits, revision: detail?.revision)
        case .reject: await inbox.reject(item.id)
        case .retry: await inbox.retry(item.id)
        case .keep: await inbox.keepAsOne(item.id)
        case .reviewAgain: await inbox.reviewAgain(item.id)
        }
        if let failed = inbox.failure, failed.id == item.id {
            failure = failed
            inbox.failure = nil
            if case let .method(error) = failed.error, [.targetChanged, .requestChanged].contains(error.code) {
                edit = nil
                await reload()
            }
        } else if (done && (answer == .save || answer == .reject)) || !inbox.items.contains(where: { $0.id == item.id }) {
            edit = nil
            dismiss()
        } else if done, answer == .reviewAgain {
            await reload()
        }
    }

    /// The swipe's and the menu's label for a card a swipe saves.
    static func saveLabel(_ action: SuggestionAction) -> LocalizedStringKey {
        action == .duplicate ? "Already Saved" : "Save"
    }

    /// The edit sheet's save button.
    static func saveKey(_ action: SuggestionAction) -> LocalizedStringKey {
        switch action {
        case .update: "Replace"
        case .merge: "Merge"
        default: "Save"
        }
    }

    static func failureTitle(_ failure: InboxModel.Failure) -> String {
        let title = failure.item.title
        switch failure.answer {
        case .save:
            switch failure.item.action {
            case .archive: return String(localized: "Couldn't archive “\(title)”.")
            case .split: return String(localized: "Couldn't split “\(title)”.")
            case .merge: return String(localized: "Couldn't merge “\(title)”.")
            case .update, .duplicate, .conflict: return String(localized: "Couldn't apply “\(title)”.")
            case .create, .unknown: return String(localized: "Couldn't save “\(title)”.")
            }
        case .reject: return String(localized: "Couldn't reject “\(title)”.")
        case .retry: return String(localized: "Couldn't try “\(title)” again.")
        case .keep: return String(localized: "Couldn't keep “\(title)” as one.")
        case .reviewAgain: return String(localized: "Couldn't review “\(title)” again.")
        }
    }

    /// Why, in the Mac's words where the Inbox has its own.
    static func failureMessage(_ failure: InboxModel.Failure) -> String {
        if failure.answer == .reviewAgain, case let .method(error) = failure.error, error.code == .targetChanged {
            return String(localized: "A memory it changes was archived or deleted. Reject it, or restore that memory first.")
        }
        return PhoneModel.vaultMessage(for: failure.error)
    }

    /// "Updates “…”", "Already saved", "Removes “…”": a split piece's own action, as on the Mac.
    static func pieceBadge(_ piece: InboxItem, memories: [InboxMemory]) -> String? {
        let title = memories.first { $0.memory.id == piece.targetMemoryId }?.memory.title ?? piece.title
        switch piece.action {
        case .update: return String(localized: "Updates “\(title)”")
        case .duplicate: return String(localized: "Already saved")
        case .archive: return String(localized: "Removes “\(title)”")
        default: return nil
        }
    }

    /// "Suggested by Claude Code · 2 h ago", as the Mac's Inbox words it.
    static func sourceLine(_ item: InboxItem) -> String {
        let time = item.createdAt.formatted(.relative(presentation: .named))
        switch item.origin {
        case .agent:
            return item.targetMemoryId == nil ? String(localized: "Suggested by \(item.sourceLabel) · \(time)")
                                              : String(localized: "Correction from \(item.sourceLabel) · \(time)")
        case .captureMac: return String(localized: "Captured on your Mac · \(time)")
        case .captureIPhone: return String(localized: "Captured on \(item.sourceLabel) · \(time)")
        case .seedQuestion: return String(localized: "Your answer · \(time)")
        case .consolidation: return String(localized: "Tidy-up · \(time)")
        case .import: return String(localized: "Imported · \(time)")
        }
    }

    static func action(_ item: InboxItem) -> String {
        switch item.action {
        case .create: String(localized: "New memory")
        case .update: String(localized: "Change to a memory")
        case .archive: String(localized: "Archive a memory")
        case .duplicate: String(localized: "Already in your vault")
        case .split: String(localized: "Split a memory")
        case .merge: String(localized: "Merge memories")
        case .conflict: String(localized: "Memories that disagree")
        case .unknown: String(localized: "Review on your Mac")
        }
    }
}

/// A memory a card refers to: its title opens it, its text below.
private struct QuotedMemory: View {
    let memory: Memory

    var body: some View {
        NavigationLink(value: InboxView.MemoryLink(id: memory.id)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.title).font(.subheadline.weight(.medium))
                Text(memory.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            }
            .padding(.vertical, 2)
        }
    }
}

/// An update's old → new, for the title or the text.
private struct Change: View {
    let label: LocalizedStringKey
    let old: String
    let new: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if old == new {
                Text(new).font(.subheadline)
            } else {
                Text(old).font(.subheadline).strikethrough().foregroundStyle(.secondary)
                Text(new).font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Why the tidy-up archives: "A copy", "Out of date", "Expired".
private struct ReasonPill: View {
    let reason: InboxArchiveReason

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(reason == .expired ? Color.secondary : Color.orange)
            .background((reason == .expired ? Color.secondary : Color.orange).opacity(0.15), in: Capsule())
    }

    private var title: String {
        switch reason {
        case .duplicate: String(localized: "A copy")
        case .superseded: String(localized: "Out of date")
        case .expired: String(localized: "Expired")
        }
    }
}
