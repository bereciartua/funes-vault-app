import FunesPhone
import FunesProtocol
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share extension (`com.funesvault.ios.share`): the shared text or URL, an optional note,
/// and **Save**, which adds it to the capture queue in the App Group. It never sends anything
/// itself; the app or a background refresh delivers (UX: iPhone, Capture surfaces).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let host = UIHostingController(rootView: ShareView(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

private struct ShareView: View {
    let providers: [NSItemProvider]
    let done: () -> Void
    let cancel: () -> Void

    @State private var shared: String?
    @State private var loading = true
    @State private var note = ""
    @State private var problem: String?
    @FocusState private var editingNote: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if loading {
                        ProgressView()
                    } else if let shared {
                        Text(shared)
                            .lineLimit(8)
                            .textSelection(.enabled)
                    } else {
                        Text("There's no text or link to save here.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Add a note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($editingNote)
                } footer: {
                    Text("Saved on this iPhone, then sent to Funes on your Mac when it's reachable.")
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Remember in Funes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Return adds a line to the note, so the keyboard has its own way out.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editingNote = false }.bold()
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(shared == nil)
                }
            }
            .onChange(of: note) { problem = nil }
            .task {
                switch await SharedContent.text(from: providers) {
                case let .text(text): shared = text
                case .tooLong: problem = Self.message(for: .tooLong)
                case .nothing: break
                }
                loading = false
            }
        }
    }

    private func save() {
        guard let shared else { return }
        do {
            try CaptureQueue.appGroup().add(shared, note: note, source: .share)
            AppSignal.queueChanged.post()
            done()
        } catch {
            problem = Self.message(for: error)
        }
    }

    static func message(for error: CaptureQueueError) -> String {
        switch error {
        case .empty: String(localized: "There's no text or link to save here.")
        case .tooLong: String(localized: "That's over 10,000 characters. Share a shorter selection.")
        case .secret: String(localized: "Blocked: looks like a secret. Funes never stores passwords, keys or card numbers.")
        case .full: String(localized: "Queue full: connect to your Mac.")
        case .storage: String(localized: "Couldn't save on this iPhone. Open Funes Vault and try again.")
        }
    }
}

/// The text to save from what was shared: the selected text, the link, or both.
@MainActor enum SharedContent {
    enum Loaded: Sendable {
        case text(String)
        /// Far over a capture's 10,000 characters: not read in full.
        case tooLong
        case nothing
    }

    /// A shared text's size is checked before it's read: a capture is at most 10,000 characters,
    /// so anything over this many bytes can't be one (the queue checks the exact count).
    nonisolated static let maxTextBytes = 256 * 1024

    static func text(from providers: [NSItemProvider]) async -> Loaded {
        var texts: [String] = [], links: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = await load(URL.self, from: provider), !url.isFileURL {
                links.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                switch await loadText(from: provider) {
                case let .text(text): texts.append(text)
                case .tooLong: return .tooLong
                case .nothing: break
                }
            }
        }
        // A link that's also the shared text needn't appear twice.
        let parts = texts + links.filter { link in !texts.contains { $0.contains(link) } }
        let joined = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return joined.isEmpty ? .nothing : .text(joined)
    }

    /// The shared text through a file, so its size is known before it's read; a provider that
    /// can't give a file gives the text itself.
    private static func loadText(from provider: NSItemProvider) async -> Loaded {
        let viaFile: Loaded? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.plainText.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                // The file goes once this returns, so it's read here.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
                guard size <= maxTextBytes else { return continuation.resume(returning: .tooLong) }
                var encoding = String.Encoding.utf8
                let text = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
                    ?? (try? String(contentsOf: url, usedEncoding: &encoding))
                continuation.resume(returning: text.map(Loaded.text))
            }
        }
        if let viaFile { return viaFile }
        return await load(String.self, from: provider).map(Loaded.text) ?? .nothing
    }

    private static func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }
}
