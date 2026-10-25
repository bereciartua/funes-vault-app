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
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                        let sections = inbox.grouped(model.inbox)
                        ForEach(sections, id: \.0) { group, items in
                            if group == .tidyUp {
                                TidyUpHeader(model: model).padding(.top, 6)
                            } else {
                                Text(group.title)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                    .padding(.top, 6)
                            }
                            ForEach(items, id: \.key) { entry in
                                switch entry {
                                case let .single(suggestion):
                                    SuggestionCard(model: model, suggestion: suggestion).id(entry.key)
                                case let .group(id, pieces):
                                    GroupCard(model: model, groupID: id, pieces: pieces).id(entry.key)
                                }
                            }
                        }
                        if !sections.contains(where: { $0.0 == .tidyUp }), model.preferences.tidyUpDaily || model.tidyUp.lastRun != nil {
                            TidyUpHeader(model: model).padding(.top, 6)
                        }
                        AppliedAutomaticallyList(model: model)
                        restorable
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                // A card opened from elsewhere (open_in_funes, a Save panel's Edit…) comes into view,
                // a piece's on its group card.
                .onChange(of: inbox.focused) { _, id in
                    guard let id, let entry = inbox.grouped(model.inbox).flatMap(\.1).first(where: { $0.shows(id) }) else { return }
                    withAnimation { proxy.scrollTo(entry.key) }
                }
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
        .task { await model.tidyUp.load() }
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
            if !inbox.restorable.isEmpty || !inbox.applied.isEmpty || model.preferences.tidyUpDaily || model.tidyUp.lastRun != nil {
                ScrollView {
                    VStack(alignment: .leading) {
                        if model.preferences.tidyUpDaily || model.tidyUp.lastRun != nil { TidyUpHeader(model: model) }
                        AppliedAutomaticallyList(model: model)
                        restorable
                    }
                    .padding(20).frame(maxWidth: 820)
                }
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
/// hint, the engine that proposed it, and what it does to the memories it refers to. Each action
/// has its own buttons: Replace / Keep Both only for a correction.
struct SuggestionCard: View {
    let model: AppModel
    let suggestion: Suggestion
    @State private var form: SuggestionDraft?
    @State private var target: Memory?
    /// A merge's sources, a conflict's two memories, an archive's survivor, by id.
    @State private var others: [SuggestionTarget] = []
    @State private var memories: [UUID: Memory] = [:]
    @State private var pieces: [Suggestion] = []
    /// A memory it changes was edited, archived or deleted since it was suggested.
    @State private var stale = false
    /// A conflict's Edit…: the text that replaces the first memory.
    @State private var conflictEdit: (title: String, body: String)?
    @State private var similar: [Memory] = []
    @State private var error: String?
    @State private var applied: [Memory] = []

    private var inbox: InboxModel { model.inboxState }
    /// The tidy-up's engine, reason and what it was computed on (memory processing §9).
    private var tidyUp: TidyUpRecord? { TidyUpRecord.decode(suggestion) }
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
            } else if let state = inbox.processing[suggestion.id] {
                // Not editable or appliable until the split replaces it (memory processing §5.2).
                ProcessingBody(model: model, suggestion: suggestion, state: state)
            } else if let binding = formBinding {
                if stale { staleBanner }
                context(binding)
                if let reason = tidyUp?.reason {
                    Text(String(localized: "Why, as the model put it: “\(reason)”"))
                        .font(.callout).italic().foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            if value.touched { inbox.edited(suggestion.id) }
        })
    }

    private var staleBanner: some View {
        HStack(spacing: 8) {
            Label(String(localized: "Changed since this was suggested"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
            Spacer()
            Button(String(localized: "Review Again")) { reviewAgain() }
                .help(String(localized: "Compare with the memory as it is now, then decide again."))
        }
        .font(.callout)
    }

    private func memory(_ id: UUID) -> Memory? { id == target?.id ? target : memories[id] }

    private func role(_ role: SuggestionTarget.Role) -> [Memory] {
        others.filter { $0.role == role }.compactMap { memory($0.memoryID) }
    }

    /// What the suggestion does, per action.
    @ViewBuilder
    private func context(_ binding: Binding<SuggestionDraft>) -> some View {
        switch suggestion.action {
        case .create:
            fields(binding)
        case .update:
            if let target { CorrectionDiff(old: target, new: binding.wrappedValue) }
            // A tidy-up update that absorbs a copy archives it too, or neither (§9.4).
            ForEach(role(.source)) { copy in quoted(String(localized: "Also archives “\(copy.title)”"), copy) }
            fields(binding)
        case .archive:
            if let reason = tidyUp?.archiveReason { Pill(label: Self.title(reason), tone: reason == .expired ? .neutral : .warning) }
            if let target { quoted(String(localized: "Archives “\(target.title)”"), target) }
            if let survivor = role(.survivor).first { quoted(String(localized: "Keeps “\(survivor.title)”"), survivor) }
            if tidyUp?.archiveReason == .expired, let date = target?.expiresAt {
                Text(String(localized: "It expired \(RelativeTime.full(date)).")).font(.callout).foregroundStyle(.secondary)
            }
        case .duplicate:
            if let target { quoted(String(localized: "Already in your vault: “\(target.title)”"), target) }
        case .split:
            if let target { quoted(String(localized: "Splits “\(target.title)” into \(pieces.count)"), target) }
            ForEach(pieces) { piece in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ForEach(GroupText.badges(piece, target: nil, agentName: piece.agentID.map(model.agentName)), id: \.0) {
                        Pill(label: $0.0, tone: $0.1)
                    }
                    Text(piece.title).fontWeight(.medium) + Text(" · \(piece.body)").foregroundStyle(.secondary)
                }
                .font(.callout).lineLimit(2)
            }
            if pieces.contains(where: { $0.action == .update || $0.action == .archive }) {
                Text(String(localized: "Pieces that change other memories stay in your Inbox to review on their own."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .merge:
            let sources = role(.source)
            Text(String(localized: "Merges \(sources.count) memories into one:")).font(.callout.weight(.medium))
            ForEach(sources) { source in
                VStack(alignment: .leading, spacing: 1) {
                    Label(source.title, systemImage: "arrow.triangle.merge").font(.callout).lineLimit(1)
                    if let kept = tidyUp?.kept?[source.id] {
                        Text(String(localized: "Keeps: \(kept)")).font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
                    }
                }
            }
            fields(binding)
        case .conflict:
            Text(String(localized: "These disagree. Which is true?")).font(.callout.weight(.medium))
            ForEach(role(.target)) { m in
                HStack(alignment: .top) {
                    quoted(m.title, m)
                    Button(String(localized: "Keep This")) { apply(.keep(m.id)) }
                        .disabled(stale || conflictEdit != nil)
                        .accessibilityLabel(String(localized: "Keep “\(m.title)”"))
                }
            }
            if conflictEdit != nil {
                TextField(String(localized: "Title"), text: Binding(get: { conflictEdit?.title ?? "" },
                                                                   set: { conflictEdit?.title = $0 }))
                    .textFieldStyle(.roundedBorder).font(.headline)
                TextField(String(localized: "Text"), text: Binding(get: { conflictEdit?.body ?? "" },
                                                                  set: { conflictEdit?.body = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...8)
            }
        case .unknown:
            Text(String(localized: "This version of Funes Vault can't apply this suggestion. Update the app, or reject it."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    static func title(_ reason: TidyUpArchiveReason) -> String {
        switch reason {
        case .duplicate: String(localized: "A copy")
        case .superseded: String(localized: "Out of date")
        case .expired: String(localized: "Expired")
        }
    }

    private func quoted(_ heading: String, _ memory: Memory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(heading) { model.showMemory(memory.id) }.buttonStyle(.link).font(.callout.weight(.medium))
            Text(memory.body).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
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
            switch suggestion.action {
            case .update:
                // A tidy-up update replaces or is rejected: keeping both would leave two copies.
                if suggestion.origin != .consolidation { Button(String(localized: "Keep Both")) { apply(.keepBoth) } }
                primary(String(localized: "Replace"), .replace).disabled(stale || target == nil || incomplete)
            case .create:
                primary(String(localized: "Apply")).help(String(localized: "Apply (⌘⏎)")).disabled(incomplete)
            case .archive:
                primary(String(localized: "Archive")).disabled(stale)
            case .duplicate:
                primary(String(localized: "Already Saved")).disabled(stale)
                    .help(String(localized: "Nothing changes: it's already in your vault."))
            case .split:
                primary(String(localized: "Split into \(pieces.filter { $0.action == .create }.count)"))
                    .disabled(stale || !pieces.contains { $0.action == .create })
            case .merge:
                primary(String(localized: "Merge")).disabled(stale || incomplete)
            case .conflict:
                if let edit = conflictEdit, let first = role(.target).first {
                    Button(String(localized: "Cancel")) { conflictEdit = nil }
                    Button(String(localized: "Save")) {
                        apply(.keep(first.id), edits: SuggestionEdit(title: edit.title, body: edit.body))
                    }
                    .buttonStyle(.borderedProminent).disabled(stale)
                } else {
                    Button(String(localized: "Edit…")) {
                        if let first = role(.target).first { conflictEdit = (first.title, first.body) }
                    }
                    .disabled(stale)
                    Button(String(localized: "Both Are True")) { apply(.bothTrue) }.disabled(stale)
                }
            case .unknown:
                EmptyView()
            }
        }
    }

    private var incomplete: Bool {
        form.map { $0.title.trimmingCharacters(in: .whitespaces).isEmpty
            || $0.body.trimmingCharacters(in: .whitespaces).isEmpty || $0.categoryKeys.isEmpty } ?? true
    }

    private func primary(_ title: String, _ mode: ApplyMode? = nil) -> some View {
        Button(title) { apply(mode) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
    }

    private func hint(_ text: String, _ memories: [Memory]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc").foregroundStyle(Palette.warning)
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
        case .consolidation: return String(localized: "Tidy-up · \(time)")
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
        others = (try? await services.suggestions.targets(suggestionID: suggestion.id)) ?? []
        memories = Dictionary(uniqueKeysWithValues: ((try? services.store.memories(ids: others.map(\.memoryID))) ?? []).map { ($0.id, $0) })
        pieces = suggestion.action == .split ? (try? await services.suggestions.pieces(groupID: suggestion.id)) ?? [] : []
        stale = (try? await services.suggestions.isStale(suggestion)) ?? false
        guard suggestion.action == .create || suggestion.action == .update || suggestion.action == .merge else {
            similar = []
            return
        }
        var ids = (try? services.store.exactDuplicates(title: suggestion.title, body: suggestion.body)) ?? []
        let names = suggestion.categoryKeys.map(model.categoryName)
        let near = (try? await services.search.nearDuplicates(title: suggestion.title, body: suggestion.body,
                                                               kind: suggestion.kind ?? .fact, categoryNames: names)) ?? []
        for id in near where !ids.contains(id) && id != suggestion.targetMemoryID { ids.append(id) }
        ids.removeAll { $0 == suggestion.targetMemoryID }
        similar = (try? services.store.memories(ids: ids)) ?? []
    }

    private func apply(_ mode: ApplyMode?, edits: SuggestionEdit? = nil) {
        Task {
            do {
                let result = try await inbox.apply(suggestion, mode: mode, edits: edits)
                error = nil
                if !result.similarMemoryIDs.isEmpty {
                    inbox.result = String(localized: "Applied “\(suggestion.title)”. A similar memory exists.")
                }
            } catch VaultError.targetChanged {
                stale = true
                await load()
            } catch {
                self.error = ErrorText.message(error)
            }
        }
    }

    private func reviewAgain() {
        Task {
            do {
                try await model.services.suggestions.reviewAgain(suggestionID: suggestion.id)
                error = nil
            } catch VaultError.targetChanged {
                error = String(localized: "A memory it changes was archived or deleted. Reject it, or restore that memory first.")
            } catch {
                self.error = ErrorText.message(error)
            }
            await load()
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

/// The Tidy-up section's header (04-ux-mac.md): "Last tidy-up: today 03:04 · 37 memories checked
/// · 4 suggestions" and Tidy Up Now.
struct TidyUpHeader: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(InboxModel.Group.tidyUp.title).font(.headline).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                Text(model.tidyUp.lastRun.map(TidyUpController.summary) ?? String(localized: "No tidy-up yet"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.tidyUp.running ? String(localized: "Tidying Up…") : String(localized: "Tidy Up Now")) {
                Task { await model.tidyUp.runNow() }
            }
            .disabled(model.tidyUp.running)
            .help(String(localized: "Look for duplicates, outdated memories and conflicts now."))
        }
    }
}
