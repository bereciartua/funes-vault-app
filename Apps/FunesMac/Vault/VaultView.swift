import FunesCore
import FunesProtocol
import SwiftUI

/// The Vault (04-ux-mac.md): the setup checklist until it's done, a toolbar with search, filters,
/// sort and New Memory, the list, and the selected memory's editor.
struct VaultView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var creating = false
    @State private var managingCategories = false
    @State private var confirmDeleteNow = false

    private var vault: VaultModel { model.vault }

    var body: some View {
        VStack(spacing: 0) {
            if model.checklist.isVisible {
                SetupChecklistCard(model: model)
                    .padding([.horizontal, .top], 16)
            }
            toolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            if let result = vault.bulkResult {
                HStack {
                    Text(result).foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Dismiss")) { vault.bulkResult = nil }.buttonStyle(.link)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: 460, maxHeight: .infinity)
                detail
                    .frame(minWidth: 360, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.pane)
        .task { await vault.load() }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: model.newMemoryRequest) { _, _ in creating = true }
        .onChange(of: model.dataGeneration) { _, _ in Task { await vault.load() } }
        .onChange(of: model.selectedMemoryID) { _, id in
            if let id, !vault.selection.contains(id) { vault.selection = [id] }
        }
        .onChange(of: vault.selection) { _, selection in
            model.selectedMemoryID = selection.count == 1 ? selection.first : nil
        }
        .sheet(isPresented: $creating) {
            NewMemorySheet(model: model) { id in
                vault.status = .active
                Task {
                    await vault.load()
                    vault.selection = [id]
                }
            }
        }
        .sheet(isPresented: $managingCategories) { CategoriesSheet(model: model) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SearchField(text: Binding(get: { vault.query }, set: { vault.query = $0 }),
                            prompt: String(localized: "Search memories"), focused: $searchFocused)
                    .frame(minWidth: 180, maxWidth: 360)
                Spacer(minLength: 8)
                Button { managingCategories = true } label: {
                    Label(String(localized: "Categories…"), systemImage: "tag")
                }
                .help(String(localized: "Rename, add or delete categories"))
                Button { creating = true } label: {
                    Label(String(localized: "New Memory"), systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 6) {
                FilterMenu(title: String(localized: "Category"), options: model.categories.map { ($0.key, $0.name) },
                           selection: Binding(get: { vault.categoryKeys }, set: { vault.categoryKeys = $0 }))
                FilterMenu(title: String(localized: "Kind"), options: MemoryKind.allCases.map { ($0, $0.title) },
                           selection: Binding(get: { vault.kinds }, set: { vault.kinds = $0 }))
                FilterMenu(title: String(localized: "Sensitivity"), options: Sensitivity.allCases.map { ($0, $0.title) },
                           selection: Binding(get: { vault.sensitivities }, set: { vault.sensitivities = $0 }))
                Picker(String(localized: "Status"), selection: Binding(get: { vault.status }, set: { vault.status = $0 })) {
                    ForEach(VaultModel.StatusChoice.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(String(localized: "Status"))
                FilterMenu(title: String(localized: "Source"), options: MemorySource.allCases.map { ($0, $0.title) },
                           selection: Binding(get: { vault.sources }, set: { vault.sources = $0 }))
                if vault.hasFilters {
                    Button(String(localized: "Clear")) { vault.clearFilters() }.buttonStyle(.link)
                }
                Spacer(minLength: 8)
                Picker(String(localized: "Sort by"), selection: Binding(get: { vault.sort }, set: { vault.sort = $0 })) {
                    ForEach(VaultModel.SortChoice.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }
            .controlSize(.small)
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        VStack(spacing: 0) {
            if vault.selection.count > 1 {
                BulkBar(model: model, ids: vault.selection, status: vault.status)
                Divider()
            }
            if vault.memories.isEmpty, vault.loaded {
                emptyState
            } else {
                List(selection: Binding(get: { vault.selection }, set: { vault.selection = $0 })) {
                    ForEach(vault.memories) { memory in
                        MemoryRow(memory: memory, model: model, now: model.now)
                            .tag(memory.id)
                            .contextMenu { rowMenu(memory) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(String(localized: "Memories"))
            }
        }
        .background(Palette.card)
    }

    @ViewBuilder
    private func rowMenu(_ memory: Memory) -> some View {
        switch memory.status {
        case .deleted:
            Button(String(localized: "Restore")) { Task { await vault.perform(.restore, on: [memory.id]) } }
            Button(String(localized: "Delete Now"), role: .destructive) { Task { await vault.perform(.deleteNow, on: [memory.id]) } }
        case .archived:
            Button(String(localized: "Restore")) { Task { await vault.perform(.restore, on: [memory.id]) } }
            Button(String(localized: "Delete"), role: .destructive) { Task { await vault.perform(.delete, on: [memory.id]) } }
        case .active:
            Button(String(localized: "Archive")) { Task { await vault.perform(.archive, on: [memory.id]) } }
            Button(String(localized: "Delete"), role: .destructive) { Task { await vault.perform(.delete, on: [memory.id]) } }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !vault.query.isEmpty {
            ContentUnavailableView.search(text: vault.query)
        } else if vault.hasFilters {
            ContentUnavailableView(String(localized: "No memories match these filters"), systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text(String(localized: "Clear the filters to see everything.")))
        } else {
            switch vault.status {
            case .active:
                ContentUnavailableView {
                    Label(String(localized: "Your vault is empty"), systemImage: "archivebox")
                } description: {
                    Text(String(localized: "Answer a few questions to get started, or press ⌥⌘M anytime to remember something."))
                } actions: {
                    Button(String(localized: "Answer a Few Questions")) { model.checklist.showSeedQuestions = true }
                }
            case .archived:
                ContentUnavailableView(String(localized: "Nothing archived"), systemImage: "archivebox",
                                       description: Text(String(localized: "Archived memories are kept but never shared with agents.")))
            case .expired:
                ContentUnavailableView(String(localized: "Nothing expired"), systemImage: "clock",
                                       description: Text(String(localized: "Memories past their expiry date appear here. Agents don't get them.")))
            case .recentlyDeleted:
                ContentUnavailableView(String(localized: "Recently Deleted is empty"), systemImage: "trash",
                                       description: Text(String(localized: "Deleted memories stay here for 30 days, then they're gone for good.")))
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if vault.selection.count == 1, let id = vault.selection.first {
            MemoryDetailView(model: model, memoryID: id)
                .id(id)
        } else if vault.selection.count > 1 {
            ContentUnavailableView(String(localized: "\(vault.selection.count) memories selected"), systemImage: "square.stack",
                                   description: Text(String(localized: "Use the bar above the list to change them together.")))
        } else {
            ContentUnavailableView(String(localized: "No memory selected"), systemImage: "doc.text",
                                   description: Text(String(localized: "Select a memory to read or edit it.")))
        }
    }
}

/// One row: title, a one-line preview, category chips, sensitivity, kind, expiry and updated time.
struct MemoryRow: View {
    let memory: Memory
    let model: AppModel
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: memory.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
                .help(memory.kind.title)
                .accessibilityLabel(memory.kind.title)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(memory.title).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(RelativeTime.short(memory.updatedAt, now: now))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(RelativeTime.full(memory.updatedAt))
                }
                Text(memory.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    SensitivityBadge(sensitivity: memory.sensitivity)
                    ForEach(memory.categoryKeys.prefix(3), id: \.self) { key in
                        Pill(label: model.categoryName(key))
                    }
                    if memory.categoryKeys.count > 3 {
                        Text("+\(memory.categoryKeys.count - 3)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let expiry = ExpiryText.text(memory, now: now) {
                        Text(expiry.text).font(.caption)
                            .foregroundStyle(expiry.expired ? Color.red : Color.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

enum ExpiryText {
    /// "expires in 3 days" or "Expired".
    static func text(_ memory: Memory, now: Date) -> (text: String, expired: Bool)? {
        guard let expiresAt = memory.expiresAt else { return nil }
        if memory.isExpired(at: now) { return (String(localized: "Expired"), true) }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                                   to: Calendar.current.startOfDay(for: expiresAt)).day ?? 0
        switch days {
        case ...0: return (String(localized: "expires today"), false)
        case 1: return (String(localized: "expires tomorrow"), false)
        case 2...30: return (String(localized: "expires in \(days) days"), false)
        default: return (String(localized: "expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))"), false)
        }
    }
}

/// A pop-up of toggles: "Category", or "Category (2)" when some are chosen.
struct FilterMenu<Value: Hashable>: View {
    let title: String
    let options: [(Value, String)]
    @Binding var selection: Set<Value>

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Toggle(label, isOn: Binding(get: { selection.contains(value) },
                                            set: { on in if on { selection.insert(value) } else { selection.remove(value) } }))
            }
            if !selection.isEmpty {
                Divider()
                Button(String(localized: "Show All")) { selection = [] }
            }
        } label: {
            Text(selection.isEmpty ? title : String(localized: "\(title) (\(selection.count))"))
        }
        .fixedSize()
        .accessibilityLabel(selection.isEmpty ? title : String(localized: "\(title), \(selection.count) chosen"))
    }
}

/// A search field with a magnifier and a clear button.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .accessibilityLabel(prompt)
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.separator))
    }
}

/// Archive, Delete, Move to Category and Change Sensitivity for several memories (FR-V-14).
struct BulkBar: View {
    let model: AppModel
    let ids: Set<UUID>
    let status: VaultModel.StatusChoice
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 8) {
            Text(String(localized: "\(ids.count) selected")).font(.callout.weight(.medium))
            Spacer(minLength: 8)
            switch status {
            case .recentlyDeleted:
                Button(String(localized: "Restore")) { run(.restore) }
                Button(String(localized: "Delete Now"), role: .destructive) { confirmDelete = true }
            case .archived:
                Button(String(localized: "Restore")) { run(.restore) }
                Button(String(localized: "Delete"), role: .destructive) { run(.delete) }
            case .active, .expired:
                Button(String(localized: "Archive")) { run(.archive) }
                Menu(String(localized: "Category")) {
                    ForEach(model.categories) { category in
                        Button(String(localized: "Move to \(category.name)")) { run(.moveToCategory(category.key)) }
                    }
                }
                .fixedSize()
                Menu(String(localized: "Sensitivity")) {
                    ForEach(Sensitivity.allCases, id: \.self) { level in
                        Button(level.title) { run(.sensitivity(level)) }
                    }
                }
                .fixedSize()
                Button(String(localized: "Delete"), role: .destructive) { run(.delete) }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .confirmationDialog(String(localized: "Delete \(ids.count) memories now?"), isPresented: $confirmDelete) {
            Button(String(localized: "Delete Now"), role: .destructive) { run(.deleteNow) }
        } message: {
            Text(String(localized: "They're removed for good, with their history. This can't be undone."))
        }
    }

    private func run(_ action: VaultModel.BulkAction) {
        let ids = ids
        Task { await model.vault.perform(action, on: ids) }
    }
}
