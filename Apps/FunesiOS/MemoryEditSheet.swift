import FunesPhone
import FunesProtocol
import SwiftUI

/// Editing a memory's fields: the memory detail's Edit, and the Inbox's Edit & Save. The Mac
/// validates what's saved (FR-iOS-08); a failed save shows why and keeps the text.
struct MemoryEditSheet: View {
    let title: LocalizedStringKey
    let saveLabel: LocalizedStringKey
    @Binding var draft: MemoryEditDraft
    let original: MemoryEditDraft
    let categories: CategoryList
    let busy: Bool
    let error: String?
    let save: () async -> Void
    let cancel: () -> Void
    @FocusState private var field: Field?

    private enum Field { case title, body }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                        .font(.headline)
                        .focused($field, equals: .title)
                    TextField("Text", text: $draft.body, axis: .vertical)
                        .lineLimit(4...14)
                        .focused($field, equals: .body)
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if let problem = draft.problem {
                        Text(Self.text(problem))
                    }
                }
                Section {
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(MemoryKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Sensitivity", selection: $draft.sensitivity) {
                        ForEach(Sensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text(draft.sensitivity.explanation)
                }
                Section("Categories") {
                    ForEach(choices, id: \.self) { key in
                        Button {
                            toggle(key)
                        } label: {
                            HStack {
                                Text(categories.name(key)).foregroundStyle(.primary)
                                Spacer()
                                if draft.categories.contains(key) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityAddTraits(draft.categories.contains(key) ? .isSelected : [])
                    }
                }
                Section {
                    Toggle("Expires", isOn: Binding(
                        get: { draft.expiresAt != nil },
                        set: { draft.expiresAt = $0 ? (draft.expiresAt ?? Calendar.current.date(byAdding: .month, value: 1, to: Date())) : nil }))
                    if let expiry = draft.expiresAt {
                        DatePicker("Expires on", selection: Binding(get: { expiry }, set: { draft.expiresAt = $0 }),
                                   in: Date()..., displayedComponents: .date)
                    }
                } footer: {
                    Text("An expired memory is never shared with agents.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(draft != original)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                // Return adds a line in Text, so the keyboard has its own way out.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { field = nil }.bold()
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(saveLabel) { Task { await save() } }
                            .disabled(draft.problem != nil)
                    }
                }
            }
        }
    }

    /// The vault's categories, plus any the memory has that the list doesn't know.
    private var choices: [String] {
        let known = categories.all.map(\.key)
        return known + draft.categories.filter { !known.contains($0) }
    }

    private func toggle(_ key: String) {
        if let index = draft.categories.firstIndex(of: key) {
            draft.categories.remove(at: index)
        } else {
            draft.categories.append(key)
        }
    }

    static func text(_ problem: MemoryEditDraft.Problem) -> String {
        switch problem {
        case .emptyTitle: String(localized: "Add a title.")
        case .emptyBody: String(localized: "Add the text to remember.")
        case .noCategory: String(localized: "Choose at least one category.")
        }
    }
}
