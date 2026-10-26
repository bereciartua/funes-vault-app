import Foundation
import FunesCore
import FunesProtocol
import SwiftUI

/// The profile's words (04-ux-mac.md ▸ Settings ▸ About You): field names, values as shown, and
/// lists of fields ("name and pronouns").
enum ProfileText {
    static func title(_ field: ProfileField) -> String {
        switch field {
        case .name: String(localized: "Name")
        case .pronouns: String(localized: "Pronouns")
        case .languages: String(localized: "Languages")
        case .location: String(localized: "Location")
        case .timeZone: String(localized: "Time zone")
        case .occupation: String(localized: "Occupation")
        }
    }

    /// The field in a sentence: "name", "time zone".
    static func word(_ field: ProfileField) -> String {
        switch field {
        case .name: String(localized: "name")
        case .pronouns: String(localized: "pronouns")
        case .languages: String(localized: "languages")
        case .location: String(localized: "location")
        case .timeZone: String(localized: "time zone")
        case .occupation: String(localized: "occupation")
        }
    }

    /// "name, pronouns" (Activity's detail).
    static func list(_ fields: [ProfileField]) -> String {
        fields.sorted().map(word).joined(separator: ", ")
    }

    /// "your name and pronouns" (the Share panel).
    static func sentence(_ fields: [ProfileField]) -> String {
        let words = fields.sorted().map { $0 == .name ? String(localized: "your name") : word($0) }
        return words.formatted(.list(type: .and))
    }

    /// The given and family name in the locale's order: "Martin Bereciartua".
    static func fullName(_ p: Profile) -> String? {
        guard p.givenName != nil || p.familyName != nil else { return p.preferredName }
        var components = PersonNameComponents()
        components.givenName = p.givenName
        components.familyName = p.familyName
        return components.formatted(.name(style: .medium))
    }

    static func language(_ tag: String) -> String {
        Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    /// "Automatic (Europe/Lisbon)" or the zone's id.
    static func timeZone(_ id: String) -> String {
        id == Profile.automaticTimeZone ? String(localized: "Automatic (\(TimeZone.current.identifier))") : id
    }

    /// A field's value as the access editor shows it, or "not set".
    static func value(_ field: ProfileField, in p: Profile) -> String {
        let text: String? = switch field {
        case .name: fullName(p)
        case .pronouns: p.pronouns
        case .languages: p.languages.isEmpty ? nil : p.languages.map(language).joined(separator: " · ")
        case .location: p.location
        case .timeZone: timeZone(p.timeZone)
        case .occupation: p.occupation
        }
        return text ?? String(localized: "not set")
    }

    /// "1 agent", "3 agents".
    static func agents(_ count: Int) -> String {
        count == 1 ? String(localized: "1 agent") : String(localized: "\(count) agents")
    }

    static func problem(_ problem: Profile.Problem) -> String {
        switch problem {
        case let .secret(patterns): SecretText.message(patterns)
        case let .tooLong(limit): String(localized: "At most \(limit) characters.")
        }
    }
}

/// Settings ▸ About You (FR-U-01, ADR-0026): what Funes and your agents call you. Every field
/// saves when it loses focus or on Return; a field the secret scanner refuses keeps its saved
/// value, with the scanner's message under it.
struct AboutYouSettings: View {
    let model: AppModel
    @State private var draft = Profile()
    @State private var problems: [Profile.TextField: Profile.Problem] = [:]
    @State private var error: String?
    @State private var sharing: [ProfileField: [Agent]] = [:]
    @State private var choosingZone = false
    @FocusState private var focus: Profile.TextField?

    /// The macOS account's name, as a suggestion only (never saved by itself).
    private let suggestion = Profile.suggested(fromAccountName: NSFullUserName())

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Name")) {
                    HStack {
                        field(.givenName, String(localized: "Given name"), placeholder: suggestion?.givenName)
                        field(.familyName, String(localized: "Family name"), placeholder: suggestion?.familyName)
                    }
                }
                problemLine(.givenName)
                problemLine(.familyName)
                LabeledContent(String(localized: "Call me")) {
                    field(.preferredName, String(localized: "Call me"),
                          placeholder: draft.givenName ?? suggestion?.givenName)
                }
                problemLine(.preferredName)
                if let suggestion, model.profile.isEmpty, let name = ProfileText.fullName(suggestion) {
                    Button(String(localized: "Use “\(name)”")) { use(suggestion) }
                        .buttonStyle(.link)
                }
                LabeledContent(String(localized: "Pronouns")) {
                    field(.pronouns, String(localized: "Pronouns"), placeholder: String(localized: "e.g. she/her"))
                }
                problemLine(.pronouns)
                LabeledContent(String(localized: "Languages")) { LanguageList(languages: $draft.languages, save: save) }
                LabeledContent(String(localized: "Location")) {
                    field(.location, String(localized: "Location"), placeholder: String(localized: "e.g. Lisbon, Portugal"))
                }
                problemLine(.location)
                LabeledContent(String(localized: "Time zone")) {
                    Button(ProfileText.timeZone(draft.timeZone)) { choosingZone = true }
                        .popover(isPresented: $choosingZone, arrowEdge: .bottom) {
                            TimeZonePicker(selection: $draft.timeZone) {
                                choosingZone = false
                                save()
                            }
                        }
                        .accessibilityLabel(String(localized: "Time zone: \(ProfileText.timeZone(draft.timeZone))"))
                }
                LabeledContent(String(localized: "Occupation")) {
                    field(.occupation, String(localized: "Occupation"),
                          placeholder: String(localized: "e.g. Staff engineer at a climate startup"))
                }
                problemLine(.occupation)
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            } footer: {
                Text(String(localized: "Everything here is optional. Home greets you by the name in Call me, or your given name."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(String(localized: "Shared with")) {
                SharedWithRow(model: model, sharing: sharing)
                Text(String(localized: "Agents get only the fields you tick in each one's Access tab, with their answers, without asking. New agents get your name."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = model.profile }
        .task(id: model.dataGeneration) {
            sharing = (try? await model.services.profiles.sharing()) ?? [:]
            if focus == nil { draft = model.profile }
        }
        .onChange(of: focus) { old, _ in if old != nil { save() } }
    }

    private func field(_ key: Profile.TextField, _ label: String, placeholder: String?) -> some View {
        TextField(label, text: Binding(get: { draft[text: key] ?? "" }, set: { draft[text: key] = $0 }),
                  prompt: placeholder.map { Text($0) })
            .labelsHidden()
            .focused($focus, equals: key)
            .onSubmit(save)
            .accessibilityLabel(label)
    }

    @ViewBuilder
    private func problemLine(_ key: Profile.TextField) -> some View {
        if let problem = problems[key] {
            Text(ProfileText.problem(problem)).font(.callout).foregroundStyle(.red)
        }
    }

    private func use(_ suggestion: Profile) {
        draft.givenName = suggestion.givenName
        draft.familyName = suggestion.familyName
        save()
    }

    /// Saves what's valid; a refused field goes back to its saved value, with its message.
    private func save() {
        let saved = model.profile
        var candidate = draft.normalized()
        problems = candidate.problems()
        for key in problems.keys { candidate[text: key] = saved[text: key] }
        guard candidate.normalized() != saved.normalized() || !problems.isEmpty else { return }
        Task {
            do {
                let stored = try await model.services.profiles.save(candidate, now: Date())
                model.profile = stored
                draft = stored
                error = nil
            } catch {
                self.error = ErrorText.message(error)
            }
        }
    }
}

/// The ordered languages: add from the system's languages, remove, drag to reorder. The first is
/// the one you write in most.
private struct LanguageList: View {
    @Binding var languages: [String]
    let save: () -> Void

    private static let choices: [String] = {
        let codes = Locale.LanguageCode.isoLanguageCodes.filter { $0.identifier.count == 2 }.map(\.identifier)
        return codes.sorted { ProfileText.language($0).localizedCompare(ProfileText.language($1)) == .orderedAscending }
    }()

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if languages.isEmpty {
                Text(String(localized: "None")).foregroundStyle(.secondary)
            }
            ForEach(Array(languages.enumerated()), id: \.element) { index, tag in
                HStack(spacing: 6) {
                    Text(ProfileText.language(tag))
                    if index == 0, languages.count > 1 {
                        Text(String(localized: "most used")).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(index == 0)
                        .accessibilityLabel(String(localized: "Move \(ProfileText.language(tag)) up"))
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(index == languages.count - 1)
                        .accessibilityLabel(String(localized: "Move \(ProfileText.language(tag)) down"))
                    Button {
                        languages.remove(at: index)
                        save()
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "Remove \(ProfileText.language(tag))"))
                }
            }
            if languages.count < Profile.maxLanguages {
                Menu(String(localized: "Add Language")) {
                    ForEach(Self.choices.filter { !languages.contains($0) }, id: \.self) { tag in
                        Button(ProfileText.language(tag)) {
                            languages.append(tag)
                            save()
                        }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard languages.indices.contains(target) else { return }
        languages.swapAt(index, target)
        save()
    }
}

/// Automatic (following the Mac) or a time zone from a searchable list.
private struct TimeZonePicker: View {
    @Binding var selection: String
    let done: () -> Void
    @State private var query = ""

    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query.replacingOccurrences(of: " ", with: "_")) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(String(localized: "Search"), text: $query).textFieldStyle(.roundedBorder)
            List {
                row(Profile.automaticTimeZone, ProfileText.timeZone(Profile.automaticTimeZone))
                ForEach(matches, id: \.self) { row($0, $0.replacingOccurrences(of: "_", with: " ")) }
            }
            .frame(width: 300, height: 320)
        }
        .padding(12)
    }

    private func row(_ id: String, _ title: String) -> some View {
        Button {
            selection = id
            done()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if id == selection { Image(systemName: "checkmark") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Name 3 agents · Pronouns 1 agent · the others with none." Each count lists its agents, with
/// a link to their Access tab.
private struct SharedWithRow: View {
    let model: AppModel
    let sharing: [ProfileField: [Agent]]
    @State private var shown: ProfileField?

    var body: some View {
        let fields = ProfileField.allCases.filter { !(sharing[$0] ?? []).isEmpty }
        if fields.isEmpty {
            Text(String(localized: "No agent gets any of it yet."))
        } else {
            HStack(spacing: 4) {
                ForEach(Array(fields.enumerated()), id: \.element) { index, field in
                    let agents = sharing[field] ?? []
                    Text(ProfileText.title(field))
                    Button(ProfileText.agents(agents.count)) { shown = field }
                        .buttonStyle(.link)
                        .help(agents.map(\.name).formatted(.list(type: .and)))
                        .popover(isPresented: Binding(get: { shown == field }, set: { if !$0 { shown = nil } })) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(agents) { agent in
                                    Button(agent.name) {
                                        shown = nil
                                        model.agentTab = .access
                                        model.showAgent(agent.id)
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                            .padding(12)
                        }
                    if index < fields.count - 1 { Text("·").foregroundStyle(.secondary) }
                }
                if fields.count < ProfileField.allCases.count {
                    Text(String(localized: "· the others with none.")).foregroundStyle(.secondary)
                }
            }
        }
    }
}
