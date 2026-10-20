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
    @State private var error: String?
    @State private var similar: [Memory] = []
    @State private var confirmStillTrue = false
    @State private var confirmDeleteNow = false
    @State private var missing = false

    private var dirty: Bool { memory.map { MemoryForm($0) != form } ?? false }

    var body: some View {
        Group {
            if let memory {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        status(memory)
                        MemoryEditor(form: $form, categories: model.categories, editable: memory.status != .deleted)
                        if memory.status != .deleted { saveRow }
                        if !similar.isEmpty { similarHint }
                        Divider()
                        shared(memory)
                        HistoryList(entries: history, model: model)
                        actions(memory)
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            Button(String(localized: "Revert")) {
                if let memory { form = MemoryForm(memory) }
                error = nil
            }
            .disabled(!dirty)
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
                Button(String(localized: "Archive")) { act { try model.services.store.archiveMemory(id: memoryID, now: Date()) } }
                Button(String(localized: "Delete"), role: .destructive) {
                    act { try model.services.store.deleteMemory(id: memoryID, now: Date()) }
                }
            case .archived:
                Button(String(localized: "Restore")) { act { try model.services.store.restoreMemory(id: memoryID, now: Date()) } }
                Button(String(localized: "Delete"), role: .destructive) {
                    act { try model.services.store.deleteMemory(id: memoryID, now: Date()) }
                }
            case .deleted:
                Button(String(localized: "Restore")) { act { try model.services.store.restoreMemory(id: memoryID, now: Date()) } }
                Button(String(localized: "Delete Now…"), role: .destructive) { confirmDeleteNow = true }
            }
            Spacer()
        }
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
            if resetForm || (changed && !dirty) { form = MemoryForm(found) }
        } catch {
            missing = true
        }
    }

    private func save() {
        guard let memory else { return }
        do {
            let saved = try model.services.store.updateMemory(id: memoryID, form.edit(from: memory), now: Date())
            self.memory = saved
            form = MemoryForm(saved)
            error = nil
            history = (try? model.services.store.provenance(memoryID: memoryID)) ?? []
            Task { similar = await DuplicateHint.similar(to: saved, in: model) }
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

/// A memory's history: created, edited, archived, shared… Rows hold labels only (FR-V-12).
struct HistoryList: View {
    let entries: [ProvenanceEntry]
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "History")).font(.headline)
            ForEach(Array(entries.reversed().prefix(30).enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(Self.label(entry, model: model))
                    Spacer(minLength: 8)
                    Text(RelativeTime.full(entry.at)).font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
            if entries.count > 30 {
                Text(String(localized: "\(entries.count - 30) earlier entries")).font(.caption).foregroundStyle(.secondary)
            }
        }
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
