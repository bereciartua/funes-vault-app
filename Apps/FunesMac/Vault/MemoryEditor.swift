import FunesCore
import FunesProtocol
import SwiftUI

/// The editable fields of a memory, for the detail pane and New Memory.
struct MemoryForm: Equatable {
    var title = ""
    var body = ""
    var kind: MemoryKind = .fact
    var categoryKeys: [String] = []
    var sensitivity: Sensitivity = .low
    /// False until the user picks a level: a new memory's level follows its categories (FR-V-07).
    var sensitivityChosen = false
    var expires = false
    var expiresAt = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()

    init() {}

    init(_ memory: Memory) {
        title = memory.title
        body = memory.body
        kind = memory.kind
        categoryKeys = memory.categoryKeys
        sensitivity = memory.sensitivity
        sensitivityChosen = true
        expires = memory.expiresAt != nil
        if let date = memory.expiresAt { expiresAt = date }
    }

    var expiry: Date? { expires ? expiresAt : nil }

    /// The date picker's value counts only while an expiry is set.
    static func == (a: MemoryForm, b: MemoryForm) -> Bool {
        a.title == b.title && a.body == b.body && a.kind == b.kind && a.categoryKeys == b.categoryKeys
            && a.sensitivity == b.sensitivity && a.expiry == b.expiry
    }

    /// LOW, raised to the highest default of the chosen categories.
    static func defaultSensitivity(_ keys: [String], categories: [MemoryCategory]) -> Sensitivity {
        max(.low, categories.filter { keys.contains($0.key) }.map(\.defaultSensitivity).max() ?? .low)
    }

    /// What's wrong before saving, in the field's words; the store checks again.
    var problem: String? {
        let title = InputLimits.length(of: self.title.trimmingCharacters(in: .whitespacesAndNewlines))
        if title == 0 { return String(localized: "Add a title.") }
        if title > InputLimits.title.upperBound { return String(localized: "The title is longer than 180 characters.") }
        let body = InputLimits.length(of: self.body.trimmingCharacters(in: .whitespacesAndNewlines))
        if body == 0 { return String(localized: "Add the text to remember.") }
        if body > InputLimits.body.upperBound { return String(localized: "The text is longer than 10,000 characters.") }
        if categoryKeys.isEmpty { return String(localized: "Choose at least one category.") }
        return nil
    }

    func draft(source: MemorySource = .manual) -> MemoryDraft {
        MemoryDraft(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: body.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, categoryKeys: categoryKeys,
                    sensitivity: sensitivity, expiresAt: expiry, source: source)
    }

    func edit(from memory: Memory) -> MemoryEdit {
        MemoryEdit(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                   body: body.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, categoryKeys: categoryKeys,
                   sensitivity: sensitivity, expiresAt: .some(expiry))
    }
}

/// Title, text with a counter, kind, categories, sensitivity with its explanation, and expiry.
struct MemoryEditor: View {
    @Binding var form: MemoryForm
    let categories: [MemoryCategory]
    var editable = true
    @FocusState private var titleFocused: Bool
    var focusTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Title")).font(.callout).foregroundStyle(.secondary)
                TextField(String(localized: "Title"), text: $form.title, prompt: Text(String(localized: "A short name for it")))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($titleFocused)
                    .disabled(!editable)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(String(localized: "Text")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    let count = InputLimits.length(of: form.body)
                    Text("\(count.formatted()) / \(InputLimits.body.upperBound.formatted())")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(count > InputLimits.body.upperBound ? Color.red : Color.secondary)
                        .accessibilityLabel(String(localized: "\(count) of 10,000 characters"))
                }
                TextEditor(text: $form.body)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 110, maxHeight: 260)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.separator))
                    .disabled(!editable)
                    .accessibilityLabel(String(localized: "Text"))
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text(String(localized: "Kind")).foregroundStyle(.secondary)
                    Picker(String(localized: "Kind"), selection: $form.kind) {
                        ForEach(MemoryKind.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!editable)
                }
                GridRow {
                    Text(String(localized: "Categories")).foregroundStyle(.secondary)
                    CategoryTokens(keys: $form.categoryKeys, categories: categories, editable: editable)
                }
                GridRow(alignment: .top) {
                    Text(String(localized: "Sensitivity")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        SensitivityPicker(selection: Binding(get: { form.sensitivity }, set: {
                            form.sensitivity = $0
                            form.sensitivityChosen = true
                        }))
                        .disabled(!editable)
                        Text(form.sensitivity.explanation).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Text(String(localized: "Expires")).foregroundStyle(.secondary)
                    HStack {
                        Picker(String(localized: "Expires"), selection: $form.expires) {
                            Text(String(localized: "Never")).tag(false)
                            Text(String(localized: "On a date")).tag(true)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if form.expires {
                            DatePicker(String(localized: "Expiry date"), selection: $form.expiresAt, displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.field)
                        }
                    }
                    .disabled(!editable)
                }
            }
        }
        .onChange(of: form.categoryKeys) { _, keys in
            if !form.sensitivityChosen { form.sensitivity = MemoryForm.defaultSensitivity(keys, categories: categories) }
        }
        .onAppear { if focusTitle { titleFocused = true } }
    }
}

/// The memory's categories as removable chips, with a menu to add one (the "category token field").
struct CategoryTokens: View {
    @Binding var keys: [String]
    let categories: [MemoryCategory]
    var editable = true

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                HStack(spacing: 3) {
                    Text(categories.first { $0.key == key }?.name ?? key)
                    if editable {
                        Button { keys.removeAll { $0 == key } } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Remove \(categories.first { $0.key == key }?.name ?? key)"))
                    }
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }
            if editable {
                let available = categories.filter { !keys.contains($0.key) }
                Menu {
                    ForEach(available) { category in
                        Button(category.name) { keys.append(category.key) }
                    }
                } label: {
                    Label(String(localized: "Add"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(available.isEmpty || keys.count >= InputLimits.memoryCategories)
                .accessibilityLabel(String(localized: "Add a category"))
            }
        }
    }
}

/// Lays children out in rows, wrapping when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The six levels as a segmented control, or a pop-up where that doesn't fit.
struct SensitivityPicker: View {
    @Binding var selection: Sensitivity

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented).fixedSize()
            picker.pickerStyle(.menu).fixedSize()
        }
    }

    private var picker: some View {
        Picker(String(localized: "Sensitivity"), selection: $selection) {
            ForEach(Sensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .accessibilityLabel(String(localized: "Sensitivity"))
    }
}
