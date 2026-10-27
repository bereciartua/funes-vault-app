import FunesCore
import FunesProtocol
import SwiftUI

/// A split input in the Inbox (04-ux-mac.md, memory processing §5.2): the source line, the
/// original text (collapsible), then one row per piece with its own buttons and a badge, and
/// Apply All, which skips pieces outside the agent's scope. Keep as One shows only while no
/// piece is decided.
struct GroupCard: View {
    let model: AppModel
    let groupID: UUID
    /// The group's undecided pieces, as the Inbox lists them.
    let pieces: [Suggestion]
    @State private var showOriginal = false

    private var inbox: InboxModel { model.inboxState }
    private var group: SuggestionGroup? { inbox.groups[groupID] }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sourceLine).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let engine = GroupText.engine(group?.engine, providerName: model.providerName) {
                    Text(engine).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let text = group?.sourceText, !text.isEmpty {
                DisclosureGroup(String(localized: "Original text"), isExpanded: $showOriginal) {
                    Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.callout)
            }
            if let truncated = group?.truncated, truncated > 0 {
                Label(String(localized: "Long input: \(group?.pieces.count ?? pieces.count) shown. The original text is attached."),
                      systemImage: "text.badge.minus")
                    .font(.callout).foregroundStyle(Palette.warning)
            }
            ForEach(pieces) { piece in
                PieceRow(model: model, piece: piece)
                if piece.id != pieces.last?.id { Divider() }
            }
            HStack(spacing: 8) {
                Spacer()
                if group?.canKeepAsOne == true {
                    Button(String(localized: "Keep as One")) { Task { if let group { await inbox.keepAsOne(group) } } }
                        .help(String(localized: "Throw the pieces away and keep what arrived as one suggestion."))
                }
                Button(String(localized: "Apply All")) { Task { if let group { await inbox.applyAll(group) } } }
                    .buttonStyle(.borderedProminent)
                    .disabled(group == nil)
                    .help(String(localized: "Apply each piece as it says. Pieces outside an agent's scope wait for you."))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Split suggestion with \(pieces.count) pieces"))
    }

    /// "From ChatGPT · 12 pieces".
    private var sourceLine: String {
        let count = pieces.count
        guard let first = pieces.first else { return "" }
        switch first.origin {
        case .agent:
            let name = first.agentID.map(model.agentName) ?? String(localized: "an agent")
            return String(localized: "From \(name) · \(count) pieces")
        case .captureMac: return String(localized: "Captured on this Mac · \(count) pieces")
        case .captureIPhone: return String(localized: "Captured on iPhone · \(count) pieces")
        case .seedQuestion: return String(localized: "Your answer · \(count) pieces")
        case .consolidation: return String(localized: "Tidy-up · \(count) pieces")
        case .import:
            switch first.importRunID.flatMap({ inbox.importSources[$0] }) {
            case .chatgpt: return String(localized: "From ChatGPT · \(count) pieces")
            case .claude: return String(localized: "From Claude · \(count) pieces")
            case .markdown: return String(localized: "From Markdown · \(count) pieces")
            case .funes, nil: return String(localized: "Imported · \(count) pieces")
            }
        }
    }
}

/// One piece: its badge, what it does, its own Apply and Reject, and the notes extraction left.
struct PieceRow: View {
    let model: AppModel
    let piece: Suggestion
    @State private var target: Memory?
    @State private var form: SuggestionDraft?
    @State private var error: String?

    private var inbox: InboxModel { model.inboxState }
    private var record: PieceRecord? { piece.pieceRecord }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(GroupText.badges(piece, target: target, agentName: piece.agentID.map(model.agentName)), id: \.0) { label, tone in
                    Pill(label: label, tone: tone)
                }
                Spacer()
                Button(String(localized: "Reject"), role: .destructive) { reject() }
                    .accessibilityLabel(String(localized: "Reject “\(piece.title)”"))
                primary
            }
            content
            if let record {
                if !record.atomic {
                    Text(String(localized: "May contain more than one thing.")).font(.caption).foregroundStyle(Palette.warning)
                }
                if !record.supported {
                    Text(String(localized: "Has words that aren't in the original: check the wording."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let evidence = piece.evidence, !evidence.isEmpty {
                Text(String(localized: "From: “\(evidence.replacingOccurrences(of: "\n", with: "” · “"))”"))
                    .font(.caption).italic().foregroundStyle(.secondary).lineLimit(3)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
        }
        .padding(.vertical, 2)
        .task(id: piece.id) {
            form = inbox.draft(for: piece)
            target = piece.targetMemoryID.flatMap { try? model.services.store.memory(id: $0) }
        }
        .onChange(of: piece) { _, current in form = inbox.draft(for: current) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Piece: \(piece.title)"))
    }

    @ViewBuilder
    private var content: some View {
        switch piece.action {
        case .update:
            if let target, let form { CorrectionDiff(old: target, new: form) }
            if let claim = record?.claim { Text(claim).font(.callout) }
        case .duplicate:
            Text(String(localized: "Already in your vault: “\(target?.title ?? piece.title)”")).font(.callout.weight(.medium))
            Text(piece.body).font(.callout).foregroundStyle(.secondary)
        case .archive:
            Text(String(localized: "Says “\(target?.title ?? "")” is no longer true")).font(.callout.weight(.medium))
            Text(piece.body).font(.callout).foregroundStyle(.secondary)
        default:
            if form != nil {
                TextField(String(localized: "Title"), text: binding(\.title)).textFieldStyle(.roundedBorder).font(.headline)
                TextField(String(localized: "Text"), text: binding(\.body), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...6)
                HStack(spacing: 10) {
                    CategoryTokens(keys: binding(\.categoryKeys), categories: model.categories)
                    SensitivityPicker(selection: binding(\.sensitivity))
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<SuggestionDraft, T>) -> Binding<T> {
        Binding(get: { form![keyPath: path] }, set: { value in
            form?[keyPath: path] = value
            inbox.drafts[piece.id] = form
        })
    }

    @ViewBuilder
    private var primary: some View {
        switch piece.action {
        case .update:
            Button(String(localized: "Keep Both")) { apply(.keepBoth) }
            Button(String(localized: "Replace")) { apply(.replace) }.buttonStyle(.borderedProminent).disabled(target == nil)
        case .archive:
            Button(String(localized: "Archive")) { apply(nil) }.buttonStyle(.borderedProminent).disabled(target == nil)
        case .duplicate:
            Button(String(localized: "Already Saved")) { apply(nil) }
                .help(String(localized: "Nothing changes: it's already in your vault."))
        default:
            Button(String(localized: "Apply")) { apply(nil) }.buttonStyle(.borderedProminent)
        }
    }

    private func apply(_ mode: ApplyMode?) {
        Task {
            do {
                _ = try await inbox.apply(piece, mode: mode)
                error = nil
            } catch {
                self.error = ErrorText.message(error)
            }
        }
    }

    private func reject() {
        Task {
            do { try await inbox.reject(piece) } catch { self.error = ErrorText.message(error) }
        }
    }
}

/// The Applied automatically list (memory processing §5.7, §9.5): one row per change Funes made,
/// with Undo for 30 days, and "Undo This and N Later Changes" when later ones depend on it.
struct AppliedAutomaticallyList: View {
    let model: AppModel
    @State private var needsLater: [UUID: Int] = [:]

    private var inbox: InboxModel { model.inboxState }

    var body: some View {
        if !inbox.applied.isEmpty {
            DisclosureGroup(String(localized: "Applied automatically (\(inbox.applied.count))")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Changes Funes made without asking. You can undo each for 30 days."))
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(inbox.applied) { entry in
                        if let change = inbox.appliedChanges[entry.id] {
                            DisclosureGroup {
                                ChangeDetailView(model: model, change: change, showsHeadline: false).padding(.top, 4)
                            } label: {
                                appliedRow(entry)
                            }
                        } else {
                            appliedRow(entry)
                        }
                    }
                }
                .padding(.top, 6)
            }
            .padding(.top, 10)
        }
    }

    private func appliedRow(_ entry: UndoEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(GroupText.change(entry, titles: inbox.appliedTitles)).lineLimit(1)
                Text(RelativeTime.short(entry.createdAt, now: model.now)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let later = needsLater[entry.id] {
                Button(String(localized: "Undo This and \(later) Later Changes")) {
                    Task {
                        _ = await inbox.undo(entry, includingLater: true)
                        needsLater[entry.id] = nil
                    }
                }
            } else {
                Button(String(localized: "Undo")) {
                    Task { needsLater[entry.id] = await inbox.undo(entry) }
                }
                .accessibilityLabel(String(localized: "Undo: \(GroupText.change(entry, titles: inbox.appliedTitles))"))
            }
        }
    }
}

/// The words of the group card and the Applied automatically list.
enum GroupText {
    /// "Split by Claude via Anthropic"; "Split on this Mac" for a local model.
    static func engine(_ engine: String?, providerName: (String) -> String?) -> String? {
        guard let engine else { return nil }
        let parts = engine.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return String(localized: "Split by \(engine)") }
        let model = parts[1].split(separator: "/").last.map(String.init) ?? parts[1]
        return String(localized: "Split by \(model) via \(providerName(parts[0]) ?? parts[0])")
    }

    /// New · Updates <memory> · Already saved · Removes <memory>, and Outside <agent>'s scope.
    static func badges(_ piece: Suggestion, target: Memory?, agentName: String?) -> [(String, Pill.Tone)] {
        var out: [(String, Pill.Tone)] = []
        let title = target?.title ?? ""
        switch piece.action {
        case .update: out.append((String(localized: "Updates “\(title)”"), .accent))
        case .duplicate: out.append((String(localized: "Already saved"), .neutral))
        case .archive: out.append((String(localized: "Removes “\(title)”"), .warning))
        default: out.append((String(localized: "New"), .good))
        }
        if piece.outsideScope {
            out.append((String(localized: "Outside \(agentName ?? String(localized: "the agent"))'s scope"), .warning))
        }
        return out
    }

    /// What an automatic change did: "Saved “Prefers tea”", "Updated “Coffee order”"; the
    /// tidy-up's: "Tidy-up: merged 2 memories into “Harbor dates”".
    static func change(_ entry: UndoEntry, titles: [UUID: String]) -> String {
        let title = entry.memoryIDs.lazy.compactMap { titles[$0] }.first ?? String(localized: "a memory")
        if entry.runID != nil {
            // The memories it named come first, then the ones it created.
            let last = entry.memoryIDs.last.flatMap { titles[$0] } ?? title
            switch entry.action {
            case "update" where entry.memoryIDs.count > 1: return String(localized: "Tidy-up: updated “\(title)” and archived a copy")
            case "update": return String(localized: "Tidy-up: updated “\(title)”")
            case "archive": return String(localized: "Tidy-up: archived “\(title)”")
            case "merge": return String(localized: "Tidy-up: merged \(entry.memoryIDs.count - 1) memories into “\(last)”")
            case "split": return String(localized: "Tidy-up: split “\(title)” into \(entry.memoryIDs.count - 1)")
            default: return String(localized: "Tidy-up: changed “\(title)”")
            }
        }
        switch entry.action {
        case "create": return String(localized: "Saved “\(title)”")
        case "update": return String(localized: "Updated “\(title)”")
        case "archive": return String(localized: "Archived “\(title)”")
        case "duplicate": return String(localized: "Skipped: already saved “\(title)”")
        case "merge": return String(localized: "Merged into “\(title)”")
        case "split": return String(localized: "Split “\(title)”")
        default: return String(localized: "Changed “\(title)”")
        }
    }
}
