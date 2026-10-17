import FunesCore
import SwiftUI

/// Seven optional questions (FR-O-02, memory processing §6). Each answer becomes a suggestion with
/// a preset kind, category and sensitivity, reviewed in the Inbox like any other.
struct SeedQuestionsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var answers: [String: String] = [:]
    @State private var error: String?
    @State private var saving = false

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
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(answered == 0 ? String(localized: "Send to Inbox") : String(localized: "Send \(answered) to Inbox")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(answered == 0 || saving)
            }
        }
        .padding(24)
        .frame(width: 600, height: 640)
    }

    /// The prompts in the user's language (the catalog keeps the English text in FunesCore).
    static func prompt(_ question: SeedQuestion) -> String {
        switch question.id {
        case "collaboration_style": String(localized: "How do you like AI assistants to collaborate with you?")
        case "communication_preferences": String(localized: "What tone, level of detail, or format do you usually prefer?")
        case "software_development_preferences": String(localized: "What should coding assistants know about how you build software?")
        case "current_projects": String(localized: "Which current projects should your vault remember, and why do they matter?")
        case "privacy_preferences": String(localized: "What should Funes be especially careful not to share casually?")
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
        Task {
            var failed: [String] = []
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
                model.preferences.set(Preferences.Key.checklistSeeded, true)
                await model.refresh()
                dismiss()
                model.show(.inbox)
            } else {
                error = failed.first
            }
        }
    }
}
