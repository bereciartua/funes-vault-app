import FunesCore
import SwiftUI

/// Six optional questions (FR-O-02, memory processing §6), then the categories agents should never
/// see. Each answer becomes a suggestion with a preset kind, category and sensitivity, reviewed in
/// the Inbox like any other. The never-see step sets rules, not a memory: every agent gets Deny for
/// those categories, and new agents start with it (UX review F4).
struct SeedQuestionsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var answers: [String: String] = [:]
    @State private var error: String?
    @State private var saving = false
    @State private var neverShare: Set<String> = []
    @State private var loadedNeverShare: Set<String>?

    private var answered: Int { answers.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "A Few Questions")).font(.title2.weight(.semibold))
            Text(String(localized: "Answer any you like. Each answer goes to your Inbox, where you can edit it before it becomes a memory."))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(SeedQuestion.all) { question in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(Self.prompt(question)).fontWeight(.medium)
                                Spacer()
                                SensitivityBadge(sensitivity: question.sensitivity)
                            }
                            TextField(String(localized: "Your answer"), text: Binding(get: { answers[question.id] ?? "" },
                                                                                      set: { answers[question.id] = $0 }),
                                      axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...6)
                                .accessibilityLabel(Self.prompt(question))
                            Text(String(localized: "Saved as \(question.kind.title) in \(model.categoryName(question.categoryKey))"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            // Always in view: Save applies it, so it must never be below the fold.
            neverShareStep
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(answered == 0 ? String(localized: "Save") : String(localized: "Send \(answered) to Inbox")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (answered == 0 && neverShare == loadedNeverShare))
            }
        }
        .padding(24)
        // Fits the main window at its minimum size; the questions scroll.
        .frame(width: 600, height: 540)
        .task {
            let current = (try? await model.services.agents.neverShareCategories()) ?? []
            loadedNeverShare = current
            // Health, Finance and Legal start ticked until the user has chosen.
            neverShare = current.isEmpty ? Set(["health", "finance", "legal"]).intersection(model.categories.map(\.key)) : current
        }
    }

    /// "Which of these should agents never see?": category chips, applied as Deny.
    private var neverShareStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.bottom, 4)
            Text(String(localized: "Which of these should agents never see?")).fontWeight(.medium)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(model.categories) { category in
                    Toggle(category.name, isOn: Binding(get: { neverShare.contains(category.key) }, set: { on in
                        if on { neverShare.insert(category.key) } else { neverShare.remove(category.key) }
                    }))
                    .toggleStyle(.checkbox)
                }
            }
            Text(String(localized: "Every agent gets Deny for these, and new agents start with it. Nothing you tick here is saved as a memory, and you can change it for each agent in its Access tab."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The prompts in the user's language (the catalog keeps the English text in FunesCore).
    static func prompt(_ question: SeedQuestion) -> String {
        switch question.id {
        case "collaboration_style": String(localized: "How do you like AI assistants to collaborate with you?")
        case "communication_preferences": String(localized: "What tone, level of detail, or format do you usually prefer?")
        case "software_development_preferences": String(localized: "What should coding assistants know about how you build software?")
        case "current_projects": String(localized: "Which current projects should your vault remember, and why do they matter?")
        case "life_constraints": String(localized: "Are there practical constraints that often shape your work or availability?")
        case "long_term_goals": String(localized: "What long-term goals should assistants keep in mind when helping you?")
        default: question.prompt
        }
    }

    private func save() {
        saving = true
        let pending = SeedQuestion.all.compactMap { question -> (SeedQuestion, String)? in
            let answer = (answers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? nil : (question, answer)
        }
        let neverShare = neverShare, changedNeverShare = neverShare != loadedNeverShare
        Task {
            var failed: [String] = []
            if changedNeverShare {
                do {
                    try await model.services.agents.setNeverShareCategories(neverShare, applyToAgents: true, now: Date())
                    loadedNeverShare = neverShare
                } catch {
                    failed.append(ErrorText.message(error))
                }
            }
            for (question, answer) in pending {
                do {
                    try await model.services.suggestions.seed(question, answer: answer, now: Date())
                    answers[question.id] = nil
                } catch {
                    failed.append(ErrorText.message(error))
                }
            }
            saving = false
            if failed.isEmpty {
                await model.refresh()
                dismiss()
                if !pending.isEmpty {
                    model.preferences.set(Preferences.Key.checklistSeeded, true)
                    model.show(.inbox)
                }
            } else {
                error = failed.first
            }
        }
    }
}
