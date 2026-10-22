import FunesPhone
import FunesProtocol
import SwiftUI

/// The Inbox tab (UX: iPhone, Inbox tab; FR-iOS-09): the Mac's waiting suggestions. Swipe right
/// to save, left to reject, pull to refresh; every action is also in the row's context menu and
/// on the suggestion's own screen, with Edit & Save.
struct InboxView: View {
    let model: PhoneModel

    /// A suggestion as it was opened: its screen stays while the row is away being answered.
    struct Route: Hashable {
        let item: InboxItem

        func hash(into hasher: inout Hasher) { hasher.combine(item.id) }
    }

    var body: some View {
        @Bindable var inbox = model.inbox
        NavigationStack {
            List {
                BannerSection(model: model)
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
                                Button("Save") { Task { await inbox.save(item.id) } }
                                    .tint(.green)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Reject", role: .destructive) { Task { await inbox.reject(item.id) } }
                            }
                            .contextMenu {
                                Button("Save", systemImage: "checkmark") { Task { await inbox.save(item.id) } }
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
            .alert(inbox.failure.map(InboxItemView.failureTitle) ?? "",
                   isPresented: Binding(get: { inbox.failure != nil }, set: { if !$0 { inbox.failure = nil } }),
                   presenting: inbox.failure) { _ in
                Button("OK") {}
            } message: { failure in
                Text(PhoneModel.vaultMessage(for: failure.error))
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

/// A suggestion card: where it came from, the proposed title and text, and its fields.
struct InboxRow: View {
    let item: InboxItem
    let categories: CategoryList

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(InboxItemView.sourceLine(item)).font(.caption).foregroundStyle(.secondary)
            Text(item.title).font(.headline).lineLimit(2)
            Text(item.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 4) {
                SensitivityBadge(sensitivity: item.sensitivity)
                Text(item.kind.title).font(.caption2).foregroundStyle(.secondary)
                CategoryChips(keys: item.categories, categories: categories)
            }
            .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One suggestion in full, with Save, Edit & Save and Reject.
struct InboxItemView: View {
    let model: PhoneModel
    /// As it was opened: the row leaves the list while an answer is on its way.
    let item: InboxItem
    @State private var draft: MemoryEditDraft?
    @State private var busy = false
    /// Why the last answer didn't go through. Shown here rather than on the list underneath.
    @State private var failure: InboxModel.Failure?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        details
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } })) {
                MemoryEditSheet(title: "Edit & Save", saveLabel: "Save",
                                // As in the memory detail: a closing sheet's last write doesn't reopen it.
                                draft: Binding(get: { draft ?? MemoryEditDraft(item) }, set: { if draft != nil { draft = $0 } }),
                                original: MemoryEditDraft(item), categories: model.categories, busy: busy,
                                error: failure.map { PhoneModel.vaultMessage(for: $0.error) },
                                save: { await answer(.save, edits: draft?.changes(from: MemoryEditDraft(item))) },
                                cancel: {
                                    draft = nil
                                    failure = nil
                                })
            }
    }

    private var details: some View {
        List {
            if let failure, draft == nil {
                Section {
                    Label("\(Self.failureTitle(failure)) \(PhoneModel.vaultMessage(for: failure.error))",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text(Self.sourceLine(item)).font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.title3.bold())
                    Text(item.body).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            } header: {
                Text(Self.action(item))
            } footer: {
                if item.origin == .agent {
                    Text("Proposed by \(item.sourceLabel). Check it before you save it.")
                }
            }
            Section {
                KindRow(kind: item.kind)
                LabeledContent("Categories", value: item.categories.map(model.categories.name).formatted(.list(type: .and)))
                LabeledContent("Sensitivity") { SensitivityBadge(sensitivity: item.sensitivity) }
                if let expiry = item.expiresAt {
                    LabeledContent("Expires") { Text(expiry, format: .dateTime.day().month().year()) }
                }
            }
            if let evidence = item.evidence, !evidence.isEmpty {
                Section("\(item.sourceLabel)'s Reason") { Text(evidence) }
            }
            if let purpose = item.purpose, !purpose.isEmpty {
                Section("\(item.sourceLabel)'s Task") { Text(purpose) }
            }
            Section {
                Button("Save") { Task { await answer(.save, edits: nil) } }
                if item.action != .archive {
                    Button("Edit & Save…") { draft = MemoryEditDraft(item) }
                }
                Button("Reject", role: .destructive) { Task { await answer(.reject, edits: nil) } }
            }
            .disabled(busy)
        }
    }

    /// Saves or rejects. Done (or answered on the Mac first): back to the list. Failed: the
    /// reason shows here, and an edit stays open with its text.
    private func answer(_ answer: InboxModel.Answer, edits: MemoryChanges?) async {
        busy = true
        defer { busy = false }
        failure = nil
        let inbox = model.inbox
        let done = answer == .save ? await inbox.save(item.id, edits: edits) : await inbox.reject(item.id)
        if let failed = inbox.failure, failed.id == item.id {
            failure = failed
            inbox.failure = nil
        } else if done || !inbox.items.contains(where: { $0.id == item.id }) {
            draft = nil
            dismiss()
        }
    }

    static func failureTitle(_ failure: InboxModel.Failure) -> String {
        failure.answer == .save ? String(localized: "Couldn't save “\(failure.item.title)”.")
                                : String(localized: "Couldn't reject “\(failure.item.title)”.")
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
        case .consolidation: return String(localized: "Cleanup suggestion · \(time)")
        case .import: return String(localized: "Imported · \(time)")
        }
    }

    static func action(_ item: InboxItem) -> String {
        switch item.action {
        case .create: String(localized: "New memory")
        case .update: String(localized: "Change to a memory")
        case .archive: String(localized: "Archive a memory")
        }
    }
}
