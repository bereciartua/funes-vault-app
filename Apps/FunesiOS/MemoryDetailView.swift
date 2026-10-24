import FunesPhone
import FunesProtocol
import SwiftUI

/// One memory (UX: iPhone, Memory detail; FR-iOS-07, FR-iOS-08): full text, kind, categories,
/// sensitivity, expiry and provenance, with Edit, Archive, Restore and Delete. Each change
/// names the version shown here; if the Mac has moved on, "Changed on your Mac, reload?".
struct MemoryDetailView: View {
    let model: PhoneModel
    @State private var detail: MemoryDetailModel
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    init(model: PhoneModel, id: UUID) {
        self.model = model
        _detail = State(initialValue: model.detailModel(id))
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .task { await detail.load() }
            .toolbar {
                if let memory = detail.memory, memory.status != .deleted {
                    Button("Edit") { detail.startEditing() }
                        .disabled(detail.busy)
                }
            }
            .sheet(isPresented: Binding(get: { detail.draft != nil }, set: { if !$0 { detail.cancelEditing() } })) {
                editSheet
            }
            .alert("Changed on your Mac, reload?", isPresented: conflictBinding(editing: false)) {
                conflictButtons
            } message: {
                Text("This memory changed on your Mac after it opened here. Reload shows the Mac's version.")
            }
            .confirmationDialog("Delete this memory?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { if await detail.delete() { dismiss() } }
                }
            } message: {
                Text("It moves to Recently Deleted on your Mac, where you can restore it for 30 days.")
            }
    }

    @ViewBuilder private var content: some View {
        switch detail.phase {
        case .loading:
            ProgressView()
        case .gone:
            ContentUnavailableView("This memory is no longer on your Mac", systemImage: "questionmark.folder",
                                   description: Text("It was deleted for good."))
        case let .failed(error):
            ContentUnavailableView {
                Label("Couldn't open this memory", systemImage: "exclamationmark.triangle")
            } description: {
                Text(PhoneModel.vaultMessage(for: error))
            } actions: {
                Button("Try Again") { Task { await detail.load() } }
            }
        case .loaded:
            if let shown = detail.detail { loaded(shown) }
        }
    }

    private func loaded(_ shown: CompanionMemory) -> some View {
        let memory = shown.memory
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(memory.title).font(.title3.bold())
                    Text(memory.body).textSelection(.enabled)
                }
                .padding(.vertical, 4)
                if let line = Self.statusLine(memory) {
                    Label(line, systemImage: memory.status == .deleted ? "trash" : "archivebox")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = detail.error, detail.draft == nil {
                Section {
                    Label(PhoneModel.vaultMessage(for: error), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section {
                KindRow(kind: memory.kind)
                LabeledContent("Categories", value: memory.categoryKeys.map(model.categories.name).formatted(.list(type: .and)))
                LabeledContent("Sensitivity") { SensitivityBadge(sensitivity: memory.sensitivity) }
                LabeledContent("Expires") {
                    if let expiry = memory.expiresAt {
                        Text(expiry, format: .dateTime.day().month().year())
                    } else {
                        Text("Never")
                    }
                }
                LabeledContent("Updated") { Text(memory.updatedAt, format: .dateTime.day().month().year().hour().minute()) }
            } footer: {
                Text(memory.sensitivity.explanation)
            }
            Section("Shared") {
                if shown.sharedCount == 0 {
                    Text("Never shared with an agent").foregroundStyle(.secondary)
                } else if let last = shown.lastSharedAt {
                    Text(shown.sharedCount == 1
                         ? String(localized: "Shared once · \(last.formatted(.relative(presentation: .named)))")
                         : String(localized: "Shared \(shown.sharedCount) times · last \(last.formatted(.relative(presentation: .named)))"))
                } else {
                    Text("Shared \(shown.sharedCount) times")
                }
            }
            if !shown.provenance.isEmpty {
                Section("History") {
                    ForEach(Array(shown.provenance.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Self.event(line.event)) · \(line.label)")
                            Text(line.at, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Section { actions(memory) }
        }
        .refreshable { await detail.load() }
    }

    @ViewBuilder private func actions(_ memory: Memory) -> some View {
        switch memory.status {
        case .active:
            Button("Archive") { Task { await detail.archive() } }
                .disabled(detail.busy)
            Button("Delete…", role: .destructive) { confirmingDelete = true }
                .disabled(detail.busy)
        case .archived:
            Button("Restore") { Task { await detail.restore() } }
                .disabled(detail.busy)
            Button("Delete…", role: .destructive) { confirmingDelete = true }
                .disabled(detail.busy)
        case .deleted:
            Button("Restore") { Task { await detail.restore() } }
                .disabled(detail.busy)
        }
    }

    @ViewBuilder private var editSheet: some View {
        if let memory = detail.memory {
            MemoryEditSheet(title: "Edit Memory", saveLabel: "Save",
                            // A closing sheet's text field writes its text back once more: only an edit in
                            // progress takes it, or a saved edit would open again (device check).
                            draft: Binding(get: { detail.draft ?? MemoryEditDraft(memory) },
                                           set: { if detail.draft != nil { detail.draft = $0 } }),
                            original: MemoryEditDraft(memory), categories: model.categories, busy: detail.busy,
                            error: detail.error.map(PhoneModel.vaultMessage(for:)),
                            save: { await detail.save() }, cancel: { detail.cancelEditing() })
                // A reload puts the Mac's version in the editor: fresh fields, not ones still
                // showing what was typed.
                .id(memory.version)
                .alert("Changed on your Mac, reload?", isPresented: conflictBinding(editing: true)) {
                    conflictButtons
                } message: {
                    Text("This memory changed on your Mac after it opened here. Reload puts the Mac's version in the editor, in place of your edits.")
                }
        }
    }

    /// The question shows on the edit sheet while it's open, else on the detail.
    private func conflictBinding(editing: Bool) -> Binding<Bool> {
        Binding(get: { detail.conflict && (detail.draft != nil) == editing }, set: { if !$0 { detail.conflict = false } })
    }

    @ViewBuilder private var conflictButtons: some View {
        Button("Reload") { Task { await detail.reload() } }
        Button("Not Now", role: .cancel) {}
    }

    static func statusLine(_ memory: Memory) -> String? {
        switch memory.status {
        case .active: nil
        case .archived: String(localized: "Archived. Archived memories are kept, but never shared with agents.")
        case .deleted: String(localized: "Recently Deleted. Restore it within 30 days, or it's removed for good.")
        }
    }

    /// A provenance line's event, as the Mac's history words it.
    static func event(_ raw: String) -> String {
        switch ProvenanceEvent(rawValue: raw) {
        case .created: String(localized: "Created")
        case .edited: String(localized: "Edited")
        case .archived: String(localized: "Archived")
        case .restored: String(localized: "Restored")
        case .deleted: String(localized: "Deleted")
        case .shared: String(localized: "Shared")
        case .confirmed: String(localized: "Confirmed still true")
        case .suggestedCorrection: String(localized: "Correction suggested")
        case .appliedFromSuggestion: String(localized: "Saved from the Inbox")
        case .splitInto: String(localized: "Split into a new memory")
        case .splitFrom: String(localized: "Split from another memory")
        case .mergedInto: String(localized: "Merged into a new memory")
        case .mergedFrom: String(localized: "Merged from another memory")
        case .autoApplied: String(localized: "Changed automatically")
        case .undone: String(localized: "Undone")
        case nil: raw
        }
    }
}
