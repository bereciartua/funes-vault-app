import FunesCore
import FunesProtocol
import SwiftUI

/// New Memory (⌘N, FR-V-01): the editor in a sheet. Saving runs the secret scanner; a match
/// names the pattern type and stores nothing.
struct NewMemorySheet: View {
    let model: AppModel
    var created: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var form = MemoryForm()
    @State private var error: String?
    @State private var similar: [Memory] = []
    @State private var savedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "New Memory")).font(.title2.weight(.semibold))
            MemoryEditor(form: $form, categories: model.categories, focusTitle: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            if !similar.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc").foregroundStyle(.orange)
                    Text(String(localized: "Saved. A similar memory exists:"))
                    ForEach(similar.prefix(2)) { other in
                        Button(other.title) {
                            dismiss()
                            model.showMemory(other.id)
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }
            HStack {
                Spacer()
                if savedID != nil {
                    Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(String(localized: "Save")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(form.problem != nil)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            if form.categoryKeys.isEmpty { form.categoryKeys = ["personal_preferences"] }
        }
    }

    private func save() {
        do {
            let memory = try model.services.store.createMemory(form.draft(), now: Date())
            error = nil
            savedID = memory.id
            created(memory.id)
            Task {
                let found = await DuplicateHint.similar(to: memory, in: model)
                if found.isEmpty { dismiss() } else { similar = found }
            }
        } catch {
            self.error = ErrorText.message(error)
        }
    }
}
