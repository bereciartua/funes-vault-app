import AppKit
import FunesCore
import FunesProtocol
import SwiftUI
import UniformTypeIdentifiers

enum ImportKind: String, Identifiable {
    case chatGPT, claude, markdown, funes
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatGPT: String(localized: "Import ChatGPT Memories")
        case .claude: String(localized: "Paste Claude Memories")
        case .markdown: String(localized: "Import a Markdown File")
        case .funes: String(localized: "Import a Funes Vault Export")
        }
    }
}

/// Imports (FR-X-01..04, FR-X-06): read the file or the pasted text, show what would happen
/// (count, likely duplicates, secret-scanner blocks, over-long items) and only then store them as
/// suggestions. Imports never create agents or access.
struct ImportSheet: View {
    let model: AppModel
    let kind: ImportKind
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var preview: ImportPreview?
    @State private var includeDuplicates = false
    @State private var asMemories = false
    @State private var error: String?
    @State private var done: String?
    /// Today's cloud requests, for the split estimate (memory processing §5.8).
    @State private var today: CloudRequestCap.Day?

    /// Splitting is on and this import would be split.
    private var splits: Bool { model.preferences.splitNewMemories && kind != .funes && model.modelSettings.chosenName != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind.title).font(.title2.weight(.semibold))
            if let done {
                Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack {
                    Spacer()
                    Button(String(localized: "Open Inbox")) {
                        dismiss()
                        model.show(.inbox)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if let preview {
                previewView(preview)
            } else {
                source
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder
    private var source: some View {
        switch kind {
        case .claude:
            Text(String(localized: "In Claude, open Settings ▸ Capabilities ▸ Memory, copy what's there, and paste it here. Each line or bullet becomes a suggestion."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $pasted)
                .font(.body)
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.separator))
                .accessibilityLabel(String(localized: "Claude memories"))
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Preview")) { load(text: pasted) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        default:
            Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Choose File…")) { chooseFile() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var explanation: String {
        switch kind {
        case .chatGPT: String(localized: "Choose the memories file from your ChatGPT data export (JSON). Each memory becomes a suggestion.")
        case .markdown: String(localized: "Choose a Markdown file. Headings that match a category's name file the items under them; bullets and paragraphs become suggestions.")
        case .funes: String(localized: "Choose a funesvault.export.v1 file. Its memories come in as suggestions, or as memories if you choose so below. It never brings agents or access.")
        case .claude: ""
        }
    }

    private func previewView(_ preview: ImportPreview) -> some View {
        let ready = preview.entries.filter { $0.status == .ready }.count
        return VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text(String(localized: "Found")).foregroundStyle(.secondary); Text("\(preview.total)") }
                GridRow { Text(String(localized: "Ready")).foregroundStyle(.secondary); Text("\(ready)") }
                GridRow { Text(String(localized: "Likely duplicates")).foregroundStyle(.secondary); Text("\(preview.duplicates)") }
                GridRow {
                    Text(String(localized: "Look like secrets")).foregroundStyle(.secondary)
                    Text(preview.blocked == 0 ? "0" : String(localized: "\(preview.blocked), never imported"))
                }
                if preview.tooLong > 0 {
                    GridRow { Text(String(localized: "Longer than 10,000 characters")).foregroundStyle(.secondary); Text("\(preview.tooLong)") }
                }
                if !preview.newCategories.isEmpty {
                    GridRow {
                        Text(String(localized: "New categories")).foregroundStyle(.secondary)
                        Text(preview.newCategories.map(\.name).joined(separator: ", "))
                    }
                }
            }
            if preview.tooLong > 0 {
                HStack {
                    Text(String(localized: "Long items:"))
                    Button(String(localized: "Split Them")) { resolve(.split) }
                    Button(String(localized: "Shorten Them")) { resolve(.truncate) }
                }
                .font(.callout)
            }
            if preview.duplicates > 0 {
                Toggle(String(localized: "Import likely duplicates too"), isOn: $includeDuplicates)
            }
            if splits {
                let estimate = preview.estimatedRequests(includeDuplicates: includeDuplicates)
                let left = max(0, model.modelSettings.dailyCap - (today?.total ?? 0))
                Text(String(localized: "Splitting them into separate memories takes about \(estimate) requests to \(model.modelSettings.chosenName ?? ""). With a cloud model, \(left) of today's requests are left; the rest wait for tomorrow."))
                    .font(.callout).foregroundStyle(.secondary)
                    .task { today = try? await model.modelSettings.cap(store: model.services.store, activity: model.services.activity).today(now: Date()) }
            }
            if kind == .funes {
                Toggle(String(localized: "Restore as memories, not suggestions"), isOn: $asMemories)
                if asMemories {
                    WarningLabel(text: String(localized: "They skip the Inbox. Only do this with your own export."))
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                let count = ready + (includeDuplicates ? preview.duplicates : 0)
                if splits {
                    Button(String(localized: "Import Without Splitting")) { commit(preview, split: false) }
                        .disabled(count == 0 || preview.tooLong > 0)
                }
                Button(asMemories ? String(localized: "Restore \(count)") : String(localized: "Send \(count) to Inbox")) { commit(preview) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0 || preview.tooLong > 0)
            }
        }
    }

    // MARK: Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        switch kind {
        case .markdown: panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        default: panel.allowedContentTypes = [.json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 20 << 20 else {
                error = String(localized: "That file is over 20 MB.")
                return
            }
            if kind == .markdown {
                load(text: String(decoding: data, as: UTF8.self))
            } else {
                load(data: data)
            }
        } catch {
            self.error = String(localized: "The file couldn't be read.")
        }
    }

    private func load(text: String) {
        let items: [ImportItem] = kind == .markdown ? ImportParser.markdown(text, categories: model.categories) : ImportParser.claude(text)
        Task { await preview(items, source: kind == .markdown ? .markdown : .claude) }
    }

    private func load(data: Data) {
        Task {
            do {
                if kind == .funes {
                    let export = try ImportParser.funesExport(data)
                    preview = try await model.services.imports.preview(funesExport: export)
                } else {
                    await preview(try ImportParser.chatGPT(data), source: .chatgpt)
                }
                error = nil
            } catch {
                self.error = kind == .funes ? String(localized: "That isn't a Funes Vault export.")
                                            : String(localized: "That file doesn't hold ChatGPT memories Funes can read.")
            }
        }
    }

    private func preview(_ items: [ImportItem], source: ImportSource) async {
        guard !items.isEmpty else {
            error = String(localized: "Nothing to import was found.")
            return
        }
        do {
            preview = try await model.services.imports.preview(items, source: source)
            error = nil
        } catch {
            self.error = ErrorText.message(error)
        }
    }

    private func resolve(_ choice: ImportPreview.LongItems) {
        guard let current = preview else { return }
        let items = current.resolvingLongItems(choice)
        Task {
            preview = try? await model.services.imports.preview(items, source: current.source, newCategories: current.newCategories)
        }
    }

    private func commit(_ preview: ImportPreview, split: Bool = true) {
        Task {
            do {
                let result = try await model.services.imports.commit(preview, includeDuplicates: includeDuplicates,
                                                                     asMemories: asMemories, split: split, now: Date())
                model.preferences.set(Preferences.Key.checklistSeeded, true)
                let count = result.suggestionIDs.count + result.memoryIDs.count
                done = asMemories ? String(localized: "\(count) memories restored.") : String(localized: "\(count) suggestions are in your Inbox.")
                await model.refresh()
            } catch {
                self.error = ErrorText.message(error)
            }
        }
    }
}
