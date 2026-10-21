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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(shared == nil)
                }
            }
            .onChange(of: note) { problem = nil }
            .task {
                shared = await SharedContent.text(from: providers)
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
    static func text(from providers: [NSItemProvider]) async -> String? {
        var texts: [String] = [], links: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = await load(URL.self, from: provider), !url.isFileURL {
                links.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = await load(String.self, from: provider) {
                texts.append(text)
            }
        }
        // A link that's also the shared text needn't appear twice.
        let parts = texts + links.filter { link in !texts.contains { $0.contains(link) } }
        let joined = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    private static func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }
}
