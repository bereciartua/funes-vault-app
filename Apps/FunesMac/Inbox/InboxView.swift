import FunesCore
import FunesProtocol
import SwiftUI

/// The Inbox (04-ux-mac.md, FR-I-01..05): suggestions by source, each a card to edit and Apply,
/// Reject or put off until Later. Nothing is ever applied without the user.
struct InboxView: View {
    @Bindable var model: AppModel
    @FocusState private var listFocused: Bool

    private var inbox: InboxModel { model.inboxState }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            if model.inbox.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                        ForEach(inbox.grouped(model.inbox), id: \.0) { group, items in
                            Text(group.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.top, 6)
                            ForEach(items) { suggestion in
                                SuggestionCard(model: model, suggestion: suggestion)
                                    .id(suggestion.id)
                            }
                        }
                        restorable
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.delete) {
                    // ⌫ rejects the focused card, but only while no text field is being edited.
                    guard listFocused, let id = inbox.focused, let item = model.inbox.first(where: { $0.id == id }) else {
                        return .ignored
                    }
                    Task { try? await inbox.reject(item) }
                    return .handled
                }
            }
        }
        .background(Palette.pane)
        .task { await inbox.load() }
        .onChange(of: model.dataGeneration) { _, _ in Task { await inbox.load() } }
    }

    private var header: some View {
        PaneHeader(title: String(localized: "Inbox"), subtitle: subtitle) {
            if !inbox.selection.isEmpty {
                let items = model.inbox.filter { inbox.selection.contains($0.id) }
                Button(String(localized: "Reject \(items.count)")) { Task { await inbox.bulk(apply: false, items) } }
                Button(String(localized: "Apply \(items.count)")) { Task { await inbox.bulk(apply: true, items) } }
                    .buttonStyle(.borderedProminent)
                Button(String(localized: "Deselect")) { inbox.selection = [] }.buttonStyle(.link)
            } else if model.inbox.count > 1 {
                Button(String(localized: "Select All")) { inbox.selection = Set(model.inbox.map(\.id)) }
            }
        }
    }

    private var subtitle: String {
        if let result = inbox.result { return result }
        switch model.inbox.count {
        case 0: return String(localized: "Nothing waiting")
        case 1: return String(localized: "1 suggestion waiting for you")
        default: return String(localized: "\(model.inbox.count) suggestions waiting for you")
        }
    }

    @ViewBuilder
    private var empty: some View {
        VStack(spacing: 18) {
            ContentUnavailableView(String(localized: "Your Inbox is empty"), systemImage: "tray",
                                   description: Text(String(localized: "Suggestions from agents, captures and imports wait here until you apply or reject them.")))
            if !inbox.restorable.isEmpty {
                ScrollView { restorable.padding(20).frame(maxWidth: 820) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var restorable: some View {
        if !inbox.restorable.isEmpty {
            DisclosureGroup(String(localized: "Expired suggestions (\(inbox.restorable.count))")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Suggestions expire after 30 days. You can restore them for 7 more."))
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(inbox.restorable) { item in
                        HStack {
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Button(String(localized: "Restore")) { Task { await inbox.restore(item) } }
                                .accessibilityLabel(String(localized: "Restore \(item.title)"))
                        }
                    }
                }
                .padding(.top, 6)
            }
            .padding(.top, 10)
        }
    }
}

/// One suggestion: its source, the proposal (editable), evidence as quoted data, a duplicate
/// hint, the engine that proposed it, and for a correction the change it makes.
struct SuggestionCard: View {
    let model: AppModel
    let suggestion: Suggestion
    @State private var form: SuggestionDraft?
    @State private var target: Memory?
    @State private var similar: [Memory] = []
    @State private var error: String?
    @State private var applied: [Memory] = []

    private var inbox: InboxModel { model.inboxState }
    private var isLater: Bool { inbox.later.contains(suggestion.id) }
    private var isFocused: Bool { inbox.focused == suggestion.id }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(isOn: Binding(get: { inbox.selection.contains(suggestion.id) }, set: { on in
                    if on { inbox.selection.insert(suggestion.id) } else { inbox.selection.remove(suggestion.id) }
                })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "Select \(suggestion.title)"))
                Text(sourceLine).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if isLater { Pill(label: String(localized: "Later")) }
                if let engine = EngineText.text(suggestion, agentName: suggestion.agentID.map(model.agentName),
                                                providerName: model.providerName) {
                    Text(engine).font(.caption).foregroundStyle(.secondary)
                }
            }
            if isLater {
                HStack {
                    Text(suggestion.title).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Button(String(localized: "Review Now")) { inbox.later.remove(suggestion.id) }
                }
            } else if let binding = formBinding {
                if let target { CorrectionDiff(old: target, new: binding.wrappedValue) }
                fields(binding)
                if let evidence = suggestion.evidence, !evidence.isEmpty {
                    Text(String(localized: "Why, as reported: “\(evidence)”"))
                        .font(.callout).italic().foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let purpose = suggestion.purpose, !purpose.isEmpty {
                    Text(String(localized: "Purpose given by the agent: “\(purpose)”"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !similar.isEmpty { hint(String(localized: "Similar memory exists:"), similar) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                }
                actions
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(isFocused ? 0.7 : 0), lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { inbox.focused = suggestion.id }
        .task(id: suggestion.id) { await load() }
        // Background classification changes the proposal under the same id: an untouched card
        // shows the new values (PR #3 review 4304175704).
        .onChange(of: suggestion) { _, current in form = inbox.draft(for: current) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Suggestion: \(suggestion.title)"))
    }

    private var formBinding: Binding<SuggestionDraft>? {
        guard form != nil else { return nil }
        return Binding(get: { form! }, set: { value in
            form = value
            inbox.drafts[suggestion.id] = value
        })
    }

    private func fields(_ form: Binding<SuggestionDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(String(localized: "Title"), text: form.title)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .onTapGesture { inbox.focused = suggestion.id }
            TextField(String(localized: "Text"), text: form.body, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...8)
                .onTapGesture { inbox.focused = suggestion.id }
            HStack(spacing: 10) {
                Picker(String(localized: "Kind"), selection: form.kind) {
                    ForEach(MemoryKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                SensitivityPicker(selection: form.sensitivity)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            CategoryTokens(keys: form.categoryKeys, categories: model.categories)
                .controlSize(.small)
            Text(form.wrappedValue.sensitivity.explanation).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if !applied.isEmpty {
                hint(String(localized: "Applied. Similar memory exists:"), applied)
            }
            Spacer()
            Button(String(localized: "Later")) {
                inbox.later.insert(suggestion.id)
                inbox.selection.remove(suggestion.id)
            }
            Button(String(localized: "Reject"), role: .destructive) { reject() }
                .keyboardShortcut(isFocused ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                .help(String(localized: "Reject (⌫ or ⌘⌫)"))
            if target != nil {
                Button(String(localized: "Keep Both")) { apply(.keepBoth) }
                Button(String(localized: "Replace")) { apply(.replace) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
            } else {
                Button(String(localized: "Apply")) { apply(.keepBoth) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .help(String(localized: "Apply (⌘⏎)"))
                    .disabled(form.map { $0.title.trimmingCharacters(in: .whitespaces).isEmpty
                        || $0.body.trimmingCharacters(in: .whitespaces).isEmpty || $0.categoryKeys.isEmpty } ?? true)
            }
        }
    }

    private func hint(_ text: String, _ memories: [Memory]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc").foregroundStyle(.orange)
            Text(text)
            ForEach(memories.prefix(2)) { memory in
                Button(memory.title) { model.showMemory(memory.id) }.buttonStyle(.link)
            }
        }
        .font(.callout)
    }

    private var sourceLine: String {
        let time = RelativeTime.short(suggestion.createdAt, now: model.now)
        switch suggestion.origin {
        case .agent:
            let name = suggestion.agentID.map(model.agentName) ?? String(localized: "an agent")
            return suggestion.targetMemoryID == nil ? String(localized: "Suggested by \(name) · \(time)")
                                                    : String(localized: "Correction from \(name) · \(time)")
        case .captureMac: return String(localized: "Captured on this Mac · \(time)")
        case .captureIPhone: return String(localized: "Captured on iPhone · \(time)")
        case .seedQuestion: return String(localized: "Your answer · \(time)")
        case .consolidation: return String(localized: "Cleanup suggestion · \(time)")
        case .import:
            switch suggestion.importRunID.flatMap({ inbox.importSources[$0] }) {
            case .chatgpt: return String(localized: "Imported from ChatGPT · \(time)")
            case .claude: return String(localized: "Imported from Claude · \(time)")
            case .markdown: return String(localized: "Imported from Markdown · \(time)")
            case .funes: return String(localized: "Imported from a Funes export · \(time)")
            case nil: return String(localized: "Imported · \(time)")
            }
        }
    }

    private func load() async {
        let services = model.services
        form = inbox.draft(for: suggestion)
        if let id = suggestion.targetMemoryID { target = try? services.store.memory(id: id) }
        var ids = (try? services.store.exactDuplicates(title: suggestion.title, body: suggestion.body)) ?? []
        let names = suggestion.categoryKeys.map(model.categoryName)
        let near = (try? await services.search.nearDuplicates(title: suggestion.title, body: suggestion.body,
                                                               kind: suggestion.kind ?? .fact, categoryNames: names)) ?? []
        for id in near where !ids.contains(id) && id != suggestion.targetMemoryID { ids.append(id) }
        ids.removeAll { $0 == suggestion.targetMemoryID }
        similar = (try? services.store.memories(ids: ids)) ?? []
    }

    private func apply(_ mode: ApplyMode) {
        Task {
            do {
                let result = try await inbox.apply(suggestion, mode: mode)
                error = nil
                if !result.similarMemoryIDs.isEmpty {
                    inbox.result = String(localized: "Applied “\(suggestion.title)”. A similar memory exists.")
                }
            } catch {
                self.error = ErrorText.message(error)
            }
        }
    }

    private func reject() {
        Task {
            do { try await inbox.reject(suggestion) } catch { self.error = ErrorText.message(error) }
        }
    }
}

/// A correction's change: old → new for the title and the text (FR-S-06).
struct CorrectionDiff: View {
    let old: Memory
    let new: SuggestionDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Changes “\(old.title)”")).font(.callout.weight(.medium))
            if old.title != new.title { row(String(localized: "Title"), old.title, new.title) }
            if old.body != new.body { row(String(localized: "Text"), old.body, new.body) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    private func row(_ label: String, _ before: String, _ after: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(before).strikethrough().foregroundStyle(.secondary).font(.callout)
                .accessibilityLabel(String(localized: "Before: \(before)"))
            Text(after).font(.callout)
                .accessibilityLabel(String(localized: "After: \(after)"))
        }
        .textSelection(.enabled)
    }
}
