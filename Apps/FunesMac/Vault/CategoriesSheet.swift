import FunesCore
import FunesProtocol
import SwiftUI

/// Categories (FR-V-05, FR-V-06): rename any, add custom ones, delete custom ones with a
/// replacement for the memories in them.
struct CategoriesSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MemoryCategory?
    @State private var adding = false
    @State private var deleting: MemoryCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Categories")).font(.title2.weight(.semibold))
            Text(String(localized: "Agents' access is set per category. Built-in categories can be renamed; your own can also be deleted."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.categories) { category in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(category.name).fontWeight(.medium)
                                if category.builtin { Pill(label: String(localized: "Built in")) }
                            }
                            if !category.description.isEmpty {
                                Text(category.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(String(localized: "New memories: \(category.defaultSensitivity.title)"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(String(localized: "Rename…")) { editing = category }
                            .accessibilityLabel(String(localized: "Rename \(category.name)"))
                        if !category.builtin {
                            Button(String(localized: "Delete…"), role: .destructive) { deleting = category }
                                .accessibilityLabel(String(localized: "Delete \(category.name)"))
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 280)
            HStack {
                Button { adding = true } label: { Label(String(localized: "Add Category…"), systemImage: "plus") }
                Spacer()
                Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .sheet(item: $editing) { category in CategoryForm(model: model, existing: category) }
        .sheet(isPresented: $adding) { CategoryForm(model: model, existing: nil) }
        .sheet(item: $deleting) { category in DeleteCategoryForm(model: model, category: category) }
    }
}

/// Add or rename a category.
struct CategoryForm: View {
    let model: AppModel
    let existing: MemoryCategory?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var details = ""
    @State private var sensitivity: Sensitivity = .low
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? String(localized: "Add Category") : String(localized: "Rename Category"))
                .font(.title3.weight(.semibold))
            Form {
                TextField(String(localized: "Name"), text: $name)
                TextField(String(localized: "Description"), text: $details, prompt: Text(String(localized: "What belongs here (agents see this)")),
                          axis: .vertical)
                    .lineLimit(2...4)
                if existing == nil {
                    Picker(String(localized: "New memories start at"), selection: $sensitivity) {
                        ForEach(Sensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? String(localized: "Add") : String(localized: "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            name = existing?.name ?? ""
            details = existing?.description ?? ""
        }
    }

    private func save() {
        let store = model.services.store
        do {
            if let existing {
                try store.renameCategory(key: existing.key, name: name, description: details)
            } else {
                let key = MemoryCategory.key(forName: name, existing: Set(model.categories.map(\.key)))
                try store.createCategory(key: key, name: name, description: details, defaultSensitivity: sensitivity)
            }
            model.scheduleRefresh()
            dismiss()
        } catch {
            self.error = ErrorText.message(error)
        }
    }
}

/// Delete a custom category: its memories move to a replacement, or lose it when they have others.
struct DeleteCategoryForm: View {
    let model: AppModel
    let category: MemoryCategory
    @Environment(\.dismiss) private var dismiss
    @State private var replacement: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Delete “\(category.name)”?")).font(.title3.weight(.semibold))
            Text(String(localized: "Memories in it can move to another category. Agents that couldn't read it won't be able to read the replacement either."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(String(localized: "Move its memories to"), selection: $replacement) {
                Text(String(localized: "Don't move them")).tag(String?.none)
                ForEach(model.categories.filter { $0.key != category.key }) { Text($0.name).tag(Optional($0.key)) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Delete"), role: .destructive) { delete() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func delete() {
        do {
            try model.services.store.deleteCategory(key: category.key, replacement: replacement, now: Date())
            model.scheduleRefresh()
            dismiss()
        } catch {
            self.error = ErrorText.message(error)
        }
    }
}
