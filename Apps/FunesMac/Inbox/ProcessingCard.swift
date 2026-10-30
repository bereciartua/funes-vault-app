import FunesCore
import FunesProtocol
import SwiftUI

/// A new input New memories processing hasn't finished with (memory processing §5.2, 04-ux-mac.md
/// ▸ Inbox): the original text, read-only, with why it's waiting, and only Reject, which cancels
/// the job. When the split failed: "Couldn't split", with Try Again and Keep as One.
struct ProcessingBody: View {
    let model: AppModel
    let suggestion: Suggestion
    let state: InputProcessing
    @State private var error: String?

    private var inbox: InboxModel { model.inboxState }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if state.isProcessing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                }
                Text(state.isProcessing ? String(localized: "Processing…") : String(localized: "Couldn't split"))
                    .font(.callout.weight(.medium))
                Text(Self.status(state, engine: model.modelSettings.newMemoriesName))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Text(suggestion.body)
                .foregroundStyle(state.isProcessing ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            HStack(spacing: 8) {
                if state.isProcessing {
                    Text(String(localized: "It can be saved once it's split."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Reject"), role: .destructive) { run { try await inbox.reject(suggestion) } }
                if !state.isProcessing {
                    Button(String(localized: "Keep as One")) { run { try await inbox.keepAsOne(suggestion) } }
                        .help(String(localized: "Review it as it is, as one memory."))
                    Button(String(localized: "Try Again")) { run { try await inbox.retry(suggestion) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                error = nil
            } catch {
                self.error = ErrorText.message(error)
            }
        }
    }

    /// Why it's waiting, or why the split failed.
    static func status(_ state: InputProcessing, engine: String?) -> String {
        switch state {
        case .running:
            engine.map { String(localized: "Splitting with \($0)…") } ?? String(localized: "Splitting…")
        case .queued(ahead: 0):
            String(localized: "Next in line")
        case let .queued(ahead):
            ahead == 1 ? String(localized: "1 ahead of it") : String(localized: "\(ahead) ahead of it")
        case .waiting(_, capReached: true):
            String(localized: "Waiting: today's model limit reached")
        case .waiting:
            String(localized: "Waiting to try again")
        case let .failed(code):
            switch code {
            case "timeout": String(localized: "The model took too long.")
            case "unavailable": String(localized: "The model isn't available.")
            case "unauthorized": String(localized: "Check the provider's API key.")
            case "rate_limited": String(localized: "The provider is busy.")
            case "invalid_output": String(localized: "The model's answer wasn't usable.")
            case "no_pieces": String(localized: "Nothing usable came back.")
            default: String(localized: "The model failed.")
            }
        }
    }
}
