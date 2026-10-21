import FunesPhone
import FunesProtocol
import SwiftUI

/// The Capture tab (UX: iPhone, Capture tab): type or dictate, **Remember** saves to the queue on
/// this iPhone at once, and delivery follows. Recent captures show where each one is.
struct CaptureView: View {
    let model: PhoneModel
    @State private var text = ""
    @State private var source = CaptureSource.typed
    @State private var dictation = Dictation()
    @State private var problem: String?
    @State private var saved = 0
    @State private var toast = false
    @FocusState private var focused: Bool

    private var capture: CaptureModel { model.capture }

    var body: some View {
        NavigationStack {
            List {
                if let banner = QueueBanner(reachability: model.reachability, waiting: capture.queuedCount) {
                    banner
                }
                Section {
                    editor
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if case let .failed(message) = dictation.state {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(action: remember) {
                        Text("Remember").bold().frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dictation.isActive)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                if !capture.recent.isEmpty {
                    Section("Recent captures") {
                        ForEach(capture.recent) { item in
                            RecentRow(item: item)
                                .swipeActions {
                                    if item.status != .sent {
                                        Button("Delete", role: .destructive) { capture.delete(item.id) }
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Capture")
            .overlay(alignment: .bottom) {
                if toast {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sensoryFeedback(.success, trigger: saved)
            .onChange(of: text) { problem = nil }
            .onChange(of: model.captureRequests, initial: true) { _, requests in
                if requests > 0 { focused = true }
            }
        }
    }

    private var editor: some View {
        HStack(alignment: .top) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty && !dictation.isActive {
                    Text("What should Funes remember?")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .accessibilityHidden(true)
                }
                TextEditor(text: dictation.isActive ? .constant(text + spoken) : $text)
                    .focused($focused)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("What should Funes remember?")
            }
            micButton
        }
    }

    /// The dictation so far, after what was typed.
    private var spoken: String {
        guard !dictation.transcript.isEmpty else { return "" }
        return (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + dictation.transcript
    }

    @ViewBuilder private var micButton: some View {
        if Dictation.isAvailable {
            Button {
                Task { await toggleDictation() }
            } label: {
                Image(systemName: dictation.isActive ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 34))
                    .symbolEffect(.pulse, isActive: dictation.state == .listening)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dictation.isActive ? .red : .accentColor)
            .accessibilityLabel(dictation.isActive ? "Stop Dictation" : "Dictate")
        } else {
            // Before iOS 26: the keyboard's own dictation.
            Button {
                focused = true
            } label: {
                Image(systemName: "mic.circle")
                    .font(.system(size: 34))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Dictate with the Keyboard")
            .accessibilityHint("Opens the keyboard. Tap its microphone to dictate.")
        }
    }

    private func toggleDictation() async {
        if dictation.isActive {
            let heard = spoken
            _ = await dictation.stop()
            if !heard.isEmpty {
                text += heard
                source = .dictation
            }
        } else {
            focused = false
            await dictation.start()
        }
    }

    private func remember() {
        do {
            try capture.remember(text, source: source)
            text = ""
            source = .typed
            problem = nil
            saved += 1
            withAnimation { toast = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { toast = false }
            }
        } catch {
            problem = CaptureModel.message(for: error)
        }
    }
}

/// "Mac not reachable · 3 captures waiting" and the other states, when there's something to say.
struct QueueBanner: View {
    let text: String
    let systemImage: String
    let tint: Color

    init?(reachability: PhoneModel.Reachability, waiting: Int) {
        switch reachability {
        case .notPaired:
            text = waiting > 0
                ? String(localized: "Not paired · \(waiting) captures waiting. Pair with your Mac in Settings.")
                : String(localized: "Pair with your Mac to start. Captures wait on this iPhone until then.")
            systemImage = "iphone.slash"
            tint = .secondary
        case .unreachable, .failed:
            guard waiting > 0 else { return nil }
            text = String(localized: "Mac not reachable · \(waiting) captures waiting")
            systemImage = "wifi.slash"
            tint = .orange
        case .revoked:
            text = String(localized: "This iPhone was removed from Funes on your Mac. Captures stay here until you pair again or delete them.")
            systemImage = "xmark.octagon.fill"
            tint = .red
        case .checking, .connected:
            guard waiting > 0 else { return nil }
            text = String(localized: "\(waiting) captures waiting")
            systemImage = "tray.and.arrow.up"
            tint = .secondary
        }
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
    }
}

struct RecentRow: View {
    let item: CaptureModel.Recent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.text).lineLimit(2)
            HStack(spacing: 6) {
                status
                Spacer()
                Text(item.createdAt, style: .relative).foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .sent: Label("Sent to Mac", systemImage: "checkmark").foregroundStyle(.green)
        case .waiting: Label("Waiting", systemImage: "clock").foregroundStyle(.secondary)
        case let .rejected(code): Label(CaptureModel.message(for: code), systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}
